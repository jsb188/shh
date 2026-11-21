#!/bin/zsh
set -eu
setopt POSIX_TRAPS  # Run EXIT cleanup on failures inside replace_app as well.
cd "${0:A:h:h}"

if (( $# > 1 )) || [[ $# == 1 && "$1" != --build-only ]]; then
    echo "Usage: ${0:t} [--build-only]" >&2
    exit 2
fi

app="$PWD/build/Shh.app"
applications_dir="${SHH_APPLICATIONS_DIR:-/Applications}"
installed_app="$applications_dir/Shh.app"
build_stage=""
install_stage=""
previous_app=""
replacement=""

cleanup() {
    local result=$?
    if [[ -n "$previous_app" && ( -e "$previous_app" || -L "$previous_app" ) ]]; then
        # An interruption can arrive between the two rename operations.
        if [[ -e "$replacement" || -L "$replacement" ]] || ! mv "$previous_app" "$replacement"; then
            echo "Previous app retained at $previous_app" >&2
            return "$result"
        fi
    fi
    [[ -z "$build_stage" ]] || rm -rf "$build_stage"
    [[ -z "$install_stage" ]] || rm -rf "$install_stage"
    return "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

replace_app() {
    local staged_app="$1"
    replacement="$2"
    previous_app="${staged_app:h}/previous.app"
    if [[ -e "$replacement" || -L "$replacement" ]]; then
        mv "$replacement" "$previous_app"
    fi
    mv "$staged_app" "$replacement"
    previous_app=""
}

mkdir -p build/ModuleCache
# Serialize replacements from this checkout, including builds via build.sh.
touch build/.build-app.lock
zmodload zsh/system
zsystem flock build/.build-app.lock

build_stage="$(mktemp -d "$PWD/build/.Shh-build.XXXXXX")"
staged_app="$build_stage/Shh.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
xcrun swiftc -O -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
    -module-cache-path "$PWD/build/ModuleCache" Sources/*.swift -o "$staged_app/Contents/MacOS/Shh"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$staged_app"
codesign --verify --strict "$staged_app"
replace_app "$staged_app" "$app"
echo "Built $app"

if [[ "${1:-}" == --build-only ]]; then
    exit 0
fi

# Stage and verify on the destination filesystem before replacing the installed app.
mkdir -p "$applications_dir"
install_stage="$(mktemp -d "$applications_dir/.Shh-install.XXXXXX")"
ditto "$app" "$install_stage/Shh.app"
codesign --verify --strict "$install_stage/Shh.app"
replace_app "$install_stage/Shh.app" "$installed_app"
echo "Installed $installed_app"

if [[ "${SHH_REFRESH_DESKTOP:-1}" == 1 ]]; then
    touch "$installed_app"
    if ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed_app"; then
        echo "Installed successfully. macOS could not refresh app registration." >&2
    fi
    if killall -u "$(id -un)" Dock 2>/dev/null; then
        echo "Restarted Dock to refresh the app icon"
    fi
fi
