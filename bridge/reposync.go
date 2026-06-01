// Repo-sync: mirror a workspace's repository to one or more backup
// repositories ("sync targets"). Thin wrappers over the cling-sync `workspace`
// package.
package bridge

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"sync"

	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
	"github.com/flunderpero/cling-sync/workspace"
)

var (
	ErrSyncAlreadyRunning = lib.Errorf("sync already running")
	ErrSyncNotRunning     = lib.Errorf("sync not running")
	ErrNoSyncTargets      = lib.Errorf("no sync targets registered")
)

const defaultSyncWorkers = 2

// -----------------------------------------------------------------------------
// Sync targets
// -----------------------------------------------------------------------------

// SyncTargetInfo is a registered sync target. DisplayURI has any S3 credential
// blob stripped, safe to show in the UI.
type SyncTargetInfo struct {
	Name       string `json:"name"`
	URI        string `json:"uri"`
	DisplayURI string `json:"displayUri"`
}

func ListWorkspaceSyncTargets(localPath string) ([]SyncTargetInfo, error) {
	var infos []SyncTargetInfo
	err := withWorkspace(localPath, func(ws *workspace.Workspace) error {
		targets, err := workspace.LoadSyncTargets(context.Background(), ws)
		if err != nil {
			return lib.WrapErrorf(err, "failed to load sync targets")
		}
		infos = make([]SyncTargetInfo, len(targets))
		for i, t := range targets {
			infos[i] = SyncTargetInfo{Name: t.Name, URI: t.URI, DisplayURI: displaySyncURI(t.URI)}
		}
		return nil
	})
	return infos, err
}

// AddWorkspaceSyncTarget registers a target. The target repository must already
// exist and share the workspace repository's configuration. S3 target URLs must
// carry their encrypted credentials. `password` is only needed when the source
// or target is S3 (to decrypt the embedded credentials).
func AddWorkspaceSyncTarget(localPath, name, rawURI, password string) error {
	if err := workspace.ValidateSyncTargetName(name); err != nil {
		return err //nolint:wrapcheck
	}
	targetURI, err := normalizeSyncTargetURI(rawURI)
	if err != nil {
		return err
	}
	return withWorkspace(localPath, func(ws *workspace.Workspace) error {
		var passphrase []byte
		if clinghttp.IsS3StorageURI(string(ws.RemoteRepository)) || clinghttp.IsS3StorageURI(targetURI) {
			passphrase, err = workspacePassphrase(ws, password)
			if err != nil {
				return err
			}
		}
		if err := workspace.AddSyncTarget(context.Background(), ws, name, targetURI, passphrase); err != nil {
			return lib.WrapErrorf(err, "failed to add sync target")
		}
		return nil
	})
}

// DeleteWorkspaceSyncTarget unregisters a target. The target storage is kept.
func DeleteWorkspaceSyncTarget(localPath, name string) error {
	return withWorkspace(localPath, func(ws *workspace.Workspace) error {
		if err := workspace.DeleteSyncTarget(context.Background(), ws, name); err != nil {
			return lib.WrapErrorf(err, "failed to delete sync target")
		}
		return nil
	})
}

func normalizeSyncTargetURI(uri string) (string, error) {
	uri = strings.TrimSpace(uri)
	if uri == "" {
		return "", lib.Errorf("sync target repository must not be empty")
	}
	if err := clinghttp.RejectBareHTTPURI(uri); err != nil {
		return "", err //nolint:wrapcheck
	}
	if clinghttp.IsS3StorageURI(uri) {
		if !clinghttp.S3URIHasEmbeddedCredentials(uri) {
			return "", lib.Errorf("S3 sync target URLs must include the encrypted credentials")
		}
		return uri, nil
	}
	// The bridge runs in-process inside the GUI app where the working directory
	// is meaningless, so a relative path would resolve to a surprising location.
	if !filepath.IsAbs(uri) {
		return "", lib.Errorf("sync target folder path must be absolute: %s", uri)
	}
	return filepath.Clean(uri), nil
}

// displaySyncURI strips the encrypted credential blob from an S3 URI for the UI.
func displaySyncURI(uri string) string {
	const prefix = "s3+"
	if !strings.HasPrefix(uri, prefix) {
		return uri
	}
	u, err := url.Parse(strings.TrimPrefix(uri, prefix))
	if err != nil || u.User == nil {
		return uri
	}
	u.User = nil
	return prefix + u.String()
}

