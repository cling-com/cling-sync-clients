#!/bin/sh

set -eu

root=$(cd "$(dirname "$0")" && pwd)
cd "$root"

icon_source="$root/../ios/ClingSync/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
icon_target_1x="$root/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png"
icon_target_2x="$root/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
swiftlint_bin="$root/../tools/swiftlint"
golangci_lint_bin="$root/../tools/golangci-lint"
xcode_project="ClingSyncMac.xcodeproj"
xcode_scheme="ClingSyncMac"
derived_data_path="$root/build/DerivedData"
app_path="$derived_data_path/Build/Products/Debug/ClingSyncMac.app"
logs_dir="$root/build/logs"

run_xcodebuild() {
    log_name="$1"
    shift
    mkdir -p "$logs_dir"
    log_path="$logs_dir/$log_name"
    echo "    xcodebuild log: $log_path"
    if xcodebuild "$@" >"$log_path" 2>&1; then
        return 0
    fi
    echo "xcodebuild failed. Last 80 log lines:"
    python3 - <<'PY' "$log_path"
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(errors="replace").splitlines()
for line in lines[-80:]:
    print(line)
PY
    return 1
}

usage() {
    echo "Usage: $0 <command> [options]"
    echo
    echo "Prerequisites:"
    echo "  - Go must be installed (check with: go version)"
    echo "  - Xcode must be installed"
    echo
    echo "Commands:"
    echo "  build [target]"
    echo "      Build the target. Defaults to 'app'."
    echo "      Available targets:"
    echo "        go        - build the Go bridge (arm64 debug)"
    echo "        app       - build the macOS app with xcodebuild (arm64 debug, default)"
    echo "        release   - build the universal App Store release .pkg"
    echo "        universal - build an unsigned universal .app.zip"
    echo
    echo "  fmt"
    echo "      Format code"
    echo
    echo "  lint"
    echo "      Lint code"
    echo
    echo "  precommit"
    echo "      Run all checks before committing (fmt, lint, test)"
    echo
    echo "  test [--xcuitest]"
    echo "      Run integration tests"
    echo "      This runs go/main_test.go which in turn runs xcodebuild UI tests."
    echo "      Pass --xcuitest to run the XCUITest target directly."
    echo
    echo "  tools"
    echo "      Install development tools (swiftlint, golangci-lint)"
    echo
    echo "  run"
    echo "      Build and run the app"
    echo
    echo "  clean"
    echo "      Clean build artifacts"
    echo
    echo "  deploy_new_version"
    echo "      Build universal release with incremented build number and upload"
    echo "      to App Store Connect. Reads API credentials from project root .env."
    exit 1
}

build_tools() {
    current_go_version=$(go env GOVERSION)

    if [ -f "$swiftlint_bin" ]; then
        :
    else
        echo ">>> Downloading swiftlint"
        url=https://github.com/realm/SwiftLint/releases/download/0.59.1/portable_swiftlint.zip
        tmp_dir=$(mktemp -d)
        curl -SsL -o "$tmp_dir/swiftlint.zip" "$url"
        cd "$tmp_dir"
        unzip swiftlint.zip
        rm swiftlint.zip
        cd "$root"
        mkdir -p "$root/../tools"
        mv "$tmp_dir/swiftlint" "$swiftlint_bin"
        rm -rf "$tmp_dir"
    fi

    if [ -f "$golangci_lint_bin" ] \
        && "$golangci_lint_bin" version 2>/dev/null | grep -q "$current_go_version" \
        && "$golangci_lint_bin" version 2>/dev/null | grep -q "2.11.4"
    then
        return
    fi

    echo ">>> Installing golangci-lint"
    GOBIN="$root/../tools" go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.11.4
}

sync_icon() {
    echo ">>> Syncing app icon"
    sips -z 512 512 "$icon_source" --out "$icon_target_1x" >/dev/null
    cp "$icon_source" "$icon_target_2x"
}

build_go() {
    echo ">>> Building Go bridge"
    mkdir -p "$root/build/go"
    rm -f "$root/build/go/gobridge.a" "$root/build/go/gobridge.h"
    cd "$root/go"
    build_tags_args=""
    if [ -n "${CLING_SYNC_GO_BUILD_TAGS:-}" ]; then
        build_tags_args="-tags ${CLING_SYNC_GO_BUILD_TAGS}"
    fi
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CGO_CFLAGS="-mmacosx-version-min=13.0" \
    CGO_LDFLAGS="-mmacosx-version-min=13.0" \
    CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
    go build $build_tags_args -buildmode=c-archive -o "$root/build/go/gobridge.a" ./...
    cd "$root"
}

