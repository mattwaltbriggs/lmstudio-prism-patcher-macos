#!/usr/bin/env bash
set -euo pipefail

for cmd in curl jq tar uname codesign; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' required"; exit 1; }
done

OS="$(uname -s)"; ARCH="$(uname -m)"
[ "$OS" != "Darwin" ] && echo "Error: macOS only" && exit 1
BACKENDS_DIR="${LMSTUDIO_BACKENDS_DIR:-$HOME/.lmstudio/extensions/backends}"
INTERNAL_DIR="${LMSTUDIO_INTERNAL_DIR:-$HOME/.lmstudio/.internal}"
case "$ARCH" in
    arm64) DEFAULT_TARGET="macos-arm64" ;;
    x86_64) DEFAULT_TARGET="macos-x64" ;;
    *) echo "Error: bad arch"; exit 1 ;;
esac

CHECK_ONLY=0; TARGET=""
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        -h|--help) echo "Usage: $0 [target] [--check]"; exit 0 ;;
        -*) echo "Error: unknown $arg"; exit 2 ;;
        *) TARGET="$arg" ;;
    esac
done
TARGET="${TARGET:-$DEFAULT_TARGET}"
case "$TARGET" in
    macos-arm64*) BACKEND_PATTERN="llama.cpp-mac-arm64-*" ;;
    macos-x64*) BACKEND_PATTERN="llama.cpp-mac-x64-*" ;;
    *) echo "Error: bad target"; exit 1 ;;
esac

find_backends() {
    find "$BACKENDS_DIR" -maxdepth 1 -type d -name "$BACKEND_PATTERN" 2>/dev/null | \
    awk -F/ '{v=$NF; sub(/^.*-/, "", v); n=split(v,a,"."); printf "%05d%05d%05d\t%s\n",a[1],a[2],a[3],$0}' | \
    sort -r | cut -f2
}

[ ! -d "$BACKENDS_DIR" ] && echo "Error: no backends dir" && exit 1
BACKEND_LIST="$(find_backends)"; [ -z "$BACKEND_LIST" ] && echo "Error: no backends" && exit 1

if [ "$CHECK_ONLY" -eq 1 ]; then
    while IFS= read -r backend; do
        [ -n "$backend" ] || continue
        [ ! -f "$backend/.prism-stamp" ] && echo "Not patched: $backend" && exit 1
    done <<EOF
$BACKEND_LIST
EOF
    exit 0
fi

echo "=========================================="
echo " LM Studio PrismML Auto-Patcher (macOS)"
echo "=========================================="
echo "Selected target: $TARGET"

echo "[1/4] Querying GitHub for the latest PrismML release..."
RELEASE_API="https://api.github.com/repos/PrismML-Eng/llama.cpp/releases"
ASSET_URL=$(curl -fsSL "$RELEASE_API" | jq -r ".[0].assets[] | select(.name | test(\"-bin-${TARGET}\\\\.tar\\\\.gz$\")) | .browser_download_url")
[ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ] && echo "Error: asset not found" && exit 1
echo "Found release asset: $ASSET_URL"
PRISM_RELEASE="$(basename "$(dirname "$ASSET_URL")")"

echo "[2/4] Downloading and extracting..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
curl -fL -o "$TEMP_DIR/prism.tar.gz" "$ASSET_URL"
tar -xzf "$TEMP_DIR/prism.tar.gz" -C "$TEMP_DIR" --strip-components=1
chmod +x "$TEMP_DIR/llama-server" 2>/dev/null || true
echo "PrismML: $($TEMP_DIR/llama-server --version 2>&1 | head -n1 || echo unknown)"