// -----------------------------------------------------------------------------
// Running a sync
// -----------------------------------------------------------------------------

//nolint:gochecknoglobals,exhaustruct
var syncWorkspaceStateStore = struct {
	mu     sync.Mutex
	states map[string]*mergeWorkspaceState
}{states: map[string]*mergeWorkspaceState{}}

// StartSyncWorkspace begins mirroring the workspace repository to every
// registered target in the background, copying `workers` blocks in parallel.
func StartSyncWorkspace(localPath, password string, workers int) error {
	localPath = normalizeWorkspacePath(localPath)
	if workers < 1 {
		workers = defaultSyncWorkers
	}
	passphrase, err := verifySyncAccess(localPath, password)
	if err != nil {
		return err
	}

	syncWorkspaceStateStore.mu.Lock()
	if state := syncWorkspaceStateStore.states[localPath]; state != nil && state.snapshot().Running {
		syncWorkspaceStateStore.mu.Unlock()
		return ErrSyncAlreadyRunning
	}
	state := &mergeWorkspaceState{status: MergeWorkspaceStatus{ //nolint:exhaustruct
		Running:       true,
		CanCancel:     true,
		StatusMessage: "Preparing sync...",
	}}
	syncWorkspaceStateStore.states[localPath] = state
	syncWorkspaceStateStore.mu.Unlock()

	go runSyncWorkspace(localPath, passphrase, workers, state)
	return nil
}

// verifySyncAccess confirms targets exist and that the passphrase opens the
// repository, returning the resolved passphrase so the background job does not
// have to flow the raw password string around.
func verifySyncAccess(localPath, password string) ([]byte, error) {
	var passphrase []byte
	err := withWorkspace(localPath, func(ws *workspace.Workspace) error {
		targets, err := workspace.LoadSyncTargets(context.Background(), ws)
		if err != nil {
			return lib.WrapErrorf(err, "failed to load sync targets")
		}
		if len(targets) == 0 {
			return ErrNoSyncTargets
		}
		passphrase, err = workspacePassphrase(ws, password)
		if err != nil {
			return err
		}
		storage, err := openWorkspaceStorage(ws, passphrase)
		if err != nil {
			return err
		}
		if _, err := lib.OpenRepository(context.Background(), storage, passphrase); err != nil {
			if password == "" {
				return ErrPassphraseRequired
			}
			return lib.WrapErrorf(err, "failed to open repository")
		}
		return nil
	})
	return passphrase, err
}

// CancelSyncWorkspace requests that an in-progress sync abort. Cancellation is
// delivered through the sync context; the copy stops at the next block boundary
// and the target head is left untouched.
func CancelSyncWorkspace(localPath string) error {
	localPath = normalizeWorkspacePath(localPath)
	syncWorkspaceStateStore.mu.Lock()
	state := syncWorkspaceStateStore.states[localPath]
	syncWorkspaceStateStore.mu.Unlock()
	if state == nil || !state.snapshot().Running {
		return ErrSyncNotRunning
	}
	state.requestCancel()
	state.setStatus(MergeWorkspaceStatus{ //nolint:exhaustruct
		Running:       true,
		CanCancel:     false,
		StatusMessage: "Aborting sync...",
	})
	return nil
}

func GetSyncWorkspaceStatus(localPath string) MergeWorkspaceStatus {
	localPath = normalizeWorkspacePath(localPath)
	syncWorkspaceStateStore.mu.Lock()
	state := syncWorkspaceStateStore.states[localPath]
	syncWorkspaceStateStore.mu.Unlock()
	if state == nil {
		return MergeWorkspaceStatus{}
	}
	return state.snapshot()
}

func runSyncWorkspace(localPath string, passphrase []byte, workers int, state *mergeWorkspaceState) {
	summary, err := syncWorkspace(localPath, passphrase, workers, state)
	status := MergeWorkspaceStatus{Completed: true} //nolint:exhaustruct
	switch {
	case errors.Is(err, lib.ErrCancel):
		status.Cancelled = true
		status.StatusMessage = "Sync aborted"
	case err != nil:
		status.StatusMessage = "Sync failed"
		status.ErrorMessage = err.Error()
	default:
		status.StatusMessage = summary
	}
	state.setStatus(status)
}

