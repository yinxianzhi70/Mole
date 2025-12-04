package main

import (
	"bufio"
	"context"
	"errors"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/load"
)

const (
	cpuSampleInterval = 200 * time.Millisecond
)

func collectCPU() (CPUStatus, error) {
	counts, countsErr := cpu.Counts(false)
	if countsErr != nil || counts == 0 {
		counts = runtime.NumCPU()
	}

	logical, logicalErr := cpu.Counts(true)
	if logicalErr != nil || logical == 0 {
		logical = runtime.NumCPU()
	}
	if logical <= 0 {
		logical = 1
	}

	percents, err := cpu.Percent(cpuSampleInterval, true)
	var totalPercent float64
	perCoreEstimated := false
	if err != nil || len(percents) == 0 {
		fallbackUsage, fallbackPerCore, fallbackErr := fallbackCPUUtilization(logical)
		if fallbackErr != nil {
			if err != nil {
				return CPUStatus{}, err
			}
			return CPUStatus{}, fallbackErr
		}
		totalPercent = fallbackUsage
		percents = fallbackPerCore
		perCoreEstimated = true
	} else {
		for _, v := range percents {
			totalPercent += v
		}
		totalPercent /= float64(len(percents))
	}

	loadStats, loadErr := load.Avg()
	var loadAvg load.AvgStat
	if loadStats != nil {
		loadAvg = *loadStats
	}
	if loadErr != nil || isZeroLoad(loadAvg) {
		if fallback, err := fallbackLoadAvgFromUptime(); err == nil {
			loadAvg = fallback
		}
	}

	return CPUStatus{
		Usage:            totalPercent,
		PerCore:          percents,
		PerCoreEstimated: perCoreEstimated,
		Load1:            loadAvg.Load1,
		Load5:            loadAvg.Load5,
		Load15:           loadAvg.Load15,
		CoreCount:        counts,
		LogicalCPU:       logical,
	}, nil
}

func isZeroLoad(avg load.AvgStat) bool {
	return avg.Load1 == 0 && avg.Load5 == 0 && avg.Load15 == 0
}

func fallbackLoadAvgFromUptime() (load.AvgStat, error) {
	if !commandExists("uptime") {
		return load.AvgStat{}, errors.New("uptime command unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	out, err := runCmd(ctx, "uptime")
	if err != nil {
		return load.AvgStat{}, err
	}

	markers := []string{"load averages:", "load average:"}
	idx := -1
	for _, marker := range markers {
		if pos := strings.LastIndex(out, marker); pos != -1 {
			idx = pos + len(marker)
			break
		}
	}
	if idx == -1 {
		return load.AvgStat{}, errors.New("load averages not found in uptime output")
	}

	segment := strings.TrimSpace(out[idx:])
	fields := strings.Fields(segment)
	var values []float64
	for _, field := range fields {
		field = strings.Trim(field, ",;")
		if field == "" {
			continue
		}
		val, err := strconv.ParseFloat(field, 64)
		if err != nil {
			continue
		}
		values = append(values, val)
		if len(values) == 3 {
			break
		}
	}
	if len(values) < 3 {
		return load.AvgStat{}, errors.New("could not parse load averages from uptime output")
	}

	return load.AvgStat{
		Load1:  values[0],
		Load5:  values[1],
		Load15: values[2],
	}, nil
}

func fallbackCPUUtilization(logical int) (float64, []float64, error) {
	if logical <= 0 {
		logical = runtime.NumCPU()
	}
	if logical <= 0 {
		logical = 1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	out, err := runCmd(ctx, "ps", "-Aceo", "pcpu")
	if err != nil {
		return 0, nil, err
	}

	scanner := bufio.NewScanner(strings.NewReader(out))
	total := 0.0
	lineIndex := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		lineIndex++
		if lineIndex == 1 && (strings.Contains(strings.ToLower(line), "cpu") || strings.Contains(line, "%")) {
			continue
		}

		val, parseErr := strconv.ParseFloat(line, 64)
		if parseErr != nil {
			continue
		}
		total += val
	}
	if scanErr := scanner.Err(); scanErr != nil {
		return 0, nil, scanErr
	}

	maxTotal := float64(logical * 100)
	if total < 0 {
		total = 0
	} else if total > maxTotal {
		total = maxTotal
	}

	perCore := make([]float64, logical)
	avg := total / float64(logical)
	for i := range perCore {
		perCore[i] = avg
	}
	return total, perCore, nil
}
