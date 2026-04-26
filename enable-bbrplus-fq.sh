#!/usr/bin/env bash

set -euo pipefail

AUTO_REBOOT=0
SCRIPT_NAME="$(basename "$0")"
APT_UPDATED=0
APT_OPTS=(
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=10
  -o Acquire::https::Timeout=10
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_update_once() {
  if [[ "${APT_UPDATED}" -eq 1 ]]; then
    return
  fi

  log "updating apt cache once because a required package is missing"
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update -y
  APT_UPDATED=1
}

apt_install_missing() {
  local missing=()
  local pkg

  for pkg in "$@"; do
    if ! package_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "required apt packages already installed; skipping apt update"
    return
  fi

  command -v apt-get >/dev/null 2>&1 || die "apt-get is required to install: ${missing[*]}"
  apt_update_once
  log "installing missing apt packages: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y "${missing[@]}"
}

ensure_iproute2() {
  if command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1; then
    return
  fi

  apt_install_missing iproute2
  command -v ip >/dev/null 2>&1 || die "ip is still missing after installing iproute2"
  command -v tc >/dev/null 2>&1 || die "tc is still missing after installing iproute2"
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
ensure_iproute2

NIC="$(ip route show default | awk '/default/ {print $5; exit}')"
[[ -n "${NIC}" ]] || die "failed to detect the default network interface"

AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if ! grep -qw 'bbrplus' <<<"${AVAILABLE_CC}" && command -v modprobe >/dev/null 2>&1; then
  modprobe tcp_bbrplus 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
fi

if ! grep -qw 'bbrplus' <<<"${AVAILABLE_CC}"; then
  CURRENT_KERNEL="$(uname -r 2>/dev/null || echo unknown)"
  if grep -qi 'bbrplus' <<<"${CURRENT_KERNEL}"; then
    die "running kernel ${CURRENT_KERNEL} still does not expose bbrplus; try 'modprobe tcp_bbrplus' and check dmesg"
  fi
  die "bbrplus is not available on the current kernel (${CURRENT_KERNEL}); install or boot the BBRplus kernel first"
fi

if command -v modprobe >/dev/null 2>&1; then
  modprobe sch_fq 2>/dev/null || true
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
