package ssebench

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testFrame(i int, sent float64) string {
	data := map[string]any{"seq": i, "sentMs": sent, "scheduledMs": i * 50, "pad": ""}
	b, _ := json.Marshal(data)
	data["pad"] = strings.Repeat("x", FrameBytes-len("event: sample\ndata: \n\n")-len(b))
	b, _ = json.Marshal(data)
	return "event: sample\ndata: " + string(b) + "\n\n"
}
func terminal() string {
	return fmt.Sprintf("event: end\ndata: {\"profile\":%q,\"samples\":%d}\n\n", Profile, Samples)
}

type doerFunc func(*http.Request) (*http.Response, error)

func (f doerFunc) Do(r *http.Request) (*http.Response, error) { return f(r) }
func fake(body string) Doer {
	return doerFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" {
			panic("must read GET body")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/event-stream"}, "X-Stream-Quality-Profile": {Profile}}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})
}
func TestProtocolRejectsTruncationAndSourceFailure(t *testing.T) {
	var good strings.Builder
	for i := 0; i < Samples; i++ {
		good.WriteString(testFrame(i, float64(i*50)))
	}
	cases := map[string]string{"truncated": good.String(), "sequence": testFrame(1, 50), "source": testFrame(0, 300), "oversized": strings.Repeat("x", 4100) + "\n\n", "wrong-terminal": good.String() + "event: end\ndata: {}\n\n"}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			r := Probe(context.Background(), fake(body), "https://test.invalid")
			if r.Status == "done" || r.TokPerSec != 0 {
				t.Fatalf("accepted invalid stream: %+v", r)
			}
		})
	}
	r := Probe(context.Background(), fake(good.String()+terminal()), "https://test.invalid")
	if r.Status != "done" || r.Tokens != Samples || r.FlowPass {
		t.Fatalf("buffered stream must be complete but fail cadence: %+v", r)
	}
}
func TestDeadlineCoversQueuedAndActiveNodes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	jobs := make([]Job, 1200)
	var active, peak atomic.Int32
	for i := range jobs {
		jobs[i] = Job{Base: Result{Key: fmt.Sprint(i)}, Probe: func(ctx context.Context) Result {
			a := active.Add(1)
			defer active.Add(-1)
			for p := peak.Load(); a > p && !peak.CompareAndSwap(p, a); p = peak.Load() {
			}
			<-ctx.Done()
			return Result{Status: "timeout"}
		}}
	}
	start := time.Now()
	rs := Run(ctx, jobs, 32)
	if time.Since(start) > time.Second || len(rs) != 1200 || peak.Load() > 32 || active.Load() != 0 {
		t.Fatal("deadline/concurrency/cleanup violated")
	}
	waiting := 0
	for i, r := range rs {
		if r.Key != fmt.Sprint(i) || r.Status == "done" {
			t.Fatal("lost or false-success node")
		}
		if r.Status == "unmeasured" {
			waiting++
		}
	}
	if waiting == 0 {
		t.Fatal("queued requests must explicitly report unmeasured")
	}
}
func Test1024RealStreamsWithin20Seconds(t *testing.T) {
	if testing.Short() {
		t.Skip("8-second real SSE, two parallel waves")
	}
	var connections atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connections.Add(1)
		defer connections.Add(-1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Stream-Quality-Profile", Profile)
		start := time.Now()
		for i := 0; i < Samples; i++ {
			wait := time.NewTimer(time.Until(start.Add(time.Duration(i) * 50 * time.Millisecond)))
			select {
			case <-r.Context().Done():
				wait.Stop()
				return
			case <-wait.C:
			}
			fmt.Fprint(w, testFrame(i, float64(time.Since(start).Microseconds())/1000))
			w.(http.Flusher).Flush()
		}
		fmt.Fprint(w, terminal())
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), Budget)
	defer cancel()
	transport := &http.Transport{MaxConnsPerHost: MaxConcurrency, MaxIdleConnsPerHost: MaxConcurrency}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{Transport: transport}
	var reported atomic.Bool
	client := doerFunc(func(r *http.Request) (*http.Response, error) {
		response, err := httpClient.Do(r)
		if err != nil && reported.CompareAndSwap(false, true) {
			t.Logf("first transport error: %v", err)
		}
		return response, err
	})
	jobs := make([]Job, 1024)
	for i := range jobs {
		jobs[i] = Job{Base: Result{Key: fmt.Sprint(i)}, Probe: func(ctx context.Context) Result { return Probe(ctx, client, server.URL) }}
	}
	start := time.Now()
	results := Run(ctx, jobs, MaxConcurrency)
	elapsed := time.Since(start)
	success := 0
	for _, r := range results {
		if r.Status == "done" {
			success++
		} else {
			if success == 0 {
				t.Logf("stream failed: %s %s", r.Status, r.Error)
			}
		}
	}
	t.Logf("1024 nodes, peak limit %d, complete %d, elapsed %s", MaxConcurrency, success, elapsed)
	if len(results) != 1024 || success != 1024 || elapsed >= 20*time.Second {
		t.Fatal("all-node 20-second acceptance failed")
	}
}
