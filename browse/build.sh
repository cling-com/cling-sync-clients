#!/bin/sh

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

# Force the project's Go version for all tools.
# This fixes golangci-lint picking up the wrong version.
export GOTOOLCHAIN="go$(awk '/^go /{print $2}' "$root/go.mod")"

if [ $# -eq 0 ]; then
    echo "Usage: $0 fmt|lint|test|precommit [options]"
    echo
    echo "Prerequisites:"
    echo "  - Go must be installed (check with: go version)"
    echo "  - deno must be installed for e2e tests (check with: deno --version)"
    echo
    echo "Commands:"
    echo "  fmt"
    echo "      Format Go code"
    echo
    echo "  lint"
    echo "      Lint Go code"
    echo
    echo "  test [all|unit|e2e]"
    echo "      Run tests (default: all). Unit tests are the Go tests, e2e runs"
    echo "      the Playwright browser tests (requires deno)."
    echo
    echo "  precommit"
    echo "      Run all checks before committing (fmt, lint, test)"
    echo
    exit 1
fi

unit_test() {
    echo ">>> Running unit tests"
    go test -v -count=1 ./...
}

e2e_test() {
    echo ">>> Running e2e tests"
    cd e2e
    # A no-op when the pinned browser revision is already present, so a fresh
    # checkout (or a version bump) provisions itself.
    deno task install-browsers
    deno task test
}

test_all() {
    unit_test
    if command -v deno >/dev/null 2>&1; then
        e2e_test
    else
        echo ">>> Skipping e2e tests (deno not installed)"
    fi
}

fmt() {
    echo ">>> Formatting code"
    ../tools/golangci-lint fmt ./...
}

lint() {
    echo ">>> Linting code"
    ../tools/golangci-lint run ./...
}

cmd=$1
shift
case "$cmd" in
    fmt)
        fmt
        ;;
    lint)
        lint
        ;;
    test)
        target="all"
        if [ $# -gt 0 ]; then
            target="$1"
            shift
        fi
        case "$target" in
            unit)
                unit_test
                ;;
            e2e)
                e2e_test
                ;;
            all)
                test_all
                ;;
            *)
                echo "Unknown test target: $target"
                echo "Available targets: unit, e2e, all"
                exit 1
                ;;
        esac
        ;;
    precommit)
        echo ">>> Running precommit checks"
        $0 fmt
        $0 lint
        $0 test
        ;;
    *)
        echo "Unknown command: $cmd"
        exit 1
        ;;
esac
