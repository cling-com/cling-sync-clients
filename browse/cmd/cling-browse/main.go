// Serve the browse UI for a cling-sync repository or workspace over HTTP so
// it can be used from a normal browser.
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	clingsynchttp "github.com/cling-com/cling-sync/http"
	"github.com/cling-com/cling-sync/lib"
	"github.com/cling-com/cling-sync/workspace"
	"github.com/flunderpero/cling-sync-clients/browse/internal/auth"
	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
	"github.com/flunderpero/cling-sync-clients/browse/internal/web"
	"golang.org/x/term"
)

type args struct {
	workspace           string
	repository          string
	pathPrefix          lib.Path
	listen              string
	passphraseFromStdin bool
	insecure            bool
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(1)
	}
}

func run() error {
	parsed, err := parseArgs(os.Args[1:])
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	tmpDir, err := os.MkdirTemp("", "cling-browse-")
	if err != nil {
		return fmt.Errorf("failed to create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir) //nolint:errcheck
	sess, err := openSession(ctx, parsed, lib.NewRealFS(tmpDir))
	if err != nil {
		return err
	}
	defer sess.Close(session.DefaultCloseGrace) //nolint:errcheck
	return serve(ctx, parsed, sess)
}

func parseArgs(argv []string) (args, error) {
	var parsed args
	flags := flag.NewFlagSet("cling-browse", flag.ExitOnError)
	flags.StringVar(&parsed.workspace, "workspace", "", "Serve the repository of this local workspace directory")
	flags.StringVar(&parsed.repository, "repository", "",
		"Serve this repository (local path or s3+ URI; missing S3 credentials are read "+
			"from CLING_S3_*/AWS_* env vars or prompted)")
	var pathPrefix string
	flags.StringVar(&pathPrefix, "path-prefix", "",
		"Only serve this subtree (only with --repository, a workspace brings its own prefix)")
	flags.StringVar(&parsed.listen, "listen", "127.0.0.1:0", "Listen address")
	flags.BoolVar(&parsed.passphraseFromStdin, "passphrase-from-stdin", false,
		"Read the repository passphrase from stdin")
	flags.BoolVar(&parsed.insecure, "insecure", false,
		"Allow listening on a non-loopback address even though there is no TLS")
	if err := flags.Parse(argv); err != nil {
		return args{}, fmt.Errorf("failed to parse arguments: %w", err)
	}
	if (parsed.workspace == "") == (parsed.repository == "") {
		return args{}, errors.New("exactly one of --workspace or --repository must be given")
	}
	if pathPrefix != "" && parsed.workspace != "" {
		return args{}, errors.New("--path-prefix cannot be combined with --workspace")
	}
	var err error
	if parsed.pathPrefix, err = workspace.ValidatePathPrefix(pathPrefix); err != nil {
		return args{}, err //nolint:wrapcheck
	}
	if !isLoopback(parsed.listen) && !parsed.insecure {
		return args{}, errors.New(
			"refusing to listen on a non-loopback address, traffic would be unencrypted " +
				"(use an SSH tunnel or a TLS reverse proxy, or force with --insecure)")
	}
	return parsed, nil
}

func openSession(ctx context.Context, parsed args, tmpFS lib.FS) (*session.Session, error) {
	if parsed.repository != "" {
		passphrase, err := readPassphrase(parsed.passphraseFromStdin)
		if err != nil {
			return nil, err
		}
		uri, err := resolveRepositoryURI(parsed.repository, passphrase, parsed.passphraseFromStdin)
		if err != nil {
			return nil, err
		}
		return session.NewSession(ctx, uri, passphrase, parsed.pathPrefix, tmpFS)
	}
	wsTmpFS, err := tmpFS.MkSub("workspace")
	if err != nil {
		return nil, fmt.Errorf("failed to create workspace temp dir: %w", err)
	}
	ws, err := workspace.OpenWorkspace(ctx, lib.NewRealFS(parsed.workspace), wsTmpFS)
	if err != nil {
		return nil, fmt.Errorf("failed to open workspace %q: %w", parsed.workspace, err)
	}
	defer ws.Close() //nolint:errcheck
	passphrase, err := auth.ReadSavedPassphrase(ctx, ws)
	if errors.Is(err, auth.ErrPassphraseRequired) {
		passphrase, err = readPassphrase(parsed.passphraseFromStdin)
	}
	if err != nil {
		return nil, err
	}
	uri, err := resolveRepositoryURI(string(ws.RemoteRepository), passphrase, parsed.passphraseFromStdin)
	if err != nil {
		return nil, err
	}
	return session.NewSession(ctx, uri, passphrase, ws.PathPrefix, tmpFS)
}

const s3KeyMinLen = 16

// Mirror the cling-sync CLI: a cleartext s3+ URI gets the S3 credentials
// (env vars or interactive prompt) encrypted into it under the repository
// passphrase; local paths and embedded-credential URIs pass through.
func resolveRepositoryURI(uri string, passphrase []byte, passphraseFromStdin bool) (string, error) {
	if err := clingsynchttp.RejectBareHTTPURI(uri); err != nil {
		return "", fmt.Errorf("invalid repository URI: %w", err)
	}
	if !clingsynchttp.IsS3StorageURI(uri) {
		abs, err := filepath.Abs(uri)
		if err != nil {
			return "", fmt.Errorf("failed to get absolute path for %s: %w", uri, err)
		}
		return abs, nil
	}
	if clingsynchttp.S3URIHasEmbeddedCredentials(uri) {
		return uri, nil
	}
	creds, err := readS3Credentials(passphraseFromStdin)
	if err != nil {
		return "", err
	}
	encoded, err := clingsynchttp.EncodeS3URI(uri, creds, passphrase)
	if err != nil {
		return "", fmt.Errorf("failed to encode S3 URI: %w", err)
	}
	return encoded, nil
}

func readS3Credentials(passphraseFromStdin bool) (clingsynchttp.S3Credentials, error) {
	if creds, ok, err := readEnvS3Credentials(); err != nil || ok {
		return creds, err
	}
	if passphraseFromStdin {
		return clingsynchttp.S3Credentials{}, errors.New(
			"with --passphrase-from-stdin set CLING_S3_KEY_ID and CLING_S3_ACCESS_KEY " +
				"(or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)")
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) { //nolint:gosec
		return clingsynchttp.S3Credentials{}, errors.New(
			"set CLING_S3_KEY_ID and CLING_S3_ACCESS_KEY " +
				"(or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY), or run interactively")
	}
	fmt.Fprint(os.Stderr, "S3 access key id: ")
	var keyID string
	if _, err := fmt.Fscanln(os.Stdin, &keyID); err != nil {
		return clingsynchttp.S3Credentials{}, fmt.Errorf("failed to read access key id: %w", err)
	}
	fmt.Fprint(os.Stderr, "S3 secret access key: ")
	secret, err := term.ReadPassword(int(os.Stdin.Fd())) //nolint:gosec
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return clingsynchttp.S3Credentials{}, fmt.Errorf("failed to read secret access key: %w", err)
	}
	return clingsynchttp.S3Credentials{AccessKeyID: strings.TrimSpace(keyID), SecretAccessKey: secret}, nil
}

// Read the S3 credentials from the environment.
//
// `ok` is true iff one of the two env pairs is fully set. Mixing across
// pairs or setting only one var of a pair is rejected.
func readEnvS3Credentials() (clingsynchttp.S3Credentials, bool, error) {
	clingID, clingSecret := os.Getenv("CLING_S3_KEY_ID"), os.Getenv("CLING_S3_ACCESS_KEY")
	awsID, awsSecret := os.Getenv("AWS_ACCESS_KEY_ID"), os.Getenv("AWS_SECRET_ACCESS_KEY")
	if (clingID != "") != (clingSecret != "") {
		return clingsynchttp.S3Credentials{}, false, errors.New(
			"CLING_S3_KEY_ID and CLING_S3_ACCESS_KEY must both be set")
	}
	if clingID != "" {
		if len(clingID) < s3KeyMinLen || len(clingSecret) < s3KeyMinLen {
			return clingsynchttp.S3Credentials{}, false, fmt.Errorf(
				"CLING_S3_KEY_ID and CLING_S3_ACCESS_KEY must each be at least %d bytes", s3KeyMinLen)
		}
		return clingsynchttp.S3Credentials{AccessKeyID: clingID, SecretAccessKey: []byte(clingSecret)}, true, nil
	}
	if (awsID != "") != (awsSecret != "") {
		return clingsynchttp.S3Credentials{}, false, errors.New(
			"AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must both be set")
	}
	if awsID != "" {
		return clingsynchttp.S3Credentials{AccessKeyID: awsID, SecretAccessKey: []byte(awsSecret)}, true, nil
	}
	return clingsynchttp.S3Credentials{}, false, nil
}

// Mirror the cling-sync CLI: `--passphrase-from-stdin` reads all of stdin
// verbatim, interactive input is read without echo.
func readPassphrase(passphraseFromStdin bool) ([]byte, error) {
	if passphraseFromStdin {
		passphrase, err := io.ReadAll(os.Stdin)
		if err != nil {
			return nil, fmt.Errorf("failed to read passphrase from stdin: %w", err)
		}
		return passphrase, nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) { //nolint:gosec
		return nil, errors.New(
			"the passphrase can only be entered in an interactive terminal session, " +
				"use --passphrase-from-stdin otherwise")
	}
	fmt.Fprint(os.Stderr, "Enter passphrase: ")
	passphrase, err := term.ReadPassword(int(os.Stdin.Fd())) //nolint:gosec
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return nil, fmt.Errorf("failed to read passphrase: %w", err)
	}
	return passphrase, nil
}

