// Read-only access to a cling-sync repository at its head revision, seen
// through a `lib.RepositoryView`: directory listings and file streaming backed
// by a view snapshot that is rebuilt whenever the head changes. Every path
// that crosses the API is relative to the view's path prefix.
package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
)

var (
	ErrNotFound = errors.New("not found")
	ErrBadPath  = errors.New("invalid path")
	ErrClosed   = errors.New("session closed")
)

// One open repository at its head revision, seen through its view.
//
// The view snapshot lives in temp storage (`lib.Temp`) and is rebuilt
// whenever the repository head changes, so huge repositories never have to
// fit into one in-memory structure.
type Session struct {
	view  *lib.RepositoryView
	tmpFS lib.FS
	state sessionState
}

// How long `Close` waits for in-flight work before canceling it.
const DefaultCloseGrace = 5 * time.Second

// All mutable state of a session.
//
// The fields are only touched by its own methods (`use`, `stream`, `close`),
// which do their own locking, so no caller can get the locking wrong.
type sessionState struct {
	mu sync.Mutex
	// Atomic (not guarded by `mu`) so `close` can refuse new work
	// immediately even while a slow rebuild still holds `mu`.
	closed atomic.Bool
	// `close` cancels this context when the grace period runs out, so no
	// in-flight operation can outlive the session. It is session-scoped, not
	// request-scoped, which is why it lives in the struct.
	closeCtx    context.Context //nolint:containedctx
	closeCancel context.CancelFunc
	snapshot    *lib.ViewSnapshot
	buf         lib.BlockBuf
	generation  int
	snapshotDir string
	inFlight    sync.WaitGroup
}

// Open a repository URI (local path or s3+ URI with embedded
// encrypted credentials) directly, viewed from `pathPrefix`.
//
// `tmpFS` must stay writable for the lifetime of the session.
func NewSession(
	ctx context.Context,
	repositoryURI string,
	passphrase []byte,
	pathPrefix lib.Path,
	tmpFS lib.FS,
) (*Session, error) {
	storage, err := workspace.OpenStorage(repositoryURI, passphrase)
	if err != nil {
		return nil, fmt.Errorf("failed to open storage: %w", err)
	}
	repository, err := lib.OpenRepository(ctx, storage, passphrase)
	if err != nil {
		return nil, fmt.Errorf("failed to open repository: %w", err)
	}
	session := &Session{ //nolint:exhaustruct
		view:  lib.NewRepositoryView(repository, pathPrefix),
		tmpFS: tmpFS,
	}
	session.state.buf = lib.NewBlockBuf()
	//nolint:gosec,fatcontext // The cancel function is stored and called by `close`.
	session.state.closeCtx, session.state.closeCancel = context.WithCancel(context.Background())
	return session, nil
}

// Close the session and everything it owns.
//
// In-flight operations get `grace` to finish naturally; after that they are
// canceled and waited for, because `Repository.Close` wipes the key material
// in place.
func (s *Session) Close(grace time.Duration) error {
	wasOpen, err := s.state.close(grace, s.tmpFS)
	if !wasOpen {
		return nil
	}
	if repoErr := s.view.Repository.Close(); repoErr != nil {
		return fmt.Errorf("failed to close repository: %w", repoErr)
	}
	return err
}

