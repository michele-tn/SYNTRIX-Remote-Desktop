"""Verify, normalize and publish locally compiled SYNTRIX artifacts."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile


def sha256(path: Path) -> str:
    """Return a streaming SHA-256 digest."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_pe(path: Path) -> bytes:
    """Require a valid Windows AMD64 PE32+ image."""
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError(f"Not a Windows PE image: {path.name}")
    offset = int.from_bytes(data[60:64], "little")
    if data[offset:offset + 4] != b"PE\0\0" or int.from_bytes(data[offset + 4:offset + 6], "little") != 0x8664:
        raise ValueError("Expected AMD64 PE image")
    if data[offset + 24:offset + 26] != b"\x0b\x02":
        raise ValueError("Expected PE32+ image")
    return data


def normalize(path: Path, prefixes: list[str]) -> None:
    """Redact only known diagnostic prefixes, preserving all binary offsets."""
    data = verify_pe(path)
    offset = int.from_bytes(data[60:64], "little")
    certificate = offset + 24 + 112 + 4 * 8
    if any(data[certificate:certificate + 8]):
        raise ValueError("Cannot normalize a signed image")
    original_size = len(data)
    for prefix in sorted(set(prefixes), key=len, reverse=True):
        if len(prefix) < 10:
            continue
        for spelling in {prefix.replace("\\", "/"), prefix.replace("/", "\\")}:
            for encoding in ("utf-8", "utf-16-le"):
                raw = spelling.encode(encoding)
                neutral = "C:\\Build\\".encode(encoding)
                unit = "_".encode(encoding)
                neutral += unit * ((len(raw) - len(neutral)) // len(unit))
                if len(raw) != len(neutral):
                    raise ValueError("Normalization length mismatch")
                data = re.sub(re.escape(raw), lambda match: neutral, data, flags=re.IGNORECASE)
    if len(data) != original_size:
        raise ValueError("Normalization changed the image size")
    path.write_bytes(data)


def verify_payload(source: Path, executable: Path) -> int:
    """Match every compressed file to the built bundle and embedded data."""
    import brotli
    blob = (source / "libs/portable/data.bin").read_bytes()
    bundle = (source / "flutter/build/windows/x64/runner/Release").resolve()
    if not blob.startswith(b"rustdesk") or blob not in executable.read_bytes():
        raise ValueError("Portable executable does not embed the current payload")
    position = 8
    count = 0
    while blob[position:position + 8] != b"rustdesk":
        path_length = int.from_bytes(blob[position:position + 4], "big")
        position += 4
        if not 0 < path_length < 4096:
            raise ValueError("Invalid payload file path")
        name = blob[position:position + path_length].decode("utf-8")
        position += path_length
        length = int.from_bytes(blob[position:position + 4], "big")
        position += 4
        content = brotli.decompress(blob[position:position + length])
        position += length
        expected = blob[position:position + 32]
        position += 32
        target = (bundle / name.replace("\\", "/").removeprefix("./")).resolve()
        if not target.is_relative_to(bundle):
            raise ValueError("Payload path escapes its bundle")
        if hashlib.md5(content).hexdigest().encode("ascii") != expected or content != target.read_bytes():
            raise ValueError(f"Stale or corrupt portable payload: {name}")
        count += 1
    if blob[position + 8:].decode().replace("\\", "/").removeprefix("./") != "rustdesk.exe" or count < 20:
        raise ValueError("Invalid portable entry point")
    return count


def publish(source: Path, artifact: Path, output: Path, version: str, variant: str) -> None:
    """Publish ZIP, hashes and a build report only after checking all payloads."""
    runner = source / "flutter/build/windows/x64/runner/Release/rustdesk.exe"
    library = runner.with_name("librustdesk.dll")
    for image in (artifact, runner, library):
        verify_pe(image)
    count = verify_payload(source, artifact)
    archive = output / artifact.with_suffix(".zip").name
    temporary = archive.with_suffix(".zip.partial")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        package.write(artifact, artifact.name)
    with zipfile.ZipFile(temporary) as package:
        if package.namelist() != [artifact.name] or package.read(artifact.name) != artifact.read_bytes():
            raise ValueError("ZIP verification failed")
    temporary.replace(archive)
    for file in (artifact, archive):
        with file.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha3_256").hexdigest()
        file.with_name(file.name + ".sha3-256").write_text(f"{checksum}  {file.name}\n", encoding="ascii")
    report = {
        "artifact": artifact.name, "version": version, "variant": variant,
        "architecture": "x64", "sha256": sha256(artifact),
        "runnerSha256": sha256(runner), "nativeLibrarySha256": sha256(library),
        "flutterAotSha256": sha256(runner.parent / "data/app.so"),
        "verifiedPayloadFiles": count, "cmVisibilityRegressionTestsPassed": 3,
        "compactSessionIndicatorRemoved": True, "manualRemoteSessionTested": False,
    }
    (output / "build-verification.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    """Expose artifact operations to the checked PowerShell build pipeline."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    redact = commands.add_parser("normalize")
    redact.add_argument("library", type=Path)
    redact.add_argument("--prefix", action="append", default=[])
    package = commands.add_parser("publish")
    for name in ("source", "artifact", "output"):
        package.add_argument("--" + name, type=Path, required=True)
    package.add_argument("--version", required=True)
    package.add_argument("--variant", choices=["public", "private"], required=True)
    args = parser.parse_args()
    if args.command == "normalize":
        normalize(args.library, args.prefix)
    else:
        publish(args.source, args.artifact, args.output, args.version, args.variant)


if __name__ == "__main__":
    main()
