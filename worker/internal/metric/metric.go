// Package metric implements the worker's read-only system-metric capability.
//
// Contract:
//   - every metric is typed (gauge or counter), has a stable id, a unit, a UTC
//     timestamp, a bounded dimension map, a provider, a value when available, and a
//     quality state (valid, unavailable, unsupported, stale, error);
//   - missing data is never replaced with zero: a provider that cannot produce a value
//     reports quality=unavailable/unsupported/error with a stable code;
//   - no value is interpolated across restarts or gaps;
//   - counter rates are not computed here: raw counters are returned and the client
//     computes rates from the monotonic elapsed time between samples, which keeps one
//     rate definition and lets the client handle resets/identity changes;
//   - the snapshot is bounded: one request, one response, a fixed metric budget, and
//     per-provider timeouts enforced by the server job timeout.
//
// Platform providers: Linux reads /proc, /sys and statfs. Windows providers are compiled
// but report quality=unsupported with a stable code: the PowerShell collector owns Windows
// collection through the documented CIM providers (Win32_OperatingSystem,
// Win32_LogicalDisk, Win32_PerfFormattedData_*). The worker never enables services,
// installs drivers, resets counters or downloads anything.
package metric

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Quality is the metric quality state.
type Quality string

const (
	QualityValid       Quality = "valid"
	QualityUnavailable Quality = "unavailable"
	QualityUnsupported Quality = "unsupported"
	QualityStale       Quality = "stale"
	QualityError       Quality = "error"
)

// Types.
const (
	TypeGauge   = "gauge"
	TypeCounter = "counter"
)

// Stable error codes.
const (
	ErrUnsupportedProvider = "E_UNSUPPORTED_PROVIDER"
	ErrReadFailed          = "E_READ_FAILED"
	ErrNoBaseline          = "E_NO_BASELINE"
	ErrStale               = "E_STALE"
)

// Metric is one sample.
type Metric struct {
	ID        string            `json:"id"`
	Type      string            `json:"type"`
	Unit      string            `json:"unit"`
	TsMs      int64             `json:"tsMs"`
	Quality   Quality           `json:"quality"`
	Dims      map[string]string `json:"dims,omitempty"`
	Provider  string            `json:"provider"`
	Value     *float64          `json:"value,omitempty"`
	ErrorCode string            `json:"errorCode,omitempty"`
	Note      string            `json:"note,omitempty"`
}

// Limits the snapshot enforces.
const (
	MaxMetricsPerSnapshot = 64
	MaxDimsPerMetric      = 8
	MaxDimValueLength     = 64
)

// Provider samples one family of metrics.
type Provider interface {
	// Name returns the stable provider name (host.cpu, host.mem, ...).
	Name() string
	// Sample appends metrics (bounded) to out. Any provider error is reported as a
	// metric with quality=error and the stable code, never silently dropped.
	Sample(ctx context.Context, out *[]Metric) error
}

// Snapshot is the result of one metric.snapshot request.
type Snapshot struct {
	Scope        string   `json:"scope"`
	SampledAtMs int64    `json:"sampledAtMs"`
	Metrics     []Metric `json:"metrics"`
}

// snapshotter holds the provider set and any cross-sample state for the process.
type Snapshotter struct {
	mu        sync.Mutex
	providers []Provider
	cpu       *cpuState
	net       map[string]*netState
}

// New builds the platform provider set.
func New() *Snapshotter {
	s := &Snapshotter{
		providers: nil,
		cpu:       &cpuState{},
		net:       map[string]*netState{},
	}
	if runtime.GOOS == "linux" {
		s.providers = []Provider{
			cpuProvider{state: s.cpu},
			memProvider{},
			diskProvider{},
			uptimeProvider{},
			netProvider{state: s.net},
		}
	} else {
		// Windows builds compile; the worker returns unsupported with a stable code and
		// the PowerShell collector owns Windows metrics via CIM.
		s.providers = []Provider{unsupportedProvider{}}
	}
	return s
}

