#!/usr/bin/env python3
"""List every outside contributor whose work merged since the previous release.

python3 scripts/release_credits.py prints the block to paste under the release in CHANGELOG.md.
Run it after merging and copy the ### Thanks section into the release notes.
scripts/publish_release.sh runs --check on the release notes and refuses to publish until every contributor is named.
Add each missing line it reports before publishing.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PROJECT = "elijah7x/tivano"
MAINTAINER_USERNAMES = {"elijah7x"}
IGNORED_EMAIL_SUFFIXES = ("@anthropic.com", "@localhost")

COAUTHOR_RE = re.compile(r"(.+?)\s*<([^<>]+)>\s*")
VERSION_RE = re.compile(r'^\s*MARKETING_VERSION\s*=\s*(\d+\.\d+\.\d+)\s*$', re.MULTILINE)


def run_git(args, **kwargs):
    out = subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True, check=True, **kwargs
    )
    return out.stdout


def project_version():
    try:
        text = (ROOT / "config/release.xcconfig").read_text(encoding="utf-8")
    except OSError:
        return None
    m = VERSION_RE.search(text)
    return m.group(1) if m else None


def previous_tag():
    rev = "HEAD"
    version = project_version()
    if version:
        try:
            tags = run_git(["tag", "--points-at", "HEAD"]).split()
        except Exception:
            tags = []
        if f"v{version}" in tags:
            rev = "HEAD^"
    # A new or rewritten repository has no previous release in its ancestry.
    if not run_git(["tag", "--merged", rev, "--list", "v*"]).strip():
        return None
    return run_git(["describe", "--tags", "--abbrev=0", "--match", "v*", rev]).strip()


def commits_in_range(tag):
    out = run_git(
        [
            "log",
            "--no-merges",
            "--format=%H%x1f%an%x1f%ae%x1f%s%x1f%(trailers:key=Co-authored-by,valueonly)",
            f"{tag}..HEAD" if tag else "HEAD",
        ]
    )
    commits = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("\x1f")
        while len(parts) < 5:
            parts.append("")
        sha, name, email, subject, trailer_field = (
            parts[0],
            parts[1].strip(),
            parts[2].strip(),
            parts[3].strip(),
            parts[4],
        )
        coauthors = [
            {"name": m.group(1).strip(), "email": m.group(2).strip()}
            for m in COAUTHOR_RE.finditer(trailer_field)
        ]
        commits.append(
            {
                "sha": sha,
                "name": name,
                "email": email,
                "subject": subject,
                "coauthors": coauthors,
            }
        )
    return commits


def tag_date(tag):
    if tag is None:
        return None
    try:
        return run_git(["log", "-1", "--format=%cI", tag]).strip() or None
    except Exception:
        return None


def is_ancestor(sha, rev):
    try:
        subprocess.run(
            ["git", "merge-base", "--is-ancestor", sha, rev],
            cwd=ROOT,
            capture_output=True,
            check=True,
        )
        return True
    except Exception:
        return False


def merged_in(sha, tag):
    if is_ancestor(sha, "HEAD") and (tag is None or not is_ancestor(sha, tag)):
        return True
    try:
        if is_ancestor(sha, "origin/main") and (tag is None or not is_ancestor(sha, tag)):
            return True
    except Exception:
        pass
    return False


def merged_requests(tag):
    shas = {c["sha"] for c in commits_in_range(tag)}
    date = tag_date(tag)
    if tag is not None and not date:
        raise RuntimeError(f"Cannot determine date of previous tag {tag}")
    url = f"repos/{PROJECT}/pulls?state=closed&sort=updated&direction=desc&per_page=100"
    try:
        out = subprocess.run(
            ["gh", "api", url, "--paginate", "--slurp"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        pages = json.loads(out.stdout)
        if not isinstance(pages, list) or not pages or any(
            not isinstance(page, list) for page in pages
        ):
            raise ValueError("expected an array of PR pages")
        data = [pr for page in pages for pr in page]
        for pr in data:
            if (not isinstance(pr, dict)
                    or not {"number", "merged_at", "merge_commit_sha", "user", "title", "state"} <= pr.keys()
                    or not isinstance(pr.get("number"), int)
                    or pr["number"] <= 0
                    or pr["state"] != "closed"
                    or not isinstance(pr["title"], str)):
                raise ValueError("invalid PR record")
            if pr.get("merged_at") and (
                not isinstance(pr["merged_at"], str)
                or not isinstance(pr.get("merge_commit_sha"), str)
                or not isinstance(pr.get("user"), dict)
                or not isinstance(pr["user"].get("login"), str)
            ):
                raise ValueError("incomplete merged PR record")
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"GitHub PR query failed: {exc.stderr.strip() or exc}") from exc
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"Cannot read GitHub PR query: {exc}") from exc
    kept = []
    for pr in data:
        merged_at = pr.get("merged_at")
        if not merged_at or (date and merged_at < date):
            continue
        candidates = [
            s
            for s in (
                (pr.get("squash_commit") or {}).get("sha"),
                (pr.get("merge_commit") or {}).get("sha"),
                pr.get("merge_commit_sha"),
            )
            if s
        ]
        matched = [s for s in candidates if s in shas]
        if not matched:
            for s in candidates:
                if merged_in(s, tag):
                    matched.append(s)
                    break
        if not matched:
            continue
        author = pr.get("user") or {}
        kept.append(
            {
                "iid": pr.get("number"),
                "title": (pr.get("title") or "").strip(),
                "username": author.get("login"),
                "author_name": (author.get("login") or "").strip(),
                "is_bot": author.get("type") == "Bot",
                "shas": matched,
            }
        )
    return kept


def maintainer_emails():
    """Private identities stay in local config or the release environment."""
    configured = subprocess.run(
        ["git", "config", "--get-all", "tivano.maintainerEmail"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    ).stdout.splitlines()
    configured.extend(os.environ.get("TIVANO_MAINTAINER_EMAILS", "").split(","))
    return {email.strip().lower() for email in configured if email.strip()}


MAINTAINER_EMAILS = maintainer_emails()


def ignored_email(email):
    lowered = email.lower()
    if lowered in MAINTAINER_EMAILS:
        return True
    if lowered.endswith("@users.noreply.github.com"):
        username = lowered.split("@", 1)[0].split("+")[-1]
        return username in MAINTAINER_USERNAMES or username.endswith("[bot]")
    return lowered.endswith(IGNORED_EMAIL_SUFFIXES)


def contributors(tag):
    mrs = merged_requests(tag)
    commits = commits_in_range(tag)
    linked = set()
    for mr in mrs:
        linked.update(mr.get("shas", []))
    by_user = {}
    by_email = {}

    def entry_for_user(username, name):
        key = username.lower()
        entry = by_user.get(key)
        if entry is None:
            entry = {"name": name, "handle": username, "mrs": [], "subjects": []}
            by_user[key] = entry
        elif not entry["name"] and name:
            entry["name"] = name
        return entry

    def entry_for_email(name, email):
        key = email.lower()
        entry = by_email.get(key)
        if entry is None:
            entry = {"name": name, "handle": None, "mrs": [], "subjects": []}
            by_email[key] = entry
        return entry

    def add_subject(entry, subject):
        if subject and subject not in entry["subjects"]:
            entry["subjects"].append(subject)

    for mr in mrs:
        if (not mr["username"] or mr["username"].lower() in MAINTAINER_USERNAMES
                or mr["is_bot"] or mr["username"].lower().endswith("[bot]")):
            continue
        entry = entry_for_user(mr["username"], mr["author_name"] or mr["username"])
        pair = (mr["iid"], mr["title"])
        if pair not in entry["mrs"]:
            entry["mrs"].append(pair)

    for commit in commits:
        in_mr = commit["sha"] in linked
        if commit["email"] and not ignored_email(commit["email"]):
            entry = entry_for_email(commit["name"], commit["email"])
            if not in_mr:
                add_subject(entry, commit["subject"])
        for coauthor in commit["coauthors"]:
            if not coauthor["email"] or ignored_email(coauthor["email"]):
                continue
            entry = entry_for_email(coauthor["name"], coauthor["email"])
            if not in_mr:
                add_subject(entry, commit["subject"])

    for key, entry in list(by_email.items()):
        if not entry["name"]:
            continue
        for other in by_user.values():
            if (
                other["name"]
                and entry["name"].lower() == other["name"].lower()
            ):
                for subject in entry["subjects"]:
                    add_subject(other, subject)
                del by_email[key]
                break

    entries = [e for e in list(by_user.values()) + list(by_email.values()) if e["mrs"] or e["subjects"]]
    for entry in entries:
        entry["mrs"].sort(key=lambda pair: pair[0])
    entries.sort(
        key=lambda e: (
            min(iid for iid, _ in e["mrs"]) if e["mrs"] else float("inf"),
            (e["name"] or "").lower(),
        )
    )
    return entries


def suggested_line(entry):
    if entry["mrs"]:
        titles = "; ".join(f"{title} (#{iid})" for iid, title in entry["mrs"])
        if entry["handle"]:
            return f"- {entry['name']} (@{entry['handle']}): {titles}."
        return f"- {entry['name']}: {titles}."
    subjects = "; ".join(entry["subjects"])
    return f"- {entry['name']}: {subjects}."


def thanks_section(text):
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() in ("## Thanks", "### Thanks"):
            start = i + 1
            break
    if start is None:
        return ""
    section = []
    for line in lines[start:]:
        if line.startswith("#"):
            break
        section.append(line)
    return "\n".join(section)


def check_notes(path, entries, tag):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"Cannot read {path}: {exc}", file=sys.stderr)
        return 1
    if not entries:
        return 0
    section = thanks_section(text)
    credited = []
    for line in section.splitlines():
        match = re.fullmatch(
            r"\s*-\s+(.+?)\s*(?:\(@([A-Za-z0-9-]+)\))?\s*:\s*(\S.*?)\s*",
            line,
        )
        if not match:
            continue
        name, handle, contribution = match.groups()
        # A PR number alone is not a description of the person's contribution.
        if not re.sub(r"\(?#[0-9]+\)?|[\s.,;:()]+", "", contribution):
            continue
        credited.append((name.strip().casefold(), (handle or "").casefold(),
                         {int(iid) for iid in re.findall(r"(?<![\w#])#([0-9]+)(?![\w])", contribution)}))
    missing = []
    for entry in entries:
        required_prs = {iid for iid, _ in entry["mrs"]}
        matches = [prs for name, handle, prs in credited if (
            handle == entry["handle"].casefold() if entry["handle"]
            else name == entry["name"].casefold()
        )]
        if not any(required_prs <= prs for prs in matches):
            missing.append(entry)
    if not missing:
        return 0
    print("Missing from the Thanks section:")
    for entry in missing:
        print(suggested_line(entry))
    return 1


def main():
    args = sys.argv[1:]
    since = None
    as_json = False
    check_file = None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--since" and i + 1 < len(args):
            since = args[i + 1]
            i += 2
        elif arg.startswith("--since="):
            since = arg.split("=", 1)[1]
            i += 1
        elif arg == "--json":
            as_json = True
            i += 1
        elif arg == "--check" and i + 1 < len(args):
            check_file = args[i + 1]
            i += 2
        elif arg.startswith("--check="):
            check_file = arg.split("=", 1)[1]
            i += 1
        else:
            print(f"Unknown argument: {arg}", file=sys.stderr)
            return 2
    try:
        tag = since or previous_tag()
    except Exception as exc:
        print(f"Cannot determine previous tag: {exc}", file=sys.stderr)
        return 1
    try:
        entries = contributors(tag)
    except Exception as exc:
        print(f"Cannot determine release contributors: {exc}", file=sys.stderr)
        return 1
    if check_file is not None:
        return check_notes(check_file, entries, tag)
    if not entries:
        if as_json:
            print("[]")
        else:
            print(f"No outside contributors since {tag or 'the start of this repository'}.", file=sys.stderr)
        return 0
    if as_json:
        print(
            json.dumps(
                [
                    {
                        "name": e["name"],
                        "handle": e["handle"],
                        "merge_requests": [
                            {"iid": iid, "title": title} for iid, title in e["mrs"]
                        ],
                        "subjects": list(e["subjects"]),
                    }
                    for e in entries
                ],
                indent=2,
                ensure_ascii=False,
            )
        )
        return 0
    print("### Thanks")
    for entry in entries:
        print(suggested_line(entry))
    return 0


if __name__ == "__main__":
    sys.exit(main())
