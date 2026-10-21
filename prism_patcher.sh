#!/usr/bin/env bash
set -euo pipefail

# LM Studio PrismML Auto-Patcher (macOS)
#
# Usage:
#   ./prism_patcher.sh                 # patch every installed llama.cpp backend
#   ./prism_patcher.sh macos-arm64     # override the PrismML target prefix
#   ./prism_patcher.sh --check         # exit 0 if every backend is already patched
#                                      # (no network access; used by the watcher)

for cmd in curl jq tar uname; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required but not installed. Please install it first."
        exit 1
    fi
done

OS="$(uname -s)"
ARCH="$(uname -m)"

if [ "$OS" != "Darwin" ]; then
    echo "Error: this build targets macOS (Darwin). Detected: $OS"
    exit 1
fi

# Where LM Studio keeps its engine backends
BACKENDS_DIR="${LMSTUDIO_BACKENDS_DIR:-$HOME/.lmstudio/extensions/backends}"
INTERNAL_DIR="${LMSTUDIO_INTERNAL_DIR:-$HOME/.lmstudio/.internal}"

# Default PrismML target for the host architecture
case "$ARCH" in
    arm64)   DEFAULT_TARGET="macos-arm64" ;;
    x86_64)  DEFAULT_TARGET="macos-x64" ;;
    *)
        echo "Error: unsupported CPU architecture '$ARCH'."
        exit 1
        ;;
esac

# --- arguments -------------------------------------------------------------
CHECK_ONLY=0
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '4,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "Error: unknown option '$arg'."
            exit 2
            ;;
        *)
            TARGET="$arg"
            ;;
    esac
done
TARGET="${TARGET:-$DEFAULT_TARGET}"

# Map the PrismML target to LM Studio's backend directory naming convention
case "$TARGET" in
    macos-arm64*) BACKEND_PATTERN="llama.cpp-mac-arm64-*" ;;
    macos-x64*)   BACKEND_PATTERN="llama.cpp-mac-x64-*" ;;
    *)
        echo "Error: unknown macOS target '$TARGET'. Use macos-arm64 or macos-x64."
        exit 1
        ;;
esac

# List matching backends, newest first. Portable "sort -V" because BSD sort has
# no -V flag: zero-pad each numeric version component, then sort descending.
find_backends() {
    find "$BACKENDS_DIR" -maxdepth 1 -type d -name "$BACKEND_PATTERN" 2>/dev/null \
        | awk -F/ '{
            v=$NF; sub(/^.*-/, "", v); n=split(v, a, ".");
            printf "%05d%05d%05d\t%s\n", a[1], a[2], a[3], $0
        }' \
        | sort -r | cut -f2
}

if [ ! -d "$BACKENDS_DIR" ]; then
    echo "Error: '$BACKENDS_DIR' does not exist. Is LM Studio installed and has it run at least once?"
    exit 1
fi

BACKEND_LIST="$(find_backends)"

if [ -z "$BACKEND_LIST" ]; then
    echo "Error: could not find any LM Studio backend matching '$BACKEND_PATTERN' in $BACKENDS_DIR."
    exit 1
fi

# --- quick check mode (no network) -----------------------------------------
# Used by the launchd watcher: if every backend carries a PrismML stamp, there
# is nothing to do and we can exit without downloading anything.
if [ "$CHECK_ONLY" -eq 1 ]; then
    while IFS= read -r backend; do
        [ -n "$backend" ] || continue
        if [ ! -f "$backend/.prism-stamp" ]; then
            echo "Not patched: $backend"
            exit 1
        fi
    done <<EOF
$BACKEND_LIST
EOF
    exit 0
fi

echo "=========================================="
echo " LM Studio PrismML Auto-Patcher (macOS)"
echo "=========================================="
echo "Selected target: $TARGET"

# 1. Fetch the latest PrismML release
echo "[1/4] Querying GitHub for the latest PrismML release..."
RELEASE_API="https://api.github.com/repos/PrismML-Eng/llama.cpp/releases"
ASSET_URL=$(curl -fsSL "$RELEASE_API" \
    | jq -r ".[0].assets[] | select(.name | test(\"-bin-${TARGET}\\\\.tar\\\\.gz$\")) | .browser_download_url")

if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    echo "Error: could not find a '*-bin-${TARGET}.tar.gz' asset in the latest release."
    exit 1
fi

echo "Found release asset: $ASSET_URL"
PRISM_RELEASE="$(basename "$(dirname "$ASSET_URL")")"

# 2. Download and extract
echo "[2/4] Downloading and extracting the archive..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

curl -fL -o "$TEMP_DIR/prism.tar.gz" "$ASSET_URL"
tar -xzf "$TEMP_DIR/prism.tar.gz" -C "$TEMP_DIR" --strip-components=1
chmod +x "$TEMP_DIR/llama-server" 2>/dev/null || true

# The release tag/version, used for display only (llama-server prints to stderr)
echo "PrismML: $("$TEMP_DIR/llama-server" --version 2>&1 | head -n1 || echo unknown)"