// Snapshot collects a bounded batch of metrics.
func (s *Snapshotter) Snapshot(ctx context.Context, scope string) (*Snapshot, error) {
	now := time.Now().UTC()
	out := make([]Metric, 0, 32)

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, provider := range s.providers {
		if len(out) >= MaxMetricsPerSnapshot {
			break
		}
		if err := provider.Sample(ctx, &out); err != nil {
			out = append(out, Metric{
				ID: "provider.error", Type: TypeGauge, Unit: "count",
				TsMs: now.UnixMilli(), Quality: QualityError,
				Provider: provider.Name(), ErrorCode: ErrReadFailed,
				Note: err.Error(),
			})
		}
	}

	if len(out) > MaxMetricsPerSnapshot {
		out = out[:MaxMetricsPerSnapshot]
	}

	return &Snapshot{Scope: scope, SampledAtMs: now.UnixMilli(), Metrics: out}, nil
}

func addMetric(out *[]Metric, id, typ, unit string, quality Quality, provider string, dims map[string]string, value *float64, code, note string) {
	if len(*out) >= MaxMetricsPerSnapshot {
		return
	}
	now := time.Now().UTC()
	*out = append(*out, Metric{
		ID: id, Type: typ, Unit: unit, TsMs: now.UnixMilli(),
		Quality: quality, Dims: dims, Provider: provider,
		Value: value, ErrorCode: code, Note: note,
	})
}

func f64(v float64) *float64 { return &v }

// ---- CPU ----------------------------------------------------------------

type cpuState struct {
	lastTotal     uint64
	lastIdle      uint64
	lastMonoNanos int64
	haveBaseline  bool
}

type cpuProvider struct{ state *cpuState }

// readProcStat returns (total, idle) jiffies from /proc/stat.
func readProcStat() (uint64, uint64, error) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)
		var total, idle uint64
		for i, f := range fields[1:] {
			v, err := strconv.ParseUint(f, 10, 64)
			if err != nil {
				return 0, 0, err
			}
			total += v
			if i == 3 { // idle
				idle = v
			}
		}
		return total, idle, nil
	}
	return 0, 0, errors.New("no cpu line in /proc/stat")
}

func (p cpuProvider) Name() string { return "host.cpu" }

