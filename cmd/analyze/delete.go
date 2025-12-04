package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"sync/atomic"

	tea "github.com/charmbracelet/bubbletea"
)

func deletePathCmd(path string, counter *int64) tea.Cmd {
	return func() tea.Msg {
		count, err := deletePathWithProgress(path, counter)
		return deleteProgressMsg{
			done:  true,
			err:   err,
			count: count,
			path:  path,
		}
	}
}

func deletePathWithProgress(root string, counter *int64) (int64, error) {
	var count int64
	var firstErr error

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Skip permission errors but continue walking
			if os.IsPermission(err) {
				if firstErr == nil {
					firstErr = err
				}
				return filepath.SkipDir
			}
			// For other errors, record and continue
			if firstErr == nil {
				firstErr = err
			}
			return nil
		}

		if !d.IsDir() {
			if removeErr := os.Remove(path); removeErr == nil {
				count++
				if counter != nil {
					atomic.StoreInt64(counter, count)
				}
			} else if firstErr == nil {
				// Record first deletion error
				firstErr = removeErr
			}
		}

		return nil
	})

	// Track walk error separately
	if err != nil && firstErr == nil {
		firstErr = err
	}

	// Try to remove remaining directory structure
	// Even if this fails, we still report files deleted
	if removeErr := os.RemoveAll(root); removeErr != nil {
		if firstErr == nil {
			firstErr = removeErr
		}
	}

	// Always return count (even if there were errors), along with first error
	return count, firstErr
}
