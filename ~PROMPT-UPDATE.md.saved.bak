# Codex prompt — update SYNTRIX Remote from RustDesk

Verify the latest stable release in the official RustDesk repository and
fetch its exact tag in a separate checkout. Compare the previous and new
upstream trees, release notes, toolchain pins, and submodule commits.
Reapply the SYNTRIX changes on top of the new upstream tag. Resolve conflicts
in favor of preserving upstream fixes and the SYNTRIX behavior specified in
PROMPT-REBUILD.md. Preserve security updates and authorization behavior.

Update the archived source tree, binary-capable patch, build toolchain pins,
release metadata, versioned filename, README, and English prompts. Run the
build, create the EXE and ZIP, write SHA3-256 checksums, and verify the new
patch against the upstream tag. Check Windows GUI coexistence, branding,
icons and the Connection Manager preference. Record test limitations.
Exclude caches and personal configuration.

Update the version and baseline consistently in build.ps1, install-release.ps1,
the source manifest, documentation, prompts and release filenames. Retain
automatic patch application, SourceOnly and PrepareOnly, and SHA3-256
verification after packaging. Verify both published checksums and that the
ZIP contains exactly the standalone EXE. Exercise install-release.ps1 on an
authorized Windows test host, confirm the destination and elevation in the
installer, and check the installed version and Home card after updating an
older copy. Keep installation separate from compilation. Remove superseded
distributables and reproducible build intermediates from the publication tree.
