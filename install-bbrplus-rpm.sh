#!/usr/bin/env bash

set -euo pipefail

REPO="UJX6N/bbrplus-6.x_stable"
AUTO_REBOOT=0
KEEP_DOWNLOADS=0
RELEASE_TAG=""
SCRIPT_NAME="$(basename "$0")"
WORKDIR=""
INSTALL_SUCCEEDED=0
TEMP_SWAP_MODE="auto"
TEMP_SWAP_SIZE_MB=1024
TEMP_SWAP_THRESHOLD_MB=2048
TEMP_SWAP_FILE=""
TEMP_SWAP_CREATED=0

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

pm_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
    return
  fi

  die "dnf or yum is required"
}

package_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

install_missing_packages() {
  local missing=()
  local pkg

  for pkg in "$@"; do
    if ! package_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "required rpm packages already installed"
    return
  fi

  log "installing missing rpm packages: ${missing[*]}"
  pm_install "${missing[@]}"
}

ensure_ca_certificates() {
  if [[ -s /etc/pki/tls/certs/ca-bundle.crt || -s /etc/ssl/certs/ca-certificates.crt ]]; then
    log "CA certificate bundle already present"
    return
  fi

  install_missing_packages ca-certificates
}

run_grub_update() {
  if command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
    return
  fi

  if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
    return
  fi

  return 1
}

set_grub_default_saved() {
  local grub_defaults="/etc/default/grub"
  local backup

  [[ -f "${grub_defaults}" ]] || return 0
  grep -Eq '^GRUB_DEFAULT="?saved"?$' "${grub_defaults}" && return 0

  backup="${grub_defaults}.bbrplus-backup-$(date +%Y%m%d-%H%M%S)"
  cp "${grub_defaults}" "${backup}"

  if grep -q '^GRUB_DEFAULT=' "${grub_defaults}"; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "${grub_defaults}"
  else
    printf '\nGRUB_DEFAULT=saved\n' >>"${grub_defaults}"
  fi

  log "configured GRUB_DEFAULT=saved (backup: ${backup})"
}

find_grub_menu_entry() {
  local cfg
  local line
  local title

  for cfg in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
    [[ -r "${cfg}" ]] || continue
    while IFS= read -r line; do
      if [[ "${line}" == *"menuentry '"* && "${line}" == *"${VERSION}"* ]]; then
        title="$(sed -n "s/^[[:space:]]*menuentry '\([^']*\)'.*/\1/p" <<<"${line}" | head -n1)"
        [[ -n "${title}" ]] || continue
        printf '%s\n' "${title}"
        return 0
      fi
    done <"${cfg}"
  done

  return 1
}

configure_bbrplus_boot_default() {
  local kernel_path="/boot/vmlinuz-${VERSION}"
  local entry

  if command -v grubby >/dev/null 2>&1; then
    grubby --set-default "${kernel_path}" || {
      log "grubby could not set ${kernel_path} as the default kernel"
      return
    }
    log "set BBRplus kernel as default with grubby: ${kernel_path}"
    return
  fi

  command -v grub2-set-default >/dev/null 2>&1 || {
    log "grubby/grub2-set-default not found; cannot set BBRplus as default automatically"
    return
  }

  set_grub_default_saved
  run_grub_update || {
    log "could not regenerate GRUB config before setting default"
    return
  }

  entry="$(find_grub_menu_entry || true)"
  if [[ -z "${entry}" ]]; then
    log "could not find a GRUB menu entry for ${VERSION}; check GRUB manually"
    return
  fi

  grub2-set-default "${entry}"
  log "set BBRplus kernel as saved GRUB default: ${entry}"
}

usage() {
  cat <<'EOF'
Usage:
  install-bbrplus-rpm.sh [--auto-reboot] [--tag <release-tag>] [--keep-downloads] [--temp-swap <size>] [--no-temp-swap]

Options:
  --auto-reboot    Reboot automatically after installation completes.
  --tag <tag>      Install a specific release tag, e.g. 6.7.9-bbrplus.
  --keep-downloads Keep downloaded .rpm packages in the temp directory.
  --temp-swap <size>
                   Create a temporary install-only swap file, e.g. 1G or 2048M.
  --no-temp-swap   Disable automatic temporary swap creation.
  -h, --help       Show this help message.

Notes:
  - Supported RPM assets: EL7 x86_64, EL8 x86_64/aarch64
  - Containers such as LXC / OpenVZ / Docker cannot replace the host kernel
  - This script installs a third-party BBRplus kernel and leaves old kernels intact
EOF
}

