#!/bin/sh
# CLI to build the Android app with Go integration.

set -eu
root=$(cd $(dirname $0) && pwd)
cd "$root"

if [ $# -eq 0 ]; then
    echo "Usage: $0 build|tools|run|fmt|lint|test|env [options]"
    echo
    echo "Prerequisites:"
    echo "  - Go must be installed (check with: go version)"
    echo
    echo "Commands:"
    echo "  build [target]"
    echo "      Build the target. If no target is specified, build all targets."
    echo "      Available targets:"
    echo "        go  - build the Go shared library"
    echo "        apk - build the Android APK"
    echo "        all - build both Go library and APK (default)"
    echo
    echo "  tools"
    echo "      Install Android SDK and Gradle under ./tools/"
    echo
    echo "  run [--create-samples]"
    echo "      Build and run the app on connected device/emulator"
    echo "      If no device is connected, start the first available emulator"
    echo "      --create-samples: Create sample image files in the camera folder"
    echo
    echo "  fmt"
    echo "      Format Go and Kotlin code"
    echo
    echo "  lint"
    echo "      Lint Go and Kotlin code"
    echo
    echo "  test [target]"
    echo "      Run tests for the specified target. If no target is specified, run all tests."
    echo "      Available targets:"
    echo "        integration - run integration test on an emulator"
    echo "        unit        - run Kotlin/Android unit tests"
    echo "        all         - run all tests (default)"
    echo
    echo "  env"
    echo "      Print environment setup commands for the current shell"
    echo "      Usage: eval \$(./build.sh env)"
    echo
    echo "  precommit"
    echo "      Run all checks before committing (fmt, lint, build, test)"
    echo
    exit 1
fi

# Tool versions - fixed for reproducible builds
ANDROID_SDK_VERSION="11076708"  # Android SDK Command Line Tools
ANDROID_NDK_VERSION="28.2.13676358"  # NDK version for Android compilation
JDK_VERSION="23.0.1+11"  # JDK version for Gradle 8.13 compatibility

# Install build tools under ./tools (Android SDK and JDK)
build_tools() {
    mkdir -p tools
    
    # Install Android SDK Command Line Tools
    if [ ! -f tools/android-sdk/cmdline-tools/latest/bin/sdkmanager ]; then
        echo ">>> Installing Android SDK Command Line Tools"
        local sdk_archive="commandlinetools-mac-${ANDROID_SDK_VERSION}_latest.zip"
        local sdk_url="https://dl.google.com/android/repository/${sdk_archive}"

        curl -SsL -o "tools/${sdk_archive}" "$sdk_url"
        cd tools
        mkdir -p android-sdk/cmdline-tools
        unzip -q "$sdk_archive" -d android-sdk/cmdline-tools/
        mv android-sdk/cmdline-tools/cmdline-tools android-sdk/cmdline-tools/latest
        rm "$sdk_archive"
        cd "$root"
        
        # Install required Android components
        echo "    Installing Android SDK components"
        export ANDROID_HOME="$root/tools/android-sdk"
        export ANDROID_SDK_ROOT="$ANDROID_HOME"
        export ANDROID_AVD_HOME="$ANDROID_HOME/avd"
        mkdir -p "$ANDROID_AVD_HOME"
        yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > tools/sdkmanager.log 2>&1 || true
        "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
            "platform-tools" \
            "platforms;android-35" \
            "build-tools;35.0.0" \
            "emulator" \
            "ndk;${ANDROID_NDK_VERSION}" \
            "system-images;android-35;google_apis;arm64-v8a" >> tools/sdkmanager.log 2>&1
        
        # Create local AVD
        echo "    Creating local AVD"
        echo "no" | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
            --name "ClingSync_Pixel_7" \
            --package "system-images;android-35;google_apis;arm64-v8a" \
            --device "pixel_7_pro" \
            --path "$ANDROID_AVD_HOME/ClingSync_Pixel_7.avd" > tools/avd.log 2>&1 || {
                echo "    AVD creation failed. Check tools/avd.log for details"
            } 
        
        # golangci-lint and LSP need to find jni.h when analyzing CGO code.
        # Usually, you would just use `<include jni.h>` but tools cannot resolve
        # the path to jni.h.
        # So we make it easy on ourselves by creating a symlink to the NDK headers.
        echo "    Creating JNI headers symlink"
        echo $(pwd)
        cd tools/android-sdk/ndk
        ln -sf ${ANDROID_NDK_VERSION}/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include jni-headers
        cd "$root"
    fi
    
    # Install JDK (required for Gradle 8.13 compatibility)
    if [ ! -d "tools/jdk" ]; then
        echo ">>> Installing JDK $JDK_VERSION"
        local os_name=$(uname -s)
        local os_arch=$(uname -m)
        
        case "$os_name:$os_arch" in
            Darwin:arm64)  local jdk_file="OpenJDK23U-jdk_aarch64_mac_hotspot_${JDK_VERSION/+/_}.tar.gz" ;;
            Linux:aarch64) local jdk_file="OpenJDK23U-jdk_aarch64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz" ;;
            Linux:x86_64)  local jdk_file="OpenJDK23U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz" ;;
            *) echo "    Unsupported platform: $os_name:$os_arch"; exit 1 ;;
        esac
        
        echo "    Downloading JDK for $os_name $os_arch"
        curl -SsL -o "tools/download_jdk.tar.gz" "https://github.com/adoptium/temurin23-binaries/releases/download/jdk-${JDK_VERSION}/${jdk_file}"
        cd tools && tar -xzf download_jdk.tar.gz && rm download_jdk.tar.gz
        mv jdk-* jdk
        cd "$root"
        echo "    JDK $JDK_VERSION installed successfully"
    fi
}

