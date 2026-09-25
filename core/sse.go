package main

import (
	"context"
	"core/ssebench"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"gopkg.in/yaml.v3"
)

const sseHistoryFile = "node-score-v1.json"

type SSEParams struct {
	Profiles          []int64 `json:"profiles"`
	Name              string  `json:"name"`
	ProfileID         int64   `json:"profileId"`
	TournamentLimitMs int64   `json:"tournamentLimitMs"`
}
type sseAlias struct {
	ProfileID  int64             `json:"profileId"`
	Name       string            `json:"name"`
	Selections map[string]string `json:"selections"`
}
type sseNode struct {
	Key     string         `json:"key"`
	Name    string         `json:"name"`
	Aliases []sseAlias     `json:"aliases"`
	Config  map[string]any `json:"-"`
}
type sseIssue struct {
	ProfileID int64  `json:"profileId"`
	Name      string `json:"name"`
	Error     string `json:"error"`
}
type sseRecord struct {
	Latest      ssebench.Result `json:"latest"`
	MeasuredAt  int64           `json:"measuredAt"`
	Score       int             `json:"score"`
	LastAwardAt int64           `json:"lastAwardAt,omitempty"`
}
type sseColo struct {
	Location  string  `json:"location"`
	LatencyMs float64 `json:"latencyMs"`
	Nodes     int     `json:"nodes"`
}
type sseEntrant struct {
	Key    string  `json:"key"`
	Name   string  `json:"name"`
	Alive  bool    `json:"alive"`
	IdleMs float64 `json:"idleMs,omitempty"`
}
type sseTournament struct {
	Running    bool         `json:"running"`
	StartedAt  int64        `json:"startedAt"`
	FinishedAt int64        `json:"finishedAt,omitempty"`
	LimitMs    int64        `json:"limitMs"`
	Colos      []sseColo    `json:"colos"`
	Entrants   []sseEntrant `json:"entrants"`
	Podium     []string     `json:"podium,omitempty"`
	Error      string       `json:"error,omitempty"`
}
type sseCatalog struct {
	Nodes      []sseNode            `json:"nodes"`
	Issues     []sseIssue           `json:"issues"`
	History    map[string]sseRecord `json:"history"`
	Error      string               `json:"error,omitempty"`
	ElapsedMs  int64                `json:"elapsedMs"`
	Endpoint   string               `json:"endpoint"`
	Profile    string               `json:"profile"`
	Tournament *sseTournament       `json:"tournament,omitempty"`
}
type sseRaw struct {
	Proxies   []map[string]any `yaml:"proxies"`
	Providers map[string]struct {
		Type          string           `yaml:"type"`
		URL           string           `yaml:"url"`
		Payload       []map[string]any `yaml:"payload"`
		Override      map[string]any   `yaml:"override"`
		Filter        string           `yaml:"filter"`
		ExcludeFilter string           `yaml:"exclude-filter"`
		ExcludeType   string           `yaml:"exclude-type"`
		DialerProxy   string           `yaml:"dialer-proxy"`
	} `yaml:"proxy-providers"`
	Groups []struct {
		Name                string   `yaml:"name"`
		Type                string   `yaml:"type"`
		Proxies             []string `yaml:"proxies"`
		Use                 []string `yaml:"use"`
		IncludeAll          bool     `yaml:"include-all"`
		IncludeAllProxies   bool     `yaml:"include-all-proxies"`
		IncludeAllProviders bool     `yaml:"include-all-providers"`
		Filter              string   `yaml:"filter"`
		ExcludeFilter       string   `yaml:"exclude-filter"`
		ExcludeType         string   `yaml:"exclude-type"`
	} `yaml:"proxy-groups"`
}

var sseBatchMu sync.Mutex
var sseHistoryMu sync.Mutex

func sseReadYAML(path string, target any) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil {
		return err
	}
	if stat.Size() > 32*1024*1024 {
		return fmt.Errorf("cache exceeds size budget")
	}
	return yaml.NewDecoder(file).Decode(target)
}

