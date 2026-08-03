package bridge

import (
	"testing"

	clinghttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
)

func TestEncodeS3URIRoundTrip(t *testing.T) {
	t.Parallel()
	assert := lib.NewAssert(t)

	rawURL := "s3+https://bucket.s3.nl-ams.scw.cloud/some/prefix"
	passphrase := "test-passphrase-123"
	uri, err := EncodeS3URI(rawURL, "AKID", "secret", passphrase)
	assert.NoError(err)
	if uri == rawURL {
		t.Fatalf("encoded URI must differ from the raw URL: %q", uri)
	}

	// The encoded URI carries its credentials and is directly openable.
	assert.Equal(true, clinghttp.S3URIHasEmbeddedCredentials(uri))
	cfg, _, err := clinghttp.DecodeS3URI(uri, []byte(passphrase))
	assert.NoError(err)
	assert.Equal("AKID", cfg.AccessKeyID)

	storage, err := workspace.OpenStorage(uri, []byte(passphrase))
	assert.NoError(err)
	if storage == nil {
		t.Fatal("expected non-nil storage for an embedded-credentials URI")
	}
}

func TestEncodeS3URIRejectsNonS3(t *testing.T) {
	t.Parallel()
	if _, err := EncodeS3URI("/local/path", "AKID", "secret", "pass"); err == nil {
		t.Fatal("expected an error for a non-S3 URL")
	}
}
