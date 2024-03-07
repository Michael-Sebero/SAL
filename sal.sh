#!/usr/bin/env bash
# Arch/Artix Linux TUI installer - BIOS or UEFI (auto-detected), single disk,
# systemd/OpenRC/runit/s6/dinit.
#
# TUI look (theme, box-drawn progress display, screen flow) follows the
# Simple Void Linux installer, recolored for Arch/Artix; the desktop
# environment step is ported the same way, using pacman package names.

### RE-EXEC UNDER BASH IF INVOKED WITH SH ###
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -uo pipefail

### USER CUSTOMIZATION SECTION ###
DEFAULT_HOSTNAME=""              
DEFAULT_TIMEZONE="UTC"
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_KEYMAP="us"              
TARGET="/mnt"
EFI_SIZE="1024M"                 
BIOS_BOOT_SIZE="1M"              
SWAP_SIZE="15G"                  
USER_GROUPS="wheel,audio,video,input,storage,optical,lp,scanner,network,users,kvm,render"
EXTRA_PACKAGES=(pipewire pipewire-pulse pipewire-alsa wireplumber librewolf)
LOG="/var/tmp/sal-install.log"

# Package install persistence (see "PERSISTENT PACKAGE INSTALLATION" below).
STRAP_MAX_ATTEMPTS=5
STRAP_RETRY_DELAY=5

RANKMIRRORS_TIMEOUT=60
RANKMIRRORS_PER_MIRROR_TIMEOUT=5

BACKTITLE="Simple Arch/Artix Linux"
HAVE_DIALOG=0
WORKDIR=""
BOOT_MODE=""
INIT_SYSTEM="" DISTRO="" DISTRO_LABEL="" STRAP_CMD="" CHROOT_CMD="" BOOTLOADER_ID="" INIT_BASE_PKGS=""
DISK="" BOOT_PART="" SWAP_PART="" ROOT_PART=""
GPU_VENDOR="unknown" NVIDIA_TIER="" DE_CHOICE="" FS_CHOICE=""
NEW_HOSTNAME="" NEW_USER="" USER_PASS="" ROOT_PASS=""
ENCRYPT="no" LUKS_UUID="" LUKS_PASS=""
TIMEZONE="" LOCALE="" KEYMAP=""
FAILED_PACKAGES=() STRAP_SKIPPED=()
SKIPPED_PACKAGES=""

part_path() { case "$1" in *[0-9]) printf '%sp%s' "$1" "$2" ;; *) printf '%s%s' "$1" "$2" ;; esac; }

cleanup_and_exit() {
  local code="${1:-1}"
  swapoff -a >/dev/null 2>&1 || true
  umount -R "$TARGET" >/dev/null 2>&1 || true
  [ "$ENCRYPT" = "yes" ] && cryptsetup close cryptroot >/dev/null 2>&1 || true
  exit "$code"
}

die() {
  local tail_txt=""
  if [ -s "$LOG" ]; then
    tail_txt=$(tail -n 12 "$LOG" 2>/dev/null | tr '\r' '\n' \
                 | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/[[:cntrl:]]//g' \
                 | sed -e '/^[[:space:]]*$/d' | cut -c1-72 | tail -n 10)
  fi
  if [ "$HAVE_DIALOG" = "1" ]; then
    # Pinned to /dev/tty: same command-substitution issue ask() below works around.
    dialog --backtitle "$BACKTITLE" --title "Error" --msgbox \
      "$*\n\nLast lines of $LOG:\n\n$tail_txt" 22 78 1>/dev/tty 2>/dev/null
  else
    echo "ERROR: $*" >&2
    [ -n "$tail_txt" ] && printf '%s\n' "$tail_txt" >&2
  fi
  cleanup_and_exit 1
}

ask() { dialog "$@" 1>/dev/tty 2>"$WORKDIR/ans"; }

### PROGRESS DISPLAY (BOX-DRAWN, NO PERCENTAGE GAUGE) ###
TOTAL_PARTS=3
CURRENT_PART=0
PROGRESS_BOX_LINES=6

