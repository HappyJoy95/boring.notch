#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from extract_build_number import extract_build_number


BUILD_SETTINGS_RE = re.compile(
    r"^\s*buildSettings\s*=\s*\{(?P<body>.*?)^\s*\};",
    re.MULTILINE | re.DOTALL,
)
FORK_VERSION_RE = re.compile(
    r"^(?P<upstream>[0-9]+\.[0-9]+\.[0-9]+)-hj\.(?P<revision>[1-9][0-9]*)$"
)


def _setting(block: str, name: str) -> str | None:
    match = re.search(
        rf"^\s*{re.escape(name)}\s*=\s*(?P<value>[^;]+)\s*;",
        block,
        re.MULTILINE,
    )
    if match is None:
        return None
    return match.group("value").strip().strip('"')


def extract_marketing_version(project_text: str, bundle_identifier: str) -> str:
    matching_blocks = [
        match.group("body")
        for match in BUILD_SETTINGS_RE.finditer(project_text)
        if _setting(match.group("body"), "PRODUCT_BUNDLE_IDENTIFIER")
        == bundle_identifier
    ]
    if not matching_blocks:
        raise ValueError(
            f"No build settings found for bundle identifier {bundle_identifier}"
        )

    versions = [_setting(block, "MARKETING_VERSION") for block in matching_blocks]
    if any(version is None for version in versions):
        raise ValueError(f"MARKETING_VERSION is missing for {bundle_identifier}")
    unique_versions = set(versions)
    if len(unique_versions) != 1:
        raise ValueError(
            f"MARKETING_VERSION values disagree for {bundle_identifier}: "
            + ", ".join(sorted(unique_versions))
        )
    return versions[0]  # type: ignore[return-value]


def release_metadata(project_text: str, bundle_identifier: str, requested_version: str | None = None) -> dict[str, str]:
    project_version = extract_marketing_version(project_text, bundle_identifier)
    version = requested_version or project_version
    match = FORK_VERSION_RE.fullmatch(version)
    if match is None:
        raise ValueError(
            f"Invalid fork version {version!r}; expected upstream-version-hj.N, "
            "for example 2.7.3-hj.1"
        )
    if version != project_version:
        raise ValueError(
            f"Requested version {version} does not match the source version "
            f"{project_version}; update and commit the project version first"
        )

    return {
        "version": version,
        "tag": f"v{version}",
        "upstream_version": match.group("upstream"),
        "build_number": extract_build_number(project_text, bundle_identifier),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate fork release metadata against the checked-out source."
    )
    parser.add_argument("--pbxproj", required=True, type=Path)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--version", default="")
    args = parser.parse_args(argv)

    try:
        project_text = args.pbxproj.read_text(encoding="utf-8")
        metadata = release_metadata(
            project_text,
            args.bundle_identifier,
            args.version or None,
        )
    except Exception as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    for name, value in metadata.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
