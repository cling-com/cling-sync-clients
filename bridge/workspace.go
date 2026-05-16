package bridge

import (
	"context"
	cryptoCipher "crypto/cipher"
	"encoding/hex"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/flunderpero/cling-sync/cli/keychain"
	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
	"github.com/flunderpero/cling-sync/workspace"
)

const keychainService = "com.cling.sync"

const maxOutputBytes = 16 * 1024

var ErrPassphraseRequired = lib.Errorf("passphrase required")

var (
	ErrMergeAlreadyRunning  = lib.Errorf("merge already running")
	ErrMergeNotRunning      = lib.Errorf("merge not running")
	ErrStatusAlreadyRunning = lib.Errorf("status already running")
)

type WorkspaceInfo struct {
	Exists          bool
	HostURL         string
	RepoPathPrefix  string
	HasStoredAccess bool
}

type MergeWorkspaceStatus struct {
	Running        bool   `json:"running"`
	CanCancel      bool   `json:"canCancel"`
	Completed      bool   `json:"completed"`
	Cancelled      bool   `json:"cancelled"`
	UpToDate       bool   `json:"upToDate"`
	StatusMessage  string `json:"statusMessage"`
	DetailedOutput string `json:"detailedOutput,omitempty"`
	RevisionID     string `json:"revisionId,omitempty"`
	ErrorMessage   string `json:"errorMessage,omitempty"`
}

type mergeWorkspaceState struct {
	mu              sync.Mutex
	status          MergeWorkspaceStatus
	cancelRequested bool
	detailedOutput  string
}

//nolint:gochecknoglobals,exhaustruct
var mergeWorkspaceStateStore = struct {
	mu     sync.Mutex
	states map[string]*mergeWorkspaceState
}{states: map[string]*mergeWorkspaceState{}}

// StatusWorkspaceStatus is the status of a workspace status operation.
// We reuse the same struct shape as MergeWorkspaceStatus.
type StatusWorkspaceStatus = MergeWorkspaceStatus

//nolint:gochecknoglobals,exhaustruct
var statusWorkspaceStateStore = struct {
	mu     sync.Mutex
	states map[string]*mergeWorkspaceState
}{states: map[string]*mergeWorkspaceState{}}

