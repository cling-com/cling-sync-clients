package main

import (
	"crypto/sha256"
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
	cmd := exec.CommandContext(t.Context(), "./build.sh", "test", "--swiftui")
	cmd.Dir = ".."
	cmd.Env = os.Environ()
	output, err := cmd.CombinedOutput()
	assert.NoError(err, string(output))

	t.Log("Verifying results")
	newHead := r.Head()
	assert.NotEqual(head, newHead, "Head should have changed")

	// Second commit (HEAD): uploaded IMG_0004.JPG to uitest/sub/.
	shaImg0004 := sha256.Sum256([]byte("ui test image 4\n"))
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"uitest/sub", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"uitest/sub/IMG_0004.JPG", lib.RevisionEntryKindAdd, 0o600, lib.Sha256(shaImg0004[:])},
	}, r.RevisionInfos(newHead))

	revision, err := r.ReadRevision(newHead, lib.NewBlockBuf())
	assert.NoError(err)
	assert.Equal("Testinger", *revision.Author)
	assert.Contains(*revision.Message, "Backup 1 file")

	// First commit (HEAD~1): uploaded IMG_0001.JPG to uitest/.
	shaImg0001 := sha256.Sum256([]byte("ui test image 1\n"))
	assert.Equal([]lib.TestRevisionEntryInfo{
		{"uitest", lib.RevisionEntryKindAdd, 0o700 | iofs.ModeDir, lib.Sha256{}},
		{"uitest/IMG_0001.JPG", lib.RevisionEntryKindAdd, 0o600, lib.Sha256(shaImg0001[:])},
	}, r.RevisionInfos(revision.ParentRevisionId))
}
