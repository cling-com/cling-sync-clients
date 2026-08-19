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
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	clingsynchttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
	ws "github.com/cling-com/cling-sync/workspace"
	bridgepkg "github.com/flunderpero/cling-sync-clients/bridge"
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

// embedS3Credentials encrypts the test S3 credentials into `rawURL`, producing
// the directly-openable repository URI the client stores and sends.
func embedS3Credentials(t *testing.T, rawURL, passphrase string) string {
	t.Helper()
	uri, err := clingsynchttp.EncodeS3URI(
		rawURL,
		clingsynchttp.S3Credentials{AccessKeyID: testS3AccessKeyID, SecretAccessKey: []byte(testS3SecretAccessKey)},
		[]byte(passphrase),
	)
	if err != nil {
		t.Fatalf("encode S3 URI: %v", err)
	}
	return uri
}

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

	// The client owns the encrypted credentials: the repository URI carries them.
	repoURI := embedS3Credentials(t, hostURL, repo.Passphrase)

	t.Log("Running initial sync into empty folder")
	assert.NoError(bridgepkg.EnsureWorkspaceConfigured(repoURI, localDir, ""))
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
	assert.NoError(bridgepkg.StartStatusWorkspace(localDir, ""))
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
	revision, err := repo.ReadRevision(t.Context(), newHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Equal("Mac Test User", *revision.Author)
	assert.Equal("second macOS test sync", *revision.Message)
	assert.Equal(true, mustDirExists(t, filepath.Join(localDir, ".cling")))

	wsTmp := td.NewRealFS(t)
	workspace, err := ws.OpenWorkspace(t.Context(), lib.NewRealFS(localDir), wsTmp)
	assert.NoError(err)
	defer workspace.Close() //nolint:errcheck
	assert.Equal(repoURI, string(workspace.RemoteRepository))
	assert.Equal(newHead, mustWorkspaceHead(t, workspace))
}