func InspectWorkspace(localPath string) (*WorkspaceInfo, error) {
	ws, err := openWorkspace(localPath)
	if errors.Is(err, lib.ErrStorageNotFound) {
		return &WorkspaceInfo{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer ws.Close() //nolint:errcheck
	remote := string(ws.RemoteRepository)
	_, err = keychain.GetKeychainEntry(context.Background(), keychainService, remote)
	hasStoredAccess := ws.HasSavedPassphrase() && err == nil
	return &WorkspaceInfo{
		Exists:          true,
		HostURL:         remote,
		RepoPathPrefix:  ws.PathPrefix.String(),
		HasStoredAccess: hasStoredAccess,
	}, nil
}

func EnsureWorkspaceConfigured(hostURL, localPath, repoPathPrefix string) error {
	if err := os.MkdirAll(localPath, 0o750); err != nil {
		return lib.WrapErrorf(err, "failed to create local directory %s", localPath)
	}
	stat, err := os.Stat(localPath)
	if err != nil {
		return lib.WrapErrorf(err, "failed to stat local directory %s", localPath)
	}
	if !stat.IsDir() {
		return lib.Errorf("local path %s is not a directory", localPath)
	}
	pathPrefix, err := workspace.ValidatePathPrefix(repoPathPrefix)
	if err != nil {
		return lib.WrapErrorf(err, "invalid path prefix %q", repoPathPrefix)
	}
	ws, err := openWorkspace(localPath)
	if errors.Is(err, lib.ErrStorageNotFound) {
		ws, err = createWorkspace(localPath, hostURL, pathPrefix)
		if err != nil {
			return err
		}
		if err := ws.Close(); err != nil {
			return lib.WrapErrorf(err, "failed to close workspace")
		}
	}
	if err != nil {
		return err
	}
	defer ws.Close() //nolint:errcheck
	if string(ws.RemoteRepository) != hostURL {
		return lib.Errorf("workspace at %s is attached to %s", localPath, ws.RemoteRepository)
	}
	if ws.PathPrefix != pathPrefix {
		return lib.Errorf("workspace at %s uses path prefix %q", localPath, ws.PathPrefix.String())
	}
	return nil
}

func SaveWorkspacePassphrase(localPath, password string) error {
	ws, err := openWorkspace(localPath)
	if err != nil {
		return err
	}
	defer ws.Close() //nolint:errcheck
	storage, err := openStorage(string(ws.RemoteRepository))
	if err != nil {
		return err
	}
	// Verify the passphrase actually opens the repository before persisting it.
	if _, err := lib.OpenRepository(storage, []byte(password)); err != nil {
		return lib.WrapErrorf(err, "failed to open repository")
	}
	encKeyCipher, err := loadOrCreateWorkspaceEncKey(string(ws.RemoteRepository))
	if err != nil {
		return err
	}
	if err := ws.WriteSavedPassphrase([]byte(password), encKeyCipher); err != nil {
		return lib.WrapErrorf(err, "failed to write saved passphrase")
	}
	return nil
}

// loadOrCreateWorkspaceEncKey returns an AEAD cipher built from the keychain
// entry for `remote`, creating a fresh random key in the keychain if none
// exists. Multiple workspaces of the same remote share the same key.
func loadOrCreateWorkspaceEncKey(remote string) (cryptoCipher.AEAD, error) {
	existing, err := keychain.GetKeychainEntry(context.Background(), keychainService, remote)
	switch {
	case err == nil:
		decoded, decodeErr := hex.DecodeString(existing)
		if decodeErr != nil {
			return nil, lib.WrapErrorf(decodeErr, "failed to decode existing keychain entry")
		}
		cipher, cipherErr := lib.NewCipher(lib.RawKey(decoded))
		if cipherErr != nil {
			return nil, lib.WrapErrorf(cipherErr, "failed to create cipher")
		}
		return cipher, nil
	case errors.Is(err, keychain.ErrKeychainEntryNotFound):
		encKey, keyErr := lib.NewRawKey()
		if keyErr != nil {
			return nil, lib.WrapErrorf(keyErr, "failed to generate local encryption key")
		}
		if addErr := keychain.AddKeychainEntry(
			context.Background(),
			keychainService,
			remote,
			hex.EncodeToString(encKey[:]),
		); addErr != nil {
			return nil, lib.WrapErrorf(addErr, "failed to save local encryption key to keychain")
		}
		cipher, cipherErr := lib.NewCipher(encKey)
		if cipherErr != nil {
			return nil, lib.WrapErrorf(cipherErr, "failed to create cipher")
		}
		return cipher, nil
	default:
		return nil, lib.WrapErrorf(err, "failed to read local encryption key from keychain")
	}
}

func ClearWorkspacePassphrase(hostURL string) error {
	if err := keychain.DeleteKeychainEntry(context.Background(), keychainService, hostURL); err != nil {
		return lib.WrapErrorf(err, "failed to delete keychain entry")
	}
	return nil
}

func StartStatusWorkspace(localPath, password string, storePassword bool) error {
	localPath = normalizeWorkspacePath(localPath)
	password, err := prepareMergeWorkspaceAccess(localPath, password, storePassword)
	if err != nil {
		return err
	}

	statusWorkspaceStateStore.mu.Lock()
	if state := statusWorkspaceStateStore.states[localPath]; state != nil && state.snapshot().Running {
		statusWorkspaceStateStore.mu.Unlock()
		return ErrStatusAlreadyRunning
	}
	state := &mergeWorkspaceState{status: MergeWorkspaceStatus{ //nolint:exhaustruct
		Running:       true,
		StatusMessage: "Scanning workspace...",
	}}
	statusWorkspaceStateStore.states[localPath] = state
	statusWorkspaceStateStore.mu.Unlock()

	go runStatusWorkspace(localPath, password, state)
	return nil
}

func GetStatusWorkspaceStatus(localPath string) StatusWorkspaceStatus {
	localPath = normalizeWorkspacePath(localPath)
	statusWorkspaceStateStore.mu.Lock()
	state := statusWorkspaceStateStore.states[localPath]
	statusWorkspaceStateStore.mu.Unlock()
	if state == nil {
		return StatusWorkspaceStatus{}
	}
	return state.snapshot()
}

func runStatusWorkspace(localPath, password string, state *mergeWorkspaceState) {
	result, err := statusWorkspaceSync(localPath, password, state)
	status := StatusWorkspaceStatus{Completed: true} //nolint:exhaustruct
	switch {
	case err != nil:
		status.StatusMessage = "Status failed"
		status.ErrorMessage = err.Error()
	default:
		status.StatusMessage = result
	}
	state.setStatus(status)
}

func statusWorkspaceSync(localPath, password string, state *mergeWorkspaceState) (_ string, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = lib.Errorf("panic: %v", r)
		}
	}()

	ws, err := openWorkspace(localPath)
	if err != nil {
		return "", err
	}
	defer ws.Close() //nolint:errcheck

	repository, err := openWorkspaceRepository(ws, password)
	if err != nil {
		return "", err
	}

	progressEmit := func(text string) { state.setRunningMessage(text) }
	verboseEmit := func(text string) { state.appendOutput(text) }
	stagingMonitor := &asyncStagingMonitor{
		progress: workspace.NewDefaultStagingMonitor(workspace.DefaultMonitorModeProgress, nil, progressEmit),
		verbose:  workspace.NewDefaultStagingMonitor(workspace.DefaultMonitorModeVerbose, nil, verboseEmit),
	}

	tmpFS := lib.NewMemoryFS(500_000_000)
	opts := &workspace.StatusOptions{
		PathFilter:             nil,
		Monitor:                stagingMonitor,
		RestorableMetadataFlag: lib.RestorableMetadataFlag(0),
		UseStagingCache:        true,
	}
	statusFiles, err := workspace.Status(ws, repository, opts, tmpFS)
	if err != nil {
		return "", lib.WrapErrorf(err, "failed to get workspace status")
	}

	summary := statusFiles.Summary()
	var output strings.Builder
	for _, f := range statusFiles {
		output.WriteString(f.Format())
		output.WriteByte('\n')
	}
	if output.Len() > 0 {
		output.WriteString("\n")
	}
	output.WriteString(summary)
	// Replace scan output with status results.
	state.mu.Lock()
	state.detailedOutput = output.String()
	state.status.DetailedOutput = state.detailedOutput
	state.status.StatusMessage = summary
	state.mu.Unlock()

	return summary, nil
}

