"""Host-side transaction helper; dispatched over SSH, no installation required."""

import base64
import fcntl
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
from pathlib import Path, PurePosixPath

ROOT = Path("/opt/tsuite-deploy/patches")
PYTHON = "/home/frappe/frappe-bench/env/bin/python"
READ = """import sys,json,pathlib,base64,os
r=json.load(sys.stdin);root=pathlib.Path('/home/frappe/frappe-bench/apps')/r['app'];out=[]
for f in r['files']:
 p=root/f['path']
 if p.is_symlink() or not p.resolve().is_relative_to(root.resolve()):raise ValueError('Unsafe source path')
 s=p.stat();b=p.read_bytes()
 if p.suffix=='.py':compile(base64.b64decode(f['after']),str(p),'exec')
 out.append(dict(path=f['path'],data=base64.b64encode(b).decode(),mode=s.st_mode&0o777,uid=s.st_uid,gid=s.st_gid))
print(json.dumps(out))
"""
HEALTH = """import os,sys,frappe
os.chdir('/home/frappe/frappe-bench/sites');frappe.init(site=sys.argv[1]);frappe.connect()
frappe.db.sql('SELECT 1');__import__(sys.argv[2]);frappe.destroy()
"""
IDLE = """import os,sys,frappe
os.chdir('/home/frappe/frappe-bench/sites');frappe.init(site=sys.argv[1])
from frappe.utils.background_jobs import get_redis_conn
from rq import Worker
assert not any(w.get_state()=='busy' for w in Worker.all(connection=get_redis_conn())), 'Background jobs are busy'
frappe.destroy()
"""


def run(*args, data=None):
    p = subprocess.run(
        list(args), input=data, capture_output=True, check=False, timeout=120
    )
    if p.returncode:
        # Commands can contain committed source; avoid reflecting arguments or credential-bearing errors.
        raise RuntimeError("Command failed: " + args[0])
    return p.stdout


def inspect(names):
    return json.loads(run("docker", "inspect", *names))


def containers(project, require_running=True):
    names = (
        run(
            "docker",
            "ps",
            "-a",
            "--filter",
            "label=com.docker.compose.project=" + project,
            "--format",
            "{{.ID}}",
        )
        .decode()
        .splitlines()
    )
    if not names:
        raise ValueError("Compose project not found")
    rows = inspect(names)
    selected = [
        r
        for r in rows
        if r["Config"]["Labels"].get("com.docker.compose.service")
        in {"backend", "frontend", "websocket", "scheduler"}
        or r["Config"]["Labels"]
        .get("com.docker.compose.service", "")
        .startswith("queue-")
    ]
    if not any(
        r["Config"]["Labels"].get("com.docker.compose.service") == "backend"
        for r in selected
    ):
        raise ValueError("Backend not found")
    if len({r["Image"] for r in selected}) != 1 or (
        require_running
        and not all(
            r["State"]["Running"] and not r["State"].get("Restarting") for r in selected
        )
    ):
        raise ValueError("Application containers must be running with the same image")
    return selected


def read(request, rows):
    return {
        r["Id"]: json.loads(
            run(
                "docker",
                "exec",
                "-i",
                r["Id"],
                PYTHON,
                "-c",
                READ,
                data=json.dumps(request).encode(),
            )
        )
        for r in rows
    }


def verify(request, rows, side):
    snapshots = read(request, rows)
    expected = {f["path"]: f[side] for f in request["files"]}
    if any(
        f["data"] != expected[f["path"]] for files in snapshots.values() for f in files
    ):
        raise ValueError("Container source differs from expected " + side + " revision")
    return snapshots


def backend(rows):
    return next(
        r["Id"]
        for r in rows
        if r["Config"]["Labels"].get("com.docker.compose.service") == "backend"
    )


