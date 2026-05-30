package bridge

import (
	"encoding/json"
	"testing"

	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
)

// These tests share the bridge's global credentials store, so they cannot run
// in parallel with each other.
func TestOpenRepositoryReportsMissingCredentials(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	assert.NoError(InitBridge(t.TempDir()))

	params, err := json.Marshal(struct { //nolint:gosec // test payload, not a real credential
		HostURL  string `json:"hostUrl"`
		Password string `json:"password"`
	}{
		HostURL:  "s3+https://bucket.s3.nl-ams.scw.cloud/some/prefix",
		Password: "passphrase",
	})
	assert.NoError(err)
	result := Execute("openRepository", string(params))
	var parsed struct {
		Error *struct {
			Message string `json:"message"`
			Code    string `json:"code"`
		} `json:"error,omitempty"`
	}
	assert.NoError(json.Unmarshal([]byte(result), &parsed))
	if parsed.Error == nil {
		t.Fatalf("expected error, got %q", result)
	}
	assert.Equal("s3_credentials_required", parsed.Error.Code)
}

func TestEncryptAndStoreS3CredentialsPersists(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	dataDir := t.TempDir()

	assert.NoError(InitBridge(dataDir))
	rawURL := "s3+https://bucket.s3.nl-ams.scw.cloud/some/prefix"
	params, err := json.Marshal(struct { //nolint:gosec // test payload, not a real credential
		HostURL     string `json:"hostUrl"`
		Passphrase  string `json:"passphrase"`
		AccessKeyID string `json:"accessKeyId"`
		AccessKey   string `json:"accessKey"`
	}{
		HostURL:     rawURL,
		Passphrase:  "pass",
		AccessKeyID: "AKID",
		AccessKey:   "secret",
	})
	assert.NoError(err)
	res := Execute("encryptAndStoreS3Credentials", string(params))
	var ok struct {
		Success bool `json:"success"`
		Error   *struct {
			Message string `json:"message"`
		} `json:"error,omitempty"`
	}
	assert.NoError(json.Unmarshal([]byte(res), &ok))
	if ok.Error != nil {
		t.Fatalf("unexpected error: %s", ok.Error.Message)
	}
	assert.Equal(true, ok.Success)

	// Now lookup the encrypted URI for this URL.
	encrypted, found := lookupS3URI(rawURL)
	assert.Equal(true, found)
	if encrypted == rawURL {
		t.Fatalf("encrypted URI should not equal raw URL: %q", encrypted)
	}

	// And clearing should remove it.
	clearParams, err := json.Marshal(struct {
		HostURL string `json:"hostUrl"`
	}{HostURL: rawURL})
	assert.NoError(err)
	res = Execute("clearStoredS3Credentials", string(clearParams))
	assert.NoError(json.Unmarshal([]byte(res), &ok))
	if ok.Error != nil {
		t.Fatalf("unexpected error: %s", ok.Error.Message)
	}
	_, found = lookupS3URI(rawURL)
	assert.Equal(false, found)
}

// A URL that already carries the encrypted credentials in its userinfo should
// be usable directly, with no entry in the credentials store.
func TestOpenStorageAcceptsEmbeddedCredentials(t *testing.T) { //nolint:paralleltest
	assert := lib.NewAssert(t)
	assert.NoError(InitBridge(t.TempDir()))

	rawURL := "s3+https://bucket.s3.nl-ams.scw.cloud/some/prefix"
	passphrase := []byte("test-passphrase-123")
	embedded, err := clinghttp.EncodeS3URI(
		rawURL,
		clinghttp.S3Credentials{
			AccessKeyID:     "AKID",
			SecretAccessKey: []byte("secret"),
		},
		passphrase,
	)
	assert.NoError(err)

	storage, err := openStorage(embedded, passphrase)
	assert.NoError(err)
	if storage == nil {
		t.Fatalf("expected non-nil storage for embedded-credentials URI")
	}
	_, found := lookupS3URI(rawURL)
	assert.Equal(false, found)
}