if [ "${TERM:-}" = "linux" ]; then
  SPINNER_FRAMES=('-' '\' '|' '/')
  ICON_OK="+"
  ICON_FAIL="x"
else
  SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  ICON_OK="✓"
  ICON_FAIL="✗"
fi
SPINNER_IDX=0

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  TUI_LIVE=1
  if [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
    C_BORDER=$(tput setaf 32)
  else
    C_BORDER=$(tput setaf 6)
  fi
  C_BOLD=$(tput bold); C_DIM=$(tput dim)
  C_OK=$(tput setaf 2); C_FAIL=$(tput setaf 1); C_RESET=$(tput sgr0); EL_SEQ=$(tput el)
else
  TUI_LIVE=0
  C_BORDER=""; C_BOLD=""; C_DIM=""; C_OK=""; C_FAIL=""; C_RESET=""; EL_SEQ=""
fi

term_width() {
  local w
  w=$(tput cols 2>/dev/null) || w=80
  [ "$w" -ge 44 ] 2>/dev/null || w=44
  printf '%s' "$w"
}

box_width() {
  local w target; w=$(term_width)
  target=$((w - 4))
  [ "$target" -le 78 ] || target=78
  [ "$target" -ge 36 ] || target=36
  printf '%s' "$target"
}

fmt_elapsed() {
  local s="$1" h m
  h=$((s / 3600)); m=$(((s % 3600) / 60)); s=$((s % 60))
  if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"
  else printf '%d:%02d' "$m" "$s"
  fi
}

repeat_char() {
  local ch="$1" n="$2" out="" i
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

progress_paint() {
  local msg="$1" elapsed="$2" activity="$3" style="${4:-}"
  local width; width=$(box_width)
  local inner=$((width - 2))       
  local content=$((inner - 2))     
  local outer; outer=$(term_width)
  local padn=$(( (outer - width) / 2 ))
  [ "$padn" -ge 0 ] || padn=0
  local pad; pad=$(printf '%*s' "$padn" '')

  local hline; hline=$(repeat_char '─' "$inner")
  local top="${pad}${C_BORDER}┌${hline}┐${C_RESET}${EL_SEQ}"
  local mid="${pad}${C_BORDER}├${hline}┤${C_RESET}${EL_SEQ}"
  local bot="${pad}${C_BORDER}└${hline}┘${C_RESET}${EL_SEQ}"
  local side_l="${pad}${C_BORDER}│${C_RESET} "
  local side_r=" ${C_BORDER}│${C_RESET}${EL_SEQ}"

  local icon
  case "$style" in
    ok)   icon="${C_OK}${ICON_OK}${C_RESET}" ;;
    fail) icon="${C_FAIL}${ICON_FAIL}${C_RESET}" ;;
    *)    icon="${C_BORDER}${SPINNER_FRAMES[$((SPINNER_IDX % ${#SPINNER_FRAMES[@]}))]}${C_RESET}" ;;
  esac
  local part_label="Part ${CURRENT_PART}/${TOTAL_PARTS}"
  local time_label; time_label="Elapsed Time: $(fmt_elapsed "$elapsed")"
  local head_gap=$((content - 2 - ${#part_label} - ${#time_label}))
  [ "$head_gap" -ge 1 ] || head_gap=1
  local head_pad; head_pad=$(printf '%*s' "$head_gap" '')

  msg=$(printf '%s' "$msg" | cut -c1-"$content")
  local msg_pad=$((content - ${#msg})); [ "$msg_pad" -ge 0 ] || msg_pad=0

  activity=$(printf '%s' "$activity" | cut -c1-"$content")
  local activity_color="$C_DIM"
  case "$style" in
    ok)   activity_color="$C_OK" ;;
    fail) activity_color="$C_FAIL" ;;
  esac
  local act_pad=$((content - ${#activity})); [ "$act_pad" -ge 0 ] || act_pad=0

  printf '%s\n' "$top"
  printf '%s%s %s%s%s%s%s%s%s%s\n' \
    "$side_l" "$icon" "$C_BOLD" "$part_label" "$C_RESET" "$head_pad" "$C_DIM" "$time_label" "$C_RESET" "$side_r"
  printf '%s\n' "$mid"
  printf '%s%s%s%s%*s%s\n' "$side_l" "$C_BOLD" "$msg" "$C_RESET" "$msg_pad" '' "$side_r"
  printf '%s%s%s%s%*s%s\n' "$side_l" "$activity_color" "$activity" "$C_RESET" "$act_pad" '' "$side_r"
  printf '%s\n' "$bot"
}

run_part() {
  local msg="$1"; shift
  CURRENT_PART=$((CURRENT_PART + 1))

  ( "$@" ) >>"$LOG" 2>&1 </dev/null &
  local pid=$! start_ts=$SECONDS elapsed=0 line rc

  [ "$TUI_LIVE" = "1" ] && tput civis 2>/dev/null
  printf '\n'
  SPINNER_IDX=0
  progress_paint "$msg" 0 "Working..."
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.4
    elapsed=$((SECONDS - start_ts))
    SPINNER_IDX=$((SPINNER_IDX + 1))

    line=$(tail -c 500 "$LOG" 2>/dev/null | tr '\r' '\n' \
             | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p}' | tail -n 1)
    [ -n "$line" ] || line="Working..."
    if [ "$TUI_LIVE" = "1" ]; then tput cuu "$PROGRESS_BOX_LINES" 2>/dev/null; printf '\r'; fi
    progress_paint "$msg" "$elapsed" "$line"
  done

  elapsed=$((SECONDS - start_ts))
  wait "$pid"
  rc=$?
  if [ "$TUI_LIVE" = "1" ]; then tput cuu "$PROGRESS_BOX_LINES" 2>/dev/null; printf '\r'; fi
  if [ "$rc" -eq 0 ]; then
    progress_paint "$msg" "$elapsed" "Done." "ok"
  else
    progress_paint "$msg" "$elapsed" "Failed - see $LOG" "fail"
  fi
  [ "$TUI_LIVE" = "1" ] && tput cnorm 2>/dev/null
  printf '\n'

  [ "$rc" -eq 0 ] || die "Step failed: $msg (see $LOG)"
}

### PREFLIGHT (PLAIN TERMINAL, DIALOG NOT AVAILABLE YET) ###
preflight_root() { [ "$(id -u)" -eq 0 ] || { echo "ERROR: run this script as root." >&2; exit 1; }; }

preflight_cowspace() {
  local cow="/run/archiso/cowspace"
  local fstype total_kb target_kb current_kb cap_kb

  fstype=$(findmnt -no FSTYPE "$cow" 2>/dev/null) || return 0
  [ "$fstype" = "tmpfs" ] || return 0

  total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
  [ -n "$total_kb" ] || return 0

  target_kb=$((total_kb * 60 / 100))
  cap_kb=$((8 * 1024 * 1024))
  [ "$target_kb" -le "$cap_kb" ] || target_kb="$cap_kb"

  current_kb=$(df -k --output=size "$cow" 2>/dev/null | tail -n1 | tr -dc '0-9')
  if [ -n "$current_kb" ] && [ "$target_kb" -le "$current_kb" ]; then
    return 0  # already big enough (e.g. cow_spacesize= was already passed at boot)
  fi

  echo "Live session write space is limited ($cow, 256M by default) -- growing it to ~$((target_kb / 1024 / 1024))G so the install has room..."
  mount -o "remount,size=${target_kb}k" "$cow" \
    || echo "WARNING: could not grow $cow; large installs may fail with 'No space left on device'. You can also pass cow_spacesize=4G on the kernel command line at boot." >&2
}

preflight_tools() {
  local need=()
  command -v dialog      >/dev/null 2>&1 || need+=(dialog)
  command -v sgdisk      >/dev/null 2>&1 || need+=(gptfdisk)
  command -v wipefs      >/dev/null 2>&1 || need+=(util-linux)
  command -v partprobe   >/dev/null 2>&1 || need+=(parted)
  command -v mkfs.fat    >/dev/null 2>&1 || need+=(dosfstools)
  command -v mkfs.ext4   >/dev/null 2>&1 || need+=(e2fsprogs)
  command -v mkfs.btrfs  >/dev/null 2>&1 || need+=(btrfs-progs)
  command -v mkfs.xfs    >/dev/null 2>&1 || need+=(xfsprogs)
  command -v mkfs.f2fs   >/dev/null 2>&1 || need+=(f2fs-tools)
  command -v rankmirrors >/dev/null 2>&1 || need+=(pacman-contrib)
  command -v sudo        >/dev/null 2>&1 || need+=(sudo)
  command -v lspci       >/dev/null 2>&1 || need+=(pciutils)
  command -v lvs         >/dev/null 2>&1 || need+=(lvm2)
  command -v cryptsetup  >/dev/null 2>&1 || need+=(cryptsetup)
  command -v mdadm       >/dev/null 2>&1 || need+=(mdadm)
  command -v curl        >/dev/null 2>&1 || need+=(curl)
  command -v gpg         >/dev/null 2>&1 || need+=(gnupg)
  if [ "${#need[@]}" -gt 0 ]; then
    echo "Installing host-side tools: ${need[*]}" >&2
    pacman -Sy --noconfirm --needed "${need[@]}" \
      || { echo "Could not install required tools. Aborting." >&2; exit 1; }
  fi
  command -v dialog >/dev/null 2>&1 && HAVE_DIALOG=1
}

detect_boot_mode() {
  if [ -d /sys/firmware/efi/efivars ]; then
    BOOT_MODE="uefi"
  else
    BOOT_MODE="bios"
  fi
}

detect_gpu() {
  local pci; pci=$(lspci -nnk 2>/dev/null | grep -iE 'vga|3d|display' || true)
  if   grep -qiE 'amd|ati|advanced micro devices|radeon' <<<"$pci"; then GPU_VENDOR="amd"
  elif grep -qi 'intel' <<<"$pci"; then GPU_VENDOR="intel"
  elif grep -qi 'nvidia' <<<"$pci"; then
    GPU_VENDOR="nvidia"
    if grep -qiE 'rtx|gtx *16[3-9][0-9]' <<<"$pci"; then
      NVIDIA_TIER="rtx"
    else
      NVIDIA_TIER="legacy"
    fi
  else GPU_VENDOR="unknown"
  fi
}

detect_system_settings() {
  local km="" loc="" tz="" a
  local -a args=()

  if [ -r /etc/vconsole.conf ]; then
    km=$(sed -n 's/^KEYMAP="\?\([^"]*\)"\?.*/\1/p' /etc/vconsole.conf | head -n1)
  fi
  if [ -z "$km" ] && [ -r /etc/conf.d/keymaps ]; then
    km=$(sed -n 's/^keymap="\?\([^"]*\)"\?.*/\1/p' /etc/conf.d/keymaps | head -n1)
  fi

  # 2. How the ISO was booted. Arch/Artix images use several spellings.
  if [ -r /proc/cmdline ]; then
    read -ra args < /proc/cmdline
    for a in "${args[@]}"; do
      case "$a" in
        vconsole.keymap=?*) [ -z "$km" ]  && km="${a#vconsole.keymap=}" ;;
        keytable=?*)        [ -z "$km" ]  && km="${a#keytable=}" ;;
        keymap=?*)          [ -z "$km" ]  && km="${a#keymap=}" ;;
        locale.LANG=?*)     [ -z "$loc" ] && loc="${a#locale.LANG=}" ;;
        lang=?*)            [ -z "$loc" ] && loc="${a#lang=}" ;;
        timezone=?*)        [ -z "$tz" ]  && tz="${a#timezone=}" ;;
        tz=?*)              [ -z "$tz" ]  && tz="${a#tz=}" ;;
      esac
    done
  fi

  if [ -z "$loc" ] && [ -r /etc/locale.conf ]; then
    loc=$(sed -n 's/^LANG="\?\([^"]*\)"\?.*/\1/p' /etc/locale.conf | head -n1)
  fi
  [ -z "$loc" ] && loc="${LANG:-}"
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    tz=$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')
  fi

  if [ -n "$km" ] && [ ! -d /usr/share/kbd/keymaps ]; then

    KEYMAP="$km"
  elif [ -n "$km" ] && find /usr/share/kbd/keymaps -name "$km.map.gz" -print -quit 2>/dev/null | grep -q .; then
    KEYMAP="$km"
  else
    KEYMAP="$DEFAULT_KEYMAP"
  fi

  case "$loc" in
    C|C.*|POSIX|"") loc="" ;;
  esac
  case "$loc" in
    *.*) LOCALE="$loc" ;;
    *)   LOCALE="$DEFAULT_LOCALE" ;;
  esac

  if [ -n "$tz" ] && [ -e "/usr/share/zoneinfo/$tz" ]; then
    TIMEZONE="$tz"
  else
    TIMEZONE="$DEFAULT_TIMEZONE"
  fi

  echo "Detected settings -- keymap: $KEYMAP, locale: $LOCALE, timezone: $TIMEZONE" >>"$LOG" 2>&1
}