patch_backend() {
    local backend="$1"
    local backup="$backend/.prism-backup"
    local full_backup="$backend/.prism-full-backup"
    mkdir -p "$backup" "$full_backup"
    chmod -R u+w "$backend" 2>/dev/null || true

    for f in "$backend"/*.dylib "$backend"/*.node "$backend"/llama-server; do
        [ -e "$f" ] && [ ! -L "$f" ] && [ ! -f "$full_backup/$(basename "$f")" ] && cp -p "$f" "$full_backup/" 2>/dev/null
    done 2>/dev/null
    [ -f "$backend/libllama-server-impl.dylib" ] && cp -p "$backend/libllama-server-impl.dylib" "$backup/" 2>/dev/null

    local backend_ver=$(basename "$backend" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' || echo "0.0.0")
    local major=$(echo "$backend_ver" | cut -d. -f1)
    local minor=$(echo "$backend_ver" | cut -d. -f2)

    if [ "$major" -ge 2 ] && [ "$minor" -ge 60 ]; then
        echo "    Using full replacement strategy for v$backend_ver"
        for f in "$backend"/*.node; do cp "$f" "/tmp/$(basename "$f").bak.$$" 2>/dev/null || true; done
        for src in "$TEMP_DIR"/*; do
            [ -e "$src" ] || continue
            base="$(basename "$src")"
            [ "$base" = "llm_engine.node" ] && continue
            [ "$base" = "liblmstudio_bindings.node" ] && continue
            if [ -L "$src" ]; then
                cp -a "$src" "$backend/" 2>/dev/null
            elif [ -f "$src" ]; then
                cp -f "$src" "$backend/$base" && chmod +x "$backend/$base" 2>/dev/null
            fi
        done
        for f in /tmp/*.bak.$$; do [ -e "$f" ] && cp "$f" "$backend/$(basename "${f%.bak.$$}")" 2>/dev/null; done
        rm -f /tmp/*.bak.$$ 2>/dev/null
        for f in "$backend"/*.[0-9]*.[0-9]*.[0-9]*.dylib; do
            [ -e "$f" ] || continue
            base=$(basename "$f")
            stem="${base%%.[0-9]*.[0-9]*.[0-9]*.dylib}"
            [ "$stem" != "$base" ] && ln -sfn "$base" "$backend/${stem}.0.dylib" && ln -sfn "$base" "$backend/${stem}.dylib"
        done
        ln -sfn libllama-common.0.2.0.dylib "$backend/libllama-common.0.dylib" 2>/dev/null
        ln -sfn libllama-common.0.2.0.dylib "$backend/libllama-common.dylib" 2>/dev/null
        ln -sfn libllama.0.2.0.dylib "$backend/libllama.0.dylib" 2>/dev/null
        ln -sfn libllama.0.2.0.dylib "$backend/libllama.dylib" 2>/dev/null
        ln -sfn libmtmd.0.2.0.dylib "$backend/libmtmd.0.dylib" 2>/dev/null
        ln -sfn libmtmd.0.2.0.dylib "$backend/libmtmd.dylib" 2>/dev/null
        find "$backend" -maxdepth 1 -type f \( -name "*.dylib" -o -name "llama-server" -o -name "ggml-*" -o -name "libllama*" -o -name "libmtmd*" \) | xargs -I{} codesign --force -s - {} 2>/dev/null || true
    else
        for src in "$TEMP_DIR"/*.dylib; do
            [ -e "$src" ] || continue
            [ -L "$src" ] && continue
            base="$(basename "$src")"
            case "$base" in
                *.[0-9]*.[0-9]*.[0-9]*.dylib)
                    cp -f "$src" "$backend/$base"
                    stem="${base%%.[0-9]*.[0-9]*.[0-9]*.dylib}"
                    ln -sfn "$base" "$backend/${stem}.0.dylib"
                    [ ! -e "$backend/${stem}.dylib" ] && ln -sfn "$base" "$backend/${stem}.dylib"
                    ;;
            esac
        done
        cp -f "$TEMP_DIR/llama-server" "$backend/llama-server"
        cp -f "$TEMP_DIR/libllama-server-impl.dylib" "$backend/libllama-server-impl.dylib"
        chmod +x "$backend/llama-server"
        ln -sfn libllama-common.0.2.0.dylib "$backend/libllama-common.0.dylib" 2>/dev/null
        codesign --force -s - "$backend/llama-server" "$backend/libllama-server-impl.dylib" 2>/dev/null || true
    fi

    if command -v xattr >/dev/null 2>&1; then
        xattr -dr com.apple.quarantine "$backend" 2>/dev/null || true
    fi

    if ! "$backend/llama-server" --version >/dev/null 2>&1; then
        echo "    ! smoke test failed, rolling back"
        [ -d "$full_backup" ] && [ "$(ls -A "$full_backup" 2>/dev/null)" ] && cp -f "$full_backup"/* "$backend/" 2>/dev/null
        [ -f "$backup/libllama-server-impl.dylib" ] && cp -p "$backup/libllama-server-impl.dylib" "$backend/" 2>/dev/null
        return 1
    fi

    printf '%s\n' "$PRISM_RELEASE" > "$backend/.prism-stamp"
    return 0
}

echo "[3/4] Locating LM Studio backends matching $BACKEND_PATTERN..."
echo "Found backends:"
echo "$BACKEND_LIST" | sed 's|.*/|    |'
[ -f "$INTERNAL_DIR/backend-preferences-v1.json" ] && PREFERRED=$(jq -r '.[] | select(.name | test("^llama.cpp-")) | .version' "$INTERNAL_DIR/backend-preferences-v1.json" 2>/dev/null | head -n1) && [ -n "$PREFERRED" ] && echo "LM Studio currently prefers version: $PREFERRED"

echo "[4/4] Patching backends with $PRISM_RELEASE..."
PATCHED=0; FAILED=0
while IFS= read -r backend; do
    [ -n "$backend" ] || continue
    echo "  -> $backend"
    if patch_backend "$backend"; then PATCHED=$((PATCHED + 1)); else FAILED=$((FAILED + 1)); fi
done <<EOF
$BACKEND_LIST
EOF

echo "=========================================="
echo " Patched $PATCHED backend(s), $FAILED failed."
echo " Restart LM Studio to apply the new binaries."
echo "=========================================="
[ "$PATCHED" -eq 0 ] && exit 1
