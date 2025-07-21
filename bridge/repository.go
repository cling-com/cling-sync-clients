package bridge

import (
	"context"
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	clinghttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
	"github.com/flunderpero/cling-sync/workspace"
)

var repository *lib.Repository //nolint:gochecknoglobals

func EnsureRepositoryOpen(hostURL, password string) error {
	// If repository is already open, just return
	if repository != nil {
		return nil
	}

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
	return nil
}

func UploadFile(filePath, repoPathPrefix string) (*lib.RevisionEntry, error) {
	if repository == nil {
		return nil, lib.Errorf("repository not opened - call 'ensureOpen' command first")
	}
	repoPathPrefix = strings.Trim(repoPathPrefix, "/")
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
	repoPathStr := repoPathPrefix + "/" + strings.Trim(filename, "/")
	repoPath := lib.NewPath(strings.Split(repoPathStr, "/")...)
	md, err := workspace.AddFileToRepository(
		fs,
		filename,
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
		return "", lib.Errorf("repository not opened - call 'ensureOpen' command first")
	}

	// Create a new commit
	tempFS := lib.NewMemoryFS(10_000_000)
	commit, err := lib.NewCommit(repository, tempFS)
	if err != nil {
		return "", lib.WrapErrorf(err, "failed to create commit")
	}

	// Add each entry
	for _, entry := range entries {
		if err := commit.Add(entry); err != nil {
			return "", lib.WrapErrorf(err, "failed to add entry to commit")
		}
	}

	// Commit with the provided info
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