### INIT SYSTEM + DISTRO DETECTION ###
detect_init_and_distro() {
  case "$(ps -p 1 -o comm=)" in
    systemd)     INIT_SYSTEM="systemd" ;;
    s6-svscan)   INIT_SYSTEM="s6" ;;
    runit-init)  INIT_SYSTEM="runit" ;;
    dinit)       INIT_SYSTEM="dinit" ;;
    openrc-init) INIT_SYSTEM="openrc" ;;
    *)
      if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then INIT_SYSTEM="systemd"
      elif command -v s6-rc &>/dev/null; then INIT_SYSTEM="s6"
      elif command -v sv &>/dev/null; then INIT_SYSTEM="runit"
      elif command -v dinitctl &>/dev/null; then INIT_SYSTEM="dinit"
      elif command -v rc-update &>/dev/null; then INIT_SYSTEM="openrc"
      else INIT_SYSTEM="unknown"
      fi
      ;;
  esac

  if [ "$INIT_SYSTEM" = "unknown" ]; then
    ask --backtitle "$BACKTITLE" --title "Init System" --menu \
      "Couldn't auto-detect the init system from PID 1.\nWhich one does this live environment match?" 15 60 5 \
      systemd "systemd (Arch Linux)" \
      openrc  "OpenRC (Artix)" \
      runit   "runit (Artix)" \
      s6      "s6 (Artix)" \
      dinit   "dinit (Artix)" \
      || die "Installation cancelled."
    INIT_SYSTEM=$(<"$WORKDIR/ans")
    [ -z "$INIT_SYSTEM" ] && die "No init system selected."
  fi

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    DISTRO="arch"
    DISTRO_LABEL="Arch Linux"
    STRAP_CMD="pacstrap"
    CHROOT_CMD="arch-chroot"
    BOOTLOADER_ID="ArchLinux"
  else
    DISTRO="artix"
    DISTRO_LABEL="Artix Linux"
    STRAP_CMD="basestrap"
    CHROOT_CMD="artix-chroot"
    BOOTLOADER_ID="Artix"
  fi

  if ! command -v "$STRAP_CMD" &>/dev/null || ! command -v "$CHROOT_CMD" &>/dev/null; then
    die "$STRAP_CMD/$CHROOT_CMD not found. Run this from the matching $DISTRO_LABEL live ISO."
  fi

  case "$INIT_SYSTEM" in
    systemd) INIT_BASE_PKGS="" ;;
    openrc)  INIT_BASE_PKGS="openrc elogind-openrc" ;;
    runit)   INIT_BASE_PKGS="runit elogind-runit" ;;
    s6)      INIT_BASE_PKGS="s6-base elogind-s6" ;;
    dinit)   INIT_BASE_PKGS="dinit elogind-dinit" ;;
  esac
}

init_svc_pkg() { printf '%s-%s' "$1" "$INIT_SYSTEM"; }

### DESKTOP ENVIRONMENT PACKAGE SETS (pacman, Arch/Artix only) ###
gpu_packages() {
  case "$GPU_VENDOR" in
    amd)   printf '%s' "mesa vulkan-radeon vulkan-icd-loader" ;;
    intel) printf '%s' "mesa vulkan-intel vulkan-icd-loader" ;;
    nvidia)
      case "$NVIDIA_TIER" in
        legacy) printf '%s' "linux-headers nvidia-580xx-dkms" ;;
        *)      printf '%s' "linux-headers nvidia-open-dkms" ;;
      esac
      ;;
    *)     printf '%s' "mesa" ;;
  esac
}

fs_packages() {
  case "$1" in
    btrfs) printf '%s' "btrfs-progs" ;;
    xfs)   printf '%s' "xfsprogs" ;;
    f2fs)  printf '%s' "f2fs-tools" ;;
    *)     printf '%s' "" ;;
  esac
}

de_packages() {
  case "$1" in
    kde)      printf '%s' "plasma-meta sddm dolphin konsole plasma-nm" ;;
    gnome)    printf '%s' "gnome gnome-tweaks gdm" ;;
    xfce)     printf '%s' "xfce4 xfce4-goodies lightdm lightdm-gtk-greeter network-manager-applet" ;;
    mate)     printf '%s' "mate mate-extra lightdm lightdm-gtk-greeter network-manager-applet" ;;
    cinnamon) printf '%s' "cinnamon lightdm lightdm-gtk-greeter network-manager-applet" ;;
  esac
}

de_display_manager() {
  case "$1" in
    kde)                 printf '%s' "sddm" ;;
    gnome)                printf '%s' "gdm" ;;
    xfce|mate|cinnamon)  printf '%s' "lightdm" ;;
  esac
}

de_label() {
  case "$1" in
    kde)      printf '%s' "KDE Plasma" ;;
    gnome)    printf '%s' "GNOME" ;;
    xfce)     printf '%s' "XFCE" ;;
    mate)     printf '%s' "MATE" ;;
    cinnamon) printf '%s' "Cinnamon" ;;
  esac
}

