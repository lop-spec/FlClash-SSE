package ssebench

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
)

const Profile = "chatgpt-claude-colo-idle-v1"
const ChatGPTURL = "https://chatgpt.com/backend-api/codex/models"
const ClaudeURL = "https://api.anthropic.com/v1/models"
const Samples = 3
const Pings = 6
const MaxConcurrency = 32
const Budget = 30 * time.Second

// Awards are the points for the idle tournament podium, best first.
var Awards = []int{4, 3, 2, 1}

type Result struct {
	Key        string  `json:"key"`
	Name       string  `json:"name"`
	Profiles   []int64 `json:"profiles"`
	Status     string  `json:"status"`
	Error      string  `json:"error,omitempty"`
	Samples    int     `json:"samples"`
	LatencyMs  float64 `json:"latencyMs"`
	MedianMs   float64 `json:"medianMs"`
	PingMs     float64 `json:"pingMs"`
	OffsetMs   float64 `json:"offsetMs"`
	EstimateMs float64 `json:"estimateMs"`
	ConnectMs  float64 `json:"connectMs"`
	HTTPStatus int     `json:"httpStatus,omitempty"`
	Location   string  `json:"location,omitempty"`
	IdleMs     float64 `json:"idleMs,omitempty"`
	Place      int     `json:"place,omitempty"`
	Survived   bool    `json:"survived,omitempty"`
	ElapsedMs  float64 `json:"elapsedMs"`
}

// Dialer opens a TCP stream to host:port through one node.
type Dialer func(ctx context.Context, address string) (net.Conn, error)

// Targets lets tests point both gates at local servers; TLS only supplies roots.
type Targets struct {
	ChatGPT string
	Claude  string
	TLS     *tls.Config
}

var Production = Targets{ChatGPT: ChatGPTURL, Claude: ClaudeURL}

// Session is the warm ChatGPT connection that the idle tournament watches.
type Session struct {
	conn    net.Conn
	cc      *http2.ClientConn
	release func()
}

func (s *Session) Closed() bool { return s == nil || s.cc.State().Closed }

func (s *Session) Close() {
	if s == nil {
		return
	}
	s.cc.Close()
	s.conn.Close()
	if s.release != nil {
		s.release()
	}
}

// Refresh sends one request so every tournament entrant starts idling together.
func (s *Session) Refresh(ctx context.Context, rawURL string) error {
	r, err := send(ctx, s.cc, rawURL)
	if err != nil {
		return err
	}
	if status, reason := classify(r); status != "done" {
		return errors.New(reason)
	}
	return nil
}

// Adopt ties extra cleanup, such as the node adapter, to the session lifetime.
func (s *Session) Adopt(release func()) { s.release = release }

var errNoHTTP2 = errors.New("server did not negotiate HTTP/2")

func millis(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func open(ctx context.Context, dial Dialer, rawURL string, base *tls.Config) (*Session, float64, error) {
	target, err := url.Parse(rawURL)
	if err != nil {
		return nil, 0, err
	}
	port := target.Port()
	if port == "" {
		port = "443"
	}
	begin := time.Now()
	raw, err := dial(ctx, net.JoinHostPort(target.Hostname(), port))
	if err != nil {
		return nil, 0, err
	}
	config := &tls.Config{}
	if base != nil {
		config = base.Clone()
	}
	config.ServerName, config.NextProtos = target.Hostname(), []string{"h2"}
	conn := tls.Client(raw, config)
	handshake, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	if err = conn.HandshakeContext(handshake); err != nil {
		raw.Close()
		return nil, 0, err
	}
	if conn.ConnectionState().NegotiatedProtocol != "h2" {
		conn.Close()
		return nil, 0, errNoHTTP2
	}
	cc, err := (&http2.Transport{}).NewClientConn(conn)
	if err != nil {
		conn.Close()
		return nil, 0, err
	}
	return &Session{conn: conn, cc: cc}, millis(time.Since(begin)), nil
}

type reply struct {
	status    int
	ray       string
	mitigated string
	body      string
	ms        float64
}

func send(ctx context.Context, cc *http2.ClientConn, rawURL string) (reply, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return reply{}, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "FlClashSSE-latency/1")
	begin := time.Now()
	resp, err := cc.RoundTrip(req)
	if err != nil {
		return reply{}, err
	}
	ms := millis(time.Since(begin))
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	return reply{resp.StatusCode, resp.Header.Get("Cf-Ray"), resp.Header.Get("Cf-Mitigated"), string(body), ms}, nil
}

// PING is answered by the Cloudflare edge, so it times only this node's path.
func ping(ctx context.Context, cc *http2.ClientConn) (float64, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	begin := time.Now()
	if err := cc.Ping(ctx); err != nil {
		return 0, err
	}
	return millis(time.Since(begin)), nil
}

// An unauthenticated 401 is the only proof the exit reached the service;
// region blocks and Cloudflare challenges answer 403 before authentication.
func classify(r reply) (string, string) {
	switch {
	case r.status == http.StatusUnauthorized:
		return "done", ""
	case r.status == http.StatusForbidden && strings.Contains(r.body, "unsupported_country"):
		return "blocked", "unsupported region"
	case r.status == http.StatusForbidden && (r.mitigated != "" || strings.Contains(r.body, "challenge")):
		return "blocked", "Cloudflare challenge"
	case r.status == http.StatusForbidden:
		return "blocked", "HTTP 403"
	default:
		return "failed", fmt.Sprintf("HTTP %d", r.status)
	}
}

