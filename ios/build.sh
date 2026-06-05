#!/bin/sh
# CLI to build the iOS app with Go integration.

bundle_id="com.cling.ClingSync"
development_team_id="253W4734C9"

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

swiftlint_bin="$root/../tools/swiftlint"
golangci_lint_bin="$root/../tools/golangci-lint"
logs_dir="$root/build/logs"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <command> [options]"
    echo
    echo "Prerequisites:"
    echo "  - Go must be installed (check with: go version)"
    echo "  - Xcode must be installed"
    echo
    echo "Commands:"
    echo "  build [target] [options]"
    echo "      Build the target. If no target is specified, build all targets."
    echo "      Available targets:"
    echo "        go [--simulator]  - build the Go shared library"
    echo "            --simulator build for iOS simulator instead of iOS"
    echo "        app [--inc-build-number] - build the iOS app archive for App Store"
    echo "            --inc-build-number increment the build number before building"
    echo "        all               - build everything (default)"
    echo
    echo "  deploy_new_version"
    echo "      Build with incremented build number and upload to App Store Connect."
    echo "      Reads APP_STORE_CONNECT_API_KEY and APP_STORE_CONNECT_ISSUER_ID from"
    echo "      the project root .env file."
    echo
    echo "  App Store Connect API Key Setup:"
    echo "    1. Go to https://appstoreconnect.apple.com/access/integrations/api"
    echo "    2. Create a new key with 'App Manager' role"
    echo "    3. Note the Issuer ID and Key ID"
    echo "    4. Download the .p8 file"
    echo "    5. mkdir -p ~/.appstoreconnect/private_keys"
    echo "    6. mv AuthKey_<KeyID>.p8 ~/.appstoreconnect/private_keys/"
    echo "    7. Add to project root .env file:"
    echo "       APP_STORE_CONNECT_API_KEY=<KeyID>"
    echo "       APP_STORE_CONNECT_ISSUER_ID=<IssuerID>"
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
    echo "  test [--swiftui]"
    echo "      Run integration tests"
    echo "      This runs \`go/main_test.go\` which in turn runs \`$0 test --swiftui\`"
    echo "      to run the actual SwiftUI integration test."
    echo "      We do this so that \`go/main_test.go\` can set up a test repository,"
    echo "      run the SwiftUI integration test, and then verify the repository state."
    echo
    echo "  tools"
    echo "      Install development tools (swiftlint)"
    echo
    echo "  run [--simulator]"
    echo "      Build and run the app on a connected device or simulator"
    echo "      --simulator: Run on simulator instead of physical device"
    echo
    echo "  clean"
    echo "      Clean build artifacts"
    exit 1
fi

