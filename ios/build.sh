#!/bin/sh
# CLI to build the iOS app with Go integration.

bundle_id="com.cling.ClingSync"
development_team_id="253W4734C9"

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

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
    echo "  fmt"
    echo "      Format code"
    echo
    echh "  lint"
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
    if [ -f tools/swiftlint ]; then
        return
    fi
    echo ">>> Downloading swiftlint"
    local url=https://github.com/realm/SwiftLint/releases/download/0.59.1/portable_swiftlint.zip
    local tmp_dir=$(mktemp -d)
    curl -SsL -o "$tmp_dir/swiftlint.zip" "$url"
    cd "$tmp_dir"
    unzip swiftlint.zip
    rm swiftlint.zip
    cd "$root"
    mkdir -p tools
    mv "$tmp_dir/swiftlint" "$root/tools/"
    rm -rf "$tmp_dir"
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
        echo ">>> Incrementing build number..."
        
        # Use agvtool to increment the build number.
        # This works with modern Xcode projects that don't have Info.plist files.
        cd "$root"
        
        # Get current version and increment it.
        local current_build=$(xcrun agvtool what-version -terse)
        xcrun agvtool next-version -all
        local new_build=$(xcrun agvtool what-version -terse)
        
        echo ">>> Build number: $current_build -> $new_build"
    fi
    
    # Build Go library for device first.
    build_go
    
    # Clean build folder.
    rm -rf build/ClingSync.xcarchive
    
    # Create archive.
    echo ">>> Creating archive..."
    xcodebuild archive \
        -project ClingSync.xcodeproj \
        -scheme ClingSync \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath build/ClingSync.xcarchive \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$development_team_id" \
        || {
            echo "Error: Archive failed"
            exit 1
        }
    
    # Export archive for App Store.
    echo ">>> Exporting archive for App Store..."
    
    xcodebuild -exportArchive \
        -archivePath build/ClingSync.xcarchive \
        -exportPath build/export \
        -exportOptionsPlist build/ExportOptions.plist \
        || {
            echo "Error: Export failed"
            exit 1
        }
    
    echo ">>> Successfully created App Store archive"
    echo "    Archive location: build/ClingSync.xcarchive"
    echo "    IPA location: build/export/ClingSync.ipa"
}

build_all() {
    build_go 
    build_app
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
        xcodebuild \
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
        xcodebuild -project ClingSync.xcodeproj \
            -scheme ClingSync \
            -configuration Debug \
            -sdk iphoneos \
            -derivedDataPath build/DerivedData \
            build
        
        # Install on device using ios-deploy (if available).
        if ! command -v ios-deploy &> /dev/null; then
            echo "ios-deploy not found. Please install it with: brew install ios-deploy"
            echo "Or run the app from Xcode"
            exit 1
        fi
        local app_path=$(find build/DerivedData -name "ClingSync.app" -type d | head -1)
        ios-deploy --bundle "$app_path" --debug
    fi
}

fmt() {
    echo ">>> Formatting code"

    echo "    Formatting Go code"
    cd go
    ../../tools/golangci-lint fmt .
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
    "$root/tools/swiftlint" lint --quiet --strict --config "$root/.swiftlint.yml" .
}

integration_test() {
    echo ">>> Running integration tests"
    cd go
    go test -v -count=1 ./... "$@"
}

# Global variable to store the simulator device ID. Is set by `ensure_simulator`.
simulator_device_id=""

# Ensure a simulator exists and is booted.
#
# Input:
#   $1: Simulator name (default: "ClingSync-Dev")
#   $2: Device type (default: "iPhone 15")  
#   $3: OS version (default: "17")
#
# Output:
#   $simulator_device_id: Simulator device ID
ensure_simulator() {
    local simulator_name="${1:-ClingSync-Dev}"
    local device_type="${2:-iPhone 15}"
    local os_version="${3:-17}"
    
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

integration_test_swiftui() {
    echo ">>> Running the SwiftUI integration test"
    local simulator_name="ClingSync-UITest"
    
    # Ensure simulator exists and is booted.
    ensure_simulator "$simulator_name"
    
    # Build Go library for simulator first.
    build_go --simulator
    
    # Run the UI test.
    echo ">>> Running UI test on simulator: $simulator_device_id"
    xcodebuild test \
        -project ClingSync.xcodeproj \
        -scheme ClingSync \
        -destination "id=$simulator_device_id" \
        -only-testing:ClingSyncUITests/ClingSyncUITests/testHappyPath \
        || {
            echo "❌ UI test failed"
            return 1
        }
    
    echo "✅ UI test passed"
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
    fmt)
        fmt
        ;;
    lint)
        lint
        ;;
    test)
        if [ $# -gt 0 ] && [ "$1" == "--swiftui" ]; then
            integration_test_swiftui
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
