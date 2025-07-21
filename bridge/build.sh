#!/bin/sh

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

if [ $# -eq 0 ]; then
    echo "Usage: $0 fmt|lint|test|precommit [options]"
    echo
    echo "Prerequisites:"
    echo "  - Go must be installed (check with: go version)"
    echo
    echo "Commands:"
    echo "  fmt"
    echo "      Format Go code"
    echo
    echo "  lint"
    echo "      Lint Go code"
    echo
    echo "  test"
    echo "      Run Go tests"
    echo
    echo "  precommit"
    echo "      Run all checks before committing (fmt, lint, test)"
    echo
    exit 1
fi

test() {
    echo ">>> Running tests"
    go test -v -count=1 ./...
}

fmt() {
    echo ">>> Formatting code"
    ../tools/golangci-lint fmt .
}

# Lint code
lint() {
    echo ">>> Linting code"
    ../tools/golangci-lint run .
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
        test "$@"
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
