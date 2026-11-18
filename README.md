# SYNTRIX Remote for Windows x64

Based on RustDesk. This release is based on
RustDesk 1.5.3 at commit `95cca3f661f635b3cc85c04935fe8d96d8f432ef`.

| Path | Purpose |
| --- | --- |
| [source/](source/) | Complete patched source tree with the pinned hbb_common sources |
| [SYNTRIX-vs-RustDesk-1.5.3.patch](SYNTRIX-vs-RustDesk-1.5.3.patch) | SYNTRIX changes against the pinned upstream release, including binary icons |
| [release/](release/) | Windows x64 portable EXE, ZIP, and SHA3-256 checksum files |
| [build.ps1](build.ps1) | Dependency setup, patch application, compilation, and packaging |
| [PROMPT-REBUILD.md](PROMPT-REBUILD.md) | Codex instructions for exact source reconstruction |
| [PROMPT-UPDATE.md](PROMPT-UPDATE.md) | Codex instructions for integrating later upstream changes |
| [LICENCE](LICENCE) | Original RustDesk license |


## Build from the pinned baseline

Run this command in a dedicated PowerShell 7 process on Windows x64:

    pwsh -NoProfile -File ./build.ps1

The script provisions a separate build cache, checks out upstream 1.5.3,
initializes the pinned submodule, and applies the SYNTRIX patch. It installs
missing prerequisites, generates the Flutter/Rust bridge, compiles the
release, and writes the EXE, ZIP, and checksums under release/. The included
source/ tree is the complete reference snapshot. Build-time generated files
are recreated from their inputs.

Before packaging, the build normalizes absolute Windows profile paths in
Opus and FFmpeg diagnostics in the unsigned native library.

PowerShell 7, internet access, curl.exe, and tar.exe are host requirements.
The script uses WinGet for missing Git or Python. Visual Studio Build Tools
installation may require elevation or an operating-system restart. Flutter
requires permission to create plugin symbolic links. If local Windows policy
denies these links, use an authorized elevated session or Developer Mode.

The default cache is %LOCALAPPDATA%\SyntrixPublicBuild. To prepare and verify the
patched checkout without installing compilers:

    pwsh -NoProfile -File ./build.ps1 -CacheRoot 'C:/SyntrixBuild' -SourceOnly

The initial vcpkg build can take several hours. The SDK and custom engine
archives are verified with pinned SHA-256 values. The engine download URL is
an upstream rolling URL. If its contents change, the script stops on the
integrity check and requires the pinned archive in the cache.

If the pinned vcpkg dependencies for `x64-windows-static` were already
installed in the selected cache, pass `-UseInstalledNativeDependencies`
to reuse them without running dependency installation again. The normal
command installs dependencies when setting up a fresh cache.

## Verify the release

    python ./package-release.py ./release/SYNTRIX-1.5.3-x64-portable.exe --verify

This checks both SHA3-256 files and compares the ZIP payload with the
standalone EXE. Rebuilds can differ byte for byte because the packer writes
a timestamp.

## Update the Windows installation

    pwsh -NoProfile -File ./install-release.ps1

The script verifies the release and opens the installer. Check the target
directory in the installer and approve the Windows elevation request. The
Home page can display an installation update even if the portable EXE is
already at the latest upstream version. That card compares the running
build date with the build date recorded for the local installation.
After installation, check the new copy in Settings → About and verify that
the Home page no longer shows the local installation update.

## Windows coexistence

The Windows GUI window class and portable binary cache are separate from
upstream RustDesk. The application retains upstream configuration and service
identifiers. Keep the upstream license and notices together with the source.

[RustDesk source](https://github.com/rustdesk/rustdesk) ·
[Upstream 1.5.3 release](https://github.com/rustdesk/rustdesk/releases/tag/1.5.3)
