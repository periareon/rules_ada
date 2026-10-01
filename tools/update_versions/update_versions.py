"""Generate versions.bzl from a hermetic-gnat release.

Toolchains come from https://github.com/periareon/hermetic-gnat.  Each of its
releases (tag YYYY.MM.DD or YYYY.MM.DD.N) is one build of the recipe and contains one
archive per platform for every GCC version it supports, named
gnat-<arch>-<os>-<gcc>.tar.gz.  rules_ada tracks exactly one such release:
by default the newest, or the one named with --release.
"""

import argparse
import base64
import binascii
import json
import logging
import os
import re
import time
import urllib.request
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen

HERMETIC_GNAT_REPO = "periareon/hermetic-gnat"

RELEASES_API = (
    f"https://api.github.com/repos/{HERMETIC_GNAT_REPO}/releases?page={{page}}"
)

RELEASE_TAG_REGEX = re.compile(r"^(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$")

ASSET_REGEX = re.compile(
    r"^gnat-(x86_64|aarch64)-(linux|darwin|windows64)-(\d+\.\d+\.\d+)\.tar\.gz$"
)

PLATFORM_MAP = {
    ("x86_64", "linux"): "linux-x86_64",
    ("aarch64", "linux"): "linux-aarch64",
    ("x86_64", "darwin"): "darwin-x86_64",
    ("aarch64", "darwin"): "darwin-aarch64",
    ("x86_64", "windows64"): "windows-x86_64",
}

REQUEST_HEADERS = {"User-Agent": "rules_ada/update_versions"}

VERSIONS_BZL_TEMPLATE = '''\
"""GNAT toolchain versions

A mapping of platform to integrity of the archive for each GCC version in
hermetic-gnat release {release} (https://github.com/{repo}).
"""

# AUTO-GENERATED: DO NOT MODIFY
#
# Update using the following command:
#
# ```
# bazel run //tools/update_versions
# ```

HERMETIC_GNAT_RELEASE = "{release}"

GNAT_VERSIONS = {versions}

DEFAULT_GNAT_VERSION = "{default_version}"
'''


def _workspace_root() -> Path:
    if "BUILD_WORKSPACE_DIRECTORY" in os.environ:
        return Path(os.environ["BUILD_WORKSPACE_DIRECTORY"])
    return Path(__file__).parent.parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=_workspace_root() / "ada" / "private" / "versions.bzl",
        help="The path in which to save results.",
    )
    parser.add_argument(
        "--release",
        help="hermetic-gnat release tag to use (default: the newest).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    return parser.parse_args()


def integrity(hex_str: str) -> str:
    """Convert a sha256 hex value to a Bazel integrity value."""
    raw_bytes = binascii.unhexlify(hex_str.strip())
    encoded = base64.b64encode(raw_bytes).decode("utf-8")
    return f"sha256-{encoded}"


def fetch_sha256(url: str) -> str | None:
    """Download a .sha256 sidecar file and return the hex hash."""
    req = urllib.request.Request(url, headers=REQUEST_HEADERS)
    logging.debug("Fetching checksum: %s", url)
    try:
        with urlopen(req) as resp:
            content = resp.read().decode("utf-8").strip()
            # Format: "hexhash  filename" or just "hexhash"
            return content.split()[0]
    except HTTPError as exc:
        logging.warning("Failed to fetch %s: %s", url, exc)
        return None


def gcc_version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def list_releases() -> list[dict]:
    """All published (non-draft, non-prerelease) date-versioned releases."""
    page = 1
    releases: list[dict] = []
    while True:
        url = RELEASES_API.format(page=page)
        req = urllib.request.Request(url, headers=REQUEST_HEADERS)
        logging.debug("Fetching releases page %d", page)
        try:
            with urlopen(req) as resp:
                json_data = json.loads(resp.read())
        except HTTPError as exc:
            if exc.code != 403:
                raise
            reset_time = exc.headers.get("x-ratelimit-reset")
            if not reset_time:
                raise
            sleep_duration = float(reset_time) - time.time()
            if sleep_duration > 0:
                logging.warning("Rate limited, waiting %.0fs", sleep_duration)
                time.sleep(sleep_duration)
            continue

        if not json_data:
            return releases
        for release in json_data:
            if not RELEASE_TAG_REGEX.match(release["tag_name"]):
                continue
            if release.get("draft") or release.get("prerelease"):
                logging.debug("Skipping %s (draft/prerelease)", release["tag_name"])
                continue
            releases.append(release)
        page += 1
        time.sleep(0.5)


def release_sort_key(release: dict) -> tuple[int, ...]:
    """(year, month, day, same-day sequence); a missing sequence sorts first."""
    return tuple(int(p or 0) for p in RELEASE_TAG_REGEX.match(release["tag_name"]).groups())


def collect_versions(release: dict) -> dict[str, dict[str, dict[str, str]]]:
    """Map GCC version -> platform -> {url, strip_prefix, integrity}."""
    asset_map: dict[str, str] = {}
    sha256_assets: dict[str, str] = {}
    for asset in release["assets"]:
        name = asset["name"]
        dl_url = asset["browser_download_url"]
        if name.endswith(".tar.gz.sha256"):
            sha256_assets[name.removesuffix(".sha256")] = dl_url
        elif name.endswith(".tar.gz"):
            asset_map[name] = dl_url

    versions: dict[str, dict[str, dict[str, str]]] = {}
    for asset_name, download_url in sorted(asset_map.items()):
        m = ASSET_REGEX.match(asset_name)
        if not m:
            continue
        arch, os_name, gcc_version = m.groups()
        platform_key = PLATFORM_MAP.get((arch, os_name))
        if not platform_key:
            continue
        sha256_url = sha256_assets.get(asset_name)
        if not sha256_url:
            logging.warning("No .sha256 sidecar for %s", asset_name)
            continue
        hex_hash = fetch_sha256(sha256_url)
        if not hex_hash:
            continue
        versions.setdefault(gcc_version, {})[platform_key] = {
            "url": download_url,
            "strip_prefix": asset_name.removesuffix(".tar.gz"),
            "integrity": integrity(hex_hash),
        }
        logging.debug("  %s %s -> %s", gcc_version, platform_key, asset_name)
    return versions


def main() -> None:
    args = parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    releases = list_releases()
    if not releases:
        logging.error("No hermetic-gnat releases found")
        return

    if args.release:
        matching = [r for r in releases if r["tag_name"] == args.release]
        if not matching:
            logging.error(
                "Release %s not found (have: %s)",
                args.release,
                ", ".join(r["tag_name"] for r in releases),
            )
            return
        release = matching[0]
    else:
        release = max(releases, key=release_sort_key)
    logging.info("Using hermetic-gnat release %s", release["tag_name"])

    versions = collect_versions(release)
    if not versions:
        logging.error("Release %s has no toolchain archives", release["tag_name"])
        return

    sorted_versions = sorted(versions.keys(), key=gcc_version_key)
    default_version = sorted_versions[-1]
    sorted_releases = {v: versions[v] for v in sorted_versions}

    output = VERSIONS_BZL_TEMPLATE.format(
        repo=HERMETIC_GNAT_REPO,
        release=release["tag_name"],
        versions=json.dumps(sorted_releases, indent=4, sort_keys=True),
        default_version=default_version,
    )

    logging.info("Writing to %s", args.output)
    args.output.write_text(output)
    logging.info(
        "Done. %d GCC version(s) from %s, default=%s",
        len(versions),
        release["tag_name"],
        default_version,
    )


if __name__ == "__main__":
    main()