func sseMatcher(filter, exclude, types string) (func(string, string) (bool, error), error) {
	compile := func(text string) ([]*regexp2.Regexp, error) {
		regs := []*regexp2.Regexp{}
		if text == "" {
			return regs, nil
		}
		for _, part := range strings.Split(text, "`") {
			re, err := regexp2.Compile(part, regexp2.None)
			if err != nil {
				return nil, err
			}
			re.MatchTimeout = 10 * time.Millisecond
			regs = append(regs, re)
		}
		return regs, nil
	}
	include, err := compile(filter)
	if err != nil {
		return nil, err
	}
	deny, err := compile(exclude)
	if err != nil {
		return nil, err
	}
	return func(name, kind string) (bool, error) {
		for _, t := range strings.Split(types, "|") {
			if t != "" && strings.EqualFold(kind, t) {
				return false, nil
			}
		}
		for _, re := range deny {
			match, err := re.MatchString(name)
			if err != nil {
				return false, err
			}
			if match {
				return false, nil
			}
		}
		if len(include) == 0 {
			return true, nil
		}
		for _, re := range include {
			match, err := re.MatchString(name)
			if err != nil {
				return false, err
			}
			if match {
				return true, nil
			}
		}
		return false, nil
	}, nil
}

func sseSelections(raw sseRaw, name string) map[string]string {
	selections := map[string]string{"GLOBAL": name}
	groups := map[string][]string{}
	for _, g := range raw.Groups {
		if g.Type == "select" {
			groups[g.Name] = g.Proxies
		}
	}
	memo := map[string]bool{}
	var reach func(string, map[string]bool) bool
	reach = func(group string, seen map[string]bool) bool {
		if value, known := memo[group]; known {
			return value
		}
		if seen[group] {
			return false
		}
		seen[group] = true
		defer delete(seen, group)
		for _, child := range groups[group] {
			if child == name || reach(child, seen) {
				selections[group] = child
				memo[group] = true
				return true
			}
		}
		memo[group] = false
		return false
	}
	for name := range groups {
		reach(name, map[string]bool{})
	}
	return selections
}

