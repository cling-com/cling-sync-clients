package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	bridgepkg "github.com/flunderpero/cling-sync-clients/bridge"
	clingsynchttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
	ws "github.com/flunderpero/cling-sync/workspace"
)

type nopCommitMonitor struct{}

func (nopCommitMonitor) OnBeforeCommit() error                  { return nil }
func (nopCommitMonitor) OnStart(entry *lib.RevisionEntry) error { return nil }

func (nopCommitMonitor) OnAddBlock(
	entry *lib.RevisionEntry,
	blockId lib.BlockId,
	dataSize int,
	bytesWritten *int,
) error {
	return nil
}
func (nopCommitMonitor) OnEnd(entry *lib.RevisionEntry) error { return nil }

var td = lib.TestData{} //nolint:gochecknoglobals

const (
	uiTestConfigPath       = "/tmp/cling-sync-macos-ui-test-config.json"
	uiTestMockKeychainPath = "/tmp/cling-sync-macos-ui-mock-keychain.json"
	xcodeProjectPath       = "../ClingSyncMac.xcodeproj"
	testS3Region           = "us-east-1"
	testS3AccessKeyID      = "minioadmin"
	testS3SecretAccessKey  = "minioadmin"
)

func TestMacOSIntegration(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)

	repoFS := td.NewRealFS(t)
	repo := td.NewTestRepository(t, repoFS)
	initialHead := repo.Head()
	commitFileToRepository(t, repo.Repository, "remote.txt", "hello from remote", "remote author", "seed remote file")

	hostURL, shutdown := serveRepository(t, repo.Storage)
	defer shutdown()
	localDir := filepath.Join(t.TempDir(), "workspace")
	assert.NoError(os.MkdirAll(localDir, 0o750))

	assert.NoError(bridgepkg.InitBridge(t.TempDir()))
	assert.NoError(bridgepkg.EncryptAndStoreS3Credentials(
		hostURL, repo.Passphrase, testS3AccessKeyID, testS3SecretAccessKey,
	))

	t.Log("Running initial sync into empty folder")
	assert.NoError(bridgepkg.EnsureWorkspaceConfigured(hostURL, localDir, ""))
	assert.NoError(bridgepkg.SaveWorkspacePassphrase(localDir, repo.Passphrase))
	revisionID, upToDate, err := bridgepkg.MergeWorkspace(localDir, "", "Mac Test User", "initial macOS test sync")
	assert.NoError(err)
	assert.Equal(false, upToDate)
	assert.Equal(repo.Head().String(), revisionID)
	assert.Equal("hello from remote", mustReadFile(t, filepath.Join(localDir, "remote.txt")))
	assert.Equal(true, mustDirExists(t, filepath.Join(localDir, ".cling")))

	t.Log("Adding local file and checking status before merge")
	localContents := []byte("hello from local")
	writeErr := os.WriteFile(filepath.Join(localDir, "local.txt"), localContents, 0o600)
	assert.NoError(writeErr)

	// Run status and verify the new file is detected.
	assert.NoError(bridgepkg.StartStatusWorkspace(localDir, "", false))
	var statusResult bridgepkg.StatusWorkspaceStatus
	for range 100 {
		statusResult = bridgepkg.GetStatusWorkspaceStatus(localDir)
		if statusResult.Completed {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	assert.Equal(true, statusResult.Completed)
	assert.Equal("", statusResult.ErrorMessage)
	assert.Contains(statusResult.StatusMessage, "1 added")
	assert.Contains(statusResult.DetailedOutput, "local.txt")

	_, upToDate, err = bridgepkg.MergeWorkspace(localDir, "", "Mac Test User", "second macOS test sync")
	assert.NoError(err)
	assert.Equal(false, upToDate)

	newHead := repo.Head()
	assert.NotEqual(initialHead, newHead)
	assert.Equal([]lib.TestFileInfo{
		{Path: "local.txt", Mode: 0o600, Size: len("hello from local"), Content: "hello from local"},
		{Path: "remote.txt", Mode: 0o600, Size: len("hello from remote"), Content: "hello from remote"},
	}, repo.RevisionSnapshotFileInfos(newHead, nil))
	revision, err := repo.ReadRevision(newHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Equal("Mac Test User", *revision.Author)
	assert.Equal("second macOS test sync", *revision.Message)
	assert.Equal(true, mustDirExists(t, filepath.Join(localDir, ".cling")))

	wsTmp := td.NewRealFS(t)
	workspace, err := ws.OpenWorkspace(lib.NewRealFS(localDir), wsTmp)
	assert.NoError(err)
	defer workspace.Close() //nolint:errcheck
	assert.Equal(hostURL, string(workspace.RemoteRepository))
	assert.Equal(newHead, mustWorkspaceHead(t, workspace))
}

func TestMacOSXCUITest(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	repoFS := td.NewRealFS(t)
	repo := td.NewTestRepository(t, repoFS)
	initialHead := repo.Head()
	commitFileToRepository(t, repo.Repository, "remote.txt", "hello from remote", "remote author", "seed remote file")

	hostURL, shutdown := serveRepository(t, repo.Storage)
	defer shutdown()
	defaultsSuite := "com.cling.ClingSyncMac.ui." + time.Now().Format("20060102150405.000000000")
	defer cleanupDefaultsSuite(t, defaultsSuite)

	// The combined UI test drives two workspaces:
	//   - workspace 1 uses the plain S3 URL so we exercise the S3 prompt flow,
	//   - workspace 2 uses an embedded-credentials URL so we exercise the
	//     bridge's passthrough that skips the prompt.
	embeddedURL, err := clingsynchttp.EncodeS3URI(
		hostURL,
		clingsynchttp.S3Credentials{
			AccessKeyID:     testS3AccessKeyID,
			SecretAccessKey: []byte(testS3SecretAccessKey),
		},
		[]byte(repo.Passphrase),
	)
	assert.NoError(err)

	localDir := filepath.Join(t.TempDir(), "workspace-ui")
	assert.NoError(os.MkdirAll(localDir, 0o750))
	secondLocalDir := filepath.Join(t.TempDir(), "workspace-ui-second")
	assert.NoError(os.MkdirAll(secondLocalDir, 0o750))

	// Pre-stage the file that workspace 2 will merge so we don't have to
	// mutate the filesystem between two xcodebuild invocations.
	uiContents := []byte("hello from ui")
	assert.NoError(os.WriteFile(filepath.Join(secondLocalDir, "local-ui.txt"), uiContents, 0o600))

	runXCUITest(
		t,
		uiTestConfig{
			defaultsSuite:  defaultsSuite,
			hostURL:        hostURL,
			secondHostURL:  embeddedURL,
			passphrase:     repo.Passphrase,
			localDir:       localDir,
			secondLocalDir: secondLocalDir,
			author:         "Mac UI Test User",
			s3AccessKeyID:  testS3AccessKeyID,
			s3SecretAccess: testS3SecretAccessKey,
			newRepoPath:    "",
		},
		"testConfigureAndMergeTwoWorkspaces",
	)

	assert.Equal(true, mustDirExists(t, filepath.Join(localDir, ".cling")))
	assert.Equal("hello from remote", mustReadFile(t, filepath.Join(localDir, "remote.txt")))

	newHead := repo.Head()
	assert.NotEqual(initialHead, newHead)
	assert.Equal([]lib.TestFileInfo{
		{Path: "local-ui.txt", Mode: 0o600, Size: len("hello from ui"), Content: "hello from ui"},
		{Path: "remote.txt", Mode: 0o600, Size: len("hello from remote"), Content: "hello from remote"},
	}, repo.RevisionSnapshotFileInfos(newHead, nil))

	workspaceTmp := td.NewRealFS(t)
	workspace, err := ws.OpenWorkspace(lib.NewRealFS(localDir), workspaceTmp)
	assert.NoError(err)
	defer workspace.Close() //nolint:errcheck
	assert.Equal(hostURL, string(workspace.RemoteRepository))
}

func TestMacOSXCUITestCreateNewRepository(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	// XCUIElement identifiers cap at 128 chars, and the workspace.merge.<path>
	// identifier embeds the local dir verbatim. The default t.TempDir() prefix
	// is too long for that, so we mint a short one under /tmp instead.
	parentDir, err := os.MkdirTemp("/tmp", "cnr-") //nolint:usetesting
	assert.NoError(err)
	t.Cleanup(func() { _ = os.RemoveAll(parentDir) })
	newRepoPath := filepath.Join(parentDir, "repo")
	localDir := filepath.Join(parentDir, "ws")
	assert.NoError(os.MkdirAll(localDir, 0o750))
	// Seed a file the initial merge will commit into the freshly created repository.
	const testFileContent = "hello from new repo"
	const testFile = "new-repo-file.txt"
	assert.NoError(os.WriteFile(filepath.Join(localDir, testFile), []byte(testFileContent), 0o600))
	defaultsSuite := "com.cling.ClingSyncMac.ui.newrepo." + time.Now().Format("20060102150405.000000000")
	defer cleanupDefaultsSuite(t, defaultsSuite)

	// Use "testpassphrase" so we can re-open the repository with TestData helpers below.
	writeXCUITestConfig(t, uiTestConfig{
		defaultsSuite:  defaultsSuite,
		hostURL:        "http://unused.invalid",
		secondHostURL:  "",
		passphrase:     "testpassphrase",
		localDir:       localDir,
		secondLocalDir: filepath.Join(parentDir, "workspace-second-unused"),
		author:         "Mac UI Test User",
		s3AccessKeyID:  "",
		s3SecretAccess: "",
		newRepoPath:    newRepoPath,
	})
	logDir := filepath.Join("..", "build", "testlogs")
	if err := os.MkdirAll(logDir, 0o750); err != nil {
		t.Fatalf("create xcodebuild log dir: %v", err)
	}
	logPath := filepath.Join(logDir, "testCreateNewRepositoryFromMissingPath.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		t.Fatalf("create xcodebuild log file: %v", err)
	}
	t.Cleanup(func() {
		_ = logFile.Close()
		if !t.Failed() {
			_ = os.Remove(logPath)
		}
	})
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(
		ctx,
		"xcodebuild",
		"-project", xcodeProjectPath,
		"-scheme", "ClingSyncMac",
		"-destination", "platform=macOS",
		"-test-timeouts-enabled", "YES",
		"-default-test-execution-time-allowance", "30",
		"-maximum-test-execution-time-allowance", "90",
		"-only-testing:ClingSyncMacUITests/ClingSyncMacUITests/testCreateNewRepositoryFromMissingPath",
		"test",
	)
	cmd.Dir = "."
	cmd.Env = append(os.Environ(),
		"CLING_SYNC_GO_BUILD_TAGS=mock",
		"CLING_SYNC_MOCK_KEYCHAIN_FILE="+uiTestMockKeychainPath,
	)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		t.Fatalf("xcode ui test timed out; log: %s\n%s", logPath, readLogTail(t, logPath))
	}
	if err != nil {
		t.Fatalf("xcode ui test failed: %v\nlog: %s\n%s", err, logPath, readLogTail(t, logPath))
	}

	assert.Equal(true, mustDirExists(t, filepath.Join(newRepoPath, ".cling", "repository")))
	assert.Equal(true, mustDirExists(t, filepath.Join(newRepoPath, ".cling", "repository", "objects")))
	assert.Equal(true, mustDirExists(t, filepath.Join(localDir, ".cling")))

	wsTmp := td.NewRealFS(t)
	workspaceObj, err := ws.OpenWorkspace(lib.NewRealFS(localDir), wsTmp)
	assert.NoError(err)
	defer workspaceObj.Close() //nolint:errcheck
	assert.Equal(newRepoPath, string(workspaceObj.RemoteRepository))

	repo := td.OpenRepository(t, lib.NewRealFS(newRepoPath))
	head := repo.Head()
	assert.Equal(false, head.IsRoot())
	assert.Equal([]lib.TestFileInfo{
		{Path: testFile, Mode: 0o600, Size: len(testFileContent), Content: testFileContent},
	}, repo.RevisionSnapshotFileInfos(head, nil))
}

func serveRepository(t *testing.T, storage *lib.FileStorage) (string, func()) {
	t.Helper()
	s3Server := clingsynchttp.NewS3StorageServer(storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3Server.RegisterRoutes(mux)
	listener, err := net.Listen("tcp", "127.0.0.1:0") //nolint:noctx
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := &http.Server{Handler: mux} //nolint:gosec,exhaustruct
	go server.Serve(listener)            //nolint:errcheck
	return "s3+http://" + listener.Addr().String(), func() {
		_ = server.Close()
	}
}

type uiTestConfig struct {
	defaultsSuite  string
	hostURL        string
	secondHostURL  string
	passphrase     string
	localDir       string
	secondLocalDir string
	author         string
	s3AccessKeyID  string
	s3SecretAccess string
	newRepoPath    string
}

func runXCUITest(t *testing.T, cfg uiTestConfig, onlyTest string) {
	t.Helper()
	writeXCUITestConfig(t, cfg)
	logDir := filepath.Join("..", "build", "testlogs")
	if err := os.MkdirAll(logDir, 0o750); err != nil {
		t.Fatalf("create xcodebuild log dir: %v", err)
	}
	logPath := filepath.Join(logDir, onlyTest+".log")
	logFile, err := os.Create(logPath)
	if err != nil {
		t.Fatalf("create xcodebuild log file: %v", err)
	}
	t.Cleanup(func() {
		_ = logFile.Close()
		if !t.Failed() {
			_ = os.Remove(logPath)
		}
	})
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext( //nolint:gosec
		ctx,
		"xcodebuild",
		"-project", xcodeProjectPath,
		"-scheme", "ClingSyncMac",
		"-destination", "platform=macOS",
		"-test-timeouts-enabled", "YES",
		"-default-test-execution-time-allowance", "60",
		"-maximum-test-execution-time-allowance", "180",
		"-only-testing:ClingSyncMacUITests/ClingSyncMacUITests/"+onlyTest,
		"test",
	)
	cmd.Dir = "."
	cmd.Env = append(os.Environ(),
		"CLING_SYNC_GO_BUILD_TAGS=mock",
		"CLING_SYNC_MOCK_KEYCHAIN_FILE="+uiTestMockKeychainPath,
	)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		t.Fatalf("xcode ui test timed out; log: %s\n%s", logPath, readLogTail(t, logPath))
	}
	if err != nil {
		t.Fatalf("xcode ui test failed: %v\nlog: %s\n%s", err, logPath, readLogTail(t, logPath))
	}
	t.Logf("xcode ui test passed: %s", onlyTest)
}

func readLogTail(t *testing.T, path string) string {
	t.Helper()
	const maxLines = 120
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("failed to read log %s: %v", path, err)
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return "xcodebuild log is empty"
	}
	lines := strings.Split(trimmed, "\n")
	if len(lines) > maxLines {
		lines = lines[len(lines)-maxLines:]
	}
	return strings.Join(lines, "\n")
}

