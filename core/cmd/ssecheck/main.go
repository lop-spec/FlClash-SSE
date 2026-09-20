// ssecheck validates the public synthetic source without calling a model.
package main

import (
	"context"
	"core/ssebench"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"
)

func main() {
	endpoint := flag.String("endpoint", "https://flclash-sse.1781297309.workers.dev/api/stream", "synthetic SSE endpoint")
	count := flag.Int("count", 4, "number of concurrent validation streams")
	flag.Parse()
	if *count < 1 || *count > 1024 {
		panic("count must be 1..1024")
	}
	ctx, cancel := context.WithTimeout(context.Background(), ssebench.Budget)
	defer cancel()
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, DisableCompression: true, MaxIdleConnsPerHost: 512, MaxConnsPerHost: 512}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	jobs := make([]ssebench.Job, *count)
	for i := range jobs {
		jobs[i] = ssebench.Job{Base: ssebench.Result{Key: fmt.Sprint(i)}, Probe: func(ctx context.Context) ssebench.Result { return ssebench.Probe(ctx, client, *endpoint) }}
	}
	start := time.Now()
	results := ssebench.Run(ctx, jobs, ssebench.MaxConcurrency)
	statuses := map[string]int{}
	errors := map[string]int{}
	complete, flowPass := 0, 0
	low, high := 1e9, 0.0
	for _, r := range results {
		statuses[r.Status]++
		if r.Error != "" {
			errors[r.Error]++
		}
		if r.Status == "done" {
			complete++
			if r.TokPerSec < low {
				low = r.TokPerSec
			}
			if r.TokPerSec > high {
				high = r.TokPerSec
			}
		}
		if r.FlowPass {
			flowPass++
		}
	}
	elapsed := time.Since(start)
	json.NewEncoder(os.Stdout).Encode(map[string]any{"nodes": *count, "complete": complete, "flowPass": flowPass, "elapsedMs": elapsed.Milliseconds(), "statuses": statuses, "errors": errors, "minTokPerSec": low, "maxTokPerSec": high})
	if complete != *count || elapsed >= 20*time.Second {
		os.Exit(1)
	}
}
