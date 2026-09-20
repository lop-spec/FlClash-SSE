package main

import (
	"context"
	"core/ssebench"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSSEPreservesLastValidToks(t *testing.T) {
	good := ssebench.Result{Status: "done", Tokens: ssebench.Samples, TokPerSec: 19.1, ElapsedMs: 8400}
	old := mergeSSEResult(sseRecord{}, good)
	for _, status := range []string{"running", "timeout", "failed", "unmeasured", "unsupported", "endpoint", "measurement", "done"} {
		next := mergeSSEResult(old, ssebench.Result{Status: status})
		if next.LastSuccess == nil || next.LastSuccess.TokPerSec != 19.1 || next.MeasuredAt != old.MeasuredAt {
			t.Fatalf("%s erased history", status)
		}
	}
	good.TokPerSec = 19.4
	next := mergeSSEResult(old, good)
	if next.LastSuccess.TokPerSec != 19.4 {
		t.Fatal("valid result not updated")
	}
	home := t.TempDir()
	if err := writeSSEHistory(home, map[string]sseRecord{"k": next}); err != nil {
		t.Fatal(err)
	}
	loaded, err := readSSEHistory(home)
	if err != nil || loaded["k"].LastSuccess.TokPerSec != 19.4 {
		t.Fatal("history did not survive restart")
	}
	if err := writeSSEHistory(home, loaded); err != nil {
		t.Fatal("atomic replacement failed", err)
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
	path := filepath.Join(home, "sse-history-v1.json")
	os.WriteFile(path, corrupt, 0600)
	result = loadSSECatalog(context.Background(), home, &SSEParams{Profiles: []int64{1}})
	after, _ := os.ReadFile(path)
	if result.Error == "" || string(after) != string(corrupt) {
		t.Fatal("corrupt history must be preserved and reported")
	}
}
