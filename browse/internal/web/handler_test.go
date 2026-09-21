package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
)

func TestPage(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("a.txt", "hello a")
	w.Write("docs/readme.md", "# readme")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	handler := newTestHandler(t, repoDir, "")

	resp := get(t, handler, "/")
	assert.Equal(http.StatusOK, resp.Code)
	body := resp.Body.String()
	assert.Equal(true, strings.Contains(body, "a.txt"))
	assert.Equal(true, strings.Contains(body, `data-path="docs"`))
	assert.Equal(true, strings.Contains(body, "<script>"))
}

func TestDirFragment(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("docs/readme.md", "# readme")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	handler := newTestHandler(t, repoDir, "")

	resp := get(t, handler, "/dir?path=docs")
	assert.Equal(http.StatusOK, resp.Code)
	body := resp.Body.String()
	assert.Equal(true, strings.Contains(body, "readme.md"))
	assert.Equal(true, strings.Contains(body, "download?path=docs%2Freadme.md"))
	assert.Equal(false, strings.Contains(body, "<script>"))
}

// File names are repository content, so they must never become markup.
func TestFileNamesAreEscaped(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write(`"><img src=x onerror=alert(1)>.txt`, "evil")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	handler := newTestHandler(t, repoDir, "")

	resp := get(t, handler, "/")
	assert.Equal(http.StatusOK, resp.Code)
	body := resp.Body.String()
	assert.Equal(false, strings.Contains(body, "<img"))
	assert.Equal(true, strings.Contains(body, "&lt;img src=x onerror=alert(1)&gt;.txt"))
}

func TestDownload(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("docs/readme.md", "# readme")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	handler := newTestHandler(t, repoDir, "")

	resp := get(t, handler, "/download?path=docs%2Freadme.md")
	assert.Equal(http.StatusOK, resp.Code)
	assert.Equal("# readme", resp.Body.String())
	assert.Equal("8", resp.Header().Get("Content-Length"))
	assert.Equal(`attachment; filename=readme.md`, resp.Header().Get("Content-Disposition"))

	assert.Equal(http.StatusNotFound, get(t, handler, "/download?path=nope.txt").Code)
	assert.Equal(http.StatusNotFound, get(t, handler, "/download?path=docs").Code)
}

// The path prefix scopes the whole UI: the root view is the prefix itself and
// anything outside the view does not exist.
func TestPathPrefixScopesTheView(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("a.txt", "hello a")
	w.Write("docs/readme.md", "# readme")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)
	handler := newTestHandler(t, repoDir, "docs/")

	resp := get(t, handler, "/")
	assert.Equal(http.StatusOK, resp.Code)
	body := resp.Body.String()
	assert.Equal(true, strings.Contains(body, "readme.md"))
	assert.Equal(false, strings.Contains(body, "a.txt"))

	assert.Equal(http.StatusOK, get(t, handler, "/dir?path=").Code)
	assert.Equal(http.StatusNotFound, get(t, handler, "/dir?path=docs").Code)
	assert.Equal(http.StatusNotFound, get(t, handler, "/download?path=a.txt").Code)
}

// Open a session over the repository at `repoDir` (created with
// `td.NewTestRepository`, hence the fixed passphrase) and return a handler
// over it; the session is closed after the test.
func newTestHandler(t *testing.T, repoDir string, pathPrefix string) http.Handler {
	t.Helper()
	assert := lib.NewAssert(t)
	prefix, err := workspace.ValidatePathPrefix(pathPrefix)
	assert.NoError(err)
	sess, err := session.NewSession(t.Context(), repoDir, []byte("testpassphrase"), prefix, td.NewFS(t))
	assert.NoError(err)
	t.Cleanup(func() { _ = sess.Close(0) })
	return NewHandler(sess)
}

func get(t *testing.T, handler http.Handler, target string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequestWithContext(t.Context(), http.MethodGet, target, nil))
	return recorder
}
