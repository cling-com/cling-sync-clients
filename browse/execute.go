// The embedded protocol of the browse web UI: the apps' cgo/JNI glue
// forwards `(command, paramsJSON)` pairs here, mirroring the bridge
// package's JSON command pattern. Repository access lives in
// internal/session, the views in internal/web; cmd/cling-browse serves the
// same views over real HTTP instead.
package browse

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
	"github.com/flunderpero/cling-sync-clients/browse/internal/auth"
	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
)

var executeRegistry = newRegistry() //nolint:gochecknoglobals

func Execute(command string, paramsJSON string) (result string) {
	defer func() {
		if r := recover(); r != nil {
			result = errorResponse(fmt.Sprintf("panic: %v", r), "")
		}
	}()
	switch command {
	case "open":
		return executeOpen(paramsJSON)
	case "call":
		return executeCall(paramsJSON)
	case "download":
		return executeDownload(paramsJSON)
	case "close":
		return executeClose(paramsJSON)
	case "closeAll":
		return executeCloseAll()
	default:
		return errorResponse("Unknown command: "+command, "")
	}
}

func executeOpen(paramsJSON string) string {
	var params struct {
		WorkspacePath string `json:"workspacePath"`
		RepositoryURI string `json:"repositoryUri"`
		Passphrase    string `json:"passphrase"`
		PathPrefix    string `json:"pathPrefix"`
		TmpDir        string `json:"tmpDir"`
	}
	if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
		return errorResponse("Failed to parse parameters: "+err.Error(), "")
	}
	if params.TmpDir == "" {
		return errorResponse("tmpDir is required", "")
	}
	if (params.WorkspacePath == "") == (params.RepositoryURI == "") {
		return errorResponse("exactly one of workspacePath or repositoryUri is required", "")
	}
	pathPrefix, err := workspace.ValidatePathPrefix(params.PathPrefix)
	if err != nil {
		return errorResponse(err.Error(), "")
	}
	epoch := executeRegistry.currentEpoch()
	tmpDir, err := os.MkdirTemp(params.TmpDir, "browse-")
	if err != nil {
		return errorResponse("Failed to create temp dir: "+err.Error(), "")
	}
	var passphrase []byte
	if params.Passphrase != "" {
		passphrase = []byte(params.Passphrase)
	}
	ctx := context.Background()
	var sess *session.Session
	tmpFS := lib.NewRealFS(tmpDir)
	if params.WorkspacePath != "" {
		sess, err = openWorkspaceSession(ctx, params.WorkspacePath, passphrase, tmpFS)
	} else {
		sess, err = session.NewSession(ctx, params.RepositoryURI, passphrase, pathPrefix, tmpFS)
	}
	if err != nil {
		_ = os.RemoveAll(tmpDir)
		if errors.Is(err, auth.ErrPassphraseRequired) {
			return errorResponse(err.Error(), "passphrase_required")
		}
		return errorResponse(err.Error(), "")
	}
	handle, err := executeRegistry.add(sess, tmpDir, epoch)
	if err != nil {
		return errorResponse(err.Error(), "")
	}
	return marshalResponse(struct {
		Handle int `json:"handle"`
	}{handle})
}

// Open the repository referenced by a local workspace, like the cling-sync
// CLI does: open the workspace, read its saved passphrase when the app sent
// none (that is the protocol's way of using the stored credentials), and
// open the repository it points at.
func openWorkspaceSession(
	ctx context.Context,
	workspacePath string,
	passphrase []byte,
	tmpFS lib.FS,
) (*session.Session, error) {
	wsTmpFS, err := tmpFS.MkSub("workspace")
	if err != nil {
		return nil, fmt.Errorf("failed to create workspace temp dir: %w", err)
	}
	ws, err := workspace.OpenWorkspace(ctx, lib.NewRealFS(workspacePath), wsTmpFS)
	if err != nil {
		return nil, fmt.Errorf("failed to open workspace %q: %w", workspacePath, err)
	}
	defer ws.Close() //nolint:errcheck
	if passphrase == nil {
		if passphrase, err = auth.ReadSavedPassphrase(ctx, ws); err != nil {
			return nil, err
		}
	}
	return session.NewSession(ctx, string(ws.RemoteRepository), passphrase, ws.PathPrefix, tmpFS)
}

func executeCall(paramsJSON string) string {
	var params struct {
		Handle int    `json:"handle"`
		Target string `json:"target"`
	}
	if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
		return errorResponse("Failed to parse parameters: "+err.Error(), "")
	}
	result, err := executeRegistry.call(params.Handle, params.Target)
	if err != nil {
		return errorResponse(err.Error(), "")
	}
	// Error responses must never reach the page as insertable HTML, so they
	// travel as protocol errors, exactly like a rejected fetch in the browser.
	if result.status >= http.StatusBadRequest {
		return errorResponse(strings.TrimSpace(string(result.body)), "")
	}
	return marshalResponse(struct {
		Body string `json:"body"`
	}{string(result.body)})
}

func executeDownload(paramsJSON string) string {
	var params struct {
		Handle   int    `json:"handle"`
		Path     string `json:"path"`
		DestPath string `json:"destPath"`
	}
	if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
		return errorResponse("Failed to parse parameters: "+err.Error(), "")
	}
	if err := executeRegistry.downloadTo(params.Handle, params.Path, params.DestPath); err != nil {
		return errorResponse(err.Error(), "")
	}
	return `{"success":true}`
}

func executeClose(paramsJSON string) string {
	var params struct {
		Handle int `json:"handle"`
	}
	if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
		return errorResponse("Failed to parse parameters: "+err.Error(), "")
	}
	if err := executeRegistry.close(params.Handle); err != nil {
		return errorResponse(err.Error(), "")
	}
	return `{"success":true}`
}

// Close every open session, e.g. when the app drops its decrypted state
// after a while in the background.
func executeCloseAll() string {
	if err := executeRegistry.closeAll(); err != nil {
		return errorResponse(err.Error(), "")
	}
	return `{"success":true}`
}

func errorResponse(message, code string) string {
	response := struct {
		Error struct {
			Message string `json:"message"`
			Code    string `json:"code,omitempty"`
		} `json:"error"`
	}{}
	response.Error.Message = message
	response.Error.Code = code
	return marshalResponse(response)
}

func marshalResponse(v any) string {
	jsonBytes, err := json.Marshal(v)
	if err != nil {
		return `{"error": {"message": "Failed to marshal response"}}`
	}
	return string(jsonBytes)
}
