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

func TestAndroidIntegration(t *testing.T) { //nolint:paralleltest
	t.Log("Serving test repository via HTTP")
	fs := td.NewRealFS(t)
	r := td.NewTestRepository(t, fs)
	assert := lib.NewAssert(t)
	head := r.Head()

	// Start HTTP server.
	httpStorage := clingsynchttp.NewHTTPStorageServer(r.Storage, "http://localhost:9124")
	mux := http.NewServeMux()
	httpStorage.RegisterRoutes(mux)
	server := &http.Server{ //nolint:gosec,exhaustruct
		Addr:    "0.0.0.0:9124",
		Handler: mux,
	}
	go server.ListenAndServe() //nolint:errcheck
	t.Cleanup(func() {
		server.Close() //nolint:errcheck,gosec
	})

	t.Log("Running Android tests")
	cmd := exec.Command("./gradlew", "connectedAndroidTest", "-q")
	cmd.Dir = ".."
	cmd.Env = append(os.Environ(), //nolint:forbidigo
		"TEST_PASSPHRASE="+r.Passphrase,
		"TEST_SERVER_URL=http://10.0.2.2:9124",
		"TEST_DESTINATION_PATH=/",
	)
	output, err := cmd.CombinedOutput()
	assert.NoError(err, string(output))

	t.Log("Verifying results")
	newHead := r.Head()
	assert.NotEqual(head, newHead, "Head should have changed")

	assert.Equal([]lib.TestRevisionEntryInfo{
		{"phone", lib.RevisionEntryAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/camera", lib.RevisionEntryAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"phone/camera/blue_sky.jpg", lib.RevisionEntryAdd, 0o600, td.SHA256("Blue sky")},
		{"phone/camera/red_earth.jpg", lib.RevisionEntryAdd, 0o600, td.SHA256("Red earth")},
	}, r.RevisionInfos(newHead))

	revision, err := r.ReadRevision(newHead)
	assert.NoError(err)
	assert.Contains(revision.Message, "Backup 2 files from Google")
	assert.Equal("Testinger", revision.Author)
}
