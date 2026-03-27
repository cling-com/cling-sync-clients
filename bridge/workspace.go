package bridge

import (
	"context"
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

const maxMergeOutputBytes = 16 * 1024

var ErrPassphraseRequired = lib.Errorf("passphrase required")

var (
	ErrMergeAlreadyRunning = lib.Errorf("merge already running")
	ErrMergeNotRunning     = lib.Errorf("merge not running")
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

//nolint:gochecknoglobals
var mergeWorkspaceStateStore = struct {
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
	hasStoredAccess := ws.HasRepositoryKeys() && err == nil
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
	keys, err := lib.DecryptRepositoryKeys(storage, []byte(password))
	if err != nil {
		return lib.WrapErrorf(err, "failed to decrypt repository keys")
	}
	encKey, err := lib.NewRawKey()
	if err != nil {
		return lib.WrapErrorf(err, "failed to generate local encryption key")
	}
	encKeyStr := hex.EncodeToString(encKey[:])
	encKeyCipher, err := lib.NewCipher(encKey)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create cipher")
	}
	err = keychain.AddKeychainEntry(context.Background(), keychainService, string(ws.RemoteRepository), encKeyStr)
	if errors.Is(err, keychain.ErrKeychainEntryAlreadyExists) {
		encKeyStr, err = keychain.GetKeychainEntry(context.Background(), keychainService, string(ws.RemoteRepository))
		if err != nil {
			return lib.WrapErrorf(err, "failed to get encryption key from keychain")
		}
		encKeyBytes, err := hex.DecodeString(encKeyStr)
		if err != nil {
			return lib.WrapErrorf(err, "failed to decode encryption key from keychain")
		}
		encKeyCipher, err = lib.NewCipher(lib.RawKey(encKeyBytes))
		if err != nil {
			return lib.WrapErrorf(err, "failed to create cipher")
		}
	}
	if err != nil {
		return lib.WrapErrorf(err, "failed to add repository keys to keychain")
	}
	if err := ws.WriteRepositoryKeys(keys, encKeyCipher); err != nil {
		return lib.WrapErrorf(err, "failed to write repository keys")
	}
	return nil
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
		StagingMonitor:         workspace.NewDefaultStagingMonitor(workspace.DefaultMonitorModeSilent, nil, nil),
		CpMonitor:              workspace.NewDefaultCpMonitor(workspace.DefaultMonitorModeSilent, nil, nil, workspace.CpOnExistsOverwrite, false),
		CommitMonitor:          workspace.NewDefaultCommitMonitor(workspace.DefaultMonitorModeSilent, nil, nil),
		Author:                 author,
		Message:                message,
		RestorableMetadataFlag: lib.RestorableMetadataAll,
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
	state := &mergeWorkspaceState{status: MergeWorkspaceStatus{
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
	state.setStatus(MergeWorkspaceStatus{
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
	status := MergeWorkspaceStatus{Completed: true, UpToDate: upToDate, RevisionID: revisionID}
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

func mergeWorkspaceAsync(
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
		RestorableMetadataFlag: lib.RestorableMetadataAll,
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

func (m *asyncStagingMonitor) OnStart(path lib.Path, dirEntry fs.DirEntry) error {
	if err := m.verbose.OnStart(path, dirEntry); err != nil {
		return err
	}
	return m.progress.OnStart(path, dirEntry)
}

func (m *asyncStagingMonitor) OnEnd(path lib.Path, excluded bool, metadata *lib.FileMetadata) error {
	if err := m.verbose.OnEnd(path, excluded, metadata); err != nil {
		return err
	}
	return m.progress.OnEnd(path, excluded, metadata)
}

type asyncCpMonitor struct {
	progress *workspace.DefaultCpMonitor
	verbose  *workspace.DefaultCpMonitor
}

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

func (m *asyncCpMonitor) OnWrite(entry *lib.RevisionEntry, targetPath string, blockID lib.BlockId, data []byte) error {
	if err := m.verbose.OnWrite(entry, targetPath, blockID, data); err != nil {
		return err
	}
	return m.progress.OnWrite(entry, targetPath, blockID, data)
}

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

func (m *asyncCommitMonitor) OnBeforeCommit() error {
	if err := m.verbose.OnBeforeCommit(); err != nil {
		return err
	}
	return m.progress.OnBeforeCommit()
}

func (m *asyncCommitMonitor) OnStart(entry *lib.RevisionEntry) error {
	if err := m.verbose.OnStart(entry); err != nil {
		return err
	}
	return m.progress.OnStart(entry)
}

func (m *asyncCommitMonitor) OnAddBlock(
	entry *lib.RevisionEntry,
	header *lib.BlockHeader,
	existed bool,
	dataSize int64,
) error {
	if err := m.verbose.OnAddBlock(entry, header, existed, dataSize); err != nil {
		return err
	}
	return m.progress.OnAddBlock(entry, header, existed, dataSize)
}

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
	if len(s.detailedOutput) > maxMergeOutputBytes {
		s.detailedOutput = s.detailedOutput[len(s.detailedOutput)-maxMergeOutputBytes:]
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
	if ws.HasRepositoryKeys() {
		encKeyStr, keyErr := keychain.GetKeychainEntry(
			context.Background(),
			keychainService,
			string(ws.RemoteRepository),
		)
		if keyErr == nil {
			encKey, decodeErr := hex.DecodeString(encKeyStr)
			if decodeErr != nil {
				return nil, ErrPassphraseRequired
			}
			encKeyCipher, cipherErr := lib.NewCipher(lib.RawKey(encKey))
			if cipherErr != nil {
				return nil, ErrPassphraseRequired
			}
			keys, readErr := ws.ReadRepositoryKeys(encKeyCipher)
			if readErr != nil {
				return nil, ErrPassphraseRequired
			}
			repository, openErr := lib.OpenRepositoryWithKeys(storage, keys)
			if openErr != nil {
				return nil, ErrPassphraseRequired
			}
			return repository, nil
		}
		if !errors.Is(keyErr, keychain.ErrKeychainEntryNotFound) {
			return nil, ErrPassphraseRequired
		}
	}
	return nil, ErrPassphraseRequired
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
