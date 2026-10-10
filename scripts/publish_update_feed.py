#!/usr/bin/env python3
"""Publish release metadata, not app source, to the isolated gh-pages branch.

GitHub's Git Database API supports root commits (parents=[]); later commits
fast-forward normally. No push hook is disabled and main/dev are untouched.
https://docs.github.com/rest/git/commits#create-a-commit
https://docs.github.com/rest/pages/pages#create-a-github-pages-site
"""
import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

PROJECT = "elijah7x/tivano"
BRANCH = "gh-pages"
FEED_URL = "https://elijah7x.github.io/tivano/updates.json"
RAW_URL = f"https://raw.githubusercontent.com/{PROJECT}/{BRANCH}/updates.json"


def api(endpoint, payload=None, method=None, optional=False):
    args = ["gh", "api", f"repos/{PROJECT}/{endpoint}"]
    if method:
        args += ["--method", method]
    if payload is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    try:
        data = json.loads(result.stdout) if result.stdout.strip() else None
    except ValueError:
        raise RuntimeError(f"Invalid GitHub response for {endpoint}")
    if result.returncode:
        if optional and isinstance(data, dict) and str(data.get("status")) == "404":
            return None
        raise RuntimeError(f"GitHub request failed for {endpoint}; no missing-resource assumption was made")
    return data


def version(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected a stable vX.Y.Z tag")
    return tuple(map(int, tag[1:].split(".")))


def make_feed(release, dmg):
    tag = release["tag_name"]
    version(tag)
    if release.get("draft") or release.get("prerelease") or not release.get("published_at"):
        raise ValueError("Only published stable releases can enter the feed")
    filename = f"Tivano-{tag[1:]}.dmg"
    assets = [a for a in release["assets"] if a["name"] == filename]
    if len(assets) != 1 or len(release["assets"]) != 1:
        raise ValueError("The release must have exactly its one DMG installer")
    asset = assets[0]
    expected_url = f"https://github.com/{PROJECT}/releases/download/{tag}/{filename}"
    if asset["browser_download_url"] != expected_url:
        raise ValueError("Unexpected installer URL")
    if dmg.name != filename or dmg.stat().st_size != asset["size"]:
        raise ValueError("The local DMG name/size does not match the published asset")
    checksum = hashlib.sha256()
    with dmg.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1_048_576), b""):
            checksum.update(chunk)
    digest = checksum.hexdigest()
    if asset.get("digest") != f"sha256:{digest}":
        raise ValueError("The local DMG checksum does not match GitHub's uploaded asset digest")
    return {
        "schema_version": 1,
        "releases": [{
            "tag_name": tag, "name": release.get("name"), "body": release.get("body", ""),
            "published_at": release["published_at"], "draft": False, "prerelease": False,
            "assets": [{"name": filename, "browser_download_url": expected_url,
                        "size": asset["size"], "sha256": digest}],
        }],
    }


def publish(feed):
    tag = feed["releases"][0]["tag_name"]
    ref = api(f"git/ref/heads/{BRANCH}", optional=True)
    parent = ref["object"]["sha"] if ref else None
    base_tree = None
    if parent:
        base_tree = api(f"git/commits/{parent}")["tree"]["sha"]
        previous = api(f"contents/updates.json?ref={parent}", optional=True)
        if previous:
            old = json.loads(base64.b64decode(previous["content"]))
            if old.get("schema_version") != 1:
                raise ValueError("Unknown existing feed schema; do not overwrite it")
            if any(version(r["tag_name"]) > version(tag) for r in old["releases"]):
                raise ValueError("Refusing to move the feed to an older version")
            if old == feed:
                print(f"Feed already describes {tag}")
                return
    entries = []
    for name, content in [("updates.json", json.dumps(feed, ensure_ascii=False, indent=2) + "\n"),
                          (".nojekyll", "")]:
        sha = api("git/blobs", {"content": content, "encoding": "utf-8"})["sha"]
        entries.append({"path": name, "mode": "100644", "type": "blob", "sha": sha})
    tree_input = {"tree": entries}
    if base_tree:
        tree_input["base_tree"] = base_tree
    tree = api("git/trees", tree_input)["sha"]
    commit = api("git/commits", {"message": f"Update Tivano feed to {tag}", "tree": tree,
                                  "parents": [parent] if parent else []})["sha"]
    if parent:
        # Refuse concurrent publication rather than overwrite another publisher's update.
        if api(f"git/ref/heads/{BRANCH}")["object"]["sha"] != parent:
            raise RuntimeError("The feed moved during publication; retry after reviewing it")
        api(f"git/refs/heads/{BRANCH}", {"sha": commit, "force": False}, method="PATCH")
    else:
        api("git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": commit})
    print(f"Published metadata for {tag}: {commit}")


def ensure_pages():
    pages = api("pages", optional=True)
    if pages is None:
        api("pages", {"build_type": "legacy", "source": {"branch": BRANCH, "path": "/"}})
    elif pages.get("source") != {"branch": BRANCH, "path": "/"} or pages.get("cname"):
        raise RuntimeError("Pages already has a different source/domain; its configuration was not changed")
    print(f"Primary: {FEED_URL}\nFallback: {RAW_URL}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--output", type=Path, help="Write the manifest locally without publishing")
    parser.add_argument("--enable-pages", action="store_true", help="Create the Pages site if absent")
    args = parser.parse_args()
    version(args.tag)
    release = api(f"releases/tags/{args.tag}")
    feed = make_feed(release, args.dmg)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(feed, ensure_ascii=False, indent=2) + "\n")
        return
    # Check existing Pages ownership before changing any branch content.
    pages = api("pages", optional=True)
    if pages and (pages.get("source") != {"branch": BRANCH, "path": "/"} or pages.get("cname")):
        raise RuntimeError("Existing Pages configuration differs; nothing was published")
    publish(feed)
    if args.enable_pages:
        ensure_pages()
    elif pages is None:
        raise RuntimeError("Feed is published, but Pages is absent; rerun with --enable-pages")
    print("Pages deployment is asynchronous; verify the public JSON after the Pages build completes.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, KeyError) as error:
        sys.exit(str(error))
