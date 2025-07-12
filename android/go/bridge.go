// Bridge between Go and Android/JVM.
//
// We chose to implement a JSON-based command pattern protocol to minimize the JNI shenanigans.

package main

/*
#include "../tools/android-sdk/ndk/jni-headers/jni.h"
#include <stdlib.h>

static jstring new_string(JNIEnv *env, const char *str) {
    return (*env)->NewStringUTF(env, str);
}

static const char* get_string(JNIEnv *env, jstring str) {
    return (*env)->GetStringUTFChars(env, str, NULL);
}

static void release_string(JNIEnv *env, jstring str, const char *chars) {
    (*env)->ReleaseStringUTFChars(env, str, chars);
}
*/
import "C"

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"unsafe"

	"github.com/flunderpero/cling-sync/lib"
)

//export Java_com_clingsync_android_GoBridge_Execute
func Java_com_clingsync_android_GoBridge_Execute(
	env *C.JNIEnv,
	obj C.jobject,
	cmdStr C.jstring,
	paramsStr C.jstring,
) C.jstring {
	// Convert jstrings to Go strings.
	cmdCStr := C.get_string(env, cmdStr)
	command := C.GoString(cmdCStr)
	C.release_string(env, cmdStr, cmdCStr)
	paramsCStr := C.get_string(env, paramsStr)
	params := C.GoString(paramsCStr)
	C.release_string(env, paramsStr, paramsCStr)

	// Execute command and get result.
	result := Execute(command, params)

	// Convert result back to jstring.
	resultCStr := C.CString(result)
	defer C.free(unsafe.Pointer(resultCStr))
	return C.new_string(env, resultCStr)
}

func Execute(command string, paramsJSON string) string { //nolint:funlen
	switch command {
	case "ensureOpen":
		var params struct {
			HostURL  string `json:"hostUrl"`
			Password string `json:"password"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		err := EnsureRepositoryOpen(params.HostURL, params.Password)
		if err != nil {
			return errorResponse(err.Error())
		}
		response := struct {
			Success bool `json:"success"`
		}{Success: true}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "uploadFile":
		var params struct {
			FilePath       string `json:"filePath"`
			RepoPathPrefix string `json:"repoPathPrefix"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		entry, err := UploadFile(params.FilePath, params.RepoPathPrefix)
		if err != nil {
			return errorResponse(err.Error())
		}

		// Marshal the entry to bytes
		var buf bytes.Buffer
		if err := lib.MarshalRevisionEntry(entry, &buf); err != nil {
			return errorResponse("Failed to marshal revision entry: " + err.Error())
		}

		// Encode as base64
		entryBase64 := base64.StdEncoding.EncodeToString(buf.Bytes())

		response := struct {
			RevisionEntry string `json:"revisionEntry"`
		}{RevisionEntry: entryBase64}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "commit":
		var params struct {
			RevisionEntries []string `json:"revisionEntries"`
			Author          string   `json:"author"`
			Message         string   `json:"message"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}

		entries := make([]*lib.RevisionEntry, 0, len(params.RevisionEntries))
		for _, entryBase64 := range params.RevisionEntries {
			entryBytes, err := base64.StdEncoding.DecodeString(entryBase64)
			if err != nil {
				return errorResponse("Failed to decode base64 entry: " + err.Error())
			}
			buf := bytes.NewReader(entryBytes)
			entry, err := lib.UnmarshalRevisionEntry(buf)
			if err != nil {
				return errorResponse("Failed to unmarshal revision entry: " + err.Error())
			}

			entries = append(entries, entry)
		}

		revisionId, err := CommitEntries(entries, params.Author, params.Message)
		if err != nil {
			return errorResponse(err.Error())
		}
		response := struct {
			RevisionId string `json:"revisionId"`
		}{RevisionId: revisionId}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	default:
		return errorResponse(fmt.Sprintf("Unknown command: %s", command))
	}
}

func errorResponse(message string) string {
	response := struct { //nolint:exhaustruct
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}{}
	response.Error.Message = message

	jsonBytes, err := json.Marshal(response)
	if err != nil {
		return `{"error": {"message": "Failed to marshal response"}}`
	}
	return string(jsonBytes)
}

func main() {
}
