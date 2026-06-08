# BBRplus + fq One-Key Installer

One-command installer for BBRplus + fq on Debian/Ubuntu servers, with a safe
built-in BBR + fq fallback for systems where the BBRplus `.deb` kernel installer
is not supported.

On Debian/Ubuntu, the one-key installer installs the third-party BBRplus kernel
when the running kernel does not already expose `bbrplus`. Ubuntu 22.04/24.04
can work on some providers, but replacing the stock/cloud kernel can make other
provider images unreachable after reboot. Keep snapshot, VNC, serial console, or
rescue access available for production machines.

Non-Debian/Ubuntu systems use the safe stock-kernel path because this repository
currently ships only Debian/Ubuntu `.deb` BBRplus kernel packages.

## One-Key Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --auto-reboot
```

Behavior:

- If the current kernel already supports `bbrplus`, the script applies
  `fq + bbrplus`.
- On Debian/Ubuntu, if `bbrplus` is not available, the script installs the
  BBRplus kernel first. After reboot, a one-shot systemd finalizer applies
  persistent `fq + bbrplus`.
- On non-Debian/Ubuntu systems, the script applies safe stock-kernel `fq + bbr`
  instead and does not replace the kernel.

## Safe Built-In BBR + fq

Use this on Ubuntu 22.04 / 24.04, RHEL-compatible systems, or on any VPS where
you do not want to replace the provider kernel:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/enable-bbr-fq.sh)
```

Or use the one-key script in safe mode:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --safe-bbr
```

## Install Kernel Only

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus.sh) --auto-reboot
```

The compatibility flag below is still accepted, but no longer required because
direct BBRplus kernel installation proceeds by default on Debian/Ubuntu:

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
- Ubuntu 22.04 / 24.04 can install BBRplus on compatible providers, but kernel
  replacement can still make incompatible provider images unreachable after reboot
- RHEL-compatible systems do not use the BBRplus kernel installer; they use
  stock-kernel `bbr` when available
- On multi-queue NICs, `tc qdisc show` may still display `mq` as the root qdisc; that does not necessarily mean `fq` is inactive
- The scripts skip `apt-get update` when required packages are already installed; if a package is missing, apt runs once with retry and timeout options
- After installing the kernel, the installer sets the BBRplus GRUB entry as the saved default boot option when GRUB tools are available
