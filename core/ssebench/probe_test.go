package ssebench

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type origin struct {
	server      *httptest.Server
	connections atomic.Int32
	requests    atomic.Int32
}

func newOrigin(t *testing.T, handler func(n int32, w http.ResponseWriter)) *origin {
	o := &origin{}
	o.server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Errorf("probe must use HTTP/2, got %s", r.Proto)
		}
		handler(o.requests.Add(1), w)
	}))
	o.server.EnableHTTP2 = true
	o.server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			o.connections.Add(1)
		}
	}
	o.server.StartTLS()
	t.Cleanup(o.server.Close)
	return o
}

func unauthorized(delay func(n int32) time.Duration) func(int32, http.ResponseWriter) {
	return func(n int32, w http.ResponseWriter) {
		time.Sleep(delay(n))
		w.Header().Set("Cf-Ray", fmt.Sprintf("%x-NRT", n))
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprint(w, `{"detail":"Unauthorized"}`)
	}
}

func fixed(d time.Duration) func(int32) time.Duration { return func(int32) time.Duration { return d } }

// The httptest certificate is issued for example.com, so both targets use that
// name and the dialer routes by port.
func targets(chatgpt, claude *origin, trusted bool) (Dialer, Targets) {
	addresses := map[string]string{"1001": chatgpt.server.Listener.Addr().String(), "1002": claude.server.Listener.Addr().String()}
	var dialer net.Dialer
	dial := func(ctx context.Context, address string) (net.Conn, error) {
		_, port, _ := net.SplitHostPort(address)
		return dialer.DialContext(ctx, "tcp", addresses[port])
	}
	t := Targets{ChatGPT: "https://example.com:1001/backend-api/codex/models", Claude: "https://example.com:1002/v1/models"}
	if trusted {
		t.TLS = &tls.Config{RootCAs: chatgpt.server.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs}
		t.TLS.RootCAs.AddCert(claude.server.Certificate())
	}
	return dial, t
}

func TestScreenMeasuresSequentialWarmRequestsAndKeepsTheConnection(t *testing.T) {
	chatgpt := newOrigin(t, unauthorized(fixed(40*time.Millisecond)))
	claude := newOrigin(t, unauthorized(fixed(0)))
	dial, targets := targets(chatgpt, claude, true)
	r, session := Screen(context.Background(), dial, targets)
	if r.Status != "done" || r.Samples != Samples || r.Location != "NRT" || session == nil || session.Closed() {
		t.Fatalf("unexpected result: %+v session=%v", r, session)
	}
	if r.LatencyMs < 40 || r.LatencyMs > r.MedianMs || r.MedianMs > 400 || r.ConnectMs <= 0 {
		t.Fatalf("latency outside the served delay: %+v", r)
	}
	// Loopback PING is below the Windows timer resolution and may read as zero.
	if r.PingMs < 0 || r.PingMs >= r.LatencyMs || r.OffsetMs < 35 || r.EstimateMs != r.MedianMs || r.OffsetMs != r.MedianMs-r.PingMs {
		t.Fatalf("PING must isolate the path from the served delay: %+v", r)
	}
	if chatgpt.connections.Load() != 1 || chatgpt.requests.Load() != Samples+1 || claude.requests.Load() != 1 {
		t.Fatalf("connections=%d requests=%d claude=%d", chatgpt.connections.Load(), chatgpt.requests.Load(), claude.requests.Load())
	}
	if err := session.Refresh(context.Background(), targets.ChatGPT); err != nil || chatgpt.connections.Load() != 1 {
		t.Fatalf("refresh must reuse the warm connection: %v", err)
	}
	session.Close()
	if !session.Closed() {
		t.Fatal("closed session still reports open")
	}
}

func TestScreenRejectsEitherBlockedService(t *testing.T) {
	cases := map[string]struct {
		chatgpt, claude int
		header, body    string
		status, reason  string
	}{
		"region":    {403, 401, "", `{"detail":{"code":"unsupported_country_region_territory"}}`, "blocked", "unsupported region"},
		"challenge": {403, 401, "challenge", `<html>Just a moment</html>`, "blocked", "Cloudflare challenge"},
		"limited":   {429, 401, "", `slow down`, "failed", "HTTP 429"},
		"hijacked":  {200, 401, "", `<html>portal</html>`, "failed", "HTTP 200"},
		"claude":    {401, 403, "", `{"error":{"type":"forbidden"}}`, "blocked", "Claude: HTTP 403"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			reply := func(code int) func(int32, http.ResponseWriter) {
				return func(_ int32, w http.ResponseWriter) {
					if c.header != "" {
						w.Header().Set("Cf-Mitigated", c.header)
					}
					w.WriteHeader(code)
					fmt.Fprint(w, c.body)
				}
			}
			chatgpt, claude := newOrigin(t, reply(c.chatgpt)), newOrigin(t, reply(c.claude))
			dial, targets := targets(chatgpt, claude, true)
			r, session := Screen(context.Background(), dial, targets)
			if r.Status != c.status || !strings.Contains(r.Error, c.reason) || session != nil {
				t.Fatalf("got %+v session=%v", r, session)
			}
		})
	}
}

