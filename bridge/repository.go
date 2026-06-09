package bridge

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
	"github.com/flunderpero/cling-sync/workspace"
)

var (
	repository        *lib.Repository                    //nolint:gochecknoglobals
	repositoryHostURL string                             //nolint:gochecknoglobals
	head              lib.RevisionId                     //nolint:gochecknoglobals
	snapshot          *lib.Temp[*lib.RevisionEntry]      //nolint:gochecknoglobals
	snapshotCache     *lib.TempCache[*lib.RevisionEntry] //nolint:gochecknoglobals

	repositoryFileHashes *RepositoryFileHashes //nolint:gochecknoglobals
)

// Init sets the directory the bridge writes its caches to. Apps must call this
// once at startup before the repository file hash index can be persisted or read.
func Init(cacheDir string) {
	repositoryFileHashes = NewRepositoryFileHashes(cacheDir)
}

// CheckRepositoryOpen returns true if a repository is currently open for the given host URL.
// If the repository is open but the host URL does not match, it is closed to prevent misuse.
func CheckRepositoryOpen(hostURL string) bool {
	if repository == nil {
		return false
	}
	if repositoryHostURL != hostURL {
		closeRepository()
		return false
	}
	return true
}

// CheckFileRepositoryExists reports whether a cling repository exists on the
// local filesystem at the given path. Callers must only invoke this for local
// paths. S3 URIs are rejected so the call site has to decide explicitly
// whether a remote check makes sense.
func CheckFileRepositoryExists(localPath string) (bool, error) {
	if clinghttp.IsS3StorageURI(localPath) {
		return false, lib.Errorf("CheckFileRepositoryExists called with S3 URI: %s", localPath)
	}
	stat, statErr := os.Stat(localPath)
	if statErr != nil {
		if errors.Is(statErr, os.ErrNotExist) {
			return false, nil
		}
		return false, lib.WrapErrorf(statErr, "failed to stat %s", localPath)
	}
	if !stat.IsDir() {
		return false, lib.Errorf("%s is not a directory", localPath)
	}
	storage, err := lib.NewFileStorage(lib.NewRealFS(localPath), lib.StoragePurposeRepository)
	if err != nil {
		return false, lib.WrapErrorf(err, "failed to open file storage at %s", localPath)
	}
	if _, err := storage.Open(context.Background()); err != nil {
		if errors.Is(err, lib.ErrStorageNotFound) {
			return false, nil
		}
		return false, lib.WrapErrorf(err, "failed to read repository config at %s", localPath)
	}
	return true, nil
}

// InitNewFileRepository creates a fresh cling repository on the local filesystem at the
// given path, protected by the given passphrase. The path must not already host a
// repository (or the underlying lib.InitNewRepository call will fail).
func InitNewFileRepository(localPath, passphrase string) error {
	if clinghttp.IsS3StorageURI(localPath) {
		return lib.Errorf("cannot initialize a new file repository at S3 URI: %s", localPath)
	}
	if passphrase == "" {
		return lib.Errorf("passphrase must not be empty")
	}
	if err := os.MkdirAll(localPath, 0o750); err != nil {
		return lib.WrapErrorf(err, "failed to create repository directory %s", localPath)
	}
	storage, err := lib.NewFileStorage(lib.NewRealFS(localPath), lib.StoragePurposeRepository)
	if err != nil {
		return lib.WrapErrorf(err, "failed to open file storage at %s", localPath)
	}
	if _, err := lib.InitNewRepository(context.Background(), storage, []byte(passphrase)); err != nil {
		return lib.WrapErrorf(err, "failed to initialize new repository at %s", localPath)
	}
	return nil
}

// GetRepositoryHeadRevisionID returns the current HEAD revision ID or an empty string.
func GetRepositoryHeadRevisionID() string {
	if repository == nil || head == (lib.RevisionId{}) {
		return ""
	}
	return head.String()
}