def save(path, state):
    temp = path.with_suffix(".tmp")
    with open(temp, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def write(cid, app, files):
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for f in files:
            data = base64.b64decode(f["data"])
            info = tarfile.TarInfo(
                "home/frappe/frappe-bench/apps/" + app + "/" + f["path"]
            )
            info.size = len(data)
            info.mode = f["mode"]
            info.uid = f["uid"]
            info.gid = f["gid"]
            tar.addfile(info, io.BytesIO(data))
    run("docker", "cp", "-a", "-", cid + ":/", data=archive.getvalue())


def health(request, rows):
    limit = time.monotonic() + 60
    while True:
        try:
            current = inspect([r["Id"] for r in rows])
            if not all(
                r["State"]["Running"]
                and not r["State"].get("Restarting")
                and r["State"].get("Health", {}).get("Status", "healthy") == "healthy"
                for r in current
            ):
                raise RuntimeError("Containers not healthy")
            run(
                "docker",
                "exec",
                backend(rows),
                PYTHON,
                "-c",
                HEALTH,
                request["site"],
                request["app"],
            )
            return
        except RuntimeError:
            if time.monotonic() >= limit:
                raise
            time.sleep(2)


def restore(state, path):
    request = state["request"]
    rows = state["containers"]
    ids = [r["Id"] for r in rows]
    state["status"] = "rolling_back"
    save(path, state)
    run("docker", "stop", *ids)
    for cid, files in state["original"].items():
        write(cid, request["app"], files)
    run("docker", "start", *ids)
    health(request, rows)
    verify(request, rows, "before")
    state["status"] = "rolled_back"
    save(path, state)


def process(request, directory):
    action = request["action"]
    records = [json.loads(p.read_text()) for p in directory.glob("*.json")]
    if action == "status":
        return {
            "patches": [
                {k: s[k] for k in ("id", "app", "commit", "status", "image")}
                for s in records
            ]
        }
    ident = request.get("id")
    if not ident or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", ident):
        raise ValueError("Invalid patch ID")
    path = directory / (ident + ".json")
    if action == "rollback":
        state = json.loads(path.read_text())
        if state["status"] not in {
            "applied",
            "applying",
            "rollback_failed",
            "rolling_back",
        }:
            raise ValueError("Patch is not active")
        current = containers(request["project"], require_running=False)
        if {r["Id"] for r in current} != {r["Id"] for r in state["containers"]}:
            raise ValueError(
                "Containers recreated; cannot restore this backup into a different image"
            )
        if state["status"] == "applied":
            verify(state["request"], current, "after")
        restore(state, path)
        return {"id": ident, "status": state["status"]}
    # Defense in depth: direct helper invocations cannot bypass the patch scope.
    app = request["app"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", app):
        raise ValueError("Invalid app")
    if not request.get("site") or not request.get("files"):
        raise ValueError("Missing site/files")
    for f in request["files"]:
        p = PurePosixPath(f["path"])
        if (
            p.is_absolute()
            or ".." in p.parts
            or p.parts[0] != app
            or {
                "doctype",
                "patches",
                "migrations",
                "public",
                "config",
                "fixtures",
                "tests",
                ".git",
            }.intersection(p.parts)
            or p.name in {"hooks.py", "install.py", "setup.py", "requirements.txt"}
            or not (
                p.suffix == ".py"
                or ("prompts" in p.parts and p.suffix in {".md", ".txt"})
            )
        ):
            raise ValueError("File outside patch scope")
    if any(
        s["status"] in {"applied", "applying", "rolling_back", "rollback_failed"}
        for s in records
    ):
        raise ValueError("Resolve the existing active patch before deploying another")
    rows = containers(request["project"])
    original = verify(request, rows, "before")
    run("docker", "exec", backend(rows), PYTHON, "-c", IDLE, request["site"])
    if action == "check":
        return {
            "id": ident,
            "status": "checked",
            "containers": len(rows),
            "files": len(request["files"]),
        }
    if action == "prepare":
        if path.exists():
            raise ValueError("Patch ID already exists; use a new ID")
        state = {
            "id": ident,
            "app": app,
            "commit": request["commit"],
            "status": "prepared",
            "image": rows[0]["Config"]["Image"],
            "image_id": rows[0]["Image"],
            "containers": rows,
            "request": request,
            "original": original,
        }
        # Store only identity fields, not Docker environment values / secrets.
        state["containers"] = [
            {
                "Id": r["Id"],
                "Config": {
                    "Labels": {
                        "com.docker.compose.service": r["Config"]["Labels"][
                            "com.docker.compose.service"
                        ]
                    }
                },
            }
            for r in rows
        ]
        save(path, state)
        return {"id": ident, "status": "prepared", "backup": state}
    if action != "apply":
        raise ValueError("Unknown action")
    state = json.loads(path.read_text())
    if state["status"] != "prepared" or any(
        state["request"][k] != request[k]
        for k in ("files", "base", "commit", "app", "site")
    ):
        raise ValueError("Prepared patch does not match request")
    if {r["Id"] for r in rows} != {r["Id"] for r in state["containers"]}:
        raise ValueError("Containers changed after backup")
    state["status"] = "applying"
    save(path, state)
    try:
        run("docker", "stop", *[r["Id"] for r in rows])
        for r in rows:
            files = [
                {
                    **f,
                    "data": next(
                        n["after"] for n in request["files"] if n["path"] == f["path"]
                    ),
                }
                for f in original[r["Id"]]
            ]
            write(r["Id"], app, files)
        run("docker", "start", *[r["Id"] for r in rows])
        health(request, rows)
        verify(request, rows, "after")
        state["status"] = "applied"
        save(path, state)
    except BaseException:
        try:
            restore(state, path)
        except BaseException:  # noqa: BLE001 -- persist recovery failure even on interruption
            state["status"] = "rollback_failed"
            save(path, state)
        raise
    return {"id": ident, "status": state["status"], "containers": len(rows)}


def main():
    request = json.load(sys.stdin)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", request["project"]):
        raise ValueError("Invalid project")
    directory = ROOT / request["project"]
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(directory / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return process(request, directory)


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except Exception as e:  # noqa: BLE001 -- CLI emits a sanitized failure envelope
        print(json.dumps({"status": "failed", "error": str(e)}))
        sys.exit(1)