# Files the PrismML llama-server subprocess loads by name and that we must
# replace (they are only ever consumed by the subprocess, never by LM Studio's
# in-process llm_engine.node):
#   - llama-server
#   - libllama-server-impl.dylib
#   - libllama-common.0.dylib (repointed to PrismML's versioned build)
OVERWRITE_FILES="llama-server libllama-server-impl.dylib"
REPOINT_SYMLINKS="libllama-common.0.dylib"

# Patch a single backend directory. Returns 0 on success, 1 on failure (and
# rolls that backend back to its pre-patch state).
patch_backend() {
    backend="$1"
    backup="$backend/.prism-backup"
    mkdir -p "$backup"
    chmod -R u+w "$backend" 2>/dev/null || true

    # Snapshot anything we are about to overwrite / repoint
    for f in $OVERWRITE_FILES; do
        if [ -f "$backend/$f" ] && [ ! -e "$backup/$f" ]; then
            cp -p "$backend/$f" "$backup/$f"
        fi
    done
    for l in $REPOINT_SYMLINKS; do
        if [ -L "$backend/$l" ] && [ ! -e "$backup/$l.target" ]; then
            readlink "$backend/$l" > "$backup/$l.target"
        fi
    done

    # Install PrismML's version-suffixed dylibs side by side with LM Studio's
    # unversioned, signed libraries and wire up the versioned/plain symlinks.
    for src in "$TEMP_DIR"/*.dylib; do
        [ -e "$src" ] || continue
        [ -L "$src" ] && continue

        base="$(basename "$src")"
        case "$base" in
            *.[0-9]*.[0-9]*.[0-9]*.dylib)
                cp -f "$src" "$backend/$base"
                stem="${base%%.[0-9]*.[0-9]*.[0-9]*.dylib}"
                ln -sfn "$base" "$backend/${stem}.0.dylib"
                if [ ! -e "$backend/${stem}.dylib" ]; then
                    ln -sfn "$base" "$backend/${stem}.dylib"
                fi
                ;;
        esac
    done

    # The engine-protocol subprocess binaries
    cp -f "$TEMP_DIR/llama-server" "$backend/llama-server"
    cp -f "$TEMP_DIR/libllama-server-impl.dylib" "$backend/libllama-server-impl.dylib"
    chmod +x "$backend/llama-server"

    # Strip quarantine if the archive came from a browser download
    if command -v xattr >/dev/null 2>&1; then
        xattr -dr com.apple.quarantine "$backend" 2>/dev/null || true
    fi

    # Smoke test: make sure the patched server starts and resolves every lib
    if ! "$backend/llama-server" --version >/dev/null 2>&1; then
        echo "    ! smoke test failed, rolling back this backend"
        for f in $OVERWRITE_FILES; do
            [ -e "$backup/$f" ] && cp -p "$backup/$f" "$backend/$f"
        done
        for l in $REPOINT_SYMLINKS; do
            [ -f "$backup/$l.target" ] && ln -sfn "$(cat "$backup/$l.target")" "$backend/$l"
        done
        for src in "$TEMP_DIR"/*.dylib; do
            [ -e "$src" ] || continue
            base="$(basename "$src")"
            case "$base" in
                *.[0-9]*.[0-9]*.[0-9]*.dylib)
                    stem="${base%%.[0-9]*.[0-9]*.[0-9]*.dylib}"
                    rm -f "$backend/$base"
                    rm -f "$backend/${stem}.0.dylib"
                    [ -L "$backend/${stem}.dylib" ] && rm -f "$backend/${stem}.dylib"
                    ;;
            esac
        done
        return 1
    fi

    # Record which PrismML release this backend was patched with. The watcher
    # uses this file to decide whether anything needs doing.
    printf '%s\n' "$PRISM_RELEASE" > "$backend/.prism-stamp"
    return 0
}

# 3. Report what we found
echo "[3/4] Locating LM Studio backends matching $BACKEND_PATTERN..."
echo "Found backends:"
echo "$BACKEND_LIST" | sed 's|.*/|    |'

if [ -f "$INTERNAL_DIR/backend-preferences-v1.json" ]; then
    PREFERRED=$(jq -r '.[] | select(.name | test("^llama.cpp-")) | .version' \
        "$INTERNAL_DIR/backend-preferences-v1.json" 2>/dev/null | head -n1 || true)
    [ -n "$PREFERRED" ] && echo "LM Studio currently prefers version: $PREFERRED"
fi

# 4. Patch every backend
echo "[4/4] Patching backends with $PRISM_RELEASE..."
PATCHED=0
FAILED=0

while IFS= read -r backend; do
    [ -n "$backend" ] || continue
    echo "  -> $backend"
    if patch_backend "$backend"; then
        PATCHED=$((PATCHED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done <<EOF
$BACKEND_LIST
EOF

echo "=========================================="
echo " Patched $PATCHED backend(s), $FAILED failed."
echo " Restart LM Studio to apply the new binaries."
echo " (Originals backed up in .prism-backup/ inside each backend)"
echo "=========================================="

if [ "$PATCHED" -eq 0 ]; then
    exit 1
fi
