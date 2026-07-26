#!/bin/bash
# Build pre-compiled libssh2 + OpenSSL vendor artifacts for VVTerm.
#
# Produces libssh2-vendor.tar.gz with the layout VVTerm expects under
# Vendor/libssh2/:
#   macos/{lib,include}/         iOS arm64
#   ios/{lib,include}/            iOS arm64
#   ios-simulator/{lib,include}/  iOS Simulator arm64
#   include/                      copy of macos/include
#   module.modulemap
#
# VVTerm consumes this with:
#   curl -L -o libssh2-vendor.tar.gz <release-url>
#   tar xzf libssh2-vendor.tar.gz -C Vendor/libssh2
#
# Targets match VVTerm/scripts/build.sh:
#   OpenSSL 3.2.0, macOS dep 13.3, iOS dep 16.0, arm64 only.

set -euo pipefail

OPENSSL_VERSION="3.2.0"
MACOS_DEPLOYMENT_TARGET="13.3"
IOS_DEPLOYMENT_TARGET="16.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
VENDOR_DIR="${VENDOR_DIR:-$WORK_DIR/vendor}"
OUTPUT="${OUTPUT:-$WORK_DIR/libssh2-vendor.tar.gz}"

log() { echo "::group::$1" || echo "[INFO] $1"; }
endgroup() { echo "::endgroup::" || true; }

# ---------- OpenSSL ----------

build_openssl() {
    local target="$1" configure_args="$2" prefix="$3"
    log "OpenSSL ${OPENSSL_VERSION} — ${target}"
    cd "$WORK_DIR/openssl-${OPENSSL_VERSION}"
    make clean 2>/dev/null || true
    ./Configure $configure_args --prefix="$prefix" no-shared no-tests no-apps
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" build_libs
    make install_sw
    endgroup
}

build_openssl_macos() {
    local sdk; sdk=$(xcrun --sdk macosx --show-sdk-path)
    export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
    export CC="$(xcrun --sdk macosx -f clang) -isysroot $sdk -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
    build_openssl "macOS arm64" "darwin64-arm64-cc" "$WORK_DIR/openssl-macos"
    unset MACOSX_DEPLOYMENT_TARGET CC
}

build_openssl_ios() {
    local sdk; sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneOS.sdk"
    export CC="$(xcrun --sdk iphoneos -f clang) -isysroot $sdk -miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
    build_openssl "iOS arm64" "ios64-xcrun" "$WORK_DIR/openssl-ios"
    unset CROSS_TOP CROSS_SDK CC
}

build_openssl_simulator() {
    local sdk; sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneSimulator.sdk"
    export CC="$(xcrun --sdk iphonesimulator -f clang) -isysroot $sdk -arch arm64 -mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
    build_openssl "iOS Simulator arm64" "iossimulator-xcrun" "$WORK_DIR/openssl-simulator"
    unset CROSS_TOP CROSS_SDK CC
}

# ---------- libssh2 ----------

build_libssh2() {
    local target="$1" prefix="$2" openssl_prefix="$3" extra_cmake="$4"
    log "libssh2 — ${target}"
    local build="$WORK_DIR/libssh2-build-$target"
    rm -rf "$build"; mkdir -p "$build"; cd "$build"
    cmake "$REPO_ROOT" \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        $extra_cmake \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DOPENSSL_ROOT_DIR="$openssl_prefix" \
        -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_prefix/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$openssl_prefix/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
    make install
    cp "$openssl_prefix/lib/libssl.a" "$prefix/lib/"
    cp "$openssl_prefix/lib/libcrypto.a" "$prefix/lib/"
    endgroup
}

build_libssh2_macos() {
    build_libssh2 "macOS arm64" "$VENDOR_DIR/macos" "$WORK_DIR/openssl-macos" \
        "-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET"
}

build_libssh2_ios() {
    local sdk; sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    build_libssh2 "iOS arm64" "$VENDOR_DIR/ios" "$WORK_DIR/openssl-ios" \
        "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET"
}

build_libssh2_simulator() {
    local sdk; sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    build_libssh2 "iOS Simulator arm64" "$VENDOR_DIR/ios-simulator" "$WORK_DIR/openssl-simulator" \
        "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET"
}

# ---------- package ----------

create_modulemap() {
    log "module.modulemap"
    rsync -a --delete "$VENDOR_DIR/macos/include/" "$VENDOR_DIR/include/"
    cat > "$VENDOR_DIR/module.modulemap" << 'EOF'
module libssh2 {
    header "include/libssh2.h"
    header "include/libssh2_sftp.h"
    header "include/libssh2_publickey.h"
    link "ssh2"
    link "ssl"
    link "crypto"
    export *
}
EOF
    endgroup
}

package() {
    log "Packaging"
    # Strip cmake metadata to keep the tarball lean (VVTerm doesn't use it).
    find "$VENDOR_DIR" -type d -name cmake -prune -exec rm -rf {} +
    find "$VENDOR_DIR" -name '*.cmake' -delete
    find "$VENDOR_DIR" -name 'cmake_install.cmake' -delete
    tar czf "$OUTPUT" -C "$VENDOR_DIR" .
    endgroup
    echo "Output: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
}

# ---------- main ----------

download_openssl() {
    log "Downloading OpenSSL ${OPENSSL_VERSION}"
    cd "$WORK_DIR"
    if [ ! -d "openssl-${OPENSSL_VERSION}" ]; then
        curl -L -O "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
        tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
    fi
    endgroup
}

main() {
    mkdir -p "$VENDOR_DIR"
    download_openssl
    build_openssl_macos
    build_libssh2_macos
    build_openssl_ios
    build_libssh2_ios
    build_openssl_simulator
    build_libssh2_simulator
    create_modulemap
    package
}

main "$@"