func loadSSECatalog(ctx context.Context, home string, params *SSEParams) sseCatalog {
	out := sseCatalog{Nodes: []sseNode{}, Issues: []sseIssue{}, History: map[string]sseRecord{}, Endpoint: ssebench.ChatGPTURL, Profile: ssebench.Profile}
	indices := map[string]int{}
	seenProfiles := map[int64]bool{}
	issue := func(id int64, name, reason string) {
		out.Issues = append(out.Issues, sseIssue{id, name, reason})
		logError("SSE catalog: profile %d %s", id, reason)
	}
	for _, id := range params.Profiles {
		if seenProfiles[id] {
			continue
		}
		seenProfiles[id] = true
		if ctx.Err() != nil {
			issue(id, "", "catalog deadline reached")
			continue
		}
		if id <= 0 {
			issue(id, "", "invalid profile ID")
			continue
		}
		var raw sseRaw
		if sseReadYAML(filepath.Join(home, "profiles", fmt.Sprintf("%d.yaml", id)), &raw) != nil {
			issue(id, "", "subscription cache unavailable or invalid")
			continue
		}
		nodes := append([]map[string]any{}, raw.Proxies...)
		providerNames := make([]string, 0, len(raw.Providers))
		for name := range raw.Providers {
			providerNames = append(providerNames, name)
		}
		sort.Strings(providerNames)
		providerMembers := map[string][]string{}
		for _, name := range providerNames {
			provider := raw.Providers[name]
			matches, matchErr := sseMatcher(provider.Filter, provider.ExcludeFilter, provider.ExcludeType)
			if matchErr != nil {
				issue(id, name, "invalid provider filter")
				continue
			}
			if _, ok := provider.Override["proxy-name"]; ok {
				issue(id, name, "provider regex renaming is not supported by the isolated catalog")
				continue
			}
			if _, ok := provider.Override["override-expr"]; ok {
				issue(id, name, "provider expression overrides are not supported by the isolated catalog")
				continue
			}
			entries := provider.Payload
			if provider.Type != "inline" {
				key := "proxy-providers/" + name
				if provider.URL != "" {
					key = name + "@" + provider.URL
				}
				sum := md5.Sum([]byte(key))
				path := filepath.Join(home, "profiles", "providers", strconv.FormatInt(id, 10), "proxies", hex.EncodeToString(sum[:]))
				var cached sseRaw
				if sseReadYAML(path, &cached) != nil {
					issue(id, name, "provider cache missing; update this subscription before testing")
					continue
				}
				entries = cached.Proxies
			}
			for _, entry := range entries {
				if ctx.Err() != nil {
					issue(id, name, "catalog deadline reached")
					break
				}
				rawName, _ := entry["name"].(string)
				kind, _ := entry["type"].(string)
				matched, err := matches(rawName, kind)
				if err != nil {
					issue(id, name, "provider filter exceeded evaluation budget")
					break
				}
				if !matched {
					continue
				}
				config := make(map[string]any, len(entry))
				for k, v := range entry {
					config[k] = v
				}
				if provider.DialerProxy != "" {
					config["dialer-proxy"] = provider.DialerProxy
				}
				for _, key := range []string{"tfo", "mptcp", "udp", "udp-over-tcp", "up", "down", "dialer-proxy", "skip-cert-verify", "name-cert-verify", "interface-name", "routing-mark", "ip-version"} {
					if v, ok := provider.Override[key]; ok {
						config[key] = v
					}
				}
				label, _ := config["name"].(string)
				prefix, _ := provider.Override["additional-prefix"].(string)
				suffix, _ := provider.Override["additional-suffix"].(string)
				config["name"] = prefix + label + suffix
				providerMembers[name] = append(providerMembers[name], prefix+label+suffix)
				nodes = append(nodes, config)
			}
		}
		for i := range raw.Groups {
			group := &raw.Groups[i]
			if group.IncludeAll || group.IncludeAllProxies {
				for _, node := range raw.Proxies {
					if name, ok := node["name"].(string); ok {
						group.Proxies = append(group.Proxies, name)
					}
				}
			}
			uses := group.Use
			if group.IncludeAll || group.IncludeAllProviders {
				uses = providerNames
			}
			for _, name := range uses {
				group.Proxies = append(group.Proxies, providerMembers[name]...)
			}
			matches, err := sseMatcher(group.Filter, group.ExcludeFilter, group.ExcludeType)
			if err != nil {
				issue(id, group.Name, "invalid group filter; startup selection excluded")
				group.Proxies = nil
				continue
			}
			kinds := map[string]string{}
			for _, n := range nodes {
				label, _ := n["name"].(string)
				kinds[label], _ = n["type"].(string)
			}
			filtered := []string{}
			for _, name := range group.Proxies {
				if ctx.Err() != nil {
					issue(id, group.Name, "catalog deadline reached")
					break
				}
				matched, err := matches(name, kinds[name])
				if err != nil {
					issue(id, group.Name, "group filter exceeded evaluation budget")
					break
				}
				if matched {
					filtered = append(filtered, name)
				}
			}
			group.Proxies = filtered
		}
		for _, rawNode := range nodes {
			if ctx.Err() != nil {
				issue(id, "", "catalog deadline reached")
				break
			}
			name, _ := rawNode["name"].(string)
			if params.Name != "" && (name != params.Name || id != params.ProfileID) {
				continue
			}
			config := make(map[string]any, len(rawNode))
			for k, v := range rawNode {
				if k != "name" {
					config[k] = v
				}
			}
			encoded, err := json.Marshal(config)
			if err != nil {
				issue(id, name, "invalid node configuration")
				continue
			}
			sum := sha256.Sum256(encoded)
			key := hex.EncodeToString(sum[:])
			alias := sseAlias{id, name, sseSelections(raw, name)}
			if index, ok := indices[key]; ok {
				out.Nodes[index].Aliases = append(out.Nodes[index].Aliases, alias)
				continue
			}
			config["name"] = name
			indices[key] = len(out.Nodes)
			out.Nodes = append(out.Nodes, sseNode{key, name, []sseAlias{alias}, config})
		}
	}
	history, tournament, err := readSSEHistory(home)
	if err != nil {
		out.Error = "SSE history is unreadable; existing file preserved"
		logError("SSE history: read failed; refusing overwrite")
	} else {
		out.History, out.Tournament = history, tournament
	}
	return out
}