get_android_paths() {
    echo "export ANDROID_HOME=$root/tools/android-sdk"
    echo "export ANDROID_SDK_ROOT=$root/tools/android-sdk"
    echo "export ANDROID_AVD_HOME=$root/tools/android-sdk/avd"
    echo "export NDK_HOME=$root/tools/android-sdk/ndk/${ANDROID_NDK_VERSION}"
    echo "export NDK_ROOT=$root/tools/android-sdk/ndk/${ANDROID_NDK_VERSION}"
    echo "export GOPATH=$root/tools/gopath"
    # Set JAVA_HOME based on OS structure
    if [ -d "$root/tools/jdk/Contents/Home" ]; then
        echo "export JAVA_HOME=$root/tools/jdk/Contents/Home"
    else
        echo "export JAVA_HOME=$root/tools/jdk"
    fi
}

# Get PATH additions for Android tools.
get_android_path_extension() {
    # Set JDK bin path based on OS structure
    if [ -d "$root/tools/jdk/Contents/Home/bin" ]; then
        local jdk_bin_path="$root/tools/jdk/Contents/Home/bin"
    else
        local jdk_bin_path="$root/tools/jdk/bin"
    fi
    echo "$jdk_bin_path:$root/tools/android-sdk/platform-tools:$root/tools/android-sdk/cmdline-tools/latest/bin:$root/tools/android-sdk/emulator"
}

# Print environment setup commands for eval.
print_env() {
    if [ ! -d "$root/tools/android-sdk" ]; then
        echo "echo 'Error: Android SDK not installed. Run: ./build.sh tools' >&2" 
        exit 1
    fi
    if [ ! -d "$root/tools/jdk" ]; then
        echo "echo 'Error: JDK not installed. Run: ./build.sh tools' >&2" 
        exit 1
    fi
    get_android_paths
    echo "export PATH=\"$(get_android_path_extension):\$PATH\""
}

# Set PATH to include system Go and local Android tools.
set_local_path() {
    # Include system Go paths, use system GOROOT and local GOPATH.
    local go_bin_dir=$(dirname $(which go))
    export GOPATH="$root/tools/gopath"
    mkdir -p "$GOPATH"
    
    # Set Android environment variables
    eval $(get_android_paths)
    
    # Set PATH with Android tools prepended
    export PATH="$go_bin_dir:$(get_android_path_extension):/usr/bin:/bin"
}

build_go() {
    echo ">>> Building Go shared library"
    set_local_path
    cd go
    mkdir -p ../app/src/main/jniLibs/arm64-v8a
 
    # Cross-compile for Android using NDK toolchain.
    CC="$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang" \
    CXX="$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang++" \
    CGO_ENABLED=1 \
    GOOS=android \
    GOARCH=arm64 \
    go build -buildmode=c-shared -tags cgo -o ../app/src/main/jniLibs/arm64-v8a/libclingsync.so ./...
    
    # Copy header file to jniLibs (for reference)
    cp ../app/src/main/jniLibs/arm64-v8a/libclingsync.h ../app/src/main/jniLibs/ 2>/dev/null || true

    cd "$root"
}

build_apk() {
    echo ">>> Building Android APK"
    set_local_path
    ./gradlew assembleDebug -q
}

build_all() {
    build_go
    build_apk
}

