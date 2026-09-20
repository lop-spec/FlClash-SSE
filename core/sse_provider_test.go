package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestSSEProviderFiltersOverridesAndSelectionPaths(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, "profiles"), 0700)
	const config = `proxy-providers:
  subscription:
    type: inline
    filter: ^keep
    override:
      additional-prefix: "SSE-"
      udp: true
    payload:
      - {name: keep-1, type: socks5, server: localhost, port: 1080}
      - {name: reject-1, type: socks5, server: localhost, port: 1081}
proxy-groups:
  - {name: Inner, type: select, use: [subscription]}
  - {name: Outer, type: select, proxies: [Inner]}
  - {name: Auto, type: url-test, use: [subscription]}
`
	os.WriteFile(filepath.Join(home, "profiles", "1.yaml"), []byte(config), 0600)
	result := loadSSECatalog(context.Background(), home, &SSEParams{Profiles: []int64{1}})
	if len(result.Nodes) != 1 || len(result.Issues) != 0 {
		t.Fatalf("provider catalog: %+v", result)
	}
	node := result.Nodes[0]
	choices := node.Aliases[0].Selections
	if node.Name != "SSE-keep-1" || node.Config["udp"] != true || choices["Inner"] != node.Name || choices["Outer"] != "Inner" {
		t.Fatalf("provider mapping differs from runtime: %+v", node)
	}
	if _, changed := choices["Auto"]; changed {
		t.Fatal("startup must not override automatic policy groups")
	}
}

func TestSSEProviderInvalidRegexIsVisible(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, "profiles"), 0700)
	os.WriteFile(filepath.Join(home, "profiles", "1.yaml"), []byte("proxy-providers:\n  bad: {type: inline, filter: '[broken', payload: []}\n"), 0600)
	result := loadSSECatalog(context.Background(), home, &SSEParams{Profiles: []int64{1}})
	if len(result.Issues) != 1 || len(result.Nodes) != 0 {
		t.Fatal("invalid filters must be visible, not silently ignored")
	}
}
