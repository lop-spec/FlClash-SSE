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
	"net/http"
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
	"gopkg.in/yaml.v3"
)

const sseEndpoint = "https://flclash-sse.1781297309.workers.dev/api/stream"

type SSEParams struct {
	Profiles  []int64 `json:"profiles"`
	Name      string  `json:"name"`
	ProfileID int64   `json:"profileId"`
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
	LastSuccess *ssebench.Result `json:"lastSuccess,omitempty"`
	Latest      ssebench.Result  `json:"latest"`
	MeasuredAt  int64            `json:"measuredAt"`
}
type sseCatalog struct {
	Nodes     []sseNode            `json:"nodes"`
	Issues    []sseIssue           `json:"issues"`
	History   map[string]sseRecord `json:"history"`
	Error     string               `json:"error,omitempty"`
	ElapsedMs int64                `json:"elapsedMs"`
	Endpoint  string               `json:"endpoint"`
	Profile   string               `json:"profile"`
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
	out := sseCatalog{Nodes: []sseNode{}, Issues: []sseIssue{}, History: map[string]sseRecord{}, Endpoint: sseEndpoint, Profile: ssebench.Profile}
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
	history, err := readSSEHistory(home)
	if err != nil {
		out.Error = "SSE history is unreadable; existing file preserved"
		logError("SSE history: read failed; refusing overwrite")
	} else {
		out.History = history
	}
	return out
}

func readSSEHistory(home string) (map[string]sseRecord, error) {
	sseHistoryMu.Lock()
	defer sseHistoryMu.Unlock()
	history := map[string]sseRecord{}
	bytes, err := os.ReadFile(filepath.Join(home, "sse-history-v1.json"))
	if os.IsNotExist(err) {
		return history, nil
	}
	if err != nil {
		return nil, err
	}
	var store struct {
		Profile  string               `json:"profile"`
		Endpoint string               `json:"endpoint"`
		Results  map[string]sseRecord `json:"results"`
	}
	if err = json.Unmarshal(bytes, &store); err != nil {
		return nil, err
	}
	if store.Profile != ssebench.Profile || store.Endpoint != sseEndpoint {
		return nil, fmt.Errorf("incompatible history")
	}
	if store.Results != nil {
		history = store.Results
	}
	return history, nil
}

func validSSEResult(r ssebench.Result) bool {
	return r.Status == "done" && r.Tokens == ssebench.Samples && r.TokPerSec > 0 && r.TokPerSec < 100000 && r.ElapsedMs > 0
}
func mergeSSEResult(previous sseRecord, next ssebench.Result) sseRecord {
	previous.Latest = next
	if validSSEResult(next) {
		previous.LastSuccess = &next
		previous.MeasuredAt = time.Now().UnixMilli()
	}
	return previous
}

func writeSSEHistory(home string, history map[string]sseRecord) error {
	sseHistoryMu.Lock()
	defer sseHistoryMu.Unlock()
	data, err := json.Marshal(map[string]any{"profile": ssebench.Profile, "endpoint": sseEndpoint, "results": history})
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(home, ".sse-history-*")
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
	return os.Rename(temp, filepath.Join(home, "sse-history-v1.json"))
}

func probeSSENode(ctx context.Context, node sseNode) ssebench.Result {
	if ctx.Err() != nil {
		return ssebench.Result{Status: "unmeasured", Error: "batch deadline reached before start"}
	}
	if detour, _ := node.Config["dialer-proxy"].(string); detour != "" {
		return ssebench.Result{Status: "unsupported", Error: "chained dialer requires an isolated dependency graph"}
	}
	proxy, err := adapter.ParseProxy(node.Config)
	if err != nil {
		return ssebench.Result{Status: "unsupported", Error: "proxy configuration or protocol is unsupported"}
	}
	defer proxy.Close()
	transport := &http.Transport{Proxy: nil, DisableCompression: true, DisableKeepAlives: true, TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 8 * time.Second,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
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
		}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return ssebench.Probe(ctx, client, sseEndpoint)
}

func handleSSECatalog(params *SSEParams) sseCatalog {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return loadSSECatalog(ctx, C.Path.HomeDir(), params)
}
func handleSSEBatch(params *SSEParams) sseCatalog {
	start := time.Now()
	if !sseBatchMu.TryLock() {
		return sseCatalog{Error: "SSE batch already running"}
	}
	defer sseBatchMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), ssebench.Budget)
	defer cancel()
	home := C.Path.HomeDir()
	catalog := loadSSECatalog(ctx, home, params)
	jobs := make([]ssebench.Job, 0, len(catalog.Nodes))
	for _, node := range catalog.Nodes {
		node := node
		profiles := make([]int64, 0, len(node.Aliases))
		for _, a := range node.Aliases {
			profiles = append(profiles, a.ProfileID)
		}
		jobs = append(jobs, ssebench.Job{Base: ssebench.Result{Key: node.Key, Name: node.Name, Profiles: profiles}, Probe: func(ctx context.Context) ssebench.Result { return probeSSENode(ctx, node) }})
	}
	for _, result := range ssebench.Run(ctx, jobs, ssebench.MaxConcurrency) {
		if result.Status != "done" {
			logError("SSE %s: %s", result.Status, result.Error)
		}
		catalog.History[result.Key] = mergeSSEResult(catalog.History[result.Key], result)
	}
	if catalog.Error == "" {
		if err := writeSSEHistory(home, catalog.History); err != nil {
			catalog.Error = "SSE persistence failed; previous disk history retained"
			logError("SSE persistence: write failed")
		}
	}
	catalog.ElapsedMs = time.Since(start).Milliseconds()
	return catalog
}