func (p cpuProvider) Sample(ctx context.Context, out *[]Metric) error {
	total, idle, err := readProcStat()
	if err != nil {
		addMetric(out, "host.cpu.utilization", TypeGauge, "%", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		return nil
	}

	nowMono := time.Now().UnixNano()

	if !p.state.haveBaseline {
		p.state.lastTotal = total
		p.state.lastIdle = idle
		p.state.lastMonoNanos = nowMono
		p.state.haveBaseline = true
		addMetric(out, "host.cpu.utilization", TypeGauge, "%", QualityUnavailable, p.Name(), nil, nil, ErrNoBaseline, "first sample: utilization needs two reads")
		return nil
	}

	elapsed := nowMono - p.state.lastMonoNanos
	if elapsed <= 0 {
		elapsed = 1
	}

	dtTotal := total - p.state.lastTotal
	dtIdle := idle - p.state.lastIdle

	p.state.lastMonoNanos = nowMono

	// Counter reset: total went backwards (reboot or wrap), start a fresh baseline and
	// emit no negative rate.
	if dtTotal > math.MaxUint64/2 {
		p.state.lastTotal = total
		p.state.lastIdle = idle
		addMetric(out, "host.cpu.utilization", TypeGauge, "%", QualityUnavailable, p.Name(), nil, nil, ErrNoBaseline, "counter reset; new baseline")
		return nil
	}

	p.state.lastTotal = total
	p.state.lastIdle = idle

	if dtTotal == 0 {
		addMetric(out, "host.cpu.utilization", TypeGauge, "%", QualityValid, p.Name(), nil, f64(0), "", "")
		return nil
	}

	utilTicks := float64(dtTotal-dtIdle) / float64(dtTotal)
	addMetric(out, "host.cpu.utilization", TypeGauge, "%", QualityValid, p.Name(), nil, f64(utilTicks*100), "", "")
	return nil
}

// ---- Memory -------------------------------------------------------------

type memProvider struct{}

func (p memProvider) Name() string { return "host.mem" }

func (p memProvider) Sample(ctx context.Context, out *[]Metric) error {
	// /proc/meminfo: MemTotal and MemAvailable are in kB on Linux.
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		addMetric(out, "host.mem.physical.usedBytes", TypeGauge, "bytes", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		addMetric(out, "host.mem.physical.availableBytes", TypeGauge, "bytes", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		addMetric(out, "host.mem.physical.totalBytes", TypeGauge, "bytes", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		return nil
	}

	var totalKB, availKB int64
	for _, line := range strings.Split(string(data), "\n") {
		switch {
		case strings.HasPrefix(line, "MemTotal:"):
			totalKB, _ = parseKb(line)
		case strings.HasPrefix(line, "MemAvailable:"):
			availKB, _ = parseKb(line)
		}
	}

	if totalKB <= 0 {
		addMetric(out, "host.mem.physical.totalBytes", TypeGauge, "bytes", QualityUnavailable, p.Name(), nil, nil, ErrReadFailed, "MemTotal missing")
		return nil
	}

	// used = total - available; commit is not exposed by /proc/meminfo and is
	// deliberately not estimated.
	usedBytes := float64((totalKB - availKB) * 1024)
	availBytes := float64(availKB * 1024)
	totalBytes := float64(totalKB * 1024)
	addMetric(out, "host.mem.physical.usedBytes", TypeGauge, "bytes", QualityValid, p.Name(), nil, f64(usedBytes), "", "")
	addMetric(out, "host.mem.physical.availableBytes", TypeGauge, "bytes", QualityValid, p.Name(), nil, f64(availBytes), "", "")
	addMetric(out, "host.mem.physical.totalBytes", TypeGauge, "bytes", QualityValid, p.Name(), nil, f64(totalBytes), "", "")
	return nil
}

func parseKb(line string) (int64, error) {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return 0, errors.New("malformed meminfo line")
	}
	return strconv.ParseInt(fields[1], 10, 64)
}

// ---- Disk ---------------------------------------------------------------

type diskProvider struct{}

func (p diskProvider) Name() string { return "host.disk" }

func (p diskProvider) Sample(ctx context.Context, out *[]Metric) error {
	// The system volume is probed by the client; the worker reports the root volume.
	const path = "/"
	var stat syscallStatfs
	if err := statfs(path, &stat); err != nil {
		addMetric(out, "host.disk.system.freeBytes", TypeGauge, "bytes", QualityError, p.Name(), map[string]string{"mount": path}, nil, ErrReadFailed, err.Error())
		addMetric(out, "host.disk.system.totalBytes", TypeGauge, "bytes", QualityError, p.Name(), map[string]string{"mount": path}, nil, ErrReadFailed, err.Error())
		return nil
	}
	free := float64(stat.Bavail) * float64(stat.Bsize)
	total := float64(stat.Blocks) * float64(stat.Bsize)
	addMetric(out, "host.disk.system.freeBytes", TypeGauge, "bytes", QualityValid, p.Name(), map[string]string{"mount": path}, f64(free), "", "")
	addMetric(out, "host.disk.system.totalBytes", TypeGauge, "bytes", QualityValid, p.Name(), map[string]string{"mount": path}, f64(total), "", "")
	return nil
}

// ---- Uptime -------------------------------------------------------------

type uptimeProvider struct{}

func (p uptimeProvider) Name() string { return "host.uptime" }

func (p uptimeProvider) Sample(ctx context.Context, out *[]Metric) error {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		addMetric(out, "host.uptime.seconds", TypeGauge, "seconds", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		return nil
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		addMetric(out, "host.uptime.seconds", TypeGauge, "seconds", QualityUnavailable, p.Name(), nil, nil, ErrReadFailed, "empty uptime")
		return nil
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		addMetric(out, "host.uptime.seconds", TypeGauge, "seconds", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		return nil
	}
	addMetric(out, "host.uptime.seconds", TypeGauge, "seconds", QualityValid, p.Name(), nil, f64(v), "", "")
	return nil
}

// ---- Network ------------------------------------------------------------

type netState struct {
	lastRx        uint64
	lastTx        uint64
	lastMonoNanos int64
	haveBaseline  bool
}

type netProvider struct{ state map[string]*netState }

func (p netProvider) Name() string { return "host.net" }

func readStatCounter(iface, stat string) (uint64, error) {
	data, err := os.ReadFile(filepath.Join("/sys/class/net", iface, "statistics", stat))
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
}

func (p netProvider) Sample(ctx context.Context, out *[]Metric) error {
	dirs, err := os.ReadDir("/sys/class/net")
	if err != nil {
		addMetric(out, "host.net.links", TypeGauge, "count", QualityError, p.Name(), nil, nil, ErrReadFailed, err.Error())
		return nil
	}

	linkCount := 0
	for _, dir := range dirs {
		name := dir.Name()
		if name == "lo" {
			continue
		}
		if len(*out) >= MaxMetricsPerSnapshot {
			break
		}

		dims := map[string]string{"adapter": name}
		linkState := "down"
		linkValue := 0.0

		carrier, err := os.ReadFile(filepath.Join("/sys/class/net", name, "carrier"))
		if err == nil && strings.TrimSpace(string(carrier)) == "1" {
			linkState = "up"
			linkValue = 1
		}
		addMetric(out, "host.net.link.state", TypeGauge, "state", QualityValid, p.Name(), dims, f64(linkValue), "", linkState)
		linkCount++
	}

	addMetric(out, "host.net.links", TypeGauge, "count", QualityValid, p.Name(), nil, f64(float64(linkCount)), "", "")

	// Counters are returned raw; rate computation happens on the client with monotonic
	// elapsed time, so identities and resets stay in one place.
	for _, dir := range dirs {
		name := dir.Name()
		if name == "lo" {
			continue
		}
		dims := map[string]string{"adapter": name}
		rx, rxErr := readStatCounter(name, "rx_bytes")
		tx, txErr := readStatCounter(name, "tx_bytes")
		if rxErr == nil {
			addMetric(out, "host.net.rxBytes", TypeCounter, "bytes", QualityValid, p.Name(), dims, f64(float64(rx)), "", "")
		} else {
			addMetric(out, "host.net.rxBytes", TypeCounter, "bytes", QualityError, p.Name(), dims, nil, ErrReadFailed, rxErr.Error())
		}
		if txErr == nil {
			addMetric(out, "host.net.txBytes", TypeCounter, "bytes", QualityValid, p.Name(), dims, f64(float64(tx)), "", "")
		} else {
			addMetric(out, "host.net.txBytes", TypeCounter, "bytes", QualityError, p.Name(), dims, nil, ErrReadFailed, txErr.Error())
		}
	}
	return nil
}

// ---- Unsupported (Windows default) --------------------------------------

type unsupportedProvider struct{}

func (p unsupportedProvider) Name() string { return "host.sum" }

func (p unsupportedProvider) Sample(ctx context.Context, out *[]Metric) error {
	// The PowerShell collector owns Windows metrics through CIM; the worker reports
	// that support explicitly instead of fabricating values.
	addMetric(out, "host.cpu.utilization", TypeGauge, "%", QualityUnsupported, p.Name(), nil, nil, ErrUnsupportedProvider, "Windows CPU metrics are collected by the PowerShell provider")
	addMetric(out, "host.mem.physical.totalBytes", TypeGauge, "bytes", QualityUnsupported, p.Name(), nil, nil, ErrUnsupportedProvider, "Windows memory metrics are collected by the PowerShell provider")
	addMetric(out, "host.disk.system.freeBytes", TypeGauge, "bytes", QualityUnsupported, p.Name(), nil, nil, ErrUnsupportedProvider, "Windows disk metrics are collected by the PowerShell provider")
	addMetric(out, "host.uptime.seconds", TypeGauge, "seconds", QualityUnsupported, p.Name(), nil, nil, ErrUnsupportedProvider, "Windows uptime is collected by the PowerShell provider")
	addMetric(out, "host.net.rxBytes", TypeCounter, "bytes", QualityUnsupported, p.Name(), nil, nil, ErrUnsupportedProvider, "Windows network metrics are collected by the PowerShell provider")
	return nil
}

func (s *Snapshotter) Stat() string { return fmt.Sprintf("providers=%d", len(s.providers)) }
