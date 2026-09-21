package browse

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
)

func TestExecute(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)

	w.Write("docs/readme.md", "# readme")
	_, err := workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)

	openParams, err := json.Marshal(map[string]string{
		"repositoryUri": repoDir,
		"passphrase":    r.Passphrase,
		"tmpDir":        t.TempDir(),
	})
	assert.NoError(err)
	var opened struct {
		Handle int `json:"handle"`
	}
	assert.NoError(json.Unmarshal([]byte(Execute("open", string(openParams))), &opened))
	assert.Equal(true, opened.Handle > 0)

	var called struct {
		Body string `json:"body"`
	}
	callResult := Execute("call", `{"handle":`+jsonInt(opened.Handle)+`,"target":"dir?path=docs"}`)
	assert.NoError(json.Unmarshal([]byte(callResult), &called))
	assert.Equal(true, strings.Contains(called.Body, "readme.md"))

	destPath := filepath.Join(t.TempDir(), "readme.md")
	downloadParams, err := json.Marshal(map[string]any{
		"handle": opened.Handle, "path": "docs/readme.md", "destPath": destPath,
	})
	assert.NoError(err)
	assert.Equal(`{"success":true}`, Execute("download", string(downloadParams)))
	content, err := os.ReadFile(destPath)
	assert.NoError(err)
	assert.Equal("# readme", string(content))

	assert.Equal(`{"success":true}`, Execute("close", `{"handle":`+jsonInt(opened.Handle)+`}`))
	afterClose := Execute("call", `{"handle":`+jsonInt(opened.Handle)+`,"target":"dir?path=docs"}`)
	assert.Equal(true, strings.Contains(afterClose, `"error"`))

	errResult := Execute("open", `{"tmpDir":""}`)
	assert.Equal(true, strings.Contains(errResult, `"error"`))
}

// Handler error responses (4xx/5xx) must surface as protocol errors so no
// transport ever inserts them into the page as HTML.
func TestExecuteCallErrorStatusBecomesError(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)
	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))

	openParams, err := json.Marshal(map[string]string{
		"repositoryUri": repoDir, "passphrase": r.Passphrase, "tmpDir": t.TempDir(),
	})
	assert.NoError(err)
	var opened struct {
		Handle int `json:"handle"`
	}
	assert.NoError(json.Unmarshal([]byte(Execute("open", string(openParams))), &opened))
	result := Execute("call", `{"handle":`+jsonInt(opened.Handle)+`,"target":"dir?path=..%2Fevil"}`)
	assert.Equal(true, strings.Contains(result, `"error"`))
	assert.Equal(false, strings.Contains(result, `"body"`))
	assert.Equal(`{"success":true}`, Execute("close", `{"handle":`+jsonInt(opened.Handle)+`}`))
}

func jsonInt(value int) string {
	data, _ := json.Marshal(value) //nolint:errchkjson
	return string(data)
}
