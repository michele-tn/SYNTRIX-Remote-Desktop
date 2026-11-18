# SYNTRIX upstream baseline

Verified on 2026-11-17 against https://github.com/rustdesk/rustdesk.

| Reference | Commit |
| --- | --- |
| Latest stable tag, `1.5.3` | `95cca3f661f635b3cc85c04935fe8d96d8f432ef` |
| Published `nightly` tag | `12b5cc7f725ad5510ccfaa8f28f15aece35c0d5a` |
| Observed `origin/master` | `54416dcaa127d209f2cfbdc4b08235bae78ccfe6` |
| `libs/hbb_common` at selected baseline | `fae47e024dd83cef6aaecde0aa7d11731df11649` |

`git fetch --tags --prune` succeeded. The version-sorted numeric tags and GitHub's latest stable release both identify 1.5.3. The tag was committed on 2026-11-09. The published nightly tag was committed on 2026-07-10.

`git merge-base --is-ancestor 1.5.3 nightly` returned 1. The reverse check returned 0. The check against `origin/master` returned 0, but that commit differs from the published nightly. The stable tag is the fallback because the published nightly fails the ancestry requirement.

Branch `feature/syntrix-custom-edition` starts at 1.5.3. `Cargo.toml` declares 1.5.3 and `flutter/pubspec.yaml` declares 1.5.3+71. Recursive submodule initialization succeeded.
