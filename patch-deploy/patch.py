#!/usr/bin/env python3
"""Build and dispatch small, committed Frappe source patches from the control node."""

import argparse
import base64
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path, PurePosixPath


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def allowed(path, app):
    p = PurePosixPath(path)
    blocked = {
        "doctype",
        "patches",
        "migrations",
        "public",
        "config",
        "fixtures",
        "tests",
        "node_modules",
        ".git",
    }
    if (
        p.is_absolute()
        or ".." in p.parts
        or not p.parts
        or p.parts[0] != app
        or blocked.intersection(p.parts)
        or not re.fullmatch(r"[\w./-]+", path)
        or p.name in {"hooks.py", "install.py", "setup.py", "requirements.txt"}
    ):
        return False
    return p.suffix == ".py" or ("prompts" in p.parts and p.suffix in {".md", ".txt"})


def bundle(repo, app, base, commit):
    base = git(repo, "rev-parse", base + "^{commit}").decode().strip()
    commit = git(repo, "rev-parse", commit + "^{commit}").decode().strip()
    git(repo, "merge-base", "--is-ancestor", base, commit)
    # Only committed source participates; no working tree files are read.
    changes = (
        git(repo, "diff", "--no-renames", "--name-status", base, commit)
        .decode()
        .splitlines()
    )
    if not changes:
        raise ValueError("No changes")
    files = []
    for change in changes:
        status, path = change.split("\t")
        if status != "M" or not allowed(path, app):
            raise ValueError("Outside first-version patch scope: " + path)
        for ref in (base, commit):
            mode = git(repo, "ls-tree", ref, "--", path).decode().split()[0]
            if mode != "100644":
                raise ValueError("Only regular source files are supported: " + path)
        before = git(repo, "show", base + ":" + path)
        after = git(repo, "show", commit + ":" + path)
        files.append(
            {
                "path": path,
                "before": base64.b64encode(before).decode(),
                "after": base64.b64encode(after).decode(),
            }
        )
    if sum(len(base64.b64decode(f["after"])) for f in files) > 2 * 1024 * 1024:
        raise ValueError("Patch exceeds 2 MiB")
    return {"app": app, "base": base, "commit": commit, "files": files}


def dispatch(args, request):
    helper = Path(__file__).with_name("remote.py").read_text()
    command = "sudo -n python3 -c " + shlex.quote(helper)
    ssh = ["ssh", "-o", "BatchMode=yes"]
    if args.identity:
        ssh += ["-i", args.identity]
    ssh += [args.host, command]
    if request["action"] == "apply":
        prepared = subprocess.run(
            ssh,
            input=json.dumps({**request, "action": "prepare"}),
            text=True,
            stdout=subprocess.PIPE,
            check=False,
        )
        record = json.loads(prepared.stdout)
        if prepared.returncode:
            print(json.dumps(record))
            return prepared.returncode
        backup = record["backup"]
        directory = Path(args.records) / args.host.replace("@", "_") / args.project
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = directory / (request["id"] + ".json")
        # Do not modify any containers until the off-host backup is safely written.
        with open(
            target, "w", opener=lambda p, flags: os.open(p, flags | os.O_EXCL, 0o600)
        ) as f:
            json.dump(backup, f)
            f.flush()
            os.fsync(f.fileno())
    result = subprocess.run(
        ssh, input=json.dumps(request), text=True, stdout=subprocess.PIPE, check=False
    )
    if result.stdout:
        print(json.dumps(json.loads(result.stdout), ensure_ascii=False))
    return result.returncode


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "action", choices=["check", "apply", "rollback", "status", "verify-upgrade"]
    )
    p.add_argument(
        "--host", required=True, help="Existing SSH identity, e.g. ubuntu@host"
    )
    p.add_argument("--identity")
    p.add_argument("--project", default="frappe-customer")
    p.add_argument("--app", default="tai")
    p.add_argument("--repo", type=Path)
    p.add_argument("--base", help="Source commit represented by the running image")
    p.add_argument("--commit", help="Committed patch / proposed formal release commit")
    p.add_argument("--id", help="Patch identifier returned by check/apply")
    p.add_argument("--records", default="/srv/tsuite-deploy/backups/patches")
    p.add_argument(
        "--site", help="Site for database-backed post-restart health verification"
    )
    args = p.parse_args()
    if args.host.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_.@-]+", args.host):
        p.error("Invalid SSH host")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.app):
        p.error("Invalid app")
    request = {
        "action": args.action,
        "project": args.project,
        "app": args.app,
        "site": args.site,
        "id": args.id,
    }
    if args.action in {"check", "apply"}:
        if not all((args.repo, args.base, args.commit, args.site)):
            p.error("check/apply require --repo --base --commit --site")
        git(args.repo, "fetch", "--no-tags", "origin")
        request.update(bundle(args.repo, args.app, args.base, args.commit))
        if not git(
            args.repo,
            "for-each-ref",
            "--contains=" + request["commit"],
            "--format=%(refname)",
            "refs/remotes/origin",
        ).strip():
            p.error("Patch commit must be present in a fetched origin branch")
        request["id"] = args.id or (args.app + "-" + request["commit"][:12])
    if args.action == "rollback" and not args.id:
        p.error("rollback requires --id")
    if args.action == "verify-upgrade":
        if not args.repo or not args.commit:
            p.error("verify-upgrade requires --repo --commit")
        # Obtain the ledger first, then check ancestry locally without shipping credentials.
        helper = Path(__file__).with_name("remote.py").read_text()
        ssh = ["ssh", "-o", "BatchMode=yes"] + (
            ["-i", args.identity] if args.identity else []
        )
        r = subprocess.run(
            ssh + [args.host, "sudo -n python3 -c " + shlex.quote(helper)],
            input=json.dumps({**request, "action": "status"}),
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        )
        for record in json.loads(r.stdout)["patches"]:
            if record["status"] in {"applying", "rolling_back", "rollback_failed"}:
                p.error("Resolve the incomplete patch before a formal upgrade")
            if record["status"] == "applied" and record["app"] == args.app:
                git(
                    args.repo,
                    "merge-base",
                    "--is-ancestor",
                    record["commit"],
                    args.commit,
                )
        print("Proposed release includes all active patches for this app")
        return 0
    return dispatch(args, request)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