func TestWorkspaceAccess(localPath, password string) error {
	ws, err := openWorkspace(localPath)
	if err != nil {
		return err
	}
	defer ws.Close() //nolint:errcheck
	_, err = openWorkspaceRepository(ws, password)
	return err
}

func MergeWorkspace(localPath, password, author, message string) (string, bool, error) {
	ws, err := openWorkspace(localPath)
	if err != nil {
		return "", false, err
	}
	defer ws.Close() //nolint:errcheck
	repository, err := openWorkspaceRepository(ws, password)
	if err != nil {
		return "", false, err
	}
	opts := &workspace.MergeOptions{
		StagingMonitor: workspace.NewDefaultStagingMonitor(workspace.DefaultMonitorModeSilent, nil, nil),
		CpMonitor: workspace.NewDefaultCpMonitor(
			workspace.DefaultMonitorModeSilent,
			nil,
			nil,
			workspace.CpOnExistsOverwrite,
			false,
		),
		CommitMonitor:          workspace.NewDefaultCommitMonitor(workspace.DefaultMonitorModeSilent, nil, nil),
		Author:                 author,
		Message:                message,
		RestorableMetadataFlag: lib.RestorableMetadataFlag(0),
		UseStagingCache:        true,
	}
	revisionID, err := workspace.Merge(ws, repository, opts)
	if errors.Is(err, workspace.ErrUpToDate) {
		head, headErr := repository.Head()
		if headErr != nil {
			return "", false, lib.WrapErrorf(headErr, "failed to get repository head")
		}
		return head.String(), true, nil
	}
	if err != nil {
		return "", false, lib.WrapErrorf(err, "failed to merge")
	}
	return revisionID.String(), false, nil
}

func StartMergeWorkspace(localPath, password, author, message string, storePassword bool) error {
	localPath = normalizeWorkspacePath(localPath)
	password, err := prepareMergeWorkspaceAccess(localPath, password, storePassword)
	if err != nil {
		return err
	}

	mergeWorkspaceStateStore.mu.Lock()
	if state := mergeWorkspaceStateStore.states[localPath]; state != nil && state.snapshot().Running {
		mergeWorkspaceStateStore.mu.Unlock()
		return ErrMergeAlreadyRunning
	}
	state := &mergeWorkspaceState{status: MergeWorkspaceStatus{ //nolint:exhaustruct
		Running:       true,
		CanCancel:     true,
		StatusMessage: "Preparing merge...",
	}}
	mergeWorkspaceStateStore.states[localPath] = state
	mergeWorkspaceStateStore.mu.Unlock()

	go runMergeWorkspace(localPath, password, author, message, state)
	return nil
}

