#!/usr/bin/env bash

set -euo pipefail

AUTO_REBOOT=0
SCRIPT_NAME="$(basename "$0")"

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  enable-bbrplus-fq.sh [--auto-reboot]

Options:
  --auto-reboot  Reboot automatically after applying the persistent config.
  -h, --help     Show this help message.

What this script does:
  - sets net.core.default_qdisc = fq
  - sets net.ipv4.tcp_congestion_control = bbrplus
  - writes the settings to /etc/sysctl.d/99-bbrplus-fq.conf
  - reloads sysctl immediately

Notes:
  - On multi-queue NICs, tc may still show mq as the root qdisc after reboot.
    That is normal; fq is still used as the default qdisc for the device queues.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-reboot)
      AUTO_REBOOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "please run as root"
command -v sysctl >/dev/null 2>&1 || die "sysctl is required"
command -v ip >/dev/null 2>&1 || die "ip is required"
command -v tc >/dev/null 2>&1 || die "tc is required"

NIC="$(ip route show default | awk '/default/ {print $5; exit}')"
[[ -n "${NIC}" ]] || die "failed to detect the default network interface"

AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if ! grep -qw 'bbrplus' <<<"${AVAILABLE_CC}"; then
  die "bbrplus is not available on the current kernel; install or boot the BBRplus kernel first"
fi

cat >/etc/sysctl.d/99-bbrplus-fq.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus
EOF

log "wrote persistent config to /etc/sysctl.d/99-bbrplus-fq.conf"
sysctl --system >/dev/null
log "reloaded sysctl settings"

# Best-effort immediate apply for the current interface. If this fails, the
# persistent sysctl config will still take effect after the next reboot.
if tc qdisc replace dev "${NIC}" root fq 2>/dev/null; then
  log "applied fq immediately on ${NIC}"
else
  log "could not replace the active root qdisc on ${NIC}; reboot recommended"
fi

cat <<EOF

Persistent BBRplus + fq configuration applied.

Current checks:
  sysctl net.core.default_qdisc
  sysctl net.ipv4.tcp_congestion_control
  tc qdisc show dev ${NIC}

After reboot, verify with:
  sysctl net.core.default_qdisc
  sysctl net.ipv4.tcp_congestion_control
  tc qdisc show dev ${NIC}

EOF

if [[ "${AUTO_REBOOT}" -eq 1 ]]; then
  log "auto reboot requested; rebooting in 5 seconds"
  sleep 5
  reboot
else
  log "done; reboot once if you want the default qdisc to be applied cleanly at boot"
fi
