package main

import (
	"context"
	"core/ssebench"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSSEHistoryKeepsLatestAttemptAndAccumulatesScores(t *testing.T) {
	if fresh := mergeSSEResult(sseRecord{}, ssebench.Result{Status: "unmeasured"}); fresh.Latest.Status != "unmeasured" || fresh.MeasuredAt == 0 {
		t.Fatal("a node never measured must still report that it was not covered")
	}
	good := ssebench.Result{Status: "done", Samples: ssebench.Samples, LatencyMs: 180}
	old := mergeSSEResult(sseRecord{Score: 7, LastAwardAt: 5}, good)
	if old.Latest.LatencyMs != 180 || old.MeasuredAt == 0 || old.Score != 7 {
		t.Fatal("valid result not recorded or score lost")
	}
	if kept := mergeSSEResult(old, ssebench.Result{Status: "unmeasured"}); kept.Latest.LatencyMs != 180 || kept.MeasuredAt != old.MeasuredAt {
		t.Fatal("a node the batch never reached must keep its last record")
	}
	for _, status := range []string{"timeout", "failed", "blocked", "unsupported"} {
		if next := mergeSSEResult(old, ssebench.Result{Status: status}); next.Latest.Status != status || next.Latest.LatencyMs != 0 || next.Score != 7 {
			t.Fatalf("%s must replace the older result but keep the score", status)
		}
	}
	history := map[string]sseRecord{"a": old, "b": {}, "c": {}, "d": {}, "e": {Score: 1}}
	awardPodium(history, []string{"b", "a", "e", "c", "d"}, 99)
	for key, want := range map[string]int{"b": 4, "a": 10, "e": 3, "c": 1, "d": 0} {
		if history[key].Score != want {
			t.Fatalf("%s score %d, want %d", key, history[key].Score, want)
		}
	}
	if history["b"].LastAwardAt != 99 || history["d"].LastAwardAt != 0 {
		t.Fatal("award time not recorded only for the podium")
	}
	home := t.TempDir()
	last := &sseTournament{FinishedAt: 99, Podium: []string{"b", "a"}, Colos: []sseColo{{Location: "NRT", LatencyMs: 228, Nodes: 12}}}
	if err := writeSSEHistory(home, history, last); err != nil {
		t.Fatal(err)
	}
	loaded, tournament, err := readSSEHistory(home)
	if err != nil || loaded["a"].Score != 10 || loaded["a"].Latest.LatencyMs != 180 || tournament == nil || tournament.Podium[0] != "b" {
		t.Fatal("scores or the last tournament did not survive restart")
	}
	if err := writeSSEHistory(home, loaded, tournament); err != nil {
		t.Fatal("atomic replacement failed", err)
	}
}

func TestSSEColosRankByTheMedianOfTheirNodes(t *testing.T) {
	results := []ssebench.Result{
		{Status: "done", Location: "SIN", LatencyMs: 290},
		{Status: "done", Location: "SIN", LatencyMs: 150},
		{Status: "done", Location: "SIN", LatencyMs: 300},
		{Status: "done", Location: "NRT", LatencyMs: 230},
		{Status: "done", Location: "NRT", LatencyMs: 220},
		{Status: "done", Location: "LAX", LatencyMs: 340},
		{Status: "blocked", Location: "HKG", LatencyMs: 90},
		{Status: "done", LatencyMs: 10},
	}
	colos := rankColos(results)
	if len(colos) != 3 || colos[0].Location != "NRT" || colos[0].LatencyMs != 225 || colos[0].Nodes != 2 || colos[1].Location != "SIN" || colos[1].LatencyMs != 290 {
		t.Fatalf("got %+v", colos)
	}
}

func TestSSEAllProfilesDeduplicateWithoutLosingMembership(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, "profiles"), 0700)
	for _, id := range []string{"1", "2"} {
		if err := os.WriteFile(filepath.Join(home, "profiles", id+".yaml"), []byte("proxies:\n  - {name: node-"+id+", type: socks5, server: 127.0.0.1, port: 19090}\nproxy-groups:\n  - {name: SELECT, type: select, proxies: [node-"+id+"]}\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	result := loadSSECatalog(context.Background(), home, &SSEParams{Profiles: []int64{1, 2, 3}})
	if len(result.Nodes) != 1 || len(result.Nodes[0].Aliases) != 2 || len(result.Issues) != 1 {
		t.Fatalf("lost profiles: %+v", result)
	}
	for _, a := range result.Nodes[0].Aliases {
		if a.Selections["SELECT"] != a.Name {
			t.Fatal("startup selection mismatch")
		}
	}
	encoded, _ := json.Marshal(result)
	if contains := string(encoded); len(contains) == 0 {
		t.Fatal("empty result")
	}
	corrupt := []byte("not-json")
	path := filepath.Join(home, sseHistoryFile)
	os.WriteFile(path, corrupt, 0600)
	result = loadSSECatalog(context.Background(), home, &SSEParams{Profiles: []int64{1}})
	after, _ := os.ReadFile(path)
	if result.Error == "" || string(after) != string(corrupt) {
		t.Fatal("corrupt history must be preserved and reported")
	}
}
