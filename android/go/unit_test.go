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

	bridge "github.com/flunderpero/cling-sync-clients/bridge"
	clingsynchttp "github.com/flunderpero/cling-sync/http"
	"github.com/flunderpero/cling-sync/lib"
)

// TestAndroidUnit drives the JVM unit tests against the REAL Go bridge. It starts
// a host-side execute server (wrapping bridge.Execute over HTTP, with a per-test
// repository factory), then runs the Robolectric unit tests pointed at it. No
// emulator, no fake bridge.
func TestAndroidUnit(t *testing.T) { //nolint:paralleltest
	es := newExecuteServer(t)

	cmd := exec.CommandContext(t.Context(), "./gradlew", "testDebugUnitTest", "--rerun-tasks", //nolint:gosec
		"-Pclingsync.executeServerUrl="+es.url)
	cmd.Dir = ".."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatal(string(out))
	}
}

type executeServer struct {
	url      string
	mu       sync.Mutex
	tempDirs []string
}

func newExecuteServer(t *testing.T) *executeServer {
	t.Helper()
	// The app calls the bridge's "init" once at startup to set a writable cache
	// dir; mirror that here so the process-global bridge is ready for every test.
	// The Kotlin side re-runs "init" with its own dir and index key over /execute.
	bridge.Init(t.TempDir(), make([]byte, 32))
	es := &executeServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/execute", es.handleExecute)
	mux.HandleFunc("/new-repo", es.handleNewRepo)
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: mux} //nolint:gosec,exhaustruct
	go server.Serve(ln)                  //nolint:errcheck
	es.url = "http://" + ln.Addr().String()
	t.Cleanup(func() {
		_ = server.Close()
		es.mu.Lock()
		defer es.mu.Unlock()
		for _, d := range es.tempDirs {
			_ = os.RemoveAll(d)
		}
	})
	return es
}

// handleExecute calls the real bridge.Execute. Bridge state (the open repository)
// is process-global, which matches the real app's single session; the JVM tests
// run sequentially and each opens its own repository.
func (es *executeServer) handleExecute(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Command string `json:"command"`
		Params  string `json:"params"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	_, _ = w.Write([]byte(bridge.Execute(req.Command, req.Params)))
}

func (es *executeServer) handleNewRepo(w http.ResponseWriter, r *http.Request) {
	cfg, err := es.createRepo(r.Context(), r.URL.Query().Get("fault") == "true")
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
	ControlURL string `json:"controlUrl"`
}

// createRepo initialises a fresh repository in a temp dir and serves it over a
// new in-process S3 server on an ephemeral port, optionally with fault injection.
func (es *executeServer) createRepo(ctx context.Context, fault bool) (repoConfig, error) {
	dir, err := os.MkdirTemp("", "clingrepo")
	if err != nil {
		return repoConfig{}, err
	}
	es.mu.Lock()
	es.tempDirs = append(es.tempDirs, dir)
	es.mu.Unlock()

	const passphrase = "testpassphrase"
	storage, err := lib.NewFileStorage(lib.NewRealFS(dir), lib.StoragePurposeRepository)
	if err != nil {
		return repoConfig{}, err
	}
	if _, err := lib.InitNewRepository(ctx, storage, []byte(passphrase)); err != nil {
		return repoConfig{}, err
	}

	s3 := clingsynchttp.NewS3StorageServer(storage, testS3Region, testS3AccessKeyID, testS3SecretAccessKey)
	mux := http.NewServeMux()
	s3.RegisterRoutes(mux)
	var handler http.Handler = mux
	if fault {
		handler = (&faultControl{}).wrap(mux)
	}
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return repoConfig{}, err
	}
	server := &http.Server{Handler: handler} //nolint:gosec,exhaustruct
	go server.Serve(ln)                      //nolint:errcheck

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
		ControlURL: "http://" + base,
	}, nil
}
