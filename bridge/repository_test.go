package bridge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"os"
	"path/filepath"
	"testing"

	"github.com/flunderpero/cling-sync/lib"
)

var td = lib.TestData{} //nolint:gochecknoglobals

// snapshotFromEntries commits the given entries into a throwaway repository and
// returns a snapshot of its HEAD plus that HEAD revision, the shape
// RepositoryFileHashes.Write consumes.
func snapshotFromEntries(t *testing.T, entries ...*lib.RevisionEntry) (*lib.Temp[*lib.RevisionEntry], lib.RevisionId) {
	t.Helper()
	assert := lib.NewAssert(t)
	repo := td.NewTestRepository(t, td.NewFS(t))
	commit, err := lib.NewCommit(context.Background(), repo.Repository, td.NewFS(t))
	assert.NoError(err)
	for _, entry := range entries {
		assert.NoError(commit.Add(entry))
	}
	_, err = commit.Commit(context.Background(), td.CommitInfo())
	assert.NoError(err)
	snapshot, err := lib.NewRevisionSnapshot(context.Background(), repo.Repository, repo.Head(), td.NewFS(t))
	assert.NoError(err)
	return snapshot, repo.Head()
}

func fileEntry(path, content string) *lib.RevisionEntry {
	return td.RevisionEntryExt(path, lib.RevisionEntryKindAdd, 0o600, content)
}

func setupRepositoryGlobals(t *testing.T) {
	t.Helper()
	repository = nil
	repositoryHostURL = ""
	head = lib.RevisionId{}
	snapshot = nil
	snapshotCache = nil
	Init(t.TempDir())
}

func TestRepositoryFileHashes(t *testing.T) {
	t.Parallel()

	t.Run("New uses the cache dir", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		r := NewRepositoryFileHashes("/some/cache")
		assert.Equal(filepath.Join("/some/cache", "repository_file_hashes.bin"), r.path)
	})

	t.Run("Write, contains, head, and reload from disk", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		cacheDir := t.TempDir()
		snapshot, head := snapshotFromEntries(t, fileEntry("a.jpg", "alpha"), fileEntry("b.jpg", "beta"))

		r := NewRepositoryFileHashes(cacheDir)
		assert.NoError(r.Write(snapshot, head))
		assert.Equal(true, r.Contains(td.SHA256("alpha")))
		assert.Equal(true, r.Contains(td.SHA256("beta")))
		assert.Equal(false, r.Contains(td.SHA256("gamma")))
		assert.Equal(head, r.Head())

		// A fresh instance over the same dir reads the persisted index AND the head it
		// was built for, the case the headless reminder relies on (no Write, cold process).
		reloaded := NewRepositoryFileHashes(cacheDir)
		assert.Equal(true, reloaded.Contains(td.SHA256("alpha")))
		assert.Equal(false, reloaded.Contains(td.SHA256("gamma")))
		assert.Equal(head, reloaded.Head())
	})

	t.Run("Index records its head, is sorted, deduplicated, and skips directories", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		cacheDir := t.TempDir()
		// Two files share content (one hash after dedup); one lives in a subdir,
		// whose directory entry carries a zero hash and must be skipped.
		snapshot, head := snapshotFromEntries(
			t,
			fileEntry("a.jpg", "same"),
			fileEntry("b.jpg", "same"),
			fileEntry("sub/c.jpg", "other"),
		)

		r := NewRepositoryFileHashes(cacheDir)
		assert.NoError(r.Write(snapshot, head))

		data, err := os.ReadFile(r.path)
		assert.NoError(err)
		// The 32-byte head revision precedes the two de-duplicated content hashes.
		assert.Equal(len(head)+2*sha256.Size, len(data))
		assert.Equal(true, bytes.Equal(data[:len(head)], head[:]))
		hashes := data[len(head):]
		for i := sha256.Size; i < len(hashes); i += sha256.Size {
			assert.Equal(true, bytes.Compare(hashes[i-sha256.Size:i], hashes[i:i+sha256.Size]) < 0)
		}
		assert.Equal(true, r.Contains(td.SHA256("same")))
		assert.Equal(true, r.Contains(td.SHA256("other")))
		assert.Equal(false, r.Contains(lib.Sha256{}))
	})

	t.Run("Clear drops memory, head, and file", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		snapshot, head := snapshotFromEntries(t, fileEntry("a.jpg", "alpha"))
		r := NewRepositoryFileHashes(t.TempDir())
		assert.NoError(r.Write(snapshot, head))
		assert.Equal(true, r.Contains(td.SHA256("alpha")))

		r.Clear()

		_, statErr := os.Stat(r.path)
		assert.Equal(true, os.IsNotExist(statErr))
		assert.Equal(false, r.Contains(td.SHA256("alpha")))
		assert.Equal(lib.RevisionId{}, r.Head())
	})

	t.Run("Contains is false without an index", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		r := NewRepositoryFileHashes(t.TempDir())
		assert.Equal(false, r.Contains(td.SHA256("alpha")))
	})
}

