# Codex prompt — rebuild SYNTRIX Remote

Rebuild the Windows x64 SYNTRIX Remote release from this repository in English.
Use the exact RustDesk 1.5.3 commit documented in README.md. Verify the source
baseline and submodules, apply the binary patch in an isolated checkout, and
compare the result with the included source snapshot. Retain the upstream
license and attribution.

Preserve the Windows idle Connection Manager toggle in Security → Password.
The checkbox is on by default, the choice persists, and active sessions and
pending local approvals remain visible and manageable. Keep the session
count in the tray and preserve authentication, alerts, permissions, and
approval paths. Retain the distinct Windows window class and portable
extraction directory. Keep the 256 square icon frames, SVG, product name,
and attribution to RustDesk.

Run build.ps1, verify the inner runner version, PE architecture, icon
resources, About page, and the two checkbox states. Check the EXE and ZIP
SHA3-256 files and verify the archive round trip. Record what was actually
tested.

Deliver the complete source snapshot and Git manifest, binary-capable patch,
license, English documentation, both prompts, and the versioned portable EXE
and ZIP with individual SHA3-256 files. The Windows x64 bootstrap must apply
the patch automatically, provision dependencies, regenerate the bridge,
build and package the release. Keep SourceOnly and PrepareOnly available.
Verify the published files with package-release.py --verify and verify that
install-release.ps1 validates the release before opening the installer.
On an authorized test host, check the installed version and Home page after
updating a prior installation. The Home card uses the local installation
build date. Exclude old releases, temporary files, build caches and secrets.
Use source-manifest.json as the exact reconstruction reference and report
any binary differences due to build timestamps separately.