func writeXCUITestConfig(t *testing.T, cfg uiTestConfig) {
	t.Helper()
	config := struct {
		DefaultsSuite   string `json:"defaultsSuite"`
		ServerURL       string `json:"serverUrl"`
		SecondServerURL string `json:"secondServerUrl,omitempty"`
		S3AccessKeyID   string `json:"s3AccessKeyId,omitempty"`
		S3AccessKey     string `json:"s3AccessKey,omitempty"`
		Passphrase      string `json:"passphrase"`
		LocalDir        string `json:"localDir"`
		SecondLocalDir  string `json:"secondLocalDir"`
		Author          string `json:"author"`
		NewRepoPath     string `json:"newRepoPath,omitempty"`
	}{
		DefaultsSuite:   cfg.defaultsSuite,
		ServerURL:       cfg.hostURL,
		SecondServerURL: cfg.secondHostURL,
		S3AccessKeyID:   cfg.s3AccessKeyID,
		S3AccessKey:     cfg.s3SecretAccess,
		Passphrase:      cfg.passphrase,
		LocalDir:        cfg.localDir,
		SecondLocalDir:  cfg.secondLocalDir,
		Author:          cfg.author,
		NewRepoPath:     cfg.newRepoPath,
	}
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("marshal ui test config: %v", err)
	}
	if err := os.WriteFile(uiTestConfigPath, data, 0o600); err != nil {
		t.Fatalf("write ui test config: %v", err)
	}
	t.Cleanup(func() {
		_ = os.Remove(uiTestConfigPath)
		_ = os.Remove(uiTestMockKeychainPath)
	})
}

