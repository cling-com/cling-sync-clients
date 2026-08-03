package bridge

import (
	clinghttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
)

// EncodeS3URI builds an `s3+...` repository URI that carries the given S3
// credentials encrypted with `passphrase`. The client stores the result and
// sends it as the repository; the bridge keeps no credential state of its own.
func EncodeS3URI(rawURL, accessKeyID, accessKey, passphrase string) (string, error) {
	if !clinghttp.IsS3StorageURI(rawURL) {
		return "", lib.Errorf("not an S3 URI: %q", rawURL)
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
		return "", err //nolint:wrapcheck
	}
	return uri, nil
}
