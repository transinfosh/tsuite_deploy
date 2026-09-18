"""Portable Linux support terminal; authorization uses HTTPS, terminal uses edge SSH."""

import fcntl
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import time
import types
import urllib.parse
import urllib.request

# The console embeds both sources; filesystem execution uses the adjacent module.
CLIENT_SOURCE = globals().get("CLIENT_SOURCE") or pathlib.Path(__file__).read_text(encoding="utf-8")
ACTIVITY_SOURCE = globals().get("ACTIVITY_SOURCE") or pathlib.Path(__file__).with_name(
    "tsuite_support_activity.py"
).read_text(encoding="utf-8")

SESSION_RE = re.compile(r"[a-f0-9]{12}")
KEY_RE = re.compile(r"(ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+")


class AuthorizationRevoked(ValueError):
    pass


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(value)


def claim(grant, public_key):
    url = urllib.parse.urlsplit(grant["url"])
    if (
        url.scheme != "https"
        or not url.hostname
        or url.username
        or url.password
        or url.query
        or url.fragment
        or url.path != "/support"
    ):
        raise ValueError("Invalid authorization URL")
    body = json.dumps({"id": grant["id"], "token": grant["token"], "public_key": public_key}).encode()
    request = urllib.request.Request(
        grant["url"] + "/operator-claim", data=body, headers={"Content-Type": "application/json"}
    )

    # A redirect must never forward the bearer grant to another URL.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args):
            return None

    with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
        raw = response.read(32769)
    if len(raw) > 32768:
        raise ValueError("Authorization response too large")
    result = json.loads(raw)
    if (
        result.get("id") != grant["id"]
        or not re.fullmatch(r"[A-Za-z0-9.-]+", result.get("host", ""))
        or result.get("user") != "tsuite-operator"
        or type(result.get("port")) is not int
        or not 1 <= result["port"] <= 65535
        or not re.fullmatch(
            r"ssh-ed25519-cert-v01@openssh.com [A-Za-z0-9+/=]+(?: [^\r\n]*)?", result.get("certificate", "")
        )
        or not isinstance(result.get("known_hosts"), str)
        or not result["known_hosts"].strip()
    ):
        raise ValueError("Invalid authorization response")
    return result


def edge_arguments(root, settings):
    return [
        "ssh",
        "-F",
        "none",
        "-T",
        "-i",
        str(root / "identity"),
        "-o",
        f"CertificateFile={root / 'identity-cert.pub'}",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={root / 'edge_known_hosts'}",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=3",
        "-p",
        str(settings["port"]),
        f"{settings['user']}@{settings['host']}",
    ]


def session_status(root, settings):
    response = subprocess.run(
        [*edge_arguments(root, settings), "show", settings["id"]], text=True, capture_output=True, timeout=20
    )
    if response.returncode:
        if "Permission denied (publickey" in response.stderr:
            raise AuthorizationRevoked("会话授权已撤销或过期。")
        raise ValueError("Edge 无法连接，请检查网络和网页状态。")
    remote = json.loads(response.stdout)
    if remote.get("id") != settings["id"] or type(remote.get("expires_at")) is not int:
        raise ValueError("Invalid session status")
    return remote


