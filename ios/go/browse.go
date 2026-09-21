package main

import "C"

import (
	"github.com/flunderpero/cling-sync-clients/browse"
)

//export GoBrowse
func GoBrowse(cmd *C.char, params *C.char) *C.char {
	command := C.GoString(cmd)
	paramsJSON := C.GoString(params)
	result := browse.Execute(command, paramsJSON)
	return C.CString(result)
}
