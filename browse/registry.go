package browse

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
	"github.com/flunderpero/cling-sync-clients/browse/internal/web"
)

var ErrClosedWhileOpening = errors.New("all sessions were closed while this one was opening")

// Integer handles for sessions, so the cgo/JNI glue in the apps only ever
// moves strings and ints across the language boundary.
type registry struct {
	mu     sync.Mutex
	nextID int
	// Bumped by `closeAll`. A session whose open started in an older epoch
	// is closed instead of registered, so no open that was in flight during
	// `closeAll` can bring a repository back.
	epoch    int
	sessions map[int]registeredSession
}

type registeredSession struct {
	session *session.Session
	handler http.Handler
	// Owned by the session and removed when it is closed.
	tmpDir string
}

func newRegistry() *registry {
	return &registry{sessions: map[int]registeredSession{}} //nolint:exhaustruct
}

// Return the epoch that must be passed to `add` for a session opened from
// now on.
func (r *registry) currentEpoch() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.epoch
}

// Register `sess` and return its handle.
//
// If `closeAll` ran since `epoch` was read, `sess` is closed, `tmpDir` is
// removed, and ErrClosedWhileOpening is returned.
func (r *registry) add(sess *session.Session, tmpDir string, epoch int) (int, error) {
	entry := registeredSession{session: sess, handler: web.NewHandler(sess), tmpDir: tmpDir}
	r.mu.Lock()
	if epoch != r.epoch {
		r.mu.Unlock()
		return 0, errors.Join(ErrClosedWhileOpening, closeEntry(entry, 0))
	}
	r.nextID++
	r.sessions[r.nextID] = entry
	id := r.nextID
	r.mu.Unlock()
	return id, nil
}

func (r *registry) call(id int, target string) (callResult, error) {
	entry, err := r.get(id)
	if err != nil {
		return callResult{}, err
	}
	return call(context.Background(), entry.handler, target)
}

func (r *registry) downloadTo(id int, path string, destPath string) error {
	entry, err := r.get(id)
	if err != nil {
		return err
	}
	parsed, err := session.ParsePath(path)
	if err != nil {
		return err
	}
	return entry.session.DownloadTo(context.Background(), parsed, destPath)
}

// Closing an unknown handle is a no-op, it may already be gone through
// `closeAll`.
func (r *registry) close(id int) error {
	r.mu.Lock()
	entry, ok := r.sessions[id]
	delete(r.sessions, id)
	r.mu.Unlock()
	if !ok {
		return nil
	}
	return closeEntry(entry, session.DefaultCloseGrace)
}

// Close every session right away, canceling in-flight work instead of
// waiting for it.
func (r *registry) closeAll() error {
	r.mu.Lock()
	r.epoch++
	entries := r.sessions
	r.sessions = map[int]registeredSession{}
	r.mu.Unlock()
	errs := make([]error, 0, len(entries))
	for _, entry := range entries {
		errs = append(errs, closeEntry(entry, 0))
	}
	return errors.Join(errs...)
}

func (r *registry) get(id int) (registeredSession, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	entry, ok := r.sessions[id]
	if !ok {
		return registeredSession{}, fmt.Errorf("unknown session handle %d: %w", id, session.ErrNotFound)
	}
	return entry, nil
}

func closeEntry(entry registeredSession, grace time.Duration) error {
	err := entry.session.Close(grace)
	if rmErr := os.RemoveAll(entry.tmpDir); rmErr != nil {
		err = errors.Join(err, fmt.Errorf("failed to remove temp dir: %w", rmErr))
	}
	return err
}
