package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"testing"

	clingsynchttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
)

// provisionPort is the fixed loopback port the Swift unit tests reach the
// provisioning server on. It is fixed (not ephemeral) because a host-app-loaded
// XCTest inherits the simulator's launchd environment, which is captured once at
// boot and cannot be refreshed per run, so the port cannot be passed in. The
// Swift side gates bridge tests on reachability of this port (see TestRepo).
const provisionPort = 47645

// TestIOSUnit drives the XCTest unit suite against the REAL Go bridge. Unlike
// Android (whose JVM cannot host the Go runtime), the iOS bridge is linked into
// the host app and runs in-process, so this driver only provisions fresh
// repositories + S3 servers on demand. The Swift tests call bridge.Execute
// directly. No emulator, no fake bridge.
func TestIOSUnit(t *testing.T) { //nolint:paralleltest
	ps := newProvisionServer(t)
	t.Logf("Provisioning server listening at %s", ps.url)

	cmd := exec.CommandContext(t.Context(), "./build.sh", "test", "--unit-xcode")
	cmd.Dir = ".."
	cmd.Env = os.Environ()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatal(string(out))
	}
}

type provisionServer struct {
	url      string
	mu       sync.Mutex
	tempDirs []string
}

func newProvisionServer(t *testing.T) *provisionServer {
	t.Helper()
	ps := &provisionServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/new-repo", ps.handleNewRepo)
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:"+strconv.Itoa(provisionPort))
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: mux} //nolint:gosec,exhaustruct
	go server.Serve(ln)                  //nolint:errcheck
	ps.url = "http://" + ln.Addr().String()
	t.Cleanup(func() {
		_ = server.Close()
		ps.mu.Lock()
		defer ps.mu.Unlock()
		for _, d := range ps.tempDirs {
			_ = os.RemoveAll(d)
		}
	})
	return ps
}

func (ps *provisionServer) handleNewRepo(w http.ResponseWriter, r *http.Request) {
	cfg, err := ps.createRepo(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(cfg); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

type repoConfig struct {
	URL        string `json:"url"`
	Passphrase string `json:"passphrase"`
	S3KeyID    string `json:"s3KeyId"`
	S3Key      string `json:"s3Key"`
}

// createRepo initialises a fresh repository in a temp dir and serves it over a
// new in-process S3 server on an ephemeral 127.0.0.1 port (the simulator shares
// the host loopback).
func (ps *provisionServer) createRepo(ctx context.Context) (repoConfig, error) {
	dir, err := os.MkdirTemp("", "clingrepo")
	if err != nil {
		return repoConfig{}, err
	}
	ps.mu.Lock()
	ps.tempDirs = append(ps.tempDirs, dir)
	ps.mu.Unlock()

	const passphrase = "testpassphrase"
	storage, err := lib.NewFileStorage(lib.NewRealFS(dir), lib.StoragePurposeRepository)
	if err != nil {
		return repoConfig{}, err
	}
	if _, err := lib.InitNewRepository(ctx, storage, []byte(passphrase), td.Argon2idParams()); err != nil {
		return repoConfig{}, err
	}

	s3 := clingsynchttp.NewS3StorageServer(storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3.RegisterRoutes(mux)
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return repoConfig{}, err
	}
	server := &http.Server{Handler: mux} //nolint:gosec,exhaustruct
	go server.Serve(ln)                  //nolint:errcheck

	tcpAddr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		return repoConfig{}, fmt.Errorf("listener address is not TCP")
	}
	base := "127.0.0.1:" + strconv.Itoa(tcpAddr.Port)
	return repoConfig{
		URL:        "s3+http://" + base,
		Passphrase: passphrase,
		S3KeyID:    testS3AccessKeyID,
		S3Key:      testS3SecretAccessKey,
	}, nil
}