func TestScreenFailsWhenSamplingBreaksMidway(t *testing.T) {
	chatgpt := newOrigin(t, func(n int32, w http.ResponseWriter) {
		if n > 3 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	})
	claude := newOrigin(t, unauthorized(fixed(0)))
	dial, targets := targets(chatgpt, claude, true)
	if r, session := Screen(context.Background(), dial, targets); r.Status != "failed" || !strings.Contains(r.Error, "sample 3: HTTP 503") || session != nil {
		t.Fatalf("got %+v", r)
	}
}

func TestScreenRequiresVerifiedTLS(t *testing.T) {
	chatgpt, claude := newOrigin(t, unauthorized(fixed(0))), newOrigin(t, unauthorized(fixed(0)))
	dial, targets := targets(chatgpt, claude, false)
	if r, _ := Screen(context.Background(), dial, targets); r.Status != "failed" || chatgpt.requests.Load() != 0 {
		t.Fatalf("untrusted certificate accepted: %+v", r)
	}
}

func TestScreenReportsDeadlineAsTimeout(t *testing.T) {
	chatgpt := newOrigin(t, unauthorized(func(n int32) time.Duration {
		if n > 1 {
			return time.Second
		}
		return 0
	}))
	claude := newOrigin(t, unauthorized(fixed(0)))
	dial, targets := targets(chatgpt, claude, true)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if r, _ := Screen(ctx, dial, targets); r.Status != "timeout" {
		t.Fatalf("deadline must not look like a node failure: %+v", r)
	}
}

func TestSummarizeUsesMedianAndMinimum(t *testing.T) {
	if median, low := summarize([]float64{300, 100, 200, 500, 400}); median != 300 || low != 100 {
		t.Fatalf("median=%v min=%v", median, low)
	}
	if median, _ := summarize([]float64{4, 1, 3, 2}); median != 2.5 {
		t.Fatalf("even median=%v", median)
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
	if time.Since(start) > time.Second || len(rs) != 1200 || peak.Load() > 32 {
		t.Fatal("deadline/concurrency/cleanup violated")
	}
	deadline := time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("context-aware probes did not release")
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

func TestDeadlineDoesNotWaitForUncooperativeAdapter(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	release := make(chan struct{})
	defer close(release)
	jobs := []Job{{Base: Result{Key: "stuck"}, Probe: func(context.Context) Result { <-release; return Result{Status: "done"} }}}
	start := time.Now()
	results := Run(ctx, jobs, 1)
	if time.Since(start) > 200*time.Millisecond || results[0].Status != "timeout" {
		t.Fatal("deadline waited for adapter shutdown")
	}
}

func TestFullScreenOf256NodesWithinBudget(t *testing.T) {
	if testing.Short() {
		t.Skip("real TLS connections for 256 nodes")
	}
	chatgpt := newOrigin(t, unauthorized(fixed(120*time.Millisecond)))
	claude := newOrigin(t, unauthorized(fixed(120*time.Millisecond)))
	dial, targets := targets(chatgpt, claude, true)
	jobs := make([]Job, 256)
	sessions := make([]*Session, len(jobs))
	for i := range jobs {
		i := i
		jobs[i] = Job{Base: Result{Key: fmt.Sprint(i)}, Probe: func(ctx context.Context) Result {
			r, s := Screen(ctx, dial, targets)
			sessions[i] = s
			return r
		}}
	}
	start := time.Now()
	results := Run(context.Background(), jobs, MaxConcurrency)
	elapsed := time.Since(start)
	done := 0
	for i, r := range results {
		if r.Status == "done" && r.LatencyMs >= 120 {
			done++
		} else if done == 0 {
			t.Logf("node failed: %+v", r)
		}
		sessions[i].Close()
	}
	t.Logf("256 nodes, concurrency %d, done %d, connections %d, elapsed %s", MaxConcurrency, done, chatgpt.connections.Load(), elapsed)
	if done != len(jobs) || chatgpt.connections.Load() != int32(len(jobs)) || elapsed >= Budget {
		t.Fatal("full-screen budget acceptance failed")
	}
}
