#!/usr/bin/env bash
set -Eeuo pipefail

for command_name in ssh sshd ssh-keygen python3; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf '跳过：缺少 %s\n' "$command_name"
		exit 0
	}
done

work_dir="$(mktemp -d /tmp/tsuite-support-ssh-test.XXXXXX)"
sshd_pid=""
tunnel_pid=""
cleanup() {
	[[ -z "$tunnel_pid" ]] || kill "$tunnel_pid" 2>/dev/null || true
	[[ -z "$sshd_pid" ]] || kill "$sshd_pid" 2>/dev/null || true
	[[ -z "$tunnel_pid" ]] || wait "$tunnel_pid" 2>/dev/null || true
	[[ -z "$sshd_pid" ]] || wait "$sshd_pid" 2>/dev/null || true
	find "$work_dir" -mindepth 1 -delete
	rmdir "$work_dir"
}
trap cleanup EXIT

read -r sshd_port allowed_port denied_port < <(python3 - <<'PY'
import socket

ports = []
for _ in range(3):
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    ports.append(probe.getsockname()[1])
    probe.close()
print(*ports)
PY
)
ssh-keygen -q -t ed25519 -N '' -f "$work_dir/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$work_dir/client_key"
ssh-keygen -q -t ed25519 -N '' -f "$work_dir/enrollment_key"
printf 'command="/usr/sbin/nologin",restrict,port-forwarding,permitlisten="127.0.0.1:%s",expiry-time="20990101000000Z" %s\n' \
	"$allowed_port" "$(cat "$work_dir/client_key.pub")" >"$work_dir/authorized_keys"
printf 'command="printf enrollment-only",restrict,expiry-time="20990101000000Z" %s\n' \
	"$(cat "$work_dir/enrollment_key.pub")" >>"$work_dir/authorized_keys"
cat >"$work_dir/sshd_config" <<EOF
Port $sshd_port
ListenAddress 127.0.0.1
HostKey $work_dir/host_key
PidFile $work_dir/sshd.pid
AuthorizedKeysFile $work_dir/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowTcpForwarding remote
GatewayPorts no
PermitTTY no
X11Forwarding no
AllowAgentForwarding no
PermitUserRC no
MaxSessions 1
EOF
/usr/sbin/sshd -D -e -f "$work_dir/sshd_config" >"$work_dir/sshd.log" 2>&1 &
sshd_pid=$!
for _ in {1..50}; do
	kill -0 "$sshd_pid" 2>/dev/null || {
		cat "$work_dir/sshd.log" >&2
		exit 1
	}
	if ssh-keyscan -p "$sshd_port" 127.0.0.1 >/dev/null 2>&1; then
		break
	fi
	sleep 0.05
done

common_args=(
	-F none -i "$work_dir/client_key" -o IdentitiesOnly=yes -o BatchMode=yes
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
	-o ExitOnForwardFailure=yes -p "$sshd_port" "$(id -un)@127.0.0.1"
)
ssh -NT "${common_args[@]}" -R "127.0.0.1:$allowed_port:127.0.0.1:22" &
tunnel_pid=$!
sleep 0.2
kill -0 "$tunnel_pid"

if ssh -NT "${common_args[@]}" -R "127.0.0.1:$denied_port:127.0.0.1:22" 2>/dev/null; then
	printf '错误：隧道密钥可以监听未授权端口\n' >&2
	exit 1
fi
if ssh "${common_args[@]}" true >/dev/null 2>&1; then
	printf '错误：隧道密钥可以创建远端 shell\n' >&2
	exit 1
fi

enrollment_output="$(ssh -F none -T -i "$work_dir/enrollment_key" \
	-o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$sshd_port" \
	"$(id -un)@127.0.0.1" bootstrap)"
[[ "$enrollment_output" == "enrollment-only" ]]
if ssh -NT -F none -i "$work_dir/enrollment_key" -o IdentitiesOnly=yes \
	-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o LogLevel=ERROR -o ExitOnForwardFailure=yes -p "$sshd_port" \
	-R "127.0.0.1:$denied_port:127.0.0.1:22" "$(id -un)@127.0.0.1" 2>/dev/null; then
	printf '错误：enrollment key 可以创建端口转发\n' >&2
	exit 1
fi
