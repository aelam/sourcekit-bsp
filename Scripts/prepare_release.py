#!/usr/bin/env python3
"""Prepare a version commit or select the commit to release."""

import os
from pathlib import Path
import re
import subprocess
import sys


VERSION_FILE = "Sources/sourcekit-bsp/SourceKitBSPVersion.swift"
VERSION_DECLARATION = re.compile(
    r'^([ \t]*static let current = ")([^"\r\n]+)("[ \t]*)$', re.MULTILINE
)
RELEASE_VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)


def git(root, *args):
    return subprocess.check_output(
        ["git", *args], cwd=root, text=True, stderr=subprocess.PIPE
    ).strip()


def version_parts(version):
    if not isinstance(version, str) or not re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version
    ):
        raise ValueError("The current version must use stable major.minor.patch format.")
    return tuple(int(part) for part in version.split("."))


def next_version(version, bump):
    if bump not in ("patch", "minor", "major"):
        raise ValueError("Choose patch, minor, or major.")
    parts = list(version_parts(version))
    index = {"major": 0, "minor": 1, "patch": 2}[bump]
    parts[index] += 1
    parts[index + 1:] = [0] * (2 - index)
    return ".".join(str(part) for part in parts)


def release_version_key(version):
    match = RELEASE_VERSION.fullmatch(version)
    if not match:
        raise ValueError("SourceKitBSPVersion.current must use semantic version format.")
    prerelease = match.group(4)
    identifiers = prerelease.split(".") if prerelease else []
    if any(part.isdigit() and len(part) > 1 and part.startswith("0") for part in identifiers):
        raise ValueError("Numeric prerelease identifiers must not have leading zeroes.")
    return (
        tuple(int(match.group(index)) for index in (1, 2, 3)),
        prerelease is None,
        tuple((0, int(part)) if part.isdigit() else (1, part) for part in identifiers),
    )


def read_version(source):
    matches = list(VERSION_DECLARATION.finditer(source))
    if len(matches) != 1:
        raise ValueError("Expected one SourceKitBSPVersion.current declaration.")
    version = matches[0].group(2)
    release_version_key(version)
    return version, matches[0]


def version_source(root, commit):
    return git(root, "show", f"{commit}:{VERSION_FILE}")


def replace_version(source, version):
    _, declaration = read_version(source)
    return source[:declaration.start(2)] + version + source[declaration.end(2):]


def tag_commit(root, tag):
    try:
        return git(root, "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}")
    except subprocess.CalledProcessError as error:
        if error.returncode != 1:
            raise
        return None


def release_plan(root, version, commit, should_publish=True):
    tag = f"v{version}"
    existing = tag_commit(root, tag)
    if should_publish and existing and existing != commit:
        raise ValueError(f"Tag {tag} already points to another commit; existing tags are never moved.")
    return {
        "release_version": version, "tag_name": tag, "commit": commit,
        "should_publish": "true" if should_publish else "false",
    }


def prepare_manual_release(root, bump, base_commit, run_id):
    if not re.fullmatch(r"[0-9a-f]{40}", base_commit or "") or not re.fullmatch(r"[1-9][0-9]*", run_id or ""):
        raise ValueError("GITHUB_SHA and GITHUB_RUN_ID must identify this release run.")
    base_source = version_source(root, base_commit)
    base_version, _ = read_version(base_source)
    version = next_version(base_version, bump)
    tag = f"v{version}"
    marker = f"Release-Run: {run_id}"
    git(root, "fetch", "origin", "main", "--tags")
    candidates = git(root, "log", "origin/main", "--format=%H", "--fixed-strings", "--grep", marker).splitlines()
    matches = [commit for commit in candidates if marker in git(root, "show", "-s", "--format=%B", commit).splitlines()]
    if len(matches) > 1:
        raise ValueError("More than one version commit matches this release run.")
    if matches:
        commit = matches[0]
        parents = git(root, "rev-list", "--parents", "-n", "1", commit).split()
        changed = git(root, "diff-tree", "--no-commit-id", "--name-only", "-r", commit).splitlines()
        if parents != [commit, base_commit] or changed != [VERSION_FILE] or version_source(root, commit) != replace_version(base_source, version):
            raise ValueError("The existing version commit does not match this release run.")
        return release_plan(root, version, commit)

    if git(root, "rev-parse", "HEAD") != base_commit or git(root, "rev-parse", "origin/main") != base_commit:
        raise ValueError("main advanced after this run started. Start a new release run from main.")
    if git(root, "status", "--porcelain"):
        raise ValueError("Release preparation requires a clean checkout.")
    if tag_commit(root, tag):
        raise ValueError(f"Tag {tag} already exists. This run will not create another version.")

    version_path = root / VERSION_FILE
    version_path.write_text(replace_version(version_path.read_text(), version))
    git(root, "add", VERSION_FILE)
    git(root, "-c", "user.name=github-actions[bot]",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "-c", "commit.gpgsign=false", "commit", "-m", f"chore: release {tag}", "-m", marker)
    commit = git(root, "rev-parse", "HEAD")
    git(root, "push", "origin", "HEAD:refs/heads/main")
    return release_plan(root, version, commit)


def plan_automatic_release(root, before, ref_type, ref_name):
    commit = git(root, "rev-parse", "HEAD")
    version, _ = read_version(version_source(root, commit))
    if ref_type == "tag":
        if ref_name != f"v{version}":
            raise ValueError(f"Release tag {ref_name} does not match version {version}.")
        return release_plan(root, version, commit)
    if ref_type != "branch" or ref_name != "main":
        raise ValueError("Automatic releases require main or a version tag.")
    if not re.fullmatch(r"[0-9a-f]{40}", before or ""):
        raise ValueError("BEFORE_SHA must identify the commit before the push.")
    message = git(root, "show", "-s", "--format=%B", commit)
    if re.search(r"^Release-Run: [1-9][0-9]*$", message, re.MULTILINE):
        return release_plan(root, version, commit, should_publish=False)
    if before != "0" * 40:
        previous, _ = read_version(version_source(root, before))
        if previous == version:
            return release_plan(root, version, commit, should_publish=False)
        if release_version_key(version) <= release_version_key(previous):
            raise ValueError(f"Version {version} must be greater than {previous}.")
    return release_plan(root, version, commit)


def main():
    root = Path(__file__).resolve().parent.parent
    event = os.environ.get("GITHUB_EVENT_NAME")
    if event == "workflow_dispatch" and os.environ.get("GITHUB_REF") == "refs/heads/main":
        plan = prepare_manual_release(root, os.environ.get("BUMP_TYPE"), os.environ.get("GITHUB_SHA"), os.environ.get("GITHUB_RUN_ID"))
    elif event == "push":
        plan = plan_automatic_release(root, os.environ.get("BEFORE_SHA"), os.environ.get("GITHUB_REF_TYPE"), os.environ.get("GITHUB_REF_NAME"))
    else:
        raise ValueError("Run manual release preparation through GitHub Actions on main.")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.writelines(f"{key}={value}\n" for key, value in plan.items())
    action = "Prepared" if plan["should_publish"] == "true" else "Skipped"
    print(f"{action} {plan['tag_name']} at {plan['commit']}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
