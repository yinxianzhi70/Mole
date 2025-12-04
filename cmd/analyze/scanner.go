package main

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sync/singleflight"
)

var scanGroup singleflight.Group

func scanPathConcurrent(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) (scanResult, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}

	var total int64
	entries := make([]dirEntry, 0, len(children))
	largeFiles := make([]fileEntry, 0, maxLargeFiles*2)

	// Use worker pool for concurrent directory scanning
	// For I/O-bound operations, use more workers than CPU count
	numWorkers := runtime.NumCPU() * cpuMultiplier
	if numWorkers < minWorkers {
		numWorkers = minWorkers
	}
	if numWorkers > maxWorkers {
		numWorkers = maxWorkers
	}
	if numWorkers > len(children) {
		numWorkers = len(children)
	}
	if numWorkers < 1 {
		numWorkers = 1
	}
	sem := make(chan struct{}, numWorkers)
	var wg sync.WaitGroup

	// Use channels to collect results without lock contention
	entryChan := make(chan dirEntry, len(children))
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	// Start goroutines to collect from channels
	var collectorWg sync.WaitGroup
	collectorWg.Add(2)
	go func() {
		defer collectorWg.Done()
		for entry := range entryChan {
			entries = append(entries, entry)
		}
	}()
	go func() {
		defer collectorWg.Done()
		for file := range largeFileChan {
			largeFiles = append(largeFiles, file)
		}
	}()

	isRootDir := root == "/"

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		// Skip symlinks to avoid following them into unexpected locations
		// Use Type() instead of IsDir() to check without following symlinks
		if child.Type()&fs.ModeSymlink != 0 {
			// For symlinks, get their target info but mark them specially
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			atomic.AddInt64(&total, size)

			entryChan <- dirEntry{
				Name:       child.Name() + " →", // Add arrow to indicate symlink
				Path:       fullPath,
				Size:       size,
				IsDir:      false, // Don't allow navigation into symlinks
				LastAccess: getLastAccessTimeFromInfo(info),
			}
			continue
		}

		if child.IsDir() {
			// In root directory, skip system directories completely
			if isRootDir && skipSystemDirs[child.Name()] {
				continue
			}

			// For folded directories, calculate size quickly without expanding
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()

					// Try du command first for folded dirs (much faster)
					size, err := getDirectorySizeFromDu(path)
					if err != nil || size <= 0 {
						// Fallback to walk if du fails
						size = calculateDirSizeFast(path, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					entryChan <- dirEntry{
						Name:       name,
						Path:       path,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{}, // Lazy load when displayed
					}
				}(child.Name(), fullPath)
				continue
			}

			// Normal directory: full scan with detail
			wg.Add(1)
			go func(name, path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)

				entryChan <- dirEntry{
					Name:       name,
					Path:       path,
					Size:       size,
					IsDir:      true,
					LastAccess: time.Time{}, // Lazy load when displayed
				}
			}(child.Name(), fullPath)
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}
		// Get actual disk usage for sparse files and cloud files
		size := getActualFileSize(fullPath, info)
		atomic.AddInt64(&total, size)
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		entryChan <- dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			IsDir:      false,
			LastAccess: getLastAccessTimeFromInfo(info),
		}
		// Only track large files that are not code/text files
		if !shouldSkipFileForLargeTracking(fullPath) && size >= minLargeFileSize {
			largeFileChan <- fileEntry{Name: child.Name(), Path: fullPath, Size: size}
		}
	}

	wg.Wait()

	// Close channels and wait for collectors to finish
	close(entryChan)
	close(largeFileChan)
	collectorWg.Wait()

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Size > entries[j].Size
	})
	if len(entries) > maxEntries {
		entries = entries[:maxEntries]
	}

	// Try to use Spotlight (mdfind) for faster large file discovery
	// This is a performance optimization that gracefully falls back to scan results
	// if Spotlight is unavailable or fails. The fallback is intentionally silent
	// because users only care about correct results, not the method used.
	if spotlightFiles := findLargeFilesWithSpotlight(root, minLargeFileSize); len(spotlightFiles) > 0 {
		largeFiles = spotlightFiles
	} else {
		// Use files collected during scanning (fallback path)
		// Sort and trim large files collected from scanning
		sort.Slice(largeFiles, func(i, j int) bool {
			return largeFiles[i].Size > largeFiles[j].Size
		})
		if len(largeFiles) > maxLargeFiles {
			largeFiles = largeFiles[:maxLargeFiles]
		}
	}

	return scanResult{
		Entries:    entries,
		LargeFiles: largeFiles,
		TotalSize:  total,
	}, nil
}