// OpenRepository closes any existing repository and opens a new one. `hostURL`
// is a local path or an `s3+...` URI carrying its encrypted credentials.
func OpenRepository(hostURL, password string) error {
	closeRepository()
	storage, err := workspace.OpenStorage(hostURL, []byte(password))
	if err != nil {
		return lib.WrapErrorf(err, "failed to open repository storage")
	}
	repository, err = lib.OpenRepository(context.Background(), storage, []byte(password))
	if err != nil {
		return lib.WrapErrorf(err, "failed to open repository")
	}
	repositoryHostURL = hostURL
	if err := refreshSnapshot(); err != nil {
		closeRepository()
		return err
	}
	return nil
}

func refreshSnapshot() error {
	currentHead, err := repository.Head(context.Background())
	if err != nil {
		return lib.WrapErrorf(err, "failed to get HEAD revision")
	}
	if currentHead == head && snapshot != nil {
		return nil
	}
	return rebuildSnapshot(currentHead)
}

// rebuildSnapshot rebuilds the snapshot, revision cache and file-hash index for the
// given revision unconditionally. CommitEntries calls it with the revision it just
// wrote rather than re-reading HEAD: the hash index is cleared before a commit, so
// it MUST be rebuilt afterwards, but a caching/eventually-consistent backend can
// still report the old HEAD right after the write, which would otherwise skip the
// rebuild via the refreshSnapshot early-return and leave the index empty (so every
// already-uploaded file scans as new and is uploaded again).
func rebuildSnapshot(revision lib.RevisionId) error {
	ctx := context.Background()
	head = revision
	tmpFs := lib.NewMemoryFS(500_000_000)
	newSnapshot, err := lib.NewRevisionSnapshot(ctx, repository, revision, tmpFs)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create revision snapshot")
	}
	snapshot = newSnapshot
	snapshotCache, err = lib.NewRevisionEntryTempCache(snapshot, 10)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create revision cache")
	}
	if err := repositoryFileHashes.Write(snapshot, revision); err != nil {
		return lib.WrapErrorf(err, "failed to write repository file hash index")
	}
	return nil
}

// EnsureFileHashesAtHead makes the persisted hash index reflect the repository's
// current HEAD, rebuilding it when it was written for a different revision (a remote
// merge, a stale prior-session index, an eventually-consistent commit). The
// interactive scan/share call this before checking membership, since the repository
// is open. The headless merge reminder does NOT: it cannot open the repository and
// answers from whatever index the last foreground session left.
func EnsureFileHashesAtHead() error {
	if repository == nil {
		return lib.Errorf("repository not opened - call 'OpenRepository' first")
	}
	currentHead, err := repository.Head(context.Background())
	if err != nil {
		return lib.WrapErrorf(err, "failed to get HEAD revision")
	}
	if repositoryFileHashes.Head() == currentHead {
		return nil
	}
	return rebuildSnapshot(currentHead)
}

func closeRepository() {
	repository = nil
	repositoryHostURL = ""
	head = lib.RevisionId{}
	snapshot = nil
	snapshotCache = nil
	repositoryFileHashes.Clear()
}

// RepositoryFileHashes is the sorted set of file content hashes in the
// repository's HEAD, kept in memory and persisted to disk so membership can be
// answered without the repository open.
type RepositoryFileHashes struct {
	path   string
	head   lib.RevisionId
	hashes []lib.Sha256
}

const repositoryFileHashesFileName = "repository_file_hashes.bin"

func NewRepositoryFileHashes(cacheDir string) *RepositoryFileHashes {
	return &RepositoryFileHashes{
		path:   filepath.Join(cacheDir, repositoryFileHashesFileName),
		head:   lib.RevisionId{},
		hashes: nil,
	}
}

