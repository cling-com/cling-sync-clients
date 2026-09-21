package main

import (
	"net"
	"net/http"
	"strings"
	"testing"

	clingsynchttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
)

const (
	testS3KeyID  = "testkeyid1234567"
	testS3Secret = "testsecret123456"
)

var (
	td   = lib.TestData{}                //nolint:gochecknoglobals
	wstd = workspace.WorkspaceTestData{} //nolint:gochecknoglobals
)

func clearS3Env(t *testing.T) {
	t.Helper()
	for _, key := range []string{"CLING_S3_KEY_ID", "CLING_S3_ACCESS_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"} {
		t.Setenv(key, "")
	}
}

func TestReadEnvS3Credentials(t *testing.T) {
	assert := lib.NewAssert(t)

	clearS3Env(t)
	_, ok, err := readEnvS3Credentials()
	assert.NoError(err)
	assert.Equal(false, ok)

	t.Setenv("CLING_S3_KEY_ID", testS3KeyID)
	_, _, err = readEnvS3Credentials()
	assert.Equal(true, err != nil && strings.Contains(err.Error(), "must both be set"))

	t.Setenv("CLING_S3_ACCESS_KEY", "short")
	_, _, err = readEnvS3Credentials()
	assert.Equal(true, err != nil && strings.Contains(err.Error(), "at least"))

	t.Setenv("CLING_S3_ACCESS_KEY", testS3Secret)
	creds, ok, err := readEnvS3Credentials()
	assert.NoError(err)
	assert.Equal(true, ok)
	assert.Equal(testS3KeyID, creds.AccessKeyID)

	clearS3Env(t)
	t.Setenv("AWS_ACCESS_KEY_ID", "aws-key")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "aws-secret")
	creds, ok, err = readEnvS3Credentials()
	assert.NoError(err)
	assert.Equal(true, ok)
	assert.Equal("aws-key", creds.AccessKeyID)
}

// The whole cling-sync CLI parity path: a cleartext s3+ URI plus env
// credentials yields an encrypted URI that opens a real repository served
// over the S3 protocol.
func TestResolveRepositoryURI(t *testing.T) {
	assert := lib.NewAssert(t)
	clearS3Env(t)

	_, err := resolveRepositoryURI("http://example.com", nil, true)
	assert.Equal(true, err != nil)

	uri, err := resolveRepositoryURI("/some/local/path", nil, true)
	assert.NoError(err)
	assert.Equal("/some/local/path", uri)

	// Cleartext s3+ URI without env credentials and without a terminal.
	_, err = resolveRepositoryURI("s3+http://127.0.0.1:1", []byte("test"), true)
	assert.Equal(true, err != nil && strings.Contains(err.Error(), "CLING_S3_KEY_ID"))

	repoDir := t.TempDir()
	r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
	w := wstd.NewTestWorkspace(t, r.Repository)
	w.Write("hello.txt", "hello")
	_, err = workspace.Merge(t.Context(), w.Workspace, r.Repository, wstd.MergeOptions())
	assert.NoError(err)

	s3 := clingsynchttp.NewS3StorageServer(r.Storage, "us-east-1", testS3KeyID, testS3Secret)
	mux := http.NewServeMux()
	s3.RegisterRoutes(mux)
	var lc net.ListenConfig
	listener, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	assert.NoError(err)
	server := &http.Server{Handler: mux} //nolint:gosec,exhaustruct
	go server.Serve(listener)            //nolint:errcheck
	t.Cleanup(func() { _ = server.Close() })

	t.Setenv("CLING_S3_KEY_ID", testS3KeyID)
	t.Setenv("CLING_S3_ACCESS_KEY", testS3Secret)
	resolved, err := resolveRepositoryURI("s3+http://"+listener.Addr().String(), []byte(r.Passphrase), true)
	assert.NoError(err)
	assert.Equal(true, clingsynchttp.S3URIHasEmbeddedCredentials(resolved))

	sess, err := session.NewSession(t.Context(), resolved, []byte(r.Passphrase), lib.Path{}, td.NewFS(t))
	assert.NoError(err)
	t.Cleanup(func() { _ = sess.Close(0) })
	entries, err := sess.ListDir(t.Context(), lib.Path{})
	assert.NoError(err)
	assert.Equal(1, len(entries))
	assert.Equal("hello.txt", entries[0].Path.Base().String())
}