func TestRepository(t *testing.T) { //nolint:paralleltest
	t.Run("CheckFiles panics without Init", func(t *testing.T) { //nolint:paralleltest
		repositoryFileHashes = nil
		defer func() {
			if recover() == nil {
				t.Fatal("CheckFiles must panic when Init was not called")
			}
		}()
		_, _ = CheckFiles([]lib.Sha256{td.SHA256("alpha")})
	})

	t.Run("Open, upload, commit, and check membership", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)

		repoDir := filepath.Join(t.TempDir(), "repo")
		assert.NoError(InitNewFileRepository(repoDir, "testpassphrase"))
		assert.NoError(OpenRepository(repoDir, "testpassphrase"))
		assert.Equal(true, CheckRepositoryOpen(repoDir))

		source := filepath.Join(t.TempDir(), "hello.jpg")
		assert.NoError(os.WriteFile(source, []byte("hello world"), 0o600))
		hash := td.SHA256("hello world")

		before, err := CheckFiles([]lib.Sha256{hash})
		assert.NoError(err)
		assert.Equal([]bool{false}, before)

		entry, uploaded, err := UploadFile(source, "phone/hello.jpg")
		assert.NoError(err)
		assert.Equal(true, uploaded)
		assert.NotNil(entry)
		_, err = CommitEntries([]*lib.RevisionEntry{entry}, "Tester", "backup")
		assert.NoError(err)
		assert.NotEqual("", GetRepositoryHeadRevisionID())

		after, err := CheckFiles([]lib.Sha256{hash, td.SHA256("nope")})
		assert.NoError(err)
		assert.Equal([]bool{true, false}, after)

		_, uploaded, err = UploadFile(source, "phone/hello.jpg")
		assert.NoError(err)
		assert.Equal(false, uploaded)
	})

	t.Run("Rebuilds a cleared hash index even when HEAD looks unchanged", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)

		repoDir := filepath.Join(t.TempDir(), "repo")
		assert.NoError(InitNewFileRepository(repoDir, "testpassphrase"))
		assert.NoError(OpenRepository(repoDir, "testpassphrase"))
		source := filepath.Join(t.TempDir(), "a.jpg")
		assert.NoError(os.WriteFile(source, []byte("alpha"), 0o600))
		entry, _, err := UploadFile(source, "a.jpg")
		assert.NoError(err)
		_, err = CommitEntries([]*lib.RevisionEntry{entry}, "Tester", "backup")
		assert.NoError(err)

		// CommitEntries clears the hash index before committing, so it MUST be rebuilt
		// afterwards. A backend whose HEAD read lags the just-committed write makes the
		// refresh see an unchanged HEAD; rebuilding from the known revision (not by
		// re-reading HEAD) must still repopulate the index, otherwise every file scans
		// as new and is re-uploaded forever.
		repositoryFileHashes.Clear()
		found, err := CheckFiles([]lib.Sha256{td.SHA256("alpha")})
		assert.NoError(err)
		assert.Equal([]bool{false}, found)

		assert.NoError(rebuildSnapshot(head))
		found, err = CheckFiles([]lib.Sha256{td.SHA256("alpha")})
		assert.NoError(err)
		assert.Equal([]bool{true}, found)
	})

	t.Run( //nolint:paralleltest
		"EnsureFileHashesAtHead rebuilds a stale index and no-ops a current one",
		func(t *testing.T) {
			setupRepositoryGlobals(t)
			assert := lib.NewAssert(t)

			repoDir := filepath.Join(t.TempDir(), "repo")
			assert.NoError(InitNewFileRepository(repoDir, "testpassphrase"))
			assert.NoError(OpenRepository(repoDir, "testpassphrase"))
			source := filepath.Join(t.TempDir(), "a.jpg")
			assert.NoError(os.WriteFile(source, []byte("alpha"), 0o600))
			entry, _, err := UploadFile(source, "a.jpg")
			assert.NoError(err)
			_, err = CommitEntries([]*lib.RevisionEntry{entry}, "Tester", "backup")
			assert.NoError(err)

			// The index is tagged with the committed HEAD, so a verify is a no-op and keeps
			// the content.
			assert.Equal(GetRepositoryHeadRevisionID(), repositoryFileHashes.Head().String())
			assert.NoError(EnsureFileHashesAtHead())
			found, err := CheckFiles([]lib.Sha256{td.SHA256("alpha")})
			assert.NoError(err)
			assert.Equal([]bool{true}, found)

			// A stale index (a remote merge, a reminder-era index, a missed post-commit
			// rebuild): its head no longer matches HEAD, so the interactive scan's verify
			// must rebuild it. The headless reminder, by contrast, would just use it as-is.
			repositoryFileHashes.Clear()
			assert.NoError(EnsureFileHashesAtHead())
			assert.Equal(GetRepositoryHeadRevisionID(), repositoryFileHashes.Head().String())
			found, err = CheckFiles([]lib.Sha256{td.SHA256("alpha")})
			assert.NoError(err)
			assert.Equal([]bool{true}, found)
		},
	)

	t.Run("EnsureFileHashesAtHead errors when the repository is not open", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)
		assert.Error(EnsureFileHashesAtHead(), "repository not opened")
	})

	t.Run("Close discards everything, including a loaded index", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)

		repoDir := filepath.Join(t.TempDir(), "repo")
		assert.NoError(InitNewFileRepository(repoDir, "testpassphrase"))
		assert.NoError(OpenRepository(repoDir, "testpassphrase"))
		source := filepath.Join(t.TempDir(), "a.jpg")
		assert.NoError(os.WriteFile(source, []byte("alpha"), 0o600))
		entry, _, err := UploadFile(source, "a.jpg")
		assert.NoError(err)
		_, err = CommitEntries([]*lib.RevisionEntry{entry}, "Tester", "backup")
		assert.NoError(err)

		// Drop the in-memory copy and re-read it from disk so the index is genuinely
		// loaded (not just freshly written) before the close.
		indexPath := repositoryFileHashes.path
		repositoryFileHashes.hashes = nil
		found, err := CheckFiles([]lib.Sha256{td.SHA256("alpha")})
		assert.NoError(err)
		assert.Equal([]bool{true}, found)
		assert.Equal(false, repositoryFileHashes.hashes == nil)
		_, statErr := os.Stat(indexPath)
		assert.NoError(statErr)

		closeRepository()

		assert.Equal(true, repository == nil)
		assert.Equal("", repositoryHostURL)
		assert.Equal(lib.RevisionId{}, head)
		assert.Equal(true, snapshot == nil)
		assert.Equal(true, snapshotCache == nil)
		assert.Equal(true, repositoryFileHashes.hashes == nil)
		_, statErr = os.Stat(indexPath)
		assert.Equal(true, os.IsNotExist(statErr))
	})

	t.Run("CheckRepositoryOpen closes on host mismatch", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)

		repoDir := filepath.Join(t.TempDir(), "repo")
		assert.NoError(InitNewFileRepository(repoDir, "testpassphrase"))
		assert.NoError(OpenRepository(repoDir, "testpassphrase"))

		assert.Equal(false, CheckRepositoryOpen("s3+https://other.example.com"))
		assert.Equal(false, CheckRepositoryOpen(repoDir))
	})

	t.Run("CheckFileRepositoryExists", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)

		missing := filepath.Join(t.TempDir(), "absent")
		exists, err := CheckFileRepositoryExists(missing)
		assert.NoError(err)
		assert.Equal(false, exists)

		repoDir := filepath.Join(t.TempDir(), "repo")
		assert.NoError(InitNewFileRepository(repoDir, "testpassphrase"))
		exists, err = CheckFileRepositoryExists(repoDir)
		assert.NoError(err)
		assert.Equal(true, exists)

		_, err = CheckFileRepositoryExists("s3+https://bucket.example.com")
		assert.Error(err, "S3 URI")
	})

	t.Run("GetRepositoryHeadRevisionID is empty when closed", func(t *testing.T) { //nolint:paralleltest
		setupRepositoryGlobals(t)
		assert := lib.NewAssert(t)
		assert.Equal("", GetRepositoryHeadRevisionID())
	})
}
