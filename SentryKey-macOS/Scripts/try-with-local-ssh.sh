#!/bin/bash
# Tries the development agent with a real ssh client and a real sshd.
#
# Starts a throwaway sshd on 127.0.0.1 with its own configuration, host key
# and authorized_keys in a temporary folder, then logs in through
# sentrykey-agent-dev with each behaviour of the stand-in phone. Only the
# "approve" behaviour may get in.
#
# Nothing outside the temporary folder is read or written: your ~/.ssh and
# the system sshd are not involved. The login runs as you, on this machine.
#
# Usage: Scripts/try-with-local-ssh.sh [--with-timeout]
#   --with-timeout  also tries the phone that never answers (waits 45 s).
set -euo pipefail

cd "$(dirname "$0")/.."

with_timeout=no
if [ "${1:-}" = "--with-timeout" ]; then with_timeout=yes; fi

swift build --product sentrykey-agent-dev >&2
agent_binary="$(swift build --show-bin-path)/sentrykey-agent-dev"

# /tmp rather than $TMPDIR: a socket path is limited to about 100 bytes.
work="$(mktemp -d /tmp/sentrykey-try.XXXXXX)"
socket="$work/agent/agent.sock"
port=$((20000 + RANDOM % 20000))
agent_pid=""
sshd_pid=""

cleanup() {
    [ -n "$agent_pid" ] && kill "$agent_pid" 2>/dev/null || true
    [ -n "$sshd_pid" ] && kill "$sshd_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$work/host_key"
cat > "$work/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $work/host_key
AuthorizedKeysFile $work/authorized_keys
PidFile $work/sshd.pid
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

start_agent() {
    "$agent_binary" --socket "$socket" --behaviour "$1" > "$work/public_key" 2> "$work/agent.log" &
    agent_pid=$!
    for _ in $(seq 1 100); do
        [ -S "$socket" ] && [ -s "$work/public_key" ] && return 0
        kill -0 "$agent_pid" 2>/dev/null || break
        perl -e 'select(undef, undef, undef, 0.05)'
    done
    echo "the agent did not start:" >&2
    cat "$work/agent.log" >&2
    exit 1
}

stop_agent() {
    kill "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
    agent_pid=""
}

login() {
    ssh -F /dev/null -p "$port" \
        -o IdentityAgent="$socket" \
        -o IdentityFile=none \
        -o PreferredAuthentications=publickey \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$work/known_hosts" \
        -o ConnectTimeout=5 \
        127.0.0.1 'echo LOGIN-OK' 2> "$work/ssh.log"
}

failures=0
check() {
    local behaviour="$1" expected="$2" result
    start_agent "$behaviour"
    # Each agent start makes a new key: the server must trust this one.
    cp "$work/public_key" "$work/authorized_keys"
    if [ "$(login || true)" = "LOGIN-OK" ]; then result=accepted; else result=refused; fi
    stop_agent
    if [ "$result" = "$expected" ]; then
        echo "ok    phone=$behaviour: login $result"
    else
        echo "FAIL  phone=$behaviour: login $result, expected $expected"
        sed 's/^/        ssh:   /' "$work/ssh.log"
        sed 's/^/        agent: /' "$work/agent.log"
        failures=$((failures + 1))
    fi
}

/usr/sbin/sshd -D -e -f "$work/sshd_config" 2> "$work/sshd.log" &
sshd_pid=$!
for _ in $(seq 1 100); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    if ! kill -0 "$sshd_pid" 2>/dev/null; then
        echo "sshd did not start:" >&2
        cat "$work/sshd.log" >&2
        exit 1
    fi
    perl -e 'select(undef, undef, undef, 0.05)'
done

check approve accepted
check deny refused
check wrong-key refused
check unreachable refused
if [ "$with_timeout" = yes ]; then check silent refused; fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed. sshd log:" >&2
    cat "$work/sshd.log" >&2
    exit 1
fi
echo "All checks passed."
