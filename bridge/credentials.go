// Bridge-managed credential store for S3 repositories.
//
// Each client (Android/iOS/macOS) calls InitBridge once with a writable
// directory. The bridge keeps a JSON map of {cleartextURL: encryptedS3URI}
// there. Clients then work exclusively in cleartext URLs. OpenRepository
// returns the error code "s3_credentials_required" when no encrypted URI is
// stored for the given URL, prompting the UI to ask for the S3 key.
package bridge

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"

	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
)

const credentialsFileName = "s3_credentials.json"

var ErrS3CredentialsRequired = lib.Errorf("S3 credentials required")

//nolint:gochecknoglobals
var (
	credStoreMu   sync.Mutex
	credStorePath string
	credStore     map[string]string
)

// InitBridge sets the writable directory where the credentials map lives.
// Must be called before any S3-backed OpenRepository.
func InitBridge(dataDir string) error {
	credStoreMu.Lock()
	defer credStoreMu.Unlock()
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return lib.WrapErrorf(err, "failed to create bridge data dir")
	}
	credStorePath = filepath.Join(dataDir, credentialsFileName)
	credStore = make(map[string]string)
	data, err := os.ReadFile(credStorePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return lib.WrapErrorf(err, "failed to read credentials file")
	}
	if err := json.Unmarshal(data, &credStore); err != nil {
		return lib.WrapErrorf(err, "failed to parse credentials file")
	}
	return nil
}

// EncryptAndStoreS3Credentials encrypts the provided credentials with the
// passphrase and stores the resulting S3 URI under the cleartext URL key.
func EncryptAndStoreS3Credentials(rawURL, passphrase, accessKeyID, accessKey string) error {
	if !clinghttp.IsS3StorageURI(rawURL) {
		return lib.Errorf("not an S3 URI: %q", rawURL)
	}
	uri, err := clinghttp.EncodeS3URI(
		rawURL,
		clinghttp.S3Credentials{
			AccessKeyID:     accessKeyID,
			SecretAccessKey: []byte(accessKey),
		},
		[]byte(passphrase),
	)
	if err != nil {
		return err //nolint:wrapcheck
	}
	credStoreMu.Lock()
	defer credStoreMu.Unlock()
	if credStorePath == "" {
		return lib.Errorf("bridge not initialized: call initBridge first")
	}
	credStore[canonicalURL(rawURL)] = uri
	return saveCredStoreLocked()
}

// ClearStoredS3Credentials removes the stored encrypted URI for the given cleartext URL.
func ClearStoredS3Credentials(rawURL string) error {
	credStoreMu.Lock()
	defer credStoreMu.Unlock()
	if credStorePath == "" {
		return nil
	}
	delete(credStore, canonicalURL(rawURL))
	return saveCredStoreLocked()
}

// lookupS3URI returns the stored encrypted URI for a cleartext S3 URL.
func lookupS3URI(rawURL string) (string, bool) {
	credStoreMu.Lock()
	defer credStoreMu.Unlock()
	uri, ok := credStore[canonicalURL(rawURL)]
	return uri, ok
}

func saveCredStoreLocked() error {
	data, err := json.Marshal(credStore)
	if err != nil {
		return lib.WrapErrorf(err, "failed to encode credentials")
	}
	if err := os.WriteFile(credStorePath, data, 0o600); err != nil {
		return lib.WrapErrorf(err, "failed to write credentials file")
	}
	return nil
}

func canonicalURL(rawURL string) string {
	return strings.TrimRight(strings.TrimSpace(rawURL), "/")
}