func GetMergeWorkspaceStatus(localPath string) MergeWorkspaceStatus {
	localPath = normalizeWorkspacePath(localPath)
	mergeWorkspaceStateStore.mu.Lock()
	state := mergeWorkspaceStateStore.states[localPath]
	mergeWorkspaceStateStore.mu.Unlock()
	if state == nil {
		return MergeWorkspaceStatus{}
	}
	return state.snapshot()
}

func CancelMergeWorkspace(localPath string) error {
	localPath = normalizeWorkspacePath(localPath)
	mergeWorkspaceStateStore.mu.Lock()
	state := mergeWorkspaceStateStore.states[localPath]
	mergeWorkspaceStateStore.mu.Unlock()
	if state == nil || !state.snapshot().Running {
		return ErrMergeNotRunning
	}
	state.requestCancel()
	state.setStatus(MergeWorkspaceStatus{ //nolint:exhaustruct
		Running:       true,
		CanCancel:     false,
		StatusMessage: "Cancelling merge...",
	})
	return nil
}

func prepareMergeWorkspaceAccess(localPath, password string, storePassword bool) (string, error) {
	if storePassword && password != "" {
		if err := SaveWorkspacePassphrase(localPath, password); err != nil {
			return "", err
		}
		return "", nil
	}
	ws, err := openWorkspace(localPath)
	if err != nil {
		return "", err
	}
	defer ws.Close() //nolint:errcheck
	if _, err := openWorkspaceRepository(ws, password); err != nil {
		return "", err
	}
	return password, nil
}

func runMergeWorkspace(localPath, password, author, message string, state *mergeWorkspaceState) {
	revisionID, upToDate, err := mergeWorkspaceAsync(localPath, password, author, message, state)
	status := MergeWorkspaceStatus{Completed: true, UpToDate: upToDate, RevisionID: revisionID} //nolint:exhaustruct
	switch {
	case errors.Is(err, lib.ErrCancel):
		status.Cancelled = true
		status.StatusMessage = "Merge cancelled"
	case err != nil:
		status.StatusMessage = "Merge failed"
		status.ErrorMessage = err.Error()
	case upToDate:
		status.StatusMessage = "Up to date"
	default:
		status.StatusMessage = "Merged " + shortenRevisionID(revisionID)
	}
	state.setStatus(status)
}

func mergeWorkspaceAsync( //nolint:funlen
	localPath, password, author, message string,
	state *mergeWorkspaceState,
) (_ string, _ bool, err error) {
	ws, err := openWorkspace(localPath)
	if err != nil {
		return "", false, err
	}
	defer ws.Close() //nolint:errcheck

	repository, err := openWorkspaceRepository(ws, password)
	if err != nil {
		return "", false, err
	}

	progressEmit := func(text string) { state.setRunningMessage(text) }
	verboseEmit := func(text string) { state.appendOutput(text) }
	cancel := func() error {
		if state.isCancelRequested() {
			return lib.ErrCancel
		}
		return nil
	}
	staging := &asyncStagingMonitor{
		progress: workspace.NewDefaultStagingMonitor(workspace.DefaultMonitorModeProgress, cancel, progressEmit),
		verbose:  workspace.NewDefaultStagingMonitor(workspace.DefaultMonitorModeVerbose, cancel, verboseEmit),
	}
	cp := &asyncCpMonitor{
		progress: workspace.NewDefaultCpMonitor(
			workspace.DefaultMonitorModeProgress,
			cancel,
			progressEmit,
			workspace.CpOnExistsOverwrite,
			false,
		),
		verbose: workspace.NewDefaultCpMonitor(
			workspace.DefaultMonitorModeVerbose,
			cancel,
			verboseEmit,
			workspace.CpOnExistsOverwrite,
			false,
		),
	}
	commit := &asyncCommitMonitor{
		progress: workspace.NewDefaultCommitMonitor(workspace.DefaultMonitorModeProgress, cancel, progressEmit),
		verbose:  workspace.NewDefaultCommitMonitor(workspace.DefaultMonitorModeVerbose, cancel, verboseEmit),
	}

	revisionID, err := workspace.Merge(ws, repository, &workspace.MergeOptions{
		StagingMonitor:         staging,
		CpMonitor:              cp,
		CommitMonitor:          commit,
		Author:                 author,
		Message:                message,
		RestorableMetadataFlag: lib.RestorableMetadataFlag(0),
		UseStagingCache:        true,
	})
	if errors.Is(err, workspace.ErrUpToDate) {
		head, headErr := repository.Head()
		if headErr != nil {
			return "", false, lib.WrapErrorf(headErr, "failed to get repository head")
		}
		return head.String(), true, nil
	}
	if err != nil {
		return "", false, lib.WrapErrorf(err, "failed to merge")
	}
	return revisionID.String(), false, nil
}