def cleanup_watch(root, settings):
    # One local watcher per session. Status polling never renews the customer lease.
    with (root / ".watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        deadline = settings["expires_at"]
        while root.is_dir():
            try:
                remote = session_status(root, settings)
                if remote.get("status") not in {"issued", "enrolled"}:
                    shutil.rmtree(root)
                    return 0
                deadline = remote["expires_at"]
            except AuthorizationRevoked:
                shutil.rmtree(root, ignore_errors=True)
                return 0
            except (ValueError, OSError, subprocess.SubprocessError):
                pass
            if time.time() >= deadline:
                # Fail closed after the last confirmed lease if the network is unavailable.
                shutil.rmtree(root)
                return 0
            time.sleep(min(30, max(1, deadline - time.time())))
    return 0


def wait_for_customer(root, settings):
    print("等待客户接入…", file=sys.stderr)
    while True:
        remote = session_status(root, settings)
        if (
            remote.get("id") != settings["id"]
            or remote.get("status") not in {"issued", "enrolled"}
            or type(remote.get("expires_at")) is not int
            or time.time() >= remote["expires_at"]
        ):
            raise ValueError("会话已经结束或过期。")
        if remote["status"] == "enrolled" and remote.get("tunnel_reachable") is True:
            if (
                not KEY_RE.fullmatch(remote.get("customer_host_key", ""))
                or type(remote.get("remote_port")) is not int
                or not 1024 <= remote["remote_port"] <= 65535
                or remote.get("platform") not in {"linux", "windows"}
            ):
                raise ValueError("Invalid customer connection metadata")
            return remote
        time.sleep(3)


def connect(root, settings, remote, command):
    port = remote["remote_port"]
    host_line = f"[127.0.0.1]:{port} {remote['customer_host_key']}\n"
    known_hosts = root / "customer_known_hosts"
    if known_hosts.exists():
        if known_hosts.read_text() != host_line:
            raise ValueError("客户主机密钥发生变化，拒绝连接。")
    else:
        write_private(known_hosts, host_line)
    proxy = shlex.join([*edge_arguments(root, settings), "proxy", settings["id"]])
    arguments = [
        "ssh",
        "-F",
        "none",
        "-i",
        str(root / "identity"),
        "-o",
        f"CertificateFile={root / 'identity-cert.pub'}",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        f"ProxyCommand={proxy}",
        "-p",
        str(port),
        f"tsuite-ops-{settings['id'][:8]}@127.0.0.1",
    ]
    base = list(arguments)
    if command:
        # This option deliberately accepts a remote shell command, as ssh does.
        arguments.append(command)
    activity = types.ModuleType("tsuite_support_activity")
    exec(ACTIVITY_SOURCE, activity.__dict__)
    environment = os.environ.copy()
    environment["SHELL"] = "/bin/sh"
    return activity.connect(
        arguments, base, remote["platform"], settings["id"], running_command=bool(command), env=environment
    )


def main():
    if not shutil.which("ssh") or not shutil.which("ssh-keygen"):
        raise ValueError("支持机需要 Python 3 和 OpenSSH Client（ssh、ssh-keygen）。")
    if len(sys.argv) > 1 and sys.argv[1] == "--watch":
        root = pathlib.Path(__file__).resolve().parent
        settings = json.loads((root / "session.json").read_text())
        return cleanup_watch(root, settings)
    if len(sys.argv) > 1 and sys.argv[1] == "--resume":
        root = pathlib.Path(__file__).resolve().parent
        settings = json.loads((root / "session.json").read_text())
        command = sys.argv[2] if len(sys.argv) > 2 else None
    else:
        raw = sys.stdin.buffer.read(8193)
        if len(raw) > 8192:
            raise ValueError("Invalid grant")
        grant = json.loads(raw)
        if not isinstance(grant, dict) or not SESSION_RE.fullmatch(grant.get("id", "")):
            raise ValueError("Invalid session ID")
        parent = (
            pathlib.Path(os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
            / "tsuite-support/portable"
        )
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        root = parent / grant["id"]
        root.mkdir(mode=0o700)  # Never replace a claimed identity or follow an existing session symlink.
        try:
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "identity")],
                check=True,
                stdin=subprocess.DEVNULL,
            )
            public_key = " ".join((root / "identity.pub").read_text().split()[:2])
            settings = claim(grant, public_key)
            write_private(root / "identity-cert.pub", settings.pop("certificate") + "\n")
            write_private(root / "edge_known_hosts", settings.pop("known_hosts"))
            write_private(root / "session.json", json.dumps(settings))
            write_private(
                root / "support.py",
                "CLIENT_SOURCE = "
                + repr(CLIENT_SOURCE)
                + "\nACTIVITY_SOURCE = "
                + repr(ACTIVITY_SOURCE)
                + "\n"
                + CLIENT_SOURCE,
            )
        except BaseException:
            shutil.rmtree(root)
            raise
        grant.clear()
        command = None
        print(
            "授权已领取。再次连接命令：\n" + shlex.join(["python3", str(root / "support.py"), "--resume"]),
            file=sys.stderr,
        )
    subprocess.Popen(
        ["python3", str(root / "support.py"), "--watch"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    # The bootstrap pipe carries only the grant. Real terminal input comes from the local tty.
    if not command:
        sys.stdin = open("/dev/tty", "r")
    try:
        remote = wait_for_customer(root, settings)
        return connect(root, settings, remote, command)
    except AuthorizationRevoked:
        shutil.rmtree(root, ignore_errors=True)
        raise


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Do not print HTTP bodies or grants; they may contain bearer credentials.
        print("支持连接失败：" + str(error), file=sys.stderr)
        raise SystemExit(1)
