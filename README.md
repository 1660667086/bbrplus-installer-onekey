# BBRplus + fq One-Key Installer

One-command installer for BBRplus + fq on Debian/Ubuntu and supported
CentOS/RHEL-compatible servers, with a safe built-in BBR + fq fallback for
systems where no matching BBRplus kernel package is available.

On Debian/Ubuntu, the one-key installer installs the third-party BBRplus kernel
when the running kernel does not already expose `bbrplus`. Ubuntu 22.04/24.04
can work on some providers, but replacing the stock/cloud kernel can make other
provider images unreachable after reboot. Keep snapshot, VNC, serial console, or
rescue access available for production machines.

CentOS/RHEL-compatible EL7/EL8 systems use the upstream BBRplus RPM packages
when available. Other non-Debian/Ubuntu systems use the safe stock-kernel path.

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
- On supported CentOS/RHEL-compatible EL7/EL8 systems, the script installs the
  BBRplus RPM kernel first and then applies persistent `fq + bbrplus`.
- On systems without a matching BBRplus package, the script applies safe
  stock-kernel `fq + bbr` instead and does not replace the kernel.
- Kernel packages are installed in a recoverable sequence: headers first, image
  second, with one automatic `dpkg` repair and retry if the image install fails.
- On low-memory servers without active swap, the installer creates a temporary
  install-only swap file and removes it before exiting.
- The one-shot boot finalizer is enabled only after the kernel installer
  completes successfully.

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

For CentOS/RHEL-compatible EL7/EL8 systems:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus-rpm.sh) --auto-reboot
```

Force a larger temporary swap file during installation:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --temp-swap 2G --auto-reboot
```

Disable temporary swap creation:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --no-temp-swap --auto-reboot
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

## Recover An Interrupted Install

If the installer exits during `dpkg` and reports a kept `/tmp/bbrplus-install.*`
directory, do not reboot first. Check and repair the package database:

```bash
dpkg --audit
dpkg --configure -a
```

If `linux-image-<version>` is still reported as broken, reinstall the downloaded
image package from the kept directory:

```bash
dpkg -i /tmp/bbrplus-install.*/Debian-Ubuntu_Required_linux-image-*_*.deb
dpkg --audit
```

For RPM installs, reinstall the downloaded kernel RPM from the kept directory:

```bash
dnf install -y /tmp/bbrplus-rpm-install.*/CentOS*_Required_kernel-*.rpm || \
  yum install -y /tmp/bbrplus-rpm-install.*/CentOS*_Required_kernel-*.rpm
```

After `dpkg --audit` is clean, run `update-grub` and choose the generated
BBRplus GRUB entry if it was not already set automatically. On RPM systems,
use `grubby --default-kernel` to confirm the selected default kernel.

## Notes

- BBRplus kernel install support: `Debian / Ubuntu / EL7 / EL8`
- Safe built-in BBR support: `Debian / Ubuntu / RHEL-compatible`
- Debian/Ubuntu architectures: `amd64 / arm64`
- RPM architectures: `EL7 x86_64`, `EL8 x86_64 / aarch64`
- Containers like `LXC / OpenVZ / Docker` cannot replace the host kernel
- Machines with `Secure Boot` enabled are not recommended for unsigned third-party kernels
- Ubuntu 22.04 / 24.04 can install BBRplus on compatible providers, but kernel
  replacement can still make incompatible provider images unreachable after reboot
- Temporary swap is used only during installation; the scripts do not add it to
  `/etc/fstab`
- EL9 RPM packages are not currently available in the upstream BBRplus release;
  EL9-compatible systems use stock-kernel `bbr` unless a matching release is added
- On multi-queue NICs, `tc qdisc show` may still display `mq` as the root qdisc; that does not necessarily mean `fq` is inactive
- The scripts skip `apt-get update` when required packages are already installed; if a package is missing, apt runs once with retry and timeout options
- After installing the kernel, the installer sets the BBRplus GRUB entry as the saved default boot option when GRUB tools are available
