package main

import (
	iofs "io/fs"
	"net/http"
	"os"
	"os/exec"
	"testing"

	clingsynchttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
)

var td = lib.TestData{} //nolint:gochecknoglobals

const (
	testS3Region          = "us-east-1"
	testS3AccessKeyID     = "minioadmin"
	testS3SecretAccessKey = "minioadmin"
)

func TestAndroidIntegration(t *testing.T) { //nolint:paralleltest
	t.Log("Serving test repository via S3")
	fs := td.NewRealFS(t)
	r := td.NewTestRepository(t, fs)
	assert := lib.NewAssert(t)
	head := r.Head()

	// Start an in-process S3 server in front of the repository storage.
	s3Server := clingsynchttp.NewS3StorageServer(
		r.Storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey,
	)
	mux := http.NewServeMux()
	s3Server.RegisterRoutes(mux)
	server := &http.Server{ //nolint:gosec,exhaustruct
		Addr:    "0.0.0.0:9124",
		Handler: mux,
	}
	go server.ListenAndServe() //nolint:errcheck
	t.Cleanup(func() {
		server.Close() //nolint:errcheck,gosec
	})

	t.Log("Pushing test files to emulator")
	adb := "../tools/android-sdk/platform-tools/adb"

	// Create test directories.
	for _, dir := range []string{
		"/sdcard/DCIM/Camera/vacation",
		"/sdcard/ClingSyncTest/docs",
	} {
		out, err := exec.CommandContext(t.Context(), adb, "shell", "mkdir", "-p", dir).
			CombinedOutput()
		assert.NoError(err, string(out))
	}

	// Push test files: media files to DCIM/Camera, mixed files to ClingSyncTest.
	for _, f := range []struct{ name, path, content string }{
		// DCIM/Camera files (used by testBackupFiles).
		{"blue_sky.jpg", "/sdcard/DCIM/Camera/blue_sky.jpg", "Blue sky"},
		{"red_earth.jpg", "/sdcard/DCIM/Camera/red_earth.jpg", "Red earth"},
		{"green_grass.jpg", "/sdcard/DCIM/Camera/green_grass.jpg", "Green grass"},
		{"sunset.jpg", "/sdcard/DCIM/Camera/vacation/sunset.jpg", "Sunset"},
		// ClingSyncTest files (used by testCustomFolder).
		{"photo.jpg", "/sdcard/ClingSyncTest/photo.jpg", "Test photo"},
		{"video.mp4", "/sdcard/ClingSyncTest/video.mp4", "Test video"},
		{"notes.txt", "/sdcard/ClingSyncTest/notes.txt", "Test notes"},
		{"report.pdf", "/sdcard/ClingSyncTest/docs/report.pdf", "Test report"},
	} {
		tmpFile := t.TempDir() + "/" + f.name
		assert.NoError(os.WriteFile(tmpFile, []byte(f.content), 0o644)) //nolint:gosec
		out, err := exec.CommandContext(t.Context(), adb, "push", tmpFile, f.path).
			CombinedOutput()
		assert.NoError(err, string(out))
	}

	t.Log("Running Android tests")
	embeddedURL, err := clingsynchttp.EncodeS3URI(
		"s3+http://10.0.2.2:9124",
		clingsynchttp.S3Credentials{
			AccessKeyID:     testS3AccessKeyID,
			SecretAccessKey: []byte(testS3SecretAccessKey),
		},
		[]byte(r.Passphrase),
	)
	assert.NoError(err)

	cmd := exec.CommandContext(t.Context(), "./gradlew", "connectedAndroidTest", "-q")
	cmd.Dir = ".."
	cmd.Env = append(os.Environ(),
		"TEST_PASSPHRASE="+r.Passphrase,
		"TEST_SERVER_URL=s3+http://10.0.2.2:9124",
		"TEST_SERVER_URL_EMBEDDED="+embeddedURL,
		"TEST_S3_ACCESS_KEY_ID="+testS3AccessKeyID,
		"TEST_S3_ACCESS_KEY="+testS3SecretAccessKey,
		"TEST_DESTINATION_PATH=/",
	)
	output, err := cmd.CombinedOutput()
	assert.NoError(err, string(output))

	t.Log("Verifying results")
	newHead := r.Head()
	assert.NotEqual(head, newHead, "Head should have changed")

	// Most recent commit (HEAD): media file uploaded from ClingSyncTest.
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"backup", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"backup/photo.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Test photo")},
	}, r.RevisionInfos(newHead))

	revision, err := r.ReadRevision(t.Context(), newHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Contains(*revision.Message, "Backup 1 file")
	assert.Equal("Testinger", *revision.Author)

	// Previous commit (HEAD~1): DCIM files.
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"phone", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera/blue_sky.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Blue sky")},
		{"phone/Camera/red_earth.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Red earth")},
		{"phone/Camera/vacation", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/Camera/vacation/sunset.jpg", lib.RevisionEntryKindAdd, 0o600, td.SHA256("Sunset")},
	}, r.RevisionInfos(revision.ParentRevisionId))
}
