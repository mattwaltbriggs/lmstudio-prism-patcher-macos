#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " LM Studio PrismML Auto-Patcher (macOS)"
echo "=========================================="

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

# Default PrismML target for the host architecture
case "$ARCH" in
    arm64)   DEFAULT_TARGET="macos-arm64" ;;
    x86_64)  DEFAULT_TARGET="macos-x64" ;;
    *)
        echo "Error: unsupported CPU architecture '$ARCH'."
        exit 1
        ;;
esac

TARGET="${1:-$DEFAULT_TARGET}"
echo "Selected target: $TARGET"

# Map the PrismML target to LM Studio's backend directory naming convention
case "$TARGET" in
    macos-arm64*) BACKEND_PATTERN="llama.cpp-mac-arm64-*" ;;
    macos-x64*)   BACKEND_PATTERN="llama.cpp-mac-x64-*" ;;
    *)
        echo "Error: unknown macOS target '$TARGET'. Use macos-arm64 or macos-x64."
        exit 1
        ;;
esac

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

# 2. Download and extract
echo "[2/4] Downloading and extracting the archive..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

curl -fL -o "$TEMP_DIR/prism.tar.gz" "$ASSET_URL"
tar -xzf "$TEMP_DIR/prism.tar.gz" -C "$TEMP_DIR" --strip-components=1
chmod +x "$TEMP_DIR/llama-server" 2>/dev/null || true

# The release tag/version, used for display only
echo "PrismML: $("$TEMP_DIR/llama-server" --version 2>&1 | head -n1 || echo unknown)"

# 3. Locate the highest-version LM Studio backend for this architecture
echo "[3/4] Locating the highest version LM Studio backend matching $BACKEND_PATTERN..."

if [ ! -d "$BACKENDS_DIR" ]; then
    echo "Error: '$BACKENDS_DIR' does not exist. Is LM Studio installed and has it run at least once?"
    exit 1
fi

# Portable "sort -V": zero-pad each numeric component, then sort.
# macOS/BSD sort has no -V flag.
LM_BACKEND_DIR=$(find "$BACKENDS_DIR" -maxdepth 1 -type d -name "$BACKEND_PATTERN" 2>/dev/null \
    | awk -F/ '{
        v=$NF; sub(/^.*-/, "", v); n=split(v, a, ".");
        printf "%05d%05d%05d\t%s\n", a[1], a[2], a[3], $0
    }' \
    | sort -r | head -n1 | cut -f2)

if [ -z "$LM_BACKEND_DIR" ] || [ ! -d "$LM_BACKEND_DIR" ]; then
    echo "Error: could not find an LM Studio backend matching '$BACKEND_PATTERN' in $BACKENDS_DIR."
    exit 1
fi

echo "Targeting backend: $LM_BACKEND_DIR"

# 4. Patch the backend
echo "[4/4] Patching the backend..."

BACKUP_DIR="$LM_BACKEND_DIR/.prism-backup"
mkdir -p "$BACKUP_DIR"

# Make the directory writable without breaking symlinks
chmod -R u+w "$LM_BACKEND_DIR" 2>/dev/null || true

# Back up the two LM Studio files we intentionally overwrite (once)
for f in llama-server libllama-server-impl.dylib; do
    if [ -f "$LM_BACKEND_DIR/$f" ] && [ ! -e "$BACKUP_DIR/$f" ]; then
        cp -p "$LM_BACKEND_DIR/$f" "$BACKUP_DIR/$f"
    fi
done

# Copy PrismML's version-suffixed dylibs (e.g. libllama.0.2.0.dylib) and wire up
# the versioned/plain symlinks. We NEVER clobber LM Studio's unversioned
# libraries: LM Studio's in-process engine (llm_engine.node -> libllm_engine.dylib)
# is built against those exact builds and needs them (it references symbols that
# PrismML's fork does not export). Keeping both sets side by side lets the
# engine-protocol llama-server subprocess run PrismML while the rest of LM Studio
# keeps its signed, symbol-compatible libraries.
for src in "$TEMP_DIR"/*.dylib; do
    [ -e "$src" ] || continue
    [ -L "$src" ] && continue

    base="$(basename "$src")"
    case "$base" in
        *.[0-9]*.[0-9]*.[0-9]*.dylib)
            cp -f "$src" "$LM_BACKEND_DIR/$base"
            stem="${base%%.[0-9]*.[0-9]*.[0-9]*.dylib}"
            ln -sfn "$base" "$LM_BACKEND_DIR/${stem}.0.dylib"
            if [ ! -e "$LM_BACKEND_DIR/${stem}.dylib" ]; then
                ln -sfn "$base" "$LM_BACKEND_DIR/${stem}.dylib"
            fi
            ;;
    esac
done

# PrismML's llama-server executable (ad-hoc/linker-signed) and its server impl.
cp -f "$TEMP_DIR/llama-server" "$LM_BACKEND_DIR/llama-server"
cp -f "$TEMP_DIR/libllama-server-impl.dylib" "$LM_BACKEND_DIR/libllama-server-impl.dylib"
chmod +x "$LM_BACKEND_DIR/llama-server"

# The prism llama-server links @rpath/libllama-common.0.dylib; point that at the
# PrismML build (the loop above already repointed it, this is belt-and-braces).
prism_common="$(ls "$TEMP_DIR"/libllama-common.*.*.*.dylib 2>/dev/null | head -n1 || true)"
if [ -n "$prism_common" ]; then
    ln -sfn "$(basename "$prism_common")" "$LM_BACKEND_DIR/libllama-common.0.dylib"
fi

# Remove the quarantine attribute if the archive came from a browser download
if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$LM_BACKEND_DIR" 2>/dev/null || true
fi

# Sanity check: make sure the freshly copied server actually starts and resolves
# all of its PrismML libraries.
if ! "$LM_BACKEND_DIR/llama-server" --version >/dev/null 2>&1; then
    echo "Warning: the patched llama-server failed a smoke test. Restoring LM Studio's original binaries."
    for f in llama-server libllama-server-impl.dylib; do
        [ -e "$BACKUP_DIR/$f" ] && cp -p "$BACKUP_DIR/$f" "$LM_BACKEND_DIR/$f"
    done
    if [ -n "$prism_common" ]; then
        rm -f "$LM_BACKEND_DIR/$(basename "$prism_common")"
    fi
    echo "Error: patch aborted. Your backend was left as it was."
    exit 1
fi

echo "=========================================="
echo " Patching complete!"
echo " Restart LM Studio to apply the new binaries."
echo " (Original files backed up in: $BACKUP_DIR)"
echo "=========================================="