func readSSEHistory(home string) (map[string]sseRecord, *sseTournament, error) {
	sseHistoryMu.Lock()
	defer sseHistoryMu.Unlock()
	history := map[string]sseRecord{}
	bytes, err := os.ReadFile(filepath.Join(home, sseHistoryFile))
	if os.IsNotExist(err) {
		return history, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	var store struct {
		Profile    string               `json:"profile"`
		Endpoint   string               `json:"endpoint"`
		Results    map[string]sseRecord `json:"results"`
		Tournament *sseTournament       `json:"tournament"`
	}
	if err = json.Unmarshal(bytes, &store); err != nil {
		return nil, nil, err
	}
	if store.Profile != ssebench.Profile || store.Endpoint != ssebench.ChatGPTURL {
		return nil, nil, fmt.Errorf("incompatible history")
	}
	if store.Results != nil {
		history = store.Results
	}
	return history, store.Tournament, nil
}

// Latency is a time-of-day state, so an older result must not outrank a fresh
// failure; scores are the only thing that accumulates across runs.
func mergeSSEResult(previous sseRecord, next ssebench.Result) sseRecord {
	if next.Status == "unmeasured" && previous.MeasuredAt != 0 {
		return previous
	}
	previous.Latest, previous.MeasuredAt = next, time.Now().UnixMilli()
	return previous
}

func awardPodium(history map[string]sseRecord, podium []string, now int64) {
	for place, key := range podium {
		if place >= len(ssebench.Awards) {
			return
		}
		record := history[key]
		record.Score += ssebench.Awards[place]
		record.LastAwardAt = now
		history[key] = record
	}
}

// Exit colos decide how far Cloudflare still has to carry a request to the
// ChatGPT origin, so they are compared by the median of their nodes.
func rankColos(results []ssebench.Result) []sseColo {
	latencies := map[string][]float64{}
	for _, r := range results {
		if r.Status == "done" && r.Location != "" {
			latencies[r.Location] = append(latencies[r.Location], r.LatencyMs)
		}
	}
	colos := make([]sseColo, 0, len(latencies))
	for location, values := range latencies {
		sort.Float64s(values)
		median := values[len(values)/2]
		if len(values)%2 == 0 {
			median = (values[len(values)/2-1] + median) / 2
		}
		colos = append(colos, sseColo{Location: location, LatencyMs: median, Nodes: len(values)})
	}
	sort.Slice(colos, func(a, b int) bool {
		if colos[a].LatencyMs != colos[b].LatencyMs {
			return colos[a].LatencyMs < colos[b].LatencyMs
		}
		return colos[a].Location < colos[b].Location
	})
	return colos
}

func writeSSEHistory(home string, history map[string]sseRecord, tournament *sseTournament) error {
	sseHistoryMu.Lock()
	defer sseHistoryMu.Unlock()
	data, err := json.Marshal(map[string]any{"profile": ssebench.Profile, "endpoint": ssebench.ChatGPTURL, "results": history, "tournament": tournament})
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(home, ".node-score-*")
	if err != nil {
		return err
	}
	temp := f.Name()
	defer os.Remove(temp)
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(temp, filepath.Join(home, sseHistoryFile))
}

// sseSessions collects warm connections from probes; a probe that finishes
// after the batch deadline sealed the set must not leak its connection.
type sseSessions struct {
	mu     sync.Mutex
	open   map[int]*ssebench.Session
	sealed bool
}

func (s *sseSessions) keep(index int, session *ssebench.Session) {
	if session == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sealed {
		session.Close()
		return
	}
	s.open[index] = session
}

func (s *sseSessions) seal() map[int]*ssebench.Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sealed = true
	return s.open
}