type asyncStagingMonitor struct {
	progress *workspace.DefaultStagingMonitor
	verbose  *workspace.DefaultStagingMonitor
}

//nolint:wrapcheck // Monitor delegates forward errors from the inner monitors.
func (m *asyncStagingMonitor) OnStart(path lib.Path, dirEntry fs.DirEntry) error {
	if err := m.verbose.OnStart(path, dirEntry); err != nil {
		return err
	}
	return m.progress.OnStart(path, dirEntry)
}

//nolint:wrapcheck
func (m *asyncStagingMonitor) OnEnd(path lib.Path, excluded bool, metadata *lib.PathMetadata) error {
	if err := m.verbose.OnEnd(path, excluded, metadata); err != nil {
		return err
	}
	return m.progress.OnEnd(path, excluded, metadata)
}

type asyncCpMonitor struct {
	progress *workspace.DefaultCpMonitor
	verbose  *workspace.DefaultCpMonitor
}

//nolint:wrapcheck // Monitor delegates forward errors from the inner monitors.
func (m *asyncCpMonitor) OnStart(entry *lib.RevisionEntry, targetPath string) error {
	if err := m.verbose.OnStart(entry, targetPath); err != nil {
		return err
	}
	return m.progress.OnStart(entry, targetPath)
}

func (m *asyncCpMonitor) OnExists(entry *lib.RevisionEntry, targetPath string) workspace.CpOnExists {
	_ = m.verbose.OnExists(entry, targetPath)
	return m.progress.OnExists(entry, targetPath)
}

//nolint:wrapcheck
func (m *asyncCpMonitor) OnWrite(entry *lib.RevisionEntry, targetPath string, blockID lib.BlockId, data []byte) error {
	if err := m.verbose.OnWrite(entry, targetPath, blockID, data); err != nil {
		return err
	}
	return m.progress.OnWrite(entry, targetPath, blockID, data)
}

//nolint:wrapcheck
func (m *asyncCpMonitor) OnEnd(entry *lib.RevisionEntry, targetPath string) error {
	if err := m.verbose.OnEnd(entry, targetPath); err != nil {
		return err
	}
	return m.progress.OnEnd(entry, targetPath)
}

func (m *asyncCpMonitor) OnError(entry *lib.RevisionEntry, targetPath string, err error) workspace.CpOnError {
	_ = m.verbose.OnError(entry, targetPath, err)
	return m.progress.OnError(entry, targetPath, err)
}

type asyncCommitMonitor struct {
	progress *workspace.DefaultCommitMonitor
	verbose  *workspace.DefaultCommitMonitor
}

//nolint:wrapcheck
func (m *asyncCommitMonitor) OnBeforeCommit() error {
	if err := m.verbose.OnBeforeCommit(); err != nil {
		return err
	}
	return m.progress.OnBeforeCommit()
}

//nolint:wrapcheck
func (m *asyncCommitMonitor) OnStart(entry *lib.RevisionEntry) error {
	if err := m.verbose.OnStart(entry); err != nil {
		return err
	}
	return m.progress.OnStart(entry)
}

//nolint:wrapcheck
func (m *asyncCommitMonitor) OnAddBlock(
	entry *lib.RevisionEntry,
	blockId lib.BlockId,
	dataSize int,
	bytesWritten *int,
) error {
	if err := m.verbose.OnAddBlock(entry, blockId, dataSize, bytesWritten); err != nil {
		return err
	}
	return m.progress.OnAddBlock(entry, blockId, dataSize, bytesWritten)
}

//nolint:wrapcheck
func (m *asyncCommitMonitor) OnEnd(entry *lib.RevisionEntry) error {
	if err := m.verbose.OnEnd(entry); err != nil {
		return err
	}
	return m.progress.OnEnd(entry)
}

func (s *mergeWorkspaceState) requestCancel() {
	s.mu.Lock()
	s.cancelRequested = true
	s.mu.Unlock()
}

func (s *mergeWorkspaceState) isCancelRequested() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cancelRequested
}

