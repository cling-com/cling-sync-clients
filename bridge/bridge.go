// Bridge between Go and native code.
//
// We chose to implement a JSON-based command pattern protocol to ease the integration
// with any native code.

package bridge

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/flunderpero/cling-sync/lib"
)

func Execute(command string, paramsJSON string) (result string) { //nolint:funlen
	// Recover from panics and convert them to error responses
	defer func() {
		if r := recover(); r != nil {
			// Convert panic to error response
			errMsg := fmt.Sprintf("panic: %v", r)
			result = errorResponse(errMsg)
		}
	}()

	switch command {
	case "checkRepositoryOpen":
		var params struct {
			HostURL string `json:"hostUrl"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		response := struct {
			Open           bool   `json:"open"`
			HeadRevisionID string `json:"headRevisionId"`
		}{Open: CheckRepositoryOpen(params.HostURL), HeadRevisionID: GetRepositoryHeadRevisionID()}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "openRepository":
		var params struct {
			HostURL  string `json:"hostUrl"`
			Password string `json:"password"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		err := OpenRepository(params.HostURL, params.Password)
		if err != nil {
			return errorResponse(err.Error())
		}
		response := struct {
			HeadRevisionID string `json:"headRevisionId"`
		}{HeadRevisionID: GetRepositoryHeadRevisionID()}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "checkFiles":
		var params struct {
			Sha256s []string `json:"sha256s"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		sha256s := make([]lib.Sha256, len(params.Sha256s))
		for i, s := range params.Sha256s {
			sha256, err := hex.DecodeString(s)
			if err != nil {
				return errorResponse("Failed to decode SHA256 hash: " + err.Error())
			}
			if len(sha256) != 32 {
				return errorResponse("Invalid SHA256 hash length: " + s)
			}
			sha256s[i] = lib.Sha256(sha256)
		}
		res, err := CheckFiles(sha256s)
		if err != nil {
			return errorResponse(err.Error())
		}
		response := struct {
			Results []string `json:"results"`
		}{Results: res}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "uploadFile":
		var params struct {
			LocalFilePath string `json:"localFilePath"`
			RepoFilePath  string `json:"repoFilePath"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		entry, uploaded, err := UploadFile(params.LocalFilePath, params.RepoFilePath)
		if err != nil {
			return errorResponse(err.Error())
		}
		if !uploaded {
			response := struct {
				RevisionEntry string `json:"revisionEntry"`
				Skipped       bool   `json:"skipped"`
			}{RevisionEntry: "", Skipped: true}
			jsonBytes, err := json.Marshal(response)
			if err != nil {
				return errorResponse("Failed to marshal response: " + err.Error())
			}
			return string(jsonBytes)
		}
		w := lib.NewProtobufWriter(make([]byte, entry.MarshallSize()+64))
		if err := entry.Marshall(w); err != nil {
			return errorResponse("Failed to marshal revision entry: " + err.Error())
		}

		// Encode as base64
		entryBase64 := base64.StdEncoding.EncodeToString(w.Bytes())

		response := struct {
			RevisionEntry string `json:"revisionEntry"`
			Skipped       bool   `json:"skipped"`
		}{RevisionEntry: entryBase64, Skipped: false}
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

			entry, err := lib.UnmarshallRevisionEntry(lib.NewProtobufReader(entryBytes))
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
	case "checkFileRepositoryExists":
		var params struct {
			LocalPath string `json:"localPath"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		exists, err := CheckFileRepositoryExists(params.LocalPath)
		if err != nil {
			return errorResponse(err.Error())
		}
		response := struct {
			Exists bool `json:"exists"`
		}{Exists: exists}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "initNewFileRepository":
		var params struct {
			LocalPath string `json:"localPath"`
			Password  string `json:"password"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		if err := InitNewFileRepository(params.LocalPath, params.Password); err != nil {
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
	case "configureWorkspace":
		var params struct {
			HostURL        string `json:"hostUrl"`
			LocalPath      string `json:"localPath"`
			RepoPathPrefix string `json:"repoPathPrefix"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		err := EnsureWorkspaceConfigured(params.HostURL, params.LocalPath, params.RepoPathPrefix)
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
	case "inspectWorkspace":
		var params struct {
			LocalPath string `json:"localPath"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		info, err := InspectWorkspace(params.LocalPath)
		if err != nil {
			return errorResponse(err.Error())
		}
		jsonBytes, err := json.Marshal(info)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "storeWorkspacePassphrase":
		var params struct {
			LocalPath string `json:"localPath"`
			Password  string `json:"password"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		if err := SaveWorkspacePassphrase(params.LocalPath, params.Password); err != nil {
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
	case "clearWorkspacePassphrase":
		var params struct {
			HostURL string `json:"hostUrl"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		if err := ClearWorkspacePassphrase(params.HostURL); err != nil {
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
	case "testWorkspaceAccess":
		var params struct {
			LocalPath string `json:"localPath"`
			Password  string `json:"password"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		if err := TestWorkspaceAccess(params.LocalPath, params.Password); err != nil {
			if errors.Is(err, ErrPassphraseRequired) {
				return errorResponseWithCode(err.Error(), "passphrase_required")
			}
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
	case "mergeWorkspace":
		var params struct {
			LocalPath string `json:"localPath"`
			Password  string `json:"password"`
			Author    string `json:"author"`
			Message   string `json:"message"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		revisionID, upToDate, err := MergeWorkspace(params.LocalPath, params.Password, params.Author, params.Message)
		if err != nil {
			if errors.Is(err, ErrPassphraseRequired) {
				return errorResponseWithCode(err.Error(), "passphrase_required")
			}
			return errorResponse(err.Error())
		}
		response := struct {
			RevisionID string `json:"revisionId"`
			UpToDate   bool   `json:"upToDate"`
		}{RevisionID: revisionID, UpToDate: upToDate}
		jsonBytes, err := json.Marshal(response)
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "startMergeWorkspace":
		var params struct {
			LocalPath     string `json:"localPath"`
			Password      string `json:"password"`
			Author        string `json:"author"`
			Message       string `json:"message"`
			StorePassword bool   `json:"storePassword"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		err := StartMergeWorkspace(
			params.LocalPath,
			params.Password,
			params.Author,
			params.Message,
			params.StorePassword,
		)
		if err != nil {
			if errors.Is(err, ErrPassphraseRequired) {
				return errorResponseWithCode(err.Error(), "passphrase_required")
			}
			if errors.Is(err, ErrMergeAlreadyRunning) {
				return errorResponseWithCode(err.Error(), "merge_already_running")
			}
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
	case "getMergeWorkspaceStatus":
		var params struct {
			LocalPath string `json:"localPath"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		jsonBytes, err := json.Marshal(GetMergeWorkspaceStatus(params.LocalPath))
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	case "cancelMergeWorkspace":
		var params struct {
			LocalPath string `json:"localPath"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		if err := CancelMergeWorkspace(params.LocalPath); err != nil {
			if errors.Is(err, ErrMergeNotRunning) {
				return errorResponseWithCode(err.Error(), "merge_not_running")
			}
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
	case "startStatusWorkspace":
		var params struct {
			LocalPath     string `json:"localPath"`
			Password      string `json:"password"`
			StorePassword bool   `json:"storePassword"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		err := StartStatusWorkspace(params.LocalPath, params.Password, params.StorePassword)
		if err != nil {
			if errors.Is(err, ErrPassphraseRequired) {
				return errorResponseWithCode(err.Error(), "passphrase_required")
			}
			if errors.Is(err, ErrStatusAlreadyRunning) {
				return errorResponseWithCode(err.Error(), "status_already_running")
			}
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
	case "getStatusWorkspaceStatus":
		var params struct {
			LocalPath string `json:"localPath"`
		}
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			return errorResponse("Failed to parse parameters: " + err.Error())
		}
		jsonBytes, err := json.Marshal(GetStatusWorkspaceStatus(params.LocalPath))
		if err != nil {
			return errorResponse("Failed to marshal response: " + err.Error())
		}
		return string(jsonBytes)
	default:
		return errorResponse(fmt.Sprintf("Unknown command: %s", command))
	}
}

func errorResponse(message string) string {
	return errorResponseWithCode(message, "")
}

func errorResponseWithCode(message, code string) string {
	response := struct {
		Error struct {
			Message string `json:"message"`
			Code    string `json:"code,omitempty"`
		} `json:"error"`
	}{}
	response.Error.Message = message
	response.Error.Code = code

	jsonBytes, err := json.Marshal(response)
	if err != nil {
		return `{"error": {"message": "Failed to marshal response"}}`
	}
	return string(jsonBytes)
}
