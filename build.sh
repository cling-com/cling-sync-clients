#!/bin/sh
# CLI to build the cling-sync clients.

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

if [ $# -eq 0 ]; then
    echo "Usage: $0 bridge|ios|android|macos|tools|use-dev-cling-sync|build|fmt|lint|test|precommit [options]"
    echo
    echo "Commands:"
    echo "  bridge [options]"
    echo "      Build the shared bridge. Dispatches to bridge/build.sh"
    echo
    echo "  android [options]"
    echo "      Build the Android app. Dispatches to android/build.sh"
    echo
    echo "  ios [options]"
    echo "      Build the iOS app. Dispatches to ios/build.sh"
    echo
    echo "  macos [options]"
    echo "      Build the macOS app. Dispatches to macos/build.sh"
    echo
    echo "  tools"
    echo "      Install development tools (golangci-lint)"
    echo
    echo "  release check|tag|build|upload|all"
    echo "      Tag, build, and publish a new patch release. Run on darwin."
    echo "        check  - verify HEAD has a green CI build on GitHub"
    echo "                 (tag, build, and upload run this first too)"
    echo "        tag    - tag HEAD with the next patch version (latest pushed + 1)"
    echo "        build  - build the GitHub downloads (macOS universal app, Android APK)"
    echo "                 into ./dist and the macOS/iOS App Store packages"
    echo "        upload - push the tag, upload macOS/iOS to App Store Connect, and"
    echo "                 publish ./dist as a GitHub release"
    echo "        all    - run check, tag, build, and upload in order"
    echo
    echo "  use-dev-cling-sync on|off"
    echo "      Build against the ../cling-sync checkout instead of the released"
    echo "      version, for lock-step development. While on, \`macos test --remote\`"
    echo "      also mirrors ../cling-sync to the runner VM and tests against it."
    echo
    echo "  build [project]"
    echo "      Build apps. If no project is specified, build all apps (ios, android, macos)."
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

projects="bridge ios android macos"

# The checkout `use-dev-cling-sync` builds against. macos/build.sh assumes this
# same location when mirroring it to the runner VM.
dev_cling_sync="../cling-sync"

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

# Latest vMAJOR.MINOR.PATCH release tag, or empty if there are none.
latest_version() {
    git for-each-ref --sort=-v:refname --format='%(refname:short)' 'refs/tags/*' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1
}

# Latest vMAJOR.MINOR.PATCH release tag that exists on the remote, excluding $1
# if given, or empty if there are none. The remote is the source of truth for
# what has been released: a local tag from a release run that failed before
# `upload` is not one.
latest_pushed_version() {
    git ls-remote --tags origin 'v*' \
        | sed -n 's|.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
        | grep -vxF "${1:-}" \
        | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -n1
}

# Verify the current HEAD has a green CI build on GitHub.
run_check_release() {
    cd "$root"
    command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is not installed"; exit 1; }
    local sha state
    sha=$(git rev-parse HEAD)
    echo ">>> Checking CI status for $sha"
    state=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs" --jq '
        if (.check_runs | length) == 0 then "none"
        elif any(.check_runs[]; .status != "completed") then "pending"
        elif all(.check_runs[]; .conclusion == "success" or .conclusion == "skipped") then "success"
        else "failure"
        end') || { echo "Could not query CI status for HEAD. Is it pushed to GitHub?"; exit 1; }
    case "$state" in
        success) echo "    CI is green" ;;
        none)    echo "No CI build found for HEAD. Push it and wait for CI."; exit 1 ;;
        pending) echo "CI is still running for HEAD. Wait for it to finish."; exit 1 ;;
        *)       echo "CI is not green for HEAD ($state)."; exit 1 ;;
    esac
}

# Tag HEAD with the next patch version after the latest *pushed* release. If a
# previous release run already created that tag but died before pushing it, reuse
# it rather than bumping again, so a resumed run releases the version it started.
run_tag_release() {
    cd "$root"
    if [ -n "$(git status --porcelain)" ]; then
        echo "Working tree is not clean. Commit or stash your changes before releasing."
        exit 1
    fi
    local pushed ver major minor patch new
    pushed=$(latest_pushed_version)
    [ -n "$pushed" ] || { echo "No pushed release tag found on origin."; exit 1; }
    ver="${pushed#v}"
    major="${ver%%.*}"
    minor="${ver#*.}"; minor="${minor%%.*}"
    patch="${ver##*.}"
    new="v$major.$minor.$((patch + 1))"
    if git rev-parse -q --verify "refs/tags/$new^{commit}" >/dev/null; then
        echo ">>> Reusing $new, tagged by an earlier run that never pushed it"
    else
        echo ">>> Tagging $new (latest pushed: $pushed)"
    fi
    # -f so a reused tag follows HEAD if it moved since that run.
    git tag -f "$new"
}