setup_theme() {
  cat > "$WORKDIR/dialogrc" <<'EOF'
use_shadow = OFF
use_colors = ON
screen_color = (CYAN,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = (CYAN,BLACK,ON)
border_color = (CYAN,BLACK,ON)
button_active_color = (BLACK,CYAN,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_key_active_color = (BLACK,CYAN,ON)
button_key_inactive_color = (CYAN,BLACK,ON)
button_label_active_color = (BLACK,CYAN,ON)
button_label_inactive_color = (WHITE,BLACK,ON)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (CYAN,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (CYAN,BLACK,ON)
item_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,CYAN,ON)
tag_color = (CYAN,BLACK,ON)
tag_selected_color = (BLACK,CYAN,ON)
tag_key_color = (CYAN,BLACK,ON)
tag_key_selected_color = (BLACK,CYAN,ON)
check_color = (WHITE,BLACK,OFF)
check_selected_color = (BLACK,CYAN,ON)
uarrow_color = (CYAN,BLACK,ON)
darrow_color = (CYAN,BLACK,ON)
border2_color = (CYAN,BLACK,ON)
inputbox_border2_color = (CYAN,BLACK,ON)
menubox_border2_color = (CYAN,BLACK,ON)
EOF
  export DIALOGRC="$WORKDIR/dialogrc"
}

transition_screen() {
  local msg="${1:-}"
  [ "$TUI_LIVE" = "1" ] || return 0
  tput sgr0 2>/dev/null
  clear 2>/dev/null
  if [ -n "$msg" ]; then
    local cols rows col row
    cols=$(term_width); rows=$(tput lines 2>/dev/null || echo 24)
    col=$(( (cols - ${#msg}) / 2 )); [ "$col" -ge 0 ] || col=0
    row=$((rows / 2))
    tput cup "$row" "$col" 2>/dev/null
    printf '%s%s%s%s' "$C_BORDER" "$C_BOLD" "$msg" "$C_RESET"
    sleep 0.6
    tput sgr0 2>/dev/null
    clear 2>/dev/null
  fi
}

### TUI SCREENS ###
welcome_screen() {
  dialog --backtitle "$BACKTITLE" --title "Welcome" --msgbox \
"This will erase a disk of your choosing and install $DISTRO_LABEL.\n\nDetected init:      $INIT_SYSTEM\nDetected boot mode: $BOOT_MODE\nDetected keymap:    $KEYMAP\nDetected locale:    $LOCALE\nDetected timezone:  $TIMEZONE\n\nPress OK to begin." 17 60 1>/dev/tty
}

get_username() {
  while true; do
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --inputbox "Username for the new account:" 10 60 \
      || die "Installation cancelled."
    NEW_USER=$(<"$WORKDIR/ans")
    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "$NEW_USER" != "root" ]; then break; fi
    dialog --backtitle "$BACKTITLE" --msgbox "Invalid username. Lowercase letters/digits/-/_, starting with a letter or _." 9 60 1>/dev/tty
  done
}

get_hostname() {
  local default="${DEFAULT_HOSTNAME:-$DISTRO}"
  while true; do
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --inputbox "Hostname:" 10 50 "$default" \
      || die "Installation cancelled."
    NEW_HOSTNAME=$(<"$WORKDIR/ans")
    [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] && break
    dialog --backtitle "$BACKTITLE" --msgbox "Invalid hostname. Letters, digits, and - only." 8 50 1>/dev/tty
  done
}

get_password() {
  local prompt="$1" p1 p2
  while true; do
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --insecure --passwordbox "$prompt" 10 60 \
      || die "Installation cancelled."
    p1=$(<"$WORKDIR/ans")
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --insecure --passwordbox "Confirm password:" 10 60 \
      || die "Installation cancelled."
    p2=$(<"$WORKDIR/ans")
    if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then printf '%s' "$p1"; return 0; fi

    dialog --backtitle "$BACKTITLE" --msgbox "Passwords were empty or did not match. Try again." 8 60 1>/dev/tty
  done
}

select_drive() {
  local args=() line dev size model
  while IFS= read -r line; do
    dev=$(awk '{print $1}' <<<"$line")
    size=$(awk '{print $2}' <<<"$line")
    model=$(cut -d' ' -f3- <<<"$line")
    args+=("$dev" "$size  $model")
  done < <(lsblk -dpno NAME,SIZE,MODEL -e7,11)
  [ "${#args[@]}" -gt 0 ] || die "No disks found."

  ask --backtitle "$BACKTITLE" --title "Select Disk (2/5)" \
    --menu "Choose the disk to install $DISTRO_LABEL onto.\nALL DATA ON THE CHOSEN DISK WILL BE ERASED." 18 70 8 "${args[@]}" \
    || die "Installation cancelled."
  DISK=$(<"$WORKDIR/ans")

  dialog --backtitle "$BACKTITLE" --title "Confirm" --yesno \
    "This will ERASE ALL DATA on $DISK and install $DISTRO_LABEL ($INIT_SYSTEM, $BOOT_MODE).\n\nContinue?" 10 60 1>/dev/tty \
    || die "Aborted — disk not touched."

  BOOT_PART=$(part_path "$DISK" 1)
  SWAP_PART=$(part_path "$DISK" 2)
  ROOT_PART=$(part_path "$DISK" 3)
}

select_filesystem() {
  local args=() fs
  for fs in ext4 btrfs xfs f2fs; do
    if ensure_fs_module "$fs"; then
      case "$fs" in
        ext4)  args+=(ext4 "EXT4") ;;
        btrfs) args+=(btrfs "BTRFS") ;;
        xfs)   args+=(xfs "XFS") ;;
        f2fs)  args+=(f2fs "F2FS") ;;
      esac
    else
      echo "Filesystem '$fs' has no usable kernel module here; leaving it out of the menu." >>"$LOG" 2>&1
    fi
  done
  [ "${#args[@]}" -gt 0 ] \
    || die "This live environment can't mount any of ext4/btrfs/xfs/f2fs. Boot a matching ISO."

  ask --backtitle "$BACKTITLE" --title "Filesystem (3/5)" --default-item "ext4" \
    --menu "Filesystem for the root partition:" 15 60 4 \
    "${args[@]}" \
    || die "Installation cancelled."
  FS_CHOICE=$(<"$WORKDIR/ans")

  if dialog --backtitle "$BACKTITLE" --title "Filesystem (3/5)" --yesno "Encrypt the root partition with LUKS?" 8 60 1>/dev/tty; then
    ENCRYPT="yes"
    LUKS_PASS=$(get_password "Enter the LUKS encryption password:")
  else
    ENCRYPT="no"
  fi
}

select_de() {
  ask --backtitle "$BACKTITLE" --title "Desktop Environment (4/5)" --default-item "kde" \
    --menu "Choose a desktop environment:" 15 60 5 \
    kde "KDE Plasma" gnome "GNOME" xfce "XFCE" mate "MATE" cinnamon "Cinnamon" \
    || die "Installation cancelled."
  DE_CHOICE=$(<"$WORKDIR/ans")
}

confirm_and_summarize() {
  dialog --backtitle "$BACKTITLE" --title "Confirm" --yesno \
"About to install $DISTRO_LABEL onto $DISK:\n\nInit:       $INIT_SYSTEM\nBoot:       $BOOT_MODE\nFilesystem: $FS_CHOICE\nEncrypted:  $ENCRYPT\nHostname:   $NEW_HOSTNAME\nUser:       $NEW_USER\nDesktop:    $(de_label "$DE_CHOICE")\nTimezone:   $TIMEZONE\nLocale:     $LOCALE\nKeymap:     $KEYMAP\n\nProceed?" 20 60 1>/dev/tty \
    || die "Aborted — disk not touched."
}

### HEAVY LIFTING ###
wait_for_device() {
  local dev="$1" max="${2:-50}" tries=0
  while [ ! -b "$dev" ] && [ "$tries" -lt "$max" ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  [ -b "$dev" ]
}

partitions_present() {
  local dev
  for dev in "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; do
    [ -b "$dev" ] || return 1
  done
  return 0
}

teardown_disk_holders() {
  local disk="$1" base p mp vg dm
  base=$(basename "$disk")

  swapoff -a 2>/dev/null || true
  umount -R "$TARGET" 2>/dev/null || true

  # Deepest mountpoint first, so nested mounts come apart cleanly.
  while IFS= read -r mp; do
    [ -n "$mp" ] && umount -R "$mp" 2>/dev/null || true
  done < <(lsblk -lnpo MOUNTPOINT "$disk" 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -r)
  for p in "${disk}"*; do umount "$p" 2>/dev/null || true; done

  # LVM volume groups with a physical volume on this disk.
  if command -v pvs >/dev/null 2>&1; then
    while IFS= read -r vg; do
      [ -n "$vg" ] && vgchange -an "$vg" >/dev/null 2>&1 || true
    done < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null \
               | awk -v d="$disk" '$1 ~ "^"d {print $2}' | sort -u)
  fi

  # MD arrays assembled from this disk.
  command -v mdadm >/dev/null 2>&1 && mdadm --stop --scan >/dev/null 2>&1

  # Whatever device-mapper nodes are left (LUKS, stale leftovers) that sit on it.
  if command -v dmsetup >/dev/null 2>&1; then
    while IFS= read -r dm; do
      [ -n "$dm" ] || continue
      if dmsetup deps -o devname "$dm" 2>/dev/null | grep -q "$base"; then
        cryptsetup close "$dm" >/dev/null 2>&1 \
          || dmsetup remove -f "$dm" >/dev/null 2>&1 || true
      fi
    done < <(dmsetup ls 2>/dev/null | grep -v 'No devices' | awk '{print $1}')
  fi
}

reread_partition_table() {
  local disk="$1"

  blockdev --rereadpt "$disk" >/dev/null 2>&1 || true
  partprobe "$disk" >/dev/null 2>&1 || true
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=10 >/dev/null 2>&1 || sleep 2
  else
    sleep 2
  fi
}

ensure_fs_module() {
  local fs="$1" mod="$1"
  case "$fs" in
    fat|vfat) mod="vfat" ;;
  esac
  grep -qw "$mod" /proc/filesystems 2>/dev/null && return 0
  modprobe "$mod" >/dev/null 2>&1 || true
  grep -qw "$mod" /proc/filesystems 2>/dev/null
}

size_to_mib() {
  local s n unit
  s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  n=$(printf '%s' "$s" | tr -cd '0-9')
  unit=$(printf '%s' "$s" | tr -cd 'A-Z')
  [ -n "$n" ] || n=0
  case "$unit" in
    T*) printf '%s' $((n * 1024 * 1024)) ;;
    G*) printf '%s' $((n * 1024)) ;;
    M*) printf '%s' "$n" ;;
    K*) printf '%s' $((n / 1024)) ;;
    *)  printf '%s' "$n" ;;
  esac
}

computed_swap_mib() {
  local disk="$1" bytes want cap
  bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || bytes=0
  [ -n "$bytes" ] || bytes=0
  want=$(size_to_mib "$SWAP_SIZE")
  cap=$((bytes / 1048576 / 4))
  [ "$cap" -gt 0 ] 2>/dev/null || cap="$want"
  [ "$want" -gt "$cap" ] && want="$cap"
  [ "$want" -lt 512 ] && want=512
  printf '%s' "$want"
}