func TestMacOSSyncRepoBackup(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)

	repoFS := td.NewRealFS(t)
	repo := td.NewTestRepository(t, repoFS)
	commitFileToRepository(t, repo.Repository, "remote.txt", "hello from remote", "remote author", "seed remote file")
	sourceHead := repo.Head()

	hostURL, shutdown := serveRepository(t, repo.Storage)
	defer shutdown()
	backupHostURL, backupStorage, backupShutdown := serveBackupRepository(t, repo.Storage)
	defer backupShutdown()

	localDir := filepath.Join(t.TempDir(), "workspace")
	assert.NoError(os.MkdirAll(localDir, 0o750))

	repoURI := embedS3Credentials(t, hostURL, repo.Passphrase)
	assert.NoError(bridgepkg.EnsureWorkspaceConfigured(repoURI, localDir, ""))

	syncTargetURL := embedS3Credentials(t, backupHostURL, repo.Passphrase)

	t.Log("Adding the backup sync target")
	assert.NoError(bridgepkg.AddWorkspaceSyncTarget(localDir, "backup", syncTargetURL, repo.Passphrase))

	targets, err := bridgepkg.ListWorkspaceSyncTargets(localDir)
	assert.NoError(err)
	assert.Equal(1, len(targets))
	assert.Equal("backup", targets[0].Name)
	// The display URI must not leak the encrypted credential blob.
	assert.Equal(false, strings.Contains(targets[0].DisplayURI, "@"))

	t.Log("Running the sync to the backup target with 4 workers")
	assert.NoError(bridgepkg.StartSyncWorkspace(localDir, repo.Passphrase, 4))
	var syncResult bridgepkg.MergeWorkspaceStatus
	for range 200 {
		syncResult = bridgepkg.GetSyncWorkspaceStatus(localDir)
		if syncResult.Completed {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	assert.Equal(true, syncResult.Completed)
	assert.Equal("", syncResult.ErrorMessage)
	assert.Contains(syncResult.StatusMessage, "Synced")
	// The detailed output carries the full monitor progress and the global
	// worker count we passed in.
	assert.Contains(syncResult.DetailedOutput, "source has")
	assert.Contains(syncResult.DetailedOutput, "updating target repository head")
	assert.Contains(syncResult.DetailedOutput, "[4 workers]")

	// Aborting when no sync is running is reported, not silently ignored.
	if cancelErr := bridgepkg.CancelSyncWorkspace(localDir); cancelErr == nil {
		t.Fatal("expected CancelSyncWorkspace to fail when no sync is running")
	}

	// The backup repository head must now match the source head.
	backupHead, err := lib.ReadRef(t.Context(), backupStorage, "head")
	assert.NoError(err)
	assert.Equal(sourceHead, backupHead)

	t.Log("Deleting the backup sync target")
	assert.NoError(bridgepkg.DeleteWorkspaceSyncTarget(localDir, "backup"))
	targets, err = bridgepkg.ListWorkspaceSyncTargets(localDir)
	assert.NoError(err)
	assert.Equal(0, len(targets))
}

func TestMacOSSyncRepoFileTargetAndValidation(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)

	repoFS := td.NewRealFS(t)
	repo := td.NewTestRepository(t, repoFS)
	commitFileToRepository(t, repo.Repository, "source-data.txt", "hello from source", "source author", "seed source")
	sourceHead := repo.Head()
	srcToml, err := repo.Storage.Open(t.Context())
	assert.NoError(err)

	localDir := filepath.Join(t.TempDir(), "workspace")
	assert.NoError(os.MkdirAll(localDir, 0o750))

	// The source repository is a local file path (no S3), exercising the
	// file-path branches of the sync-target code.
	assert.NoError(bridgepkg.EnsureWorkspaceConfigured(repoFS.BasePath, localDir, ""))

	// A local file backup repository that shares the source configuration.
	backupFS := td.NewRealFS(t)
	backupStorage, err := lib.NewFileStorage(backupFS, lib.StoragePurposeRepository)
	assert.NoError(err)
	assert.NoError(backupStorage.Init(t.Context(), srcToml, lib.RepositoryConfigHeaderComment))
	assert.NoError(lib.WriteRef(t.Context(), backupStorage, "head", lib.RevisionId{}))

	assert.NoError(bridgepkg.AddWorkspaceSyncTarget(localDir, "local-backup", backupFS.BasePath, repo.Passphrase))

	// A relative folder path must be rejected, not silently resolved.
	relErr := bridgepkg.AddWorkspaceSyncTarget(localDir, "rel", "relative/backup", repo.Passphrase)
	if relErr == nil || !strings.Contains(relErr.Error(), "absolute") {
		t.Fatalf("expected absolute-path error, got %v", relErr)
	}
	// An S3 target URL without embedded credentials must be rejected.
	s3Err := bridgepkg.AddWorkspaceSyncTarget(
		localDir, "badS3", "s3+https://bucket.s3.example.com/prefix", repo.Passphrase,
	)
	if s3Err == nil || !strings.Contains(s3Err.Error(), "credentials") {
		t.Fatalf("expected embedded-credentials error, got %v", s3Err)
	}

	targets, err := bridgepkg.ListWorkspaceSyncTargets(localDir)
	assert.NoError(err)
	assert.Equal(1, len(targets))
	assert.Equal("local-backup", targets[0].Name)
	// A file-path target's display URI is the path itself.
	assert.Equal(backupFS.BasePath, targets[0].DisplayURI)

	assert.NoError(bridgepkg.StartSyncWorkspace(localDir, repo.Passphrase, 2))
	var syncResult bridgepkg.MergeWorkspaceStatus
	for range 200 {
		syncResult = bridgepkg.GetSyncWorkspaceStatus(localDir)
		if syncResult.Completed {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	assert.Equal(true, syncResult.Completed)
	assert.Equal("", syncResult.ErrorMessage)
	assert.Contains(syncResult.StatusMessage, "Synced")

	backupHead, err := lib.ReadRef(t.Context(), backupStorage, "head")
	assert.NoError(err)
	assert.Equal(sourceHead, backupHead)
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

	// Sync target ("backup"): a second server hosting an empty repository that
	// shares the source's configuration. Its URL embeds the encrypted
	// credentials, as required when adding an S3 sync target from the UI.
	backupHostURL, backupStorage, backupShutdown := serveBackupRepository(t, repo.Storage)
	defer backupShutdown()
	syncTargetURL, err := clingsynchttp.EncodeS3URI(
		backupHostURL,
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
			syncTargetURL:  syncTargetURL,
			controlURL:     "",
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

	// The UI ran "Sync Repository" on workspace 1 after its first merge, which
	// mirrors the source repository to the backup target. The backup head must
	// have advanced to match whatever the source head was at sync time.
	backupHead, err := lib.ReadRef(t.Context(), backupStorage, "head")
	assert.NoError(err)
	assert.Equal(false, backupHead.IsRoot())

	workspaceTmp := td.NewRealFS(t)
	workspace, err := ws.OpenWorkspace(t.Context(), lib.NewRealFS(localDir), workspaceTmp)
	assert.NoError(err)
	defer workspace.Close() //nolint:errcheck
	// The client encoded the S3 credentials into the stored repository URI.
	assert.Equal(true, clingsynchttp.S3URIHasEmbeddedCredentials(string(workspace.RemoteRepository)))
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
		syncTargetURL:  "",
		controlURL:     "",
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
	resultBundle := xcresultBundle(t, "testCreateNewRepositoryFromMissingPath")
	t.Cleanup(func() {
		_ = logFile.Close()
		if !t.Failed() {
			_ = os.Remove(logPath)
			_ = os.RemoveAll(resultBundle)
		}
	})
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(
		ctx,
		"xcodebuild",
		"-project", xcodeProjectPath,
		"-scheme", "ClingSyncMac",
		"-destination", "platform=macOS",
		"-test-timeouts-enabled", "YES",
		"-default-test-execution-time-allowance", "120",
		"-maximum-test-execution-time-allowance", "420",
		"-resultBundlePath", resultBundle,
		"-only-testing:ClingSyncMacUITests/ClingSyncMacUITests/testCreateNewRepositoryFromMissingPath",
		"CODE_SIGN_IDENTITY=-",
		"CODE_SIGNING_REQUIRED=NO",
		"CODE_SIGNING_ALLOWED=YES",
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
	workspaceObj, err := ws.OpenWorkspace(t.Context(), lib.NewRealFS(localDir), wsTmp)
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

// TestMacOSXCUITestAutoMergeError drives a background auto-merge against a
// repository whose S3 server rejects writes, asserts the menu surfaces
// "Merge (failed)" without recording a success, then clears the fault and
// asserts the next auto-merge recovers and commits the seeded local file.
func TestMacOSXCUITestAutoMergeError(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	repoFS := td.NewRealFS(t)
	repo := td.NewTestRepository(t, repoFS)
	commitFileToRepository(t, repo.Repository, "remote.txt", "hello from remote", "remote author", "seed remote file")
	initialHead := repo.Head()

	hostURL, controlURL, shutdown := serveFaultRepository(t, repo.Storage)
	defer shutdown()
	defaultsSuite := "com.cling.ClingSyncMac.ui.automergeerror." + time.Now().Format("20060102150405.000000000")
	defer cleanupDefaultsSuite(t, defaultsSuite)

	// Embed the credentials so the UI skips the S3 prompt and the test focuses on
	// the merge error/recovery path.
	embeddedURL := embedS3Credentials(t, hostURL, repo.Passphrase)

	// A short /tmp dir keeps the workspace.merge.<path> XCUIElement identifier
	// under the 128-char cap (the default t.TempDir() prefix is too long).
	parentDir, err := os.MkdirTemp("/tmp", "ame-") //nolint:usetesting
	assert.NoError(err)
	t.Cleanup(func() { _ = os.RemoveAll(parentDir) })
	localDir := filepath.Join(parentDir, "ws")
	assert.NoError(os.MkdirAll(localDir, 0o750))
	// Seed a local change so the merge must push to the write-failing repository.
	const localFile = "local-err.txt"
	const localContent = "local change"
	assert.NoError(os.WriteFile(filepath.Join(localDir, localFile), []byte(localContent), 0o600))

	runXCUITest(
		t,
		uiTestConfig{
			defaultsSuite:  defaultsSuite,
			hostURL:        embeddedURL,
			secondHostURL:  "",
			syncTargetURL:  "",
			controlURL:     controlURL,
			passphrase:     repo.Passphrase,
			localDir:       localDir,
			secondLocalDir: filepath.Join(parentDir, "unused-second"),
			author:         "Mac UI Test User",
			s3AccessKeyID:  "",
			s3SecretAccess: "",
			newRepoPath:    "",
		},
		"testAutoMergeErrorThenRecovers",
	)

	// The recovery auto-merge committed the seeded local file alongside the
	// pre-existing remote file.
	newHead := repo.Head()
	assert.NotEqual(initialHead, newHead)
	assert.Equal([]lib.TestFileInfo{
		{Path: localFile, Mode: 0o600, Size: len(localContent), Content: localContent},
		{Path: "remote.txt", Mode: 0o600, Size: len("hello from remote"), Content: "hello from remote"},
	}, repo.RevisionSnapshotFileInfos(newHead, nil))
}

// TestMacOSXCUITestMutualExclusion runs a slow (latency-injected) background
// merge and asserts that while it runs the workspace's other operations are
// disabled in the menu, then re-enable once it finishes.
func TestMacOSXCUITestMutualExclusion(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	repoFS := td.NewRealFS(t)
	repo := td.NewTestRepository(t, repoFS)
	commitFileToRepository(t, repo.Repository, "remote.txt", "hello from remote", "remote author", "seed remote file")

	hostURL, controlURL, shutdown := serveFaultRepository(t, repo.Storage)
	defer shutdown()
	defaultsSuite := "com.cling.ClingSyncMac.ui.mutualexclusion." + time.Now().Format("20060102150405.000000000")
	defer cleanupDefaultsSuite(t, defaultsSuite)

	embeddedURL := embedS3Credentials(t, hostURL, repo.Passphrase)

	parentDir, err := os.MkdirTemp("/tmp", "mex-") //nolint:usetesting
	assert.NoError(err)
	t.Cleanup(func() { _ = os.RemoveAll(parentDir) })
	localDir := filepath.Join(parentDir, "ws")
	assert.NoError(os.MkdirAll(localDir, 0o750))
	// A local change makes the merge push (latency-delayed) so it stays running
	// long enough to inspect the menu.
	assert.NoError(os.WriteFile(filepath.Join(localDir, "local-mex.txt"), []byte("local change"), 0o600))

	runXCUITest(
		t,
		uiTestConfig{
			defaultsSuite:  defaultsSuite,
			hostURL:        embeddedURL,
			secondHostURL:  "",
			syncTargetURL:  "",
			controlURL:     controlURL,
			passphrase:     repo.Passphrase,
			localDir:       localDir,
			secondLocalDir: filepath.Join(parentDir, "unused-second"),
			author:         "Mac UI Test User",
			s3AccessKeyID:  "",
			s3SecretAccess: "",
			newRepoPath:    "",
		},
		"testRunningMergeDisablesSiblings",
	)
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

// serveBackupRepository creates a fresh, empty repository whose configuration
// matches `srcStorage` and serves it as a second S3 server. This is the sync
// target ("backup") in the sync-repo tests.
func serveBackupRepository(t *testing.T, srcStorage *lib.FileStorage) (string, *lib.FileStorage, func()) {
	t.Helper()
	assert := lib.NewAssert(t)
	srcToml, err := srcStorage.Open(t.Context())
	assert.NoError(err)
	backupFS := td.NewRealFS(t)
	backupStorage, err := lib.NewFileStorage(backupFS, lib.StoragePurposeRepository)
	assert.NoError(err)
	assert.NoError(backupStorage.Init(t.Context(), srcToml, lib.RepositoryConfigHeaderComment))
	assert.NoError(lib.WriteRef(t.Context(), backupStorage, "head", lib.RevisionId{}))
	hostURL, shutdown := serveRepository(t, backupStorage)
	return hostURL, backupStorage, shutdown
}

// serveFaultRepository serves a repository over an S3 server that can inject
// write failures or latency, toggled at runtime over /__test/{reset,
// fail-writes?on=,latency?ms=} on the returned control URL (same port, plain
// http). It returns the s3+http repository URL and the http control URL.
func serveFaultRepository(t *testing.T, storage *lib.FileStorage) (string, string, func()) {
	t.Helper()
	s3Server := clingsynchttp.NewS3StorageServer(storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3Server.RegisterRoutes(mux)
	listener, err := net.Listen("tcp", "127.0.0.1:0") //nolint:noctx
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := &http.Server{Handler: (&faultControl{}).wrap(mux)} //nolint:gosec,exhaustruct
	go server.Serve(listener)                                    //nolint:errcheck
	base := listener.Addr().String()
	return "s3+http://" + base, "http://" + base, func() {
		_ = server.Close()
	}
}

// faultControl injects write failures / latency into an S3 server, toggled at
// runtime over its /__test/... control endpoints. The XCUITest reaches these via
// a raw socket because App Transport Security blocks cleartext-to-localhost.
type faultControl struct {
	mu         sync.Mutex
	failWrites bool
	latency    time.Duration
}

func (c *faultControl) read() (bool, time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.failWrites, c.latency
}

func (c *faultControl) handleControl(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()
	switch r.URL.Path {
	case "/__test/reset":
		c.failWrites = false
		c.latency = 0
	case "/__test/fail-writes":
		c.failWrites = r.URL.Query().Get("on") == "true"
	case "/__test/latency":
		ms, _ := strconv.Atoi(r.URL.Query().Get("ms"))
		c.latency = time.Duration(ms) * time.Millisecond
	default:
		http.NotFound(w, r)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (c *faultControl) wrap(inner http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/__test/") {
			c.handleControl(w, r)
			return
		}
		failWrites, latency := c.read()
		if latency > 0 {
			time.Sleep(latency)
		}
		if failWrites && (r.Method == http.MethodPut || r.Method == http.MethodPost) {
			http.Error(w, "injected write failure", http.StatusInternalServerError)
			return
		}
		inner.ServeHTTP(w, r)
	})
}

type uiTestConfig struct {
	defaultsSuite  string
	hostURL        string
	secondHostURL  string
	syncTargetURL  string
	controlURL     string
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
	resultBundle := xcresultBundle(t, onlyTest)
	t.Cleanup(func() {
		_ = logFile.Close()
		if !t.Failed() {
			_ = os.Remove(logPath)
			_ = os.RemoveAll(resultBundle)
		}
	})
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(
		ctx,
		"xcodebuild",
		"-project", xcodeProjectPath,
		"-scheme", "ClingSyncMac",
		"-destination", "platform=macOS",
		"-test-timeouts-enabled", "YES",
		"-default-test-execution-time-allowance", "120",
		"-maximum-test-execution-time-allowance", "420",
		"-resultBundlePath", resultBundle,
		"-only-testing:ClingSyncMacUITests/ClingSyncMacUITests/"+onlyTest,
		"CODE_SIGN_IDENTITY=-",
		"CODE_SIGNING_REQUIRED=NO",
		"CODE_SIGNING_ALLOWED=YES",
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

func xcresultBundle(t *testing.T, name string) string {
	t.Helper()
	dir := filepath.Join("..", "build", "results")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatalf("create xcresult dir: %v", err)
	}
	bundle := filepath.Join(dir, name+".xcresult")
	_ = os.RemoveAll(bundle)
	return bundle
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
		SyncTargetURL   string `json:"syncTargetUrl,omitempty"`
		ControlURL      string `json:"controlUrl,omitempty"`
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
		SyncTargetURL:   cfg.syncTargetURL,
		ControlURL:      cfg.controlURL,
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
		t.Context(),
		fs,
		repoPath,
		stat,
		repo,
		nil,
		nopCommitMonitor{},
	)
	assert.NoError(err)
	commit, err := lib.NewCommit(t.Context(), repo, td.NewFS(t))
	assert.NoError(err)
	assert.NoError(commit.Add(&lib.RevisionEntry{Path: repoPath, Kind: lib.RevisionEntryKindAdd, Metadata: md}))
	revisionID, err := commit.Commit(t.Context(), &lib.CommitInfo{Author: author, Message: message})
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
	head, err := workspace.Head(t.Context())
	if err != nil {
		t.Fatalf("workspace head: %v", err)
	}
	return head
}
