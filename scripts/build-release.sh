#!/usr/bin/env bash

set -euo pipefail

release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_build_root="${release_root}/.build-release"
release_dist_dir="${release_root}/dist"
release_app_name="춘구마 키우기 도우미.app"
release_app_path="${release_dist_dir}/${release_app_name}"
release_zip_path="${release_dist_dir}/ChoongumaGrowHelper-macOS-universal.zip"
release_module_cache="${release_build_root}/module-cache"
release_package_cache="${release_build_root}/package-cache"

# Some standalone Command Line Tools releases expose a newer default SDK than
# their bundled Swift compiler can load. Prefer the compatible 15.4 SDK when it
# is present; Xcode and CI environments otherwise use their selected SDK.
if [[ -z "${SDKROOT:-}" ]]; then
    if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    else
        export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    fi
fi

if [[ "${release_build_root}" != "${release_root}/.build-release" ||
      "${release_dist_dir}" != "${release_root}/dist" ]]; then
    echo "Refusing to clean unexpected paths." >&2
    exit 1
fi

rm -rf "${release_build_root}" "${release_dist_dir}"
mkdir -p \
    "${release_app_path}/Contents/MacOS" \
    "${release_app_path}/Contents/Resources" \
    "${release_module_cache}" \
    "${release_package_cache}"

export CLANG_MODULE_CACHE_PATH="${release_module_cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${release_module_cache}"

build_arch() {
    local release_arch="$1"
    local release_scratch="${release_build_root}/${release_arch}"
    swift build \
        --disable-sandbox \
        --cache-path "${release_package_cache}" \
        --configuration release \
        --arch "${release_arch}" \
        --scratch-path "${release_scratch}"
    swift build \
        --disable-sandbox \
        --cache-path "${release_package_cache}" \
        --configuration release \
        --arch "${release_arch}" \
        --scratch-path "${release_scratch}" \
        --show-bin-path
}

arm_bin_dir="$(build_arch arm64 | tail -n 1)"
intel_bin_dir="$(build_arch x86_64 | tail -n 1)"

lipo -create \
    "${arm_bin_dir}/ChoongumaGrowHelper" \
    "${intel_bin_dir}/ChoongumaGrowHelper" \
    -output "${release_app_path}/Contents/MacOS/ChoongumaGrowHelper"

install -m 644 "${release_root}/Support/Info.plist" "${release_app_path}/Contents/Info.plist"
install -m 644 "${release_root}/README.md" "${release_app_path}/Contents/Resources/README.md"
codesign --force --deep --sign - "${release_app_path}"

ditto -c -k --sequesterRsrc --keepParent "${release_app_path}" "${release_zip_path}"
(
    cd "${release_dist_dir}"
    shasum -a 256 "$(basename "${release_zip_path}")" > "$(basename "${release_zip_path}").sha256"
)

codesign --verify --deep --strict --verbose=2 "${release_app_path}"
lipo -archs "${release_app_path}/Contents/MacOS/ChoongumaGrowHelper"
echo "Created ${release_zip_path}"
