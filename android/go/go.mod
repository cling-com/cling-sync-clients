module github.com/flunderpero/cling-sync-android/go-bridge

go 1.24.2

require (
	github.com/flunderpero/cling-sync/http v0.0.0
	github.com/flunderpero/cling-sync/lib v0.0.0
	github.com/flunderpero/cling-sync/workspace v0.0.0
)

require (
	golang.org/x/crypto v0.37.0 // indirect
	golang.org/x/sys v0.32.0 // indirect
)

replace github.com/flunderpero/cling-sync/workspace v0.0.0 => ../../../cling-sync/workspace

replace github.com/flunderpero/cling-sync/lib v0.0.0 => ../../../cling-sync/lib

replace github.com/flunderpero/cling-sync/http v0.0.0 => ../../../cling-sync/http
