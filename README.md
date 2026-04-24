# BBRplus + fq One-Key Installer

One-command installer for the BBRplus kernel and persistent `fq + bbrplus`
configuration on Debian and Ubuntu servers.

## One-Key Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --auto-reboot
```

The first run installs the BBRplus kernel if the current kernel does not support
`bbrplus`. After reboot, a one-shot systemd finalizer applies the persistent
`fq + bbrplus` settings automatically.

## Install Kernel Only

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus.sh) --auto-reboot
```

## Install A Specific Release

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/onekey-bbrplus-fq.sh) --tag 6.7.9-bbrplus --auto-reboot
```

## Apply fq Only

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

- Supported systems: `Debian / Ubuntu`
- Supported architectures: `amd64 / arm64`
- Containers like `LXC / OpenVZ / Docker` cannot replace the host kernel
- Machines with `Secure Boot` enabled are not recommended for unsigned third-party kernels
- On multi-queue NICs, `tc qdisc show` may still display `mq` as the root qdisc; that does not necessarily mean `fq` is inactive
