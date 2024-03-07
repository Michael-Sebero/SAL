<p align="center">
	<img src="https://upload.wikimedia.org/wikipedia/commons/1/13/Arch_Linux_%22Crystal%22_icon.svg" width="30%" />
</p>
<br>

## How to Install
* For Artix Login as root `user:root` and `password:artix` (Arch is already logged-in)

* Run these command below

```
curl -LO raw.github.com/michael-sebero/sal/main/sal.sh

sh sal.sh
```

## How does SAL work?
The installer consists of five simple TUI steps which configure your Arch/Artix Linux installation. Every instance receives 15 GB of swap space by default, with a choice of F2FS, XFS, BTRFS or EXT4 for the filesystem and KDE, XFCE, MATE, Cinnamon or GNOME as the desktop environment. Repository mirrors are automatically ranked before package installation to select the fastest available mirrors and speed up the installation process. Full filesystem encryption is available as an option also.

> [!IMPORTANT]
> Some packages are installed from [ALHP's](https://wiki.archlinux.org/title/Unofficial_user_repositories#ALHP) x86-64-v3 and x86-64-v4 repositories. This script automatically detects your CPU’s microarchitecture and configures the appropriate repositories. **If your CPU does not support x86-64-v3, packages will instead be installed from default repositories.**

<p align="center">
	<img src="https://i.postimg.cc/J0tC8vwx/Screenshot-from-2026-09-16-19-20-10.png"/>
</p>

## Contact and Donations
* [Email](michaelsebero@disroot.org)
* [PayPal](https://www.paypal.com/donate/?cmd=_donations&business=YYGU9JWJEE2AG)