build_go_universal() {
    echo ">>> Building universal Go bridge (arm64 + amd64)"
    mkdir -p "$root/build/go"
    rm -f "$root/build/go/gobridge.a" "$root/build/go/gobridge.h"
    cd "$root/go"
    build_tags_args=""
    if [ -n "${CLING_SYNC_GO_BUILD_TAGS:-}" ]; then
        build_tags_args="-tags ${CLING_SYNC_GO_BUILD_TAGS}"
    fi

    echo "    Building arm64..."
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CGO_CFLAGS="-mmacosx-version-min=13.0" \
    CGO_LDFLAGS="-mmacosx-version-min=13.0" \
    CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
    go build $build_tags_args -buildmode=c-archive -o "$root/build/go/gobridge-arm64.a" ./...

    echo "    Building amd64..."
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CGO_CFLAGS="-mmacosx-version-min=13.0 -target x86_64-apple-macos13.0" \
    CGO_LDFLAGS="-mmacosx-version-min=13.0 -target x86_64-apple-macos13.0" \
    CC="clang -target x86_64-apple-macos13.0" \
    CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 \
    go build $build_tags_args -buildmode=c-archive -o "$root/build/go/gobridge-amd64.a" ./...

    echo "    Creating universal binary..."
    lipo -create \
        "$root/build/go/gobridge-arm64.a" \
        "$root/build/go/gobridge-amd64.a" \
        -output "$root/build/go/gobridge.a"
    # Use the arm64 header (identical across architectures).
    cp "$root/build/go/gobridge-arm64.h" "$root/build/go/gobridge.h"
    rm -f "$root/build/go/gobridge-arm64.a" "$root/build/go/gobridge-amd64.a" \
          "$root/build/go/gobridge-arm64.h" "$root/build/go/gobridge-amd64.h"

    cd "$root"
}

build_app() {
    echo ">>> Building macOS app"
    sync_icon
    build_go
    run_xcodebuild xcodebuild-build.log \
        -project "$xcode_project" \
        -scheme "$xcode_scheme" \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data_path" \
        build
    local repo_build="$root/../build"
    mkdir -p "$repo_build"
    echo ">>> Copying app to $repo_build/ClingSyncMac.app"
    rm -rf "$repo_build/ClingSyncMac.app"
    cp -R "$app_path" "$repo_build/ClingSyncMac.app"
}

fmt() {
    echo ">>> Formatting code"
    build_tools

    echo "    Formatting Go code"
    cd "$root/go"
    "$golangci_lint_bin" fmt .
    cd "$root"

    echo "    Formatting Swift code"
    "$(xcrun --find swift-format)" --recursive --in-place --configuration "$root/../ios/.swiftformat.json" "$root"
}

lint() {
    echo ">>> Linting code"
    build_tools

    echo "    Linting Go code"
    cd "$root/go"
    "$golangci_lint_bin" run ./...
    cd "$root"
    echo "    Linting Swift code"
    "$swiftlint_bin" lint --quiet --strict --config "$root/.swiftlint.yml" "$root"
}

integration_test() {
    echo ">>> Running integration tests"
    cd "$root/go"
    go test -v -count=1 ./...
}

integration_test_xcuitest() {
    echo ">>> Running XCUITests"
    sync_icon
    run_xcodebuild xcodebuild-test.log \
        -project "$xcode_project" \
        -scheme "$xcode_scheme" \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data_path" \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 30 \
        -maximum-test-execution-time-allowance 90 \
        test
}

development_team_id="253W4734C9"