create_sample_files() {
    echo ">>> Creating sample files in emulator"
    local temp_dir="/tmp/clingsync_samples"
    mkdir -p "$temp_dir"
    
    # Create 3 tiny PNG files with different colors
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==" | base64 -d > "$temp_dir/red_sample.png"
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" | base64 -d > "$temp_dir/green_sample.png"
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" | base64 -d > "$temp_dir/blue_sample.png"
    
    echo "    Pushing sample files to device..."
    adb shell "mkdir -p /sdcard/DCIM/Camera"
    
    for file in "$temp_dir"/*; do
        adb push "$file" "/sdcard/DCIM/Camera/" 2>/dev/null
    done
    
    rm -rf "$temp_dir"
    echo "    Sample files created successfully"
}

start_emulator_if_needed() {
    if ! adb devices | grep -q "device$"; then
        echo ">>> No devices connected. Starting emulator..."
        
        # Get first available AVD from local installation.
        local avd=$("$ANDROID_HOME/emulator/emulator" -list-avds 2>/dev/null | head -n1)
        
        if [ -z "$avd" ]; then
            echo "    No AVDs found. Creating one..."
            echo "no" | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
                --name "ClingSync_Pixel_7" \
                --package "system-images;android-35;google_apis;arm64-v8a" \
                --device "pixel_7_pro" \
                --path "$ANDROID_AVD_HOME/ClingSync_Pixel_7.avd" > tools/avd-runtime.log 2>&1
            avd="ClingSync_Pixel_7"
        fi
        
        "$ANDROID_HOME/emulator/emulator" -avd "$avd" -no-snapshot-load &
        
        # Wait for it to boot.
        adb wait-for-device
        while [ "$(adb shell getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
            sleep 2
        done
    fi
}

run_app() {
    echo ">>> Running app"
    set_local_path
    
    # Parse command line options
    local create_samples=false
    if [ $# -gt 0 ] && [ "$1" = "--create-samples" ]; then
        create_samples=true
    fi
    
    build_all
    start_emulator_if_needed
    ./gradlew installDebug -q
    
    if [ "$create_samples" = true ]; then
        echo ">>> Creating sample files in emulator"
        create_sample_files
    fi
    
    adb shell am start -n com.clingsync.android/.MainActivity
    echo "    App launched successfully"
}

test_integration() {
    echo ">>> Running integration tests"
    set_local_path
    build_go
    start_emulator_if_needed
    cd go
    go test -v -count=1 ./... "$@"
}

test_unit() {
    echo ">>> Running unit tests"
    set_local_path
    ./gradlew testDebugUnitTest --rerun-tasks -q "$@"
}

test_all() {
    test_integration "$@"
    cd $root
    test_unit "$@"
}

fmt() {
    echo ">>> Formatting code"
    set_local_path
    
    # Format Go code
    echo "    Formatting Go code"
    cd go
    ../../tools/golangci-lint fmt .
    cd "$root"
    
    # Format Kotlin code
    echo "    Formatting Kotlin code"
    ./gradlew ktlintFormat -q
}

# Lint code
lint() {
    echo ">>> Linting code"
    set_local_path
    
    # Lint Go code
    echo "    Linting Go code"
    cd go
    ../../tools/golangci-lint run .
    cd "$root"
    
    # Lint Kotlin code
    echo "    Linting Kotlin code"
    ./gradlew ktlintCheck -q
}

cmd=$1
shift
case "$cmd" in
    build)
        build_tools
        target="all"
        if [ $# -gt 0 ]; then
            target="$1"
        fi
        case "$target" in
            go)
                build_go "$@"
                ;;
            apk)
                build_apk "$@"
                ;;
            all)
                build_all "$@"
                ;;
            *)
                echo "Unknown build target: $1"
                echo "Available targets: go, apk, all"
                exit 1
                ;;
        esac
        ;;
    tools)
        build_tools
        ;;
    run)
        build_tools
        run_app "$@"
        ;;
    fmt)
        fmt
        ;;
    lint)
        lint
        ;;
    test)
        build_tools
        target="all"
        if [ $# -gt 0 ]; then
            target="$1"
            shift
        fi
        case "$target" in
            integration)
                test_integration "$@"
                ;;
            unit)
                test_unit "$@"
                ;;
            all)
                test_all "$@"
                ;;
            *)
                echo "Unknown test target: $1"
                echo "Available targets: go, unit, all"
                exit 1
                ;;
        esac
        ;;
    env)
        print_env
        ;;
    precommit)
        echo ">>> Running precommit checks"
        $0 fmt
        $0 lint
        $0 build all
        $0 test all 
        ;;
    *)
        echo "Unknown command: $cmd"
        exit 1
        ;;
esac
