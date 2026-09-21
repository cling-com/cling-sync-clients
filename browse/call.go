package browse

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"strings"
)

type callResult struct {
	status int
	body   []byte
}

// Run one GET against the handler without any network transport.
//
// This is the embedded counterpart of a real HTTP request: the WebView's
// injected callback lands here.
func call(ctx context.Context, handler http.Handler, target string) (callResult, error) {
	if !strings.HasPrefix(target, "/") {
		target = "/" + target
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return callResult{}, fmt.Errorf("invalid request %q: %w", target, err)
	}
	recorder := &memoryResponseWriter{header: http.Header{}, status: http.StatusOK} //nolint:exhaustruct
	handler.ServeHTTP(recorder, req)
	return callResult{status: recorder.status, body: recorder.body.Bytes()}, nil
}

type memoryResponseWriter struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (w *memoryResponseWriter) Header() http.Header {
	return w.header
}

func (w *memoryResponseWriter) Write(data []byte) (int, error) {
	return w.body.Write(data) //nolint:wrapcheck
}

func (w *memoryResponseWriter) WriteHeader(status int) {
	w.status = status
}
