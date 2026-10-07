# LM Studio PrismML Auto-Patcher (macOS)

A zero-dependency Bash script that downloads the latest [PrismML llama.cpp](https://github.com/PrismML-Eng/llama.cpp)
release and surgically patches your active **LM Studio for macOS** backend so it can natively load
advanced serialization formats such as **PTQ1_0** on Apple Silicon (Metal) and Intel Macs.

This is a macOS port of the original
[Linux gist by JohnRTitor](https://gist.github.com/JohnRTitor/7259ea44e41aeaca228457667f94a9ca).
The Linux version relies on `.so` files, `sort -V`, and symlink conventions that do not exist on
Darwin; the code was rewritten to work with Mach-O `.dylib` libraries, Apple code signing, and
LM Studio's macOS library layout.

## Why a separate macOS port was needed

LM Studio ships a **different library layout on macOS** than on Linux, and PrismML's builds are
structured differently from LM Studio's. The following differences drove the port:

| Concern | Linux (original) | macOS (this port) |
| --- | --- | --- |
| Shared libraries | `.so` | `.dylib` (versioned `libfoo.0.21.0.dylib`) |
| Version sort | `find ... \| sort -V` | `sort -V` does not exist (BSD `sort`); portable zero-padded sort used |
| Backend naming | `llama.cpp-linux-*` | `llama.cpp-mac-arm64-*` / `llama.cpp-mac-x64-*` |
| Targets | `ubuntu-*`, `linux-cuda-*` | `macos-arm64`, `macos-x64` |
| Library resolution | `LD_LIBRARY_PATH` / symlinks | `@rpath` / `@loader_path` (two-level namespace) |
| Code signing | none | ad-hoc / hardened runtime + library validation |

### The important macOS-specific problem: do not clobber LM Studio's libraries

LM Studio's in-process engine is loaded as `llm_engine.node` → `libllm_engine.dylib` and links the
**unversioned** dylibs (`libllama.dylib`, `libmtmd.dylib`, `libggml-cpu.dylib`, …). That engine
references a handful of symbols PrismML's fork does **not** export, for example:

```
_llama_batch_ext_add_embd   _llama_batch_ext_init   _llama_batch_ext_set_pos
_llama_process              _llama_get_causal_attn  _mtmd_helper_init_opt_default
```

Simply overwriting them with the PrismML builds makes `llm_engine.node` fail to load
(`Symbol not found`). On top of that, LM Studio's macOS binaries are hardened-runtime signed with
LM Studio's team ID, so ad-hoc PrismML dylibs dropped into that process would also fail
library validation.

Meanwhile, actual inference runs through the **engine-protocol `llama-server` subprocess**
(`useLlamaCppEngineProtocolRuntime3: true` on modern LM Studio), which loads its own dependency
chain.

### The fix: side-by-side libraries

Instead of replacing everything, the script installs PrismML's libraries **under their versioned
names** (`libllama.0.2.0.dylib`, `libggml.0.21.0.dylib`, …) and only overwrites the files that are
exclusively consumed by the `llama-server` subprocess:

* `llama-server` (the actual inference binary)
* `libllama-server-impl.dylib`
* the `libllama-common.0.dylib` symlink (repointed at PrismML's build)

Everything the in-process engine needs stays untouched and signed. Mach-O's two-level namespace
means `libllm_engine.dylib` keeps binding to LM Studio's original unversioned files, while the
PrismML `llama-server` binds to PrismML's versioned files. Both worlds coexist in the same
directory:

```
lmstudio backend dir/
├── llama-server                 ← PrismML (engine-protocol subprocess)
├── libllama-server-impl.dylib   ← PrismML
├── libllama-common.0.dylib      → libllama-common.0.2.0.dylib   (PrismML)
├── libllama.0.2.0.dylib         + libllama.0.dylib, libllama.dylib
├── libggml.0.21.0.dylib         + aliases
├── libggml-{base,cpu,blas,metal,rpc}.0.21.0.dylib + aliases
├── libmtmd.0.2.0.dylib          + aliases
├── libllama.dylib               ← LM Studio original (in-process engine, signed)
├── libmtmd.dylib                ← LM Studio original
├── libggml-*.dylib              ← LM Studio original
├── libggml_llamacpp.dylib       ← LM Studio original
├── libllm_engine.dylib          ← LM Studio original
└── llm_engine.node              ← LM Studio original
```

No re-signing is required: PrismML's binaries are already ad-hoc/linker-signed and the
`llama-server` subprocess does not enforce library validation. The script also strips the
quarantine attribute, runs a smoke test, and rolls back automatically if the patched server fails
to start.

## Features

* **Standalone** – only `curl`, `jq`, and `tar` are required.
* **Dynamic fetching** – queries the GitHub API for the latest PrismML release.
* **Auto-targeting** – detects the CPU architecture and scans
  `~/.lmstudio/extensions/backends` for the highest-version matching backend.
* **Surgical, side-by-side patching** – never breaks LM Studio's signed in-process engine.
* **Backup + rollback** – originals are saved to `.prism-backup/` inside the backend directory.

## Requirements

* macOS (Apple Silicon or Intel)
* LM Studio installed and launched at least once
* `curl`, `jq`, `tar` (`jq` via `brew install jq` if missing)

## Usage

```bash
chmod +x prism_patcher.sh
./prism_patcher.sh
```

Then restart LM Studio. The script patches the highest-version backend; make sure LM Studio is
using that version (model load settings → **Runtime** dropdown).

### Advanced targets

Pass a PrismML release prefix to override the default (`macos-arm64` on Apple Silicon,
`macos-x64` on Intel):

```bash
# Apple Silicon (default)
./prism_patcher.sh macos-arm64

# Apple Silicon, KleidiAI CPU kernels
./prism_patcher.sh macos-arm64-kleidiai

# Intel
./prism_patcher.sh macos-x64
```

You can also point the script at a different backend root (useful for testing):

```bash
LMSTUDIO_BACKENDS_DIR=/path/to/backends ./prism_patcher.sh
```

## Caveats

* **LM Studio updates the backend automatically.** With `autoUpdateExtensionPacks` /
  `autoDeleteExtensionPacks` enabled, LM Studio downloads a new backend and deletes the old one,
  wiping the patch. Re-run the script after each update, or disable those options in
  **Settings → Developer**.
* Only the engine-protocol `llama-server` path (chat/completion) is patched. Embeddings that run
  through the in-process `llm_engine.node` keep using LM Studio's libraries.
* PrismML's server must remain CLI/API-compatible with the engine protocol LM Studio expects.
  The script aborts and restores the originals if the patched server fails a startup smoke test.

## Credits

* Original Linux gist: [JohnRTitor](https://gist.github.com/JohnRTitor/7259ea44e41aeaca228457667f94a9ca)
* macOS port: [mattwaltbriggs](https://github.com/mattwaltbriggs)
* Upstream project: [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp)

## License

MIT — see [LICENSE](LICENSE).
