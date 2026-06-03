#!/usr/bin/env bash

set -euo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main}"
AUTO_REBOOT=0
FORCE_THIRD_PARTY_KERNEL=0
SCRIPT_NAME="$(basename "$0")"
INSTALL_ARGS=()
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

install_iproute2_package() {
  if command -v apt-get >/dev/null 2>&1; then
    apt_install_missing iproute2
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute iproute-tc || dnf install -y iproute
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y iproute iproute-tc || yum install -y iproute
    return
  fi

  die "iproute2/iproute is required, but no supported package manager was found"
}

usage() {
  cat <<'EOF'
Usage:
  onekey-bbrplus-fq.sh [--auto-reboot] [--tag <release-tag>] [--keep-downloads] [--force-third-party-kernel]

Options:
  --auto-reboot    Reboot automatically when a reboot is required.
  --tag <tag>      Install a specific BBRplus release tag, e.g. 6.7.9-bbrplus.
  --keep-downloads Keep downloaded kernel packages in the temp directory.
  --force-third-party-kernel
                   Replace the kernel even on guarded Ubuntu LTS releases.
  -h, --help       Show this help message.

What this script does:
  - if BBRplus is already available, persist and apply BBRplus + fq directly
  - on Ubuntu 22.04/24.04 and non-Debian/Ubuntu systems, default to built-in BBR + fq
  - otherwise, if BBRplus is not available, install the BBRplus kernel first
  - install a one-shot boot finalizer so fq is applied after the kernel reboot
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-reboot)
      AUTO_REBOOT=1
      INSTALL_ARGS+=("--auto-reboot")
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      INSTALL_ARGS+=("--tag" "$2")
      shift 2
      ;;
    --keep-downloads)
      INSTALL_ARGS+=("--keep-downloads")
      shift
      ;;
    --force-third-party-kernel)
      FORCE_THIRD_PARTY_KERNEL=1
      INSTALL_ARGS+=("--force-third-party-kernel")
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
command -v sysctl >/dev/null 2>&1 || die "sysctl is required"

ensure_iproute2() {
  if command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1; then
    return
  fi

  install_iproute2_package
  command -v ip >/dev/null 2>&1 || die "ip is still missing after installing iproute2"
  command -v tc >/dev/null 2>&1 || die "tc is still missing after installing iproute2"
}

bbrplus_available() {
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if grep -qw 'bbrplus' <<<"${available}"; then
    return 0
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbrplus 2>/dev/null || true
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    grep -qw 'bbrplus' <<<"${available}"
    return
  fi

  return 1
}

install_boot_finalizer() {
  command -v systemctl >/dev/null 2>&1 || {
    log "systemctl not found; skipping boot finalizer"
    return
  }

  cat >/usr/local/sbin/bbrplus-fq-finalize.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[bbrplus-fq-finalize] %s\n' "$*"
}

APT_UPDATED=0
APT_OPTS=(
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=10
  -o Acquire::https::Timeout=10
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

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

  command -v apt-get >/dev/null 2>&1 || return 1
  apt_update_once
  log "installing missing apt packages: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y "${missing[@]}"
}

if ! command -v ip >/dev/null 2>&1 || ! command -v tc >/dev/null 2>&1; then
  apt_install_missing iproute2 || true
fi

if command -v modprobe >/dev/null 2>&1; then
  modprobe tcp_bbrplus 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
fi

AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if ! grep -qw 'bbrplus' <<<"${AVAILABLE_CC}"; then
  log "bbrplus is still not available on kernel $(uname -r); leaving service enabled for the next boot"
  exit 1
fi

cat >/etc/sysctl.d/99-bbrplus-fq.conf <<'CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus
CONF

sysctl --system >/dev/null

NIC="$(ip route show default | awk '/default/ {print $5; exit}')"
if [[ -n "${NIC}" ]]; then
  tc qdisc replace dev "${NIC}" root fq 2>/dev/null || true
fi

systemctl disable bbrplus-fq-finalize.service >/dev/null 2>&1 || true

log "BBRplus + fq finalized successfully"
EOF

  chmod +x /usr/local/sbin/bbrplus-fq-finalize.sh

  cat >/etc/systemd/system/bbrplus-fq-finalize.service <<'EOF'
[Unit]
Description=Finalize BBRplus + fq after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bbrplus-fq-finalize.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable bbrplus-fq-finalize.service >/dev/null
  log "installed boot finalizer: bbrplus-fq-finalize.service"
}

run_remote_script() {
  local script="$1"
  shift
  local tmp
  tmp="$(mktemp "/tmp/${script}.XXXXXX")"
  curl -fsSL "${RAW_BASE}/${script}" -o "${tmp}"
  bash "${tmp}" "$@"
}

get_os_field() {
  local field="$1"

  [[ -r /etc/os-release ]] || return 1
  (
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${field}" in
      ID)
        printf '%s' "${ID:-}"
        ;;
      VERSION_ID)
        printf '%s' "${VERSION_ID:-}"
        ;;
      PRETTY_NAME)
        printf '%s' "${PRETTY_NAME:-}"
        ;;
    esac
  )
}

should_use_mainline_bbr_fallback() {
  local os_id
  local os_version

  [[ "${FORCE_THIRD_PARTY_KERNEL}" -eq 0 ]] || return 1

  os_id="$(get_os_field ID || true)"
  os_version="$(get_os_field VERSION_ID || true)"

  case "${os_id}" in
    debian)
      return 1
      ;;
    ubuntu)
      ;;
    *)
      return 0
      ;;
  esac

  case "${os_version}" in
    22.04|24.04)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

guard_supported_kernel_installer() {
  local os_id
  local os_pretty

  os_id="$(get_os_field ID || true)"
  case "${os_id}" in
    debian|ubuntu)
      return
      ;;
  esac

  os_pretty="$(get_os_field PRETTY_NAME || true)"
  die "${os_pretty:-unsupported system} is not supported by the BBRplus kernel installer; only Debian/Ubuntu .deb installs are implemented"
}

ensure_iproute2

if bbrplus_available; then
  log "bbrplus is already available on the current kernel; applying fq now"
  if [[ "${AUTO_REBOOT}" -eq 1 ]]; then
    run_remote_script "enable-bbrplus-fq.sh" "--auto-reboot"
  else
    run_remote_script "enable-bbrplus-fq.sh"
  fi
  exit 0
fi

log "current kernel $(uname -r) does not expose bbrplus"
if should_use_mainline_bbr_fallback; then
  os_pretty="$(get_os_field PRETTY_NAME || true)"
  log "${os_pretty:-guarded Ubuntu LTS} detected; using built-in BBR + fq instead of replacing the kernel"
  if [[ "${AUTO_REBOOT}" -eq 1 ]]; then
    run_remote_script "enable-bbr-fq.sh" "--auto-reboot"
  else
    run_remote_script "enable-bbr-fq.sh"
  fi
  exit 0
fi

guard_supported_kernel_installer
log "installing BBRplus kernel first"
install_boot_finalizer
run_remote_script "install-bbrplus.sh" "${INSTALL_ARGS[@]}"
