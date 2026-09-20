package ssebench

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const Profile = "fc-sse-v1-256b-50ms-8s"
const Samples = 161
const FrameBytes = 256
const MaxConcurrency = 512
const Budget = 19 * time.Second

type Result struct {
	Key        string  `json:"key"`
	Name       string  `json:"name"`
	Profiles   []int64 `json:"profiles"`
	Status     string  `json:"status"`
	Error      string  `json:"error,omitempty"`
	Tokens     int     `json:"tokens"`
	TokPerSec  float64 `json:"tokPerSec"`
	FirstMs    float64 `json:"firstMs"`
	JitterMs   float64 `json:"jitterMs"`
	MaxGapMs   float64 `json:"maxGapMs"`
	BurstRatio float64 `json:"burstRatio"`
	ElapsedMs  float64 `json:"elapsedMs"`
	Location   string  `json:"location,omitempty"`
	FlowPass   bool    `json:"flowPass"`
}

type Doer interface {
	Do(*http.Request) (*http.Response, error)
}
type sample struct {
	Seq         int     `json:"seq"`
	SentMs      float64 `json:"sentMs"`
	ScheduledMs float64 `json:"scheduledMs"`
}
type arrival struct {
	sample
	at float64
}

func Probe(ctx context.Context, client Doer, endpoint string) Result {
	start := time.Now()
	fail := func(status, reason string) Result {
		return Result{Status: status, Error: reason, ElapsedMs: float64(time.Since(start).Microseconds()) / 1000}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return fail("endpoint", "invalid test URL")
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return fail("timeout", "batch deadline reached")
		}
		return fail("failed", "connection or TLS failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fail("endpoint", fmt.Sprintf("test source HTTP %d", resp.StatusCode))
	}
	if !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") || resp.Header.Get("X-Stream-Quality-Profile") != Profile {
		return fail("endpoint", "incompatible SSE source")
	}
	if enc := resp.Header.Get("Content-Encoding"); enc != "" && enc != "identity" {
		return fail("endpoint", "compressed stream rejected")
	}
	reader := bufio.NewReaderSize(io.LimitReader(resp.Body, Samples*FrameBytes+4096), 4096)
	events := make([]arrival, 0, Samples)
	for {
		var block strings.Builder
		for {
			line, e := reader.ReadString('\n')
			block.WriteString(line)
			if block.Len() > 4096 {
				return fail("measurement", "oversized SSE frame")
			}
			if e != nil {
				if ctx.Err() != nil {
					return fail("timeout", "batch deadline reached")
				}
				return fail("failed", "truncated SSE stream")
			}
			if line == "\n" {
				break
			}
		}
		at := float64(time.Since(start).Microseconds()) / 1000
		text := block.String()
		lines := strings.Split(strings.TrimSuffix(text, "\n\n"), "\n")
		if len(lines) != 2 || !strings.HasPrefix(lines[1], "data: ") {
			return fail("measurement", "invalid SSE frame")
		}
		data := strings.TrimPrefix(lines[1], "data: ")
		switch lines[0] {
		case "event: sample":
			var s sample
			if json.Unmarshal([]byte(data), &s) != nil || len(events) >= Samples || len(text) != FrameBytes || s.Seq != len(events) || s.ScheduledMs != float64(s.Seq*50) || math.IsNaN(s.SentMs) || math.IsInf(s.SentMs, 0) || s.SentMs < 0 || (len(events) > 0 && s.SentMs < events[len(events)-1].SentMs) {
				return fail("measurement", "invalid sequence, timing or frame size")
			}
			if math.Abs(s.SentMs-s.ScheduledMs) > 250 {
				return fail("endpoint", "source missed its schedule")
			}
			events = append(events, arrival{s, at})
		case "event: end":
			var end struct {
				Profile string `json:"profile"`
				Samples int    `json:"samples"`
			}
			if json.Unmarshal([]byte(data), &end) != nil || end.Profile != Profile || end.Samples != Samples || len(events) != Samples {
				return fail("measurement", "incomplete SSE terminal")
			}
			extra, queues := make([]float64, 0, Samples-1), make([]float64, 0, Samples)
			bursts := 0
			first := events[0]
			for i, e := range events {
				queues = append(queues, (e.at-first.at)-(e.SentMs-first.SentMs))
				if i > 0 {
					prev := events[i-1]
					received, sent := e.at-prev.at, e.SentMs-prev.SentMs
					extra = append(extra, math.Max(0, received-sent))
					if received < 5 && sent >= 25 {
						bursts++
					}
				}
			}
			sort.Float64s(extra)
			sort.Float64s(queues)
			jitter := percentile(queues, .95) - percentile(queues, .05)
			gap := extra[len(extra)-1]
			burst := float64(bursts) / float64(Samples-1)
			return Result{Status: "done", Tokens: Samples, TokPerSec: float64(Samples) * 1000 / math.Max(at, 1), FirstMs: first.at, JitterMs: jitter, MaxGapMs: gap, BurstRatio: burst, ElapsedMs: at, Location: resp.Header.Get("X-Stream-Quality-Location"), FlowPass: jitter <= 100 && gap <= 500 && burst <= .1}
		default:
			return fail("measurement", "unknown SSE event")
		}
	}
}

func percentile(sorted []float64, q float64) float64 {
	return sorted[int(math.Ceil(q*float64(len(sorted))))-1]
}

type Job struct {
	Base  Result
	Probe func(context.Context) Result
}

func Run(ctx context.Context, jobs []Job, concurrency int) []Result {
	if concurrency < 1 {
		concurrency = 1
	}
	if concurrency > MaxConcurrency {
		concurrency = MaxConcurrency
	}
	results := make([]Result, len(jobs))
	tasks := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < concurrency && w < len(jobs); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range tasks {
				value := Result{Status: "unmeasured", Error: "batch deadline reached before start"}
				if ctx.Err() == nil {
					value = jobs[i].Probe(ctx)
				}
				value.Key = jobs[i].Base.Key
				value.Name = jobs[i].Base.Name
				value.Profiles = jobs[i].Base.Profiles
				results[i] = value
			}
		}()
	}
	ramp := time.NewTicker(time.Millisecond)
	defer ramp.Stop()
	for i := range jobs {
		if ctx.Err() == nil {
			select {
			case <-ramp.C:
			case <-ctx.Done():
			}
		}
		tasks <- i
	}
	close(tasks)
	wg.Wait()
	return results
}
