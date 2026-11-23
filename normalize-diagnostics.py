"""Remove Windows profile paths from native diagnostics in an unsigned build."""

import argparse
import re
from pathlib import Path


DEPENDENCY_SOURCE_PATH = re.compile(
    rb"[a-z]:[\\/]Users[\\/][^\\/\x00\r\n]+"
    rb"(?:[\\/][^\\/\x00\r\n]+)*?"
    rb"(?=[\\/]vcpkg[\\/]buildtrees[\\/](?:opus|ffmpeg)[\\/]src[\\/])",
    re.IGNORECASE,
)


def normalize(library: Path) -> int:
    original = library.read_bytes()
    if original[:2] != b"MZ":
        raise ValueError("Expected a Windows PE library.")
    pe_offset = int.from_bytes(original[60:64], "little")
    if original[pe_offset:pe_offset + 4] != b"PE\0\0":
        raise ValueError("Invalid Windows PE library.")
    optional_header = pe_offset + 24
    if original[optional_header:optional_header + 2] != b"\x0b\x02":
        raise ValueError("Expected a Windows PE32+ library.")
    certificate = optional_header + 112 + 4 * 8
    if any(original[certificate:certificate + 8]):
        raise ValueError("Diagnostic paths must be normalized before signing.")

    # Preserve string lengths and file offsets in the linked image.
    def neutral_path(match: re.Match[bytes]) -> bytes:
        return b"C:\\Build\\" + b"_" * (len(match[0]) - len(b"C:\\Build\\"))

    updated, count = DEPENDENCY_SOURCE_PATH.subn(neutral_path, original)
    if count:
        if len(updated) != len(original):
            raise ValueError("Diagnostic path normalization changed the file size.")
        library.write_bytes(updated)
    return count


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    options = parser.parse_args()
    count = normalize(options.library)
    print(f"Normalized {count} native diagnostic paths in {options.library.name}.")
