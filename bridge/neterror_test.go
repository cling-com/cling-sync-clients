package bridge

import (
	"context"
	"errors"
	"net"
	"net/url"
	"syscall"
	"testing"

	"github.com/flunderpero/cling-sync/lib"
)

func TestIsNetworkError(t *testing.T) {
	t.Parallel()
	opError := &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED} //nolint:exhaustruct
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"connection refused errno", syscall.ECONNREFUSED, true},
		{"host unreachable errno", syscall.EHOSTUNREACH, true},
		{"network unreachable errno", syscall.ENETUNREACH, true},
		{"timed out errno", syscall.ETIMEDOUT, true},
		{"dial op error", opError, true},
		{"dns lookup error", &net.DNSError{Err: "no such host", Name: "nas.local"}, true}, //nolint:exhaustruct
		{"url error wraps op error", &url.Error{Op: "Get", URL: "https://x", Err: opError}, true},
		{"context deadline", context.DeadlineExceeded, true},
		{"wrapped op error", lib.WrapErrorf(opError, "failed to open repository"), true},
		{"deeply wrapped errno", lib.WrapErrorf(lib.WrapErrorf(syscall.ENETUNREACH, "inner"), "outer"), true},
		// Not connectivity: must surface to the user, not be swallowed by backoff.
		{"permission errno", syscall.EACCES, false},
		{"passphrase error", lib.Errorf("passphrase required"), false},
		{"corruption", errors.New("repository is corrupt"), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := isNetworkError(tc.err); got != tc.want {
				t.Fatalf("isNetworkError(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
