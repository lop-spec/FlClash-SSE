package main

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

// Full screening and tournament on a copy of an installed app's profiles:
// FLCLASH_SSE_LIVE_HOME, FLCLASH_SSE_LIVE_OUT, optional FLCLASH_SSE_LIVE_LIMIT_MS.
func TestLiveBatchAndTournament(t *testing.T) {
	home, out := os.Getenv("FLCLASH_SSE_LIVE_HOME"), os.Getenv("FLCLASH_SSE_LIVE_OUT")
	if home == "" || out == "" {
		t.Skip("live subscriptions not configured")
	}
	work := t.TempDir()
	source := filepath.Join(home, "profiles")
	err := filepath.WalkDir(source, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(work, "profiles", strings.TrimPrefix(path, source))
		if d.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0600)
	})
	if err != nil {
		t.Fatal(err)
	}
	C.SetHomeDir(work)
	files, _ := filepath.Glob(filepath.Join(work, "profiles", "*.yaml"))
	params := &SSEParams{}
	params.TournamentLimitMs, _ = strconv.ParseInt(os.Getenv("FLCLASH_SSE_LIVE_LIMIT_MS"), 10, 64)
	for _, file := range files {
		if id, err := strconv.ParseInt(strings.TrimSuffix(filepath.Base(file), ".yaml"), 10, 64); err == nil {
			params.Profiles = append(params.Profiles, id)
		}
	}
	start := time.Now()
	screened := handleSSEBatch(params)
	screenMs := time.Since(start).Milliseconds()
	for live := snapshotTournament(); live != nil && live.Running; live = snapshotTournament() {
		time.Sleep(time.Second)
	}
	sseBatchMu.Lock()
	sseBatchMu.Unlock()
	history, tournament, err := readSSEHistory(work)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(map[string]any{"screenMs": screenMs, "totalMs": time.Since(start).Milliseconds(), "error": screened.Error, "nodes": len(screened.Nodes), "history": history, "tournament": tournament})
	if err := os.WriteFile(out, encoded, 0600); err != nil {
		t.Fatal(err)
	}
	t.Logf("%d nodes screened in %dms, total %s", len(screened.Nodes), screenMs, time.Since(start))
}
