# Native side-car binaries

The bundled inference engine (`lib/core/ai/llama_server_backend.dart`)
spawns the upstream `llama-server` binary as a child process and talks
to it over loopback HTTP. The build matrix below describes how to
produce each platform's binary and where the build system expects to
find it.

> **Important.** The Dart-side architecture works without these
> binaries — `LlamaServerBackend.isAvailable` returns `false`, the
> "Built-in engine" path in onboarding is hidden, and the app falls
> back to "Connect to existing Ollama / LM Studio" exactly as before.
> The side-car only needs to be present on builds that ship the
> built-in engine.

## Layout

```
native/
├── README.md           ← you are here
├── linux/              ← drop llama-server (and optional libllama.so)
├── windows/            ← drop llama-server.exe (and optional llama.dll)
└── macos/              ← drop llama-server (and optional libllama.dylib),
                          universal arm64+x86_64
```

The CMake / Xcode integration in `linux/CMakeLists.txt`,
`windows/CMakeLists.txt` and `macos/Runner/Configs/copy_bundled_engine.sh`
copies whatever files it finds in these directories into the bundle's
`lib/` (Linux), next to the .exe (Windows), or into `Frameworks/`
(macOS).

The `libllama.{so,dll,dylib}` shared library is **optional** — it is
only used by the future FFI path (`lib/core/ai/llama_cpp_bindings.dart`),
which is currently disabled. Production builds need only the
`llama-server` binary.

## Building llama.cpp's `llama-server`

Upstream: https://github.com/ggerganov/llama.cpp

The binary is small to build (~5 minutes on a modern laptop) and ~5 MB
when statically linked. We pin upstream tag `b4350` (or any later
release that still ships `llama-server` and the OpenAI-compatible
HTTP routes — the API has been stable for a year+).

### Linux (x86_64 and arm64)

```bash
git clone --depth 1 --branch b4350 https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -DLLAMA_NATIVE=OFF -DLLAMA_BUILD_SERVER=ON \
              -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build build --config Release --target llama-server -j$(nproc)
cp build/bin/llama-server /path/to/hamma/native/linux/
```

For a portable build (single binary that runs on any glibc ≥ 2.31),
add `-DCMAKE_C_FLAGS=-static-libgcc -DCMAKE_CXX_FLAGS=-static-libstdc++`.

### macOS (universal — arm64 + x86_64)

```bash
git clone --depth 1 --branch b4350 https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -DLLAMA_NATIVE=OFF -DLLAMA_BUILD_SERVER=ON \
              -DGGML_METAL=ON \
              -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
              -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
cmake --build build --config Release --target llama-server -j$(sysctl -n hw.ncpu)
cp build/bin/llama-server /path/to/hamma/native/macos/
# Re-sign for distribution (Hamma's notarisation runs on the bundle).
codesign --force --sign - /path/to/hamma/native/macos/llama-server
```

### Windows (x86_64)

Run from a "x64 Native Tools Command Prompt for VS 2022":

```cmd
git clone --depth 1 --branch b4350 https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -G "Visual Studio 17 2022" -A x64 ^
              -DLLAMA_NATIVE=OFF -DLLAMA_BUILD_SERVER=ON
cmake --build build --config Release --target llama-server
copy build\bin\Release\llama-server.exe \path\to\hamma\native\windows\
```

## Verifying

After dropping the binary in place, the launcher-injection unit tests
pass without it:

```bash
flutter test test/bundled_engine_test.dart test/llama_server_backend_test.dart
```

To exercise the real binary end-to-end, run the integration test
with `LLAMA_SERVER_BIN` and `LLAMA_SERVER_MODEL` set to absolute
paths (it is otherwise skipped):

```bash
LLAMA_SERVER_BIN=/path/to/native/linux/llama-server \
LLAMA_SERVER_MODEL=/path/to/some-tiny.gguf \
  flutter test test/llama_server_backend_integration_test.dart
```

The bundled model catalog (`lib/core/ai/bundled_model_catalog.dart`)
lists four sane defaults; the smallest is Gemma 3 1B Q4 at ~750 MB.

## Why a subprocess side-car instead of FFI?

Three reasons:

1. **Stable ABI.** llama.cpp's HTTP API has been stable for a year+;
   its C struct ABI (`llama_batch`, `llama_*_params`) is not — it
   moves with most upstream releases. Wrapping the HTTP API instead
   means a libllama upgrade doesn't break Hamma.
2. **Process isolation.** A model crash (CUDA OOM, mmap fault, native
   assert) takes down only the subprocess, not the host app.
3. **Per-OS toolchain divergence.** llama.cpp's CMake is sensitive to
   compiler version, BLAS choice, GPU SDK presence. Keeping the build
   out-of-tree lets us pin a specific upstream tag in CI without
   polluting Flutter's build graph.

CI builds the side-car binaries once per release tag and uploads
them to the GitHub Releases page; the Flutter build script downloads
them into `native/<os>/` before invoking `flutter build`.

The FFI scaffolding in `lib/core/ai/llama_cpp_bindings.dart` and
`LlamaCppBackend` (in `bundled_engine.dart`) remains as a future
escape hatch for environments where spawning a subprocess isn't
viable (locked-down sandboxes, future iOS support). It is currently
disabled (`isAvailable` returns `false`) and not surfaced to users.
