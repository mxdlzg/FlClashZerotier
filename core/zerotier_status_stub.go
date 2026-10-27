//go:build !cgo

package main

func handleGetZeroTierStatus(response MethodResponse) {
	response.success(map[string]any{
		"configured": false,
		"state":      "STOPPED",
		"networks":   []any{},
	})
}
