# SYNTRIX Windows branding

SYNTRIX Remote is a distribution based on RustDesk. The Windows Flutter runner
and the portable launcher use SYNTRIX Remote as their product name. The Windows
About page identifies the upstream project and retains its copyright and license
notice.

The Windows runner still uses `rustdesk.exe` as its internal filename. In the
upstream build and runtime, that filename appears in the Flutter release
bundle and the portable packer. The portable launcher is staged as
`SYNTRIX-1.5.3-x64-portable.exe`.

The Windows executable resources and About page credit RustDesk as the
upstream project. The new icon
uses two opposing shapes to represent a remote connection. Generate the SVG
and all 256 square Windows icon frames, from 1×1 to 256×256, with
`python scripts/generate_syntrix_icons.py` in an environment with Pillow.

Windows uses a dedicated native window class for SYNTRIX window discovery
and a separate portable extraction directory for the standard payload.
This protects against activating an already-open upstream window and sharing
the upstream binary cache. Configuration, service, IPC and update isolation
remain separate concerns. The custom theme is also pending.