func shouldFoldDirWithPath(name, path string) bool {
	// Check basic fold list first
	if foldDirs[name] {
		return true
	}

	// Special case: npm cache directories - fold all subdirectories
	// This includes: .npm/_quick/*, .npm/_cacache/*, .npm/a-z/*, .tnpm/*
	if strings.Contains(path, "/.npm/") || strings.Contains(path, "/.tnpm/") {
		// Get the parent directory name
		parent := filepath.Base(filepath.Dir(path))
		// If parent is a cache folder (_quick, _cacache, etc) or npm dir itself, fold it
		if parent == ".npm" || parent == ".tnpm" || strings.HasPrefix(parent, "_") {
			return true
		}
		// Also fold single-letter subdirectories (npm cache structure like .npm/a/, .npm/b/)
		if len(name) == 1 {
			return true
		}
	}

	return false
}

func shouldSkipFileForLargeTracking(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return skipExtensions[ext]
}

// calculateDirSizeFast performs fast directory size calculation without detailed tracking or large file detection.
// Updates progress counters in batches to reduce atomic operation overhead.
func calculateDirSizeFast(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	var total int64
	var localFiles, localDirs int64
	var batchBytes int64

	// Create context with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	walkFunc := func(path string, d fs.DirEntry, err error) error {
		// Check for timeout
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if err != nil {
			return nil
		}
		if d.IsDir() {
			localDirs++
			// Batch update every N dirs to reduce atomic operations
			if localDirs%batchUpdateSize == 0 {
				atomic.AddInt64(dirsScanned, batchUpdateSize)
				localDirs = 0
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		// Get actual disk usage for sparse files and cloud files
		size := getActualFileSize(path, info)
		total += size
		batchBytes += size
		localFiles++
		if currentPath != nil {
			*currentPath = path
		}
		// Batch update every N files to reduce atomic operations
		if localFiles%batchUpdateSize == 0 {
			atomic.AddInt64(filesScanned, batchUpdateSize)
			atomic.AddInt64(bytesScanned, batchBytes)
			localFiles = 0
			batchBytes = 0
		}
		return nil
	}

	_ = filepath.WalkDir(root, walkFunc)

	// Final update for remaining counts
	if localFiles > 0 {
		atomic.AddInt64(filesScanned, localFiles)
	}
	if localDirs > 0 {
		atomic.AddInt64(dirsScanned, localDirs)
	}
	if batchBytes > 0 {
		atomic.AddInt64(bytesScanned, batchBytes)
	}

	return total
}

// Use Spotlight (mdfind) to quickly find large files in a directory
func findLargeFilesWithSpotlight(root string, minSize int64) []fileEntry {
	// mdfind query: files >= minSize in the specified directory
	query := fmt.Sprintf("kMDItemFSSize >= %d", minSize)

	ctx, cancel := context.WithTimeout(context.Background(), mdlsTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "mdfind", "-onlyin", root, query)
	output, err := cmd.Output()
	if err != nil {
		// Fallback: mdfind not available or failed
		return nil
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	var files []fileEntry

	for _, line := range lines {
		if line == "" {
			continue
		}

		// Filter out code files first (cheapest check, no I/O)
		if shouldSkipFileForLargeTracking(line) {
			continue
		}

		// Filter out files in folded directories (cheap string check)
		if isInFoldedDir(line) {
			continue
		}

		// Use Lstat instead of Stat (faster, doesn't follow symlinks)
		info, err := os.Lstat(line)
		if err != nil {
			continue
		}

		// Skip if it's a directory or symlink
		if info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		// Get actual disk usage for sparse files and cloud files
		actualSize := getActualFileSize(line, info)
		files = append(files, fileEntry{
			Name: filepath.Base(line),
			Path: line,
			Size: actualSize,
		})
	}

	// Sort by size (descending)
	sort.Slice(files, func(i, j int) bool {
		return files[i].Size > files[j].Size
	})

	// Return top N
	if len(files) > maxLargeFiles {
		files = files[:maxLargeFiles]
	}

	return files
}

// isInFoldedDir checks if a path is inside a folded directory (optimized)
func isInFoldedDir(path string) bool {
	// Split path into components for faster checking
	parts := strings.Split(path, string(os.PathSeparator))
	for _, part := range parts {
		if foldDirs[part] {
			return true
		}
	}
	return false
}

func calculateDirSizeConcurrent(root string, largeFileChan chan<- fileEntry, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	// Read immediate children
	children, err := os.ReadDir(root)
	if err != nil {
		return 0
	}

	var total int64
	var wg sync.WaitGroup

	// Limit concurrent subdirectory scans to avoid too many goroutines
	maxConcurrent := runtime.NumCPU() * 2
	if maxConcurrent > maxDirWorkers {
		maxConcurrent = maxDirWorkers
	}
	sem := make(chan struct{}, maxConcurrent)

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		// Skip symlinks to avoid following them into unexpected locations
		if child.Type()&fs.ModeSymlink != 0 {
			// For symlinks, just count their size without following
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			total += size
			atomic.AddInt64(filesScanned, 1)
			atomic.AddInt64(bytesScanned, size)
			continue
		}

		if child.IsDir() {
			// Check if this is a folded directory
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				// Use du for folded directories (much faster)
				wg.Add(1)
				go func(path string) {
					defer wg.Done()
					size, err := getDirectorySizeFromDu(path)
					if err == nil && size > 0 {
						atomic.AddInt64(&total, size)
						atomic.AddInt64(bytesScanned, size)
						atomic.AddInt64(dirsScanned, 1)
					}
				}(fullPath)
				continue
			}

			// Recursively scan subdirectory in parallel
			wg.Add(1)
			go func(path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)
			}(fullPath)
			continue
		}

		// Handle files
		info, err := child.Info()
		if err != nil {
			continue
		}

		size := getActualFileSize(fullPath, info)
		total += size
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		// Track large files
		if !shouldSkipFileForLargeTracking(fullPath) && size >= minLargeFileSize {
			largeFileChan <- fileEntry{Name: child.Name(), Path: fullPath, Size: size}
		}

		// Update current path
		if currentPath != nil {
			*currentPath = fullPath
		}
	}

	wg.Wait()
	return total
}