func probeSSENode(ctx context.Context, node sseNode) (ssebench.Result, *ssebench.Session) {
	if ctx.Err() != nil {
		return ssebench.Result{Status: "unmeasured", Error: "batch deadline reached before start"}, nil
	}
	if detour, _ := node.Config["dialer-proxy"].(string); detour != "" {
		return ssebench.Result{Status: "unsupported", Error: "chained dialer requires an isolated dependency graph"}, nil
	}
	proxy, err := adapter.ParseProxy(node.Config)
	if err != nil {
		return ssebench.Result{Status: "unsupported", Error: "proxy configuration or protocol is unsupported"}, nil
	}
	dial := func(ctx context.Context, address string) (net.Conn, error) {
		host, portText, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		port, e := strconv.Atoi(portText)
		if e != nil {
			return nil, e
		}
		metadata := &C.Metadata{NetWork: C.TCP, Host: host, DstPort: uint16(port)}
		if ip, e := netip.ParseAddr(host); e == nil {
			metadata.DstIP = ip
			metadata.Host = ""
		}
		return proxy.DialContext(ctx, metadata)
	}
	result, session := ssebench.Screen(ctx, dial, ssebench.Production)
	if session == nil {
		proxy.Close()
		return result, nil
	}
	// Some adapters own their transport; closing them early would kill the
	// connection the tournament is watching.
	session.Adopt(func() { proxy.Close() })
	return result, session
}

var sseProgressMu sync.Mutex
var sseProgress *sseTournament

func snapshotTournament() *sseTournament {
	sseProgressMu.Lock()
	defer sseProgressMu.Unlock()
	if sseProgress == nil {
		return nil
	}
	copied := *sseProgress
	copied.Colos = append([]sseColo(nil), sseProgress.Colos...)
	copied.Entrants = append([]sseEntrant(nil), sseProgress.Entrants...)
	copied.Podium = append([]string(nil), sseProgress.Podium...)
	return &copied
}

func handleSSECatalog(params *SSEParams) sseCatalog {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	catalog := loadSSECatalog(ctx, C.Path.HomeDir(), params)
	if live := snapshotTournament(); live != nil {
		catalog.Tournament = live
	}
	return catalog
}

type sseContender struct {
	key     string
	name    string
	result  ssebench.Result
	session *ssebench.Session
	since   time.Time
}

// handleSSEBatch returns after the screening pass; the idle tournament keeps
// running in the background and holds the batch lock until it has scored.
func handleSSEBatch(params *SSEParams) sseCatalog {
	start := time.Now()
	if !sseBatchMu.TryLock() {
		return sseCatalog{Error: "SSE batch already running", Tournament: snapshotTournament()}
	}
	handedOff := false
	defer func() {
		if !handedOff {
			sseBatchMu.Unlock()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), ssebench.Budget)
	defer cancel()
	home := C.Path.HomeDir()
	catalog := loadSSECatalog(ctx, home, params)
	sessions := &sseSessions{open: map[int]*ssebench.Session{}}
	jobs := make([]ssebench.Job, 0, len(catalog.Nodes))
	for i, node := range catalog.Nodes {
		i, node := i, node
		profiles := make([]int64, 0, len(node.Aliases))
		for _, a := range node.Aliases {
			profiles = append(profiles, a.ProfileID)
		}
		jobs = append(jobs, ssebench.Job{Base: ssebench.Result{Key: node.Key, Name: node.Name, Profiles: profiles}, Probe: func(ctx context.Context) ssebench.Result {
			result, session := probeSSENode(ctx, node)
			sessions.keep(i, session)
			return result
		}})
	}
	results := ssebench.Run(ctx, jobs, ssebench.MaxConcurrency)
	open := sessions.seal()
	for _, result := range results {
		if result.Status != "done" {
			logError("SSE %s: %s", result.Status, result.Error)
		}
		catalog.History[result.Key] = mergeSSEResult(catalog.History[result.Key], result)
	}
	full := params.Name == "" && catalog.Error == ""
	contenders := []*sseContender{}
	previous := catalog.Tournament
	if full {
		colos := rankColos(results)
		top := map[string]bool{}
		for i := 0; i < len(colos) && i < 2; i++ {
			top[colos[i].Location] = true
		}
		for i, r := range results {
			if session := open[i]; session != nil && r.Status == "done" && top[r.Location] {
				contenders = append(contenders, &sseContender{key: r.Key, name: r.Name, result: r, session: session})
				delete(open, i)
			}
		}
		catalog.Tournament = &sseTournament{Running: true, StartedAt: time.Now().UnixMilli(), Colos: colos}
		previous = nil
	}
	for _, session := range open {
		session.Close()
	}
	if catalog.Error == "" {
		if err := writeSSEHistory(home, catalog.History, previous); err != nil {
			catalog.Error = "SSE persistence failed; previous disk history retained"
			logError("SSE persistence: write failed")
		}
	}
	if full {
		handedOff = startTournament(home, &catalog, contenders, params.TournamentLimitMs)
	}
	catalog.ElapsedMs = time.Since(start).Milliseconds()
	return catalog
}