do_partitioning() {
  ensure_fs_module "$FS_CHOICE" \
    || { echo "The running kernel has no $FS_CHOICE support and modprobe couldn't load it." >&2; return 1; }
  if [ "$BOOT_MODE" = "uefi" ]; then
    ensure_fs_module vfat \
      || { echo "The running kernel has no vfat support; the ESP can't be mounted." >&2; return 1; }
  fi

  echo "Releasing anything holding $DISK (mounts, LVM, MD, device-mapper)..."
  teardown_disk_holders "$DISK"

  echo "Wiping old signatures and partition table on $DISK..."
  wipefs -af "$DISK" || true
  sgdisk -Z "$DISK" || true
  reread_partition_table "$DISK"
  sgdisk -o "$DISK" || true

  local swap_mib; swap_mib=$(computed_swap_mib "$DISK")
  echo "Partitioning $DISK ($BOOT_MODE, ${swap_mib}MiB swap)..."
  if [ "$BOOT_MODE" = "uefi" ]; then
    sgdisk -n 1:0:"+$EFI_SIZE" -t 1:ef00 -c 1:"EFI System" "$DISK"
  else
    sgdisk -n 1:0:"+$BIOS_BOOT_SIZE" -t 1:ef02 -c 1:"BIOS boot" "$DISK"
  fi
  sgdisk -n 2:0:"+${swap_mib}M" -t 2:8200 -c 2:"Linux swap" "$DISK"
  sgdisk -n 3:0:0               -t 3:8300 -c 3:"Linux root" "$DISK"
  reread_partition_table "$DISK"

  local attempt
  for attempt in 1 2 3; do
    wait_for_device "$ROOT_PART" 25 || true
    partitions_present && break
    echo "Partition nodes not visible yet; asking the kernel to re-read (attempt $attempt)..."
    reread_partition_table "$DISK"
  done
  if ! partitions_present; then
    echo "Partition device nodes never appeared -- the kernel did not pick up the new table." >&2
    echo "--- sgdisk -p $DISK ---" >&2; sgdisk -p "$DISK" >&2 2>&1 || true
    echo "--- lsblk $DISK ---"     >&2; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK" >&2 2>&1 || true
    echo "--- holders ---"         >&2; ls -1 /sys/block/"$(basename "$DISK")"/holders 2>/dev/null >&2 || true
    dmsetup ls >&2 2>&1 || true
    return 1
  fi

  echo "Clearing stale signatures on the new partitions..."
  local part
  for part in "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; do
    wipefs -af "$part" >/dev/null 2>&1 || true
  done

  if [ "$BOOT_MODE" = "uefi" ]; then
    echo "Formatting ESP..."
    mkfs.fat -F32 -n EFI "$BOOT_PART" || return 1
  fi

  echo "Creating swap..."
  mkswap -L swap "$SWAP_PART" || return 1
  swapon "$SWAP_PART" || return 1

  local root_target="$ROOT_PART"
  if [ "$ENCRYPT" = "yes" ]; then
    echo "Encrypting root with LUKS..."
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks1 --batch-mode "$ROOT_PART" --key-file=- \
      || return 1

    LUKS_UUID=$(blkid -o value -s UUID "$ROOT_PART")
    echo "$LUKS_UUID" > "$WORKDIR/luks_uuid"
    printf '%s' "$LUKS_PASS" | cryptsetup luksOpen "$ROOT_PART" cryptroot --key-file=- \
      || return 1
    root_target="/dev/mapper/cryptroot"
  fi

  echo "Formatting root ($FS_CHOICE)..."
  case "$FS_CHOICE" in
    f2fs)  mkfs.f2fs -f  -l "$DISTRO" "$root_target" || return 1 ;;
    xfs)   mkfs.xfs  -f  -L "$DISTRO" "$root_target" || return 1 ;;
    btrfs) mkfs.btrfs -f -L "$DISTRO" "$root_target" || return 1 ;;
    *)     mkfs.ext4 -F  -L "$DISTRO" "$root_target" || return 1 ;;
  esac
  command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 >/dev/null 2>&1

  local seen; seen=$(blkid -o value -s TYPE "$root_target" 2>/dev/null)
  echo "Root filesystem on $root_target reads as: ${seen:-unrecognised}"

  echo "Mounting root..."
  mount -t "$FS_CHOICE" "$root_target" "$TARGET" || return 1

  if [ "$BOOT_MODE" = "uefi" ]; then
    mkdir -p "$TARGET/boot/efi"
    mount -t vfat "$BOOT_PART" "$TARGET/boot/efi" || return 1
  fi
}

### REPOSITORY INTEGRATION (HOST SIDE) ###
detect_cpu_level() {
    local lvl

    lvl=$(/lib/ld-linux-x86-64.so.2 --help 2>&1 \
            | grep -v 'not supported' \
            | grep -E '\(supported' \
            | head -n 1 | awk '{print $1}')
    case "$lvl" in
        x86-64-v4) echo "v4" ;;
        x86-64-v3) echo "v3" ;;
        *)         echo "" ;;
    esac
}

write_pacman_conf() {
  local distro="$1" cpu_level="$2" alhp_ok="$3"
  local arch_line base_mirrorlist native_repos tiered_repos repo

  case "$cpu_level" in
    v3) arch_line="x86_64 x86_64_v3" ;;
    v4) arch_line="x86_64 x86_64_v4" ;;
    *)  arch_line="auto" ;;
  esac

  if [ "$distro" = "artix" ]; then
    native_repos="system world galaxy lib32"
    tiered_repos="extra multilib"
    base_mirrorlist="/etc/pacman.d/mirrorlist-arch"
  else
    native_repos=""
    tiered_repos="core extra multilib"
    base_mirrorlist="/etc/pacman.d/mirrorlist"
  fi

  {
    printf '[options]\nHoldPkg     = pacman glibc\nArchitecture = %s\nColor\nParallelDownloads = 10\nSigLevel    = Required DatabaseOptional\nLocalFileSigLevel = Optional\n\n' "$arch_line"

    for repo in $native_repos; do
      printf '[%s]\nInclude = /etc/pacman.d/mirrorlist\n\n' "$repo"
    done

    for repo in $tiered_repos; do
      if [ "$alhp_ok" = "true" ]; then
        [ "$cpu_level" = "v4" ] && printf '[%s-x86-64-v4]\nInclude = /etc/pacman.d/alhp-mirrorlist\n\n' "$repo"
        { [ "$cpu_level" = "v3" ] || [ "$cpu_level" = "v4" ]; } && printf '[%s-x86-64-v3]\nInclude = /etc/pacman.d/alhp-mirrorlist\n\n' "$repo"
      fi
      printf '[%s]\nInclude = %s\n\n' "$repo" "$base_mirrorlist"
    done

    [ "$distro" = "artix" ] && printf '[auris]\nSigLevel = Required\nServer = https://auris.artixlinux.org/api/packages/auris/arch/$repo/$arch\n\n'

    printf '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n'
  } > /etc/pacman.conf
}

