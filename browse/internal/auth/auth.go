// Reading the passphrase a workspace saved to stay authenticated, mirroring
// the cling-sync CLI: the AEAD-encrypted passphrase lives in the workspace,
// the encryption key in the OS keychain. Neither alone unlocks anything.
package auth

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/cling-com/cling-sync/keychain"
	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
)

// Same keychain service the cling-sync CLI and the app bridge use, so a
// passphrase saved by either of them works here too.
const keychainService = "com.cling.sync"

var ErrPassphraseRequired = errors.New("passphrase required")

// Read the saved passphrase of `ws`.
//
// ErrPassphraseRequired is returned when the workspace has no saved
// passphrase or the keychain entry is missing, so callers can prompt.
func ReadSavedPassphrase(ctx context.Context, ws *workspace.Workspace) ([]byte, error) {
	keyHex, err := keychain.GetKeychainEntry(ctx, keychainService, string(ws.RemoteRepository))
	if errors.Is(err, keychain.ErrKeychainEntryNotFound) {
		return nil, ErrPassphraseRequired
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read keychain entry: %w", err)
	}
	keyBytes, err := hex.DecodeString(keyHex)
	if err != nil || len(keyBytes) != len(lib.RawKey{}) {
		return nil, fmt.Errorf("malformed keychain entry: %w", ErrPassphraseRequired)
	}
	cipher, err := lib.NewCipher(lib.RawKey(keyBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create cipher: %w", err)
	}
	passphrase, err := ws.ReadSavedPassphrase(ctx, cipher)
	if errors.Is(err, workspace.ErrSavedPassphraseNotFound) {
		return nil, ErrPassphraseRequired
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read saved passphrase: %w", err)
	}
	return passphrase, nil
}