func location(ray string) string {
	if i := strings.LastIndexByte(ray, '-'); i >= 0 {
		return ray[i+1:]
	}
	return ""
}

func summarize(values []float64) (median, low float64) {
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	n := len(sorted)
	median = sorted[n/2]
	if n%2 == 0 {
		median = (sorted[n/2-1] + sorted[n/2]) / 2
	}
	return median, sorted[0]
}

func failure(ctx context.Context, stage string) Result {
	if ctx.Err() != nil {
		return Result{Status: "timeout", Error: "batch deadline reached"}
	}
	return Result{Status: "failed", Error: stage}
}

func gate(ctx context.Context, dial Dialer, rawURL string, base *tls.Config) Result {
	s, _, err := open(ctx, dial, rawURL, base)
	if err != nil {
		return failure(ctx, "connection or TLS failed")
	}
	defer s.Close()
	r, err := send(ctx, s.cc, rawURL)
	if err != nil {
		return failure(ctx, "connection dropped")
	}
	status, reason := classify(r)
	return Result{Status: status, Error: reason, HTTPStatus: r.status}
}

func screenChatGPT(ctx context.Context, dial Dialer, t Targets) (Result, *Session) {
	s, connectMs, err := open(ctx, dial, t.ChatGPT, t.TLS)
	if err != nil {
		return failure(ctx, "connection or TLS failed"), nil
	}
	first, err := send(ctx, s.cc, t.ChatGPT)
	if err != nil {
		s.Close()
		return failure(ctx, "connection dropped"), nil
	}
	if status, reason := classify(first); status != "done" {
		s.Close()
		return Result{Status: status, Error: reason, HTTPStatus: first.status, ConnectMs: connectMs}, nil
	}
	values := make([]float64, 0, Samples)
	pings := make([]float64, 0, Pings)
	for i := 0; i < Pings; i++ {
		p, err := ping(ctx, s.cc)
		if err != nil {
			s.Close()
			return failure(ctx, "connection dropped while pinging"), nil
		}
		pings = append(pings, p)
		if i >= Samples {
			continue
		}
		r, err := send(ctx, s.cc, t.ChatGPT)
		if err != nil {
			s.Close()
			return failure(ctx, "connection dropped while sampling"), nil
		}
		if status, reason := classify(r); status != "done" {
			s.Close()
			return Result{Status: status, Error: fmt.Sprintf("sample %d: %s", i+1, reason), HTTPStatus: r.status}, nil
		}
		values = append(values, r.ms)
	}
	median, low := summarize(values)
	pingMs, _ := summarize(pings)
	return Result{
		Status:     "done",
		Samples:    Samples,
		LatencyMs:  low,
		MedianMs:   median,
		PingMs:     pingMs,
		OffsetMs:   median - pingMs,
		EstimateMs: median,
		ConnectMs:  connectMs,
		HTTPStatus: first.status,
		Location:   location(first.ray),
	}, s
}

// Screen measures warm ChatGPT request latency and checks that Claude is not
// blocked on the same exit, because one node carries both services. Sequential
// samples matter: overlapping requests on one connection distort the timing.
func Screen(ctx context.Context, dial Dialer, t Targets) (Result, *Session) {
	start := time.Now()
	claude := make(chan Result, 1)
	go func() { claude <- gate(ctx, dial, t.Claude, t.TLS) }()
	r, session := screenChatGPT(ctx, dial, t)
	var c Result
	select {
	case c = <-claude:
	case <-ctx.Done():
		c = Result{Status: "timeout", Error: "batch deadline reached"}
	}
	if r.Status == "done" && c.Status != "done" {
		session.Close()
		session = nil
		r.Status, r.Error, r.HTTPStatus = c.Status, "Claude: "+c.Error, c.HTTPStatus
	}
	r.ElapsedMs = millis(time.Since(start))
	return r, session
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
	ctx, cancel := context.WithTimeout(ctx, Budget)
	defer cancel()
	results := make([]Result, len(jobs))
	started := make([]atomic.Bool, len(jobs))
	for i, job := range jobs {
		results[i] = job.Base
		results[i].Status = "unmeasured"
		results[i].Error = "batch deadline reached before start"
	}
	type completed struct {
		index int
		value Result
	}
	replies := make(chan completed, concurrency)
	tasks := make(chan int)
	for w := 0; w < concurrency && w < len(jobs); w++ {
		go func() {
			for i := range tasks {
				if ctx.Err() != nil {
					return
				}
				started[i].Store(true)
				value := jobs[i].Probe(ctx)
				select {
				case replies <- completed{i, value}:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	go func() {
		defer close(tasks)
		ramp := time.NewTicker(time.Millisecond)
		defer ramp.Stop()
		for i := range jobs {
			select {
			case <-ramp.C:
			case <-ctx.Done():
				return
			}
			select {
			case tasks <- i:
			case <-ctx.Done():
				return
			}
		}
	}()
	for received := 0; received < len(jobs); received++ {
		select {
		case reply := <-replies:
			base := jobs[reply.index].Base
			reply.value.Key, reply.value.Name, reply.value.Profiles = base.Key, base.Name, base.Profiles
			results[reply.index] = reply.value
		case <-ctx.Done():
			for i := range results {
				if results[i].Status == "unmeasured" && started[i].Load() {
					results[i].Status, results[i].Error = "timeout", "batch deadline reached"
				}
			}
			return results
		}
	}
	return results
}