setup_repo_integration() {
  local CPU_LEVEL
### IMPORT REPOSITORY KEYS ###
echo "Importing repository keys..."

pacman-key --init

curl -s https://raw.githubusercontent.com/chaotic-aur/.github/refs/heads/main/profile/README.md \
    | grep -Eo "pacman-key --recv-key [0-9A-F]+" \
    | sed "s/--recv-key \([0-9A-F]*\)/--recv-key \1; pacman-key --lsign-key \1/" \
    | bash

if [ "$DISTRO" = "artix" ]; then
    curl https://auris.artixlinux.org/api/packages/auris/arch/repository.key -o /root/auris.key
    gpg --show-keys /root/auris.key
    pacman-key --add /root/auris.key
    pacman-key --lsign-key 74E5750C4A3C00F037070EF2357B525A97500B9F
    rm -f /root/auris.key

    pacman -Sy --noconfirm --needed artix-archlinux-support pacman-contrib artix-keyring archlinux-keyring artix-mirrorlist archlinux-mirrorlist < <(yes '')
    pacman-key --populate archlinux artix
else
    pacman -Sy --noconfirm --needed pacman-contrib archlinux-keyring < <(yes '')
    pacman-key --populate archlinux
fi

pacman -U --noconfirm \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' < <(yes '')
pacman-key --populate chaotic

write_pacman_conf "$DISTRO" "" false

pacman -Sy --noconfirm --needed paru base-devel git < <(yes '')

local build_user="sal-builder"
local alhp_ok=false
id "$build_user" >/dev/null 2>&1 || useradd -m -G wheel "$build_user"
echo "$build_user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-sal-builder
chmod 440 /etc/sudoers.d/99-sal-builder

if runuser -l "$build_user" -c 'paru -S --noconfirm --needed alhp-keyring alhp-mirrorlist' < <(yes ''); then
  alhp_ok=true
else
  echo "Building alhp-keyring/alhp-mirrorlist failed; continuing without ALHP repos." >&2
fi
rm -f /etc/sudoers.d/99-sal-builder
userdel -r "$build_user" >/dev/null 2>&1

CPU_LEVEL=$(detect_cpu_level)
echo "Configuring pacman repos (distro: $DISTRO, CPU level: ${CPU_LEVEL:-baseline}, ALHP repos available: $alhp_ok)..."

local repo_label="chaotic-aur"
[ "$DISTRO" = "artix" ] && repo_label="chaotic-aur/auris"

if [ -z "$CPU_LEVEL" ]; then
    echo "CPU is below x86-64-v3 — writing a baseline config with $repo_label but no ALHP repos." >&2
elif [ "$alhp_ok" != "true" ]; then
    echo "CPU supports x86-64-$CPU_LEVEL but ALHP repos failed to build — writing Architecture=x86_64 x86_64_$CPU_LEVEL with $repo_label but no ALHP repos." >&2
fi

write_pacman_conf "$DISTRO" "$CPU_LEVEL" "$alhp_ok"
}

### PERSISTENT PACKAGE INSTALLATION ###
target_has_pkg() {
  pacman -r "$TARGET" -Qi "$1" >/dev/null 2>&1 \
    || pacman -r "$TARGET" -Qg "$1" >/dev/null 2>&1
}

# strap_batch <label> <pkg...> - one transaction, retried up to 5 times.
strap_batch() {
  local label="$1"; shift
  [ "$#" -gt 0 ] || return 0
  local attempt
  for attempt in $(seq 1 "$STRAP_MAX_ATTEMPTS"); do
    echo "$label: $STRAP_CMD attempt $attempt/$STRAP_MAX_ATTEMPTS ($# packages)..."
    if "$STRAP_CMD" "$TARGET" --needed "$@" < <(yes ''); then
      echo "$label: installed."
      return 0
    fi
    if [ "$attempt" -lt "$STRAP_MAX_ATTEMPTS" ]; then
      echo "$label: attempt $attempt failed, retrying in ${STRAP_RETRY_DELAY}s..." >&2
      sleep "$STRAP_RETRY_DELAY"
    fi
  done
  echo "$label: all $STRAP_MAX_ATTEMPTS attempts failed." >&2
  return 1
}

strap_each() {
  local label="$1"; shift
  local pkg attempt
  STRAP_SKIPPED=()
  for pkg in "$@"; do
    [ -n "$pkg" ] || continue
    if target_has_pkg "$pkg"; then
      echo "$label: $pkg is already installed, skipping."
      continue
    fi
    for attempt in $(seq 1 "$STRAP_MAX_ATTEMPTS"); do
      echo "$label: installing $pkg (attempt $attempt/$STRAP_MAX_ATTEMPTS)..."
      if "$STRAP_CMD" "$TARGET" --needed "$pkg" < <(yes ''); then
        break
      fi
      if [ "$attempt" -lt "$STRAP_MAX_ATTEMPTS" ]; then
        echo "$label: attempt $attempt failed for $pkg, retrying in ${STRAP_RETRY_DELAY}s..." >&2
        sleep "$STRAP_RETRY_DELAY"
      else
        echo "$label: all $STRAP_MAX_ATTEMPTS attempts failed for $pkg, skipping..." >&2
        STRAP_SKIPPED+=("$pkg")
      fi
    done
  done
  return 0
}

install_group() {
  local label="$1" mode="$2"; shift 2
  [ "$#" -gt 0 ] || return 0

  strap_batch "$label" "$@" && return 0

  echo "$label: batch install failed, falling back to one package at a time..." >&2
  strap_each "$label" "$@"
  [ "${#STRAP_SKIPPED[@]}" -gt 0 ] || return 0

  if [ "$mode" = "critical" ]; then
    echo "ERROR: these packages are required for a bootable system and could not be installed:" >&2
    printf '  - %s\n' "${STRAP_SKIPPED[@]}" >&2
    return 1
  fi

  FAILED_PACKAGES+=("${STRAP_SKIPPED[@]}")
  echo "$label: continuing without ${#STRAP_SKIPPED[@]} package(s)." >&2
  return 0
}

