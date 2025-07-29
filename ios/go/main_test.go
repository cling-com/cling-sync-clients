package main

import (
	"encoding/hex"
	iofs "io/fs"
	"net/http"
	"os"
	"os/exec"
	"testing"

	clingsynchttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
)

var td = lib.TestData{} //nolint:gochecknoglobals

func TestIOSIntegration(t *testing.T) { //nolint:paralleltest
	t.Log("Serving test repository via HTTP")
	fs := td.NewRealFS(t)
	r := td.NewTestRepository(t, fs)
	assert := lib.NewAssert(t)
	head := r.Head()
	assert.Equal("testpassphrase", r.Passphrase)

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

	t.Log("Running iOS tests")
	cmd := exec.Command("./build.sh", "test", "--swiftui")
	cmd.Dir = ".."
	cmd.Env = os.Environ() //nolint:forbidigo
	output, err := cmd.CombinedOutput()
	assert.NoError(err, string(output))

	t.Log("Verifying results")
	newHead := r.Head()
	assert.NotEqual(head, newHead, "Head should have changed")

	// We rely on the iOS simulators always using the same sample photos.
	shaImg0001, err := hex.DecodeString("a7f1d7c31aa85f51347d27fae0b72dfdede4f5d99f3ba69e0be92b834f8c3eb7")
	assert.NoError(err)
	shaImg0004, err := hex.DecodeString("5864d328a5b09805637c971e4a6e8802a184b01d7d1cfe80ff1a61e2783f46f1")
	assert.NoError(err)
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"uitest", lib.RevisionEntryAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"uitest/IMG_0001.JPG", lib.RevisionEntryAdd, 0o600, lib.Sha256(shaImg0001)},
		{"uitest/IMG_0004.JPG", lib.RevisionEntryAdd, 0o600, lib.Sha256(shaImg0004)},
	}, r.RevisionInfos(newHead))

	revision, err := r.ReadRevision(newHead)
	assert.NoError(err)
	assert.Equal("Testinger", revision.Author)
	assert.Contains(revision.Message, "Backup 2 files from")
	// The message should include the device name
	assert.Contains(revision.Message, "Clone")
}