// Return the direct children of `dir` at the current head revision; the empty
// path is the view's root.
func (s *Session) ListDir(ctx context.Context, dir lib.Path) ([]*lib.RevisionEntry, error) {
	entries := []*lib.RevisionEntry{}
	// The entries outlive the locked section on purpose: `lib` guarantees
	// that unmarshalling never aliases the reused `st.buf`.
	err := s.state.use(ctx, s.view, s.tmpFS, func(_ context.Context, st *sessionState) error {
		if !dir.IsEmpty() {
			cache, err := st.snapshot.Cache()
			if err != nil {
				return fmt.Errorf("failed to build snapshot cache: %w", err)
			}
			_, ok, err := cache.Get(lib.PathKey{Path: dir, IsDir: true})
			if err != nil {
				return fmt.Errorf("failed to look up %q: %w", dir.String(), err)
			}
			if !ok {
				return fmt.Errorf("no directory at %q: %w", dir.String(), ErrNotFound)
			}
		}
		dirStr := dir.String()
		reader := st.snapshot.Reader(func(e *lib.RevisionEntry) bool {
			return e.Path.Dir().String() == dirStr
		})
		for {
			entry, err := reader.Read(st.buf)
			if errors.Is(err, io.EOF) {
				return nil
			}
			if err != nil {
				return fmt.Errorf("failed to read snapshot: %w", err)
			}
			entries = append(entries, entry)
		}
	})
	if err != nil {
		return nil, err
	}
	sortEntries(entries)
	return entries, nil
}

// Look up the regular file at `path`.
func (s *Session) ResolveFile(ctx context.Context, path lib.Path) (*lib.RevisionEntry, error) {
	var entry *lib.RevisionEntry
	err := s.state.use(ctx, s.view, s.tmpFS, func(_ context.Context, st *sessionState) error {
		cache, err := st.snapshot.Cache()
		if err != nil {
			return fmt.Errorf("failed to build snapshot cache: %w", err)
		}
		e, ok, err := cache.Get(lib.PathKey{Path: path, IsDir: false})
		if err != nil {
			return fmt.Errorf("failed to look up %q: %w", path.String(), err)
		}
		if !ok || !e.Metadata.FileMode.IsRegular() {
			return fmt.Errorf("no regular file at %q: %w", path.String(), ErrNotFound)
		}
		entry = e
		return nil
	})
	return entry, err
}

// Write the content of `entry` to `w`.
//
// `entry` must be a regular file as returned by `ResolveFile`.
func (s *Session) StreamFile(ctx context.Context, w io.Writer, entry *lib.RevisionEntry) error {
	return s.state.stream(ctx, func(ctx context.Context) error {
		buf := lib.NewBlockBuf()
		for _, blockId := range entry.Metadata.BlockIds {
			data, err := s.view.Repository.ReadBlock(ctx, blockId, buf, lib.ReadBlockOpts{})
			if err != nil {
				return fmt.Errorf("failed to read block of %q: %w", entry.Path.String(), err)
			}
			if _, err := w.Write(data); err != nil {
				return fmt.Errorf("failed to write content of %q: %w", entry.Path.String(), err)
			}
		}
		return nil
	})
}

// Stream a file into `destPath`.
//
// The app glue uses this so file bytes never cross the JS bridge.
func (s *Session) DownloadTo(ctx context.Context, path lib.Path, destPath string) error {
	entry, err := s.ResolveFile(ctx, path)
	if err != nil {
		return err
	}
	dest, err := os.OpenFile(destPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("failed to create %q: %w", destPath, err)
	}
	if err := s.StreamFile(ctx, dest, entry); err != nil {
		_ = dest.Close()
		_ = os.Remove(destPath)
		return err
	}
	if err := dest.Close(); err != nil {
		_ = os.Remove(destPath)
		return fmt.Errorf("failed to close %q: %w", destPath, err)
	}
	return nil
}

// Parse a raw request path; the empty string is the repository root.
func ParsePath(raw string) (lib.Path, error) {
	if raw == "" {
		return lib.Path{}, nil
	}
	path, err := lib.NewPath(raw)
	if err != nil {
		return lib.Path{}, fmt.Errorf("%q: %w", raw, ErrBadPath)
	}
	return path, nil
}

// Run `fn` with exclusive access to a snapshot matching the current
// repository head, rebuilding it first when the head moved.
//
// The context handed to `fn` (and used for the rebuild) is additionally
// canceled when `close` gives up waiting on in-flight work.
func (st *sessionState) use(
	ctx context.Context,
	view *lib.RepositoryView,
	tmpFS lib.FS,
	fn func(ctx context.Context, st *sessionState) error,
) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.closed.Load() {
		return ErrClosed
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	//nolint:contextcheck // Merging in the lifecycle context is the point.
	defer context.AfterFunc(st.closeCtx, cancel)()
	head, err := view.Repository.Head(ctx)
	if err != nil {
		return fmt.Errorf("failed to read repository head: %w", err)
	}
	if st.snapshot == nil || head != st.snapshot.RevisionId {
		if err := st.rebuild(ctx, view, tmpFS, head); err != nil {
			return err
		}
	}
	return fn(ctx, st)
}

