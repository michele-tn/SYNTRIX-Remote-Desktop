# Public source verification

- Baseline: RustDesk 1.5.3.
- The binary-capable patch was applied to the upstream tree in an isolated Git index. The resulting tree matched source-manifest.json.
- The public source retains RustDesk attribution. Local build notes and private branding are excluded.
- The public Windows x64 runner was built from the patched tree and returned
  `1.5.3` for `--version`. The build reused an existing pinned vcpkg cache.
- Packaging normalized Windows profile paths in Opus and FFmpeg diagnostic
  strings in the unsigned native DLL. The release EXE metadata credits
  RustDesk.
- All 91 embedded files were decompressed, matched against the built
  bundle, and scanned for the known private identifiers and paths.
- Both SHA3-256 checksums passed. The ZIP contains the standalone EXE
  byte for byte.
- The portable launcher extracted the runner, whose hash matched the build,
  and returned `1.5.3` for `--version`.
