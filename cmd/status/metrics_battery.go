package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/host"
)

func collectBatteries() (batts []BatteryStatus, err error) {
	defer func() {
		if r := recover(); r != nil {
			// Swallow panics from platform-specific battery probes to keep the UI alive.
			err = fmt.Errorf("battery collection failed: %v", r)
		}
	}()

	// macOS: pmset
	if runtime.GOOS == "darwin" && commandExists("pmset") {
		if out, err := runCmd(context.Background(), "pmset", "-g", "batt"); err == nil {
			if batts := parsePMSet(out); len(batts) > 0 {
				return batts, nil
			}
		}
	}

	// Linux: /sys/class/power_supply
	matches, _ := filepath.Glob("/sys/class/power_supply/BAT*/capacity")
	for _, capFile := range matches {
		statusFile := filepath.Join(filepath.Dir(capFile), "status")
		capData, err := os.ReadFile(capFile)
		if err != nil {
			continue
		}
		statusData, _ := os.ReadFile(statusFile)
		percentStr := strings.TrimSpace(string(capData))
		percent, _ := strconv.ParseFloat(percentStr, 64)
		status := strings.TrimSpace(string(statusData))
		if status == "" {
			status = "Unknown"
		}
		batts = append(batts, BatteryStatus{
			Percent: percent,
			Status:  status,
		})
	}
	if len(batts) > 0 {
		return batts, nil
	}

	return nil, errors.New("no battery data found")
}

func parsePMSet(raw string) []BatteryStatus {
	lines := strings.Split(raw, "\n")
	var out []BatteryStatus
	var timeLeft string

	for _, line := range lines {
		// Check for time remaining
		if strings.Contains(line, "remaining") {
			// Extract time like "1:30 remaining"
			parts := strings.Fields(line)
			for i, p := range parts {
				if p == "remaining" && i > 0 {
					timeLeft = parts[i-1]
				}
			}
		}

		if !strings.Contains(line, "%") {
			continue
		}
		fields := strings.Fields(line)
		var (
			percent float64
			found   bool
			status  = "Unknown"
		)
		for i, f := range fields {
			if strings.Contains(f, "%") {
				value := strings.TrimSuffix(strings.TrimSuffix(f, ";"), "%")
				if p, err := strconv.ParseFloat(value, 64); err == nil {
					percent = p
					found = true
					if i+1 < len(fields) {
						status = strings.TrimSuffix(fields[i+1], ";")
					}
				}
				break
			}
		}
		if !found {
			continue
		}

		// Get battery health and cycle count
		health, cycles := getBatteryHealth()

		out = append(out, BatteryStatus{
			Percent:    percent,
			Status:     status,
			TimeLeft:   timeLeft,
			Health:     health,
			CycleCount: cycles,
		})
	}
	return out
}

func getBatteryHealth() (string, int) {
	if runtime.GOOS != "darwin" {
		return "", 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType")
	if err != nil {
		return "", 0
	}

	var health string
	var cycles int

	lines := strings.Split(out, "\n")
	for _, line := range lines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "cycle count") {
			parts := strings.Split(line, ":")
			if len(parts) == 2 {
				cycles, _ = strconv.Atoi(strings.TrimSpace(parts[1]))
			}
		}
		if strings.Contains(lower, "condition") {
			parts := strings.Split(line, ":")
			if len(parts) == 2 {
				health = strings.TrimSpace(parts[1])
			}
		}
	}
	return health, cycles
}

func collectThermal() ThermalStatus {
	if runtime.GOOS != "darwin" {
		return ThermalStatus{}
	}

	var thermal ThermalStatus

	// Get fan info from system_profiler
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType")
	if err == nil {
		lines := strings.Split(out, "\n")
		for _, line := range lines {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "fan") && strings.Contains(lower, "speed") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					// Extract number from string like "1200 RPM"
					numStr := strings.TrimSpace(parts[1])
					numStr = strings.Split(numStr, " ")[0]
					thermal.FanSpeed, _ = strconv.Atoi(numStr)
				}
			}
		}
	}

	// Try to get CPU temperature using sudo powermetrics (may not work without sudo)
	// Fallback: use SMC reader or estimate from thermal pressure
	ctx2, cancel2 := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel2()

	// Try thermal level as a proxy
	out2, err := runCmd(ctx2, "sysctl", "-n", "machdep.xcpm.cpu_thermal_level")
	if err == nil {
		level, _ := strconv.Atoi(strings.TrimSpace(out2))
		// Estimate temp: level 0-100 roughly maps to 40-100°C
		if level >= 0 {
			thermal.CPUTemp = 45 + float64(level)*0.5
		}
	}

	return thermal
}

func collectSensors() ([]SensorReading, error) {
	temps, err := host.SensorsTemperatures()
	if err != nil {
		return nil, err
	}
	var out []SensorReading
	for _, t := range temps {
		if t.Temperature <= 0 || t.Temperature > 150 {
			continue
		}
		out = append(out, SensorReading{
			Label: prettifyLabel(t.SensorKey),
			Value: t.Temperature,
			Unit:  "°C",
		})
	}
	return out, nil
}

func prettifyLabel(key string) string {
	key = strings.TrimSpace(key)
	key = strings.TrimPrefix(key, "TC")
	key = strings.ReplaceAll(key, "_", " ")
	return key
}