# Build every release artifact for the current tag: the GitHub downloads (macOS
# universal app, Android APK) into ./dist plus the macOS and iOS App Store
# packages. Each platform build derives its version from the latest tag.
run_build_release() {
    cd "$root"
    local version
    version=$(latest_version)
    [ -n "$version" ] || { echo "No release tag found. Run \`release tag\` first."; exit 1; }
    echo ">>> Building release artifacts for $version"
    rm -rf dist
    mkdir -p dist

    echo ">>> Building macOS universal app (GitHub)"
    ./macos/build.sh build universal
    cp "build/ClingSyncMac.app.zip" "dist/ClingSyncMac-$version.app.zip"

    echo ">>> Building Android release APK (GitHub)"
    ./android/build.sh build release
    cp "build/clingsync-release.apk" "dist/ClingSync-android-$version.apk"

    echo ">>> Building macOS App Store package"
    ./macos/build.sh release build

    echo ">>> Building iOS App Store package"
    ./ios/build.sh release build

    echo ">>> GitHub release artifacts:"
    ls -1 dist
}

# Push the current tag, upload the macOS and iOS packages to App Store Connect,
# and publish ./dist as a GitHub release.
run_upload_release() {
    cd "$root"
    command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is not installed"; exit 1; }
    local version prev
    version=$(latest_version)
    [ -n "$version" ] || { echo "No release tag found. Run \`release tag\` first."; exit 1; }
    # Excluding the version being released keeps the notes right when a partial
    # upload is re-run and the tag is already on the remote.
    prev=$(latest_pushed_version "$version")
    echo ">>> Pushing git tag $version"
    git push origin "$version"

    echo ">>> Uploading macOS to App Store Connect"
    ./macos/build.sh release upload

    echo ">>> Uploading iOS to App Store Connect"
    ./ios/build.sh release upload

    echo ">>> Publishing GitHub release $version"
    # Release notes are the commit log since the previous release tag.
    git log --format='- %s (%h) by %an' "$prev..$version" \
        | gh release create "$version" dist/* --title "$version" --notes-file -
    echo
    echo "Released $version"
}

# Point the Go modules at the ../cling-sync checkout instead of the released
# version, for developing both repositories in lock-step. The go.work file is
# untracked, so this is a local-only override that never reaches CI or a release.
# Its presence is what "dev mode is on" means, here and in macos/build.sh.
run_use_dev_cling_sync() {
    cd "$root"
    case "${1:-}" in
        on)
            [ -f "$dev_cling_sync/go.mod" ] || {
                echo "No Go module at $dev_cling_sync"; exit 1
            }
            rm -f go.work go.work.sum
            go work init
            go work use ./bridge ./ios/go ./android/go ./macos/go "$dev_cling_sync"
            echo ">>> On. Building against $dev_cling_sync."
            ;;
        off)
            rm -f go.work go.work.sum
            echo ">>> Off. Building against the released cling-sync."
            ;;
        *)
            if [ -f go.work ]; then
                echo "On, building against $dev_cling_sync."
            else
                echo "Off, building against the released cling-sync."
            fi
            echo "Usage: $0 use-dev-cling-sync on|off"
            exit 1
            ;;
    esac
}

run_release() {
    # tag, build, and upload each verify HEAD has a green CI build first, so a
    # release can never be cut from a red or untested commit regardless of which
    # phase is invoked. `all` runs the check once up front instead of per phase.
    case "${1:-}" in
        check)  run_check_release ;;
        tag)    run_check_release; run_tag_release ;;
        build)  run_check_release; run_build_release ;;
        upload) run_check_release; run_upload_release ;;
        all)
            run_check_release
            run_tag_release
            run_build_release
            run_upload_release
            ;;
        *)
            echo "Usage: $0 release check|tag|build|upload|all"
            exit 1
            ;;
    esac
}

cmd=$1
shift
case "$cmd" in
    android)
        exec ./android/build.sh "$@"
        ;;
    bridge)
        exec ./bridge/build.sh "$@"
        ;;
    ios)
        exec ./ios/build.sh "$@"
        ;;
    macos)
        exec ./macos/build.sh "$@"
        ;;
    tools)
        build_tools
        ;;
    release)
        run_release "$@"
        ;;
    use-dev-cling-sync)
        run_use_dev_cling_sync "$@"
        ;;
    build)
        apps="ios android macos"
        if [ $# -gt 0 ]; then
            apps="$1"
        fi
        run_project_cmd build "$apps"
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
