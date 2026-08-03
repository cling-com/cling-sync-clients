package main

import (
	"crypto/sha256"
	iofs "io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	clingsynchttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
)

var td = lib.TestData{} //nolint:gochecknoglobals

const (
	testS3Region          = "us-east-1"
	testS3AccessKeyID     = "minioadmin"
	testS3SecretAccessKey = "minioadmin"
)

// uiTestRepo is a fresh repository served over an in-process S3 server on an
// ephemeral 127.0.0.1 port (the simulator shares the host loopback).
type uiTestRepo struct {
	repo *lib.TestRepository
	url  string // cleartext s3+http://127.0.0.1:port
}

func newUITestRepo(t *testing.T) *uiTestRepo {
	t.Helper()
	repo := td.NewTestRepository(t, td.NewRealFS(t))
	s3 := clingsynchttp.NewS3StorageServer(repo.Storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3.RegisterRoutes(mux)
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: mux} //nolint:gosec,exhaustruct
	go server.Serve(ln)                  //nolint:errcheck
	t.Cleanup(func() { _ = server.Close() })
	return &uiTestRepo{repo: repo, url: "s3+http://" + ln.Addr().String()}
}

// faultRepo serves a repository over an S3 server that can inject write failures
// or latency, toggled at runtime over /__test/{reset,fail-writes?on=,latency?ms=}
// on its controlURL.
type faultRepo struct {
	url        string // cleartext s3+http://127.0.0.1:port
	controlURL string // http://127.0.0.1:port
}

func newFaultRepo(t *testing.T) *faultRepo {
	t.Helper()
	repo := td.NewTestRepository(t, td.NewRealFS(t))
	s3 := clingsynchttp.NewS3StorageServer(repo.Storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3.RegisterRoutes(mux)
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: (&faultControl{}).wrap(mux)} //nolint:gosec,exhaustruct
	go server.Serve(ln)                                          //nolint:errcheck
	t.Cleanup(func() { _ = server.Close() })
	base := ln.Addr().String()
	return &faultRepo{url: "s3+http://" + base, controlURL: "http://" + base}
}

// faultControl injects write failures / latency into an S3 server, toggled at
// runtime over its /__test/... control endpoints.
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

// TestIOSIntegration drives the full SwiftUI XCUITest suite against real Go
// bridges and in-process S3 servers. Each scenario gets its own isolated
// repository (passed by URL via the test environment) so they never interfere,
// then the Go side verifies what actually landed in the repositories.
func TestIOSIntegration(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)

	main := newUITestRepo(t)
	switchTarget := newUITestRepo(t)
	multi := newUITestRepo(t)
	share := newUITestRepo(t)
	abort := newFaultRepo(t)
	failure := newFaultRepo(t)
	assert.Equal("testpassphrase", main.repo.Passphrase)

	embeddedURL, err := clingsynchttp.EncodeS3URI(
		main.url,
		clingsynchttp.S3Credentials{
			AccessKeyID:     testS3AccessKeyID,
			SecretAccessKey: []byte(testS3SecretAccessKey),
		},
		[]byte(main.repo.Passphrase),
	)
	assert.NoError(err)

	mainHead := main.repo.Head()
	multiHead := multi.repo.Head()
	shareHead := share.repo.Head()

	t.Log("Running iOS UI tests")
	env := []string{
		"TEST_HOST_URL=" + main.url,
		"TEST_HOST_URL_EMBEDDED=" + embeddedURL,
		"TEST_SWITCH_URL=" + switchTarget.url,
		"TEST_MULTI_URL=" + multi.url,
		"TEST_SHARE_URL=" + share.url,
		"TEST_ABORT_URL=" + abort.url,
		"TEST_ABORT_CONTROL_URL=" + abort.controlURL,
		"TEST_FAILURE_URL=" + failure.url,
		"TEST_FAILURE_CONTROL_URL=" + failure.controlURL,
		"TEST_S3_ACCESS_KEY_ID=" + testS3AccessKeyID,
		"TEST_S3_ACCESS_KEY=" + testS3SecretAccessKey,
	}
	cmd := exec.CommandContext(t.Context(), "./build.sh", "test", "--swiftui")
	cmd.Dir = ".."
	cmd.Env = os.Environ()
	for _, e := range env {
		// xcodebuild forwards variables to the XCUITest runner only when prefixed
		// with TEST_RUNNER_ (the prefix is stripped before the runner sees them).
		cmd.Env = append(cmd.Env, "TEST_RUNNER_"+e)
	}
	output, err := cmd.CombinedOutput()
	assert.NoError(err, string(output))

	t.Log("Verifying results")
	verifyHappyPath(t, main, mainHead)
	verifyShareUpload(t, share, shareHead)

	// The multi-select scenario uploads both fixtures in a single commit.
	assert.NotEqual(multiHead, multi.repo.Head(), "multi-select repository should have a new commit")

	// switchTarget exists only so the switch scenario points at a different
	// repository id. It intentionally receives no commit.
	_ = switchTarget
}

// verifyHappyPath asserts the two commits the happy-path scenario makes:
// IMG_0001.JPG -> uitest/ then IMG_0004.JPG -> uitest/sub/.
func verifyHappyPath(t *testing.T, repo *uiTestRepo, initialHead lib.RevisionId) {
	t.Helper()
	assert := lib.NewAssert(t)
	r := repo.repo
	newHead := r.Head()
	assert.NotEqual(initialHead, newHead, "Head should have changed")

	shaImg0004 := sha256.Sum256([]byte("ui test image 4\n"))
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"uitest/sub", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"uitest/sub/IMG_0004.JPG", lib.RevisionEntryKindAdd, 0o600, lib.Sha256(shaImg0004[:])},
	}, r.RevisionInfos(newHead))

	revision, err := r.ReadRevision(t.Context(), newHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Equal("Testinger", *revision.Author)
	assert.Contains(*revision.Message, "Backup 1 file")

	shaImg0001 := sha256.Sum256([]byte("ui test image 1\n"))
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"uitest", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"uitest/IMG_0001.JPG", lib.RevisionEntryKindAdd, 0o600, lib.Sha256(shaImg0001[:])},
	}, r.RevisionInfos(revision.ParentRevisionId))
}

// verifyShareUpload asserts the share scenario committed the staged fixture to the
// edited target directory: shared-note.txt -> shared/.
func verifyShareUpload(t *testing.T, repo *uiTestRepo, initialHead lib.RevisionId) {
	t.Helper()
	assert := lib.NewAssert(t)
	r := repo.repo
	newHead := r.Head()
	assert.NotEqual(initialHead, newHead, "share repository should have a new commit")

	sha := sha256.Sum256([]byte("shared from ios\n"))
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"shared", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"shared/shared-note.txt", lib.RevisionEntryKindAdd, 0o600, lib.Sha256(sha[:])},
	}, r.RevisionInfos(newHead))

	revision, err := r.ReadRevision(t.Context(), newHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Equal("Testinger", *revision.Author)
	assert.Contains(*revision.Message, "Backup 1 file")
}
