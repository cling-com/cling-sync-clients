package bridge

import (
	"path/filepath"
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
	head, err := repository.Head()
	assert.NoError(err)
	assert.Equal(repo.Head(), head)
}
