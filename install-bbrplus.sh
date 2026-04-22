#!/usr/bin/env bash

set -euo pipefail

REPO="UJX6N/bbrplus-6.x_stable"
AUTO_REBOOT=0
KEEP_DOWNLOADS=0
RELEASE_TAG=""
SCRIPT_NAME="$(basename "$0")"
WORKDIR=""

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
  install-bbrplus.sh [--auto-reboot] [--tag <release-tag>] [--keep-downloads]

Options:
  --auto-reboot    Reboot automatically after installation completes.
  --tag <tag>      Install a specific release tag, e.g. 6.7.9-bbrplus.
  --keep-downloads Keep downloaded .deb packages in the temp directory.
  -h, --help       Show this help message.

Notes:
  - Supported systems: Debian / Ubuntu on amd64 or arm64
  - Containers such as LXC / OpenVZ / Docker cannot replace the host kernel
  - This script installs a third-party BBRplus kernel and leaves old kernels intact
EOF
}

cleanup() {
  if [[ -n "${WORKDIR}" && -d "${WORKDIR}" && "${KEEP_DOWNLOADS}" -eq 0 ]]; then
    rm -rf "${WORKDIR}"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-reboot)
      AUTO_REBOOT=1
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      RELEASE_TAG="$2"
      shift 2
      ;;
    --keep-downloads)
      KEEP_DOWNLOADS=1
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
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v dpkg >/dev/null 2>&1 || die "dpkg is required"
command -v apt-get >/dev/null 2>&1 || die "apt-get is required"

if command -v systemd-detect-virt >/dev/null 2>&1; then
  if systemd-detect-virt -cq; then
    die "container detected; containers cannot install a new kernel"
  fi
fi

if [[ -f /proc/user_beancounters ]] || [[ -d /proc/vz ]]; then
  die "OpenVZ/Virtuozzo container detected; cannot replace the host kernel"
fi

if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    die "Secure Boot is enabled; unsigned third-party kernels may fail to boot"
  fi
fi

if [[ ! -r /etc/os-release ]]; then
  die "cannot detect operating system"
fi

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu)
    ;;
  *)
    die "unsupported system: ${PRETTY_NAME:-unknown}; only Debian/Ubuntu are supported"
    ;;
esac

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64|arm64)
    ;;
  *)
    die "unsupported architecture: ${ARCH}; only amd64/arm64 are supported"
    ;;
esac

CURRENT_KERNEL="$(uname -r)"
log "detected ${PRETTY_NAME:-$ID} on ${ARCH}, current kernel: ${CURRENT_KERNEL}"

apt-get update -y
apt-get install -y ca-certificates curl

if [[ -z "${RELEASE_TAG}" ]]; then
  log "querying latest BBRplus release from ${REPO}"
  RELEASE_TAG="$(
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -n 's/^[[:space:]]*\"tag_name\":[[:space:]]*\"\([^\"]*\)\".*/\1/p' \
      | head -n1
  )"
  [[ -n "${RELEASE_TAG}" ]] || die "failed to determine latest release tag"
fi

VERSION="${RELEASE_TAG}"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
IMAGE_ASSET="Debian-Ubuntu_Required_linux-image-${VERSION}_${VERSION}-1_${ARCH}.deb"
HEADERS_ASSET="Debian-Ubuntu_Optional_linux-headers-${VERSION}_${VERSION}-1_${ARCH}.deb"
IMAGE_URL="${DOWNLOAD_BASE}/${IMAGE_ASSET}"
HEADERS_URL="${DOWNLOAD_BASE}/${HEADERS_ASSET}"

log "selected release: ${RELEASE_TAG}"

curl -fsI "${IMAGE_URL}" >/dev/null || die "kernel image asset not found: ${IMAGE_ASSET}"
curl -fsI "${HEADERS_URL}" >/dev/null || die "kernel headers asset not found: ${HEADERS_ASSET}"

WORKDIR="$(mktemp -d /tmp/bbrplus-install.XXXXXX)"
log "downloading packages to ${WORKDIR}"
curl -fL --retry 3 --connect-timeout 15 -o "${WORKDIR}/${IMAGE_ASSET}" "${IMAGE_URL}"
curl -fL --retry 3 --connect-timeout 15 -o "${WORKDIR}/${HEADERS_ASSET}" "${HEADERS_URL}"

if [[ -f /etc/sysctl.d/99-bbrplus.conf ]]; then
  BACKUP_DIR="/root/bbrplus-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  cp /etc/sysctl.d/99-bbrplus.conf "${BACKUP_DIR}/99-bbrplus.conf"
  log "backed up existing /etc/sysctl.d/99-bbrplus.conf to ${BACKUP_DIR}"
fi

cat >/etc/sysctl.d/99-bbrplus.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus
EOF

log "installing BBRplus kernel packages"
dpkg -i "${WORKDIR}/${HEADERS_ASSET}" "${WORKDIR}/${IMAGE_ASSET}" || apt-get install -f -y

if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg
elif command -v grub2-mkconfig >/dev/null 2>&1; then
  grub2-mkconfig -o /boot/grub2/grub.cfg
fi

if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbrplus; then
  log "bbrplus is already available on the running kernel; applying sysctl now"
  sysctl --system >/dev/null
fi

cat <<EOF

BBRplus packages installed successfully.

Target kernel:
  ${RELEASE_TAG}

Configured defaults:
  net.core.default_qdisc = fq
  net.ipv4.tcp_congestion_control = bbrplus

Verification after reboot:
  uname -r
  sysctl net.ipv4.tcp_available_congestion_control
  sysctl net.ipv4.tcp_congestion_control
  lsmod | grep bbr

EOF

if [[ "${AUTO_REBOOT}" -eq 1 ]]; then
  log "auto reboot requested; rebooting in 5 seconds"
  sleep 5
  reboot
else
  log "reboot is required to finish enabling BBRplus"
fi