// Run `fn` concurrently with other operations; `close` waits for it, because
// `Repository.Close` wipes the key material in place.
//
// The context handed to `fn` is additionally canceled when `close` gives up
// waiting on in-flight work.
func (st *sessionState) stream(ctx context.Context, fn func(ctx context.Context) error) error {
	st.mu.Lock()
	if st.closed.Load() {
		st.mu.Unlock()
		return ErrClosed
	}
	st.inFlight.Add(1)
	st.mu.Unlock()
	defer st.inFlight.Done()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	//nolint:contextcheck // Merging in the lifecycle context is the point.
	defer context.AfterFunc(st.closeCtx, cancel)()
	return fn(ctx)
}

// Flip to closed, wait for in-flight work, and remove the snapshot's temp
// storage.
//
// In-flight work gets `grace` to finish naturally, then it is canceled.
// `wasOpen` is false when the state was already closed.
func (st *sessionState) close(grace time.Duration, tmpFS lib.FS) (wasOpen bool, err error) {
	if !st.closed.CompareAndSwap(false, true) {
		return false, nil
	}
	streamsDone := make(chan struct{})
	go func() {
		st.inFlight.Wait()
		close(streamsDone)
	}()
	select {
	case <-streamsDone:
	case <-time.After(grace):
	}
	st.closeCancel()
	<-streamsDone
	// Waits for any `use` still unwinding from the cancellation. From here
	// the state is unreachable: `use` and `stream` refuse closed sessions.
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.snapshot == nil {
		return true, nil
	}
	err = st.snapshot.Remove()
	_ = tmpFS.RemoveAll(st.snapshotDir)
	st.snapshot = nil
	if err != nil {
		return true, fmt.Errorf("failed to remove snapshot temp storage: %w", err)
	}
	return true, nil
}

// Build a fresh snapshot of `head` and swap it in, removing the old one.
func (st *sessionState) rebuild(
	ctx context.Context,
	view *lib.RepositoryView,
	tmpFS lib.FS,
	head lib.RevisionId,
) error {
	// Use a monotonic increasing generation counter to make sure that multiple
	// attempts at rebuilding the same revision snapshot are fully isolated and
	// do not depend on a failed attempt to clean up properly.
	st.generation++
	subdir := fmt.Sprintf("snapshot-%d-%s", st.generation, head)
	snapshotFS, err := tmpFS.MkSub(subdir)
	if err != nil {
		return fmt.Errorf("failed to create snapshot temp dir: %w", err)
	}
	monitor := workspace.NewDefaultRevisionSnapshotMonitor(workspace.DefaultMonitorModeSilent, func(string) {})
	snapshot, err := view.NewSnapshot(ctx, head, snapshotFS, monitor)
	if err != nil {
		_ = tmpFS.RemoveAll(subdir)
		return fmt.Errorf("failed to build revision snapshot: %w", err)
	}
	if st.snapshot != nil {
		_ = st.snapshot.Remove()
		_ = tmpFS.RemoveAll(st.snapshotDir)
	}
	st.snapshot = snapshot
	st.snapshotDir = subdir
	return nil
}

func sortEntries(entries []*lib.RevisionEntry) {
	slices.SortFunc(entries, func(a, b *lib.RevisionEntry) int {
		aIsDir := a.Metadata.FileMode.IsDir()
		if aIsDir != b.Metadata.FileMode.IsDir() {
			if aIsDir {
				return -1
			}
			return 1
		}
		return strings.Compare(
			strings.ToLower(a.Path.Base().String()),
			strings.ToLower(b.Path.Base().String()),
		)
	})
}