cleanup() {
  cleanup_temp_swap

  if [[ -z "${WORKDIR}" || ! -d "${WORKDIR}" || "${KEEP_DOWNLOADS}" -eq 1 ]]; then
    return
  fi

  if [[ "${INSTALL_SUCCEEDED}" -eq 1 ]]; then
    rm -rf "${WORKDIR}"
  else
    log "installer did not complete; keeping downloaded packages in ${WORKDIR}"
  fi
}

trap cleanup EXIT

parse_size_mb() {
  local raw="$1"
  local normalized
  local number
  local unit

  normalized="${raw,,}"
  if [[ ! "${normalized}" =~ ^([0-9]+)([gm]?)$ ]]; then
    die "invalid swap size '${raw}', use values like 1024M or 1G"
  fi

  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "${unit}" in
    g)
      printf '%s\n' "$((number * 1024))"
      ;;
    m|"")
      printf '%s\n' "${number}"
      ;;
  esac
}

active_swap_mb() {
  awk 'NR > 1 {sum += $3} END {printf "%d\n", sum / 1024}' /proc/swaps 2>/dev/null || printf '0\n'
}

mem_total_mb() {
  awk '/MemTotal:/ {printf "%d\n", $2 / 1024}' /proc/meminfo 2>/dev/null || printf '0\n'
}

create_temp_swap() {
  local mem_mb
  local swap_mb
  local avail_mb
  local swap_dir="/var/tmp"

  [[ "${TEMP_SWAP_MODE}" != "off" ]] || return

  swap_mb="$(active_swap_mb)"
  if [[ "${TEMP_SWAP_MODE}" == "auto" && "${swap_mb}" -gt 0 ]]; then
    log "active swap already present (${swap_mb}M); skipping temporary swap"
    return
  fi

  mem_mb="$(mem_total_mb)"
  if [[ "${TEMP_SWAP_MODE}" == "auto" && "${mem_mb}" -ge "${TEMP_SWAP_THRESHOLD_MB}" ]]; then
    log "memory is ${mem_mb}M; skipping automatic temporary swap"
    return
  fi

  mkdir -p "${swap_dir}"
  avail_mb="$(df -Pm "${swap_dir}" | awk 'NR == 2 {print $4}')"
  if [[ -n "${avail_mb}" && "${avail_mb}" -le $((TEMP_SWAP_SIZE_MB + 256)) ]]; then
    if [[ "${TEMP_SWAP_MODE}" == "always" ]]; then
      die "not enough free space in ${swap_dir} for ${TEMP_SWAP_SIZE_MB}M temporary swap"
    fi
    log "not enough free space in ${swap_dir} for temporary swap; continuing without it"
    return
  fi

  command -v mkswap >/dev/null 2>&1 || die "mkswap is required for temporary swap"
  command -v swapon >/dev/null 2>&1 || die "swapon is required for temporary swap"

  TEMP_SWAP_FILE="$(mktemp "${swap_dir}/bbrplus-install-swap.XXXXXX")"
  chmod 600 "${TEMP_SWAP_FILE}"
  if ! fallocate -l "${TEMP_SWAP_SIZE_MB}M" "${TEMP_SWAP_FILE}" 2>/dev/null; then
    dd if=/dev/zero of="${TEMP_SWAP_FILE}" bs=1M count="${TEMP_SWAP_SIZE_MB}" status=none
  fi

  mkswap "${TEMP_SWAP_FILE}" >/dev/null
  if ! swapon "${TEMP_SWAP_FILE}" 2>/dev/null; then
    log "temporary swap created with fallocate was rejected; recreating with dd"
    rm -f "${TEMP_SWAP_FILE}"
    TEMP_SWAP_FILE="$(mktemp "${swap_dir}/bbrplus-install-swap.XXXXXX")"
    chmod 600 "${TEMP_SWAP_FILE}"
    dd if=/dev/zero of="${TEMP_SWAP_FILE}" bs=1M count="${TEMP_SWAP_SIZE_MB}" status=none
    mkswap "${TEMP_SWAP_FILE}" >/dev/null
    swapon "${TEMP_SWAP_FILE}"
  fi
  TEMP_SWAP_CREATED=1
  log "enabled temporary ${TEMP_SWAP_SIZE_MB}M swap at ${TEMP_SWAP_FILE}"
}

