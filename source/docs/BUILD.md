# Windows x64 build

Use an x64 Windows host with Visual Studio C++ Build Tools and the Windows SDK.
The build scripts expect an isolated toolchain root containing `rustup/`,
`cargo/`, `flutter/` and `vcpkg/`. The selected Rust toolchain is
`1.75.0-x86_64-pc-windows-msvc`; Flutter 3.24.5 supplies Dart 3.5.4.
Use the vcpkg commit recorded in the Windows workflow and fetch its full
history so the pinned registry can resolve historical port trees.

Use a short toolchain path for the Cargo cache. On this build host `X:/`
maps to the isolated toolchain directory. The longer physical path exceeded
the Windows path limit during the HarfBuzz dependency checkout.

With Visual Studio 2026, Flutter 3.24.5 falls back to the Visual Studio 2019
CMake generator. The isolated SDK on this host maps major version 18 to
`Visual Studio 18 2026` in
`packages/flutter_tools/lib/src/windows/visual_studio.dart`. Rebuilding the
Flutter tool snapshot applied the mapping. The Windows CMake cache confirmed
the new generator.

The repository's physical path produced a 264-character include path for
`flutter_gpu_texture_renderer`. For the successful incremental build, MSBuild
received process-scoped `CL` include options for both the plugin's `windows`
directory and its `windows/include` directory using the short `X:/pub-cache`
path. The native source and the pinned plugin revision were retained.

Prepare the Flutter SDK with the Windows x64 engine and dropdown-menu patch
from the pinned upstream workflow. Resolve the Flutter dependencies with
`flutter pub get` from the `flutter` directory. The release build expects
the following files from the bridge generation step.

- `src/bridge_generated.rs`
- `src/bridge_generated.io.rs`
- `flutter/lib/generated_bridge.dart`
- `flutter/lib/generated_bridge.freezed.dart`

The local bridge generation used `cargo-expand` 1.0.95 and
`flutter_rust_bridge_codegen` 1.80.1. The latter needed `RUST_LOG=info` and an
explicit `--llvm-path` pointing to a directory with `bin/libclang.dll`.
Set Cargo, Rustup and Flutter to the isolated toolchain before running the
generator from the repository root.

```powershell
flutter_rust_bridge_codegen --skip-add-mod-to-lib --llvm-path X:/llvm-ffigen `
    --rust-input ./src/flutter_ffi.rs `
    --dart-output ./flutter/lib/generated_bridge.dart `
    --c-output ./flutter/macos/Runner/bridge_generated.h

./scripts/build-windows.ps1 -ToolchainRoot X:/
./scripts/package-windows.ps1 -ToolchainRoot X:/
```

The build script installs the x64 static vcpkg dependencies and invokes the
upstream release recipe. Run it after any existing vcpkg installation has
finished so the two invocations do not contend for the same installation
lock. The script checks the executable architecture, version and SHA-256.

The packaging script uses the upstream portable packer and its Python
`brotli` dependency. On success, it stages `SYNTRIX-1.5.3-x64-portable.exe` under
`dist/windows-x64/portable/` and writes its size, architecture and SHA-256 to
`dist/windows-x64/reports/portable.json`.
