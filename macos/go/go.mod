module github.com/flunderpero/cling-sync-clients/go-bridge-macos

go 1.26.5

require github.com/flunderpero/cling-sync-clients/bridge v0.0.0

require (
	github.com/cling-com/cling-sync v0.0.3
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)

replace github.com/flunderpero/cling-sync-clients/bridge v0.0.0 => ../../bridge
