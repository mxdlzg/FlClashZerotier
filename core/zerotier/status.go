//go:build cgo

package zerotier

import "fmt"

// NetworkStatus is the JSON-facing view of one joined network's live state.
type NetworkStatus struct {
	Nwid     string   `json:"nwid"`
	Status   int      `json:"status"`
	Assigned []string `json:"assigned"`
	Routes   []string `json:"routes"`
}

// StatusInfo is the JSON-facing core status snapshot for the settings UI.
type StatusInfo struct {
	State    string          `json:"state"`
	Node     string          `json:"node"`
	UdpPort  int             `json:"udp-port"`
	Networks []NetworkStatus `json:"networks"`
}

// GetStatus returns the current engine + per-network state. Safe to call at
// any time; returns state STOPPED (with empty networks) when no engine exists.
func GetStatus() StatusInfo {
	e := currentEngine()
	if e == nil {
		return StatusInfo{State: StateStopped.String()}
	}
	st := e.getState()
	info := StatusInfo{State: st.String()}
	if st != StateRunning {
		return info
	}
	info.Node = fmt.Sprintf("%010x", e.nodeAddress())
	info.UdpPort = e.boundPort()
	for _, s := range e.Snapshots() {
		ns := NetworkStatus{
			Nwid:   fmt.Sprintf("%016x", s.Nwid),
			Status: s.Status,
		}
		for _, a := range s.Assigned {
			ns.Assigned = append(ns.Assigned, fmt.Sprintf("%s/%d", a.Addr.String(), a.Bits))
		}
		for _, r := range s.Routes {
			ns.Routes = append(ns.Routes, r.Prefix.String())
		}
		info.Networks = append(info.Networks, ns)
	}
	return info
}
