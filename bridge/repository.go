package bridge

import (
	"context"
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
	repository     *lib.Repository        //nolint:gochecknoglobals
	head           lib.RevisionId         //nolint:gochecknoglobals
	snapshot       *lib.RevisionTemp      //nolint:gochecknoglobals
	snapshotCache  *lib.RevisionTempCache //nolint:gochecknoglobals
	repoPathPrefix lib.Path               //nolint:gochecknoglobals
)

// Open the repository if needed and updates the current revision snapshot if the HEAD changed.
func EnsureRepositoryOpen(hostURL, password, repoPathPrefix_ string) error {
	// If repository is already open, verify the HEAD revision did not change.
	// If it did, refresh the snapshot.
	var err error
	repoPathPrefix, err = lib.NewPath(strings.Trim(repoPathPrefix_, "/"))
	if err != nil {
		return lib.WrapErrorf(err, "failed to create repo path prefix %s", repoPathPrefix_)
	}
	if repository != nil {
		currentHead, err := repository.Head()
		if err != nil {
			return lib.WrapErrorf(err, "failed to get HEAD revision")
		}
		if currentHead == head {
			return nil
		}
	}
	if repository == nil {
		// todo: what are the right timeouts?
		httpClient := &http.Client{ //nolint:exhaustruct
			Timeout: 30 * time.Second,
		}
		client := clinghttp.NewDefaultHTTPClient(httpClient, context.Background())
		storage := clinghttp.NewHTTPStorageClient(hostURL, client)
		var err error
		repository, err = lib.OpenRepository(storage, []byte(password))
		if err != nil {
			return lib.WrapErrorf(err, "failed to open repository")
		}
	}
	currenHead, err := repository.Head()
	if err != nil {
		return lib.WrapErrorf(err, "failed to get HEAD revision")
	}
	if currenHead == head && snapshot != nil {
		return nil
	}
	head = currenHead
	tmpFs := lib.NewMemoryFS(500_000_000)
	snapshot, err = lib.NewRevisionSnapshot(repository, head, tmpFs)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create revision snapshot")
	}
	snapshotCache, err = lib.NewRevisionTempCache(snapshot, 20)
	if err != nil {
		return lib.WrapErrorf(err, "failed to create revision cache")
	}
	return nil
}

// Check if the given files (based on their SHA256 hashes) are *somewhere* in the HEAD
// revision of the repository.
// If a file is found, the path inside the repository is returned, otherwise an empty string.
func CheckFiles(sha256s []lib.Sha256) ([]string, error) {
	if repository == nil {
		return nil, lib.Errorf("repository not opened - call 'EnsureRepositoryOpen' command first")
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

func UploadFile(filePath string) (*lib.RevisionEntry, error) {
	if repository == nil {
		return nil, lib.Errorf("repository not opened - call 'EnsureRepositoryOpen' command first")
	}
	fileInfo, err := os.Stat(filePath) //nolint:forbidigo
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to stat file %s", filePath)
	}
	if fileInfo.IsDir() {
		return nil, lib.Errorf("cannot add directory %s to repository", filePath)
	}
	filename := filepath.Base(filePath)
	dir := filepath.Dir(filePath)
	fs := lib.NewRealFS(dir)
	// Ensure the final repoPath is not absolute.
	filenamePath, err := lib.NewPath(strings.Trim(filename, "/"))
	if err != nil {
		return nil, lib.WrapErrorf(err, "invalid path %s", filename)
	}
	repoPath := repoPathPrefix.Join(filenamePath)
	md, err := workspace.AddFileToRepository(
		fs,
		filenamePath,
		fileInfo,
		repository,
		nil,
		func(entry *lib.RevisionEntry, header *lib.BlockHeader, existed bool, dataSize int64) {},
	)
	if err != nil {
		return nil, lib.WrapErrorf(err, "failed to add file %s to repository", filePath)
	}
	// We want to have predictable file permissions and modes.
	md.ModeAndPerm = 0o600
	entry := &lib.RevisionEntry{
		Path:     repoPath,
		Type:     lib.RevisionEntryAdd,
		Metadata: &md,
	}
	return entry, nil
}

func CommitEntries(entries []*lib.RevisionEntry, author, message string) (string, error) {
	if repository == nil {
		return "", lib.Errorf("repository not opened - call 'EnsureRepositoryOpen' command first")
	}
	tempFS := lib.NewMemoryFS(500_000_000)
	commit, err := lib.NewCommit(repository, tempFS)
	if err != nil {
		return "", lib.WrapErrorf(err, "failed to create commit")
	}
	if err := commit.EnsureDirExists(repoPathPrefix, snapshotCache); err != nil {
		return "", lib.WrapErrorf(err, "failed to ensure path prefix exists as a directory in the repository")
	}
	for _, entry := range entries {
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
	return hex.EncodeToString(revisionId[:]), nil
}