// measureOverviewSize calculates the size of a directory using multiple strategies.
func measureOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}

	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return 0, fmt.Errorf("path must be absolute: %s", path)
	}

	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("cannot access path: %v", err)
	}

	if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
		return cached, nil
	}

	if duSize, err := getDirectorySizeFromDu(path); err == nil && duSize > 0 {
		_ = storeOverviewSize(path, duSize)
		return duSize, nil
	}

	if logicalSize, err := getDirectoryLogicalSize(path); err == nil && logicalSize > 0 {
		_ = storeOverviewSize(path, logicalSize)
		return logicalSize, nil
	}

	if cached, err := loadCacheFromDisk(path); err == nil {
		_ = storeOverviewSize(path, cached.TotalSize)
		return cached.TotalSize, nil
	}

	return 0, fmt.Errorf("unable to measure directory size with fast methods")
}

func getDirectorySizeFromDu(path string) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "du", "-sk", path)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return 0, fmt.Errorf("du timeout after %v", duTimeout)
		}
		if stderr.Len() > 0 {
			return 0, fmt.Errorf("du failed: %v (%s)", err, stderr.String())
		}
		return 0, fmt.Errorf("du failed: %v", err)
	}
	fields := strings.Fields(stdout.String())
	if len(fields) == 0 {
		return 0, fmt.Errorf("du output empty")
	}
	kb, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse du output: %v", err)
	}
	if kb <= 0 {
		return 0, fmt.Errorf("du size invalid: %d", kb)
	}
	return kb * 1024, nil
}

func getDirectoryLogicalSize(path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsPermission(err) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		total += getActualFileSize(p, info)
		return nil
	})
	if err != nil && err != filepath.SkipDir {
		return 0, err
	}
	return total, nil
}

func getActualFileSize(_ string, info fs.FileInfo) int64 {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return info.Size()
	}

	actualSize := stat.Blocks * 512
	if actualSize < info.Size() {
		return actualSize
	}
	return info.Size()
}

func getLastAccessTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return getLastAccessTimeFromInfo(info)
}

func getLastAccessTimeFromInfo(info fs.FileInfo) time.Time {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}
	}
	return time.Unix(stat.Atimespec.Sec, stat.Atimespec.Nsec)
}
