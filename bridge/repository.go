package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
	"github.com/flunderpero/cling-sync/workspace"
)

var (
	repository        *lib.Repository                   //nolint:gochecknoglobals
	repositoryHostURL string                            //nolint:gochecknoglobals
	head              lib.RevisionId                    //nolint:gochecknoglobals
	snapshot          *lib.Temp[lib.RevisionEntry]      //nolint:gochecknoglobals
	snapshotCache     *lib.TempCache[lib.RevisionEntry] //nolint:gochecknoglobals
)

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

// GetRepositoryHeadRevisionID returns the current HEAD revision ID or an empty string.
func GetRepositoryHeadRevisionID() string {
	if repository == nil || head == (lib.RevisionId{}) {
		return ""
	}
	return head.String()
}

// OpenRepository closes any existing repository and opens a new one.
func OpenRepository(hostURL, password string) error {
	closeRepository()
	httpClient := &http.Client{ //nolint:exhaustruct
		Timeout: 30 * time.Second,
	}
	client := clinghttp.NewDefaultHTTPClient(httpClient)
	storage := clinghttp.NewHTTPStorageClient(hostURL, client)
	var err error
	repository, err = lib.OpenRepository(storage, []byte(password))
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
	currentHead, err := repository.Head()
	if err != nil {
		return lib.WrapErrorf(err, "failed to get HEAD revision")
	}
	if currentHead == head && snapshot != nil {
		return nil
	}
	head = currentHead
	tmpFs := lib.NewMemoryFS(500_000_000)
	snapshot, err = lib.NewRevisionSnapshot(repository, head, tmpFs)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create revision snapshot")
	}
	snapshotCache, err = lib.NewRevisionEntryTempCache(snapshot, 10)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create revision cache")
	}
	return nil
}

func closeRepository() {
	repository = nil
	repositoryHostURL = ""
	head = lib.RevisionId{}
	snapshot = nil
	snapshotCache = nil
}

// Check if the given files (based on their SHA256 hashes) are *somewhere* in the HEAD
// revision of the repository.
// If a file is found, the path inside the repository is returned, otherwise an empty string.
func CheckFiles(sha256s []lib.Sha256) ([]string, error) {
	if repository == nil {
		return nil, lib.Errorf("repository not opened - call 'OpenRepository' first")
	}
	r := snapshot.Reader(nil)
	res := make([]string, len(sha256s))
	for {
		re, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, lib.WrapErrorf(err, "failed to read revision")
		}
		if re.Type == lib.RevisionEntryDelete {
			// This should never happen because we are reading from a snapshot.
			continue
		}
		for i, sha256 := range sha256s {
			if sha256 == re.Metadata.FileHash {
				res[i] = re.Path.String()
			}
		}
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
	md.ModeAndPerm = 0o600
	entry := &lib.RevisionEntry{
		Path:     repoPath,
		Type:     lib.RevisionEntryAdd,
		Metadata: &md,
	}
	return entry, true, nil
}

func CommitEntries(entries []*lib.RevisionEntry, author, message string) (string, error) {
	if repository == nil {
		return "", lib.Errorf("repository not opened - call 'OpenRepository' first")
	}
	tempFS := lib.NewMemoryFS(500_000_000)
	commit, err := lib.NewCommit(repository, tempFS)
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
	revisionId, err := commit.Commit(commitInfo)
	if err != nil {
		return "", lib.WrapErrorf(err, "failed to commit")
	}
	if err := refreshSnapshot(); err != nil {
		return "", lib.WrapErrorf(err, "failed to refresh snapshot after commit")
	}
	return hex.EncodeToString(revisionId[:]), nil
}
