package main

import (
	iofs "io/fs"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	clingsynchttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
)

var td = lib.TestData{} //nolint:gochecknoglobals

const (
	testS3Region          = "us-east-1"
	testS3AccessKeyID     = "minioadmin"
	testS3SecretAccessKey = "minioadmin"
)

// faultControl injects latency and write failures into an S3 server. The
// instrumented test toggles it at runtime via `/__test/...` endpoints, so a
// single emulator run can exercise the upload-failure and abort-mid-upload
// paths without restarting the harness.
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

type testServer struct {
	repo *lib.TestRepository
	// url is the app-facing cleartext S3 URL. The emulator reaches the host
	// loopback via 10.0.2.2.
	url string
}

// startServer serves a fresh repository over an in-process S3 server on the
// given port. When fault is non-nil, its control endpoints inject failures.
func startServer(t *testing.T, port int, fault *faultControl) *testServer {
	t.Helper()
	repo := td.NewTestRepository(t, td.NewRealFS(t))
	s3 := clingsynchttp.NewS3StorageServer(repo.Storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3.RegisterRoutes(mux)
	var handler http.Handler = mux
	if fault != nil {
		handler = fault.wrap(mux)
	}
	server := &http.Server{ //nolint:gosec,exhaustruct
		Addr:    "0.0.0.0:" + strconv.Itoa(port),
		Handler: handler,
	}
	go server.ListenAndServe() //nolint:errcheck
	t.Cleanup(func() { _ = server.Close() })
	return &testServer{repo: repo, url: "s3+http://10.0.2.2:" + strconv.Itoa(port)}
}

func TestAndroidIntegration(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)

	t.Log(
		"Starting repositories (A=main, B=switch-target, scratch=failure/abort/wrong-pass, reattach, mediaSub, docsSub)",
	)
	repoA := startServer(t, 9124, nil)
	repoB := startServer(t, 9125, nil)
	scratch := startServer(t, 9126, &faultControl{})
	reattach := startServer(t, 9127, &faultControl{})
	mediaSub := startServer(t, 9128, nil)
	docsSub := startServer(t, 9129, nil)

	headA := repoA.repo.Head()
	headB := repoB.repo.Head()
	headScratch := scratch.repo.Head()
	headReattach := reattach.repo.Head()
	headMediaSub := mediaSub.repo.Head()
	headDocsSub := docsSub.repo.Head()

	// An S3 URL that already carries its encrypted credentials, so the app can
	// connect to repo A after only the passphrase prompt (no S3 dialog).
	embeddedURL, err := clingsynchttp.EncodeS3URI(
		repoA.url,
		clingsynchttp.S3Credentials{
			AccessKeyID:     testS3AccessKeyID,
			SecretAccessKey: []byte(testS3SecretAccessKey),
		},
		[]byte(repoA.repo.Passphrase),
	)
	assert.NoError(err)

	t.Log("Pushing test files to emulator")
	adb := "../tools/android-sdk/platform-tools/adb"
	for _, dir := range []string{
		"/sdcard/DCIM/Camera/vacation",
		"/sdcard/ClingSyncTest/docs",
		"/sdcard/MediaSub/album",
	} {
		out, err := exec.CommandContext(t.Context(), adb, "shell", "mkdir", "-p", dir).
			CombinedOutput()
		assert.NoError(err, string(out))
	}
	for _, f := range []struct{ name, path, content string }{
		// DCIM/Camera files (used by testBackupFiles + several others).
		{"blue_sky.jpg", "/sdcard/DCIM/Camera/blue_sky.jpg", "Blue sky"},
		{"red_earth.jpg", "/sdcard/DCIM/Camera/red_earth.jpg", "Red earth"},
		{"green_grass.jpg", "/sdcard/DCIM/Camera/green_grass.jpg", "Green grass"},
		{"sunset.jpg", "/sdcard/DCIM/Camera/vacation/sunset.jpg", "Sunset"},
		// ClingSyncTest files (used by the custom-folder + search steps).
		{"photo.jpg", "/sdcard/ClingSyncTest/photo.jpg", "Test photo"},
		{"video.mp4", "/sdcard/ClingSyncTest/video.mp4", "Test video"},
		{"notes.txt", "/sdcard/ClingSyncTest/notes.txt", "Test notes"},
		{"report.pdf", "/sdcard/ClingSyncTest/docs/report.pdf", "Test report"},
		// MediaSub: a media file in a subdirectory (synced under media-only) and a
		// text file in the same subdirectory (excluded under media-only).
		{"root.jpg", "/sdcard/MediaSub/root.jpg", "Root pic"},
		{"beach.jpg", "/sdcard/MediaSub/album/beach.jpg", "Beach pic"},
		{"readme.txt", "/sdcard/MediaSub/album/readme.txt", "Album readme"},
	} {
		tmpFile := t.TempDir() + "/" + f.name
		assert.NoError(os.WriteFile(tmpFile, []byte(f.content), 0o644)) //nolint:gosec
		out, err := exec.CommandContext(t.Context(), adb, "push", tmpFile, f.path).
			CombinedOutput()
		assert.NoError(err, string(out))
	}

	t.Log("Running Android tests")
	arg := func(k, v string) string {
		return "-Pandroid.testInstrumentationRunnerArguments." + k + "=" + v
	}
	cmd := exec.CommandContext(t.Context(), "./gradlew", "connectedAndroidTest", //nolint:gosec
		arg("serverUrl", repoA.url),
		arg("embeddedUrl", embeddedURL),
		arg("switchUrl", repoB.url),
		arg("scratchUrl", scratch.url),
		arg("reattachUrl", reattach.url),
		arg("passphrase", repoA.repo.Passphrase),
		arg("wrongPassphrase", "definitely-the-wrong-passphrase"),
		arg("s3KeyId", testS3AccessKeyID),
		arg("s3Key", testS3SecretAccessKey),
		arg("destination", "/phone/"),
		arg("switchDestination", "/switched/"),
		arg("mediaSubUrl", mediaSub.url),
		arg("docsSubUrl", docsSub.url),
	)
	cmd.Dir = ".."
	output, err := cmd.CombinedOutput()
	assert.NoError(err, string(output))

	t.Log("Verifying repository A (happy path + select-all + search)")
	newHeadA := repoA.repo.Head()
	assert.NotEqual(headA, newHeadA, "Repo A head should have changed")

	// HEAD: the searched-and-uploaded media file from the custom folder.
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"backup", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/photo.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Test photo")},
	}, repoA.repo.RevisionInfos(newHeadA))
	revHead, err := repoA.repo.ReadRevision(t.Context(), newHeadA, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Contains(*revHead.Message, "Backup 1 file")
	assert.Equal("Testinger", *revHead.Author)

	// HEAD~1: green_grass, selected via "Select All" (which must exclude the
	// already-synced files, so this commit contains green_grass alone). The phone
	// and phone/Camera directories already exist from the DCIM commit, so only the
	// new file entry is recorded.
	greenHead := revHead.ParentRevisionId
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"phone/Camera/green_grass.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Green grass")},
	}, repoA.repo.RevisionInfos(greenHead))

	// HEAD~2: the original three DCIM files (now also asserting message+author).
	revGreen, err := repoA.repo.ReadRevision(t.Context(), greenHead, lib.NewBlockBuf())
	assert.NoError(err)
	dcimHead := revGreen.ParentRevisionId
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"phone", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera/blue_sky.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Blue sky")},
		{"phone/Camera/red_earth.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Red earth")},
		{"phone/Camera/vacation", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera/vacation/sunset.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Sunset")},
	}, repoA.repo.RevisionInfos(dcimHead))
	revDcim, err := repoA.repo.ReadRevision(t.Context(), dcimHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Contains(*revDcim.Message, "Backup 3 files")
	assert.Equal("Testinger", *revDcim.Author)

	t.Log("Verifying repository B (repository switch landed here, not in A)")
	newHeadB := repoB.repo.Head()
	assert.NotEqual(headB, newHeadB, "Repo B should have received the switched upload")
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"switched", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"switched/Camera", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"switched/Camera/blue_sky.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Blue sky")},
	}, repoB.repo.RevisionInfos(newHeadB))

	t.Log("Verifying scratch repository is untouched (wrong-pass, failure and abort made no commit)")
	assert.Equal(headScratch, scratch.repo.Head(), "Scratch repo must have no commits")

	t.Log("Verifying reattach repository (the upload completed after the ViewModel was recreated)")
	newHeadReattach := reattach.repo.Head()
	assert.NotEqual(headReattach, newHeadReattach, "Reattach repo should have received the upload")
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"phone", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera/blue_sky.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Blue sky")},
		{"phone/Camera/red_earth.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Red earth")},
	}, reattach.repo.RevisionInfos(newHeadReattach))

	t.Log("Verifying mediaSub repository (subdirectory media file synced, subdirectory text file excluded)")
	newHeadMediaSub := mediaSub.repo.Head()
	assert.NotEqual(headMediaSub, newHeadMediaSub, "MediaSub repo should have received the upload")
	// Entries are ordered files-before-subdirectories within each level, so the
	// top-level root.jpg precedes the album/ subdirectory.
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"backup", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/root.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Root pic")},
		{"backup/album", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/album/beach.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Beach pic")},
	}, mediaSub.repo.RevisionInfos(newHeadMediaSub))

	t.Log("Verifying docsSub repository (non-media subdirectory files synced after the media filter was turned off)")
	newHeadDocsSub := docsSub.repo.Head()
	assert.NotEqual(headDocsSub, newHeadDocsSub, "DocsSub repo should have received the upload")
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"backup", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/letters", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/letters/hello.txt", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Hello letter")},
		{"backup/reports", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/reports/q1.pdf", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Q1 report")},
	}, docsSub.repo.RevisionInfos(newHeadDocsSub))
}
