package main

import (
	"fmt"
	"strings"
)

// Health score calculation weights and thresholds
const (
	// Weights (must sum to ~100 for total score)
	healthCPUWeight     = 30.0
	healthMemWeight     = 25.0
	healthDiskWeight    = 20.0
	healthThermalWeight = 15.0
	healthIOWeight      = 10.0

	// CPU thresholds
	cpuNormalThreshold = 30.0
	cpuHighThreshold   = 70.0

	// Memory thresholds
	memNormalThreshold     = 50.0
	memHighThreshold       = 80.0
	memPressureWarnPenalty = 5.0
	memPressureCritPenalty = 15.0

	// Disk thresholds
	diskWarnThreshold = 70.0
	diskCritThreshold = 90.0

	// Thermal thresholds
	thermalNormalThreshold = 60.0
	thermalHighThreshold   = 85.0

	// Disk IO thresholds (MB/s)
	ioNormalThreshold = 50.0
	ioHighThreshold   = 150.0
)

func calculateHealthScore(cpu CPUStatus, mem MemoryStatus, disks []DiskStatus, diskIO DiskIOStatus, thermal ThermalStatus) (int, string) {
	// Start with perfect score
	score := 100.0
	issues := []string{}

	// CPU Usage (30% weight) - deduct up to 30 points
	// 0-30% CPU = 0 deduction, 30-70% = linear, 70-100% = heavy penalty
	cpuPenalty := 0.0
	if cpu.Usage > cpuNormalThreshold {
		if cpu.Usage > cpuHighThreshold {
			cpuPenalty = healthCPUWeight * (cpu.Usage - cpuNormalThreshold) / cpuHighThreshold
		} else {
			cpuPenalty = (healthCPUWeight / 2) * (cpu.Usage - cpuNormalThreshold) / (cpuHighThreshold - cpuNormalThreshold)
		}
	}
	score -= cpuPenalty
	if cpu.Usage > cpuHighThreshold {
		issues = append(issues, "High CPU")
	}

	// Memory Usage (25% weight) - deduct up to 25 points
	// 0-50% = 0 deduction, 50-80% = linear, 80-100% = heavy penalty
	memPenalty := 0.0
	if mem.UsedPercent > memNormalThreshold {
		if mem.UsedPercent > memHighThreshold {
			memPenalty = healthMemWeight * (mem.UsedPercent - memNormalThreshold) / memNormalThreshold
		} else {
			memPenalty = (healthMemWeight / 2) * (mem.UsedPercent - memNormalThreshold) / (memHighThreshold - memNormalThreshold)
		}
	}
	score -= memPenalty
	if mem.UsedPercent > memHighThreshold {
		issues = append(issues, "High Memory")
	}

	// Memory Pressure (extra penalty)
	if mem.Pressure == "warn" {
		score -= memPressureWarnPenalty
		issues = append(issues, "Memory Pressure")
	} else if mem.Pressure == "critical" {
		score -= memPressureCritPenalty
		issues = append(issues, "Critical Memory")
	}

	// Disk Usage (20% weight) - deduct up to 20 points
	diskPenalty := 0.0
	if len(disks) > 0 {
		diskUsage := disks[0].UsedPercent
		if diskUsage > diskWarnThreshold {
			if diskUsage > diskCritThreshold {
				diskPenalty = healthDiskWeight * (diskUsage - diskWarnThreshold) / (100 - diskWarnThreshold)
			} else {
				diskPenalty = (healthDiskWeight / 2) * (diskUsage - diskWarnThreshold) / (diskCritThreshold - diskWarnThreshold)
			}
		}
		score -= diskPenalty
		if diskUsage > diskCritThreshold {
			issues = append(issues, "Disk Almost Full")
		}
	}

	// Thermal (15% weight) - deduct up to 15 points
	thermalPenalty := 0.0
	if thermal.CPUTemp > 0 {
		if thermal.CPUTemp > thermalNormalThreshold {
			if thermal.CPUTemp > thermalHighThreshold {
				thermalPenalty = healthThermalWeight
				issues = append(issues, "Overheating")
			} else {
				thermalPenalty = healthThermalWeight * (thermal.CPUTemp - thermalNormalThreshold) / (thermalHighThreshold - thermalNormalThreshold)
			}
		}
		score -= thermalPenalty
	}

	// Disk IO (10% weight) - deduct up to 10 points
	ioPenalty := 0.0
	totalIO := diskIO.ReadRate + diskIO.WriteRate
	if totalIO > ioNormalThreshold {
		if totalIO > ioHighThreshold {
			ioPenalty = healthIOWeight
			issues = append(issues, "Heavy Disk IO")
		} else {
			ioPenalty = healthIOWeight * (totalIO - ioNormalThreshold) / (ioHighThreshold - ioNormalThreshold)
		}
	}
	score -= ioPenalty

	// Ensure score is in valid range
	if score < 0 {
		score = 0
	}
	if score > 100 {
		score = 100
	}

	// Generate message
	msg := "Excellent"
	if score >= 90 {
		msg = "Excellent"
	} else if score >= 75 {
		msg = "Good"
	} else if score >= 60 {
		msg = "Fair"
	} else if score >= 40 {
		msg = "Poor"
	} else {
		msg = "Critical"
	}

	if len(issues) > 0 {
		msg = msg + ": " + strings.Join(issues, ", ")
	}

	return int(score), msg
}

func formatUptime(secs uint64) string {
	days := secs / 86400
	hours := (secs % 86400) / 3600
	mins := (secs % 3600) / 60
	if days > 0 {
		return fmt.Sprintf("%dd %dh %dm", days, hours, mins)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, mins)
	}
	return fmt.Sprintf("%dm", mins)
}
