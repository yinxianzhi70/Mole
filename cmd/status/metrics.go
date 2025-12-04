package main

import (
	"context"
	"fmt"
	"os/exec"
	"time"

	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/net"
)

type MetricsSnapshot struct {
	CollectedAt    time.Time
	Host           string
	Platform       string
	Uptime         string
	Procs          uint64
	Hardware       HardwareInfo
	HealthScore    int    // 0-100 system health score
	HealthScoreMsg string // Brief explanation

	CPU          CPUStatus
	GPU          []GPUStatus
	Memory       MemoryStatus
	Disks        []DiskStatus
	DiskIO       DiskIOStatus
	Network      []NetworkStatus
	Proxy        ProxyStatus
	Batteries    []BatteryStatus
	Thermal      ThermalStatus
	Sensors      []SensorReading
	Bluetooth    []BluetoothDevice
	TopProcesses []ProcessInfo
}

type HardwareInfo struct {
	Model     string // MacBook Pro 14-inch, 2021
	CPUModel  string // Apple M1 Pro / Intel Core i7
	TotalRAM  string // 16GB
	DiskSize  string // 512GB
	OSVersion string // macOS Sonoma 14.5
}

type DiskIOStatus struct {
	ReadRate  float64 // MB/s
	WriteRate float64 // MB/s
}

type ProcessInfo struct {
	Name   string
	CPU    float64
	Memory float64
}

type CPUStatus struct {
	Usage            float64
	PerCore          []float64
	PerCoreEstimated bool
	Load1            float64
	Load5            float64
	Load15           float64
	CoreCount        int
	LogicalCPU       int
}

type GPUStatus struct {
	Name        string
	Usage       float64
	MemoryUsed  float64
	MemoryTotal float64
	Note        string
}

type MemoryStatus struct {
	Used        uint64
	Total       uint64
	UsedPercent float64
	SwapUsed    uint64
	SwapTotal   uint64
	Pressure    string // macOS memory pressure: normal/warn/critical
}

type DiskStatus struct {
	Mount       string
	Device      string
	Used        uint64
	Total       uint64
	UsedPercent float64
	Fstype      string
	External    bool
}

type NetworkStatus struct {
	Name      string
	RxRateMBs float64
	TxRateMBs float64
	IP        string
}

type ProxyStatus struct {
	Enabled bool
	Type    string // HTTP, SOCKS, System
	Host    string
}

type BatteryStatus struct {
	Percent    float64
	Status     string
	TimeLeft   string
	Health     string
	CycleCount int
}

type ThermalStatus struct {
	CPUTemp  float64
	GPUTemp  float64
	FanSpeed int
	FanCount int
}

type SensorReading struct {
	Label string
	Value float64
	Unit  string
	Note  string
}

type BluetoothDevice struct {
	Name      string
	Connected bool
	Battery   string
}

type Collector struct {
	prevNet    map[string]net.IOCountersStat
	lastNetAt  time.Time
	lastBTAt   time.Time
	lastBT     []BluetoothDevice
	lastGPUAt  time.Time
	cachedGPU  []GPUStatus
	prevDiskIO disk.IOCountersStat
	lastDiskAt time.Time
}

func NewCollector() *Collector {
	return &Collector{
		prevNet: make(map[string]net.IOCountersStat),
	}
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	now := time.Now()
	hostInfo, _ := host.Info()

	cpuStats, cpuErr := collectCPU()
	memStats, memErr := collectMemory()
	diskStats, diskErr := collectDisks()
	hwInfo := collectHardware(memStats.Total, diskStats)
	diskIO := c.collectDiskIO(now)
	netStats, netErr := c.collectNetwork(now)
	proxyStats := collectProxy()
	batteryStats, _ := collectBatteries()
	thermalStats := collectThermal()
	sensorStats, _ := collectSensors()
	gpuStats, gpuErr := c.collectGPU(now)
	btStats := c.collectBluetooth(now)
	topProcs := collectTopProcesses()

	var mergeErr error
	for _, e := range []error{cpuErr, memErr, diskErr, netErr, gpuErr} {
		if e != nil {
			if mergeErr == nil {
				mergeErr = e
			} else {
				mergeErr = fmt.Errorf("%v; %w", mergeErr, e)
			}
		}
	}

	// Calculate health score
	score, scoreMsg := calculateHealthScore(cpuStats, memStats, diskStats, diskIO, thermalStats)

	return MetricsSnapshot{
		CollectedAt:    now,
		Host:           hostInfo.Hostname,
		Platform:       fmt.Sprintf("%s %s", hostInfo.Platform, hostInfo.PlatformVersion),
		Uptime:         formatUptime(hostInfo.Uptime),
		Procs:          hostInfo.Procs,
		Hardware:       hwInfo,
		HealthScore:    score,
		HealthScoreMsg: scoreMsg,
		CPU:            cpuStats,
		GPU:            gpuStats,
		Memory:         memStats,
		Disks:          diskStats,
		DiskIO:         diskIO,
		Network:        netStats,
		Proxy:          proxyStats,
		Batteries:      batteryStats,
		Thermal:        thermalStats,
		Sensors:        sensorStats,
		Bluetooth:      btStats,
		TopProcesses:   topProcs,
	}, mergeErr
}

// Utility functions

func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

func commandExists(name string) bool {
	if name == "" {
		return false
	}
	defer func() {
		if r := recover(); r != nil {
			// If LookPath panics due to permissions or platform quirks, act as if the command is missing.
		}
	}()
	_, err := exec.LookPath(name)
	return err == nil
}

// humanBytes is defined in view.go to avoid duplication