func syncWorkspace(
	localPath string, passphrase []byte, workers int, state *mergeWorkspaceState,
) (summary string, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = lib.Errorf("panic: %v", r)
		}
	}()
	err = withWorkspace(localPath, func(ws *workspace.Workspace) error {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		state.setCancelCtx(cancel)
		defer state.setCancelCtx(nil)

		targets, err := workspace.LoadSyncTargets(ctx, ws)
		if err != nil {
			return lib.WrapErrorf(err, "failed to load sync targets")
		}
		if len(targets) == 0 {
			return ErrNoSyncTargets
		}

		monitor := newSyncMonitor(state)
		failures := 0
		for _, t := range targets {
			if state.isCancelRequested() {
				return lib.ErrCancel
			}
			state.setRunningMessage("Syncing to " + t.Name + "...")
			state.appendOutput(fmt.Sprintf("→ %s (%s) [%d workers]", t.Name, displaySyncURI(t.URI), workers))
			runErr := workspace.RunSync(ctx, ws, t.Name, monitor, passphrase, workers)
			if runErr != nil && state.isCancelRequested() {
				// Cancellation cancels ctx, which surfaces as a RunSync error.
				return lib.ErrCancel
			}
			if runErr != nil {
				failures++
				state.appendOutput("  failed: " + runErr.Error())
			} else {
				state.appendOutput("  done")
			}
		}
		if failures > 0 {
			return lib.Errorf("%d of %d sync target(s) failed", failures, len(targets))
		}
		if len(targets) == 1 {
			summary = "Synced " + targets[0].Name
		} else {
			summary = fmt.Sprintf("Synced %d targets", len(targets))
		}
		return nil
	})
	return summary, err
}

// -----------------------------------------------------------------------------
// Progress monitor
// -----------------------------------------------------------------------------

// asyncSyncRepoMonitor fans every progress event out to a progress monitor
// (single-line status) and a verbose monitor (detailed log). Abort is handled
// via context cancellation, not here, because lib.SyncRepository copies blocks
// on worker goroutines.
type asyncSyncRepoMonitor struct {
	progress *workspace.DefaultSyncRepoMonitor
	verbose  *workspace.DefaultSyncRepoMonitor
}

func newSyncMonitor(state *mergeWorkspaceState) *asyncSyncRepoMonitor {
	return &asyncSyncRepoMonitor{
		progress: workspace.NewDefaultSyncRepoMonitor(
			workspace.DefaultMonitorModeProgress,
			func(text string) { state.setRunningMessage(text) },
		),
		verbose: workspace.NewDefaultSyncRepoMonitor(
			workspace.DefaultMonitorModeVerbose,
			func(text string) { state.appendOutput(text) },
		),
	}
}

func (m *asyncSyncRepoMonitor) OnSrcBlockIdsRead(blocksTotal int) {
	m.verbose.OnSrcBlockIdsRead(blocksTotal)
	m.progress.OnSrcBlockIdsRead(blocksTotal)
}

func (m *asyncSyncRepoMonitor) OnDstBlockIdsRead(blocksTotal int) {
	m.verbose.OnDstBlockIdsRead(blocksTotal)
	m.progress.OnDstBlockIdsRead(blocksTotal)
}

func (m *asyncSyncRepoMonitor) OnBeforeCopy(srcBlocks, dstBlocks int) {
	m.verbose.OnBeforeCopy(srcBlocks, dstBlocks)
	m.progress.OnBeforeCopy(srcBlocks, dstBlocks)
}

func (m *asyncSyncRepoMonitor) OnCopyBlock(blockID lib.BlockId, existed bool, length int) {
	m.verbose.OnCopyBlock(blockID, existed, length)
	m.progress.OnCopyBlock(blockID, existed, length)
}

func (m *asyncSyncRepoMonitor) OnBeforeUpdateDstHead(newHead lib.RevisionId) {
	m.verbose.OnBeforeUpdateDstHead(newHead)
	m.progress.OnBeforeUpdateDstHead(newHead)
}