do_bootstrap() {
  echo "Ranking mirrors (this can take a minute)..."
  if timeout "$RANKMIRRORS_TIMEOUT" rankmirrors -n 6 -m "$RANKMIRRORS_PER_MIRROR_TIMEOUT" /etc/pacman.d/mirrorlist \
       > /etc/pacman.d/mirrorlist.ranked 2>/dev/null \
     && grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist.ranked; then
    mv /etc/pacman.d/mirrorlist.ranked /etc/pacman.d/mirrorlist
  else
    echo "Mirror ranking failed, timed out, or produced no servers; keeping the default mirrorlist." >&2
    rm -f /etc/pacman.d/mirrorlist.ranked
  fi

  setup_repo_integration

  local nm_svc_pkg="" dbus_svc_pkg=""
  if [ "$INIT_SYSTEM" != "systemd" ]; then
    nm_svc_pkg=$(init_svc_pkg networkmanager)
    dbus_svc_pkg=$(init_svc_pkg dbus)
  fi

  local bootloader_pkgs
  if [ "$BOOT_MODE" = "uefi" ]; then
    bootloader_pkgs="grub efibootmgr"
  else
    bootloader_pkgs="grub"
  fi

  local critical_packages=(base linux linux-firmware mkinitcpio iptables)
  [ -n "$INIT_BASE_PKGS" ] && critical_packages+=($INIT_BASE_PKGS)
  critical_packages+=($bootloader_pkgs)
  local fs_pkg; fs_pkg=$(fs_packages "$FS_CHOICE")
  [ -n "$fs_pkg" ] && critical_packages+=("$fs_pkg")
  [ "$ENCRYPT" = "yes" ] && critical_packages+=(cryptsetup)

  local optional_packages=(base-devel tzdata sudo networkmanager)
  [ -n "$nm_svc_pkg" ] && optional_packages+=("$nm_svc_pkg")
  [ -n "$dbus_svc_pkg" ] && optional_packages+=("$dbus_svc_pkg")
  optional_packages+=(xorg-server xorg-xinit xterm ttf-dejavu)
  optional_packages+=("${EXTRA_PACKAGES[@]}")
  optional_packages+=($(gpu_packages))
  optional_packages+=($(de_packages "$DE_CHOICE"))
  local dm_pkg; dm_pkg=$(de_display_manager "$DE_CHOICE")
  if [ "$INIT_SYSTEM" != "systemd" ] && [ -n "$dm_pkg" ]; then
    local dm_svc_pkg; dm_svc_pkg=$(init_svc_pkg "$dm_pkg")
    [ -n "$dm_svc_pkg" ] && optional_packages+=("$dm_svc_pkg")
  fi

  echo "Running $STRAP_CMD ($DISTRO_LABEL base system + $INIT_SYSTEM + kernel + bootloader + $(de_label "$DE_CHOICE"))..."
  if ! strap_batch "Full package set" "${critical_packages[@]}" "${optional_packages[@]}"; then
    echo "Full package set would not install in one transaction; installing it in groups..." >&2
    install_group "Base system" critical "${critical_packages[@]}" || return 1
    install_group "Desktop and extra packages" optional "${optional_packages[@]}"
  fi

  if [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
    echo "The following packages failed to install and were skipped:" >&2
    printf '  - %s\n' "${FAILED_PACKAGES[@]}" >&2
    printf '%s\n' "${FAILED_PACKAGES[@]}" > "$WORKDIR/failed_packages"
  fi

  echo "Copying repository configuration into the new system..."
  cp /etc/pacman.conf "$TARGET/etc/pacman.conf"
  install -d -m 755 "$TARGET/etc/pacman.d"
  for f in mirrorlist mirrorlist-arch chaotic-mirrorlist alhp-mirrorlist; do
    [ -f "/etc/pacman.d/$f" ] && cp "/etc/pacman.d/$f" "$TARGET/etc/pacman.d/$f"
  done
  rm -rf "$TARGET/etc/pacman.d/gnupg"
  cp -a /etc/pacman.d/gnupg "$TARGET/etc/pacman.d/gnupg"

  # genfstab is Arch's name for the same tool Artix calls fstabgen.
  local fstab_cmd="fstabgen"
  [ "$DISTRO" = "arch" ] && fstab_cmd="genfstab"

  echo "Generating fstab..."
  "$fstab_cmd" -U "$TARGET" >> "$TARGET/etc/fstab" || return 1

  sed -i -e 's/flush_merge,//' -e 's/,flush_merge//' -e 's/\bflush_merge\b//' "$TARGET/etc/fstab"

  install -d -m 700 "$TARGET/root"
  printf '%s:%s\nroot:%s\n' "$NEW_USER" "$USER_PASS" "$ROOT_PASS" > "$TARGET/root/.sal-creds"
  chmod 600 "$TARGET/root/.sal-creds"
}

write_chroot_script() {
  cat > "$TARGET/root/sal-configure.sh" <<'CHROOT_SCRIPT_EOF'
#!/bin/bash
set -uo pipefail

INIT_SYSTEM="@@INIT_SYSTEM@@"
BOOTLOADER_ID="@@BOOTLOADER_ID@@"
BOOT_MODE="@@BOOT_MODE@@"
NEW_HOSTNAME="@@NEW_HOSTNAME@@"
NEW_USER="@@NEW_USER@@"
USER_GROUPS="@@USER_GROUPS@@"
TIMEZONE="@@TIMEZONE@@"
LOCALE="@@LOCALE@@"
KEYMAP="@@KEYMAP@@"
DISK="@@DISK@@"
DE_CHOICE="@@DE_CHOICE@@"
ROOT_PART="@@ROOT_PART@@"
ENCRYPT="@@ENCRYPT@@"
LUKS_UUID="@@LUKS_UUID@@"

echo "Configuring timezone/clock..."
if [ -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
else
    echo "Unknown timezone '$TIMEZONE', falling back to UTC." >&2
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
fi
hwclock --systohc

echo "Configuring locale..."
if grep -q "^#${LOCALE} " /etc/locale.gen; then
    sed -i "s/^#${LOCALE} /${LOCALE} /" /etc/locale.gen
elif ! grep -q "^${LOCALE} " /etc/locale.gen; then
    echo "Locale '$LOCALE' not found in locale.gen, falling back to en_US.UTF-8." >&2
    LOCALE="en_US.UTF-8"
    sed -i "s/^#${LOCALE} /${LOCALE} /" /etc/locale.gen
fi
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "Configuring console keymap ($KEYMAP)..."
if [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
else
    mkdir -p /etc/conf.d
    printf 'keymap="%s"\n' "$KEYMAP" > /etc/conf.d/keymaps
fi

echo "Configuring X11 keyboard layout..."
XKB_LAYOUT="${KEYMAP%%-*}"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKB_EOF
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "${XKB_LAYOUT}"
EndSection
XKB_EOF

echo "Configuring hostname..."
echo "$NEW_HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${NEW_HOSTNAME}.localdomain ${NEW_HOSTNAME}
HOSTS_EOF

echo "Creating user $NEW_USER..."
GROUPS_FINAL=""
IFS=',' read -ra WANT_GROUPS <<< "$USER_GROUPS"
for g in "${WANT_GROUPS[@]}"; do
    [ -n "$g" ] || continue
    getent group "$g" >/dev/null 2>&1 && GROUPS_FINAL="${GROUPS_FINAL:+$GROUPS_FINAL,}$g"
done
echo "Groups for $NEW_USER: ${GROUPS_FINAL:-<none>}"
if [ -n "$GROUPS_FINAL" ]; then
    useradd -m -G "$GROUPS_FINAL" -s /bin/bash "$NEW_USER" \
      || { echo "useradd failed for $NEW_USER -- aborting." >&2; exit 1; }
else
    useradd -m -s /bin/bash "$NEW_USER" \
      || { echo "useradd failed for $NEW_USER -- aborting." >&2; exit 1; }
fi

mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
grep -q '^[[:space:]]*@includedir /etc/sudoers.d' /etc/sudoers \
  || grep -q '^[[:space:]]*#includedir /etc/sudoers.d' /etc/sudoers \
  || echo "@includedir /etc/sudoers.d" >> /etc/sudoers

echo "Setting passwords..."
chpasswd < /root/.sal-creds || { echo "chpasswd failed -- aborting." >&2; exit 1; }
rm -f /root/.sal-creds

for acct in root "$NEW_USER"; do
    case "$(passwd -S "$acct" 2>/dev/null | awk '{print $2}')" in
        P) echo "Password set for $acct." ;;
        *) echo "WARNING: $acct has no usable password -- login will fail." >&2 ;;
    esac
done

if [ "$ENCRYPT" = "yes" ]; then
    echo "Embedding a LUKS keyfile into the initramfs..."
    dd bs=512 count=4 if=/dev/urandom of=/boot/volume.key status=none
    chmod 000 /boot/volume.key
    printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey "$ROOT_PART" /boot/volume.key --key-file=- \
        || { echo "cryptsetup luksAddKey failed -- aborting configuration." >&2; exit 1; }

    echo "cryptroot  UUID=$LUKS_UUID  /boot/volume.key  luks" >> /etc/crypttab

    if ! grep -q '/boot/volume.key' /etc/mkinitcpio.conf; then
        if grep -q '^FILES=' /etc/mkinitcpio.conf; then
            sed -i "s#^FILES=(\(.*\))#FILES=(\1 /boot/volume.key)#" /etc/mkinitcpio.conf
            sed -i 's#^FILES=( #FILES=(#' /etc/mkinitcpio.conf
        else
            echo 'FILES=(/boot/volume.key)' >> /etc/mkinitcpio.conf
        fi
    fi

    if ! grep -qE '^HOOKS=\([^)]*\bencrypt\b' /etc/mkinitcpio.conf; then
        sed -i 's/\bfilesystems\b/encrypt filesystems/' /etc/mkinitcpio.conf
    fi
fi

echo "Regenerating initramfs..."
mkinitcpio -P || { echo "mkinitcpio failed -- aborting configuration." >&2; exit 1; }

if [ "$ENCRYPT" = "yes" ]; then
    grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub 2>/dev/null \
        || echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
fi

echo "Installing bootloader (GRUB, $BOOT_MODE)..."
if [ "$BOOT_MODE" = "uefi" ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$BOOTLOADER_ID" \
        || { echo "grub-install failed -- aborting configuration." >&2; exit 1; }
else
    grub-install --target=i386-pc "$DISK" \
        || { echo "grub-install failed -- aborting configuration." >&2; exit 1; }
fi

if [ "$ENCRYPT" = "yes" ] \
   && ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\bcryptdevice=' /etc/default/grub; then
    sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=\"#GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$LUKS_UUID:cryptroot cryptkey=rootfs:/boot/volume.key #" /etc/default/grub
fi

if ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*[[:space:]])?rw([[:space:]][^"]*)?"' /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="rw /' /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg || { echo "grub-mkconfig failed -- aborting configuration." >&2; exit 1; }

if [ "$ENCRYPT" = "yes" ] && ! grep -q 'cryptdevice=' /boot/grub/grub.cfg; then
    echo "WARNING: /boot/grub/grub.cfg has no cryptdevice= parameter -- the encrypted root will likely fail to unlock at boot." >&2
fi

if ! grep -qE '(^|[[:space:]])rw([[:space:]]|$)' /boot/grub/grub.cfg; then
    echo "WARNING: /boot/grub/grub.cfg has no 'rw' kernel parameter -- root will likely boot read-only." >&2
fi

enable_service_persist() {
    local svc="$1" runlevel="${2:-default}" ok=0
    case "$INIT_SYSTEM" in
        systemd)
            systemctl enable "$svc" >/dev/null 2>&1 && ok=1
            ;;
        openrc)
            if [ -f "/etc/init.d/$svc" ]; then
                rc-update add "$svc" "$runlevel" >/dev/null 2>&1 && ok=1
            fi
            ;;
        runit)
            if [ -d "/etc/runit/sv/$svc" ]; then
                mkdir -p /etc/runit/runsvdir/default
                ln -sf "/etc/runit/sv/$svc" "/etc/runit/runsvdir/default/$svc" && ok=1
            fi
            ;;
        s6)
            if command -v s6 >/dev/null 2>&1; then
                s6 set enable "$svc" >/dev/null 2>&1 && ok=1
            fi
            if [ "$ok" -ne 1 ] && [ -d "/etc/s6/sv/$svc" ]; then
                mkdir -p /etc/s6/adminsv/default/contents.d
                touch "/etc/s6/adminsv/default/contents.d/$svc" && ok=1
            fi
            ;;
        dinit)
            if [ -e "/etc/dinit.d/$svc" ]; then
                mkdir -p /etc/dinit.d/boot.d
                ln -sf "../$svc" "/etc/dinit.d/boot.d/$svc" && ok=1
            fi
            ;;
    esac
    if [ "$ok" -eq 1 ]; then
        echo "Enabled service: $svc"
    else
        echo "WARNING: could not enable service '$svc' under $INIT_SYSTEM (not installed?)." >&2
    fi
}