func cleanupDefaultsSuite(t *testing.T, suite string) {
	t.Helper()
	cmd := exec.CommandContext(t.Context(), "defaults", "delete", suite)
	_ = cmd.Run()
}

func commitFileToRepository(t *testing.T, repo *lib.Repository, path, content, author, message string) lib.RevisionId {
	t.Helper()
	assert := lib.NewAssert(t)
	fs := td.NewRealFS(t)
	assert.NoError(os.WriteFile(filepath.Join(fs.BasePath, path), []byte(content), 0o600))
	stat, err := fs.Stat(path)
	assert.NoError(err)
	repoPath, err := lib.NewPath(path)
	assert.NoError(err)
	md, err := ws.AddFileToRepository(
		fs,
		repoPath,
		stat,
		repo,
		nil,
		nopCommitMonitor{},
	)
	assert.NoError(err)
	commit, err := lib.NewCommit(repo, td.NewFS(t))
	assert.NoError(err)
	assert.NoError(commit.Add(&lib.RevisionEntry{Path: repoPath, Kind: lib.RevisionEntryKindAdd, Metadata: md}))
	revisionID, err := commit.Commit(&lib.CommitInfo{Author: author, Message: message})
	assert.NoError(err)
	return revisionID
}

func mustReadFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func mustDirExists(t *testing.T, path string) bool {
	t.Helper()
	stat, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	return stat.IsDir()
}

func mustWorkspaceHead(t *testing.T, workspace *ws.Workspace) lib.RevisionId {
	t.Helper()
	head, err := workspace.Head()
	if err != nil {
		t.Fatalf("workspace head: %v", err)
	}
	return head
}