// Write captures every file content hash in the snapshot as a sorted index, in
// memory and on disk, tagged with the revision it was built for. The on-disk layout
// is the 32-byte head revision id followed by the sorted, de-duplicated hashes, so a
// later session (or the headless reminder) can tell which revision the index covers.
func (r *RepositoryFileHashes) Write(snapshot *lib.Temp[*lib.RevisionEntry], head lib.RevisionId) error {
	reader := snapshot.Reader(nil)
	buf := lib.NewBlockBuf()
	hashes := make([]lib.Sha256, 0)
	for {
		entry, err := reader.Read(buf)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return lib.WrapErrorf(err, "failed to read revision")
		}
		// Directories and other non-file entries carry a zero hash.
		if entry.Kind == lib.RevisionEntryKindDelete || entry.Metadata.FileHash == (lib.Sha256{}) {
			continue
		}
		hashes = append(hashes, entry.Metadata.FileHash)
	}
	sort.Slice(hashes, func(i, j int) bool { return bytes.Compare(hashes[i][:], hashes[j][:]) < 0 })
	r.head = head
	r.hashes = hashes

	// Write the file.
	tmp := r.path + ".tmp"
	file, err := os.Create(tmp)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create %s", tmp)
	}
	writer := bufio.NewWriter(file)
	if _, err := writer.Write(head[:]); err != nil {
		_ = file.Close()
		return lib.WrapErrorf(err, "failed to write %s", tmp)
	}
	for i := range r.hashes {
		if i > 0 && r.hashes[i] == r.hashes[i-1] {
			continue
		}
		if _, err := writer.Write(r.hashes[i][:]); err != nil {
			_ = file.Close()
			return lib.WrapErrorf(err, "failed to write %s", tmp)
		}
	}
	if err := writer.Flush(); err != nil {
		_ = file.Close()
		return lib.WrapErrorf(err, "failed to flush %s", tmp)
	}
	if err := file.Close(); err != nil {
		return lib.WrapErrorf(err, "failed to close %s", tmp)
	}
	if err := os.Rename(tmp, r.path); err != nil {
		return lib.WrapErrorf(err, "failed to replace %s", r.path)
	}
	return nil
}

// Contains reports whether the hash is in the index, loading it from disk on first
// use. An absent or unreadable index reads as empty.
func (r *RepositoryFileHashes) Contains(hash lib.Sha256) bool {
	hashes := r.get()
	i := sort.Search(len(hashes), func(i int) bool { return bytes.Compare(hashes[i][:], hash[:]) >= 0 })
	return i < len(hashes) && hashes[i] == hash
}

// Head returns the revision the persisted index was built for, loading it from disk
// on first use. A missing or unreadable index reads as the root (zero) revision.
func (r *RepositoryFileHashes) Head() lib.RevisionId {
	r.get()
	return r.head
}

// Clear drops the index in memory and on disk. Called before a commit, which moves
// HEAD and so invalidates it; rebuildSnapshot rewrites it afterwards.
func (r *RepositoryFileHashes) Clear() {
	r.head = lib.RevisionId{}
	r.hashes = nil
	_ = os.Remove(r.path)
}

func (r *RepositoryFileHashes) get() []lib.Sha256 {
	if r.hashes != nil {
		return r.hashes
	}
	file, err := os.Open(r.path)
	if err != nil {
		return nil
	}
	defer file.Close() //nolint:errcheck
	info, err := file.Stat()
	if err != nil || int(info.Size()) < len(r.head) {
		return nil
	}
	reader := bufio.NewReader(file)
	var head lib.RevisionId
	if _, err := io.ReadFull(reader, head[:]); err != nil {
		return nil
	}
	hashes := make([]lib.Sha256, (int(info.Size())-len(head))/sha256.Size)
	for i := range hashes {
		if _, err := io.ReadFull(reader, hashes[i][:]); err != nil {
			r.head, r.hashes = head, hashes[:i]
			return r.hashes
		}
	}
	r.head, r.hashes = head, hashes
	return r.hashes
}

// CheckFiles reports, for each given SHA-256, whether its content is present in the
// persisted hash index. It answers from the index alone, WITHOUT verifying the index
// is current, so it does not require the repository open: the headless merge reminder
// relies on this against the index the last foreground session left. Interactive
// callers (scan/share) call EnsureFileHashesAtHead first to refresh a stale index.
func CheckFiles(sha256s []lib.Sha256) ([]bool, error) {
	if repositoryFileHashes == nil {
		panic("Init() must be called first")
	}
	res := make([]bool, len(sha256s))
	for i := range sha256s {
		res[i] = repositoryFileHashes.Contains(sha256s[i])
	}
	return res, nil
}