func (s *mergeWorkspaceState) setRunningMessage(text string) {
	text = strings.TrimSpace(text)
	if text == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.status.Running {
		return
	}
	s.status.StatusMessage = text
	s.status.CanCancel = !s.cancelRequested
}

func (s *mergeWorkspaceState) appendOutput(text string) {
	text = strings.TrimRight(text, "\n")
	if text == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.detailedOutput == "" {
		s.detailedOutput = text
	} else {
		s.detailedOutput += "\n" + text
	}
	if len(s.detailedOutput) > maxOutputBytes {
		s.detailedOutput = s.detailedOutput[len(s.detailedOutput)-maxOutputBytes:]
		if idx := strings.IndexByte(s.detailedOutput, '\n'); idx >= 0 {
			s.detailedOutput = s.detailedOutput[idx+1:]
		}
		if !strings.HasPrefix(s.detailedOutput, "...\n") {
			s.detailedOutput = "...\n" + s.detailedOutput
		}
	}
	s.status.DetailedOutput = s.detailedOutput
}

func (s *mergeWorkspaceState) setStatus(status MergeWorkspaceStatus) {
	s.mu.Lock()
	status.DetailedOutput = s.detailedOutput
	s.status = status
	s.mu.Unlock()
}

func (s *mergeWorkspaceState) snapshot() MergeWorkspaceStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	status := s.status
	status.DetailedOutput = s.detailedOutput
	return status
}

func normalizeWorkspacePath(localPath string) string {
	clean := filepath.Clean(strings.TrimSpace(localPath))
	if clean == "." {
		return ""
	}
	return clean
}

func shortenRevisionID(revisionID string) string {
	if len(revisionID) <= 12 {
		return revisionID
	}
	return revisionID[:12]
}

func openWorkspaceRepository(ws *workspace.Workspace, password string) (*lib.Repository, error) {
	storage, err := openStorage(string(ws.RemoteRepository))
	if err != nil {
		return nil, err
	}
	if password != "" {
		repository, err := lib.OpenRepository(storage, []byte(password))
		if err != nil {
			return nil, lib.WrapErrorf(err, "failed to open repository")
		}
		return repository, nil
	}
	if !ws.HasSavedPassphrase() {
		return nil, ErrPassphraseRequired
	}
	encKeyStr, keyErr := keychain.GetKeychainEntry(
		context.Background(),
		keychainService,
		string(ws.RemoteRepository),
	)
	if keyErr != nil {
		return nil, ErrPassphraseRequired
	}
	encKey, decodeErr := hex.DecodeString(encKeyStr)
	if decodeErr != nil {
		return nil, ErrPassphraseRequired
	}
	encKeyCipher, cipherErr := lib.NewCipher(lib.RawKey(encKey))
	if cipherErr != nil {
		return nil, ErrPassphraseRequired
	}
	passphrase, readErr := ws.ReadSavedPassphrase(encKeyCipher)
	if readErr != nil {
		return nil, ErrPassphraseRequired
	}
	repository, openErr := lib.OpenRepository(storage, passphrase)
	if openErr != nil {
		return nil, ErrPassphraseRequired
	}
	return repository, nil
}

func openWorkspace(localPath string) (*workspace.Workspace, error) {
	tmpDir, err := os.MkdirTemp("", "cling-sync-workspace")
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to create temporary directory")
	}
	ws, err := workspace.OpenWorkspace(lib.NewRealFS(localPath), lib.NewRealFS(tmpDir))
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to open workspace")
	}
	return ws, nil
}

func createWorkspace(localPath, hostURL string, pathPrefix lib.Path) (*workspace.Workspace, error) {
	tmpDir, err := os.MkdirTemp("", "cling-sync-workspace")
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to create temporary directory")
	}
	ws, err := workspace.NewWorkspace(
		lib.NewRealFS(localPath),
		lib.NewRealFS(tmpDir),
		workspace.RemoteRepository(hostURL),
		pathPrefix,
	)
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to create workspace")
	}
	return ws, nil
}

func openStorage(repository string) (lib.Storage, error) {
	if clinghttp.IsHTTPStorageUIR(repository) {
		httpClient := &http.Client{ //nolint:exhaustruct
			Timeout: 30 * time.Second,
		}
		return clinghttp.NewHTTPStorageClient(repository, clinghttp.NewDefaultHTTPClient(httpClient)), nil
	}
	storage, err := lib.NewFileStorage(lib.NewRealFS(repository), lib.StoragePurposeRepository)
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to open storage")
	}
	return storage, nil
}
