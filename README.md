# BBRplus Installer

涓ü���瑁 Debian / Ubuntu ��″ㄤ�� BBRplus �� 稿苟��ㄥ�� `fq + bbrplus` �缃�ü

## 涓ü��ц�

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus.sh) --auto-reboot
```

## �瀹���

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/bbrplus-installer-onekey/main/install-bbrplus.sh) --tag 6.7.9-bbrplus --auto-reboot
```

## ���妫ü��

```bash
uname -r
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
lsmod | grep bbr
```

## 璇存

- ��� `Debian / Ubuntu`
- ��� `amd64 / arm64`
- `LXC / OpenVZ / Docker` 杩绫诲��ㄤ��界存ユ㈠�涓绘哄� �
- 寮ü�� `Secure Boot` ��哄ㄤ�寤鸿�浣跨ㄦ���绗���瑰� �
