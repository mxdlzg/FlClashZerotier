//go:build cgo

package main

import (
	"os"
	"path/filepath"

	"core/zerotier"
	"github.com/metacubex/mihomo/constant"
)

func zerotierFileExists(homeDir, name string) bool {
	_, err := os.Stat(filepath.Join(homeDir, name))
	return err == nil
}

func handleGetZeroTierStatus(response MethodResponse) {
	homeDir := constant.Path.HomeDir()
	out := map[string]any{
		"configured":        false,
		"route-mode":        "",
		"use-custom-planet": false,
		"planet-exists":     zerotierFileExists(homeDir, zerotier.CustomPlanetFileName),
		"identity-exists":   zerotierFileExists(homeDir, zerotier.IdentityFileName),
	}
	cfg, err := zerotier.LoadConfig(homeDir)
	if err == nil && cfg.Enabled() {
		out["configured"] = true
		out["route-mode"] = string(cfg.RouteMode)
		out["use-custom-planet"] = cfg.UseCustomPlanet
	}
	st := zerotier.GetStatus()
	out["state"] = st.State
	out["node"] = st.Node
	out["udp-port"] = st.UdpPort
	out["networks"] = st.Networks
	response.success(out)
}
