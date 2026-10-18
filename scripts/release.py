#!/usr/bin/env python3
"""Package the mod and publish it as a GitHub release.

The manager installs this mod by fetching the zip from a GitHub release, which is
why the release has to exist: it is the distribution channel that needs no
mod-portal credentials. The mod portal is a second, optional channel.

Factorio is fussy about the archive layout. The zip must be named
``<name>_<version>.zip`` and contain exactly one top-level directory with that same
name, holding ``info.json`` at its root.

    scripts/release.py                 # build the zip only
    scripts/release.py --tag v0.1.0    # build, tag, and publish to GitHub and the portal

Publishing needs ``GITHUB_TOKEN`` (or ``GH_TOKEN``) with rights to the repository, and
``MOD_PORTAL_KEY`` to upload the build to the mod portal, which is what a player's client
installs from. Both are published together, or neither: ``--no-portal`` releases to GitHub
alone when that is genuinely what is wanted. ``--repo`` if the default is wrong.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = "NovaProtocol/server-connector-mod"

# Everything the game needs, and nothing the game does not.
# Top-level files, plus every Lua file under the directories listed below -- the runtime is
# a package under control/, and it must ship whole or the mod does not load.
SHIPPED = ["info.json", "settings.lua", "control.lua", "changelog.txt", "LICENSE", "README.md"]
SHIPPED_DIRS = ["control"]


def read_info():
    with open(ROOT / "info.json", encoding="utf-8") as handle:
        return json.load(handle)


def shipped_files():
    """Every file the mod ships, as paths relative to ROOT.

    The top-level files, then every Lua file under the shipped directories. Written out
    rather than walked wholesale, so scripts/, the built zips and the git metadata can
    never end up inside the mod.
    """
    files = []
    for name in SHIPPED:
        if not (ROOT / name).exists():
            raise SystemExit(f"missing {name}; the mod would be incomplete")
        files.append(name)

    for directory in SHIPPED_DIRS:
        root = ROOT / directory
        if not root.is_dir():
            raise SystemExit(f"missing {directory}/; the mod would be incomplete")
        for path in sorted(root.rglob("*.lua")):
            files.append(path.relative_to(ROOT).as_posix())

    return files


def check_lua():
    """Parse every shipped Lua file before packaging it.

    A syntax error in any one of them stops the mod loading at all -- the server refuses
    the save and says so in a log nobody is reading yet -- so it is caught here instead,
    whenever a parser is on PATH.
    """
    parser = next((shutil.which(name) for name in ("luac5.4", "luac", "luajit") if shutil.which(name)), None)
    if not parser:
        print("no Lua parser on PATH, syntax not checked")
        return

    for name in [path for path in shipped_files() if path.endswith(".lua")]:
        result = subprocess.run([parser, "-p", str(ROOT / name)], capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"{name} does not parse: {result.stderr.strip()}")

    print(f"Lua parses ({parser})")


def build(info):
    check_lua()

    files = shipped_files()
    stem = f"{info['name']}_{info['version']}"
    out = ROOT / f"{stem}.zip"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(ROOT / name, f"{stem}/{name}")

    print(f"built {out.name} ({out.stat().st_size} bytes, {len(files)} files)")
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


MOD_PORTAL = "https://mods.factorio.com"


def portal_init(name, key, publish):
    """Ask the portal for an upload URL. init_publish creates the mod page;
    init_upload adds a release to a page that already exists."""
    endpoint = "/api/v2/mods/init_publish" if publish else "/api/v2/mods/releases/init_upload"

    body = urllib.parse.urlencode({"mod": name}).encode()
    request = urllib.request.Request(MOD_PORTAL + endpoint, data=body, method="POST")
    request.add_header("Authorization", f"Bearer {key}")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")

    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read())["upload_url"]
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"portal {endpoint} failed: {error.code} {detail}") from None


def portal_send(upload_url, zip_path, key):
    """POST the zip as multipart form data. urllib has no encoder for that, so the
    body is built by hand -- small, and it keeps the script dependency-free."""
    boundary = "----server-connector" + uuid.uuid4().hex
    content = zip_path.read_bytes()

    body = b"".join([
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="file"; filename="{zip_path.name}"\r\n'.encode(),
        b"Content-Type: application/zip\r\n\r\n",
        content,
        b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])

    if not upload_url.startswith("http"):
        upload_url = MOD_PORTAL + upload_url

    request = urllib.request.Request(upload_url, data=body, method="POST")
    request.add_header("Authorization", f"Bearer {key}")
    request.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")

    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"portal upload failed: {error.code} {detail}") from None


def publish_to_portal(zip_path, info, key, create):
    upload_url = portal_init(info["name"], key, create)
    result = portal_send(upload_url, zip_path, key)
    print(f"portal: uploaded {info['name']} {info['version']} -> {result.get('url', result)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", help="create and publish a release at this tag, e.g. v0.1.0")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--commit", action="store_true", help="commit the package change first")
    parser.add_argument("--no-portal", action="store_true",
                        help="publish to GitHub only; players' clients will not be able to fetch the build")
    parser.add_argument("--create-page", action="store_true",
                        help="create the mod page on the portal first; only valid once")
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

    # Both channels or neither, and checked before anything is published: the two are not
    # interchangeable. GitHub is what the manager installs onto the servers; the portal is
    # what a player's client installs when it syncs with a server. A release that lands on
    # one and not the other leaves servers and clients on different builds, and the only
    # symptom is that nobody can join -- which is not something to discover afterwards.
    key = None
    if not args.no_portal:
        key = os.environ.get("MOD_PORTAL_KEY")
        if not key:
            print("MOD_PORTAL_KEY is required: without the portal upload, players cannot fetch "
                  "this build. Pass --no-portal to release to GitHub anyway.", file=sys.stderr)
            return 2

    # The portal first. It is the half that can fail on a bad or expired key, and a release that
    # exists on GitHub but not the portal is the one nobody can join -- so the failure has to
    # happen before anything is published at all.
    if key:
        publish_to_portal(zip_path, info, key, args.create_page)

    url = publish(zip_path, stem, args.repo, args.tag, token)
    print(f"manager can fetch it from {url}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