build_release() {
    echo ">>> Building macOS app for App Store"
    sync_icon

    # Increment build number if requested.
    if [ $# -gt 0 ] && [ "$1" = "--inc-build-number" ]; then
        cd "$root"
        current_build=$(xcrun agvtool what-version -terse)
        xcrun agvtool next-version -all 2>/dev/null
        new_build=$(xcrun agvtool what-version -terse)
        echo ">>> Build number: $current_build -> $new_build"
    fi

    build_go_universal

    rm -rf build/ClingSyncMac.xcarchive build/export

    echo ">>> Creating archive..."
    run_xcodebuild xcodebuild-archive.log \
        archive \
        -project "$xcode_project" \
        -scheme "$xcode_scheme" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath build/ClingSyncMac.xcarchive \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_ENTITLEMENTS=ClingSyncMac.entitlements \
        ENABLE_HARDENED_RUNTIME=YES \
        DEVELOPMENT_TEAM="$development_team_id" \
        -allowProvisioningUpdates

    echo ">>> Exporting for App Store..."
    PATH="/usr/bin:$PATH" run_xcodebuild xcodebuild-export.log \
        -exportArchive \
        -archivePath build/ClingSyncMac.xcarchive \
        -exportPath build/export \
        -exportOptionsPlist ExportOptions.plist \
        -allowProvisioningUpdates

    local repo_build="$root/../build"
    mkdir -p "$repo_build"
    local pkg
    pkg=$(find "$root/build/export" -name "*.pkg" | head -1)
    if [ -n "$pkg" ]; then
        echo ">>> Copying PKG to $repo_build/ClingSyncMac.pkg"
        cp "$pkg" "$repo_build/ClingSyncMac.pkg"
    fi

    echo ">>> Build complete"
    echo "    Archive: build/ClingSyncMac.xcarchive"
    echo "    PKG:     build/export/"
}

build_universal() {
    echo ">>> Building universal unsigned macOS app"
    sync_icon
    build_go_universal

    local app_release_path="$derived_data_path/Build/Products/Release/ClingSyncMac.app"
    rm -rf "$derived_data_path/Build/Products/Release"

    run_xcodebuild xcodebuild-universal.log \
        -project "$xcode_project" \
        -scheme "$xcode_scheme" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data_path" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_ENTITLEMENTS="" \
        ENABLE_HARDENED_RUNTIME=NO \
        build

    if [ ! -d "$app_release_path" ]; then
        echo "Error: built .app not found at $app_release_path"
        exit 1
    fi

    local repo_build="$root/../build"
    mkdir -p "$repo_build"
    local zip_path="$repo_build/ClingSyncMac.app.zip"
    echo ">>> Zipping app to $zip_path"
    rm -f "$zip_path"
    (cd "$(dirname "$app_release_path")" && zip -qry "$zip_path" "$(basename "$app_release_path")")

    echo ">>> Build complete"
    echo "    Zip: $zip_path"
    echo "    On each Mac: unzip, then right-click the .app -> Open (one-time Gatekeeper allow)."
}

load_env() {
    env_file="$root/../.env"
    if [ ! -f "$env_file" ]; then
        echo "Error: .env file not found at $env_file"
        exit 1
    fi
    set -a
    . "$env_file"
    set +a
}

deploy_new_version() {
    load_env

    if [ -z "${APP_STORE_CONNECT_API_KEY:-}" ] || [ -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]; then
        echo "Error: APP_STORE_CONNECT_API_KEY and APP_STORE_CONNECT_ISSUER_ID must be set in .env"
        exit 1
    fi

    build_release --inc-build-number

    pkg=$(find "$root/build/export" -name "*.pkg" | head -1)
    if [ -z "$pkg" ]; then
        echo "Error: No .pkg found in build/export/"
        exit 1
    fi

    echo ">>> Validating package..."
    xcrun altool --validate-app \
        -f "$pkg" \
        --api-key "$APP_STORE_CONNECT_API_KEY" \
        --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"

    echo ">>> Uploading to App Store Connect..."
    xcrun altool --upload-app \
        -f "$pkg" \
        --api-key "$APP_STORE_CONNECT_API_KEY" \
        --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"

    echo ">>> Upload complete. Check App Store Connect for processing status."
}

run_app() {
    build_app
    open "$app_path"
}

clean() {
    echo ">>> Cleaning build artifacts"
    rm -rf "$root/build"
    xcodebuild -project "$xcode_project" clean >/dev/null
}

if [ $# -eq 0 ]; then
    usage
fi

cmd="$1"
shift
case "$cmd" in
    build)
        target="app"
        if [ $# -gt 0 ]; then
            target="$1"
            shift
        fi
        case "$target" in
            go)
                build_go "$@"
                ;;
            app)
                build_app "$@"
                ;;
            release)
                build_release "$@"
                ;;
            universal)
                build_universal "$@"
                ;;
            *)
                echo "Unknown build target: $target"
                echo "Available targets: go, app, release, universal"
                exit 1
                ;;
        esac
        ;;
    fmt)
        fmt
        ;;
    lint)
        lint
        ;;
    test)
        if [ $# -gt 0 ] && [ "$1" = "--xcuitest" ]; then
            integration_test_xcuitest
        else
            integration_test
        fi
        ;;
    tools)
        build_tools
        ;;
    precommit)
        build_tools
        fmt
        lint
        integration_test
        ;;
    run)
        run_app
        ;;
    clean)
        clean
        ;;
    deploy_new_version)
        deploy_new_version
        ;;
    *)
        echo "Unknown command: $cmd"
        exit 1
        ;;
esac
