"""Resolve upstream releases, apply SYNTRIX patches, and build Windows x64 packages."""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parent
API = "https://api.github.com/repos/rustdesk/rustdesk"
SHA = re.compile(r"^[0-9a-f]{40}$")
BRIDGE_FILES = {
    "src/bridge_generated.rs", "src/bridge_generated.io.rs",
    "flutter/lib/generated_bridge.dart", "flutter/lib/generated_bridge.freezed.dart",
    "flutter/macos/Runner/bridge_generated.h", "flutter/ios/Runner/bridge_generated.h",
}


class UpdateError(RuntimeError):
    """An update stopped before publishing an unverified build."""


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward GitHub credentials to an artifact storage host."""

    def redirect_request(self, request, response, code, message, headers, new_url):
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected and urllib.parse.urlparse(request.full_url).netloc != urllib.parse.urlparse(new_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


def github_token() -> str:
    """Read the optional API token without placing it in commands or reports."""
    return os.environ.get("GITHUB_TOKEN", os.environ.get("GH_TOKEN", ""))


def default_cache() -> Path:
    """Keep checkouts and compilers outside the project being maintained."""
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".cache"))) / "SyntrixUpdater"


def digest(path: Path) -> str:
    """Hash a file without loading archives into memory."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(path: Path) -> dict:
    """Read a local manifest, including PowerShell UTF-8 BOM output."""
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, data: dict) -> None:
    """Atomically publish a report after its operation completed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def api_sync(endpoint: str) -> dict | list:
    """Request public upstream metadata over HTTPS."""
    headers = {"User-Agent": "SYNTRIX-Updater", "Accept": "application/vnd.github+json"}
    if github_token():
        headers["Authorization"] = "Bearer " + github_token()
    try:
        with urllib.request.urlopen(urllib.request.Request(API + "/" + endpoint, headers=headers), timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise UpdateError(f"GitHub API HTTP {error.code}: {endpoint}. GITHUB_TOKEN can increase the API limit.") from error


async def api(endpoint: str) -> dict | list:
    """Keep metadata requests outside the orchestration event loop."""
    return await asyncio.to_thread(api_sync, endpoint)


def release_date(release: dict) -> str:
    """Rolling nightly dates come from Windows x64 assets, not Android uploads."""
    if release["tag_name"].lower() == "nightly":
        dates = [a["updated_at"] for a in release.get("assets", [])
                 if re.search(r"x86_64(?:-portable)?\.exe$", a["name"], re.I)]
        return max(dates, default="")
    return release.get("published_at") or release.get("created_at") or ""


def choose_release(releases: list[dict], channel: str) -> dict:
    """Choose a published release without hard-coding a version or nightly."""
    candidates = [r for r in releases if not r.get("draft")]
    if channel == "stable":
        candidates = [r for r in candidates if not r.get("prerelease") and r["tag_name"].lower() != "nightly"]
    elif channel == "nightly":
        candidates = [r for r in candidates if r["tag_name"].lower() == "nightly"]
    candidates = [r for r in candidates if release_date(r)]
    if not candidates:
        raise UpdateError(f"No published release available for channel {channel}")
    return max(candidates, key=release_date)


def matching_windows_job(jobs: list[dict], asset_date: str) -> bool:
    """Accept a successful x64 job even when another architecture failed."""
    moment = datetime.fromisoformat(asset_date.replace("Z", "+00:00"))
    for job in jobs:
        if "x86_64-pc-windows-msvc" not in job.get("name", "") or job.get("conclusion") != "success":
            continue
        if not job.get("started_at") or not job.get("completed_at"):
            continue
        start = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
        if start <= moment <= end:
            return True
    return False


async def resolve_release(channel: str, tag: str | None) -> dict:
    """Resolve a source SHA; the rolling nightly tag itself can be stale."""
    if tag:
        release = await api("releases/tags/" + urllib.parse.quote(tag, safe=""))
    else:
        releases = []
        for page in range(1, 11):
            batch = await api(f"releases?per_page=100&page={page}")
            releases.extend(batch)
            if len(batch) < 100:
                break
        release = choose_release(releases, channel)
    result = {"tag": release["tag_name"], "releaseId": release["id"],
              "releaseUrl": release["html_url"], "published": release_date(release),
              "prerelease": release.get("prerelease", False)}
    if release["tag_name"].lower() == "nightly":
        for page in range(1, 6):
            runs = await api(f"actions/workflows/flutter-nightly.yml/runs?per_page=100&page={page}")
            for run in runs["workflow_runs"]:
                if run["status"] != "completed" or run.get("head_repository", {}).get("full_name") != "rustdesk/rustdesk":
                    continue
                if run["created_at"] > result["published"] or run["updated_at"] < result["published"]:
                    continue
                jobs = await api(f"actions/runs/{run['id']}/jobs?per_page=100")
                if matching_windows_job(jobs["jobs"], result["published"]):
                    result.update(commit=run["head_sha"], runId=run["id"])
                    break
            if "commit" in result or len(runs["workflow_runs"]) < 100:
                break
        if "commit" not in result:
            raise UpdateError("Cannot map the nightly Windows asset to a successful x64 workflow job; refusing the stale nightly Git tag.")
    else:
        commit = await api("commits/" + urllib.parse.quote(result["tag"], safe=""))
        result["commit"] = commit["sha"]
    if not SHA.fullmatch(result["commit"]):
        raise UpdateError("Upstream returned an invalid source commit")
    return result


def download_sync(url: str, destination: Path, expected: str, authenticated: bool = False) -> None:
    """Only accept complete archives matching the upstream SHA-256 digest."""
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise UpdateError("A SHA-256 digest is required for downloads")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and digest(destination) == expected.lower():
        return
    headers = {"User-Agent": "SYNTRIX-Updater"}
    if authenticated and github_token():
        headers["Authorization"] = "Bearer " + github_token()
    temporary = destination.with_suffix(destination.suffix + ".partial")
    opener = urllib.request.build_opener(SafeRedirect())
    with opener.open(urllib.request.Request(url, headers=headers), timeout=120) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output)
    if digest(temporary) != expected.lower():
        temporary.unlink(missing_ok=True)
        raise UpdateError("Downloaded archive SHA-256 mismatch")
    temporary.replace(destination)


def extract_bridge(archive: Path, source: Path) -> None:
    """Extract only known bridge files; reject traversal and duplicate members."""
    found = set()
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            name = member.filename.replace("\\", "/")
            if member.is_dir():
                continue
            if name not in BRIDGE_FILES or name in found or member.file_size > 20_000_000:
                raise UpdateError(f"Unexpected bridge archive member: {name}")
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(package.read(member))
            found.add(name)
    if not {"src/bridge_generated.rs", "src/bridge_generated.io.rs", "flutter/lib/generated_bridge.dart", "flutter/lib/generated_bridge.freezed.dart"} <= found:
        raise UpdateError("Incomplete bridge archive")


async def run(arguments: list[str], cwd: Path, log: Path | None = None) -> str:
    """Run checked processes without shell interpolation."""
    process = await asyncio.create_subprocess_exec(*arguments, cwd=cwd,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    output = bytearray()
    stream = log.open("ab") if log else None
    try:
        while chunk := await process.stdout.read(65536):
            output.extend(chunk)
            if len(output) > 4_000_000:
                del output[:-4_000_000]
            if stream:
                stream.write(chunk)
                stream.flush()
        code = await process.wait()
    finally:
        if stream:
            stream.close()
    text = output.decode("utf-8", errors="replace")
    if code:
        raise UpdateError(f"Command failed ({code}): {arguments[0]}\n{text[-4000:]}")
    return text.strip()


def postconditions(source: Path) -> None:
    """Check the requested tray-only contract before compiling."""
    page = (source / "flutter/lib/desktop/pages/server_page.dart").read_text(encoding="utf-8-sig")
    main = (source / "flutter/lib/main.dart").read_text(encoding="utf-8-sig")
    model = (source / "flutter/lib/models/server_model.dart").read_text(encoding="utf-8-sig")
    if "_ActiveSessionIndicator" in page or "compactWindowsSession" in page + main + model:
        raise UpdateError("The compact session indicator was reintroduced")
    if "!_hideCm || _connectionsRequested" not in model or "!model.shouldShowCm" not in main:
        raise UpdateError("Tray-only CM visibility invariant is missing")
    if "requestConnectionManager" not in model or "syntrix-cm-show-active" not in (source / "src/tray.rs").read_text():
        raise UpdateError("Tray opening path is missing")


async def prepare_source(git: str, source: Path, selection: dict, profile_root: Path, profile: dict, log: Path) -> None:
    """Prepare an isolated checkout and apply the patch with conflict detection."""
    source.mkdir(parents=True, exist_ok=False)
    for args in (["init", str(source)], ["-C", str(source), "remote", "add", "origin", "https://github.com/rustdesk/rustdesk.git"],
                 ["-C", str(source), "config", "core.longpaths", "true"],
                 ["-C", str(source), "fetch", "--depth=1", "origin", selection["commit"]],
                 ["-C", str(source), "checkout", "--detach", selection["commit"]]):
        await run([git] + args, source.parent, log)
    if selection["commit"] != profile["baseCommit"]:
        await run([git, "fetch", "--depth=1", "origin", profile["baseCommit"]], source, log)
    patch = profile_root / profile["patch"]
    if digest(patch) != profile["patchSha256"]:
        raise UpdateError("Customization patch integrity check failed")
    await run([git, "apply", "--3way", "--index", str(patch)], source, log)
    conflicts = await run([git, "ls-files", "--unmerged"], source, log)
    if conflicts:
        raise UpdateError("Patch conflicts remain; no build will be published")
    await run([git, "submodule", "update", "--init", "--recursive"], source, log)
    postconditions(source)


async def restore_bridge(selection: dict, source: Path, profile_root: Path, profile: dict, cache: Path) -> None:
    """Use matching CI output instead of running bridge codegen in the source tree."""
    if selection["commit"] == profile["baseCommit"]:
        archive = profile_root / profile["bridgeArchive"]
        if digest(archive) != profile["bridgeArchiveSha256"]:
            raise UpdateError("Baseline bridge integrity check failed")
    else:
        run_ids = [selection["runId"]] if selection.get("runId") else []
        if not run_ids:
            runs = await api("actions/runs?head_sha=" + selection["commit"] + "&per_page=100")
            run_ids = [r["id"] for r in runs["workflow_runs"] if r["head_sha"] == selection["commit"]
                       and r.get("head_repository", {}).get("full_name") == "rustdesk/rustdesk"]
        selected = None
        for run_id in run_ids:
            artifacts = await api(f"actions/runs/{run_id}/artifacts?per_page=100")
            selected = next((a for a in artifacts["artifacts"] if a["name"] == "bridge-artifact" and not a["expired"] and a.get("digest", "").startswith("sha256:")), None)
            if selected:
                break
        if not selected:
            raise UpdateError("No non-expired, SHA-256-verified bridge artifact for this commit. Source remains prepared; codegen was not run.")
        archive = cache / "downloads" / (str(selected["id"]) + "-bridge.zip")
        url = selected["archive_download_url"] if github_token() else f"https://nightly.link/rustdesk/rustdesk/actions/runs/{run_id}/bridge-artifact.zip"
        await asyncio.to_thread(download_sync, url, archive, selected["digest"].split(":", 1)[1], bool(github_token()))
    await asyncio.to_thread(extract_bridge, archive, source)


def profiles(variant: str) -> list[tuple[Path, dict]]:
    """Support both the complete workspace and self-contained distributions."""
    locations = [ROOT] if (ROOT / "profile.json").exists() else [ROOT / "GoLive-Public/maintenance", ROOT / "Repository-Private/maintenance"]
    result = [(p, read_json(p / "profile.json")) for p in locations if (p / "profile.json").exists()]
    result = [(p, data) for p, data in result if variant == "both" or data["variant"] == variant]
    if not result:
        raise UpdateError("No matching customization profile")
    return result


async def main_async(args: argparse.Namespace) -> None:
    """Resolve, prepare, verify, and optionally compile every selected variant."""
    selection = await resolve_release(args.channel, args.tag)
    print(json.dumps(selection, indent=2), flush=True)
    if args.plan:
        return
    helper = ROOT / "Build-Syntrix.ps1"
    if not helper.exists():
        helper = ROOT / "maintenance/Build-Syntrix.ps1"
    powershell = shutil.which("pwsh") or shutil.which("powershell")
    if not powershell:
        raise UpdateError("Windows PowerShell or PowerShell 7 is required")
    git = shutil.which("git")
    if not git:
        await run([powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(helper.parent / "Prepare-Toolchain.ps1"), "-ToolchainRoot", str(args.toolchain), "-GitOnly"], ROOT)
        git = str(args.toolchain / "git/cmd/git.exe")
    for profile_root, profile in profiles(args.variant):
        label = re.sub(r"[^A-Za-z0-9._-]", "_", selection["tag"])
        identity = f"{label}-{selection['commit'][:12]}-{profile['patchSha256'][:12]}"
        output = args.output / profile["variant"] / identity
        state = output / "update-result.json"
        if state.exists() and not args.force:
            previous = read_json(state)
            artifact = output / previous["artifact"]
            if artifact.exists() and digest(artifact) == previous["sha256"]:
                print(f"Already built and verified: {artifact}", flush=True)
                continue
        work = args.cache / "work" / (profile["variant"] + "-" + selection["commit"][:12] + "-" + uuid.uuid4().hex[:8])
        log = args.cache / "logs" / (work.name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        try:
            print(f"Preparing {profile['variant']}: {work}", flush=True)
            await prepare_source(git, work, selection, profile_root, profile, log)
            write_json(work / "syntrix-source.json", {**selection, "variant": profile["variant"], "patchSha256": profile["patchSha256"]})
            if args.prepare_only:
                print(f"Patch and visibility checks passed: {work}", flush=True)
                continue
            await restore_bridge(selection, work, profile_root, profile, args.cache)
            await run([powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(helper),
                       "-Source", str(work), "-ToolchainRoot", str(args.toolchain), "-Output", str(output), "-Variant", profile["variant"], "-Python", sys.executable], ROOT, log)
            report = read_json(output / "build-verification.json")
            artifact = output / report["artifact"]
            if digest(artifact) != report["sha256"]:
                raise UpdateError("Published artifact changed after build verification")
            write_json(state, {**selection, **report, "patchSha256": profile["patchSha256"]})
            print(f"Verified output: {artifact}", flush=True)
        except Exception as error:
            write_json(log.with_suffix(".failure.json"), {**selection, "variant": profile["variant"], "error": str(error), "log": str(log)})
            raise


def main() -> None:
    """Parse unattended update options; never install or restart services."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=["auto", "stable", "nightly"], default="auto")
    parser.add_argument("--tag", help="Select an explicit published tag instead of automatic discovery")
    parser.add_argument("--variant", choices=["public", "private", "both"], default="both")
    parser.add_argument("--cache", type=Path, default=default_cache())
    parser.add_argument("--toolchain", type=Path, default=Path.home() / ".syntrix-toolchain")
    parser.add_argument("--output", type=Path, default=default_cache() / "releases")
    parser.add_argument("--plan", action="store_true", help="Resolve current release and exact source SHA only")
    parser.add_argument("--prepare-only", action="store_true", help="Download source, apply patch, and check tray-only invariants")
    parser.add_argument("--force", action="store_true", help="Build again even if verified output already exists")
    args = parser.parse_args()
    for key in ["cache", "toolchain", "output"]:
        setattr(args, key, getattr(args, key).resolve())
    try:
        asyncio.run(main_async(args))
    except (UpdateError, OSError, ValueError) as error:
        print(f"Update stopped: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
