package zerotier

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Multi-network config (network-ids list + legacy network-id compat).

func TestAllNetworkIDsMergeDedupe(t *testing.T) {
	c := &Config{
		NetworkIDs: []string{" B6079F73C6C0EB31 ", "8056c2e21c000001", "b6079f73c6c0eb31", ""},
		NetworkID:  "8056c2e21c000001", // duplicate of list entry
	}
	got := c.AllNetworkIDs()
	want := []string{"b6079f73c6c0eb31", "8056c2e21c000001"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("AllNetworkIDs=%v want %v", got, want)
	}
}

func TestAllNetworkIDsLegacyFallback(t *testing.T) {
	c := &Config{NetworkID: "b6079f73c6c0eb31"}
	got := c.AllNetworkIDs()
	want := []string{"b6079f73c6c0eb31"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("AllNetworkIDs=%v want %v", got, want)
	}
	if !c.Enabled() {
		t.Fatal("legacy single-id config must be Enabled")
	}
}

func TestAllNetworkIDsEmpty(t *testing.T) {
	var c *Config
	if ids := c.AllNetworkIDs(); len(ids) != 0 {
		t.Fatalf("nil config must yield no ids, got %v", ids)
	}
	if c.Enabled() {
		t.Fatal("nil config must not be Enabled")
	}
	e := &Config{}
	if e.Enabled() {
		t.Fatal("empty config must not be Enabled")
	}
}

func TestLoadConfigNetworkIDs(t *testing.T) {
	dir := t.TempDir()
	raw := []byte(`{"network-ids":["b6079f73c6c0eb31","8056c2e21c000001"]}`)
	if err := os.WriteFile(filepath.Join(dir, ConfigFileName), raw, 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	got := cfg.AllNetworkIDs()
	want := []string{"b6079f73c6c0eb31", "8056c2e21c000001"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("AllNetworkIDs=%v want %v", got, want)
	}
	if !cfg.Enabled() {
		t.Fatal("multi-id config must be Enabled")
	}
}

func TestLoadConfigLegacyAndMultiMerged(t *testing.T) {
	// Old configs may still carry network-id; it must be merged in.
	dir := t.TempDir()
	raw := []byte(`{"network-ids":["b6079f73c6c0eb31"],"network-id":"8056c2e21c000001"}`)
	if err := os.WriteFile(filepath.Join(dir, ConfigFileName), raw, 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	got := cfg.AllNetworkIDs()
	want := []string{"b6079f73c6c0eb31", "8056c2e21c000001"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("AllNetworkIDs=%v want %v", got, want)
	}
}