func startTournament(home string, catalog *sseCatalog, contenders []*sseContender, limitMs int64) bool {
	rules := ssebench.DefaultRules
	if limitMs > 0 {
		rules.Limit = time.Duration(limitMs) * time.Millisecond
	}
	tournament := catalog.Tournament
	tournament.LimitMs = rules.Limit.Milliseconds()
	var wg sync.WaitGroup
	refreshed := make([]bool, len(contenders))
	for i, c := range contenders {
		wg.Add(1)
		go func(i int, c *sseContender) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			refreshed[i] = c.session.Refresh(ctx, ssebench.ChatGPTURL) == nil
			c.since = time.Now()
		}(i, c)
	}
	wg.Wait()
	entrants := []*sseContender{}
	for i, c := range contenders {
		if refreshed[i] {
			entrants = append(entrants, c)
			tournament.Entrants = append(tournament.Entrants, sseEntrant{Key: c.key, Name: c.name, Alive: true})
		} else {
			c.session.Close()
		}
	}
	history := make(map[string]sseRecord, len(catalog.History))
	for k, v := range catalog.History {
		history[k] = v
	}
	sseProgressMu.Lock()
	sseProgress = tournament
	sseProgressMu.Unlock()
	if len(entrants) == 0 {
		tournament.Running, tournament.FinishedAt = false, time.Now().UnixMilli()
		tournament.Error = "no reachable node in the two fastest colos"
		logError("SSE tournament: %s", tournament.Error)
		if err := writeSSEHistory(home, history, tournament); err != nil {
			logError("SSE persistence: write failed")
		}
		catalog.Tournament = snapshotTournament()
		return false
	}
	catalog.Tournament = snapshotTournament()
	log.Infoln("SSE tournament: %d nodes from the two fastest colos, limit %s", len(entrants), rules.Limit)
	go runTournament(home, history, entrants, rules)
	return true
}

func runTournament(home string, history map[string]sseRecord, entrants []*sseContender, rules ssebench.Rules) {
	defer sseBatchMu.Unlock()
	defer func() {
		for _, c := range entrants {
			c.session.Close()
		}
	}()
	field := make([]ssebench.Entrant, len(entrants))
	for i, c := range entrants {
		field[i] = ssebench.Entrant{LatencyMs: c.result.LatencyMs, Since: c.since, Closed: c.session.Closed}
	}
	placements := ssebench.Tournament(context.Background(), field, rules, func(i int, idle time.Duration) {
		sseProgressMu.Lock()
		sseProgress.Entrants[i].Alive = false
		sseProgress.Entrants[i].IdleMs = float64(idle.Milliseconds())
		sseProgressMu.Unlock()
		log.Infoln("SSE tournament: %s dropped after %s idle", entrants[i].name, idle.Round(time.Second))
	})
	now := time.Now().UnixMilli()
	podium := []string{}
	for place, p := range placements {
		c := entrants[p.Index]
		record := history[c.key]
		record.Latest.IdleMs, record.Latest.Place, record.Latest.Survived = p.IdleMs, place+1, p.Survived
		history[c.key] = record
		if place < len(ssebench.Awards) {
			podium = append(podium, c.key)
		}
	}
	awardPodium(history, podium, now)
	sseProgressMu.Lock()
	for _, p := range placements {
		if p.Survived {
			sseProgress.Entrants[p.Index].IdleMs = p.IdleMs
		}
	}
	sseProgress.Running, sseProgress.FinishedAt, sseProgress.Podium = false, now, podium
	sseProgressMu.Unlock()
	if err := writeSSEHistory(home, history, snapshotTournament()); err != nil {
		logError("SSE persistence: tournament scores not written")
	}
	if len(placements) > 0 {
		log.Infoln("SSE tournament: winner %s after %s idle", entrants[placements[0].Index].name, time.Duration(placements[0].IdleMs)*time.Millisecond)
	}
}
