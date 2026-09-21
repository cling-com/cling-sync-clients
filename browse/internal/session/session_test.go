package session

import (
	"bytes"
	"errors"
	"testing"

	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
)

func TestListDir(t *testing.T) {
	t.Parallel()

	t.Run("Happy path", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("a.txt", "hello a")
		w.Write("docs/readme.md", "# readme")
		w.Write("docs/deep/x.txt", "deep")
		w.Symlink("a.txt", "link")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "")

		entries, err := sess.ListDir(t.Context(), lib.Path{})
		assert.NoError(err)
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Path.Base().String())
		}
		assert.Equal([]string{"docs", "a.txt", "link"}, names)
		assert.Equal(true, entries[0].Metadata.FileMode.IsDir())
		assert.Equal(false, entries[1].Metadata.FileMode.IsDir())
		assert.Equal(true, entries[2].Metadata.FileMode.IsSymlink())
		assert.Equal("a.txt", entries[2].Metadata.SymLinkTarget.String())

		docs, err := sess.ListDir(t.Context(), td.Path("docs"))
		assert.NoError(err)
		assert.Equal(2, len(docs))
		assert.Equal("deep", docs[0].Path.Base().String())
		assert.Equal("readme.md", docs[1].Path.Base().String())
	})

	t.Run("A head change rebuilds the snapshot", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("a.txt", "hello a")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "")

		entries, err := sess.ListDir(t.Context(), lib.Path{})
		assert.NoError(err)
		assert.Equal(1, len(entries))

		w.Write("b.txt", "later")
		_, err = workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)

		entries, err = sess.ListDir(t.Context(), lib.Path{})
		assert.NoError(err)
		assert.Equal(2, len(entries))
	})

	t.Run("A path prefix scopes the view", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("a.txt", "hello a")
		w.Write("docs/readme.md", "# readme")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "docs/")

		entries, err := sess.ListDir(t.Context(), lib.Path{})
		assert.NoError(err)
		assert.Equal(1, len(entries))
		assert.Equal("readme.md", entries[0].Path.String())
	})

	t.Run("A directory that does not exist is not found", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("a.txt", "hello a")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "")

		_, err = sess.ListDir(t.Context(), td.Path("nope"))
		assert.Equal(true, errors.Is(err, ErrNotFound))
	})

	t.Run("A symlink pointing outside the view is hidden", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("a.txt", "hello a")
		w.Write("docs/readme.md", "# readme")
		w.Symlink("../a.txt", "docs/link")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "docs/")

		entries, err := sess.ListDir(t.Context(), lib.Path{})
		assert.NoError(err)
		assert.Equal(1, len(entries))
		assert.Equal("readme.md", entries[0].Path.String())
	})
}

func TestResolveFile(t *testing.T) {
	t.Parallel()

	t.Run("Happy path", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("docs/readme.md", "# readme")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "")

		entry, err := sess.ResolveFile(t.Context(), td.Path("docs/readme.md"))
		assert.NoError(err)
		assert.Equal("docs/readme.md", entry.Path.String())
		assert.Equal(int64(len("# readme")), entry.Metadata.Size)
	})

	t.Run("Directories and symlinks do not resolve", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("docs/readme.md", "# readme")
		w.Symlink("docs/readme.md", "link")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "")

		_, err = sess.ResolveFile(t.Context(), td.Path("docs"))
		assert.Equal(true, errors.Is(err, ErrNotFound))
		_, err = sess.ResolveFile(t.Context(), td.Path("link"))
		assert.Equal(true, errors.Is(err, ErrNotFound))
	})

	t.Run("A path prefix scopes the view", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		w := wstd.NewTestWorkspace(t, r.Repository)

		w.Write("a.txt", "hello a")
		w.Write("docs/readme.md", "# readme")
		_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
		assert.NoError(err)
		sess := newTestSession(t, repoDir, "docs/")

		entry, err := sess.ResolveFile(t.Context(), td.Path("readme.md"))
		assert.NoError(err)
		assert.Equal("readme.md", entry.Path.String())
		// Outside the view the file does not exist as far as the session is
		// concerned.
		_, err = sess.ResolveFile(t.Context(), td.Path("a.txt"))
		assert.Equal(true, errors.Is(err, ErrNotFound))
	})
}

func TestStreamFile(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("docs/readme.md", "# readme")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	sess := newTestSession(t, repoDir, "")

	entry, err := sess.ResolveFile(t.Context(), td.Path("docs/readme.md"))
	assert.NoError(err)
	var buf bytes.Buffer
	assert.NoError(sess.StreamFile(t.Context(), &buf, entry))
	assert.Equal("# readme", buf.String())
}

func TestClose(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("a.txt", "hello a")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	sess := newTestSession(t, repoDir, "")

	entry, err := sess.ResolveFile(t.Context(), td.Path("a.txt"))
	assert.NoError(err)
	assert.NoError(sess.Close(0))
	assert.NoError(sess.Close(0))

	_, err = sess.ListDir(t.Context(), lib.Path{})
	assert.Equal(true, errors.Is(err, ErrClosed))
	var buf bytes.Buffer
	err = sess.StreamFile(t.Context(), &buf, entry)
	assert.Equal(true, errors.Is(err, ErrClosed))
}

func TestParsePath(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)

	path, err := ParsePath("docs/readme.md")
	assert.NoError(err)
	assert.Equal("docs/readme.md", path.String())
	path, err = ParsePath("")
	assert.NoError(err)
	assert.Equal(true, path.IsEmpty())
	_, err = ParsePath("../evil")
	assert.Equal(true, errors.Is(err, ErrBadPath))
}

// Open a session over the repository at `repoDir` (created with
// `td.NewTestRepository`, hence the fixed passphrase) and close it after the
// test.
func newTestSession(t *testing.T, repoDir string, pathPrefix string) *Session {
	t.Helper()
	assert := lib.NewAssert(t)
	prefix, err := workspace.ValidatePathPrefix(pathPrefix)
	assert.NoError(err)
	sess, err := NewSession(t.Context(), repoDir, []byte("testpassphrase"), prefix, td.NewFS(t))
	assert.NoError(err)
	t.Cleanup(func() { _ = sess.Close(0) })
	return sess
}
