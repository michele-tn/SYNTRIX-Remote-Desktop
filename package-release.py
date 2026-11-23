"""Stage a Windows executable, ZIP archive, and SHA3-256 checksums."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def verify(executable: Path) -> None:
    """Check both published checksums and the archive payload."""
    archive_path = executable.with_suffix(".zip")
    digests = {}
    for artifact in (executable, archive_path):
        with artifact.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha3_256").hexdigest()
        checksum = artifact.with_name(artifact.name + ".sha3-256")
        if checksum.read_text(encoding="ascii").strip() != f"{digest}  {artifact.name}":
            raise ValueError(f"SHA3-256 mismatch: {artifact}")
        digests[artifact] = digest
    with ZipFile(archive_path) as archive:
        if archive.namelist() != [executable.name]:
            raise ValueError("Unexpected ZIP contents.")
        with archive.open(executable.name) as entry:
            if hashlib.file_digest(entry, "sha3_256").hexdigest() != digests[executable]:
                raise ValueError("ZIP payload does not match the executable.")


def package(executable: Path, output: Path) -> None:
    """Verify the archive before staging the release files."""
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".syntrix-", dir=output) as directory:
        staging = Path(directory)
        staged_exe = staging / executable.name
        shutil.copyfile(executable, staged_exe)
        staged_zip = staged_exe.with_suffix(".zip")
        with ZipFile(staged_zip, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
            archive.write(staged_exe, staged_exe.name)

        with staged_exe.open("rb") as stream:
            exe_digest = hashlib.file_digest(stream, "sha3_256").hexdigest()
        with ZipFile(staged_zip) as archive:
            if archive.namelist() != [staged_exe.name]:
                raise ValueError("Unexpected ZIP contents.")
            with archive.open(staged_exe.name) as entry:
                if hashlib.file_digest(entry, "sha3_256").hexdigest() != exe_digest:
                    raise ValueError("ZIP payload does not match the executable.")

        for artifact in (staged_exe, staged_zip):
            with artifact.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha3_256").hexdigest()
            checksum = artifact.with_name(artifact.name + ".sha3-256")
            checksum.write_text(f"{digest}  {artifact.name}\n", encoding="ascii")
            artifact.replace(output / artifact.name)
            checksum.replace(output / checksum.name)
            print(f"{digest}  {artifact.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    parser.add_argument("--verify", action="store_true")
    arguments = parser.parse_args()
    if arguments.verify:
        verify(arguments.executable)
        print(f"Verified EXE, ZIP, and SHA3-256 checksums: {arguments.executable.name}")
    elif arguments.output is None:
        parser.error("output is required when packaging")
    else:
        package(arguments.executable, arguments.output)
