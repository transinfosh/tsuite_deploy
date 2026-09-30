"""Verify portable certificates with two isolated local sshd processes (requires sudo)."""

import argparse, getpass, json, pathlib, shlex, shutil, socket, subprocess, tempfile, time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--operator-pwsh", help="Also exercise the native operator's SSH construction via pwsh")
options = parser.parse_args()

r = pathlib.Path(__file__).resolve().parents[2]
processes = []
username = getpass.getuser()


def key(p):
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(p)], check=True)
    return " ".join(pathlib.Path(str(p) + ".pub").read_text().split()[:2])


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


with tempfile.TemporaryDirectory(prefix="portable-sshd-", dir=pathlib.Path.home()) as d:
    root = pathlib.Path(d)
    ca = key(root / "ca")
    host = key(root / "host")
    key(root / "operator")
    wrong = key(root / "wrong")
    subprocess.run(
        [
            "ssh-keygen",
            "-q",
            "-s",
            str(root / "ca"),
            "-I",
            "portable-test",
            "-n",
            "012345abcdef",
            "-V",
            "-1m:forever",
            "-O",
            "clear",
            "-O",
            "permit-pty",
            str(root / "operator.pub"),
        ],
        check=True,
    )
    cp, ep = (port(), port())
    expiry = time.strftime("%Y%m%d%H%M%SZ", time.gmtime(time.time() + 300))
    customer_keys = root / "customer_keys"
    customer_keys.write_text(
        f'cert-authority,principals="012345abcdef",expiry-time="{expiry}",from="127.0.0.1",no-port-forwarding {ca}\n'
    )
    session = {
        "id": "012345abcdef",
        "status": "enrolled",
        "tunnel_reachable": True,
        "expires_at": int(time.time()) + 300,
        "remote_port": cp,
    }
    (root / "session.json").write_text(json.dumps(session))
    relay = root / "relay.py"
    relay.write_text(
        'import importlib.util,json,pathlib\ns=importlib.util.spec_from_file_location("relay",'
        + repr(str(r / "support-session/bastion/tsuite_support_console_action.py"))
        + ")\nm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\nm.manager_output=lambda *args:pathlib.Path("
        + repr(str(root / "session.json"))
        + ').read_text()\nraise SystemExit(m.relay_session("012345abcdef"))\n'
    )
    edge_keys = root / "edge_keys"
    edge_keys.write_text(
        f'cert-authority,principals="012345abcdef",expiry-time="{expiry}",restrict,command="python3 {relay}" {ca}\n'
    )

    def start(name, listen, keys):
        config = root / (name + ".conf")
        config.write_text(
            f"Port {listen}\nListenAddress 127.0.0.1\nHostKey {root}/host\nPidFile {root}/{name}.pid\nAuthorizedKeysFile {keys}\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM yes\nStrictModes yes\nLogLevel VERBOSE\nAllowUsers {username}\n"
        )
        log = (root / (name + ".log")).open("w")
        p = subprocess.Popen(
            ["sudo", "-n", "/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log
        )
        processes.append(p)
        for _ in range(30):
            try:
                with socket.create_connection(("127.0.0.1", listen), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError((root / (name + ".log")).read_text())

    known = root / "known_hosts"
    known.write_text(f"[127.0.0.1]:{cp} {host}\n[127.0.0.1]:{ep} {host}\n")

    def ssh(p, identity="operator"):
        return [
            "ssh",
            "-F",
            "none",
            "-i",
            str(root / identity),
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={known}",
            "-o",
            "ConnectTimeout=3",
            "-p",
            str(p),
            f"{username}@127.0.0.1",
        ]

    def check(args, ok, needle=None):
        result = subprocess.run(args, text=True, capture_output=True, timeout=10)
        assert (result.returncode == 0) == ok, (
            args,
            result.stdout,
            result.stderr,
            [(log.name, log.read_text()) for log in root.glob("*.log")],
        )
        if needle:
            assert needle in result.stdout, (result.stdout, result.stderr)

    try:
        start("customer", cp, customer_keys)
        start("edge", ep, edge_keys)
        check([*ssh(cp), "printf certificate-ok"], True, "certificate-ok")
        proxy = shlex.join([*ssh(ep), "proxy", "012345abcdef"])
        direct = ssh(cp)
        direct[1:1] = ["-o", f"ProxyCommand={proxy}"]
        check([*direct, "printf direct-edge-customer-ok"], True, "direct-edge-customer-ok")
        check([*ssh(ep), "show", "012345abcdef"], True, "012345abcdef")
        check([*ssh(ep), "proxy", "fedcba543210"], False)
        check([*ssh(ep), "id"], False)
        check([*ssh(cp, "wrong"), "true"], False)
        if options.operator_pwsh:
            native = root / "native operator space"
            native.mkdir(mode=0o700)
            for source, destination in (("operator", "identity"), ("operator-cert.pub", "identity-cert.pub")):
                shutil.copyfile(root / source, native / destination)
                (native / destination).chmod(0o600)
            (native / "edge_known_hosts").write_text(f"[127.0.0.1]:{ep} {host}\n")

            def ps_quote(value):
                return "'" + str(value).replace("'", "''") + "'"

            powershell = root / "native-smoke.ps1"
            powershell.write_text(
                "$ErrorActionPreference = 'Stop'\n. "
                + ps_quote(r / "support-session/operator/tsuite_support_windows.ps1")
                + " -Mode Library\nInitialize-OperatorRelay\n$root = " + ps_quote(native)
                + "\n$tools = [pscustomobject]@{ Ssh = " + ps_quote(shutil.which("ssh")) + " }\n"
                + f"$settings = [pscustomobject]@{{id = '012345abcdef'; host = '127.0.0.1'; port = {ep}; user = '{username}'}}\n"
                + "$status = Get-OperatorStatus $root $settings $tools\n"
                + "if ($status.id -cne $settings.id) { throw 'Status certificate login failed.' }\n"
                + f"$remote = [pscustomobject]@{{remote_port = {cp}; customer_host_key = '{host}'}}\n"
                + "$arguments = [string[]](Get-OperatorCustomerArguments $root $settings $remote $tools)\n"
                # The fixture uses only the current user and never creates a support account.
                + f"$arguments[$arguments.Length - 1] = '{username}@127.0.0.1'\n"
                + "$result = [TSuiteSupport.WindowsRelay]::Capture($tools.Ssh, [string[]](@('-T') + $arguments + @('printf native-certificate-proxy-ok')), 20000)\n"
                + "if ($result.ExitCode -ne 0 -or $result.Output -cne 'native-certificate-proxy-ok') { throw ('Native SSH proxy failed: ' + $result.Error) }\n"
                + "[IO.File]::WriteAllText((Join-Path $root 'customer_known_hosts'), '[127.0.0.1]:"
                + str(cp) + " " + wrong + "')\n"
                + "$result = [TSuiteSupport.WindowsRelay]::Capture($tools.Ssh, [string[]](@('-T') + $arguments + @('true')), 20000)\n"
                + "if ($result.ExitCode -eq 0) { throw 'Changed pinned host key was accepted.' }\n"
                + "Write-Output 'Native PowerShell/C# real certificate login, Edge proxy and pinned host rejection: PASS'\n"
            )
            subprocess.run([options.operator_pwsh, "-NoProfile", "-File", str(powershell)], check=True, timeout=45)
        expired = time.strftime("%Y%m%d%H%M%SZ", time.gmtime(time.time() - 60))
        customer_keys.write_text(customer_keys.read_text().replace(expiry, expired))
        check([*ssh(cp), "true"], False)
        customer_keys.write_text(f'cert-authority,principals="fedcba543210",expiry-time="{expiry}" {ca}\n')
        check([*ssh(cp), "true"], False)
        edge_keys.write_text("")
        check([*ssh(ep), "show", "012345abcdef"], False)
        print(
            "Real OpenSSH integration: certificate login, direct edge proxy, status, cross-session rejection, shell rejection, wrong key, native expiry and revocation: PASS"
        )
    finally:
        for p in processes:
            p.terminate()
        for p in processes:
            p.wait(timeout=10)
