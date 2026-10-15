#!/usr/bin/env python3
"""Package the mod and publish it as a GitHub release.

The manager installs this mod by fetching the zip from a GitHub release, which is
why the release has to exist: it is the distribution channel that needs no
mod-portal credentials. The mod portal is a second, optional channel.

Factorio is fussy about the archive layout. The zip must be named
``<name>_<version>.zip`` and contain exactly one top-level directory with that same
name, holding ``info.json`` at its root.

    scripts/release.py                 # build the zip only
    scripts/release.py --tag v0.1.0    # build, tag, and publish the release

Publishing needs ``GITHUB_TOKEN`` (or ``GH_TOKEN``) with rights to the repository,
and ``--repo`` if the default is wrong.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = "NovaProtocol/server-connector-mod"

# Everything the game needs, and nothing the game does not.
SHIPPED = ["info.json", "settings.lua", "control.lua", "changelog.txt", "LICENSE", "README.md"]


def read_info():
    with open(ROOT / "info.json", encoding="utf-8") as handle:
        return json.load(handle)


def build(info):
    stem = f"{info['name']}_{info['version']}"
    out = ROOT / f"{stem}.zip"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in SHIPPED:
            source = ROOT / name
            if not source.exists():
                raise SystemExit(f"missing {name}; the mod would be incomplete")
            archive.write(source, f"{stem}/{name}")

    print(f"built {out.name} ({out.stat().st_size} bytes, {len(SHIPPED)} files)")
    return out, stem


def api(repo, path, token, method="GET", payload=None, content_type="application/json"):
    url = f"https://api.github.com/repos/{repo}{path}"
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/vnd.github+json")
    if body is not None:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"GitHub {method} {path} failed: {error.code} {detail}") from None


def publish(zip_path, stem, repo, tag, token):
    # A release already on this tag is reused rather than fought with, so a rerun
    # after a failed asset upload does not need the tag deleted first.
    try:
        release = api(repo, f"/releases/tags/{tag}", token)
        print(f"release {tag} already exists, reusing it")
    except SystemExit:
        release = api(repo, "/releases", token, "POST", {
            "tag_name": tag,
            "name": tag,
            "body": f"server-connector-mod {stem.split('_')[-1]}",
        })
        print(f"created release {tag}")

    for asset in release.get("assets", []):
        if asset["name"] == zip_path.name:
            api(repo, f"/releases/assets/{asset['id']}", token, "DELETE")
            print(f"replaced existing asset {asset['name']}")

    upload = (
        f"https://uploads.github.com/repos/{repo}/releases/{release['id']}/assets"
        f"?name={zip_path.name}"
    )
    with open(zip_path, "rb") as handle:
        data = handle.read()
    request = urllib.request.Request(upload, data=data, method="POST")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", "application/zip")
    try:
        with urllib.request.urlopen(request) as response:
            asset = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise SystemExit(f"asset upload failed: {error.code} {error.read().decode(errors='replace')}") from None

    print(f"uploaded {asset['name']} to {release['html_url']}")
    return asset["browser_download_url"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", help="create and publish a release at this tag, e.g. v0.1.0")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--commit", action="store_true", help="commit the package change first")
    args = parser.parse_args()

    info = read_info()
    zip_path, stem = build(info)

    if args.commit:
        subprocess.run(["git", "add", "-A"], cwd=ROOT, check=True)
        subprocess.run(
            ["git", "commit", "-m", f"release: {info['name']} {info['version']}"],
            cwd=ROOT,
            check=True,
        )

    if not args.tag:
        print("no --tag given, zip built only")
        return 0

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("GITHUB_TOKEN (or GH_TOKEN) is required to publish", file=sys.stderr)
        return 2

    url = publish(zip_path, stem, args.repo, args.tag, token)
    print(f"manager can fetch it from {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
