# BBRplus + fq One-Key Installer

One-command installer for TCP acceleration on Debian, Ubuntu, and
RHEL-compatible servers.

By default, Ubuntu 22.04 and Ubuntu 24.04 use the safe stock-kernel path:
`fq + bbr`. These releases already include mainline BBR, and replacing their
stock/cloud kernel with an unsigned third-party BBRplus kernel has caused VPS
instances to become unreachable after reboot.

Non-Debian/Ubuntu systems also use the safe stock-kernel path. The BBRplus
kernel installer currently supports only Debian/Ubuntu `.deb` packages.

Other supported Debian/Ubuntu releases still install the BBRplus kernel when
the running kernel does not expose `bbrplus`.

## One-Key Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --auto-reboot
```

Behavior:

- If the current kernel already supports `bbrplus`, the script applies
  `fq + bbrplus`.
- On Ubuntu 22.04 / 24.04, if `bbrplus` is not already available, the script
  applies safe stock-kernel `fq + bbr` instead and does not replace the kernel.
- On non-Debian/Ubuntu systems, the script applies safe stock-kernel `fq + bbr`
  instead and does not replace the kernel.
- On other supported Debian/Ubuntu systems, if `bbrplus` is not available, the
  script installs the BBRplus kernel first. After reboot, a one-shot systemd
  finalizer applies persistent `fq + bbrplus`.

## Safe Built-In BBR + fq

Use this on Ubuntu 22.04 / 24.04, RHEL-compatible systems, or on any VPS where
you do not want to replace the provider kernel:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/enable-bbr-fq.sh)
```

## Install Kernel Only

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus.sh) --auto-reboot
```

On Ubuntu 22.04 / 24.04, direct BBRplus kernel installation is blocked by
default. If you have serial console or rescue access and accept the risk:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus.sh) --force-third-party-kernel --auto-reboot
```

## Install A Specific Release

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --tag 6.7.9-bbrplus --auto-reboot
```

## Apply BBRplus + fq Only

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/enable-bbrplus-fq.sh) --auto-reboot
```

## Verify After Reboot

```bash
uname -r
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
lsmod | grep bbr
```

## Notes

- BBRplus kernel install support: `Debian / Ubuntu`
- Safe built-in BBR support: `Debian / Ubuntu / RHEL-compatible`
- Supported architectures: `amd64 / arm64`
- Containers like `LXC / OpenVZ / Docker` cannot replace the host kernel
- Machines with `Secure Boot` enabled are not recommended for unsigned third-party kernels
- Ubuntu 22.04 / 24.04 use stock-kernel `bbr` by default; forcing BBRplus kernel
  replacement on these releases can make cloud VPS instances unreachable
- RHEL-compatible systems do not use the BBRplus kernel installer; they use
  stock-kernel `bbr` when available
- On multi-queue NICs, `tc qdisc show` may still display `mq` as the root qdisc; that does not necessarily mean `fq` is inactive
- The scripts skip `apt-get update` when required packages are already installed; if a package is missing, apt runs once with retry and timeout options
- After installing the kernel, the installer sets the BBRplus GRUB entry as the saved default boot option when GRUB tools are available