// UploadFile uploads a file to the repository.
// `localFilePath` is the absolute path on disk.
// `repoFilePath` is the full path in the repository (including any prefix).
// Return `true` if the file was uploaded, `false` if it was skipped.
func UploadFile(localFilePath string, repoFilePath string) (*lib.RevisionEntry, bool, error) {
	if repository == nil {
		return nil, false, lib.Errorf("repository not opened - call 'OpenRepository' first")
	}
	fileInfo, err := os.Stat(localFilePath)
	if err != nil {
		return nil, false, lib.WrapErrorf(err, "failed to stat file %s", localFilePath)
	}
	if fileInfo.IsDir() {
		return nil, false, lib.Errorf("cannot add directory %s to repository", localFilePath)
	}
	dir := filepath.Dir(localFilePath)
	localFileName, err := lib.NewPath(filepath.Base(localFilePath))
	if err != nil {
		return nil, false, lib.WrapErrorf(err, "invalid filename %s", localFilePath)
	}
	fs := lib.NewRealFS(dir)
	repoPath, err := lib.NewPath(strings.Trim(repoFilePath, "/"))
	if err != nil {
		return nil, false, lib.WrapErrorf(err, "invalid repo path %s", repoFilePath)
	}

	// Check if file already exists in the current head of the repository.
	existingEntry, found, err := snapshotCache.Get(lib.PathCompareString(repoPath, false))
	if err != nil {
		return nil, false, lib.WrapErrorf(err, "failed to get path %s from remote revision", repoPath)
	}
	if found {
		// File exists, calculate its hash to compare.
		file, err := os.Open(localFilePath)
		if err != nil {
			return nil, false, lib.WrapErrorf(err, "failed to open file %s", localFilePath)
		}
		defer file.Close() //nolint:errcheck

		hasher := sha256.New()
		if _, err := io.Copy(hasher, file); err != nil {
			return nil, false, lib.WrapErrorf(err, "failed to calculate hash for file %s", localFilePath)
		}
		fileHash := lib.Sha256(hasher.Sum(nil))

		// If hashes match, file is unchanged - return nil to skip.
		if fileHash == existingEntry.Metadata.FileHash {
			return nil, false, nil
		}
	}
	// File does not exist or has changed, proceed with upload.
	md, err := workspace.AddFileToRepository(
		context.Background(),
		fs,
		localFileName,
		fileInfo,
		repository,
		nil,
		workspace.NewDefaultCommitMonitor(workspace.DefaultMonitorModeSilent, nil, nil),
	)
	if err != nil {
		return nil, false, lib.WrapErrorf(err, "failed to add file %s to repository", localFilePath)
	}
	// We want to have predictable file permissions and modes.
	md.FileMode = 0o600
	entry := &lib.RevisionEntry{
		Path:     repoPath,
		Kind:     lib.RevisionEntryKindAdd,
		Metadata: md,
	}
	return entry, true, nil
}

func CommitEntries(entries []*lib.RevisionEntry, author, message string) (string, error) {
	if repository == nil {
		return "", lib.Errorf("repository not opened - call 'OpenRepository' first")
	}
	// The commit moves HEAD, invalidating the hash index; drop it up front so a
	// failure here can't leave a stale index. rebuildSnapshot rewrites it below.
	repositoryFileHashes.Clear()
	ctx := context.Background()
	tempFS := lib.NewMemoryFS(500_000_000)
	commit, err := lib.NewCommit(ctx, repository, tempFS)
	if err != nil {
		return "", lib.WrapErrorf(err, "failed to create commit")
	}
	for _, entry := range entries {
		// Ensure parent directories exist for entries with subdirectories.
		parent := entry.Path.Dir()
		if !parent.IsEmpty() {
			if err := commit.EnsureDirExists(parent, snapshotCache, head); err != nil {
				return "", lib.WrapErrorf(err, "failed to ensure directory %s exists", parent)
			}
		}
		if err := commit.Add(entry); err != nil {
			return "", lib.WrapErrorf(err, "failed to add entry to commit")
		}
	}
	commitInfo := &lib.CommitInfo{
		Author:  author,
		Message: message,
	}
	revisionId, err := commit.Commit(ctx, commitInfo)
	if err != nil {
		return "", lib.WrapErrorf(err, "failed to commit")
	}
	if err := rebuildSnapshot(revisionId); err != nil {
		return "", lib.WrapErrorf(err, "failed to refresh snapshot after commit")
	}
	return hex.EncodeToString(revisionId[:]), nil
}
