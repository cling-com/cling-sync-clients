package browse

import (
	"errors"
	"os"
	"testing"

	"github.com/cling-com/cling-sync/lib"
	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
)

func TestRegistry(t *testing.T) {
	t.Parallel()
	openSession := func(t *testing.T, repoDir string, passphrase string) (*session.Session, string) {
		t.Helper()
		assert := lib.NewAssert(t)
		tmpDir := t.TempDir()
		sess, err := session.NewSession(t.Context(), repoDir, []byte(passphrase), lib.Path{}, lib.NewRealFS(tmpDir))
		assert.NoError(err)
		return sess, tmpDir
	}

	t.Run("closeAll closes every session and removes its temp dir", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		reg := newRegistry()
		sessA, tmpA := openSession(t, repoDir, r.Passphrase)
		sessB, tmpB := openSession(t, repoDir, r.Passphrase)
		idA, err := reg.add(sessA, tmpA, reg.currentEpoch())
		assert.NoError(err)
		idB, err := reg.add(sessB, tmpB, reg.currentEpoch())
		assert.NoError(err)

		assert.NoError(reg.closeAll())

		_, err = reg.call(idA, "/")
		assert.Equal(true, errors.Is(err, session.ErrNotFound))
		_, err = reg.call(idB, "/")
		assert.Equal(true, errors.Is(err, session.ErrNotFound))
		_, err = os.Stat(tmpA)
		assert.Equal(true, errors.Is(err, os.ErrNotExist))
		_, err = os.Stat(tmpB)
		assert.Equal(true, errors.Is(err, os.ErrNotExist))
		assert.NoError(reg.close(idA))
	})

	t.Run("A session opened across closeAll is closed instead of registered", func(t *testing.T) {
		t.Parallel()
		assert := lib.NewAssert(t)
		repoDir := t.TempDir()
		r := td.NewTestRepository(t, lib.NewRealFS(repoDir))
		reg := newRegistry()
		epoch := reg.currentEpoch()
		sess, tmpDir := openSession(t, repoDir, r.Passphrase)

		assert.NoError(reg.closeAll())
		_, err := reg.add(sess, tmpDir, epoch)

		assert.Equal(true, errors.Is(err, ErrClosedWhileOpening))
		_, err = os.Stat(tmpDir)
		assert.Equal(true, errors.Is(err, os.ErrNotExist))
		_, err = sess.ListDir(t.Context(), lib.Path{})
		assert.Equal(true, errors.Is(err, session.ErrClosed))
	})
}
