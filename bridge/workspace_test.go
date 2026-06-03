package bridge

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/flunderpero/cling-sync/lib"
	"github.com/flunderpero/cling-sync/workspace"
)

var workspaceTestData = lib.TestData{} //nolint:gochecknoglobals

func TestEnsureWorkspaceConfiguredAllowsFileRepository(t *testing.T) {
	t.Parallel()

	assert := lib.NewAssert(t)
	repoFS := workspaceTestData.NewRealFS(t)
	repo := workspaceTestData.NewTestRepository(t, repoFS)
	localPath := filepath.Join(t.TempDir(), "workspace")

	assert.NoError(EnsureWorkspaceConfigured(repoFS.BasePath, localPath, ""))

	ws, err := openWorkspace(localPath)
	assert.NoError(err)
	defer ws.Close() //nolint:errcheck
	assert.Equal(repoFS.BasePath, string(ws.RemoteRepository))
	assert.Equal(workspace.RemoteRepository(repoFS.BasePath), ws.RemoteRepository)
	repository, err := openWorkspaceRepository(ws, repo.Passphrase)
	assert.NoError(err)
	head, err := repository.Head(context.Background())
	assert.NoError(err)
	assert.Equal(repo.Head(), head)
}

// The workspace scratch dir must live under the per-user cache dir (the sandbox
// container on macOS), not os.TempDir(), which the macOS sandbox denies.
func TestNewWorkspaceTempDir(t *testing.T) {
	t.Parallel()

	assert := lib.NewAssert(t)
	cacheDir, err := os.UserCacheDir()
	assert.NoError(err)
	base := filepath.Join(cacheDir, "cling-sync")

	dir1, err := newWorkspaceTempDir()
	assert.NoError(err)
	defer os.RemoveAll(dir1) //nolint:errcheck
	dir2, err := newWorkspaceTempDir()
	assert.NoError(err)
	defer os.RemoveAll(dir2) //nolint:errcheck

	assert.Equal(base, filepath.Dir(dir1))
	// Each call gets its own directory.
	assert.NotEqual(dir1, dir2)
	info, err := os.Stat(dir1)
	assert.NoError(err)
	assert.Equal(true, info.IsDir())
}

// A permission error from the local folder must surface the `local_access_denied`
// code so the macOS app can prompt the user to re-select the folder.
func TestErrorResponseForLocalAccessDenied(t *testing.T) {
	t.Parallel()

	assert := lib.NewAssert(t)

	denied := errorResponseFor(lib.WrapErrorf(fs.ErrPermission, "failed to open workspace"))
	assert.Contains(denied, `"code":"local_access_denied"`)

	other := errorResponseFor(lib.Errorf("some other failure"))
	assert.Equal(false, strings.Contains(other, "local_access_denied"))
}
