// Bridge between Go and iOS/Swift.
//
// We chose to implement a JSON-based command pattern protocol to ease the integration.

package main

import "C"

import (
	"github.com/flunderpero/cling-sync-clients/bridge"
)

//export GoBridge
func GoBridge(cmd *C.char, params *C.char) *C.char {
	command := C.GoString(cmd)
	paramsJSON := C.GoString(params)
	result := bridge.Execute(command, paramsJSON)
	return C.CString(result)
}

func main() {
}