cleanup_temp_swap() {
  if [[ -z "${TEMP_SWAP_FILE}" ]]; then
    return
  fi

  if [[ "${TEMP_SWAP_CREATED}" -eq 1 ]]; then
    swapoff "${TEMP_SWAP_FILE}" >/dev/null 2>&1 || true
  fi
  rm -f "${TEMP_SWAP_FILE}"
  TEMP_SWAP_CREATED=0
  log "removed temporary swap"
}

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
    --temp-swap)
      [[ $# -ge 2 ]] || die "--temp-swap requires a size, e.g. 1G or 2048M"
      TEMP_SWAP_MODE="always"
      TEMP_SWAP_SIZE_MB="$(parse_size_mb "$2")"
      [[ "${TEMP_SWAP_SIZE_MB}" -ge 128 ]] || die "--temp-swap must be at least 128M"
      shift 2
      ;;
    --no-temp-swap)
      TEMP_SWAP_MODE="off"
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
command -v rpm >/dev/null 2>&1 || die "rpm is required"

if [[ ! -r /etc/os-release ]]; then
  die "cannot detect operating system"
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  centos|rhel|rocky|almalinux|ol|oracle|cloudlinux)
    ;;
  *)
    die "unsupported rpm system: ${PRETTY_NAME:-unknown}; only EL7/EL8-compatible systems are supported"
    ;;
esac

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

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|aarch64)
    ;;
  *)
    die "unsupported architecture: ${ARCH}; only x86_64/aarch64 are supported"
    ;;
esac

VERSION_MAJOR="${VERSION_ID%%.*}"
case "${VERSION_MAJOR}" in
  7)
    [[ "${ARCH}" == "x86_64" ]] || die "EL7 BBRplus RPM is only available for x86_64"
    RPM_ASSET_PREFIX="CentOS-7"
    RPM_EL="el7"
    ;;
  8)
    RPM_ASSET_PREFIX="CentOS-Stream-8"
    RPM_EL="el8"
    ;;
  *)
    die "no BBRplus RPM asset is available for ${PRETTY_NAME:-EL ${VERSION_MAJOR}}; supported RPM assets are EL7 x86_64 and EL8 x86_64/aarch64"
    ;;
esac

CURRENT_KERNEL="$(uname -r)"
log "detected ${PRETTY_NAME:-$ID} on ${ARCH}, current kernel: ${CURRENT_KERNEL}"
log "selected RPM target: ${RPM_ASSET_PREFIX} (${RPM_EL})"

ensure_ca_certificates

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
IMAGE_ASSET="${RPM_ASSET_PREFIX}_Required_kernel-${VERSION}.${RPM_EL}.${ARCH}.rpm"
HEADERS_ASSET="${RPM_ASSET_PREFIX}_Optional_kernel-headers-${VERSION}.${RPM_EL}.${ARCH}.rpm"
IMAGE_URL="${DOWNLOAD_BASE}/${IMAGE_ASSET}"
HEADERS_URL="${DOWNLOAD_BASE}/${HEADERS_ASSET}"

log "selected release: ${RELEASE_TAG}"

curl -fsI "${IMAGE_URL}" >/dev/null || die "kernel image asset not found: ${IMAGE_ASSET}"
curl -fsI "${HEADERS_URL}" >/dev/null || die "kernel headers asset not found: ${HEADERS_ASSET}"

WORKDIR="$(mktemp -d /tmp/bbrplus-rpm-install.XXXXXX)"
log "downloading packages to ${WORKDIR}"
curl -fL --retry 3 --connect-timeout 15 -o "${WORKDIR}/${IMAGE_ASSET}" "${IMAGE_URL}"
curl -fL --retry 3 --connect-timeout 15 -o "${WORKDIR}/${HEADERS_ASSET}" "${HEADERS_URL}"

install_rpm_with_retry() {
  local rpm_path="$1"
  local label="$2"

  if pm_install "${rpm_path}"; then
    return 0
  fi

  log "${label} install failed; retrying once with rpm --replacepkgs"
  rpm -ivh --replacepkgs "${rpm_path}"
}

install_kernel_packages() {
  log "installing BBRplus kernel headers"
  install_rpm_with_retry "${WORKDIR}/${HEADERS_ASSET}" "kernel headers" || return 1

  log "installing BBRplus kernel image"
  install_rpm_with_retry "${WORKDIR}/${IMAGE_ASSET}" "kernel image" || return 1

  [[ -s "/boot/vmlinuz-${VERSION}" ]] || die "installed package is missing /boot/vmlinuz-${VERSION}"

  if [[ ! -s "/boot/initramfs-${VERSION}.img" && -x "$(command -v dracut || true)" ]]; then
    log "initramfs is missing; regenerating /boot/initramfs-${VERSION}.img"
    dracut -f "/boot/initramfs-${VERSION}.img" "${VERSION}"
  fi
}

create_temp_swap
install_kernel_packages || die "failed to install BBRplus RPM kernel packages; downloaded packages kept in ${WORKDIR}"

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

run_grub_update || log "could not regenerate GRUB config automatically"
configure_bbrplus_boot_default

if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbrplus; then
  log "bbrplus is already available on the running kernel; applying sysctl now"
  sysctl --system >/dev/null
fi

INSTALL_SUCCEEDED=1

cat <<EOF

BBRplus RPM packages installed successfully.

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
