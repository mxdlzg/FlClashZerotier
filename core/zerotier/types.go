package zerotier

import (
	"errors"
	"net/netip"
)

// Common errors returned by the adapter / engine.
var (
	ErrNoNode     = errors.New("zerotier: node not running")
	ErrNoConfig   = errors.New("zerotier: no network config")
	ErrNoRoute    = errors.New("zerotier: destination not in a managed route")
	ErrNoLocal    = errors.New("zerotier: no assigned address for this address family")
	ErrEmptyFrame = errors.New("zerotier: empty frame")
)

// Route is one ZeroTier managed route (from the config snapshot).
// Nwid identifies the network that pushed this route (multi-network):
// the adapter uses it to pick that network's MAC/assigned IP for sending.
type Route struct {
	Nwid   uint64
	Prefix netip.Prefix
	Via    netip.Addr // invalid = direct
	Flags  uint16
	Metric uint16
}

// HasGateway reports whether the route forwards via a gateway.
func (r Route) HasGateway() bool { return r.Via.IsValid() }

// AssignedAddr is an IP assigned to this node by the network controller.
type AssignedAddr struct {
	Addr netip.Addr
	Bits int
}

// Snapshot is a Go view of the latest ZT network config callback.
type Snapshot struct {
	Nwid     uint64
	Status   int
	Mac      uint64
	MTU      int
	Assigned []AssignedAddr
	Routes   []Route
}

// Frame is one Ethernet frame received from the ZT network.
type Frame struct {
	Nwid      uint64
	SrcMAC    uint64
	DstMAC    uint64
	EtherType uint16
	VlanID    uint16
	Data      []byte
}

// FrameSender is the engine surface the adapter needs. Defined as an
// interface so adapter.go stays pure Go (no cgo) and is unit-testable.
type FrameSender interface {
	// Snapshots returns one snapshot per joined network.
	Snapshots() []Snapshot
	// SnapshotFor returns the snapshot of one network (ok=false when the
	// network is not (yet) configured, e.g. still REQUESTING_CONFIGURATION).
	SnapshotFor(nwid uint64) (Snapshot, bool)
	// MatchRoute returns the managed route covering addr (nil if none).
	// Route.Nwid is the network that owns the route.
	MatchRoute(addr netip.Addr) *Route
	// SendFrame sends an Ethernet frame into the ZT network.
	SendFrame(f Frame) error
	// SubscribeMulticast joins a multicast group on a network.
	// adi is the ZeroTier multicast ADI (IPv4 ARP groups use the target IP
	// as a big-endian uint32; 0 otherwise).
	SubscribeMulticast(nwid, mac uint64, adi uint32) error
}
