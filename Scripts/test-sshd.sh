#!/bin/bash
# Starts a throwaway sshd on 127.0.0.1:2222 (as the current user, no root
# needed) and prints the environment the live tests expect. Usage:
#
#   Scripts/test-sshd.sh start   # starts sshd, writes .build/test-sshd/env.sh
#   source .build/test-sshd/env.sh && swift test --filter Live
#   Scripts/test-sshd.sh stop
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/.build/test-sshd"
PORT="${TEPFA_TEST_SSH_PORT:-2222}"

case "${1:-}" in
  start)
    mkdir -p "$DIR"
    [ -f "$DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "tepfa-test-host" -f "$DIR/host_ed25519"
    [ -f "$DIR/user_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "tepfa-test-user" -f "$DIR/user_ed25519"
    cp "$DIR/user_ed25519.pub" "$DIR/authorized_keys"
    chmod 600 "$DIR/authorized_keys"
    cat > "$DIR/sshd_config" <<CONF
Port $PORT
ListenAddress 127.0.0.1
HostKey "$DIR/host_ed25519"
AuthorizedKeysFile "$DIR/authorized_keys"
PidFile "$DIR/sshd.pid"
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel VERBOSE
# The live tests connect concurrently and some of them abort on purpose
# (declined host keys): never drop pending connections at random, and do not
# penalise 127.0.0.1 for the aborted ones (OpenSSH 9.8+ does by default).
MaxStartups 100
PerSourcePenalties no
CONF
    # Older sshd has no PerSourcePenalties and refuses the whole file: drop the line then.
    if ! /usr/sbin/sshd -t -f "$DIR/sshd_config" 2>&1 | grep -q .; then :; elif /usr/sbin/sshd -t -f "$DIR/sshd_config" 2>&1 | grep -qi "PerSourcePenalties"; then
      sed -i '' '/^PerSourcePenalties/d' "$DIR/sshd_config"
      echo "sshd here predates PerSourcePenalties; line dropped"
    fi
    if ! /usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"; then
      echo "sshd failed to start; see $DIR/sshd.log" >&2
      tail -5 "$DIR/sshd.log" >&2
      exit 1
    fi
    sleep 0.3
    printf 'export TEPFA_TEST_SSH_PORT=%s\nexport TEPFA_TEST_SSH_KEY=%q\n' "$PORT" "$DIR/user_ed25519" > "$DIR/env.sh"
    echo "sshd listening on 127.0.0.1:$PORT (pid $(cat "$DIR/sshd.pid"))"
    echo "source $DIR/env.sh && swift test --filter Live"
    ;;
  stop)
    if [ -f "$DIR/sshd.pid" ]; then kill "$(cat "$DIR/sshd.pid")" && rm -f "$DIR/sshd.pid" && echo "stopped"; else echo "not running"; fi
    ;;
  *)
    echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