build_tools() {
    local current_go_version=$(go env GOVERSION)

    if [ -f "$swiftlint_bin" ]; then
        :
    else
        echo ">>> Downloading swiftlint"
        local url=https://github.com/realm/SwiftLint/releases/download/0.59.1/portable_swiftlint.zip
        local tmp_dir=$(mktemp -d)
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

run_xcodebuild() {
    local log_name="$1"
    shift
    mkdir -p "$logs_dir"
    local log_path="$logs_dir/$log_name"
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

# Build the Go shared library for the iOS app.
#
# Input:
#   $1: "--simulator" to build for iOS simulator instead of iOS, because for some 
#       reason there is a difference.
build_go() {
    local sdk=iphoneos
    local platform=ios
    if [ $# -gt 0 ]; then
        if [ "$1" == "--simulator" ]; then
            sdk=iphonesimulator
            platform=ios-simulator
        else
            echo "Invalid argument (expected none or --simulator): $1"
            exit 1
        fi
    fi
    echo ">>> Building Go shared library for: $platform"
    cd go
    mkdir -p $root/ClingSync/go
 
    # Mimic what `$(go env GOROOT)/misc/ios/clangwrap.sh` does.
    CC="$(xcrun --sdk $sdk --find clang)" \
    CGO_CFLAGS="-isysroot $(xcrun --sdk $sdk --show-sdk-path) -m$platform-version-min=12.0 -fembed-bitcode" \
    CGO_LDFLAGS="-isysroot $(xcrun --sdk $sdk --show-sdk-path)" \
    CGO_ENABLED=1 \
    GOOS=ios \
    GOARCH=arm64 \
    go build -buildmode=c-archive -tags ios -o $root/ClingSync/go/gobridge.a ./...
    
    cd "$root"
}

# Build the iOS app archive for App Store.
#
# Input:
#   $1: "--inc-build-number" to increment the build number before building (optional).
build_app() {
    echo ">>> Building iOS app archive for App Store"

    # Increment build number if requested.
    if [ $# -gt 0 ] && [ "$1" == "--inc-build-number" ]; then
        cd "$root"
        local current_build=$(xcrun agvtool what-version -terse)
        xcrun agvtool next-version -all 2>/dev/null
        local new_build=$(xcrun agvtool what-version -terse)
        echo ">>> Build number: $current_build -> $new_build"
    fi

    # Build Go library for device first.
    build_go

    # Clean build folder.
    rm -rf build/ClingSync.xcarchive build/export

    # Create archive.
    echo ">>> Creating archive..."
    run_xcodebuild xcodebuild-archive.log \
        archive \
        -project ClingSync.xcodeproj \
        -scheme ClingSync \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath build/ClingSync.xcarchive \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$development_team_id"

    # Export IPA for App Store.
    # Use system PATH to avoid Homebrew rsync incompatibility with Xcode's export.
    echo ">>> Exporting IPA for App Store..."
    PATH="/usr/bin:$PATH" run_xcodebuild xcodebuild-export.log \
        -exportArchive \
        -archivePath build/ClingSync.xcarchive \
        -exportPath build/export \
        -exportOptionsPlist ExportOptions.plist

    local repo_build="$root/../build"
    mkdir -p "$repo_build"
    echo ">>> Copying IPA to $repo_build/ClingSync.ipa"
    cp "$root/build/export/ClingSync.ipa" "$repo_build/ClingSync.ipa"

    echo ">>> Build complete"
    echo "    Archive: build/ClingSync.xcarchive"
    echo "    IPA:     build/export/ClingSync.ipa"
}

load_env() {
    local env_file="$root/../.env"
    if [ ! -f "$env_file" ]; then
        echo "Error: .env file not found at $env_file"
        echo "Run './build.sh' for setup instructions."
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
        echo "Run './build.sh' for setup instructions."
        exit 1
    fi

    build_app --inc-build-number

    local ipa="$root/build/export/ClingSync.ipa"

    echo ">>> Validating IPA..."
    xcrun altool --validate-app \
        -f "$ipa" \
        --api-key "$APP_STORE_CONNECT_API_KEY" \
        --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"

    echo ">>> Uploading IPA to App Store Connect..."
    xcrun altool --upload-app \
        -f "$ipa" \
        --api-key "$APP_STORE_CONNECT_API_KEY" \
        --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"

    echo ">>> Upload complete. Check App Store Connect for processing status."
}

build_all() {
    build_go
}

# Install and launch the app.
#
# Input:
#   $1: "--simulator" to run on simulator instead of physical device.
run_app() {
    if [ $# -gt 0 ] && [ "$1" == "--simulator" ]; then
        echo ">>> Running app on simulator"
        
        # Ensure simulator exists and is booted.
        ensure_simulator "ClingSync-Dev"
        
        # Build Go library for simulator.
        build_go --simulator
        
        # Build app for simulator (force arm64 to match Go library).
        run_xcodebuild xcodebuild-run-simulator.log \
            -project ClingSync.xcodeproj \
            -scheme ClingSync \
            -configuration Debug \
            -sdk iphonesimulator \
            -arch arm64 \
            -derivedDataPath build/DerivedData \
            build
        
        # Install and launch using simctl.
        echo ">>> Installing app..."
        local app_path=$(find build/DerivedData -name "ClingSync.app" -type d | head -1)
        if ! xcrun simctl install "$simulator_device_id" "$app_path"; then
            echo "Error: Failed to install app"
            exit 1
        fi
        
        echo ">>> Launching app (bundle ID: $bundle_id)..."
        if ! xcrun simctl launch "$simulator_device_id" "$bundle_id"; then
            echo "Error: Failed to launch app"
            exit 1
        fi
    else
        echo ">>> Running app on physical device"
        
        # Build Go library for device.
        build_go
        
        # Build app for device.
        run_xcodebuild xcodebuild-run-device.log \
            -project ClingSync.xcodeproj \
            -scheme ClingSync \
            -configuration Debug \
            -sdk iphoneos \
            -derivedDataPath build/DerivedData \
            build

        # Install and launch on device using devicectl.
        local app_path=$(find build/DerivedData -path "*/Debug-iphoneos/ClingSync.app" -type d | head -1)
        local device_id
        device_id=$(xcrun devicectl list devices 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
        if [ -z "$device_id" ]; then
            echo "Error: No connected iOS device found"
            exit 1
        fi
        echo ">>> Installing app on device $device_id..."
        xcrun devicectl device install app --device "$device_id" "$app_path"
        echo ">>> Launching app..."
        xcrun devicectl device process launch --device "$device_id" "$bundle_id"
    fi
}

fmt() {
    echo ">>> Formatting code"

    echo "    Formatting Go code"
    cd go
    "$golangci_lint_bin" fmt .
    cd "$root"

    echo "    Formatting Swift code"
    $(xcrun --find swift-format) --recursive --in-place --configuration ./.swiftformat.json .
}

lint() {
    echo ">>> Linting code"
    echo "    Linting Go code"
    cd go
    ../../tools/golangci-lint run ./...
    cd "$root"
    build_tools
    echo "    Linting Swift code"
    "$swiftlint_bin" lint --quiet --strict --config "$root/.swiftlint.yml" .
}

unit_test() {
    echo ">>> Running unit tests"
    cd go
    go test -v -count=1 -run TestIOSUnit ./... "$@"
    cd "$root"
}

integration_test() {
    echo ">>> Running integration tests"
    cd go
    go test -v -count=1 -run TestIOSIntegration ./... "$@"
    cd "$root"
}

test_all() {
    unit_test
    integration_test
}

# Global variable to store the simulator device ID. Is set by `ensure_simulator`.
simulator_device_id=""

# Ensure a simulator exists and is booted.
#
# Input:
#   $1: Simulator name (default: "ClingSync-Dev")
#   $2: Device type (default: "iPhone 15")
#   $3: OS version (default: "17.5")
#
# Output:
#   $simulator_device_id: Simulator device ID
ensure_simulator() {
    local simulator_name="${1:-ClingSync-Dev}"
    local device_type="${2:-iPhone 15}"
    local os_version="${3:-17.5}"

    # Check if simulator exists.
    simulator_device_id=$(xcrun simctl list devices | grep "$simulator_name" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1)

    if [ -z "$simulator_device_id" ]; then
        echo ">>> Creating simulator: $simulator_name" >&2
        simulator_device_id=$(xcrun simctl create "$simulator_name" "$device_type" "iOS$os_version")
        echo ">>> Created simulator with ID: $simulator_device_id" >&2
    else
        echo ">>> Using existing simulator: $simulator_name (ID: $simulator_device_id)" >&2
    fi

    # Check if already booted.
    local state=$(xcrun simctl list devices | grep "$simulator_device_id" | grep -oE '\(Booted\)')
    if [ -z "$state" ]; then
        echo ">>> Booting simulator..." >&2
        xcrun simctl boot "$simulator_device_id"
        # Wait a bit for boot.
        sleep 3
    else
        echo ">>> Simulator already booted" >&2
    fi
}

# Used by the Go test harness to run the unit tests.
unit_xcode() {
    echo ">>> Running unit tests (ClingSyncTests) on simulator"
    ensure_simulator "ClingSync-UnitTest"
    build_go --simulator
    echo ">>> Running ClingSyncTests on simulator: $simulator_device_id"
    run_xcodebuild xcodebuild-unit.log \
        test \
        -project ClingSync.xcodeproj \
        -scheme ClingSync \
        -destination "id=$simulator_device_id" \
        -parallel-testing-enabled NO \
        -only-testing:ClingSyncTests
}

# Used by the Go test harness to run the SwiftUI tests.
integration_test_swiftui() {
    echo ">>> Running the SwiftUI integration test"
    local simulator_name="ClingSync-UITest"
    
    # Ensure simulator exists and is booted.
    ensure_simulator "$simulator_name"
    
    # Build Go library for simulator first.
    build_go --simulator
    
    # Run the UI test.
    echo ">>> Running UI test on simulator: $simulator_device_id"
    local attempt=1
    while true; do
        if run_xcodebuild xcodebuild-test.log \
            test \
            -project ClingSync.xcodeproj \
            -scheme ClingSync \
            -destination "id=$simulator_device_id" \
            -parallel-testing-enabled NO \
            -test-timeouts-enabled YES \
            -default-test-execution-time-allowance 120 \
            -maximum-test-execution-time-allowance 240 \
            -only-testing:ClingSyncUITests
        then
            break
        fi
        if ! grep -q "Failed to clone device" "$logs_dir/xcodebuild-test.log" || [ "$attempt" -ge 3 ]; then
            echo "UI test failed"
            return 1
        fi
        attempt=$((attempt + 1))
        echo ">>> Retrying after simulator clone failure (attempt $attempt)"
        sleep 2
    done
}

clean() {
    echo ">>> Cleaning build artifacts"
    rm -rf ClingSync/go/gobridge.a ClingSync/go/gobridge.h
    rm -rf build/
    xcodebuild -project ClingSync.xcodeproj clean
}

cmd="$1"
shift
case "$cmd" in
    build)
        target="all"
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
            all)
                build_all
                ;;
            *)
                echo "Unknown build target: $target"
                echo "Available targets: go, app, all"
                exit 1
                ;;
        esac
        ;;
    deploy_new_version)
        deploy_new_version
        ;;
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
                unit_test "$@"
                ;;
            integration)
                integration_test "$@"
                ;;
            all)
                test_all
                ;;
            # Internal targets re-invoked by the Go drivers.
            --unit-xcode)
                unit_xcode
                ;;
            --swiftui)
                integration_test_swiftui
                ;;
            *)
                echo "Unknown test target: $target"
                echo "Available targets: unit, integration, all"
                exit 1
                ;;
        esac
        ;;
    tools)
        build_tools
        ;;
    precommit)
        build_tools
        fmt
        lint
        test_all
        ;;
    run)
        run_app "$@"
        ;;
    clean)
        clean
        ;;
    *)
        echo "Unknown command: $1"
        exit 1
        ;;
esac
