package bridge

import (
	"context"
	"errors"
	"net"
	"syscall"
)

// isNetworkError reports whether err, anywhere in its wrapped chain, is a
// connectivity failure: the host or network being unreachable, the connection
// being refused, reset or timing out, or a DNS lookup failing. Errors are
// wrapped with a chain that supports Unwrap, so errors.As reaches the
// underlying net/syscall error instead of matching on message text.
func isNetworkError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	// Operations from the net package (dial/read/write) and DNS lookups are
	// always connectivity problems.
	if _, ok := errors.AsType[*net.OpError](err); ok {
		return true
	}
	if _, ok := errors.AsType[*net.DNSError](err); ok {
		return true
	}
	// A timeout reported through net.Error (such as an HTTP client deadline
	// wrapped in *url.Error) counts even when it is not an *net.OpError. The
	// Timeout() guard matters because a bare syscall.Errno also satisfies
	// net.Error, and only the connectivity ones below should qualify.
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return errno == syscall.ECONNREFUSED || errno == syscall.ECONNRESET ||
			errno == syscall.EHOSTUNREACH || errno == syscall.EHOSTDOWN ||
			errno == syscall.ENETUNREACH || errno == syscall.ENETDOWN ||
			errno == syscall.ETIMEDOUT
	}
	return false
}
