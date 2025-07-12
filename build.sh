#!/bin/sh
# CLI to build the cling-sync clients.

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

if [ $# -eq 0 ]; then
    echo "Usage: $0 android|tools|fmt|lint|test|precommit [options]"
    echo
    echo "Commands:"
    echo "  android [options]"
    echo "      Build the Android app. Dispatches to android/build.sh"
    echo
    echo "  ios [options]"
    echo "      Build the iOS app. Dispatches to ios/build.sh"
    echo
    echo "  tools"
    echo "      Install development tools (golangci-lint)"
    echo
    echo "  fmt [project]"
    echo "      Format code. If no project is specified, format all projects."
    echo
    echo "  lint [project]"
    echo "      Lint code. If no project is specified, lint all projects."
    echo
    echo "  test [project]"
    echo "      Run tests. If no project is specified, run all tests."
    echo
    echo "  precommit [project]"
    echo "      Run all checks before committing (fmt, lint, build, test)."
    echo
    exit 1
fi

projects="android"

build_tools() {
    if [ -f tools/golangci-lint ]; then
        return
    fi
    echo ">>> Building golangci-lint"
    local tmp_dir=$(mktemp -d)
    cp tools/golangci-lint-*.tar.gz "$tmp_dir"
    cd "$tmp_dir"
    tar xzf golangci-lint-*.tar.gz
    rm golangci-lint-*.tar.gz
    cd golangci-lint-*
    go build -o "$root/tools/golangci-lint" ./cmd/golangci-lint
    cd "$root"
    rm -rf "$tmp_dir"
}

# Run a command for all or a specific project.
# Input:
#   - $1: command
#   - $2: project (optional, if not specified, run for all projects)
run_project_cmd() {
    local cmd="$1"
    local target_projects="$projects"
    if [ $# -gt 1 ]; then
        target_projects="$2"
    fi
    for project in $target_projects; do
        echo ">>> $project"
        cd "$root/$project"
        ./build.sh "$cmd"
    done
}

cmd=$1
shift
case "$cmd" in
    android)
        exec ./android/build.sh "$@"
        ;;
    ios)
        exec ./ios/build.sh "$@"
        ;;
    tools)
        build_tools
        ;;
    fmt)
        build_tools
        run_project_cmd fmt "$@"
        ;;
    lint)
        build_tools
        run_project_cmd lint "$@"
        ;;
    test)
        run_project_cmd test "$@"
        ;;
    precommit)
        run_project_cmd precommit "$@"
        echo "Looks perfect, go ahead and commit this beauty."
        ;;
    *)
        echo "Unknown command: $cmd"
        exit 1
        ;;
esac