if [ "$INIT_SYSTEM" != "systemd" ]; then
    echo "Enabling dbus and elogind under $INIT_SYSTEM..."
    enable_service_persist dbus
    enable_service_persist elogind boot
fi

if [ "$INIT_SYSTEM" != "systemd" ]; then
    echo "Setting up PipeWire autostart under $INIT_SYSTEM..."
    cat > /usr/local/bin/sal-pipewire-launch <<'PW_EOF'
#!/bin/bash
exec /usr/bin/pipewire &
sleep 1
exec /usr/bin/wireplumber &
exec /usr/bin/pipewire-pulse &
PW_EOF
    chmod 755 /usr/local/bin/sal-pipewire-launch

    mkdir -p /etc/xdg/autostart
    cat > /etc/xdg/autostart/sal-pipewire.desktop <<'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Comment=Starts the PipeWire audio/video server, WirePlumber, and the PulseAudio-compatible socket
Exec=/usr/local/bin/sal-pipewire-launch
NoDisplay=true
X-GNOME-Autostart-Phase=WindowManager
DESKTOP_EOF
fi

echo "Enabling NetworkManager under $INIT_SYSTEM..."
enable_service_persist NetworkManager

echo "Enabling display manager for $DE_CHOICE..."
case "$DE_CHOICE" in
    kde)                 enable_service_persist sddm ;;
    gnome)               enable_service_persist gdm ;;
    xfce|mate|cinnamon)  enable_service_persist lightdm ;;
esac

if [ "$DE_CHOICE" = "kde" ]; then
    echo "Installing a pacman hook to refresh the Plasma menu cache as the real user..."
    cat > /usr/local/bin/sal-refresh-sycoca <<'SYCOCA_EOF'
#!/bin/bash
u=$(ps -eo user:32,comm | awk '$2 == "plasmashell" { print $1; exit }')
[ -n "$u" ] && su - "$u" -c 'kbuildsycoca6 --noincremental' >/dev/null 2>&1
exit 0
SYCOCA_EOF
    chmod 755 /usr/local/bin/sal-refresh-sycoca

    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/95-sal-kbuildsycoca.hook <<'HOOK_EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Path
Target = usr/share/applications/*
Target = usr/share/kservices6/*
Target = usr/share/kservicetypes6/*

[Action]
Description = Refreshing the Plasma application menu cache...
When = PostTransaction
Exec = /usr/local/bin/sal-refresh-sycoca
HOOK_EOF
fi

if [ "$INIT_SYSTEM" = "s6" ]; then
    if command -v s6 >/dev/null 2>&1; then
        echo "Committing and installing the s6-rc service set..."
        s6 set commit && s6 live install --init \
            || echo "s6 set commit/live install reported an issue; check $LOG and verify services on first boot." >&2
    elif command -v s6-db-reload >/dev/null 2>&1; then
        echo "Rebuilding the s6-rc database..."
        s6-db-reload || echo "s6-db-reload reported an issue; it will be rebuilt on first boot anyway." >&2
    fi
fi

echo "Chroot-side configuration complete."
CHROOT_SCRIPT_EOF

  sed -i \
    -e "s#@@INIT_SYSTEM@@#${INIT_SYSTEM}#g" \
    -e "s#@@BOOTLOADER_ID@@#${BOOTLOADER_ID}#g" \
    -e "s#@@BOOT_MODE@@#${BOOT_MODE}#g" \
    -e "s#@@NEW_HOSTNAME@@#${NEW_HOSTNAME}#g" \
    -e "s#@@NEW_USER@@#${NEW_USER}#g" \
    -e "s#@@USER_GROUPS@@#${USER_GROUPS}#g" \
    -e "s#@@TIMEZONE@@#${TIMEZONE}#g" \
    -e "s#@@LOCALE@@#${LOCALE}#g" \
    -e "s#@@KEYMAP@@#${KEYMAP}#g" \
    -e "s#@@DISK@@#${DISK}#g" \
    -e "s#@@DE_CHOICE@@#${DE_CHOICE}#g" \
    -e "s#@@ROOT_PART@@#${ROOT_PART}#g" \
    -e "s#@@ENCRYPT@@#${ENCRYPT}#g" \
    -e "s#@@LUKS_UUID@@#${LUKS_UUID}#g" \
    "$TARGET/root/sal-configure.sh"
  chmod 700 "$TARGET/root/sal-configure.sh"
}

do_configure() {
  cp /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true
  write_chroot_script
  echo "Entering chroot to finish configuration..."
  "$CHROOT_CMD" "$TARGET" /bin/bash /root/sal-configure.sh || return 1
  rm -f "$TARGET/root/sal-configure.sh" "$TARGET/root/.sal-creds"
}

finish_screen() {
  mkdir -p "$TARGET/var/log" 2>/dev/null
  cp "$LOG" "$TARGET/var/log/sal-install.log" 2>/dev/null || true
  if [ -n "$SKIPPED_PACKAGES" ]; then
    dialog --backtitle "$BACKTITLE" --title "Packages skipped" --msgbox \
"These packages could not be installed after $STRAP_MAX_ATTEMPTS attempts each\nand were skipped:\n\n$SKIPPED_PACKAGES\n\nThe system is installed and bootable. You can install them\nlater with pacman. Details are in /var/log/sal-install.log." 22 70 1>/dev/tty
  fi
  swapoff "$SWAP_PART" >/dev/null 2>&1 || true
  umount -R "$TARGET" >/dev/null 2>&1 || echo "Could not cleanly unmount $TARGET; safe to reboot anyway." >&2
  [ "$ENCRYPT" = "yes" ] && cryptsetup close cryptroot >/dev/null 2>&1 || true
  local n
  for n in 3 2 1; do
    dialog --backtitle "$BACKTITLE" --title "Complete (5/5)" --infobox \
"$DISTRO_LABEL install complete.\n\nRemove installation media now.\nRebooting in $n..." 9 55 1>/dev/tty
    sleep 1
  done
}

main() {
  : > "$LOG" 2>/dev/null || LOG="/tmp/sal-install.log"; : > "$LOG"
  preflight_root
  preflight_cowspace
  preflight_tools

  WORKDIR=$(mktemp -d)
  trap '[ "$TUI_LIVE" = "1" ] && tput cnorm 2>/dev/null; rm -rf "$WORKDIR"' EXIT

  setup_theme
  detect_boot_mode
  detect_init_and_distro
  detect_gpu
  detect_system_settings

  welcome_screen
  get_username
  get_hostname
  USER_PASS=$(get_password "Password for $NEW_USER:")
  ROOT_PASS=$(get_password "Root password:")
  select_drive
  select_filesystem
  select_de
  confirm_and_summarize

  transition_screen "Starting installation..."

  run_part "Partitioning $DISK..." do_partitioning
  [ -f "$WORKDIR/luks_uuid" ] && LUKS_UUID=$(<"$WORKDIR/luks_uuid")

  run_part "Installing base system and packages..." do_bootstrap
  # do_bootstrap runs in a subshell, so the skip list comes back through a file.
  [ -f "$WORKDIR/failed_packages" ] && SKIPPED_PACKAGES=$(<"$WORKDIR/failed_packages")

  run_part "Configuring the new system..." do_configure

  finish_screen
  reboot
}

main "$@"
