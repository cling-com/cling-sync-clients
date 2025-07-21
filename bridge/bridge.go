// Bridge between Go and native code.
//
// We chose to implement a JSON-based command pattern protocol to ease the integration
// with any native code.

package bridge

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/flunderpero/cling-sync/lib"
)

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
		// Decode and unmarshal each entry
		entries := make([]*lib.RevisionEntry, 0, len(params.RevisionEntries))
		for _, entryBase64 := range params.RevisionEntries {
			entryBytes, err := base64.StdEncoding.DecodeString(entryBase64)
			if err != nil {
				return errorResponse("Failed to decode base64 entry: " + err.Error())
			}

			// Unmarshal from bytes
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