func serve(ctx context.Context, parsed args, sess *session.Session) error {
	token, err := newToken()
	if err != nil {
		return err
	}
	handler := clingsynchttp.RequestLogMiddleware(tokenGate(token, web.NewHandler(sess)))
	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", parsed.listen)
	if err != nil {
		return fmt.Errorf("failed to listen on %q: %w", parsed.listen, err)
	}
	_, _ = fmt.Fprintf(os.Stdout, "Serving at http://%s/?t=%s\n", listener.Addr(), token)
	// No WriteTimeout: it would cut off long downloads. Hung requests die
	// with their connection or at shutdown.
	server := &http.Server{ //nolint:exhaustruct
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	go func() {
		<-ctx.Done()
		// The parent context is already done here, WithoutCancel detaches
		// the shutdown grace period from it.
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			_ = server.Close()
		}
	}()
	if err := server.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("server failed: %w", err)
	}
	return nil
}

const tokenCookie = "cling_browse"

// Any local process of any user can connect to a loopback port, so every
// request must present the per-run token. It is delivered once via the
// printed URL and then carried in a cookie.
func tokenGate(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if t := r.URL.Query().Get("t"); t != "" {
			if subtle.ConstantTimeCompare([]byte(t), []byte(token)) == 1 {
				http.SetCookie(w, &http.Cookie{ //nolint:exhaustruct
					Name:     tokenCookie,
					Value:    t,
					Path:     "/",
					HttpOnly: true,
					SameSite: http.SameSiteStrictMode,
				})
				http.Redirect(w, r, r.URL.Path, http.StatusSeeOther)
				return
			}
		} else if cookie, err := r.Cookie(tokenCookie); err == nil &&
			subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(token)) == 1 {
			next.ServeHTTP(w, r)
			return
		}
		http.Error(w, "Forbidden", http.StatusForbidden)
	})
}

func newToken() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("failed to generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
