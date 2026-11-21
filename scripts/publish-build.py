"""Commit project files and print the exact GitHub-published revision to build."""
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

GIT = "/usr/bin/git"
MAX_BLOB = 100 * 1024 * 1024  # GitHub’s single-file limit.
SECRET = re.compile(
    rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|"
    rb"(?:AKIA|ASIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{30,}|"
    rb"github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[A-Za-z0-9-]{20,}|"
    rb"AIza[\w-]{35}|sk-(?:proj-)?[\w-]{32,}|sk_live_[A-Za-z0-9]{16,}|"
    rb"https?://[^/\s:@]+:[^/\s@]+@|"
    rb"""(?im:^\s*(?:export\s+)?(?:[\w.-]*[_-])?(?:api[_-]?key|password|access[_-]?token|client[_-]?secret)\s*[:=]\s*["']?[a-zA-Z0-9/+_.=-]{12,})"""
)


def git(*args):
    return subprocess.check_output([GIT, *args])


def paths(*args):
    return [os.fsdecode(p) for p in git(*args).split(b"\0") if p]


def check_name(path):
    parts = Path(path).parts
    sensitive = {".env", ".ssh", ".aws", ".gnupg", ".npmrc", ".netrc", ".pypirc", ".git-credentials",
                 "credentials.json", "credentials", "id_rsa", "id_ed25519", ".secrets", ".envrc"}
    if any(p.lower() in sensitive or p.lower().startswith(".env.") for p in parts) or path.lower().endswith(
        (".p12", ".pfx", ".p8", ".pem", ".key", ".keychain", ".mobileprovision", ".sqlite", ".db")
    ):
        sys.exit(f"Refusing to publish a private or local file: {path!r}")


def project_file(path):
    if path in {".gitignore", "README.md", "Package.swift", "Package.resolved", "build.sh",
                "Resources/AppIcon.icns", "Resources/AppIcon.png", "Resources/Info.plist",
                "Resources/Music.entitlements", "Music.xcodeproj/project.pbxproj"}:
        return True
    folder, _, _ = path.partition("/")
    suffix = Path(path).suffix
    return suffix in {
        "Sources": {".swift", ".h", ".c", ".modulemap"},
        "Tests": {".swift", ".sh"}, "scripts": {".sh", ".py"},
        "docs": {".md"}, "Music.xcodeproj": {".xcscheme"},
    }.get(folder, set())


def scan_tree(tree, checked):
    for entry in paths("ls-tree", "-rz", tree):
        fields, path = entry.split("\t", 1)
        mode, kind, oid = fields.split()
        check_name(path)
        if mode not in {"100644", "100755"} or kind != "blob":
            sys.exit(f"Refusing to publish a link or submodule: {path!r}")
        if oid not in checked:
            if int(git("cat-file", "-s", oid)) > MAX_BLOB:
                sys.exit(f"File exceeds the GitHub size limit: {path!r}")
            if SECRET.search(git("cat-file", "blob", oid)):
                sys.exit(f"Possible credential in {path!r}. Remove it from outgoing commits before building.")
            checked.add(oid)


def publish(repo):
    if Path(os.fsdecode(git("rev-parse", "--show-toplevel")).strip()).resolve() != Path.cwd():
        sys.exit("Build must run at the project repository root.")
    branch = git("symbolic-ref", "--quiet", "--short", "HEAD").decode().strip()
    for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        if Path(os.fsdecode(git("rev-parse", "--git-path", marker)).strip()).exists():
            sys.exit("Finish the current Git operation before building.")
    urls = git("remote", "get-url", "--push", "--all", "origin").decode().splitlines()
    allowed = {prefix + repo + suffix for prefix in
               ("https://github.com/", "git@github.com:", "ssh://git@github.com/")
               for suffix in ("", ".git")}
    if len(urls) != 1 or urls[0] not in allowed:
        sys.exit(f"Expected a single credential-free origin push URL for github.com/{repo}.")
    if subprocess.run([GIT, "config", "--bool", "--get", "remote.origin.mirror"],
                      capture_output=True).stdout.strip() == b"true":
        sys.exit("A mirror remote cannot be used for build publishing.")

    # Include tracked edits/deletions and new project inputs. Leave unrelated
    # local files alone. Stop if an unknown build input would be omitted.
    new_files = []
    for path in paths("ls-files", "--others", "--exclude-standard", "-z"):
        if project_file(path):
            new_files.append(path)
        elif path.startswith(("Sources/", "Resources/", "Tests/", "scripts/")):
            sys.exit(f"Review and explicitly stage or ignore this new file before building: {path!r}")
    for path in paths("diff", "--name-only", "--no-renames", "-z") + new_files:
        check_name(path)
        file = Path(path)
        if file.is_symlink():
            sys.exit(f"Refusing to stage a symbolic link: {path!r}")
        if file.exists() and (not stat.S_ISREG(file.stat().st_mode) or file.stat().st_size > MAX_BLOB
                              or SECRET.search(file.read_bytes())):
            sys.exit(f"Review possible credentials or a non-regular file before staging: {path!r}")

    subprocess.run([GIT, "add", "-u", "--", "."], check=True)
    if new_files:
        subprocess.run([GIT, "--literal-pathspecs", "add", "--", *new_files], check=True)
    checked = set()
    scan_tree(git("write-tree").decode().strip(), checked)
    subprocess.run([GIT, "commit", "--allow-empty", "-m", f"Build {repo.rsplit('/', 1)[1]}"],
                   stdout=sys.stderr, check=True)
    revision = git("rev-parse", "HEAD").decode().strip()
    # Use the actual destination tip. A stale local tracking ref can omit
    # unpublished intermediate commits from the credential check.
    destination = "refs/heads/" + branch
    remote_ref = git("ls-remote", "--refs", urls[0], destination).split()
    revisions = [revision]
    if remote_ref:
        tip = remote_ref[0].decode("ascii")
        if subprocess.run([GIT, "merge-base", "--is-ancestor", tip, revision]).returncode != 0:
            sys.exit("The destination branch has diverged. Reconcile it before building.")
        revisions.append("^" + tip)
    for commit in git("rev-list", *revisions).decode().splitlines():
        scan_tree(commit, checked)
    subprocess.run([GIT, "push", "--no-force", "--no-follow-tags", "--recurse-submodules=no",
                    "origin", revision + ":" + destination], check=True)
    print(revision)


if __name__ == "__main__":
    try:
        publish(sys.argv[1])
    except subprocess.CalledProcessError as error:
        sys.exit(f"Build stopped after Git returned status {error.returncode}.")
