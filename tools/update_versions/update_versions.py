"""Fetch all available GNAT FSF build releases and generate versions.bzl."""

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

GNAT_GITHUB_RELEASES_API = (
    "https://api.github.com/repos/alire-project/GNAT-FSF-builds/releases?page={page}"
)

GNAT_RELEASE_TAG_REGEX = re.compile(r"^gnat-(\d+\.\d+\.\d+-\d+)$")

GNAT_ASSET_REGEX = re.compile(
    r"^gnat-(x86_64|aarch64)-(linux|darwin|windows64)-(\d+\.\d+\.\d+-\d+)\.tar\.gz$"
)

GNAT_PLATFORM_MAP = {
    ("x86_64", "linux"): "linux-x86_64",
    ("aarch64", "linux"): "linux-aarch64",
    ("x86_64", "darwin"): "darwin-x86_64",
    ("aarch64", "darwin"): "darwin-aarch64",
    ("x86_64", "windows64"): "windows-x86_64",
}

REQUEST_HEADERS = {"User-Agent": "rules_ada/update_versions"}

VERSIONS_BZL_TEMPLATE = '''\
"""GNAT FSF Build Versions

A mapping of platform to integrity of the archive for each version of GNAT available.
"""

# AUTO-GENERATED: DO NOT MODIFY
#
# Update using the following command:
#
# ```
# bazel run //tools/update_versions
# ```

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


def query_releases() -> dict[str, dict[str, dict[str, str]]]:
    """Fetch all GNAT FSF releases from GitHub and collect checksums."""
    page = 1
    releases_data: dict[str, dict[str, dict[str, str]]] = {}

    while True:
        url = GNAT_GITHUB_RELEASES_API.format(page=page)
        req = urllib.request.Request(url, headers=REQUEST_HEADERS)
        logging.debug("Fetching releases page %d", page)

        try:
            with urlopen(req) as resp:
                json_data = json.loads(resp.read())
                if not json_data:
                    break

                for release in json_data:
                    tag_match = GNAT_RELEASE_TAG_REGEX.match(release["tag_name"])
                    if not tag_match:
                        continue

                    version = tag_match.group(1)
                    if release.get("prerelease", False):
                        logging.debug("Skipping prerelease %s", version)
                        continue

                    logging.info("Processing GNAT %s", version)

                    asset_map: dict[str, str] = {}
                    sha256_assets: dict[str, str] = {}
                    for asset in release["assets"]:
                        name = asset["name"]
                        dl_url = asset["browser_download_url"]
                        if name.endswith(".tar.gz.sha256"):
                            base = name.removesuffix(".sha256")
                            sha256_assets[base] = dl_url
                        elif name.endswith(".tar.gz"):
                            asset_map[name] = dl_url

                    artifacts: dict[str, dict[str, str]] = {}
                    for asset_name, download_url in asset_map.items():
                        m = GNAT_ASSET_REGEX.match(asset_name)
                        if not m:
                            continue

                        arch, os_name, asset_ver = m.group(1), m.group(2), m.group(3)
                        if asset_ver != version:
                            continue

                        platform_key = GNAT_PLATFORM_MAP.get((arch, os_name))
                        if not platform_key:
                            continue

                        sha256_url = sha256_assets.get(asset_name)
                        if not sha256_url:
                            logging.warning(
                                "No .sha256 sidecar for %s", asset_name
                            )
                            continue

                        hex_hash = fetch_sha256(sha256_url)
                        if not hex_hash:
                            continue

                        strip_prefix = asset_name.removesuffix(".tar.gz")
                        artifacts[platform_key] = {
                            "url": download_url,
                            "strip_prefix": strip_prefix,
                            "integrity": integrity(hex_hash),
                        }
                        logging.debug(
                            "  %s -> %s", platform_key, strip_prefix
                        )

                    if artifacts:
                        releases_data[version] = artifacts
                        logging.info(
                            "  Found %d platform(s)", len(artifacts)
                        )

            page += 1
            time.sleep(0.5)

        except HTTPError as exc:
            if exc.code != 403:
                raise

            reset_time = exc.headers.get("x-ratelimit-reset")
            if not reset_time:
                raise

            sleep_duration = float(reset_time) - time.time()
            if sleep_duration < 0.0:
                continue

            logging.warning("Rate limited, waiting %.0fs", sleep_duration)
            time.sleep(sleep_duration)

    return releases_data


def main() -> None:
    args = parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)
    else:
        logging.basicConfig(level=logging.INFO)

    releases = query_releases()

    if not releases:
        logging.error("No releases found")
        return

    # Sort versions descending to pick latest as default
    sorted_versions = sorted(releases.keys(), reverse=True)
    default_version = sorted_versions[0]

    # Sort the dict by version for stable output
    sorted_releases = {v: releases[v] for v in sorted(releases.keys())}

    versions_str = json.dumps(sorted_releases, indent=4, sort_keys=True)
    output = VERSIONS_BZL_TEMPLATE.format(
        versions=versions_str,
        default_version=default_version,
    )

    logging.info("Writing to %s", args.output)
    args.output.write_text(output)
    logging.info(
        "Done. %d version(s), default=%s", len(releases), default_version
    )


if __name__ == "__main__":
    main()
