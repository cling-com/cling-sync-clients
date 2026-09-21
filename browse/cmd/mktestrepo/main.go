// Create a small local repository with fixed content.
//
// This exists for the e2e tests, which need a real repository to point
// cling-browse at. The passphrase is "test".
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "Usage: mktestrepo <dir>")
		os.Exit(1)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(1)
	}
}

func run(dir string) error {
	ctx := context.Background()
	repoDir := filepath.Join(dir, "repository")
	wsDir := filepath.Join(dir, "workspace")
	tmpDir := filepath.Join(dir, "tmp")
	for _, d := range []string{repoDir, wsDir, tmpDir} {
		if err := os.MkdirAll(d, 0o700); err != nil { //nolint:gosec // dir argument is trusted test-fixture input.
			return fmt.Errorf("failed to create %q: %w", d, err)
		}
	}
	storage, err := lib.NewFileStorage(lib.NewRealFS(repoDir), lib.StoragePurposeRepository)
	if err != nil {
		return fmt.Errorf("failed to create storage: %w", err)
	}
	repository, err := lib.InitNewRepository(ctx, storage, []byte("test"), lib.TestData{}.Argon2idParams())
	if err != nil {
		return fmt.Errorf("failed to init repository: %w", err)
	}
	defer repository.Close() //nolint:errcheck
	files := map[string]string{
		"hello.txt":       "hello from cling-sync",
		"docs/readme.md":  "# readme",
		"docs/deep/x.txt": "deep content",
	}
	for name, content := range files {
		path := filepath.Join(wsDir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil { //nolint:gosec // see above
			return fmt.Errorf("failed to create parent of %q: %w", path, err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil { //nolint:gosec // see above
			return fmt.Errorf("failed to write %q: %w", path, err)
		}
	}
	ws, err := workspace.NewWorkspace(
		ctx, lib.NewRealFS(wsDir), lib.NewRealFS(tmpDir), workspace.RemoteRepository(repoDir), lib.Path{})
	if err != nil {
		return fmt.Errorf("failed to create workspace: %w", err)
	}
	defer ws.Close() //nolint:errcheck
	if _, err := workspace.Merge(ctx, ws, repository, workspace.WorkspaceTestData{}.MergeOptions()); err != nil {
		return fmt.Errorf("failed to commit files: %w", err)
	}
	_, _ = fmt.Fprintln(os.Stdout, repoDir)
	return nil
}
