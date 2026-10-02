#!/usr/bin/env bash
#
# Quattro Desktop for Arch Linux
#
# Extracts the useful Omarchy 4 / Quattro desktop layer:
#   - Hyprland Lua configuration
#   - Quickshell
#   - Omarchy menus / OSD / notifications / lock / panels
#   - themes + wallpapers
#   - useful native desktop applications
#
# Deliberately does NOT install:
#   - AI / coding agents
#   - agent skills / OpenCode config
#   - Omarchy first-run agent provisioning
#   - Omarchy web apps / PWAs
#   - Chromium
#   - Omarchy distro/system provisioning
#   - hardware-specific kernel/driver stack
#   - migrations from the full Omarchy installation
#
# Run as your normal user, NOT as root.
#
# Exact Quattro source:
#   If this script is placed in an Omarchy checkout, that checkout is used.
#   Otherwise it fetches OMARCHY_REF (a branch, tag, or commit) from GitHub.
#
# Examples:
#   ./install.sh
#   OMARCHY_REF=<commit-or-tag> ./install.sh
#   ./install.sh --dry-run
#   ./install.sh --uninstall
#
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_URL="https://github.com/omacom/omarchy.git"
readonly PKGS_REPO_URL="https://github.com/omacom-io/omarchy-pkgs.git"
# Same layout as the official omarchy package. Quattro's privileged commands
# only trust a root-owned tree here, with their commands in /usr/bin.
readonly INSTALL_ROOT="/usr/share/omarchy"
readonly PKG_NAME="omarchy-quattro-standalone"
readonly BIN_DIR="/usr/local/bin"
# Layout used by earlier versions of this script (cleaned up on install).
readonly OLD_INSTALL_ROOT="/usr/local/share/omarchy-quattro"
readonly OLD_ENV_FILE="/etc/profile.d/omarchy-quattro.sh"
readonly USER_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/omarchy-quattro.conf"
readonly BACKUP_ROOT="$HOME/.local/state/omarchy-quattro/backups"

OMARCHY_REF="${OMARCHY_REF:-quattro}"
SOURCE_DIR="${OMARCHY_SOURCE_DIR:-}"
SOURCE_TMP=""
STAGE_DIR=""
STAGE_ROOT=""
DRY_RUN=0
UNINSTALL=0
SETUP_FIREWALL=0
BOOT_SPLASH=""
AUTOLOGIN=""
ENCRYPTED=0
SPLASH_NEEDS_REBUILD=0
USE_OMARCHY_REPO=1
INSTALL_DRIVERS=1
BROWSER="${QUATTRO_BROWSER:-}"
TARGET_USER=""
ORIGINAL_ARGS=()
PROFILE_DIR=""
PROFILE_TMP=""
CONTROL_CENTER_MODE=""
BRAND="${QUATTRO_BRAND:-Archy}"
readonly BUILTIN_PROFILES=(fabian)
readonly BROWSERS=(edge firefox chromium chrome brave brave-origin zen none)

# Omarchy's package repository signing key (from bin/omarchy-update-keyring).
readonly OMARCHY_REPO_KEY="40DFB630FF42BCFFB047046CF0134EE680CAC571"
readonly OMARCHY_REPO_URL='https://pkgs.omarchy.org/stable/$arch'

# Native applications intentionally retained from Quattro's desktop defaults.
PACKAGES=(
  # AUR/build prerequisites (current Arch)
  base-devel
  debugedit
  fakeroot

  # login/session + compositor / shell
  sddm
  hyprland
  hyprland-guiutils
  quickshell
  uwsm
  xdg-desktop-portal
  xdg-desktop-portal-gtk
  xdg-desktop-portal-hyprland
  xdg-utils
  xdg-terminal-exec
  xdg-user-dirs
  libnotify

  # shell / desktop plumbing
  jq
  pacman-contrib
  socat
  inotify-tools
  gum
  grim
  slurp
  wl-clipboard
  brightnessctl
  pamixer
  playerctl
  networkmanager
  bluez
  bluez-utils
  wireplumber
  pipewire
  pipewire-pulse
  pipewire-alsa
  power-profiles-daemon
  udiskie
  fcitx5
  fcitx5-gtk
  fcitx5-qt
  gnome-keyring
  libsecret

  # terminal / shell
  foot
  neovim
  tmux
  btop
  starship
  fzf
  lazygit
  ripgrep
  fd
  bat
  eza
  zoxide
  fastfetch

  # native GUI defaults
  nautilus
  sushi
  evince
  imv
  mpv

  # screenshots / media / utilities used by Quattro
  gpu-screen-recorder
  hyprpicker
  hyprsunset
  imagemagick
  ffmpegthumbnailer
  tesseract
  tesseract-data-eng
  yt-dlp

  # fonts / icons
  noto-fonts
  noto-fonts-cjk
  noto-fonts-emoji
  ttf-jetbrains-mono-nerd
  woff2-font-awesome
  adwaita-icon-theme

  # basic tools used by Omarchy helper scripts
  git
  curl
  unzip
  tree
  # lspci: omarchy-install-gaming-gpu-lib32 and the hw-detect helpers need it;
  # without it the Steam/Lutris/Heroic installs silently skip the GPU driver.
  pciutils
  # Install > Development (Ruby, Go, Python, Rust, ...) is built on mise.
  mise

  # Wayland/media plumbing Omarchy ships in its hardware manifest
  qt6-wayland
  gst-plugin-pipewire
  pipewire-jack
  alsa-utils
  linux-firmware
  webp-pixbuf-loader

  # printing
  cups
  cups-filters
  cups-pk-helper
  system-config-printer

  # removable media / network shares in Nautilus
  gvfs-mtp
  gvfs-nfs
  gvfs-smb
  dosfstools
  exfatprogs

  # networking niceties (mDNS hostnames, thunderbolt, wifi reg domain, auto TZ)
  avahi
  nss-mdns
  bolt
  wireless-regdb
  tzupdate

  # text extraction / dictation support (OCR -> clipboard, typed injection)
  zbar
  qrencode
  wtype

  # boot splash (matches the styled SDDM login already installed below)
  plymouth

  # Fido2 sudo/auth support (Setup > Security > Fido2 in the Omarchy menu)
  pam-u2f

  # firewall (installed, NOT enabled automatically -- see install_packages)
  ufw

  # shell tools the manual documents as part of the standard toolkit
  man-db
  plocate
  tldr
  expac
  inxi
  dua-cli

  # icon/theme parity with stock Omarchy
  gnome-themes-extra
  yaru-icon-theme
)

# GUI packages from the earlier draft of this installer that are no longer
# part of the lean desktop. They may be the user's own installs, so removal
# is opt-in: the installer asks before touching them and defaults to "no".
PRUNE_PREVIOUS_EXTRAS=(
  libreoffice-fresh
  pinta
  xournalpp
)

cleanup_tmp() { rm -rf -- "${SOURCE_TMP:-}" "${STAGE_DIR:-}" "${PROFILE_TMP:-}"; }
trap cleanup_tmp EXIT

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    # Drain piped input (e.g. `... | run sudo tee FILE`) so the writer doesn't
    # die of SIGPIPE when the command is only printed.
    [[ -p /dev/stdin ]] && cat >/dev/null
    return 0
  else
    "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_user() {
  (( EUID != 0 )) || die "Internal error: root mode should have handed off to a user."
  need_cmd sudo
  if (( DRY_RUN )); then
    sudo -n -v 2>/dev/null || warn "Dry run: sudo would ask for your password here."
  else
    sudo -v
  fi
}

root_handoff() {
  # Started as root (fresh Arch with only root, or `sudo ./install.sh`).
  # Everything user-facing -- AUR builds (makepkg refuses root), ~/.config,
  # the theme -- must run as the desktop user, so: pick that user, make sure
  # sudo + wheel exist, and re-run this script as them with a temporary
  # password-free sudo grant that is removed when the run ends.
  local user="${TARGET_USER:-${SUDO_USER:-}}"
  [[ $user == root ]] && user=""

  if [[ -z $user ]]; then
    [[ -t 0 ]] || die "Running as root: pass --user NAME for the account that gets the desktop."
    read -r -p "Which user account should get the desktop? " user
    [[ -n $user ]] || die "No user given."
  fi
  [[ $user =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid user name: $user"

  if ! id "$user" >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      echo "+ useradd -m -G wheel -s /bin/bash $user && passwd $user"
    elif [[ -t 0 ]]; then
      local reply
      read -r -p "User '$user' doesn't exist. Create it now? [Y/n] " reply
      [[ $reply =~ ^[Nn]$ ]] && die "Aborted: user '$user' does not exist."
      useradd -m -G wheel -s /bin/bash "$user"
      echo "Set a password for $user (used to log in and unlock the screen):"
      until passwd "$user"; do echo "Try again."; done
    else
      die "User '$user' does not exist (create it first, or run interactively)."
    fi
  fi
  (( $(id -u "$user" 2>/dev/null || echo 1000) >= 1000 )) || die "'$user' is a system account; pick a regular user."

  log "Root mode: installing the desktop for user '$user'"

  if (( DRY_RUN )); then
    echo "+ pacman -S --needed sudo; usermod -aG wheel $user; enable %wheel in sudoers"
    echo "+ (temporary NOPASSWD grant for $user while the installer runs)"
  else
    pacman -Qq sudo >/dev/null 2>&1 || pacman -Sy --needed --noconfirm sudo

    # Quattro's admin prompts and sudo rules are wheel-based (like Omarchy).
    if ! id -nG "$user" | tr ' ' '\n' | grep -qx wheel; then
      log "Adding $user to the wheel group"
      usermod -aG wheel "$user"
    fi
    if ! grep -qsE '^[[:space:]]*%wheel[[:space:]]+ALL[[:space:]]*=[[:space:]]*\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers /etc/sudoers.d/*; then
      log "Allowing the wheel group to use sudo (/etc/sudoers.d/10-wheel)"
      printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
      chmod 0440 /etc/sudoers.d/10-wheel
      visudo -cqf /etc/sudoers.d/10-wheel || { rm -f /etc/sudoers.d/10-wheel; die "Could not enable sudo for wheel."; }
    fi
  fi

  # The script (and an Omarchy checkout next to it) may live in /root, which
  # the user can't read: hand them private copies.
  [[ -f $0 ]] || die "Save the script to a file and run it from there (it re-runs itself as $user)."
  local work script
  work="$(mktemp -d /tmp/quattro-install.XXXXXX)"
  script="$work/install.sh"
  cp -- "$0" "$script"
  local src="${OMARCHY_SOURCE_DIR:-}"
  if [[ -z $src && -f ./shell/shell.qml && -d ./default/hypr ]]; then src="$PWD"; fi
  if [[ -z $src && -f ../shell/shell.qml && -d ../default/hypr ]]; then src="$(cd .. && pwd)"; fi
  if [[ -n $src ]]; then
    cp -a -- "$src" "$work/omarchy"
    src="$work/omarchy"
  fi
  if [[ -n $PROFILE_DIR ]]; then
    cp -a -- "$PROFILE_DIR" "$work/profile"
  fi
  chown -R "$user": "$work"
  chmod 0755 "$work" "$script"

  local grant=/etc/sudoers.d/zz-quattro-installer
  if (( ! DRY_RUN )); then
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" > "$grant"
    chmod 0440 "$grant"
    visudo -cqf "$grant" || { rm -f "$grant"; die "Could not create the temporary sudo grant."; }
  fi
  # shellcheck disable=SC2064
  trap "rm -f -- '$grant'; rm -rf -- '$work'" EXIT INT TERM

  local home uid
  home="$(getent passwd "$user" | cut -d: -f6)"
  uid="$(id -u "$user")"
  local runtime_dir=""
  [[ -d /run/user/$uid ]] && runtime_dir="/run/user/$uid"

  # Forward the original arguments minus --user.
  local args=() skip=0 a
  for a in "${ORIGINAL_ARGS[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case "$a" in
      --user|--profile) skip=1 ;;
      --user=*|--profile=*) ;;
      *) args+=("$a") ;;
    esac
  done
  [[ -n $PROFILE_DIR ]] && args+=(--profile "$work/profile")
  [[ -n $BROWSER ]] && args+=(--browser "$BROWSER")

  local rc=0
  (cd "$work" && runuser -u "$user" -- env -i \
    HOME="$home" USER="$user" LOGNAME="$user" SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
    TERM="${TERM:-linux}" LANG="${LANG:-C.UTF-8}" \
    ${runtime_dir:+XDG_RUNTIME_DIR="$runtime_dir"} \
    ${OMARCHY_REF:+OMARCHY_REF="$OMARCHY_REF"} \
    ${src:+OMARCHY_SOURCE_DIR="$src"} \
    bash "$script" "${args[@]}") || rc=$?

  rm -f -- "$grant"
  (( rc == 0 )) && log "Done. Log in as $user after rebooting."
  exit "$rc"
}

bootstrap_prereqs() {
  # find_source() needs git to clone the Omarchy source, and install_yay()
  # needs both git and base-devel (makepkg) to bootstrap yay -- neither is
  # guaranteed to be on a fresh Arch install. Get them before anything else
  # runs, so the script isn't relying on the user having pre-installed the
  # very tool it uses to fetch its own source.
  log "Installing prerequisites (git, base-devel)"

  if (( DRY_RUN )); then
    echo "+ sudo pacman -Sy --needed git base-devel"
    return 0
  fi

  run sudo pacman -Sy --needed git base-devel
}

find_source() {
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -f "$SOURCE_DIR/shell/shell.qml" ]] ||
      die "OMARCHY_SOURCE_DIR does not look like an Omarchy checkout: $SOURCE_DIR"
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
    return
  fi

  # Convenient when the script is copied into the cloned repository.
  if [[ -f "./shell/shell.qml" && -d "./default/hypr" ]]; then
    SOURCE_DIR="$(pwd)"
    return
  fi

  if [[ -f "../shell/shell.qml" && -d "../default/hypr" ]]; then
    SOURCE_DIR="$(cd .. && pwd)"
    return
  fi

  need_cmd git
  SOURCE_TMP="$(mktemp -d)"

  # Use fetch + checkout (rather than `clone --branch`) so OMARCHY_REF can be
  # a branch, a tag, OR a commit SHA. `clone --branch` only accepts refs.
  log "Fetching Omarchy source ($OMARCHY_REF)"
  git init -q "$SOURCE_TMP/omarchy"
  git -C "$SOURCE_TMP/omarchy" remote add origin "$REPO_URL"
  git -C "$SOURCE_TMP/omarchy" fetch --depth 1 origin "$OMARCHY_REF"
  git -C "$SOURCE_TMP/omarchy" checkout -q FETCH_HEAD
  SOURCE_DIR="$SOURCE_TMP/omarchy"
}

backup_path() {
  local path="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  printf '%s/%s-%s' "$BACKUP_ROOT" "$(basename "$path")" "$stamp"
}

backup_existing() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0

  local backup
  backup="$(backup_path "$path")"
  log "Backing up $path -> $backup"
  run mkdir -p "$BACKUP_ROOT"
  if [[ "$path" == /usr/* ]]; then
    run sudo mkdir -p "$BACKUP_ROOT"
    run sudo mv "$path" "$backup"
  else
    run mv "$path" "$backup"
  fi
}

AUR_PACKAGES=()

enable_multilib() {
  # Steam, Wine/Lutris, Heroic and all lib32-* GPU drivers live in [multilib],
  # which a stock Arch install ships commented out. Full Omarchy enables it in
  # its own pacman.conf; without it the Install > Gaming menu fails with
  # "target not found: steam".
  if grep -qE '^\[multilib\]' /etc/pacman.conf; then
    log "multilib repository already enabled"
    return 0
  fi

  log "Enabling the multilib repository"
  run sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%Y%m%d-%H%M%S)"
  run sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

  if (( ! DRY_RUN )) && ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
    # No commented stock block to uncomment (custom pacman.conf): append one.
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' |
      sudo tee -a /etc/pacman.conf >/dev/null
  fi
}

enable_omarchy_repo() {
  # Most Install-menu entries (Spotify, 1Password, Heroic, VSCode, Brave, Zen,
  # xpadneo, the RetroArch -git cores, omazed, ...) are AUR packages that
  # Omarchy prebuilds into its own signed repo, plus a few that exist ONLY
  # there. Full Omarchy's pacman.conf has it; ours didn't, so every install
  # failed with "target not found".
  #
  # It's appended AFTER core/extra/multilib. pacman takes a package from the
  # first repo that has it, so official Arch packages always win and this
  # repo only fills in what Arch doesn't carry.
  (( USE_OMARCHY_REPO )) || { log "Skipping Omarchy package repo (--no-omarchy-repo)"; return 0; }

  if grep -qE '^\[omarchy\]' /etc/pacman.conf; then
    log "Omarchy package repository already configured"
    return 0
  fi

  log "Adding Omarchy's package repository (pkgs.omarchy.org)"

  if (( DRY_RUN )); then
    echo "+ sudo pacman-key --recv-keys $OMARCHY_REPO_KEY --keyserver keys.openpgp.org"
    echo "+ sudo pacman-key --lsign-key $OMARCHY_REPO_KEY"
    echo "+ (append [omarchy] Server = $OMARCHY_REPO_URL to /etc/pacman.conf)"
    return 0
  fi

  # Trust the signing key first; only add the repo if that worked, otherwise
  # every later pacman call would fail on an unverifiable database.
  if ! sudo pacman-key --list-keys "$OMARCHY_REPO_KEY" >/dev/null 2>&1; then
    if ! sudo pacman-key --recv-keys "$OMARCHY_REPO_KEY" --keyserver keys.openpgp.org; then
      warn "Could not fetch Omarchy's signing key; NOT adding its repo. Install-menu apps will build from the AUR instead (slower)."
      return 0
    fi
  fi
  sudo pacman-key --lsign-key "$OMARCHY_REPO_KEY"

  sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%Y%m%d-%H%M%S)"
  printf '\n[omarchy]\nServer = %s\n' "$OMARCHY_REPO_URL" |
    sudo tee -a /etc/pacman.conf >/dev/null
}

install_omarchy_keyring() {
  # Keeps the repo key current across key rotations (same as omarchy-update-keyring).
  (( USE_OMARCHY_REPO )) || return 0
  grep -qE '^\[omarchy\]' /etc/pacman.conf 2>/dev/null || return 0
  pacman -Qq omarchy-keyring >/dev/null 2>&1 && return 0
  run sudo pacman -S --needed --noconfirm omarchy-keyring ||
    warn "omarchy-keyring not available; the manually trusted key still works."
}

pkg_add() {
  # Repo first, AUR for the rest -- the same logic the patched omarchy-pkg-add
  # uses at runtime. Must run after install_yay.
  local repo=() aur=() pkg
  for pkg in "$@"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 && continue
    if (( DRY_RUN )) || pacman -Si "$pkg" >/dev/null 2>&1; then
      repo+=("$pkg")
    else
      aur+=("$pkg")
    fi
  done

  if ((${#repo[@]})); then
    run sudo pacman -S --needed --noconfirm "${repo[@]}" || return 1
  fi
  if ((${#aur[@]})); then
    if command -v yay >/dev/null 2>&1; then
      run yay -S --needed --noconfirm "${aur[@]}" || return 1
    elif command -v paru >/dev/null 2>&1; then
      run paru -S --needed --noconfirm "${aur[@]}" || return 1
    else
      warn "No AUR helper; could not install: ${aur[*]}"
      return 1
    fi
  fi
}

install_packages() {
  log "Installing Arch packages"

  # Current Arch only: refresh and fully synchronize before installing anything.
  run sudo pacman -Syu --needed

  local missing=()
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} == 0)); then
    log "All required Arch packages are already installed."
    return
  fi

  # A handful of names on this list (tzupdate, yaru-icon-theme, ...) come from
  # Omarchy's own package manifest, which its ISO resolves against extra repos
  # a stock Arch install doesn't have. Split into what plain pacman can
  # actually see vs. what needs the AUR, so one unknown name doesn't take the
  # whole install down with it.
  local repo_pkgs=() aur_pkgs=()
  for pkg in "${missing[@]}"; do
    if (( DRY_RUN )) || pacman -Si "$pkg" >/dev/null 2>&1; then
      repo_pkgs+=("$pkg")
    else
      aur_pkgs+=("$pkg")
    fi
  done

  if ((${#repo_pkgs[@]})); then
    run sudo pacman -S --needed "${repo_pkgs[@]}"
  fi

  if ((${#aur_pkgs[@]})); then
    warn "Not in the official repos, will install from the AUR: ${aur_pkgs[*]}"
    AUR_PACKAGES+=("${aur_pkgs[@]}")
  fi
}

prune_previous_extras() {
  local installed=()
  local pkg
  for pkg in "${PRUNE_PREVIOUS_EXTRAS[@]}"; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
      installed+=("$pkg")
    fi
  done

  ((${#installed[@]})) || return 0

  log "Packages from the earlier installer draft are installed: ${installed[*]}"

  # These may be the user's own installs, not leftovers from a previous run
  # of this script. Never remove software silently or with --noconfirm;
  # default to keeping it when we can't ask (dry run or no tty).
  if (( DRY_RUN )) || [[ ! -t 0 ]]; then
    warn "Skipping removal of ${installed[*]} (non-interactive or dry run)."
    return 0
  fi

  local reply
  read -r -p "Remove them? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    run sudo pacman -Rns "${installed[@]}"
  fi
}

install_yay() {
  command -v yay >/dev/null 2>&1 && { log "yay already installed"; return 0; }

  log "Installing yay (AUR helper)"

  if (( DRY_RUN )); then
    echo "+ (build yay from https://aur.archlinux.org/yay.git)"
    return 0
  fi

  command -v git >/dev/null 2>&1 || die "git is required to bootstrap yay."
  command -v makepkg >/dev/null 2>&1 || die "makepkg is required to bootstrap yay."

  local build_dir
  build_dir="$(mktemp -d)"

  git clone --depth 1 https://aur.archlinux.org/yay.git "$build_dir/yay"
  (cd "$build_dir/yay" && makepkg -si --noconfirm)
  rm -rf -- "$build_dir"

  command -v yay >/dev/null 2>&1 || die "yay installation completed without a yay executable."
}

install_aur_desktop_packages() {
  # Installs whatever install_packages() couldn't find in the official repos
  # (populated into AUR_PACKAGES there).
  if ((${#AUR_PACKAGES[@]} == 0)); then
    log "No additional AUR packages required"
    return 0
  fi

  log "Installing from the AUR: ${AUR_PACKAGES[*]}"

  if (( DRY_RUN )); then
    echo "+ yay -S --needed --noconfirm ${AUR_PACKAGES[*]}"
    return 0
  fi

  if command -v yay >/dev/null 2>&1; then
    run yay -S --needed --noconfirm "${AUR_PACKAGES[@]}"
  elif command -v paru >/dev/null 2>&1; then
    run paru -S --needed "${AUR_PACKAGES[@]}"
  else
    warn "No AUR helper available; skipping: ${AUR_PACKAGES[*]}"
  fi
}

browser_label() {
  case "$1" in
    edge) echo "Microsoft Edge" ;;
    firefox) echo "Firefox" ;;
    chromium) echo "Chromium" ;;
    chrome) echo "Google Chrome" ;;
    brave) echo "Brave" ;;
    brave-origin) echo "Brave Origin" ;;
    zen) echo "Zen" ;;
    none) echo "none (keep whatever you have)" ;;
  esac
}

browser_desktop_id() {
  case "$1" in
    edge) echo microsoft-edge.desktop ;;
    firefox) echo firefox.desktop ;;
    chromium) echo chromium.desktop ;;
    chrome) echo google-chrome.desktop ;;
    brave) echo brave-browser.desktop ;;
    brave-origin) echo brave-origin.desktop ;;
    zen) echo zen.desktop ;;
  esac
}

choose_browser() {
  # --browser NAME (or QUATTRO_BROWSER) wins; otherwise ask on a terminal and
  # fall back to Edge when nobody can answer.
  if [[ -n $BROWSER ]]; then
    local b
    for b in "${BROWSERS[@]}"; do [[ $b == "$BROWSER" ]] && return 0; done
    die "Unknown browser '$BROWSER'. Choose one of: ${BROWSERS[*]}"
  fi

  if [[ ! -t 0 ]]; then
    BROWSER=edge
    return 0
  fi

  echo
  echo "Which browser should be installed and set as default?"
  local i
  for i in "${!BROWSERS[@]}"; do
    printf '  %d) %s%s\n' "$((i + 1))" "$(browser_label "${BROWSERS[$i]}")" "$( ((i == 0)) && echo '  [default]')"
  done
  local reply
  while :; do
    read -r -p "Browser [1]: " reply
    reply="${reply:-1}"
    if [[ $reply =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#BROWSERS[@]} )); then
      BROWSER="${BROWSERS[$((reply - 1))]}"
      return 0
    fi
    echo "Please enter a number from 1 to ${#BROWSERS[@]}."
  done
}

install_browser() {
  [[ $BROWSER == none ]] && { log "Browser: skipped (--browser none)"; return 0; }
  log "Installing $(browser_label "$BROWSER")"

  # Quattro's own installer: the package (repo/AUR), Wayland flags, managed
  # policy dir for theme-matched colors -- same as Install > Browser.
  run env OMARCHY_PATH="$INSTALL_ROOT" /usr/bin/omarchy-install-browser "$BROWSER" ||
    warn "Installing $BROWSER reported a problem; check the output above. You can retry from the menu: Install > Browser."
}


build_omarchy_pkg() {
  # Builds and installs a package straight from omacom-io/omarchy-pkgs's
  # pkgbuilds/<name> directory. Used for Quattro-adjacent packages that
  # live outside both the official repos and the AUR (omarchy-nvim, ttfx, ...).
  local pkg="$1"

  if pacman -Qq "$pkg" >/dev/null 2>&1; then
    log "$pkg already installed."
    return 0
  fi

  # The [omarchy] repo ships these prebuilt; only compile when it isn't there.
  if pacman -Si "$pkg" >/dev/null 2>&1; then
    log "Installing $pkg (prebuilt, Omarchy package repo)"
    run sudo pacman -S --needed --noconfirm "$pkg"
    return
  fi

  log "Building $pkg from omacom-io/omarchy-pkgs"

  if (( DRY_RUN )); then
    echo "+ (clone $PKGS_REPO_URL, sparse-checkout pkgbuilds/$pkg, makepkg -si)"
    return 0
  fi

  need_cmd git
  need_cmd makepkg

  local tmp
  tmp="$(mktemp -d)"
  # Sparse + blobless clone: this repo hosts PKGBUILDs for dozens of
  # unrelated packages, so only fetch the one directory we need.
  git clone --depth 1 --filter=blob:none --sparse "$PKGS_REPO_URL" "$tmp/omarchy-pkgs"
  git -C "$tmp/omarchy-pkgs" sparse-checkout set "pkgbuilds/$pkg"
  (cd "$tmp/omarchy-pkgs/pkgbuilds/$pkg" && makepkg -si --noconfirm)
  rm -rf -- "$tmp"
}

install_omarchy_nvim() {
  build_omarchy_pkg omarchy-nvim

  # Mirrors upstream's own bin/omarchy-reinstall-configs hook: prefer the
  # in-place refresh command, fall back to first-time setup.
  if (( ! DRY_RUN )); then
    if command -v omarchy-nvim-refresh >/dev/null 2>&1; then
      run omarchy-nvim-refresh
    elif command -v omarchy-nvim-setup >/dev/null 2>&1; then
      run omarchy-nvim-setup --force
    else
      warn "omarchy-nvim installed but neither omarchy-nvim-refresh nor omarchy-nvim-setup was found on PATH; Neovim config was not seeded into \$HOME."
    fi
  fi
}

install_ttfx() {
  # Provides the `ttfx` binary that bin/omarchy-screensaver calls directly
  # (terminal text-effects rendering for the screensaver). Without it the
  # screensaver logs "ttfx: command not found" every time it fires.
  build_omarchy_pkg ttfx
}

gpu_present() {
  # gpu_present <pci-vendor-id>  e.g. 0x10de (NVIDIA), 0x1002 (AMD), 0x8086 (Intel)
  local dev
  for dev in /sys/bus/pci/devices/*; do
    [[ $(<"$dev/vendor") == "$1" && $(<"$dev/class") == 0x03* ]] && return 0
  done
  return 1
}

nvidia_has_gsp() {
  # Turing (0x1e00) and newer: nvidia-open. Same check as omarchy-hw-nvidia-gsp.
  local dev
  for dev in /sys/bus/pci/devices/*; do
    [[ $(<"$dev/vendor") == 0x10de && $(<"$dev/class") == 0x03* ]] || continue
    (( $(<"$dev/device") >= 0x1e00 )) && return 0
  done
  return 1
}

install_kernel_headers() {
  # DKMS drivers (nvidia-open-dkms, xpadneo-dkms, ...) need headers for every
  # installed kernel. Omarchy ships linux-omarchy-headers; we use Arch's.
  local headers=() k
  for k in linux linux-lts linux-zen linux-hardened; do
    pacman -Qq "$k" >/dev/null 2>&1 && headers+=("$k-headers")
  done
  ((${#headers[@]})) || { warn "No stock Arch kernel found; install headers for your kernel yourself so DKMS modules build."; return 0; }
  pkg_add "${headers[@]}"
}

install_gpu_drivers() {
  # Port of Omarchy's install/hardware/{nvidia,vulkan}.sh and intel/*.sh,
  # plus the matching lib32 drivers so Steam/Wine find the right Vulkan ICD
  # (otherwise `pacman --noconfirm steam` picks the first lib32-vulkan provider,
  # which may be for the wrong GPU).
  (( INSTALL_DRIVERS )) || { log "Skipping GPU drivers (--no-drivers)"; return 0; }
  log "Installing GPU drivers / Vulkan / video acceleration"

  local pkgs=(mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools libva-utils)
  local nvidia=0

  if gpu_present 0x1002; then
    log "AMD GPU detected"
    pkgs+=(vulkan-radeon lib32-vulkan-radeon)
  fi

  if gpu_present 0x8086; then
    log "Intel GPU detected"
    pkgs+=(vulkan-intel lib32-vulkan-intel)
    local intel_gpu
    intel_gpu="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -i intel || true)"
    if [[ ${intel_gpu,,} =~ (hd\ graphics|uhd\ graphics|xe|iris|arc|panther\ lake) ]]; then
      pkgs+=(intel-media-driver libvpl vpl-gpu-rt)
    elif [[ ${intel_gpu,,} =~ gma ]]; then
      pkgs+=(libva-intel-driver)
    fi
  fi

  if gpu_present 0x10de; then
    nvidia=1
    if nvidia_has_gsp; then
      log "NVIDIA GPU (Turing or newer) detected: nvidia-open-dkms"
      pkgs+=(nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver egl-wayland)
    else
      log "Older NVIDIA GPU detected: nvidia-580xx legacy branch"
      pkgs+=(nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils egl-wayland)
    fi
    install_kernel_headers
  fi

  pkg_add "${pkgs[@]}" || warn "Some GPU packages failed to install: check the output above."

  if (( nvidia )); then
    # Same kernel-side setup Omarchy's nvidia.sh does. Hyprland's NVIDIA env
    # vars are already handled by default/hypr/nvidia.lua at runtime.
    run sudo mkdir -p /etc/modprobe.d /etc/mkinitcpio.conf.d
    printf 'options nvidia_drm modeset=1\n' | run sudo tee /etc/modprobe.d/nvidia.conf >/dev/null
    printf 'MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' |
      run sudo tee /etc/mkinitcpio.conf.d/nvidia.conf >/dev/null
    if command -v mkinitcpio >/dev/null 2>&1; then
      run sudo mkinitcpio -P
    else
      warn "mkinitcpio not found; regenerate your initramfs yourself so the NVIDIA modules load early."
    fi
  fi
}

install_hardware_extras() {
  # The cheap, safe parts of Omarchy's install/hardware/: Intel audio firmware,
  # thermald on Intel laptops, Wi-Fi regulatory domain from the timezone.
  (( INSTALL_DRIVERS )) || return 0
  log "Applying hardware extras"

  if lspci 2>/dev/null | grep -qiE '(Multimedia audio controller|Audio device).*Intel'; then
    pkg_add sof-firmware || true
  fi

  local on_battery=0 bat
  for bat in /sys/class/power_supply/BAT*; do
    [[ -r $bat/present && $(<"$bat/present") == 1 ]] && on_battery=1
  done
  if (( on_battery )) && grep -q GenuineIntel /proc/cpuinfo; then
    local model
    model="$(grep -m1 '^model[[:space:]]*:' /proc/cpuinfo | cut -d: -f2 | tr -d ' ')"
    if (( ${model:-0} >= 42 )); then
      pkg_add thermald && run sudo systemctl enable thermald.service || true
    fi
  fi

  local regdom=/etc/conf.d/wireless-regdom
  if [[ -f $regdom ]] && ! grep -q '^WIRELESS_REGDOM=' "$regdom"; then
    local tz country
    tz="$(readlink -f /etc/localtime 2>/dev/null || true)"
    tz="${tz#/usr/share/zoneinfo/}"
    country="$(awk -v tz="$tz" '$3 == tz {print $1; exit}' /usr/share/zoneinfo/zone.tab 2>/dev/null || true)"
    if [[ $country =~ ^[A-Z]{2}$ ]]; then
      echo "WIRELESS_REGDOM=\"$country\"" | run sudo tee -a "$regdom" >/dev/null
    fi
  fi
}

install_hyprmon() {
  if command -v hyprmon >/dev/null 2>&1 || pacman -Qq hyprmon-bin >/dev/null 2>&1; then
    log "hyprmon already installed."
    return
  fi

  log "Installing hyprmon-bin (AUR)"

  if command -v yay >/dev/null 2>&1 || (( DRY_RUN )); then
    run yay -S --needed --noconfirm hyprmon-bin
  elif command -v paru >/dev/null 2>&1; then
    run paru -S --needed hyprmon-bin
  else
    warn "No AUR helper available; skipping hyprmon-bin."
  fi
}

arch_wordmark() {
  # ASCII wordmark for the screensaver / omarchy-ascii: "ARCHY" for the default
  # brand, "ARCH LINUX" otherwise.
  if [[ $BRAND == Archy ]]; then
    cat <<'ART'
 █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗
██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝
███████║██████╔╝██║     ███████║ ╚████╔╝
██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝
██║  ██║██║  ██║╚██████╗██║  ██║   ██║
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝
ART
    return 0
  fi
  cat <<'ART'
 █████╗ ██████╗  ██████╗██╗  ██╗    ██╗     ██╗███╗   ██╗██╗   ██╗██╗  ██╗
██╔══██╗██╔══██╗██╔════╝██║  ██║    ██║     ██║████╗  ██║██║   ██║╚██╗██╔╝
███████║██████╔╝██║     ███████║    ██║     ██║██╔██╗ ██║██║   ██║ ╚███╔╝
██╔══██║██╔══██╗██║     ██╔══██║    ██║     ██║██║╚██╗██║██║   ██║ ██╔██╗
██║  ██║██║  ██║╚██████╗██║  ██║    ███████╗██║██║ ╚████║╚██████╔╝██╔╝ ██╗
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝
ART
}

arch_logo() {
  # Arch logo for fastfetch / the About screen (~/.config/omarchy/branding/about.txt).
  cat <<'ART'
                  ▄
                 ▟█▙
                ▟███▙
               ▟█████▙
              ▟███████▙
             ▂▔▀▜█████▙
            ▟██▅▂▝▜█████▙
           ▟█████████████▙
          ▟███████████████▙
         ▟█████████████████▙
        ▟███████████████████▙
       ▟█████████▛▀▀▜████████▙
      ▟████████▛      ▜███████▙
     ▟█████████        ████████▙
    ▟██████████        █████▆▅▄▃▂
   ▟██████████▛        ▜█████████▙
  ▟██████▀▀▀              ▀▀██████▙
 ▟███▀▘                       ▝▀███▙
▟▛▀                               ▀▜▙
ART
}

# >>> BEGIN EMBEDDED FILES (generated by gen_embedded.py) >>>
write_launcher_plugin() {
  # App launcher with category tabs (omarchy.launcher).
  # Generated from source files; do not edit by hand.
  local d="$1"
  mkdir -p "$d"
  cat > "$d/Launcher.qml" <<'QUATTRO_EMBED_0'
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "LauncherModel.js" as LauncherModel

// App launcher with category tabs, styled from the active Omarchy theme's
// [menu] tokens so it matches the Omarchy menu, emojis and clipboard.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property int tabIndex: 0
  property var recent: []
  property var visibleTabs: LauncherModel.TABS.slice(0)
  readonly property var currentTab: root.visibleTabs[Math.min(root.tabIndex, root.visibleTabs.length - 1)]
  property string recentPath: Quickshell.env("HOME") + "/.local/state/omarchy/launcher-recent.json"

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int tabHeight: Math.max(Style.space(32), Style.font.iconLarge + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Style.font.caption + Style.spacing.sm * 2
  property int rowHeight: Math.max(Style.space(48), Style.font.heading + Style.font.bodySmall + Style.spacing.lg * 2)
  property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { }
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.refreshTabs()
    root.tabIndex = root.tabIndexFor(payload.category || "all")
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy.launcher")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function tabIndexFor(id) {
    for (var i = 0; i < root.visibleTabs.length; i++) {
      if (root.visibleTabs[i].id === id) return i
    }
    return 0
  }

  function allEntries(query) {
    if (!root.appLibrary) return []
    var rows = root.appLibrary.sortedEntries(query || "")
    var out = []
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && rows[i].entry) out.push(rows[i].entry)
    }
    return out
  }

  // Hide category tabs no installed app belongs to (All/Recent always stay).
  function refreshTabs() {
    var entries = root.allEntries("")
    var keepId = root.currentTab ? root.currentTab.id : "all"
    var tabs = []
    for (var t = 0; t < LauncherModel.TABS.length; t++) {
      var tab = LauncherModel.TABS[t]
      if (!tab.match) { tabs.push(tab); continue }
      for (var i = 0; i < entries.length; i++) {
        if (LauncherModel.inTab(entries[i], tab)) { tabs.push(tab); break }
      }
    }
    root.visibleTabs = tabs
    root.tabIndex = root.tabIndexFor(keepId)
  }

  function rebuildDisplay() {
    displayModel.clear()
    var tab = root.currentTab
    var query = root.filterText.trim()
    var entries = []

    if (tab && tab.id === "recent") {
      var byId = ({})
      var all = root.allEntries(query)
      for (var a = 0; a < all.length; a++) byId[String(all[a].id || "")] = all[a]
      for (var r = 0; r < root.recent.length; r++) {
        if (byId[root.recent[r]]) entries.push(byId[root.recent[r]])
      }
    } else {
      var candidates = root.allEntries(query)
      for (var c = 0; c < candidates.length; c++) {
        if (LauncherModel.inTab(candidates[c], tab)) entries.push(candidates[c])
      }
    }

    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var subtitle = root.appLibrary ? root.appLibrary.entrySubtext(entry) : ""
      if (!subtitle) subtitle = String(entry.comment || "")
      displayModel.append({
        appId: String(entry.id || ""),
        label: root.appLibrary ? root.appLibrary.entryName(entry) : String(entry.name || ""),
        subtitle: subtitle,
        appIcon: String(entry.icon || "")
      })
    }

    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.rebuildDisplay()
  }

  function setTab(index) {
    if (root.visibleTabs.length === 0) return
    root.tabIndex = (index + root.visibleTabs.length) % root.visibleTabs.length
    root.selectedIndex = 0
    root.rebuildDisplay()
  }

  function move(delta) {
    if (displayModel.count === 0) return
    root.selectedIndex = Math.max(0, Math.min(displayModel.count - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count || !root.appLibrary) return
    var row = displayModel.get(index)
    root.recent = LauncherModel.pushRecent(root.recent, row.appId)
    recentFile.setText(JSON.stringify(root.recent, null, 2) + "\n")
    root.dismiss()
    root.appLibrary.launch(row.appId, row.label)
  }

  ListModel { id: displayModel }

  FileView {
    id: recentFile
    path: root.recentPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.recent = LauncherModel.parseRecent(text())
    onLoadFailed: root.recent = []
    onFileChanged: reload()
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (!root.opened) return
      root.refreshTabs()
      root.rebuildDisplay()
    }
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-launcher"

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || (ctrl && event.key === Qt.Key_Right)) {
            root.setTab(root.tabIndex + 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Backtab || (ctrl && event.key === Qt.Key_Left)) {
            root.setTab(root.tabIndex - 1)
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-Math.max(1, Math.floor(resultList.height / root.rowHeight)))
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.move(Math.max(1, Math.floor(resultList.height / root.rowHeight)))
            event.accepted = true
          } else if (event.key === Qt.Key_Home && !root.filterText) {
            root.move(-displayModel.count)
            event.accepted = true
          } else if (event.key === Qt.Key_End && !root.filterText) {
            root.move(displayModel.count)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Search line
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: searchGlyph
            text: ""
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: searchGlyph.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || ("Search " + (root.currentTab && root.currentTab.id !== "all" ? root.currentTab.label.toLowerCase() + " " : "") + "apps…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        // Category tabs: icon for every tab, label on the active one.
        Row {
          id: tabRow
          width: parent.width
          height: root.tabHeight
          spacing: Style.spacing.sm

          Repeater {
            model: root.visibleTabs

            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool active: index === root.tabIndex

              height: tabRow.height
              width: active ? tabContent.implicitWidth + Style.spacing.controlPaddingX * 2
                            : Math.max(height, tabContent.implicitWidth + Style.spacing.controlPaddingX)
              radius: root.cornerRadius
              color: active ? root.selectedBackground : (tabMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05) : "transparent")

              Row {
                id: tabContent
                anchors.centerIn: parent
                spacing: Style.spacing.md

                Text {
                  text: modelData.icon
                  color: active ? root.selectedText : root.foreground
                  opacity: active ? 1 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  visible: active
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: Font.Medium
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTab(index)
              }
            }
          }
        }

        // App list
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.tabHeight - root.footerHeight - root.contentSpacing * 3

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: Style.spacing.xxs
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: rowItem
              required property int index
              required property string appId
              required property string label
              required property string subtitle
              required property string appIcon
              readonly property bool hasCursor: index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Image {
                id: appIconImage
                width: Style.font.display + Style.spacing.md
                height: width
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.appLibrary ? root.appLibrary.iconSource(rowItem.appIcon) : ""
                asynchronous: true
              }

              Column {
                anchors.left: appIconImage.right
                anchors.leftMargin: Style.spacing.xl
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: rowItem.label
                  color: rowItem.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: rowItem.subtitle.length > 0
                  textFormat: Text.PlainText
                  text: rowItem.subtitle
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.selectedIndex = rowItem.index
                onClicked: root.activateIndex(rowItem.index)
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0
            width: parent.width

            Text {
              text: root.currentTab && root.currentTab.id === "recent" && !root.filterText ? "" : "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.filterText ? "No apps match “" + root.filterText + "”"
                  : (root.currentTab && root.currentTab.id === "recent" ? "Apps you launch will show up here" : "No apps here yet")
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        // Footer hints
        Text {
          width: parent.width
          height: root.footerHeight
          verticalAlignment: Text.AlignVCenter
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: "Tab  categories   ·   Enter  launch   ·   Super+Alt+Space  Omarchy menu"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
QUATTRO_EMBED_0
  chmod 644 "$d/Launcher.qml"
  cat > "$d/LauncherModel.js" <<'QUATTRO_EMBED_1'

// Category tabs, in display order. `match` lists freedesktop Categories
// (https://specifications.freedesktop.org/menu-spec/latest/category-registry.html).
var TABS = [
  { id: "all",         label: "All",         icon: "" },
  { id: "recent",      label: "Recent",      icon: "" },
  { id: "internet",    label: "Internet",    icon: "",
    match: ["Network", "WebBrowser", "Email", "Chat", "InstantMessaging", "IRCClient", "FileTransfer", "P2P", "News", "RemoteAccess"] },
  { id: "media",       label: "Media",       icon: "",
    match: ["AudioVideo", "Audio", "Video", "Music", "Player", "Recorder", "Midi", "Mixer", "TV"] },
  { id: "development", label: "Development", icon: "",
    match: ["Development", "IDE", "TextEditor", "Debugger", "RevisionControl", "WebDevelopment", "Building"] },
  { id: "graphics",    label: "Graphics",    icon: "",
    match: ["Graphics", "2DGraphics", "3DGraphics", "RasterGraphics", "VectorGraphics", "Photography", "Scanning", "OCR"] },
  { id: "office",      label: "Office",      icon: "",
    match: ["Office", "WordProcessor", "Spreadsheet", "Presentation", "Calendar", "ContactManagement", "Finance", "Viewer", "Dictionary"] },
  { id: "games",       label: "Games",       icon: "",
    match: ["Game", "Emulator"] },
  { id: "system",      label: "System",      icon: "",
    match: ["System", "Settings", "Monitor", "PackageManager", "TerminalEmulator", "HardwareSettings", "Security", "DesktopSettings", "Printing"] },
  { id: "utilities",   label: "Utilities",   icon: "",
    match: ["Utility", "Accessories", "Archiving", "Compression", "Calculator", "Clock", "FileManager", "FileTools", "TextTools", "Core"] }
]

function categoriesOf(entry) {
  var out = []
  try {
    var raw = entry ? entry.categories : null
    if (!raw) return out
    if (typeof raw === "string") raw = raw.split(/[;,]/)
    for (var i = 0; i < raw.length; i++) {
      var c = String(raw[i] || "").trim()
      if (c) out.push(c)
    }
  } catch (e) { }
  return out
}

function inTab(entry, tab) {
  if (!tab || !tab.match) return true
  var cats = categoriesOf(entry)
  for (var i = 0; i < cats.length; i++) {
    if (tab.match.indexOf(cats[i]) >= 0) return true
  }
  return false
}

function parseRecent(raw) {
  try {
    var parsed = JSON.parse(raw || "[]")
    if (!Array.isArray(parsed)) return []
    return parsed.filter(function(v) { return typeof v === "string" && v.length > 0 }).slice(0, 20)
  } catch (e) {
    return []
  }
}

function pushRecent(list, id) {
  var next = [id]
  for (var i = 0; i < list.length && next.length < 20; i++) {
    if (list[i] !== id) next.push(list[i])
  }
  return next
}
QUATTRO_EMBED_1
  chmod 644 "$d/LauncherModel.js"
  cat > "$d/manifest.json" <<'QUATTRO_EMBED_2'
{
  "schemaVersion": 1,
  "id": "omarchy.launcher",
  "name": "App launcher",
  "version": "1.0.0",
  "author": "Quattro standalone",
  "description": "Application launcher with search, category tabs and recent apps",
  "kinds": [
    "overlay"
  ],
  "keepLoaded": true,
  "entryPoints": {
    "overlay": "Launcher.qml"
  }
}
QUATTRO_EMBED_2
  chmod 644 "$d/manifest.json"
}

write_control_center_plugin() {
  # Control center overlay + bar button (omarchy.control-center).
  # Generated from source files; do not edit by hand.
  local d="$1"
  mkdir -p "$d"
  mkdir -p "$d/pages"
  cat > "$d/BarWidget.qml" <<'QUATTRO_EMBED_0'
import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.control-center"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    horizontalMargin: 7.5
    tooltipText: "Control center"
    onPressed: function(button) {
      if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.control-center")
    }
  }
}
QUATTRO_EMBED_0
  chmod 644 "$d/BarWidget.qml"
  cat > "$d/ControlCenter.qml" <<'QUATTRO_EMBED_1'
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import QtQuick
import qs.Commons
import qs.Ui
import "../panels/bluetooth/Model.js" as BtModel

// Control center: a sidebar of pages (home, media, audio, display, system,
// power, network, bluetooth, weather, calendar, notifications), styled from
// the theme's [menu] tokens.
//
// Two modes (switch at the bottom of the sidebar, remembered):
//   full  - every page opens inside this window
//   mixed - pages that Omarchy also has a bar panel for (and that panel is on
//           your bar) open that Omarchy panel instead
// Every such page also has an "Open Omarchy panel" button in its header.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // This plugin's own directory (where status.sh / sysinfo.sh live).
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/control-center.json"

  property bool opened: false
  property string page: "home"
  property string mode: "full"
  // Last weather report, kept across page switches so the page opens instantly.
  property var weatherCache: null

  readonly property var pages: [
    { id: "home",          label: "Home",          icon: "" },
    { id: "media",         label: "Media",         icon: "" },
    { id: "audio",         label: "Audio",         icon: "", panel: "omarchy.audio" },
    { id: "display",       label: "Display",       icon: "", panel: "omarchy.monitor" },
    { id: "system",        label: "System",        icon: "" },
    { id: "power",         label: "Power",         icon: "", panel: "omarchy.power" },
    { id: "network",       label: "Network",       icon: "", panel: "omarchy.network" },
    { id: "bluetooth",     label: "Bluetooth",     icon: "", panel: "omarchy.bluetooth" },
    { id: "weather",       label: "Weather",       icon: "", panel: "omarchy.weather" },
    { id: "calendar",      label: "Calendar",      icon: "", panel: "omarchy.clock" },
    { id: "notifications", label: "Notifications", icon: "" }
  ]
  readonly property var currentPage: root.pageById(root.page)

  readonly property var mediaService: root.shell ? root.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property string userName: Quickshell.env("USER") || "user"

  // Theme tokens shared with the pages (they receive this item as `cc`).
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property color subtle: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int gap: Style.spacing.lg
  property int tileHeight: Math.max(Style.space(64), Style.font.iconLarge + Style.font.body + Style.font.caption + Style.spacing.lg * 2)
  property int cardWidth: Math.min(Style.space(780), panel.width - Style.gapsOut * 4)
  property int cardHeight: Math.min(Style.space(620), panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 6)

  // ---- lifecycle --------------------------------------------------------

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { }
    stateFile.reload()
    if (payload.page && root.pageById(payload.page)) root.page = payload.page
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy.control-center")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- helpers the pages use -------------------------------------------

  function run(argv) {
    Quickshell.execDetached(argv)
  }

  function runAndClose(command) {
    root.dismiss()
    Util.execDetached(command)
  }

  function pageById(id) {
    for (var i = 0; i < root.pages.length; i++) if (root.pages[i].id === id) return root.pages[i]
    return null
  }

  // Uses the shell's effective bar config (your shell.json, or Omarchy's
  // default when you have none), so it matches what's really on the bar.
  function panelAvailable(pg) {
    return !!(pg && pg.panel && root.shell && typeof root.shell.barEntryConfigured === "function"
              && root.shell.barEntryConfigured(pg.panel))
  }

  // Same path as Omarchy's own keybinds (shell summon), which opens the
  // panel on the focused monitor's bar. Deferred so this overlay releases
  // keyboard focus first.
  function openBarPanel(pg) {
    if (!root.panelAvailable(pg)) return
    var id = pg.panel
    root.dismiss()
    Qt.callLater(function() { if (root.shell) root.shell.summon(id, "") })
  }

  function selectPage(pg) {
    if (!pg) return
    if (root.mode === "mixed" && root.panelAvailable(pg)) root.openBarPanel(pg)
    else root.page = pg.id
  }

  function stepPage(delta) {
    var idx = 0
    for (var i = 0; i < root.pages.length; i++) if (root.pages[i].id === root.page) idx = i
    root.page = root.pages[(idx + delta + root.pages.length) % root.pages.length].id
  }

  function setMode(next) {
    root.mode = next === "mixed" ? "mixed" : "full"
    stateFile.setText(JSON.stringify({ mode: root.mode }, null, 2) + "\n")
  }



  // ---- Bluetooth discovery (owned here so it is always stopped) ----------
  // A discovery left running stalls Bluetooth audio, and a page can unload
  // mid-scan, so the window (which stays loaded) owns start/stop.
  readonly property var btAdapter: Bluetooth.defaultAdapter
  property bool btDiscoveryWanted: false
  property bool btOwesStop: false

  Timer {
    id: btDiscoveryStart
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.btDiscoveryWanted && !!root.btAdapter && root.btAdapter.enabled && !root.btAdapter.discovering
    onTriggered: {
      try { root.btAdapter.discovering = true; root.btOwesStop = true } catch (e) { }
    }
  }

  // Runs whenever we owe a stop and the adapter reports discovering, so a
  // start that BlueZ confirms only after the page closed is still stopped.
  Timer {
    id: btDiscoveryStop
    property int attempts: 0
    interval: 600
    repeat: true
    running: (!root.opened || !root.btDiscoveryWanted) && root.btOwesStop
             && !!root.btAdapter && root.btAdapter.discovering === true
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      attempts += 1
      if (attempts > 3) {
        root.btOwesStop = false
        return
      }
      try { root.btAdapter.discovering = false } catch (e) { }
    }
  }

  Connections {
    target: root.btAdapter
    function onDiscoveringChanged() {
      if (root.btAdapter && !root.btAdapter.discovering) root.btOwesStop = false
    }
  }

  // A discovery already running when the page opens becomes ours to stop.
  onBtDiscoveryWantedChanged: if (btDiscoveryWanted && btAdapter && btAdapter.discovering) btOwesStop = true

  Component.onDestruction: {
    if (root.btOwesStop && root.btAdapter) {
      try { root.btAdapter.discovering = false } catch (e) { }
    }
  }

  // ---- Bluetooth audio auto-switch ----------------------------------------
  // Same as Omarchy's Bluetooth panel: once headphones/speakers connected from
  // here, make them the audio output as soon as PipeWire creates their sink
  // (retries for ~4 s). Lives in the window so it still runs if the page or
  // the window closes right after clicking Connect.
  property var btAudioTarget: null
  property int btAudioAttempts: 0

  function scheduleBtAudioSwitch(device) {
    if (!device) return
    root.btAudioTarget = {
      address: device.address || "",
      name: device.name || "",
      deviceName: device.deviceName || ""
    }
    root.btAudioAttempts = 0
    btAudioTimer.restart()
  }

  function trySwitchBtAudio() {
    if (!root.btAudioTarget) return
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && BtModel.bluetoothSinkMatchesDevice(n, root.btAudioTarget)) {
        Pipewire.preferredDefaultAudioSink = n
        if (n.id !== undefined && n.name)
          Quickshell.execDetached(["omarchy-audio-output-set-default", String(n.id), String(n.name)])
        root.btAudioTarget = null
        return
      }
    }
    root.btAudioAttempts += 1
    if (root.btAudioAttempts >= 8) root.btAudioTarget = null
    else btAudioTimer.restart()
  }

  Timer {
    id: btAudioTimer
    interval: 500
    onTriggered: root.trySwitchBtAudio()
  }

  // ---- persisted state ---------------------------------------------------

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text() || "{}")
        root.mode = s.mode === "mixed" ? "mixed" : "full"
      } catch (e) { root.mode = "full" }
    }
    onLoadFailed: root.mode = "full"
  }



  // ---- window --------------------------------------------------------------

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-control-center"

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: 0.6
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut * 2
      anchors.rightMargin: Style.gapsOut * 2
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      // The whole content is one FocusScope: when a text field (Wi-Fi
      // password, weather location) loses focus or disappears, focus falls
      // back here, and keys the page doesn't handle bubble up to it.
      FocusScope {
        id: keyCatcher
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        height: card.height - card.contentTopInset - card.contentBottomInset
        focus: true
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (ctrl && (event.key === Qt.Key_Tab || event.key === Qt.Key_PageDown || event.key === Qt.Key_Down)) {
            root.stepPage(1)
            event.accepted = true
          } else if (ctrl && (event.key === Qt.Key_Backtab || event.key === Qt.Key_PageUp || event.key === Qt.Key_Up)) {
            root.stepPage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Left && root.page === "calendar") {
            calendarStep(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right && root.page === "calendar") {
            calendarStep(1)
            event.accepted = true
          }
        }

        Item {
          id: frame
          anchors.fill: parent

        // Sidebar
        Rectangle {
          id: sidebar
          width: Style.space(52)
          height: parent.height
          radius: root.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
          border.width: 1
          border.color: root.subtle

          Column {
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.md
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.sm

            Repeater {
              model: root.pages
              delegate: Button {
                required property var modelData
                iconText: modelData.icon
                tooltipText: modelData.label + (root.mode === "mixed" && root.panelAvailable(modelData) ? "  (opens bar panel)" : "")
                selected: root.page === modelData.id
                foreground: root.foreground
                accent: root.selectedText
                fontFamily: root.fontFamily
                iconSize: Style.font.iconLarge
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.md
                onClicked: root.selectPage(modelData)
              }
            }
          }

          Button {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.md
            anchors.horizontalCenter: parent.horizontalCenter
            iconText: root.mode === "mixed" ? "" : ""
            tooltipText: root.mode === "mixed"
              ? "Mixed: Audio, Display, Power, Network, Bluetooth, Weather and Calendar open their bar panels. Click to keep everything in this window."
              : "Everything in this window. Click to open the bar panels for Audio, Display, Power, Network, Bluetooth, Weather and Calendar instead."
            selected: root.mode === "mixed"
            foreground: root.foreground
            accent: root.selectedText
            fontFamily: root.fontFamily
            iconSize: Style.font.icon
            horizontalPadding: Style.spacing.md
            verticalPadding: Style.spacing.md
            onClicked: root.setMode(root.mode === "mixed" ? "full" : "mixed")
          }
        }

        // Header + page
        Item {
          id: content
          anchors.left: sidebar.right
          anchors.leftMargin: root.gap + Style.spacing.sm
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          Item {
            id: header
            width: parent.width
            height: Math.max(Style.space(34), Style.font.heading + Style.spacing.lg)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.currentPage ? root.currentPage.label : ""
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.weight: Font.Bold
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Button {
                visible: root.panelAvailable(root.currentPage)
                iconText: ""
                text: "Bar panel"
                tooltipText: "Open the " + (root.currentPage ? root.currentPage.label : "") + " panel from the bar"
                bordered: true
                foreground: root.foreground
                accent: root.selectedText
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.sm
                onClicked: root.openBarPanel(root.currentPage)
              }
              Button {
                iconText: ""
                tooltipText: "Settings"
                bordered: true
                foreground: root.foreground
                accent: root.selectedText
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.sm
                onClicked: root.runAndClose("omarchy-menu summon setup")
              }
              Button {
                iconText: ""
                tooltipText: "Power menu"
                bordered: true
                foreground: root.foreground
                accent: root.selectedText
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.sm
                onClicked: root.runAndClose("omarchy-menu summon system")
              }
              Button {
                iconText: ""
                tooltipText: "Close (Esc)"
                bordered: true
                foreground: root.foreground
                accent: root.selectedText
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.sm
                onClicked: root.dismiss()
              }
            }
          }

          Loader {
            id: pageLoader
            anchors.top: header.bottom
            anchors.topMargin: root.gap
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            onLoaded: keyCatcher.forceActiveFocus()
          }
        }
        }
      }
    }
  }

  // Pages get `cc` (this item) as an initial property, so their bindings
  // never see it undefined. Only the visible page is loaded; leaving a page
  // destroys it, which stops its timers and scans.
  function loadPage() {
    if (root.opened) pageLoader.setSource(Qt.resolvedUrl("pages/" + root.pageFile(root.page) + ".qml"), { cc: root })
    else pageLoader.source = ""
  }
  onPageChanged: root.loadPage()
  onOpenedChanged: root.loadPage()

  // Left/Right on the Calendar page change month (keys reach the window's
  // focus scope, not the page).
  function calendarStep(delta) {
    if (pageLoader.item && typeof pageLoader.item.step === "function") pageLoader.item.step(delta)
  }

  function pageFile(id) {
    var map = {
      home: "HomePage", media: "MediaPage", audio: "AudioPage", display: "DisplayPage",
      system: "SystemPage", power: "PowerPage", network: "NetworkPage", bluetooth: "BluetoothPage",
      weather: "WeatherPage", calendar: "CalendarPage", notifications: "NotificationsPage"
    }
    return map[id] || "HomePage"
  }
}
QUATTRO_EMBED_1
  chmod 644 "$d/ControlCenter.qml"
  cat > "$d/manifest.json" <<'QUATTRO_EMBED_2'
{
  "schemaVersion": 1,
  "id": "omarchy.control-center",
  "name": "Control center",
  "version": "1.0.0",
  "author": "Quattro standalone",
  "description": "Quick toggles, media and system info in one panel",
  "kinds": [
    "overlay",
    "bar-widget"
  ],
  "keepLoaded": true,
  "entryPoints": {
    "overlay": "ControlCenter.qml",
    "barWidget": "BarWidget.qml"
  },
  "barWidget": {
    "displayName": "Control center",
    "description": "Opens the control center",
    "category": "System",
    "allowMultiple": false
  }
}
QUATTRO_EMBED_2
  chmod 644 "$d/manifest.json"
  cat > "$d/status.sh" <<'QUATTRO_EMBED_3'
#!/bin/bash
# Prints the control center's state as one JSON object. Read-only; every
# toggle is done by the existing omarchy-* / nmcli commands.

has_wifi=false wifi_on=false ssid="" ethernet=false
if command -v nmcli >/dev/null 2>&1; then
  nmcli -t -f TYPE device 2>/dev/null | grep -qx wifi && has_wifi=true
  [[ $(nmcli radio wifi 2>/dev/null) == enabled ]] && wifi_on=true
  ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
  nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q '^ethernet:connected' && ethernet=true
fi

has_bt=false bt_on=false
if command -v bluetoothctl >/dev/null 2>&1 && [[ -n $(timeout 2 bluetoothctl list 2>/dev/null) ]]; then
  has_bt=true
  omarchy-bluetooth-power is-on >/dev/null 2>&1 && bt_on=true
fi

profiles=$(omarchy-powerprofiles-list --active-state 2>/dev/null)

stay_awake=false
[[ -f $HOME/.local/state/omarchy/indicators/stay-awake ]] && stay_awake=true
nightlight=$(omarchy-toggle-nightlight --status 2>/dev/null | jq -r '.enabled // false' 2>/dev/null)
[[ $nightlight == true ]] || nightlight=false
dnd=false
[[ $(timeout 2 omarchy-shell notifications isDnd 2>/dev/null) == on ]] && dnd=true

jq -cn \
  --argjson hasWifi "$has_wifi" --argjson wifiOn "$wifi_on" --arg ssid "$ssid" \
  --argjson ethernet "$ethernet" \
  --argjson hasBluetooth "$has_bt" --argjson bluetoothOn "$bt_on" \
  --arg profiles "$profiles" \
  --argjson stayAwake "$stay_awake" --argjson nightlight "$nightlight" --argjson dnd "$dnd" \
  --arg host "$(cat /proc/sys/kernel/hostname 2>/dev/null)" \
  --arg uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null)" \
  '{hasWifi:$hasWifi, wifiOn:$wifiOn, ssid:$ssid, ethernet:$ethernet,
    hasBluetooth:$hasBluetooth, bluetoothOn:$bluetoothOn,
    profiles: ($profiles | split("\n") | map(select(length > 0) | split("\t") | {name: .[0], active: (.[1] == "1")})),
    stayAwake:$stayAwake, nightlight:$nightlight, dnd:$dnd,
    host:$host, uptime:(($uptime | tonumber?) // 0)}'
QUATTRO_EMBED_3
  chmod 755 "$d/status.sh"
  cat > "$d/sysinfo.sh" <<'QUATTRO_EMBED_4'
#!/bin/bash
# System snapshot for the control center's System page, as one JSON object.
# Read-only. CPU is reported as raw /proc/stat counters; the page computes
# usage from the difference between two samples.

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
cpu_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
cpu_idle=$((idle + iowait))

read -r mem_total mem_avail swap_total swap_free < <(awk '
  /^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
  END {print t+0, a+0, st+0, sf+0}' /proc/meminfo)

read -r disk_total disk_used < <(df -Pk / 2>/dev/null | awk 'NR==2 {print $2+0, $3+0}')

# Hottest sensor in degrees C (thermal zones + hwmon), 0 if none.
temp=0
for f in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
  [[ -r $f ]] || continue
  v=$(<"$f")
  [[ $v =~ ^[0-9]+$ ]] || continue
  (( v > temp )) && temp=$v
done
temp=$((temp / 1000))

read -r load1 load5 load15 _ < /proc/loadavg
cores=$(nproc 2>/dev/null || echo 1)
cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
kernel=$(uname -r)

# comm last: process names can contain spaces ("Isolated Web Co").
procs=$(ps -eo pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null | head -n 6 |
  awk '{c=$1; m=$2; $1=$2=""; sub(/^ +/, ""); printf "%s\t%s\t%s\n", $0, c, m}')

jq -cn \
  --argjson cpuTotal "${cpu_total:-0}" --argjson cpuIdle "${cpu_idle:-0}" \
  --argjson memTotal "${mem_total:-0}" --argjson memAvail "${mem_avail:-0}" \
  --argjson swapTotal "${swap_total:-0}" --argjson swapFree "${swap_free:-0}" \
  --argjson diskTotal "${disk_total:-0}" --argjson diskUsed "${disk_used:-0}" \
  --argjson temp "${temp:-0}" --argjson cores "${cores:-1}" \
  --arg load "$load1 $load5 $load15" --arg cpuModel "$cpu_model" --arg kernel "$kernel" \
  --arg procs "$procs" \
  '{cpuTotal:$cpuTotal, cpuIdle:$cpuIdle, memTotal:$memTotal, memAvail:$memAvail,
    swapTotal:$swapTotal, swapFree:$swapFree, diskTotal:$diskTotal, diskUsed:$diskUsed,
    temp:$temp, cores:$cores, load:$load, cpuModel:$cpuModel, kernel:$kernel,
    procs: ($procs | split("\n") | map(select(length > 0) | split("\t") | {name: .[0], cpu: (.[1] | tonumber? // 0), mem: (.[2] | tonumber? // 0)}))}'
QUATTRO_EMBED_4
  chmod 755 "$d/sysinfo.sh"
  cat > "$d/pages/AudioPage.qml" <<'QUATTRO_EMBED_5'
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import QtQuick
import qs.Commons
import qs.Ui
import "../../panels/audio/Model.js" as AudioModel

// Audio: output/input volume + device choice, and per-app volume.
// Mirrors Omarchy's audio panel: same device filtering, the same DSP-aware
// output sink, and Repeaters fed from settled snapshots (PipeWire can remove
// nodes mid-signal; rebuilding straight from the live list has crashed).
Item {
  id: page
  property var cc

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) list.push(n)
    }
    return list
  }
  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && !n.isSink && !n.isStream && AudioModel.isAudioSource(n) && String(n.name || "") !== "quickshell") list.push(n)
    }
    return list
  }
  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !AudioModel.isPlaybackStream(n)) continue
      if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
      list.push(n)
    }
    return list
  }

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false
  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    return sinkAvailability[String(node.name)] !== false
  }

  readonly property var audioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) if (sinkAvailable(candidateSinks[i])) list.push(candidateSinks[i])
    if (sink && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }
  readonly property var audioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }
  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++) if (candidateStreams[i].audio) list.push(candidateStreams[i])
    return list
  }

  property var displaySinks: []
  property var displaySources: []
  property var displayStreams: []
  onAudioSinksChanged: snapshotTimer.restart()
  onAudioSourcesChanged: snapshotTimer.restart()
  onAudioStreamsChanged: snapshotTimer.restart()

  // Volume goes to the physical sink behind a DSP/tuning sink (same rule as
  // the volume keys and Omarchy's audio panel).
  property string volumeSinkName: ""
  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio) return n
    }
    return sink
  }
  onSinkChanged: if (!volumeSinkProc.running) volumeSinkProc.running = true

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property real inputVolume: source && source.audio ? source.audio.volume : 0
  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false

  function pct(v) { return Math.round((Number(v) || 0) * 100) + "%" }
  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
  }
  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-input-set-default", String(node.id), String(node.name)])
  }
  function outputIcon() {
    if (page.outputMuted) return "󰝟"
    if (page.volumeSink && AudioModel.isHeadphones(page.volumeSink)) return "󰋋"
    var v = page.outputVolume
    return v >= 0.67 ? "󰕾" : (v >= 0.34 ? "󰖀" : "󰕿")
  }

  PwObjectTracker { objects: page.candidateSinks }
  PwObjectTracker { objects: page.candidateSources }
  PwObjectTracker { objects: page.audioStreams }

  Timer {
    id: snapshotTimer
    interval: 75
    onTriggered: {
      page.displaySinks = AudioModel.listSnapshot(page.audioSinks)
      page.displaySources = AudioModel.listSnapshot(page.audioSources)
      page.displayStreams = AudioModel.listSnapshot(page.audioStreams)
    }
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: page.volumeSinkName = String(text).trim()
    }
  }
  Process {
    id: availabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        page.sinkAvailability = AudioModel.parseSinkAvailability(text)
        page.sinkAvailabilityLoaded = true
      }
    }
  }
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!availabilityProc.running) availabilityProc.running = true
      if (!volumeSinkProc.running) volumeSinkProc.running = true
    }
  }
  Component.onCompleted: snapshotTimer.restart()

  component VolumeRow: Card {
    id: vrow
    property string icon: ""
    property string label: ""
    property real value: 0
    property real maximum: 1
    property bool muted: false
    signal moved(real v)
    signal muteToggled()

    cc: page.cc
    width: parent ? parent.width : 0
    height: Math.max(Style.space(52), Style.font.body + Style.spacing.xl * 2)

    IconButton {
      id: muteBtn
      cc: page.cc
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      iconText: vrow.icon
      tooltipText: vrow.muted ? "Unmute" : "Mute"
      selected: vrow.muted
      onClicked: vrow.muteToggled()
    }
    Text {
      id: vlabel
      anchors.left: muteBtn.right
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, vrow.width * 0.32)
      textFormat: Text.PlainText
      text: vrow.label
      color: page.cc.foreground
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    PanelSlider {
      id: vslider
      anchors.left: vlabel.right
      anchors.leftMargin: Style.spacing.lg
      anchors.right: vpct.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      minimum: 0
      maximum: vrow.maximum
      step: 0.05
      value: vrow.value
      trackColor: Style.selectedFillFor(page.cc.foreground, Color.accent)
      fillColor: vrow.muted ? Qt.rgba(page.cc.foreground.r, page.cc.foreground.g, page.cc.foreground.b, 0.4) : page.cc.selectedText
      knobColor: page.cc.foreground
      onMoved: function(v) { vrow.moved(v) }
      onRightClicked: vrow.muteToggled()
    }
    Text {
      id: vpct
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(40)
      horizontalAlignment: Text.AlignRight
      text: page.pct(vslider.dragging ? vslider.liveValue : vrow.value)
      color: page.cc.foreground
      opacity: 0.7
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    SectionTitle { cc: page.cc; text: "OUTPUT" }
    VolumeRow {
      icon: page.outputIcon()
      label: page.volumeSink ? AudioModel.nodeLabel(page.sink) : "No output"
      value: page.outputVolume
      muted: page.outputMuted
      onMoved: function(v) { if (page.volumeSink && page.volumeSink.audio) page.volumeSink.audio.volume = Math.max(0, Math.min(1, v)) }
      onMuteToggled: if (page.volumeSink && page.volumeSink.audio) page.volumeSink.audio.muted = !page.volumeSink.audio.muted
    }
    Repeater {
      model: page.displaySinks
      delegate: ListRow {
        required property var modelData
        cc: page.cc
        visible: page.displaySinks.length > 1
        icon: AudioModel.sinkGlyph(modelData)
        title: AudioModel.nodeLabel(modelData)
        active: !!page.sink && !!modelData && page.sink.id === modelData.id
        trailing: active ? "In use" : ""
        onClicked: page.setDefaultSink(modelData)
      }
    }

    SectionTitle { cc: page.cc; text: "INPUT" }
    VolumeRow {
      icon: page.inputMuted ? "󰍭" : "󰍬"
      label: page.source ? AudioModel.nodeLabel(page.source) : "No input"
      value: page.inputVolume
      muted: page.inputMuted
      onMoved: function(v) { if (page.source && page.source.audio) page.source.audio.volume = Math.max(0, Math.min(1, v)) }
      onMuteToggled: if (page.source && page.source.audio) page.source.audio.muted = !page.source.audio.muted
    }
    Repeater {
      model: page.displaySources
      delegate: ListRow {
        required property var modelData
        cc: page.cc
        visible: page.displaySources.length > 1
        icon: AudioModel.sourceGlyph(modelData)
        title: AudioModel.nodeLabel(modelData)
        active: !!page.source && !!modelData && page.source.id === modelData.id
        trailing: active ? "In use" : ""
        onClicked: page.setDefaultSource(modelData)
      }
    }

    SectionTitle { cc: page.cc; text: "APPLICATIONS"; visible: page.displayStreams.length > 0 }
    Repeater {
      model: page.displayStreams
      delegate: VolumeRow {
        required property var modelData
        icon: modelData && modelData.audio && modelData.audio.muted ? "󰝟" : "󰕾"
        label: AudioModel.streamLabel(modelData, page.mprisPlayers, page.displayStreams)
        value: modelData && modelData.audio ? modelData.audio.volume : 0
        maximum: 1.5
        muted: !!(modelData && modelData.audio && modelData.audio.muted)
        onMoved: function(v) { if (modelData && modelData.audio) modelData.audio.volume = Math.max(0, Math.min(1.5, v)) }
        onMuteToggled: if (modelData && modelData.audio) modelData.audio.muted = !modelData.audio.muted
      }
    }
    Text {
      width: parent.width
      visible: page.displayStreams.length === 0
      textFormat: Text.PlainText
      text: "No apps are playing sound right now."
      color: page.cc.foreground
      opacity: 0.5
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.bodySmall
      leftPadding: Style.spacing.sm
    }
  }
}
QUATTRO_EMBED_5
  chmod 644 "$d/pages/AudioPage.qml"
  cat > "$d/pages/BluetoothPage.qml" <<'QUATTRO_EMBED_6'
import Quickshell
import Quickshell.Bluetooth
import QtQuick
import qs.Commons
import qs.Ui
import "../../panels/bluetooth/Model.js" as BtModel

// Bluetooth: power, connected / paired / nearby devices, connect, pair,
// disconnect, forget. Same helpers as Omarchy's Bluetooth panel
// (omarchy-bluetooth-power / omarchy-bluetooth-device). Discovery runs only
// while this page is open and is started/stopped by the control center
// window, which also stops it if this page unloads mid-scan.
Item {
  id: page
  property var cc

  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property bool powered: !!adapter && !!adapter.enabled
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  property var sections: []
  property var pending: ({})

  function deviceFor(address) {
    var list = page.devices || []
    for (var i = 0; i < list.length; i++) if ((list[i].address || "") === address) return list[i]
    return null
  }
  function rebuild() {
    var groups = BtModel.deviceLists(page.devices)
    var out = []
    var add = function(id, title, list) {
      var rows = []
      for (var i = 0; i < list.length; i++) {
        var r = BtModel.deviceRow(list[i])
        if (!r) continue
        r.label = BtModel.deviceLabel(list[i])
        r.section = id
        rows.push(r)
      }
      if (rows.length > 0) out.push({ id: id, title: title, rows: rows })
    }
    add("connected", "CONNECTED", groups.connected)
    add("known", "PAIRED", groups.known)
    add("discovered", "NEARBY", groups.discovered)
    if (JSON.stringify(out) !== JSON.stringify(page.sections)) page.sections = out
    page.syncPending()
  }
  function setPending(address, action) {
    var next = BtModel.withPendingAction(page.pending, address, action)
    page.pending = next
    if (action) pendingTimeout.restart()
  }
  function syncPending() {
    var next = BtModel.cloneMap(page.pending)
    var changed = false
    for (var address in next) {
      var action = next[address]
      var d = page.deviceFor(address)
      var finishedConnecting = action === "connecting" && d && d.connected
      if (finishedConnecting) page.cc.scheduleBtAudioSwitch(d)
      if (finishedConnecting
          || (action === "disconnecting" && d && !d.connected)
          || (action === "forgetting" && (!d || (!d.paired && !d.bonded && !d.trusted)))) {
        delete next[address]
        changed = true
      }
    }
    if (changed) page.pending = next
  }
  function connect(address) {
    var d = page.deviceFor(address)
    if (!d || d.connected) return
    page.setPending(address, "connecting")
    page.cc.run(["omarchy-bluetooth-device", (d.paired || d.bonded || d.trusted) ? "connect" : "pair", address])
  }
  function disconnect(address) {
    var d = page.deviceFor(address)
    if (!d || !d.connected) return
    page.setPending(address, "disconnecting")
    try { if (d.disconnect) d.disconnect() } catch (e) { }
    page.cc.run(["omarchy-bluetooth-device", "disconnect", address])
  }
  function forget(address) {
    page.setPending(address, "forgetting")
    page.cc.run(["omarchy-bluetooth-device", "forget", address])
  }
  function togglePower() {
    page.cc.run(["omarchy-bluetooth-power", page.powered ? "off" : "on"])
  }
  function pendingText(action) {
    return action === "connecting" ? "Connecting…" : (action === "disconnecting" ? "Disconnecting…" : (action === "forgetting" ? "Forgetting…" : ""))
  }

  onDevicesChanged: rebuildSoon.restart()
  Component.onCompleted: { page.cc.btDiscoveryWanted = true; rebuildSoon.restart() }
  Component.onDestruction: page.cc.btDiscoveryWanted = false

  Timer { id: rebuildSoon; interval: 100; onTriggered: page.rebuild() }
  // Device properties (connected, paired, battery) change without the list
  // itself changing; refresh the snapshot regularly while visible.
  Timer { interval: 1500; running: true; repeat: true; onTriggered: page.rebuild() }
  Timer { id: pendingTimeout; interval: 25000; onTriggered: page.pending = ({}) }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    Card {
      cc: page.cc
      width: parent.width
      height: Math.max(Style.space(52), Style.font.body + Style.spacing.xl * 2)
      visible: !!page.adapter

      Text {
        id: btGlyph
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        text: page.powered ? "" : "󰂲"
        color: page.powered ? page.cc.selectedText : page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
      Text {
        anchors.left: btGlyph.right
        anchors.leftMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Bluetooth" + (page.powered && page.adapter.discovering ? "  ·  searching…" : "")
        color: page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.Medium
      }
      ToggleSwitch {
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        checked: page.powered
        foreground: page.cc.foreground
        accent: page.cc.selectedText
        onToggled: page.togglePower()
      }
    }

    Text {
      width: parent.width
      visible: !page.adapter
      textFormat: Text.PlainText
      text: "No Bluetooth adapter found."
      color: page.cc.foreground
      opacity: 0.6
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
    }

    Repeater {
      model: page.powered ? page.sections : []
      delegate: Column {
        required property var modelData
        width: parent ? parent.width : 0
        spacing: Style.spacing.xs

        SectionTitle { cc: page.cc; text: modelData.title }

        Repeater {
          model: modelData.rows
          delegate: ListRow {
            required property var modelData
            readonly property string action: page.pending[modelData.address] || ""
            cc: page.cc
            icon: modelData.connected ? "󰂱" : ""
            title: modelData.label || modelData.address
            subtitle: action ? page.pendingText(action)
                    : (modelData.connected ? "Connected" : (modelData.section === "known" ? "Paired · click to connect" : "Click to pair"))
            trailing: modelData.batteryAvailable ? " " + Math.round(modelData.battery * 100) + "%" : ""
            active: modelData.connected
            clickable: !modelData.connected && !action
            onClicked: page.connect(modelData.address)

            IconButton {
              cc: page.cc
              visible: modelData.connected
              iconText: ""
              tooltipText: "Disconnect"
              enabled: !action
              onClicked: page.disconnect(modelData.address)
            }
            IconButton {
              cc: page.cc
              visible: modelData.section !== "discovered"
              iconText: ""
              tooltipText: "Forget"
              enabled: !action
              onClicked: page.forget(modelData.address)
            }
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: !!page.adapter && page.powered && page.sections.length === 0
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.spacing.huge
      textFormat: Text.PlainText
      text: "Searching for devices… put your device in pairing mode."
      color: page.cc.foreground
      opacity: 0.55
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
    }
    Text {
      width: parent.width
      visible: !!page.adapter && !page.powered
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.spacing.huge
      textFormat: Text.PlainText
      text: "Bluetooth is off."
      color: page.cc.foreground
      opacity: 0.5
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
QUATTRO_EMBED_6
  chmod 644 "$d/pages/BluetoothPage.qml"
  cat > "$d/pages/CalendarPage.qml" <<'QUATTRO_EMBED_7'
import Quickshell
import QtQuick
import qs.Commons
import qs.Ui
import "../../panels/clock/Model.js" as ClockModel

// Calendar: month grid with ISO week numbers (Omarchy's clock-panel helpers),
// locale-aware first weekday, and a few date facts.
Item {
  id: page
  property var cc

  property date today: new Date()
  readonly property string todayKey: ClockModel.keyForDate(today)
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  readonly property int weekStart: ClockModel.normalizedWeekStart(null, Qt.locale().firstDayOfWeek)
  readonly property var weekdays: ClockModel.weekdayOrder(weekStart)
  readonly property var weeks: ClockModel.monthGrid(viewYear, viewMonth, weekStart, todayKey)
  readonly property bool showingToday: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  function step(delta) {
    var next = ClockModel.stepMonth(page.viewYear, page.viewMonth, delta)
    page.viewYear = next.year
    page.viewMonth = next.month
  }
  function goToday() {
    page.today = new Date()
    page.viewYear = page.today.getFullYear()
    page.viewMonth = page.today.getMonth()
  }

  Timer { interval: 60000; running: true; repeat: true; onTriggered: page.today = new Date() }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    Item {
      width: parent.width
      height: Math.max(Style.space(36), Style.font.title + Style.spacing.lg)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Qt.locale().standaloneMonthName(page.viewMonth, Locale.LongFormat) + " " + page.viewYear
        color: page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.title
        font.weight: Font.Bold
      }
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm
        IconButton { cc: page.cc; iconText: ""; tooltipText: "Previous month"; onClicked: page.step(-1) }
        IconButton { cc: page.cc; text: "Today"; fontSize: Style.font.caption; enabled: !page.showingToday; onClicked: page.goToday() }
        IconButton { cc: page.cc; iconText: ""; tooltipText: "Next month"; onClicked: page.step(1) }
      }
    }

    Card {
      id: grid
      cc: page.cc
      width: parent.width
      readonly property real weekColWidth: Style.space(36)
      readonly property real cellWidth: (width - Style.spacing.lg * 2 - weekColWidth) / 7
      readonly property real cellHeight: Math.max(Style.space(36), Style.font.body + Style.spacing.lg * 2)
      height: cellHeight * 7 + Style.spacing.lg * 2

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.lg

        Row {
          Text {
            width: grid.weekColWidth
            height: grid.cellHeight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "W"
            color: page.cc.foreground
            opacity: 0.4
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: page.weekdays
            delegate: Text {
              required property var modelData
              width: grid.cellWidth
              height: grid.cellHeight
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: Qt.locale().dayName(modelData, Locale.ShortFormat)
              color: page.cc.foreground
              opacity: modelData === 0 || modelData === 6 ? 0.45 : 0.65
              font.family: page.cc.fontFamily
              font.pixelSize: Style.font.caption
              font.weight: Font.Bold
            }
          }
        }

        Repeater {
          model: page.weeks
          delegate: Row {
            required property var modelData
            Text {
              width: grid.weekColWidth
              height: grid.cellHeight
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: String(modelData.week)
              color: page.cc.foreground
              opacity: 0.35
              font.family: page.cc.fontFamily
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: modelData.days
              delegate: Item {
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight
                Rectangle {
                  anchors.centerIn: parent
                  width: Math.min(parent.width, parent.height) - Style.spacing.xs
                  height: width
                  radius: page.cc.cornerRadius > 0 ? width / 2 : 0
                  color: modelData.today ? page.cc.selectedBackground : "transparent"
                  border.width: modelData.today ? 1 : 0
                  border.color: page.cc.selectedText
                }
                Text {
                  anchors.centerIn: parent
                  text: String(modelData.day)
                  color: modelData.today ? page.cc.selectedText : page.cc.foreground
                  opacity: modelData.inMonth ? (modelData.weekend ? 0.6 : 1) : 0.25
                  font.family: page.cc.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: modelData.today ? Font.Bold : Font.Normal
                }
              }
            }
          }
        }
      }
    }

    Card {
      cc: page.cc
      width: parent.width
      height: Math.max(Style.space(40), Style.font.bodySmall + Style.spacing.lg * 2)
      Text {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.lg
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: Qt.formatDate(page.today, "dddd, d MMMM yyyy")
              + "   ·   week " + ClockModel.isoWeek(page.today.getFullYear(), page.today.getMonth(), page.today.getDate())
              + "   ·   day " + ClockModel.dayOfYear(page.today.getFullYear(), page.today.getMonth(), page.today.getDate())
              + "   ·   " + ClockModel.yearProgressPercent(page.today.getFullYear(), page.today.getMonth(), page.today.getDate()) + "% of the year"
        color: page.cc.foreground
        opacity: 0.75
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }
}
QUATTRO_EMBED_7
  chmod 644 "$d/pages/CalendarPage.qml"
  cat > "$d/pages/Card.qml" <<'QUATTRO_EMBED_8'
import QtQuick

// Bordered surface used by every control center page.
Rectangle {
  property var cc
  radius: cc ? cc.cornerRadius : 0
  color: "transparent"
  border.width: 1
  border.color: cc ? cc.subtle : "#33ffffff"
}
QUATTRO_EMBED_8
  chmod 644 "$d/pages/Card.qml"
  cat > "$d/pages/DisplayPage.qml" <<'QUATTRO_EMBED_9'
import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Display: brightness of the focused monitor (internal or DDC external, via
// omarchy-brightness-display like Omarchy's display panel), night light, and
// the connected monitors.
Item {
  id: page
  property var cc

  property bool brightnessAvailable: false
  property int brightness: 0
  property string focusedMonitor: ""
  property var monitors: []
  property bool nightlight: false
  property bool hasHyprmon: false
  property int pendingBrightness: -1
  property bool setting: false

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!monitorsProc.running) monitorsProc.running = true
    if (!nightProc.running) nightProc.running = true
  }

  function queueBrightness(v) {
    page.pendingBrightness = Math.max(1, Math.min(100, Math.round(v)))
    debounce.restart()
  }
  function applyBrightness() {
    if (page.pendingBrightness < 0 || setProc.running) return
    var v = page.pendingBrightness
    page.pendingBrightness = -1
    var argv = ["omarchy-brightness-display", "--no-osd"]
    if (page.focusedMonitor) argv.push("--monitor", page.focusedMonitor)
    argv.push(v + "%")
    setProc.command = argv
    setProc.running = true
  }

  Component.onCompleted: refresh()
  Timer { interval: 5000; running: true; repeat: true; onTriggered: page.refresh() }
  Timer { id: debounce; interval: 180; onTriggered: page.applyBrightness() }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var b = String(lines[0] || "").trim()
        page.brightnessAvailable = b !== "unavailable" && b !== "" && !isNaN(parseInt(b, 10))
        if (page.brightnessAvailable && !slider.dragging && page.pendingBrightness < 0)
          page.brightness = Math.max(0, Math.min(100, parseInt(b, 10)))
        page.focusedMonitor = String(lines[5] || "").trim()
      }
    }
  }
  Process {
    id: setProc
    onExited: if (page.pendingBrightness >= 0) page.applyBrightness()
  }
  Process {
    id: monitorsProc
    command: ["bash", "-c", "hyprctl monitors -j 2>/dev/null; echo; command -v hyprmon >/dev/null && echo HYPRMON"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        page.hasHyprmon = raw.indexOf("HYPRMON") >= 0
        try {
          var list = JSON.parse(raw.replace("HYPRMON", "").trim() || "[]")
          page.monitors = list.map(function(m) {
            return {
              name: String(m.name || ""),
              description: String(m.description || ""),
              mode: (m.width || "?") + "×" + (m.height || "?") + " @ " + Math.round(Number(m.refreshRate) || 0) + " Hz",
              scale: Number(m.scale) || 1,
              focused: !!m.focused
            }
          })
        } catch (e) { page.monitors = [] }
      }
    }
  }
  Process {
    id: nightProc
    command: ["omarchy-toggle-nightlight", "--status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { page.nightlight = !!JSON.parse(text || "{}").enabled } catch (e) { }
      }
    }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    SectionTitle { cc: page.cc; text: "BRIGHTNESS" + (page.focusedMonitor ? "  ·  " + page.focusedMonitor : "") }
    Card {
      cc: page.cc
      width: parent.width
      height: Math.max(Style.space(56), Style.font.body + Style.spacing.xl * 2)

      Text {
        id: sunIcon
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        text: ""
        color: page.cc.selectedText
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
      PanelSlider {
        id: slider
        visible: page.brightnessAvailable
        anchors.left: sunIcon.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: bpct.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        minimum: 1
        maximum: 100
        step: 5
        integer: true
        value: page.brightness
        trackColor: Style.selectedFillFor(page.cc.foreground, Color.accent)
        fillColor: page.cc.selectedText
        knobColor: page.cc.foreground
        onMoved: function(v) { page.brightness = Math.round(v); page.queueBrightness(v) }
      }
      Text {
        id: bpct
        visible: page.brightnessAvailable
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(40)
        horizontalAlignment: Text.AlignRight
        text: Math.round(slider.dragging ? slider.liveValue : page.brightness) + "%"
        color: page.cc.foreground
        opacity: 0.7
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        visible: !page.brightnessAvailable
        anchors.left: sunIcon.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "This display doesn't expose brightness control (common in VMs; external monitors need DDC/CI)."
        color: page.cc.foreground
        opacity: 0.6
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }
    }

    Grid {
      id: tiles
      width: parent.width
      columns: 3
      spacing: page.cc.gap
      readonly property real tileWidth: (width - spacing * (columns - 1)) / columns

      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Night Light"
        detail: page.nightlight ? "On" : "Off"
        active: page.nightlight
        onActivated: { page.cc.run(["omarchy-toggle-nightlight"]); nightRefresh.restart() }
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Arrange displays"
        detail: page.hasHyprmon ? "hyprmon" : "Not installed"
        available: page.hasHyprmon
        onActivated: page.cc.runAndClose("omarchy-launch-or-focus-tui hyprmon")
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Wallpaper"
        detail: "Pick a background"
        onActivated: page.cc.runAndClose("omarchy-menu summon background")
      }
    }
    Timer { id: nightRefresh; interval: 700; onTriggered: { if (!nightProc.running) nightProc.running = true } }

    SectionTitle { cc: page.cc; text: "MONITORS" }
    Repeater {
      model: page.monitors
      delegate: ListRow {
        required property var modelData
        cc: page.cc
        clickable: false
        icon: ""
        title: modelData.name + (modelData.description ? "  ·  " + modelData.description : "")
        subtitle: modelData.mode + "   ·   scale " + modelData.scale
        active: modelData.focused
        trailing: modelData.focused ? "Focused" : ""
      }
    }
  }
}
QUATTRO_EMBED_9
  chmod 644 "$d/pages/DisplayPage.qml"
  cat > "$d/pages/HomePage.qml" <<'QUATTRO_EMBED_10'
import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Home: who/where, now playing, clock, quick toggles.
Item {
  id: page
  property var cc

  property var status: ({ hasWifi: false, wifiOn: false, ssid: "", ethernet: false,
                          hasBluetooth: false, bluetoothOn: false, profiles: [],
                          stayAwake: false, nightlight: false, dnd: false, host: "", uptime: 0 })
  property date now: new Date()
  readonly property var player: cc && cc.mediaService ? cc.mediaService.activePlayer : null
  readonly property string facePath: Quickshell.env("HOME") + "/.face"

  function refresh() { if (!statusProc.running) statusProc.running = true }
  function act(argv) { cc.run(argv); refreshSoon.restart() }

  function uptimeText(seconds) {
    var s = Number(seconds) || 0
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
    if (d > 0) return d + (d === 1 ? " day, " : " days, ") + h + " h"
    if (h > 0) return h + " h " + m + " min"
    return m + (m === 1 ? " minute" : " minutes")
  }
  function activeProfile() {
    var list = page.status.profiles || []
    for (var i = 0; i < list.length; i++) if (list[i].active) return list[i].name
    return ""
  }
  function cycleProfile() {
    var list = page.status.profiles || []
    if (list.length === 0) return
    var idx = 0
    for (var i = 0; i < list.length; i++) if (list[i].active) idx = i
    page.act(["omarchy-powerprofiles-set", "autodetect", list[(idx + 1) % list.length].name])
  }
  function profileLabel(name) {
    if (name === "power-saver") return "Power saver"
    if (name === "performance") return "Performance"
    if (name === "balanced") return "Balanced"
    return name ? name : "Power profile"
  }
  function profileIcon(name) {
    if (name === "power-saver") return ""
    if (name === "performance") return ""
    return ""
  }

  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: ["bash", page.cc.pluginDir + "/status.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "{}")
          if (parsed && typeof parsed === "object") page.status = parsed
        } catch (e) { }
      }
    }
  }
  Timer { id: refreshSoon; interval: 700; onTriggered: page.refresh() }
  Timer { interval: 5000; running: true; repeat: true; onTriggered: page.refresh() }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: page.now = new Date() }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    // Profile card
    Card {
      cc: page.cc
      width: parent.width
      height: Style.space(96)

      Rectangle {
        id: avatar
        width: Style.space(60)
        height: width
        radius: width / 2
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        color: page.cc.selectedBackground
        clip: true

        Image {
          id: faceImage
          anchors.fill: parent
          source: Util.fileUrl(page.facePath)
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          visible: status === Image.Ready
          asynchronous: true
        }
        Text {
          anchors.centerIn: parent
          visible: faceImage.status !== Image.Ready
          text: page.cc.userName.charAt(0).toUpperCase()
          color: page.cc.selectedText
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.display
          font.weight: Font.Bold
        }
      }

      Column {
        anchors.left: avatar.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.cc.userName
          color: page.cc.selectedText
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.Bold
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.cc.userName + "@" + (page.status.host || "localhost")
          color: page.cc.foreground
          opacity: 0.7
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Uptime – " + page.uptimeText(page.status.uptime)
          color: page.cc.foreground
          opacity: 0.7
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    // Media + clock
    Row {
      width: parent.width
      height: Math.max(Style.space(96), Style.font.displayLarge + Style.font.body * 2 + Style.spacing.lg * 3)
      spacing: page.cc.gap

      Card {
        cc: page.cc
        width: (parent.width - page.cc.gap) * 0.58
        height: parent.height

        Column {
          anchors.fill: parent
          anchors.margins: Style.spacing.lg
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: page.player && page.player.trackTitle ? page.player.trackTitle : "Nothing playing"
            color: page.cc.foreground
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.Medium
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: page.player ? (page.player.trackArtist || page.player.identity || "") : "Idle"
            color: page.cc.foreground
            opacity: 0.6
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Row {
            spacing: Style.spacing.md
            topPadding: Style.spacing.sm
            opacity: page.player ? 1 : 0.4
            Repeater {
              model: [
                { icon: "", action: "previous" },
                { icon: page.player && page.player.isPlaying ? "" : "", action: "playPause" },
                { icon: "", action: "next" }
              ]
              delegate: IconButton {
                required property var modelData
                cc: page.cc
                iconText: modelData.icon
                onClicked: if (page.cc.mediaService) page.cc.mediaService.runAction(modelData.action, false)
              }
            }
          }
        }
      }

      Card {
        cc: page.cc
        width: (parent.width - page.cc.gap) * 0.42
        height: parent.height

        Column {
          anchors.centerIn: parent
          width: parent.width - Style.spacing.lg * 2
          spacing: Style.space(2)
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: Qt.formatDateTime(page.now, "HH:mm")
            color: page.cc.selectedText
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.weight: Font.Bold
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: Qt.formatDate(page.now, "dddd, d MMM")
            color: page.cc.foreground
            opacity: 0.7
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }
    }

    // Quick toggles
    Grid {
      id: tiles
      width: parent.width
      columns: 3
      spacing: page.cc.gap
      readonly property real tileWidth: (width - spacing * (columns - 1)) / columns

      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: page.status.hasWifi ? (page.status.wifiOn ? "" : "󰤮") : "󰈀"
        label: page.status.hasWifi ? "Wi-Fi" : "Ethernet"
        detail: page.status.hasWifi ? (page.status.wifiOn ? (page.status.ssid || "On") : "Off")
                                    : (page.status.ethernet ? "Connected" : "Disconnected")
        active: page.status.hasWifi ? page.status.wifiOn : page.status.ethernet
        available: page.status.hasWifi
        onActivated: page.act(["nmcli", "radio", "wifi", page.status.wifiOn ? "off" : "on"])
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: page.status.bluetoothOn ? "" : "󰂲"
        label: "Bluetooth"
        detail: page.status.hasBluetooth ? (page.status.bluetoothOn ? "On" : "Off") : "No adapter"
        active: page.status.bluetoothOn
        available: page.status.hasBluetooth
        onActivated: page.act(["omarchy-bluetooth-power", "toggle"])
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Caffeine"
        detail: page.status.stayAwake ? "Staying awake" : "Off"
        active: !!page.status.stayAwake
        onActivated: page.act(["omarchy-toggle-idle"])
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Night Light"
        detail: page.status.nightlight ? "On" : "Off"
        active: !!page.status.nightlight
        onActivated: page.act(["omarchy-toggle-nightlight"])
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: page.status.dnd ? "" : ""
        label: "Do Not Disturb"
        detail: page.status.dnd ? "On" : "Off"
        active: !!page.status.dnd
        onActivated: page.act(["omarchy-toggle-notification-silencing"])
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: page.profileIcon(page.activeProfile())
        label: page.profileLabel(page.activeProfile())
        detail: (page.status.profiles || []).length > 1 ? "Click to switch" : "Power profile"
        active: page.activeProfile() === "performance"
        available: (page.status.profiles || []).length > 1
        onActivated: page.cycleProfile()
      }
    }
  }
}
QUATTRO_EMBED_10
  chmod 644 "$d/pages/HomePage.qml"
  cat > "$d/pages/IconButton.qml" <<'QUATTRO_EMBED_11'
import QtQuick
import qs.Commons
import qs.Ui

// Small bordered icon button with tooltip (wraps Quattro's Ui Button).
Button {
  property var cc
  bordered: true
  foreground: cc ? cc.foreground : Color.foreground
  accent: cc ? cc.selectedText : Color.accent
  fontFamily: cc ? cc.fontFamily : Style.font.family
  iconSize: Style.font.icon
  horizontalPadding: Style.spacing.md
  verticalPadding: Style.spacing.sm
}
QUATTRO_EMBED_11
  chmod 644 "$d/pages/IconButton.qml"
  cat > "$d/pages/ListRow.qml" <<'QUATTRO_EMBED_12'
import QtQuick
import qs.Commons

// One clickable line in a list: icon, title, subtitle, trailing text, and
// optional extra buttons on the right (declared as children).
Rectangle {
  id: row
  property var cc
  property string icon: ""
  property string title: ""
  property string subtitle: ""
  property string trailing: ""
  property bool active: false
  property bool clickable: true
  default property alias actions: actionRow.data
  signal clicked()

  width: parent ? parent.width : 0
  height: Math.max(Style.space(44), Style.font.body + Style.font.caption + Style.spacing.lg * 2)
  radius: cc ? cc.cornerRadius : 0
  color: active ? cc.selectedBackground
       : (rowMouse.containsMouse && clickable ? Qt.rgba(cc.foreground.r, cc.foreground.g, cc.foreground.b, 0.05) : "transparent")

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: row.clickable
    cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: row.clicked()
  }

  Text {
    id: iconText
    visible: row.icon.length > 0
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.lg
    anchors.verticalCenter: parent.verticalCenter
    width: visible ? Style.font.iconLarge + Style.spacing.sm : 0
    text: row.icon
    color: row.active ? row.cc.selectedText : row.cc.foreground
    font.family: row.cc.fontFamily
    font.pixelSize: Style.font.iconLarge
  }

  Column {
    anchors.left: iconText.right
    anchors.leftMargin: iconText.visible ? Style.spacing.lg : Style.spacing.lg
    anchors.right: trailingText.left
    anchors.rightMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: row.title
      color: row.active ? row.cc.selectedText : row.cc.foreground
      font.family: row.cc.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      visible: row.subtitle.length > 0
      textFormat: Text.PlainText
      text: row.subtitle
      color: row.cc.foreground
      opacity: 0.6
      font.family: row.cc.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    id: trailingText
    anchors.right: actionRow.left
    anchors.rightMargin: actionRow.width > 0 ? Style.spacing.md : 0
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: row.trailing
    color: row.cc.foreground
    opacity: 0.7
    font.family: row.cc.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    id: actionRow
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.sm
  }
}
QUATTRO_EMBED_12
  chmod 644 "$d/pages/ListRow.qml"
  cat > "$d/pages/MediaPage.qml" <<'QUATTRO_EMBED_13'
import Quickshell
import QtQuick
import qs.Commons
import qs.Ui

// Media: art, track, seek bar, transport, and source (player) switching.
// Playback actions go through Omarchy's media service like the bar widget.
Item {
  id: page
  property var cc

  readonly property var service: cc ? cc.mediaService : null
  readonly property var player: service ? service.activePlayer : null
  readonly property var sources: service && service.sourcePlayers ? service.sourcePlayers : []
  readonly property bool hasLength: !!player && player.lengthSupported !== false && Number(player.length) > 0
  readonly property bool canSeek: hasLength && !!player.canSeek && player.positionSupported !== false
  property bool seeking: false

  function fmt(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" + sec : sec)
  }
  function act(action) {
    if (page.service) page.service.runAction(action, false, page.service.playerKey(page.player))
  }

  // MPRIS position is not pushed; nudge the binding while playing.
  Timer {
    interval: 1000
    repeat: true
    running: !!page.player && !!page.player.isPlaying && !page.seeking
    onTriggered: { try { page.player.positionChanged() } catch (e) { } }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    Card {
      cc: page.cc
      width: parent.width
      height: Style.space(200)

      BorderSurface {
        id: art
        width: Style.space(168)
        height: width
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        radius: page.cc.cornerRadius
        color: Style.normalFillFor(page.cc.foreground, Color.accent)
        borderSpec: Border.controlSpec("normal", page.cc.foreground, Color.accent)

        Image {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          source: page.player && page.player.trackArtUrl ? page.player.trackArtUrl : ""
          visible: source !== ""
        }
        Text {
          anchors.centerIn: parent
          visible: !page.player || !page.player.trackArtUrl
          text: "󰝚"
          color: page.cc.foreground
          opacity: 0.5
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.displayLarge * 2
        }
      }

      Column {
        anchors.left: art.right
        anchors.leftMargin: Style.spacing.xxl
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.player && page.player.trackTitle ? page.player.trackTitle : "Nothing playing"
          color: page.cc.selectedText
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.Bold
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.Wrap
        }
        Text {
          width: parent.width
          visible: text.length > 0
          textFormat: Text.PlainText
          text: page.player ? (page.player.trackArtist || "") : ""
          color: page.cc.foreground
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: text.length > 0
          textFormat: Text.PlainText
          text: page.player ? (page.player.trackAlbum || "") : ""
          color: page.cc.foreground
          opacity: 0.6
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Item {
          width: parent.width
          height: Style.spacing.lg
          visible: page.hasLength
        }

        PanelSlider {
          id: seek
          width: parent.width
          visible: page.hasLength
          minimum: 0
          maximum: page.hasLength ? Number(page.player.length) : 1
          step: 5
          value: page.player ? Number(page.player.position) || 0 : 0
          trackColor: Style.selectedFillFor(page.cc.foreground, Color.accent)
          fillColor: page.cc.selectedText
          knobColor: page.cc.foreground
          enabled: page.canSeek
          onDraggingChanged: page.seeking = dragging
          onReleased: function(v) { if (page.canSeek) page.player.position = v }
        }
        Item {
          width: parent.width
          height: Style.font.caption + Style.spacing.xs
          visible: page.hasLength
          Text {
            anchors.left: parent.left
            text: page.fmt(seek.dragging ? seek.liveValue : seek.value)
            color: page.cc.foreground
            opacity: 0.6
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            text: page.hasLength ? page.fmt(page.player.length) : ""
            color: page.cc.foreground
            opacity: 0.6
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          spacing: Style.spacing.md
          opacity: page.player ? 1 : 0.4
          IconButton { cc: page.cc; iconText: ""; tooltipText: "Previous"; onClicked: page.act("previous") }
          IconButton {
            cc: page.cc
            iconText: page.player && page.player.isPlaying ? "" : ""
            tooltipText: page.player && page.player.isPlaying ? "Pause" : "Play"
            onClicked: page.act("playPause")
          }
          IconButton { cc: page.cc; iconText: ""; tooltipText: "Next"; onClicked: page.act("next") }
        }
      }
    }

    SectionTitle {
      cc: page.cc
      visible: page.sources.length > 0
      text: "SOURCES"
    }

    Repeater {
      model: page.sources
      delegate: ListRow {
        required property var modelData
        cc: page.cc
        icon: modelData && modelData.isPlaying ? "" : ""
        title: page.service ? page.service.labelFor(modelData) : ""
        subtitle: modelData ? [modelData.trackTitle || "", modelData.trackArtist || ""].filter(function(v) { return v }).join(" – ") : ""
        active: !!page.player && !!modelData && page.service.playerKey(modelData) === page.service.playerKey(page.player)
        onClicked: if (page.service && modelData) page.service.selectPlayer(page.service.playerKey(modelData))
      }
    }

    Text {
      width: parent.width
      visible: page.sources.length === 0
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.spacing.huge
      textFormat: Text.PlainText
      text: "Start playing something in a browser or music app and it shows up here."
      color: page.cc.foreground
      opacity: 0.55
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
    }
  }
}
QUATTRO_EMBED_13
  chmod 644 "$d/pages/MediaPage.qml"
  cat > "$d/pages/NetworkPage.qml" <<'QUATTRO_EMBED_14'
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import QtQuick
import qs.Commons
import qs.Ui
import "../../panels/network/Model.js" as NetModel

// Network: Wi-Fi on/off, scan, connect (with inline password), disconnect,
// forget, and wired status. Same NetworkManager backend and safety rules as
// Omarchy's network panel: rows are primitive snapshots (never live
// WifiNetwork objects), the live object is looked up by SSID when acting,
// and passwords go in-process via connectWithPsk (never on a command line).
// Enterprise (802.1X) networks are handed to Omarchy's network panel.
Item {
  id: page
  property var cc

  readonly property bool nmAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: findDevice(DeviceType.Wifi)
  readonly property var wiredDevice: findDevice(DeviceType.Wired)
  readonly property var networkObjects: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
  readonly property var failReasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })

  property var rows: []
  property bool scanning: false
  property var scannerDevice: null
  property string actionKind: ""
  property string actionSsid: ""
  property string failureSsid: ""
  property string failureReason: ""
  property string passwordSsid: ""
  // Kept at page level: rows are rebuilt during scans, which recreates the
  // inline field, so its text must not live in the field itself.
  property string passwordText: ""
  property var wired: ({})

  function findDevice(type) {
    var list = page.devices || []
    var fallback = null
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      if (!d || d.type !== type) continue
      if (d.connected) return d
      if (!fallback) fallback = d
    }
    return fallback
  }
  function networkForSsid(ssid) {
    var list = page.networkObjects || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === ssid) return list[i]
    return null
  }
  function needsCredentials(security) {
    return NetModel.requiresCredentials(security, WifiSecurityType.Open, WifiSecurityType.Owe)
  }
  function isEnterprise(security) {
    return security === WifiSecurityType.Wpa2Eap || security === WifiSecurityType.WpaEap
  }

  function setScannerEnabled(enabled) {
    var next = page.wifiDevice
    if (page.scannerDevice && page.scannerDevice !== next) {
      try { page.scannerDevice.scannerEnabled = false } catch (e) { }
    }
    page.scannerDevice = next
    if (page.scannerDevice) {
      try { page.scannerDevice.scannerEnabled = enabled } catch (e) { }
    }
  }
  function rescan() {
    if (!page.wifiDevice) return
    page.scanning = true
    page.setScannerEnabled(false)
    scanRestart.restart()
  }
  function sync() {
    var out = []
    var list = page.networkObjects || []
    for (var i = 0; i < list.length; i++) {
      var n = list[i]
      if (!n) continue
      page.checkCompletion(n)
      var r = NetModel.wifiRow(n)
      if (r && r.ssid) out.push(r)
    }
    var next = NetModel.sortWifiRows(out)
    // Only replace the list when it changed, so rows (and an open password
    // field) aren't recreated on every scan tick.
    if (JSON.stringify(next) !== JSON.stringify(page.rows)) page.rows = next
    page.scanning = false
  }

  function runAction(kind, network, fn) {
    if (page.actionKind !== "" || !network) return
    page.actionSsid = network.name || ""
    page.actionKind = kind
    page.failureSsid = ""
    page.failureReason = ""
    fn(network)
    actionTimeout.restart()
  }
  function clearAction() {
    actionTimeout.stop()
    if (page.actionKind === "connect") { page.passwordSsid = ""; page.passwordText = "" }
    page.actionSsid = ""
    page.actionKind = ""
    page.sync()
  }
  function failAction(network, reason) {
    if (!network || page.actionKind === "" || page.actionSsid !== (network.name || "")) return
    actionTimeout.stop()
    page.failureSsid = page.actionSsid
    page.failureReason = NetModel.networkFailureReason(reason, page.needsCredentials(network.security), page.failReasons)
    page.actionSsid = ""
    page.actionKind = ""
    page.sync()
  }
  function checkCompletion(network) {
    if (!network || page.actionKind === "" || page.actionSsid !== (network.name || "")) return
    if (page.actionKind === "connect" && network.connected) page.clearAction()
    else if (page.actionKind === "disconnect" && !network.connected && !network.stateChanging) page.clearAction()
    else if (page.actionKind === "forget" && !network.known && !network.stateChanging) page.clearAction()
  }

  function activate(row) {
    if (page.actionKind !== "") return
    if (row.connected) return
    if (page.isEnterprise(row.security)) {
      // 802.1X needs an identity + password form; Omarchy's network panel has it.
      if (page.cc.panelAvailable(page.cc.pageById("network"))) {
        page.cc.openBarPanel(page.cc.pageById("network"))
      } else {
        page.failureSsid = row.ssid
        page.failureReason = "Enterprise Wi-Fi: use the bar's network panel or nmtui"
      }
      return
    }
    if (!row.known && page.needsCredentials(row.security)) {
      page.passwordText = ""
      page.passwordSsid = row.ssid
      return
    }
    page.runAction("connect", page.networkForSsid(row.ssid), function(n) { n.connect() })
  }
  function submitPassword(ssid, passphrase) {
    if (!passphrase) return
    page.passwordText = ""
    page.runAction("connect", page.networkForSsid(ssid), function(n) { n.connectWithPsk(passphrase) })
  }
  function disconnectRow(ssid) {
    page.runAction("disconnect", page.networkForSsid(ssid), function(n) { n.disconnect() })
  }
  function forgetRow(ssid) {
    page.runAction("forget", page.networkForSsid(ssid), function(n) { n.forget() })
  }
  function toggleWifi() {
    Networking.wifiEnabled = !Networking.wifiEnabled
    Qt.callLater(page.rescan)
  }

  onNetworkObjectsChanged: syncSoon.restart()
  onWifiDeviceChanged: if (page.wifiDevice) page.rescan()
  Component.onCompleted: { page.rescan(); if (!wiredProc.running) wiredProc.running = true }
  Component.onDestruction: {
    if (page.scannerDevice) {
      try { page.scannerDevice.scannerEnabled = false } catch (e) { }
    }
  }

  Timer {
    id: scanRestart
    interval: 100
    onTriggered: { page.setScannerEnabled(true); scanDone.restart() }
  }
  Timer { id: scanDone; interval: 1500; onTriggered: page.sync() }
  Timer { id: syncSoon; interval: 120; onTriggered: page.sync() }
  Timer {
    id: actionTimeout
    interval: 30000
    onTriggered: {
      page.failureSsid = page.actionSsid
      page.failureReason = "Timed out"
      page.actionSsid = ""
      page.actionKind = ""
      page.sync()
    }
  }
  Timer { id: failureClear; interval: 6000; running: page.failureSsid !== ""; onTriggered: { page.failureSsid = ""; page.failureReason = "" } }
  Timer { interval: 4000; running: true; repeat: true; onTriggered: { if (!wiredProc.running) wiredProc.running = true } }

  Process {
    id: wiredProc
    command: ["omarchy-network-status", "--verbose"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = ({})
        String(text || "").split("\n").forEach(function(l) {
          var i = l.indexOf("\t")
          if (i > 0) out[l.slice(0, i)] = l.slice(i + 1)
        })
        page.wired = out
      }
    }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    // Wi-Fi switch + rescan
    Card {
      cc: page.cc
      width: parent.width
      height: Math.max(Style.space(52), Style.font.body + Style.spacing.xl * 2)
      visible: page.nmAvailable && !!page.wifiDevice

      Text {
        id: wifiGlyph
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        text: Networking.wifiEnabled ? "" : "󰤮"
        color: Networking.wifiEnabled ? page.cc.selectedText : page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
      Text {
        anchors.left: wifiGlyph.right
        anchors.leftMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Wi-Fi" + (page.scanning ? "  ·  scanning…" : "")
        color: page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.Medium
      }
      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.lg
        IconButton {
          cc: page.cc
          iconText: ""
          tooltipText: "Scan again"
          enabled: Networking.wifiEnabled && !page.scanning
          onClicked: page.rescan()
        }
        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: Networking.wifiEnabled
          foreground: page.cc.foreground
          accent: page.cc.selectedText
          onToggled: page.toggleWifi()
        }
      }
    }

    // Wired
    ListRow {
      cc: page.cc
      visible: !!page.wiredDevice
      clickable: false
      icon: page.wiredDevice && page.wiredDevice.connected ? "󰈀" : "󰈂"
      title: "Ethernet" + (page.wired.iface && page.wired.type === "ethernet" ? "  ·  " + page.wired.iface : "")
      subtitle: page.wiredDevice && page.wiredDevice.connected
        ? [page.wired.type === "ethernet" && page.wired.ip ? page.wired.ip + (page.wired.prefix ? "/" + page.wired.prefix : "") : "",
           page.wired.type === "ethernet" && page.wired.speed ? page.wired.speed + " Mb/s" : ""].filter(function(v) { return v }).join("   ·   ") || "Connected"
        : "Cable unplugged"
      active: !!page.wiredDevice && page.wiredDevice.connected
    }

    Text {
      width: parent.width
      visible: !page.nmAvailable
      textFormat: Text.PlainText
      text: "NetworkManager isn't running, so networks can't be managed here."
      color: page.cc.foreground
      opacity: 0.6
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
    }
    Text {
      width: parent.width
      visible: page.nmAvailable && !page.wifiDevice
      textFormat: Text.PlainText
      text: "No Wi-Fi adapter found."
      color: page.cc.foreground
      opacity: 0.6
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
    }

    SectionTitle {
      cc: page.cc
      visible: Networking.wifiEnabled && page.rows.length > 0
      text: "NETWORKS"
    }

    Repeater {
      model: Networking.wifiEnabled ? page.rows : []
      delegate: Column {
        id: netRow
        required property var modelData
        readonly property bool busy: page.actionSsid === modelData.ssid
        readonly property bool failed: page.failureSsid === modelData.ssid
        readonly property bool askingPassword: page.passwordSsid === modelData.ssid && !busy
        width: parent ? parent.width : 0
        spacing: Style.spacing.xs

        Connections {
          target: page.networkForSsid(netRow.modelData.ssid)
          function onConnectionFailed(reason) {
            var ours = page.actionKind === "connect" && page.actionSsid === netRow.modelData.ssid
            var network = page.networkForSsid(netRow.modelData.ssid)
            page.failAction(network, reason)
            if (ours && NetModel.shouldRepromptPassphrase(reason, page.needsCredentials(netRow.modelData.security), page.failReasons))
              page.passwordSsid = netRow.modelData.ssid
          }
          function onConnectedChanged() { page.checkCompletion(page.networkForSsid(netRow.modelData.ssid)) }
          function onKnownChanged() { page.checkCompletion(page.networkForSsid(netRow.modelData.ssid)) }
          function onStateChangingChanged() { page.checkCompletion(page.networkForSsid(netRow.modelData.ssid)) }
        }

        ListRow {
          cc: page.cc
          icon: NetModel.wifiIconFor(netRow.modelData.signal)
          title: netRow.modelData.ssid
          subtitle: netRow.busy ? (page.actionKind === "connect" ? "Connecting…" : (page.actionKind === "disconnect" ? "Disconnecting…" : "Forgetting…"))
                  : (netRow.failed ? page.failureReason
                  : [netRow.modelData.connected ? "Connected" : (netRow.modelData.known ? "Saved" : ""),
                     page.needsCredentials(netRow.modelData.security) ? (page.isEnterprise(netRow.modelData.security) ? "Enterprise" : "Secured") : "Open"]
                    .filter(function(v) { return v }).join("  ·  "))
          trailing: netRow.modelData.signal + "%"
          active: netRow.modelData.connected
          clickable: !netRow.modelData.connected && page.actionKind === ""
          onClicked: page.activate(netRow.modelData)

          IconButton {
            cc: page.cc
            visible: netRow.modelData.connected
            iconText: ""
            tooltipText: "Disconnect"
            enabled: page.actionKind === ""
            onClicked: page.disconnectRow(netRow.modelData.ssid)
          }
          IconButton {
            cc: page.cc
            visible: netRow.modelData.known && !netRow.modelData.connected
            iconText: ""
            tooltipText: "Forget"
            enabled: page.actionKind === ""
            onClicked: page.forgetRow(netRow.modelData.ssid)
          }
        }

        // Inline password entry
        Item {
          width: parent.width
          height: visible ? pw.implicitHeight + Style.spacing.sm : 0
          visible: netRow.askingPassword

          TextField {
            id: pw
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.lg
            anchors.right: pwOk.left
            anchors.rightMargin: Style.spacing.sm
            password: true
            placeholderText: "Password for " + netRow.modelData.ssid
            foreground: page.cc.foreground
            accent: page.cc.selectedText
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            text: page.passwordText
            onTextChanged: if (text !== page.passwordText) page.passwordText = text
            onAccepted: page.submitPassword(netRow.modelData.ssid, page.passwordText)
            Keys.onEscapePressed: { page.passwordSsid = ""; page.passwordText = "" }
            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
            Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
          }
          IconButton {
            id: pwOk
            cc: page.cc
            anchors.right: parent.right
            anchors.verticalCenter: pw.verticalCenter
            iconText: ""
            tooltipText: "Connect"
            onClicked: page.submitPassword(netRow.modelData.ssid, page.passwordText)
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: page.nmAvailable && !!page.wifiDevice && !Networking.wifiEnabled
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.spacing.huge
      textFormat: Text.PlainText
      text: "Wi-Fi is off."
      color: page.cc.foreground
      opacity: 0.5
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
QUATTRO_EMBED_14
  chmod 644 "$d/pages/NetworkPage.qml"
  cat > "$d/pages/NotificationsPage.qml" <<'QUATTRO_EMBED_15'
import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Notifications: Do Not Disturb, and the history Omarchy keeps on disk
// (~/.local/state/omarchy/notifications/history, newest first). Actions go
// through the notification service's own IPC.
Item {
  id: page
  property var cc

  readonly property string historyDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history"
  property var items: []
  property bool dnd: false

  function refresh() {
    if (!historyProc.running) historyProc.running = true
    if (!dndProc.running) dndProc.running = true
  }
  function ipc(method) {
    page.cc.run(["omarchy-shell", "notifications", method])
    refreshSoon.restart()
  }
  function ago(ts) {
    var t = Number(ts) || 0
    if (t > 1e12) t = t / 1000
    if (t <= 0) return ""
    var s = Math.max(0, Math.floor(Date.now() / 1000 - t))
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + " h ago"
    return Math.floor(s / 86400) + " d ago"
  }
  function parse(raw) {
    var out = []
    String(raw || "").split("\n").forEach(function(line) {
      if (!line.trim()) return
      try {
        var n = JSON.parse(line)
        out.push({
          app: String(n.app || ""),
          summary: String(n.summary || ""),
          body: String(n.body || "").replace(/<[^>]*>/g, ""),
          glyph: String(n.glyph || ""),
          urgency: Number(n.urgency) || 1,
          timestamp: Number(n.timestamp) || 0
        })
      } catch (e) { }
    })
    out.sort(function(a, b) { return b.timestamp - a.timestamp })
    if (JSON.stringify(out) !== JSON.stringify(page.items)) page.items = out
  }

  Component.onCompleted: refresh()
  Timer { interval: 4000; running: true; repeat: true; onTriggered: page.refresh() }
  Timer { id: refreshSoon; interval: 600; onTriggered: page.refresh() }

  Process {
    id: historyProc
    command: ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", page.historyDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: page.parse(text)
    }
  }
  Process {
    id: dndProc
    command: ["omarchy-shell", "notifications", "isDnd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: page.dnd = String(text || "").trim() === "on"
    }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    Grid {
      id: tiles
      width: parent.width
      columns: 3
      spacing: page.cc.gap
      readonly property real tileWidth: (width - spacing * 2) / 3

      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: page.dnd ? "" : ""
        label: "Do Not Disturb"
        detail: page.dnd ? "On" : "Off"
        active: page.dnd
        onActivated: { page.cc.run(["omarchy-toggle-notification-silencing"]); refreshSoon.restart() }
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Show again"
        detail: "Replay as popups"
        available: page.items.length > 0
        onActivated: page.ipc("showHistory")
      }
      Tile {
        cc: page.cc
        width: tiles.tileWidth
        icon: ""
        label: "Clear history"
        detail: page.items.length + " saved"
        available: page.items.length > 0
        onActivated: page.ipc("clear")
      }
    }

    SectionTitle { cc: page.cc; text: "HISTORY" }

    Repeater {
      model: page.items
      delegate: Card {
        required property var modelData
        cc: page.cc
        width: parent ? parent.width : 0
        height: noteCol.implicitHeight + Style.spacing.lg * 2
        border.color: modelData.urgency >= 2 ? Color.urgent : page.cc.subtle

        Column {
          id: noteCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.lg
          spacing: Style.space(3)

          Item {
            width: parent.width
            height: appText.height
            Text {
              id: appText
              anchors.left: parent.left
              width: parent.width - when.width - Style.spacing.md
              textFormat: Text.PlainText
              text: (modelData.glyph ? modelData.glyph + "  " : "") + (modelData.app || "Notification")
              color: page.cc.foreground
              opacity: 0.6
              font.family: page.cc.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Text {
              id: when
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: page.ago(modelData.timestamp)
              color: page.cc.foreground
              opacity: 0.5
              font.family: page.cc.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            width: parent.width
            visible: modelData.summary.length > 0
            textFormat: Text.PlainText
            text: modelData.summary
            color: page.cc.selectedText
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.Medium
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: modelData.body.length > 0
            textFormat: Text.PlainText
            text: modelData.body
            color: page.cc.foreground
            opacity: 0.8
            font.family: page.cc.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: page.items.length === 0
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.spacing.huge
      textFormat: Text.PlainText
      text: "No notifications yet."
      color: page.cc.foreground
      opacity: 0.5
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
QUATTRO_EMBED_15
  chmod 644 "$d/pages/NotificationsPage.qml"
  cat > "$d/pages/PageScroll.qml" <<'QUATTRO_EMBED_16'
import QtQuick
import QtQuick.Controls

// Vertical scroll area: children go into a Column (use width: parent.width).
// A plain Item wraps the ScrollView so `spacing` and the default property
// don't collide with ScrollView's own (FINAL) properties.
Item {
  id: wrap
  default property alias content: col.data
  property alias spacing: col.spacing

  ScrollView {
    id: sv
    anchors.fill: parent
    clip: true
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ScrollBar.vertical.policy: col.implicitHeight > sv.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

    Binding {
      target: sv.contentItem
      property: "interactive"
      value: col.implicitHeight > sv.height
    }

    Column {
      id: col
      width: sv.availableWidth
    }
  }
}
QUATTRO_EMBED_16
  chmod 644 "$d/pages/PageScroll.qml"
  cat > "$d/pages/PowerPage.qml" <<'QUATTRO_EMBED_17'
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import QtQuick
import qs.Commons
import qs.Ui

// Power: battery, power profiles, and session actions (lock, suspend, log
// out, reboot, shut down) using the same commands as Omarchy's System menu.
Item {
  id: page
  property var cc

  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: !!battery && !!battery.isPresent
  readonly property int batteryPercent: hasBattery ? Math.round(battery.percentage * 100) : -1
  readonly property bool onBattery: !!UPower.onBattery
  property var batteryInfo: ({})
  property var profiles: []
  property string armed: ""

  function refresh() {
    if (!profilesProc.running) profilesProc.running = true
    if (page.hasBattery && !batteryProc.running) batteryProc.running = true
  }
  function setProfile(name) {
    page.cc.run(["omarchy-powerprofiles-set", page.onBattery ? "battery" : "ac", name])
    refreshSoon.restart()
  }
  function profileLabel(name) {
    if (name === "power-saver") return "Power saver"
    if (name === "performance") return "Performance"
    if (name === "balanced") return "Balanced"
    return name
  }
  function profileIcon(name) {
    if (name === "power-saver") return ""
    if (name === "performance") return ""
    return ""
  }
  function batteryIcon(p) {
    if (p >= 90) return ""
    if (p >= 65) return ""
    if (p >= 40) return ""
    if (p >= 15) return ""
    return ""
  }
  // Destructive actions need a second click within 3 s.
  function session(id, command, needsConfirm) {
    if (needsConfirm && page.armed !== id) {
      page.armed = id
      disarm.restart()
      return
    }
    page.armed = ""
    page.cc.runAndClose(command)
  }

  Component.onCompleted: refresh()
  Timer { interval: 5000; running: true; repeat: true; onTriggered: page.refresh() }
  Timer { id: refreshSoon; interval: 800; onTriggered: page.refresh() }
  Timer { id: disarm; interval: 3000; onTriggered: page.armed = "" }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").split("\n").filter(function(l) { return l.length > 0 }).map(function(l) {
          var f = l.split("\t")
          return { name: f[0], active: f[1] === "1" }
        })
        if (JSON.stringify(next) !== JSON.stringify(page.profiles)) page.profiles = next
      }
    }
  }
  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = ({})
        String(text || "").split("\n").forEach(function(l) {
          var i = l.indexOf("\t")
          if (i > 0) out[l.slice(0, i)] = l.slice(i + 1)
        })
        page.batteryInfo = out
      }
    }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    Card {
      cc: page.cc
      visible: page.hasBattery
      width: parent.width
      height: Style.space(84)

      Text {
        id: batIcon
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        text: page.batteryIcon(page.batteryPercent)
        color: page.batteryPercent >= 0 && page.batteryPercent < 15 && page.onBattery ? Color.urgent : page.cc.selectedText
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.displayLarge
      }
      Column {
        anchors.left: batIcon.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          textFormat: Text.PlainText
          text: page.batteryPercent + "%  " + (page.onBattery ? "on battery"
                : (page.batteryInfo.state === "fully-charged" ? "fully charged"
                : ((page.batteryInfo.state === "holding" || page.batteryInfo.state === "pending-charge") ? "holding at limit" : "charging")))
          color: page.cc.foreground
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.Bold
        }
        Text {
          visible: text.length > 0
          textFormat: Text.PlainText
          text: [page.batteryInfo.time ? (page.onBattery ? page.batteryInfo.time + " left" : page.batteryInfo.time + " to full") : "",
                 page.batteryInfo.rate || "", page.batteryInfo.threshold ? "limit " + page.batteryInfo.threshold : ""]
                 .filter(function(v) { return v }).join("   ·   ")
          color: page.cc.foreground
          opacity: 0.65
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    SectionTitle { cc: page.cc; text: "POWER PROFILE" + (page.hasBattery ? (page.onBattery ? "  ·  ON BATTERY" : "  ·  PLUGGED IN") : "") }
    Grid {
      id: profileGrid
      width: parent.width
      columns: Math.max(1, page.profiles.length)
      spacing: page.cc.gap
      Repeater {
        model: page.profiles
        delegate: Tile {
          required property var modelData
          cc: page.cc
          width: (profileGrid.width - profileGrid.spacing * (profileGrid.columns - 1)) / profileGrid.columns
          icon: page.profileIcon(modelData.name)
          label: page.profileLabel(modelData.name)
          detail: modelData.active ? "Active" : ""
          active: modelData.active
          onActivated: page.setProfile(modelData.name)
        }
      }
    }
    Text {
      width: parent.width
      visible: page.profiles.length === 0
      textFormat: Text.PlainText
      text: "Power profiles aren't available (power-profiles-daemon not running)."
      color: page.cc.foreground
      opacity: 0.55
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.bodySmall
      leftPadding: Style.spacing.sm
    }

    SectionTitle { cc: page.cc; text: "SESSION" }
    Grid {
      id: sessionGrid
      width: parent.width
      columns: 3
      spacing: page.cc.gap
      readonly property real cellWidth: (width - spacing * 2) / 3

      Tile { cc: page.cc; width: sessionGrid.cellWidth; icon: ""; label: "Lock"; onActivated: page.session("lock", "omarchy-system-lock", false) }
      Tile { cc: page.cc; width: sessionGrid.cellWidth; icon: ""; label: "Suspend"; onActivated: page.session("suspend", "systemctl suspend", false) }
      Tile { cc: page.cc; width: sessionGrid.cellWidth; icon: ""; label: "Screensaver"; onActivated: page.session("screensaver", "omarchy-launch-screensaver force", false) }
      Tile {
        cc: page.cc; width: sessionGrid.cellWidth; icon: ""
        label: page.armed === "logout" ? "Click to confirm" : "Log out"
        active: page.armed === "logout"
        onActivated: page.session("logout", "omarchy-system-logout", true)
      }
      Tile {
        cc: page.cc; width: sessionGrid.cellWidth; icon: ""
        label: page.armed === "reboot" ? "Click to confirm" : "Reboot"
        active: page.armed === "reboot"
        onActivated: page.session("reboot", "omarchy-system-reboot", true)
      }
      Tile {
        cc: page.cc; width: sessionGrid.cellWidth; icon: ""
        label: page.armed === "shutdown" ? "Click to confirm" : "Shut down"
        active: page.armed === "shutdown"
        onActivated: page.session("shutdown", "omarchy-system-shutdown", true)
      }
    }
  }
}
QUATTRO_EMBED_17
  chmod 644 "$d/pages/PowerPage.qml"
  cat > "$d/pages/SectionTitle.qml" <<'QUATTRO_EMBED_18'
import QtQuick
import qs.Commons

Text {
  property var cc
  textFormat: Text.PlainText
  color: cc ? cc.foreground : "white"
  opacity: 0.55
  font.family: cc ? cc.fontFamily : "monospace"
  font.pixelSize: Style.font.caption
  font.weight: Font.Bold
  font.letterSpacing: 1
  topPadding: Style.spacing.sm
}
QUATTRO_EMBED_18
  chmod 644 "$d/pages/SectionTitle.qml"
  cat > "$d/pages/SystemPage.qml" <<'QUATTRO_EMBED_19'
import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// System: CPU (with a 60 s history), memory, swap, disk, temperature,
// load, and the busiest processes. Sampled every 2 s while visible.
Item {
  id: page
  property var cc

  property var info: ({})
  property var procs: []
  property var lastCpu: null
  property int cpuPercent: 0
  property var cpuHistory: []
  readonly property int historyLength: 30

  function gib(kib) { return (Number(kib) / 1048576).toFixed(1) }
  function ratio(used, total) { return total > 0 ? Math.max(0, Math.min(1, used / total)) : 0 }

  function ingest(raw) {
    var s
    try { s = JSON.parse(raw || "{}") } catch (e) { return }
    if (page.lastCpu && s.cpuTotal > page.lastCpu.total) {
      var dt = s.cpuTotal - page.lastCpu.total
      var di = s.cpuIdle - page.lastCpu.idle
      page.cpuPercent = Math.max(0, Math.min(100, Math.round(100 * (dt - di) / dt)))
      var hist = page.cpuHistory.slice(-(page.historyLength - 1))
      hist.push(page.cpuPercent)
      page.cpuHistory = hist
    }
    page.lastCpu = { total: s.cpuTotal, idle: s.cpuIdle }
    var nextProcs = s.procs || []
    if (JSON.stringify(nextProcs) !== JSON.stringify(page.procs)) page.procs = nextProcs
    page.info = s
  }

  Process {
    id: proc
    command: ["bash", page.cc.pluginDir + "/sysinfo.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: page.ingest(text)
    }
  }
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!proc.running) proc.running = true
  }

  component Meter: Card {
    id: meter
    property string icon: ""
    property string label: ""
    property string value: ""
    property real fraction: 0
    property color barColor: page.cc.selectedText

    cc: page.cc
    height: Math.max(Style.space(70), Style.font.title + Style.font.caption + Style.spacing.xl * 2 + Style.space(6))

    Column {
      anchors.fill: parent
      anchors.margins: Style.spacing.lg
      spacing: Style.spacing.sm

      Item {
        width: parent.width
        height: Style.font.title
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: meter.icon + "  " + meter.label
          color: page.cc.foreground
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: meter.value
          color: page.cc.selectedText
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.Bold
        }
      }
      Rectangle {
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Style.selectedFillFor(page.cc.foreground, Color.accent)
        Rectangle {
          width: parent.width * meter.fraction
          height: parent.height
          radius: parent.radius
          color: meter.fraction > 0.9 ? Color.urgent : meter.barColor
          Behavior on width { NumberAnimation { duration: 300 } }
        }
      }
    }
  }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    // CPU history
    Card {
      cc: page.cc
      width: parent.width
      height: Style.space(120)

      Text {
        id: cpuTitle
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.spacing.lg
        textFormat: Text.PlainText
        text: "  CPU" + (page.info.cpuModel ? "  ·  " + page.info.cpuModel : "")
        width: parent.width - cpuValue.width - Style.spacing.lg * 3
        elide: Text.ElideRight
        color: page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        id: cpuValue
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.lg
        text: page.cpuPercent + "%"
        color: page.cc.selectedText
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.display
        font.weight: Font.Bold
      }
      Row {
        id: bars
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.spacing.lg
        height: parent.height - cpuValue.height - Style.spacing.lg * 3
        spacing: Style.space(2)
        readonly property real barWidth: (width - spacing * (page.historyLength - 1)) / page.historyLength

        Repeater {
          model: page.historyLength
          delegate: Item {
            required property int index
            readonly property int sampleIndex: index - (page.historyLength - page.cpuHistory.length)
            readonly property real v: sampleIndex >= 0 ? page.cpuHistory[sampleIndex] / 100 : 0
            width: bars.barWidth
            height: bars.height
            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: Math.max(Style.space(2), parent.height * parent.v)
              radius: Math.min(width / 2, Style.space(2))
              color: parent.v > 0.9 ? Color.urgent : page.cc.selectedText
              opacity: parent.sampleIndex >= 0 ? 0.35 + 0.65 * (parent.index / page.historyLength) : 0.12
            }
          }
        }
      }
    }

    Grid {
      id: meters
      width: parent.width
      columns: 2
      spacing: page.cc.gap
      readonly property real cellWidth: (width - spacing) / 2

      Meter {
        width: meters.cellWidth
        icon: ""
        label: "Memory"
        fraction: page.ratio(page.info.memTotal - page.info.memAvail, page.info.memTotal)
        value: page.info.memTotal ? page.gib(page.info.memTotal - page.info.memAvail) + " / " + page.gib(page.info.memTotal) + " GiB" : "–"
      }
      Meter {
        width: meters.cellWidth
        icon: ""
        label: "Disk (/)"
        fraction: page.ratio(page.info.diskUsed, page.info.diskTotal)
        value: page.info.diskTotal ? page.gib(page.info.diskUsed) + " / " + page.gib(page.info.diskTotal) + " GiB" : "–"
      }
      Meter {
        width: meters.cellWidth
        icon: ""
        label: "Swap"
        fraction: page.ratio(page.info.swapTotal - page.info.swapFree, page.info.swapTotal)
        value: page.info.swapTotal ? page.gib(page.info.swapTotal - page.info.swapFree) + " / " + page.gib(page.info.swapTotal) + " GiB" : "None"
      }
      Meter {
        width: meters.cellWidth
        icon: ""
        label: "Temperature"
        fraction: page.info.temp ? Math.min(1, page.info.temp / 100) : 0
        value: page.info.temp ? page.info.temp + " °C" : "No sensor"
      }
    }

    Card {
      cc: page.cc
      width: parent.width
      height: Math.max(Style.space(40), Style.font.bodySmall + Style.spacing.lg * 2)
      Text {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.lg
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: "Load " + (page.info.load || "–") + "   ·   " + (page.info.cores || "?") + " cores   ·   Linux " + (page.info.kernel || "")
        color: page.cc.foreground
        opacity: 0.75
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }

    Item {
      width: parent.width
      height: procTitle.height
      SectionTitle { id: procTitle; cc: page.cc; text: "TOP PROCESSES" }
      IconButton {
        cc: page.cc
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: ""
        text: "btop"
        fontSize: Style.font.caption
        tooltipText: "Open btop"
        onClicked: page.cc.runAndClose("omarchy-launch-or-focus-tui btop")
      }
    }
    Repeater {
      model: page.procs
      delegate: ListRow {
        required property var modelData
        cc: page.cc
        clickable: false
        icon: ""
        title: modelData.name
        trailing: modelData.cpu.toFixed(1) + "% CPU   " + modelData.mem.toFixed(1) + "% RAM"
      }
    }
  }
}
QUATTRO_EMBED_19
  chmod 644 "$d/pages/SystemPage.qml"
  cat > "$d/pages/Tile.qml" <<'QUATTRO_EMBED_20'
import QtQuick
import qs.Commons

// Square-ish quick toggle: icon, label, detail line.
Rectangle {
  id: tile
  property var cc
  property string icon: ""
  property string label: ""
  property string detail: ""
  property bool active: false
  property bool available: true
  signal activated()

  height: cc ? cc.tileHeight : 64
  radius: cc ? cc.cornerRadius : 0
  color: active ? cc.selectedBackground
       : (tileMouse.containsMouse && available ? Qt.rgba(cc.foreground.r, cc.foreground.g, cc.foreground.b, 0.05) : "transparent")
  border.width: 1
  border.color: active ? Qt.rgba(cc.selectedText.r, cc.selectedText.g, cc.selectedText.b, 0.35) : cc.subtle
  opacity: available ? 1 : 0.4

  Column {
    anchors.centerIn: parent
    width: parent.width - Style.spacing.md * 2
    spacing: Style.space(3)

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: tile.icon
      color: tile.active ? tile.cc.selectedText : tile.cc.foreground
      font.family: tile.cc.fontFamily
      font.pixelSize: Style.font.iconLarge
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: tile.label
      color: tile.active ? tile.cc.selectedText : tile.cc.foreground
      font.family: tile.cc.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      visible: tile.detail.length > 0
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: tile.detail
      color: tile.cc.foreground
      opacity: 0.55
      font.family: tile.cc.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  MouseArea {
    id: tileMouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: tile.available
    cursorShape: Qt.PointingHandCursor
    onClicked: tile.activated()
  }
}
QUATTRO_EMBED_20
  chmod 644 "$d/pages/Tile.qml"
  cat > "$d/pages/WeatherPage.qml" <<'QUATTRO_EMBED_21'
import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "../../panels/weather/Model.js" as WModel

// Weather: current conditions, the next hours, and the next days, from
// wttr.in -- the same source, location setting
// (~/.local/state/omarchy/settings/weather.json) and helpers as Omarchy's
// weather panel. The location can be changed here (omarchy-weather-location).
Item {
  id: page
  property var cc

  readonly property string locationPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
  property var location: ({ name: "", latitude: null, longitude: null })
  property var report: cc && cc.weatherCache ? cc.weatherCache.report : null
  property bool loading: false
  property string error: ""
  property bool editing: false

  readonly property var current: report && report.current_condition ? report.current_condition[0] : null
  readonly property string country: report && report.nearest_area && report.nearest_area[0] && report.nearest_area[0].country
    ? report.nearest_area[0].country[0].value : ""
  readonly property string area: report && report.nearest_area && report.nearest_area[0] && report.nearest_area[0].areaName
    ? report.nearest_area[0].areaName[0].value : ""
  readonly property bool imperial: WModel.shouldUseImperial("", Qt.locale().name, page.country)
  readonly property string todayKey: Qt.formatDate(new Date(), "yyyy-MM-dd")
  readonly property var days: report ? WModel.buildForecastDays(report, null, page.todayKey) : []
  readonly property var hours: page.nextHours()

  function minutesOf(text) {
    var m = String(text || "").match(/(\d+):(\d+)\s*(AM|PM)?/i)
    if (!m) return -1
    var h = parseInt(m[1], 10) % 12
    if (m[3] && m[3].toUpperCase() === "PM") h += 12
    if (!m[3]) h = parseInt(m[1], 10)
    return h * 60 + parseInt(m[2], 10)
  }
  function isNight(minutes, day) {
    var astro = day && day.astronomy ? day.astronomy[0] : null
    var rise = astro ? page.minutesOf(astro.sunrise) : -1
    var set = astro ? page.minutesOf(astro.sunset) : -1
    if (rise < 0) rise = 6 * 60
    if (set < 0) set = 20 * 60
    return minutes < rise || minutes >= set
  }
  function temp(c, f) {
    var v = page.imperial ? f : c
    return v === undefined || v === null || v === "" ? "–" : v + "°"
  }
  function nextHours() {
    if (!page.report || !page.report.weather) return []
    var now = new Date()
    var nowMin = now.getHours() * 60 + now.getMinutes()
    var out = []
    for (var d = 0; d < page.report.weather.length && out.length < 8; d++) {
      var day = page.report.weather[d]
      var hourly = day.hourly || []
      for (var i = 0; i < hourly.length && out.length < 8; i++) {
        var t = parseInt(String(hourly[i].time || "0"), 10)
        var mins = Math.floor(t / 100) * 60
        if (d === 0 && mins + 180 <= nowMin) continue
        out.push({
          label: (d === 0 && out.length === 0) ? "Now" : (Math.floor(t / 100) < 10 ? "0" : "") + Math.floor(t / 100) + ":00",
          icon: WModel.iconForCode(hourly[i].weatherCode, page.isNight(mins, day)),
          temp: page.temp(hourly[i].tempC, hourly[i].tempF),
          rain: Number(hourly[i].chanceofrain) || 0
        })
      }
    }
    return out
  }
  function currentIcon() {
    if (!page.current) return ""
    var now = new Date()
    var day = page.report && page.report.weather ? page.report.weather[0] : null
    return WModel.iconForCode(page.current.weatherCode, page.isNight(now.getHours() * 60 + now.getMinutes(), day))
  }
  function dayLabel(dateString) {
    return WModel.dayName(dateString, function(date) { return Qt.formatDate(date, "dddd") })
  }

  function fetch() {
    if (fetchProc.running) return
    var q = WModel.wttrLocationQuery(page.location.name, page.location.latitude, page.location.longitude)
    page.loading = true
    fetchProc.command = ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + q + "?format=j1"]
    fetchProc.running = true
  }
  function setLocation(name) {
    var n = String(name || "").trim()
    page.editing = false
    if (!saveProc.running) {
      saveProc.command = n ? ["omarchy-weather-location", "--set", n] : ["omarchy-weather-location", "--clear"]
      saveProc.running = true
    }
  }

  // Fetch only once the saved location is known (FileView loads async), and
  // only if the cached report is older than 10 minutes.
  function fetchIfStale() {
    var fresh = page.cc.weatherCache && (Date.now() - page.cc.weatherCache.fetchedAt) < 10 * 60 * 1000
    if (!fresh) page.fetch()
  }

  FileView {
    id: locationFile
    path: page.locationPath
    printErrors: false
    onLoaded: { page.location = WModel.parseLocationFile(text()); page.fetchIfStale() }
    onLoadFailed: { page.location = WModel.parseLocationFile(""); page.fetchIfStale() }
  }
  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "{}")
          if (parsed && parsed.current_condition) {
            page.cc.weatherCache = { report: parsed, fetchedAt: Date.now() }
            page.report = parsed
            page.error = ""
          } else {
            page.error = "No weather data for this location."
          }
        } catch (e) {
          page.error = "Couldn't reach wttr.in."
        }
      }
    }
    onExited: function(code) {
      page.loading = false
      if (code !== 0 && !page.report) page.error = "Couldn't reach wttr.in."
    }
  }
  Process {
    id: saveProc
    onExited: { page.cc.weatherCache = null; locationFile.reload(); reloadThenFetch.restart() }
  }
  Timer { id: reloadThenFetch; interval: 300; onTriggered: page.fetch() }

  PageScroll {
    anchors.fill: parent
    spacing: page.cc.gap

    // Location bar
    Item {
      width: parent.width
      height: Math.max(Style.space(34), Style.font.body + Style.spacing.lg * 2)

      Text {
        anchors.left: parent.left
        anchors.right: locButtons.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: !page.editing
        textFormat: Text.PlainText
        text: "  " + (page.location.name || (page.area ? page.area + (page.country ? ", " + page.country : "") + "  (auto)" : "Detecting location…"))
              + (page.loading ? "   ·   updating…" : "")
        color: page.cc.foreground
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      TextField {
        id: locField
        anchors.left: parent.left
        anchors.right: locButtons.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: page.editing
        placeholderText: "City, e.g. Berlin  (empty = automatic)"
        foreground: page.cc.foreground
        accent: page.cc.selectedText
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: page.setLocation(text)
        Keys.onEscapePressed: page.editing = false
        onVisibleChanged: if (visible) { text = page.location.name || ""; Qt.callLater(forceActiveFocus) }
      }
      Row {
        id: locButtons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm
        IconButton {
          cc: page.cc
          iconText: page.editing ? "" : ""
          tooltipText: page.editing ? "Save location" : "Change location"
          onClicked: page.editing ? page.setLocation(locField.text) : (page.editing = true)
        }
        IconButton {
          cc: page.cc
          iconText: ""
          tooltipText: "Refresh"
          enabled: !page.loading
          onClicked: page.fetch()
        }
      }
    }

    // Current conditions
    Card {
      cc: page.cc
      width: parent.width
      height: Style.space(120)
      visible: !!page.current

      Text {
        id: bigIcon
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xxl
        anchors.verticalCenter: parent.verticalCenter
        text: page.currentIcon()
        color: page.cc.selectedText
        font.family: page.cc.fontFamily
        font.pixelSize: Style.font.displayLarge * 2
      }
      Column {
        anchors.left: bigIcon.right
        anchors.leftMargin: Style.spacing.xxl
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: page.current ? page.temp(page.current.temp_C, page.current.temp_F) : ""
          color: page.cc.selectedText
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.weight: Font.Bold
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.current && page.current.weatherDesc && page.current.weatherDesc[0] ? page.current.weatherDesc[0].value : ""
          color: page.cc.foreground
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.current
            ? "Feels like " + page.temp(page.current.FeelsLikeC, page.current.FeelsLikeF)
              + "   ·    " + page.current.humidity + "%"
              + "   ·    " + (page.imperial ? page.current.windspeedMiles + " mph" : page.current.windspeedKmph + " km/h")
            : ""
          color: page.cc.foreground
          opacity: 0.65
          font.family: page.cc.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    // Next hours
    SectionTitle { cc: page.cc; text: "NEXT HOURS"; visible: page.hours.length > 0 }
    Card {
      cc: page.cc
      width: parent.width
      height: Style.space(96)
      visible: page.hours.length > 0

      Row {
        anchors.fill: parent
        anchors.margins: Style.spacing.md
        Repeater {
          model: page.hours
          delegate: Column {
            required property var modelData
            width: (parent.width) / Math.max(1, page.hours.length)
            spacing: Style.space(3)
            anchors.verticalCenter: parent.verticalCenter
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.label; color: page.cc.foreground; opacity: 0.6; font.family: page.cc.fontFamily; font.pixelSize: Style.font.caption }
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.icon; color: page.cc.selectedText; font.family: page.cc.fontFamily; font.pixelSize: Style.font.iconLarge }
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.temp; color: page.cc.foreground; font.family: page.cc.fontFamily; font.pixelSize: Style.font.body; font.weight: Font.Medium }
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; visible: modelData.rain >= 20; text: " " + modelData.rain + "%"; color: page.cc.foreground; opacity: 0.55; font.family: page.cc.fontFamily; font.pixelSize: Style.font.caption }
          }
        }
      }
    }

    // Next days
    SectionTitle { cc: page.cc; text: "NEXT DAYS"; visible: page.days.length > 0 }
    Repeater {
      model: page.days
      delegate: ListRow {
        required property var modelData
        cc: page.cc
        clickable: false
        icon: WModel.dayIcon(modelData)
        title: page.dayLabel(modelData.date)
        trailing: WModel.bareTempForDay(modelData, "max", page.imperial) + "  /  " + WModel.bareTempForDay(modelData, "min", page.imperial)
      }
    }

    Text {
      width: parent.width
      visible: page.error !== "" && !page.current
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.spacing.huge
      textFormat: Text.PlainText
      text: page.error
      color: page.cc.foreground
      opacity: 0.6
      font.family: page.cc.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
QUATTRO_EMBED_21
  chmod 644 "$d/pages/WeatherPage.qml"
}

write_profile_fabian() {
  # Fabian's Omarchy 3.2.1 setup, ported (wallpaper is downloaded separately).
  # Generated from source files; do not edit by hand.
  local d="$1"
  mkdir -p "$d"
  mkdir -p "$d/.config/hypr"
  mkdir -p "$d/.config/omarchy/bar/modules"
  mkdir -p "$d/.config/omarchy/hooks/theme-set.d"
  cat > "$d/README.md" <<'QUATTRO_EMBED_0'
# Fabian's profile (ported from Omarchy 3.2.1)

Built into install.sh:   ./install.sh --profile fabian
(or from a folder:       ./install.sh --profile ./fabian-profile)

- .config/hypr/monitors.lua    DP-2 1080p@60 left, DP-1 1440p@85 (scale 1.25) right,
                               HDMI-A-4 / DP-3 entries, GDK_SCALE=1, fallback for others
- .config/hypr/input.lua       keyboard us,de; mouse sensitivity -0.1; touchpad scroll 0.2
- .config/hypr/looknfeel.lua   rounded corners (8)
- .config/omarchy/bar/modules  CPU and memory widgets (old Waybar icons/colors)
- .config/omarchy/hooks/theme-set.d/50-personal-bar
                               dark Nord bar (#242933, white text, soft-red alerts, 30px)
                               on every theme; delete it to let the bar follow the theme
- profile.sh                   bar layout + per-widget colors from the old Waybar CSS
                               (workspaces, clock, network, bluetooth, audio, keyboard
                               layout, control center), wallpaper, bar colors
- wallpaper                    Tokyo Night "Milad Fakurian" purple-blue, downloaded from
                               Omarchy 3.2.1 and checksum-verified

Per-widget colors live in ~/.config/omarchy/shell.json as "color" on each bar entry
(workspaces also take "activeColor" and "emptyColor"); edit them there any time.
QUATTRO_EMBED_0
  chmod 644 "$d/README.md"
  cat > "$d/profile.sh" <<'QUATTRO_EMBED_1'
#!/bin/bash
# Runs as the desktop user after the profile's files are copied into $HOME.
# Ported from Fabian's Omarchy 3.2.1 setup.
set -uo pipefail

shell_json="$HOME/.config/omarchy/shell.json"

# --- Top bar layout (from the Omarchy 3 Waybar config) -----------------------
# left:   menu, workspaces, CPU, memory
# center: update + recording indicators (no clock in the middle)
# right:  keyboard layout (only shows with 2+ layouts), clock, tray,
#         bluetooth, network, audio, control center
# Colors are the per-module colors from the old Waybar style.css.
if [[ -f $shell_json ]] && command -v jq >/dev/null; then
  tmp="$(mktemp)"
  if jq '
    ( ( [ (.bar.layout // {})[]?[]? | select(type == "object" and .id == "omarchy.clock") ] | first )
      // {"id": "omarchy.clock", "format": "dddd HH:mm", "formatAlt": "d MMMM '\''W'\''ww yyyy"}
    ) as $clock
    | .bar.layout = {
        left: [
          {"id": "omarchy.menu"},
          {"id": "omarchy.workspaces", "color": "#d4d2a9", "activeColor": "#81A1C1", "emptyColor": "#85909e"},
          {"id": "cpu", "type": "qml", "color": "#fa9f8e", "interval": 5},
          {"id": "memory", "type": "qml", "color": "#b9fac2", "interval": 3}
        ],
        center: [
          {"id": "omarchy.indicators"},
          {"id": "omarchy.system-update"}
        ],
        right: [
          {"id": "omarchy.keyboard-layout", "color": "#d1cfcf"},
          ($clock + {"color": "#8a909e"}),
          {"id": "omarchy.tray"},
          {"id": "omarchy.bluetooth", "color": "#5E81AC"},
          {"id": "omarchy.network", "color": "#5E81AC"},
          {"id": "omarchy.audio", "color": "#81A1C1"},
          {"id": "omarchy.control-center", "color": "#7a95c9"}
        ]
      }
    | .bar.position = "top"
    | del(.bar.centerAnchor)
  ' "$shell_json" > "$tmp"; then
    cat "$tmp" > "$shell_json"
  else
    echo "profile: could not update $shell_json" >&2
  fi
  rm -f "$tmp"
fi

# --- Wallpaper: Tokyo Night with the purple-blue Milad Fakurian image ---------
bg="$HOME/.config/omarchy/backgrounds/tokyo-night/3-Milad-Fakurian-Abstract-Purple-Blue.jpg"
theme_name="$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)"
if [[ -f $bg && ${theme_name,,} == "tokyo night" || -f $bg && ${theme_name,,} == "tokyo-night" ]]; then
  omarchy-theme-bg-set "$bg" >/dev/null 2>&1 || ln -nsf "$bg" "$HOME/.local/state/omarchy/current/background"
fi

# --- Bar colors / height (the theme-set hook also re-applies them later) ------
hook="$HOME/.config/omarchy/hooks/theme-set.d/50-personal-bar"
[[ -f $hook ]] && bash "$hook"

exit 0
QUATTRO_EMBED_1
  chmod 755 "$d/profile.sh"
  cat > "$d/.config/hypr/input.lua" <<'QUATTRO_EMBED_2'
-- Ported from Omarchy 3.2.1 input.conf. Only your own changes are here;
-- everything else (repeat rate, compose key, numlock, ...) is Omarchy's default.
hl.config({
  input = {
    -- US + German. Switch by clicking the layout indicator in the bar.
    kb_layout = "us,de",

    -- Slightly slower mouse.
    sensitivity = -0.1,

    touchpad = {
      -- Half of Omarchy's default scroll speed.
      scroll_factor = 0.2,
    },
  },
})
QUATTRO_EMBED_2
  chmod 644 "$d/.config/hypr/input.lua"
  cat > "$d/.config/hypr/looknfeel.lua" <<'QUATTRO_EMBED_3'
-- Ported from Omarchy 3.2.1 looknfeel.conf.
hl.config({
  decoration = {
    -- Round window corners.
    rounding = 8,
  },
})
QUATTRO_EMBED_3
  chmod 644 "$d/.config/hypr/looknfeel.lua"
  cat > "$d/.config/hypr/monitors.lua" <<'QUATTRO_EMBED_4'
-- Ported from Omarchy 3.2.1 (monitors.conf + hyprland.conf).
-- List outputs and modes with: hyprctl monitors all

-- Fallback for any other display (e.g. a VM or a laptop panel).
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- Desk: DP-2 on the left, DP-1 (1440p) to its right.
hl.monitor({ output = "DP-2", mode = "1920x1080@60.00", position = "0x0", scale = 1 })
hl.monitor({ output = "DP-1", mode = "2560x1440@84.98", position = "1920x0", scale = 1.25 })

-- Other displays you had set up.
hl.monitor({ output = "HDMI-A-4", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "DP-3", mode = "preferred", position = "auto", scale = 1.25 })

-- Keep GTK/XWayland apps unscaled (you had GDK_SCALE=1).
hl.env("GDK_SCALE", "1")
QUATTRO_EMBED_4
  chmod 644 "$d/.config/hypr/monitors.lua"
  cat > "$d/.config/omarchy/bar/modules/cpu.qml" <<'QUATTRO_EMBED_5'
import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

// CPU usage, ported from the Omarchy 3 Waybar "cpu" module.
// shell.json settings: "color" (hex, default coral), "interval" (seconds, default 5).
Item {
  id: root
  property var bar
  property string moduleName
  property var settings

  property int percent: -1
  property var last: null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function sample(line) {
    // "cpu  user nice system idle iowait irq softirq steal ..."
    var f = String(line || "").trim().split(/\s+/).slice(1).map(Number)
    if (f.length < 4 || f.some(isNaN)) return
    var idle = f[3] + (f[4] || 0)
    var total = f.reduce(function(a, b) { return a + b }, 0)
    if (root.last && total > root.last.total) {
      var busy = (total - root.last.total) - (idle - root.last.idle)
      root.percent = Math.max(0, Math.min(100, Math.round(100 * busy / (total - root.last.total))))
    }
    root.last = { total: total, idle: idle }
  }

  Process {
    id: statProc
    command: ["head", "-n1", "/proc/stat"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sample(text)
    }
  }

  Timer {
    interval: Math.max(1, Number((root.settings && root.settings.interval) || 5)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statProc.running) statProc.running = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " " + (root.percent < 0 ? "--" : root.percent) + "%"
    fontSize: Style.font.caption
    horizontalMargin: 6
    foreground: (root.settings && root.settings.color) || "#fa9f8e"
    tooltipText: "CPU usage"
    onPressed: function() { if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop") }
  }
}
QUATTRO_EMBED_5
  chmod 644 "$d/.config/omarchy/bar/modules/cpu.qml"
  cat > "$d/.config/omarchy/bar/modules/memory.qml" <<'QUATTRO_EMBED_6'
import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

// Memory usage, ported from the Omarchy 3 Waybar "memory" module.
// shell.json settings: "color" (hex, default mint), "interval" (seconds, default 3).
Item {
  id: root
  property var bar
  property string moduleName
  property var settings

  property int percent: -1
  property string detail: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function parse(text) {
    var total = 0, avail = 0
    String(text || "").split("\n").forEach(function(line) {
      var m = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/)
      if (!m) return
      if (m[1] === "MemTotal") total = Number(m[2])
      else avail = Number(m[2])
    })
    if (total <= 0) return
    var used = total - avail
    root.percent = Math.round(100 * used / total)
    root.detail = (used / 1048576).toFixed(1) + " / " + (total / 1048576).toFixed(1) + " GiB"
  }

  Process {
    id: memProc
    command: ["grep", "-E", "^(MemTotal|MemAvailable):", "/proc/meminfo"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Timer {
    interval: Math.max(1, Number((root.settings && root.settings.interval) || 3)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!memProc.running) memProc.running = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " " + (root.percent < 0 ? "--" : root.percent) + "%"
    fontSize: Style.font.caption
    horizontalMargin: 6
    foreground: (root.settings && root.settings.color) || "#b9fac2"
    tooltipText: root.detail ? "Memory: " + root.detail : "Memory usage"
    onPressed: function() { if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop") }
  }
}
QUATTRO_EMBED_6
  chmod 644 "$d/.config/omarchy/bar/modules/memory.qml"
  cat > "$d/.config/omarchy/hooks/theme-set.d/50-personal-bar" <<'QUATTRO_EMBED_7'
#!/bin/bash
# Keep the Omarchy 3 look of the top bar on every theme: dark Nord background,
# white text, 30px tall, soft-red alerts. Runs after each `omarchy theme set` (and once from
# the installer). Delete this file to let the bar follow the theme again.

BAR_BACKGROUND="#242933"
BAR_TEXT="#ffffff"
BAR_HEIGHT=30
# Alerts (muted audio, no network, recording, updates) -- your old .muted/.disconnected red.
BAR_ACTIVE="#fb958b"

theme="$HOME/.local/state/omarchy/current/theme"
shell_toml="$theme/shell.toml"
[[ -f $shell_toml ]] || exit 0

tmp="$(mktemp)"
awk -v bg="$BAR_BACKGROUND" -v fg="$BAR_TEXT" -v h="$BAR_HEIGHT" -v act="$BAR_ACTIVE" '
  /^\[/ { in_bar = ($0 ~ /^\[bar\][[:space:]]*$/) }
  in_bar && /^background[[:space:]]*=/      { print "background       = \"" bg "\""; next }
  in_bar && /^text[[:space:]]*=/            { print "text             = \"" fg "\""; next }
  in_bar && /^size-horizontal[[:space:]]*=/ { print "size-horizontal  = " h; next }
  in_bar && /^active[[:space:]]*=/          { print "active           = \"" act "\""; next }
  { print }
' "$shell_toml" > "$tmp" && cat "$tmp" > "$shell_toml"
rm -f "$tmp"

# Push the change into the running shell (same call omarchy-theme-set uses).
if command -v omarchy-shell >/dev/null 2>&1; then
  colors=""
  [[ -f $theme/colors.toml ]] && colors="$(base64 -w 0 "$theme/colors.toml")"
  timeout 2 omarchy-shell shell applyTheme "$colors" "$(base64 -w 0 "$shell_toml")" >/dev/null 2>&1 || true
fi
QUATTRO_EMBED_7
  chmod 755 "$d/.config/omarchy/hooks/theme-set.d/50-personal-bar"
}

# <<< END EMBEDDED FILES <<<

stage_runtime_tree() {
  # Quattro's privileged commands (Plymouth, DNS, browser theming, passwordless
  # sudo, ...) refuse to run root actions from a tree a user can write to, and
  # call each other through hardcoded /usr/bin/omarchy-* and
  # /usr/share/omarchy paths. So the runtime is staged here, patched as the
  # user, and then installed as a real pacman package with the exact layout of
  # the official `omarchy` package (see build_runtime_package).
  log "Staging the Quattro runtime (AI, web apps and provisioning removed)"

  STAGE_DIR="$(mktemp -d)"
  STAGE_ROOT="$STAGE_DIR/omarchy"
  local T="$STAGE_ROOT"

  run mkdir -p "$T"
  run cp -a "$SOURCE_DIR/." "$T/"
  run rm -rf "$T/.git"

  # AI / agent material
  run rm -rf \
    "$T/agents" \
    "$T/default/agents" \
    "$T/shell/plugins/agents" \
    "$T/config/opencode" \
    "$T/manual/17-ai.md"

  # Full-distro provisioning. install/helpers stays: omarchy-install-browser
  # and omarchy-theme-set-browser source install/helpers/browser-policy.sh.
  if [[ -d "$T/install" ]]; then
    run find "$T/install" -mindepth 1 -maxdepth 1 ! -name helpers -exec rm -rf -- {} +
  fi
  run rm -rf \
    "$T/provisioning" \
    "$T/migrations" \
    "$T/test" \
    "$T/plans" \
    "$T/.github" \
    "$T/AGENTS.md" \
    "$T/CLAUDE.md"

  # Commands that belong to the AI / web-app / distro-provisioning layers.
  if [[ -d "$T/bin" ]]; then
    local f name
    for f in "$T"/bin/*; do
      name="${f##*/}"
      case "$name" in
        omarchy-agent*|omarchy-default-agent|omarchy-install-ai-*|omarchy-remove-ai-*|\
        omarchy-openclaw-*|omarchy-hermes-*|omarchy-install-openclaw-*|omarchy-install-hermes-*|\
        omarchy-theme-set-claude|omarchy-theme-set-hermes|omarchy-theme-set-pi|omarchy-theme-set-t3code|\
        omarchy-theme-set-vscode|omarchy-theme-set-obsidian|omarchy-theme-set-gnome|\
        omarchy-webapp-*|omarchy-launch-webapp|omarchy-launch-or-focus-webapp|\
        omarchy-apply-system|omarchy-apply-hardware|omarchy-provision-*|omarchy-reinstall|\
        omarchy-reinstall-pkgs|omarchy-upgrade-to-quattro|omarchy-install-preinstalls|\
        omarchy-remove-preinstalls|omarchy-system-factory-reset*)
          run rm -f -- "$f"
          ;;
      esac
    done
  fi

  # Web-app desktop entries and the AI icon.
  if [[ -d "$T/applications" ]]; then
    local desktop
    while IFS= read -r -d '' desktop; do
      if grep -qE 'omarchy-launch-(or-focus-)?webapp|omarchy-webapp-' "$desktop"; then
        run rm -f "$desktop"
      fi
    done < <(find "$T/applications" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
  fi
  run rm -f "$T/applications/icons/ChatGPT.png"

  # Rebrand the ASCII art the branding "reset" commands copy from.
  if (( ! DRY_RUN )); then
    [[ -f "$T/logo.txt" ]] && arch_wordmark > "$T/logo.txt"
    [[ -f "$T/icon.txt" ]] && arch_logo > "$T/icon.txt"
  fi

  patch_fastfetch
}

patch_fastfetch() {
  # Omarchy's system fastfetch config (also the About screen) hardcodes
  # "OS: Omarchy <version>" plus its git branch and release channel. Show the
  # real system instead: os-release name, with the Nerd Font Arch icon.
  local cfg="$STAGE_ROOT/etc/fastfetch/config.jsonc" tmp
  [[ -f $cfg ]] || return 0
  (( DRY_RUN )) && { echo "+ (patch $cfg: OS from /etc/os-release, drop Omarchy branch/channel)"; return 0; }

  tmp="$(mktemp)"
  if jq '
    (if (.logo | type) == "object" then .logo.color = {"1": "blue"} else . end) |
    .modules |= map(
      if type == "object" and ((.text? // "") | test("omarchy-version-branch|omarchy-version-channel")) then empty
      elif type == "object" and ((.text? // "") | test("omarchy-version\\)")) then
        .key = "\uf303 OS" | .text = ". /etc/os-release && echo \"${PRETTY_NAME:-$NAME} $(uname -m)\""
      else . end
    )
  ' "$cfg" > "$tmp" 2>/dev/null; then
    install -m 0644 "$tmp" "$cfg"
  else
    warn "Could not patch $cfg; fastfetch will still say Omarchy."
  fi
  rm -f "$tmp"
}

patch_hyprland() {
  log "Removing Quattro web-app and agent bindings"
  local T="$STAGE_ROOT"

  local apps="$T/default/hypr/bindings/applications.lua"
  local utils="$T/default/hypr/bindings/utilities.lua"
  [[ -f "$apps" ]] && run sed -i '/webapp[[:space:]]*=/d' "$apps"
  [[ -f "$utils" ]] && run sed -i '/"Agent", "omarchy-agent --pick"/d' "$utils"

  # Small standalone autostart. Quattro's original one runs first-run
  # provisioning, which installs agent hooks.
  local autostart="$T/default/hypr/autostart.lua"
  if [[ -f "$autostart" ]]; then
    run tee "$autostart" >/dev/null <<'LUA'
hl.on("hyprland.start", function()
  hl.exec_cmd("systemctl --user import-environment $(env | cut -d'=' -f 1)")
  hl.exec_cmd("dbus-update-activation-environment --systemd --all")

  hl.exec_cmd("omarchy-launch-shell")
  hl.exec_cmd(o.launch("omarchy-hyprland-monitor-watch"))
  hl.exec_cmd(o.launch("udiskie --automount --no-notify --no-tray"))
  hl.exec_cmd("omarchy-powerprofiles-init")
end)
LUA
  fi

  # Screen recording should work even if xdg-user-dirs wasn't initialized yet.
  local recorder="$T/bin/omarchy-capture-screenrecording"
  if [[ -f "$recorder" ]]; then
    run sed -i '/^OUTPUT_DIR=/a mkdir -p "$OUTPUT_DIR" || { echo "Cannot create screen recording directory: $OUTPUT_DIR" >&2; exit 1; }' "$recorder"
  fi

  # Theme switching: keep only desktop-native hooks.
  local theme_set="$T/bin/omarchy-theme-set"
  if [[ -f "$theme_set" ]]; then
    run sed -i \
      -e '/^[[:space:]]*omarchy-restart-opencode$/d' \
      -e '/^[[:space:]]*omarchy-restart-helix$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-pi$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-claude$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-hermes$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-t3code$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-vscode$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-obsidian$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-gnome$/d' \
      -e '/^[[:space:]]*omarchy-theme-set-herdr-machines/d' \
      "$theme_set"
  fi
}

patch_arch_updates() {
  log "Replacing Omarchy's update pipeline with Arch + AUR updates (yay)"
  local T="$STAGE_ROOT"

  # omarchy-update: repos + AUR in one pass. yay -Syu runs pacman for the repo
  # part, so this covers everything; falls back to paru, then plain pacman.
  if [[ -f "$T/bin/omarchy-update" ]]; then
    run tee "$T/bin/omarchy-update" >/dev/null <<'EOF'
#!/bin/bash
# omarchy:summary=Update the system: official repos, Omarchy repo and AUR
set -euo pipefail
if command -v yay >/dev/null 2>&1; then
  yay -Syu "$@"
elif command -v paru >/dev/null 2>&1; then
  paru -Syu "$@"
else
  sudo pacman -Syu "$@"
fi
omarchy-update-status >/dev/null 2>&1 || true
EOF
    run chmod 0755 "$T/bin/omarchy-update"
  fi

  # Bar indicator: repo updates (checkupdates) plus AUR updates (yay -Qua).
  if [[ -f "$T/bin/omarchy-update-available" ]]; then
    run tee "$T/bin/omarchy-update-available" >/dev/null <<'EOF'
#!/bin/bash
# omarchy:summary=List pending repo and AUR updates; exit 1 when there are none
set -uo pipefail
updates=$(checkupdates --nocolor 2>/dev/null)
if command -v yay >/dev/null 2>&1; then
  aur=$(yay -Qua --color never 2>/dev/null)
  [[ -n $aur ]] && updates+=${updates:+$'\n'}$aur
fi
[[ -n $updates ]] || exit 1
printf '%s\n' "$updates"
EOF
    run chmod 0755 "$T/bin/omarchy-update-available"
  fi

  if [[ -f "$T/bin/omarchy-update-status" ]]; then
    run tee "$T/bin/omarchy-update-status" >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
if omarchy-update-available >/dev/null 2>&1; then
  omarchy-shell -q omarchy.system-update refresh
else
  omarchy-shell -q omarchy.system-update clear
fi
EOF
    run chmod 0755 "$T/bin/omarchy-update-status"
  fi

  # The bar widget already launches omarchy-update, which is now the yay
  # wrapper above; only the tooltip label needs changing.
  local widget="$T/shell/plugins/bar/widgets/SystemUpdate.qml"
  if [[ -f "$widget" ]]; then
    run sed -i 's/Pending Omarchy Updates/Pending System Updates/' "$widget"
  fi
}

patch_pkg_helpers() {
  log "Making omarchy-pkg-add fall back to the AUR"

  # Upstream omarchy-pkg-add is plain `pacman -S`. This version tries the
  # configured repos first and builds the rest with yay/paru, so the Install
  # menu works with or without the [omarchy] repo.
  local cmd="$STAGE_ROOT/bin/omarchy-pkg-add"
  [[ -f "$cmd" ]] || (( DRY_RUN )) || return 0

  run tee "$cmd" >/dev/null <<'EOF'
#!/bin/bash

# omarchy:summary=Install packages from the repos, falling back to the AUR
# omarchy:args=<packages...>
# omarchy:requires-sudo=true

omarchy-pkg-missing "$@" || exit 0

repo=() aur=()
for pkg in "$@"; do
  pacman -Q -- "$pkg" &>/dev/null && continue
  if pacman -Si -- "$pkg" &>/dev/null; then repo+=("$pkg"); else aur+=("$pkg"); fi
done

if (( ${#repo[@]} )); then
  if (( EUID == 0 )); then
    pacman -S --noconfirm --needed -- "${repo[@]}" || exit 1
  else
    sudo pacman -S --noconfirm --needed -- "${repo[@]}" || exit 1
  fi
fi

if (( ${#aur[@]} )); then
  echo "Not in the configured repos, building from the AUR: ${aur[*]}"
  if (( EUID == 0 )); then
    echo -e "\033[31mError: can't build AUR packages as root: ${aur[*]}\033[0m" >&2
    exit 1
  elif command -v yay &>/dev/null; then
    yay -S --noconfirm --needed -- "${aur[@]}" || exit 1
  elif command -v paru &>/dev/null; then
    paru -S --noconfirm --needed -- "${aur[@]}" || exit 1
  else
    echo -e "\033[31mError: no AUR helper (yay/paru) for: ${aur[*]}\033[0m" >&2
    exit 1
  fi
fi

for pkg in "$@"; do
  if ! pacman -Q -- "$pkg" &>/dev/null; then
    echo -e "\033[31mError: Package '$pkg' did not install\033[0m" >&2
    exit 1
  fi
done

exit 0
EOF
  run chmod 0755 "$cmd"
}

patch_direct_boot() {
  # Upstream only looks for Omarchy's own UKI (omarchy*.efi, built by its
  # Limine setup). On plain Arch, mkinitcpio builds UKIs named after the
  # preset (arch-linux.efi). Accept any UKI, on an ESP at /boot or /efi, and
  # explain how to enable UKIs when there is none instead of a bare error.
  local cmd="$STAGE_ROOT/bin/omarchy-setup-direct-boot"
  [[ -f "$cmd" ]] || (( DRY_RUN )) || return 0
  log "Adapting Direct Boot to Arch's own UKIs"

  run tee "$cmd" >/dev/null <<'EOF'
#!/bin/bash

# omarchy:summary=Add or remove an EFI boot entry that boots an Arch UKI directly
# omarchy:requires-sudo=true

LABEL="Arch Linux (direct)"

if [[ ! -d /sys/firmware/efi ]]; then
  echo "Error: System is not booted in UEFI mode" >&2
  exit 1
fi

if ! omarchy-cmd-present efibootmgr; then
  omarchy-pkg-add efibootmgr || exit 1
fi

if ! sudo efibootmgr &>/dev/null; then
  echo "Error: efibootmgr is not functional on this firmware" >&2
  exit 1
fi

bios_vendor=$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null)
case "${bios_vendor,,}" in
  *"american megatrends"*)
    echo "Error: American Megatrends firmware may not safely support custom EFI entries" >&2
    exit 1
    ;;
  *apple*)
    echo "Error: Apple firmware uses its own boot manager" >&2
    exit 1
    ;;
esac

existing_entry=$(sudo efibootmgr | grep -F "$LABEL" | head -1)

if [[ -n $existing_entry ]]; then
  boot_num=$(echo "$existing_entry" | sed -n 's/^Boot\([0-9A-Fa-f]\+\).*/\1/p')
  if gum confirm "Disable direct boot (remove the '$LABEL' EFI entry)?"; then
    sudo efibootmgr --bootnum "$boot_num" --delete-bootnum >/dev/null
    echo "Removed EFI boot entry $boot_num."
  fi
  exit 0
fi

# Find a UKI on the ESP. Prefer an Omarchy one, then the main (non-fallback) one.
esp="" uki_file=""
for mnt in /boot /efi /boot/efi; do
  mountpoint -q "$mnt" 2>/dev/null || continue
  [[ -d $mnt/EFI/Linux ]] || continue
  uki_file=$(sudo find "$mnt/EFI/Linux" -maxdepth 1 -name 'omarchy*.efi' -printf '%f\n' 2>/dev/null | head -1)
  [[ -n $uki_file ]] || uki_file=$(sudo find "$mnt/EFI/Linux" -maxdepth 1 -name '*.efi' ! -name '*fallback*' -printf '%f\n' 2>/dev/null | sort | head -1)
  if [[ -n $uki_file ]]; then esp=$mnt; break; fi
done

if [[ -z $uki_file ]]; then
  cat >&2 <<'MSG'
No unified kernel image (UKI) found in <ESP>/EFI/Linux/.

Direct boot needs a UKI. On Arch, mkinitcpio can build one:
  1. Put your kernel command line in /etc/kernel/cmdline
     (copy it from /proc/cmdline, minus the initrd= / BOOT_IMAGE= parts).
  2. In /etc/mkinitcpio.d/linux.preset, comment out default_image= and set
       default_uki="/boot/EFI/Linux/arch-linux.efi"   (or /efi/... for an ESP at /efi)
  3. sudo mkinitcpio -P
Then run this again. Keep your current boot entry until the UKI boots fine.
See https://wiki.archlinux.org/title/Unified_kernel_image
MSG
  exit 1
fi

boot_source=$(findmnt -n -o SOURCE "$esp")
disk="/dev/$(lsblk -no PKNAME "$boot_source")"
part=$(cat "/sys/class/block/${boot_source##*/}/partition")

if gum confirm "Create EFI entry '$LABEL' for $uki_file (skips the bootloader menu)?"; then
  sudo efibootmgr --create \
    --disk "$disk" \
    --part "$part" \
    --label "$LABEL" \
    --loader "\\EFI\\Linux\\$uki_file"
fi
EOF
  run chmod 0755 "$cmd"
}

patch_standalone_menu() {
  log "Removing Omarchy/AI/web-app menu entries and using Arch + AUR updates"

  local menu="$STAGE_ROOT/default/omarchy/omarchy-menu.jsonc"
  [[ -f "$menu" ]] || return 0

  # One-entry-per-line JSONC records. Prefix patterns (no closing quote) take
  # out a parent and all its children.
  run sed -i \
    -e '/"learn\.omarchy"/d' \
    -e '/"learn\.community"/d' \
    -e '/"install\.ai/d' \
    -e '/"remove\.ai/d' \
    -e '/"install\.webapp"/d' \
    -e '/"remove\.webapp"/d' \
    -e '/"install\.tui"/d' \
    -e '/"install\.preinstalls"/d' \
    -e '/"remove\.preinstalls"/d' \
    -e '/"setup\.default\.agent/d' \
    -e '/"setup\.reset"/d' \
    -e '/"update\.omarchy"/d' \
    -e '/"update\.channel/d' \
    -e '/"update\.themes"/d' \
    -e '/"update\.password"/d' \
    -e '/"update\.time"/d' \
    -e '/"update\.timezone"/d' \
    -e '/omarchy-launch-webapp/d' \
    -e '/omarchy-webapp-/d' \
    -e '/omarchy-default-agent/d' \
    -e '/omarchy-install-ai-/d' \
    -e '/omarchy-remove-ai-/d' \
    "$menu"
  # (setup.reset is Omarchy's Snapper/Limine factory reset: it would roll a
  #  plain Arch install back to a snapshot layout it doesn't have.)

  # Native update entry: repos + AUR via the omarchy-update wrapper (yay -Syu).
  if ! grep -q '"update\.arch"' "$menu"; then
    run sed -i '/"update":/a\  "update.arch": {"icon":"󰣇","label":"System (repos + AUR)","action":"omarchy-launch-floating-terminal-with-presentation omarchy-update"},' "$menu"
  fi

  # The only displayed "Omarchy" labels left are the manual and update entries.
  run sed -i 's/"label":"Omarchy"/"label":"Arch Linux"/g' "$menu"
}

patch_shell_config() {
  log "Removing the AI widget from the Quickshell bar"

  local shell_json="$STAGE_ROOT/config/omarchy/shell.json"
  [[ -f "$shell_json" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  if jq '
    if (.bar.layout.right? | type) == "array" then
      .bar.layout.right = [
        .bar.layout.right[] |
        select((if type == "object" then .id else . end) != "omarchy.agents")
      ]
    else . end
  ' "$shell_json" > "$tmp" 2>/dev/null; then
    run install -m 0644 "$tmp" "$shell_json"
  else
    warn "Could not parse $shell_json with jq; leaving the AI widget entry in place."
  fi
  rm -f "$tmp"
}

patch_bar_colors() {
  # Per-widget colors, like Waybar's per-module CSS: any bar widget's entry in
  # ~/.config/omarchy/shell.json may set "color" (and workspaces also
  # "activeColor" / "emptyColor"). Without those keys nothing changes.
  log "Adding per-widget bar colors (shell.json \"color\")"
  local T="$STAGE_ROOT"
  local button="$T/shell/Ui/WidgetButton.qml"
  local workspaces="$T/shell/plugins/bar/widgets/Workspaces.qml"
  (( DRY_RUN )) && { echo "+ (patch WidgetButton.qml + Workspaces.qml for per-widget colors)"; return 0; }

  local anchor='  property color foreground: bar ? bar.barForeground : Color.foreground'
  if [[ -f $button ]] && grep -qxF "$anchor" "$button"; then
    awk -v anchor="$anchor" '
      $0 == anchor {
        print "  // Quattro standalone: the owning widget'"'"'s shell.json entry may set \"color\"."
        print "  readonly property var colorHost: {"
        print "    var p = root.parent"
        print "    for (var i = 0; p && i < 12; i++) {"
        print "      if (p.moduleName !== undefined && p.settings !== undefined) return p"
        print "      p = p.parent"
        print "    }"
        print "    return null"
        print "  }"
        print "  readonly property string settingColor: colorHost && colorHost.settings && colorHost.settings.color ? String(colorHost.settings.color) : \"\""
        print "  property color foreground: settingColor !== \"\" ? settingColor : (bar ? bar.barForeground : Color.foreground)"
        next
      }
      { print }
    ' "$button" > "$button.tmp" && mv "$button.tmp" "$button"
  else
    warn "WidgetButton.qml changed upstream; per-widget bar colors are not available in this build."
  fi

  if [[ -f $workspaces ]] && grep -q '^        bar: root.bar$' "$workspaces"; then
    awk '
      !done && $0 == "        bar: root.bar" {
        print
        print "        foreground: focused && root.setting(\"activeColor\", \"\") !== \"\" ? root.setting(\"activeColor\", \"\")"
        print "          : (!occupied && root.setting(\"emptyColor\", \"\") !== \"\" ? root.setting(\"emptyColor\", \"\")"
        print "          : (root.setting(\"color\", \"\") !== \"\" ? root.setting(\"color\", \"\") : (root.bar ? root.bar.barForeground : Color.foreground)))"
        done = 1
        next
      }
      { print }
    ' "$workspaces" > "$workspaces.tmp" && mv "$workspaces.tmp" "$workspaces"
  else
    warn "Workspaces.qml changed upstream; workspace colors fall back to the theme."
  fi
}

add_quattro_extras() {
  # The CachyOS-inspired additions, in Omarchy's own style:
  #   - omarchy.launcher        app launcher with category tabs (Super+Space)
  #   - omarchy.control-center  quick toggles / media / clock (bar button)
  # Omarchy 3 had Super+Space = apps and Super+Alt+Space = Omarchy menu;
  # Quattro flipped them, this flips them back.
  log "Adding the category launcher and control center"
  local T="$STAGE_ROOT"
  if (( DRY_RUN )); then
    echo "+ (write shell/plugins/launcher + shell/plugins/control-center, rebind Super+Space, Arch logo on the menu button)"
    return 0
  fi

  write_launcher_plugin "$T/shell/plugins/launcher"
  write_control_center_plugin "$T/shell/plugins/control-center"

  local util="$T/default/hypr/bindings/utilities.lua"
  local old_menu='o.bind("SUPER + SPACE", "Omarchy menu", { menu = "root" })'
  local old_apps='o.bind("SUPER + ALT + SPACE", "Apps menu", { menu = "apps" })'
  if [[ -f $util ]] && grep -qxF "$old_menu" "$util" && grep -qxF "$old_apps" "$util"; then
    awk -v m="$old_menu" -v a="$old_apps" '
      $0 == m { print "o.bind(\"SUPER + SPACE\", \"App launcher\", { panel = \"omarchy.launcher\" })"; next }
      $0 == a { print "o.bind(\"SUPER + ALT + SPACE\", \"Omarchy menu\", { menu = \"root\" })"; next }
      { print }
    ' "$util" > "$util.tmp" && mv "$util.tmp" "$util"
  else
    warn "Launcher keybinds changed upstream; open the launcher with: omarchy-shell shell toggle omarchy.launcher"
  fi

  # Menu button: Arch logo instead of Omarchy's (your Omarchy 3 bar had this too).
  local menu_button="$T/shell/plugins/menu/BarWidget.qml"
  if [[ -f $menu_button ]]; then
    sed -i -e 's|text: "\\ue900"|text: "\\uf303"|' -e '/^[[:space:]]*fontFamily: "omarchy"$/d' "$menu_button"
  fi

  # Default bar: control center button at the far right.
  local shell_json="$T/config/omarchy/shell.json" tmp
  if [[ -f $shell_json ]]; then
    tmp="$(mktemp)"
    if jq '(.bar.layout.right // []) as $r
           | if any($r[]?; (type == "object" and .id == "omarchy.control-center"))
             then . else .bar.layout.right = ($r + [{"id": "omarchy.control-center"}]) end' \
         "$shell_json" > "$tmp"; then
      install -m 0644 "$tmp" "$shell_json"
    fi
    rm -f "$tmp"
  fi
}

add_boot_theming() {
  # Boot menu (Limine) + boot splash (Plymouth) in the active theme, with an
  # Arch logo instead of Omarchy's. Every theme's unlock art and picker preview
  # is re-rendered, so Style > Unlock, the SDDM login logo and "reset" all use
  # it with no other changes.
  log "Adding themed boot menu + splash (Arch logo art for every theme)"
  local T="$STAGE_ROOT"
  if (( DRY_RUN )); then
    echo "+ (write omarchy-boot-art / omarchy-boot-theme / omarchy-limine-apply, render art for each theme)"
    return 0
  fi
  mkdir -p "$T/bin" "$T/etc/sudoers.d" "$T/default/omarchy"
  cat > "$T/bin/omarchy-boot-art" <<'QUATTRO_BOOT_ART'
#!/bin/bash
# Render Arch-branded boot art in the active theme's colours.
#   render-boot-art unlock  <out.png> <accent> <text>          glow logo + wordmark (Plymouth)
#   render-boot-art preview <out.png> <bg> <text> <unlock.png>   1920x1080 splash preview (picker thumbnail)
#   render-boot-art limine  <out.jpg> <bg> <accent> <text> [wallpaper]  1920x1080 boot menu background
# Colours are RRGGBB (with or without #). Needs ImageMagick and a Nerd Font
# (for the Arch logo glyph, U+F303).
set -euo pipefail
export LC_ALL=C.UTF-8   # printf '\uXXXX' needs a UTF-8 locale (boot hooks may run with C)

IM=magick; command -v magick >/dev/null 2>&1 || IM=convert

hex() { local v="${1#\#}"; [[ $v =~ ^[0-9a-fA-F]{6}$ ]] || { echo "bad colour: $1" >&2; exit 2; }; echo "#$v"; }

font_for() {
  local f
  for pat in "$@"; do
    f=$(fc-match -f '%{file}' "$pat" 2>/dev/null || true)
    [[ -n $f && -f $f ]] && { echo "$f"; return; }
  done
  echo ""
}
GLYPH_FONT=$(font_for "Symbols Nerd Font" "JetBrainsMono Nerd Font" "JetBrainsMonoNL Nerd Font")
WORD_FONT=$(font_for "JetBrainsMono Nerd Font:style=Bold" "JetBrains Mono:style=Bold" "DejaVu Sans:style=Bold")
[[ -n $GLYPH_FONT ]] || { echo "No Nerd Font found for the Arch logo." >&2; exit 3; }
# Wordmark under the logo: $BOOT_WORDMARK, else the installed brand name, lowercased.
WORD=${BOOT_WORDMARK:-}
if [[ -z $WORD && -r ${OMARCHY_PATH:-/usr/share/omarchy}/default/omarchy/brand ]]; then
  WORD=$(head -c 40 "${OMARCHY_PATH:-/usr/share/omarchy}/default/omarchy/brand" | tr -cd 'A-Za-z0-9 ._+-')
fi
WORD=${WORD:-arch linux}; WORD=${WORD,,}
LOGO=$(printf '')

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Logo + wordmark on transparent canvas, with a soft glow in the accent colour.
logo_layer() {  # <out> <accent> <text> <glyph_px> <word_px>
  local out=$1 accent=$2 text=$3 gpx=$4 wpx=$5
  $IM -background none -fill "$accent" -font "$GLYPH_FONT" -pointsize "$gpx" label:"$LOGO" -trim +repage "$tmp/g.png"
  $IM -background none -fill "$text" -font "$WORD_FONT" -pointsize "$wpx" -kerning 2 label:"$WORD" -trim +repage "$tmp/w.png"
  local gh; gh=$($IM identify -format '%h' "$tmp/g.png" 2>/dev/null || identify -format '%h' "$tmp/g.png")
  $IM "$tmp/g.png" \( -size $((gpx / 4))x"$gh" xc:none \) "$tmp/w.png" -background none -gravity center +append "$tmp/sharp.png"
  # glow: blurred accent silhouette under the sharp art
  $IM "$tmp/sharp.png" -bordercolor none -border "$gpx" "$tmp/sharp_b.png"
  # glow = the art's alpha, blurred, filled with the accent (no colour bleed from transparent pixels)
  $IM "$tmp/sharp_b.png" -alpha extract -blur 0x$((gpx / 7)) -evaluate multiply 0.85 \
    \( +clone -fill "$accent" -colorize 100 \) +swap -compose copy-opacity -composite "$tmp/glow.png"
  $IM "$tmp/glow.png" -channel A -level 2%,100% +channel "$tmp/glow2.png"
  $IM "$tmp/glow2.png" "$tmp/sharp_b.png" -compose over -composite -depth 8 "$out"
}

case "${1:-}" in
  unlock)
    out=$2; accent=$(hex "$3"); text=$(hex "$4")
    logo_layer "$tmp/art.png" "$accent" "$text" 300 150
    $IM "$tmp/art.png" -resize '1108x523>' -background none -gravity center -extent 1108x523 "$out"
    ;;
  preview)
    out=$2; bg=$(hex "$3"); text=$(hex "$4"); art=$5
    $IM -background none -fill "$text" -font "$GLYPH_FONT" -pointsize 40 label:"$(printf '\uf023')" -trim +repage "$tmp/lock.png"
    $IM -size 1920x1080 xc:"$bg" "$art" -gravity center -geometry +0-40 -compose over -composite \
      -fill none -stroke "$text" -strokewidth 3 -draw "roundrectangle 818,842 1102,888 6,6" \
      -stroke none -fill "$text" \
      -draw "circle 840,865 845,865" -draw "circle 858,865 863,865" -draw "circle 876,865 881,865" -draw "circle 894,865 899,865" \
      "$tmp/lock.png" -gravity northwest -geometry +770+846 -compose over -composite \
      -depth 8 "$out"
    ;;
  limine)
    out=$2; bg=$(hex "$3"); accent=$(hex "$4"); text=$(hex "$5"); wall=${6:-}
    if [[ -n $wall && -f $wall ]]; then
      # theme wallpaper: cover-crop, soft blur, darkened so the menu stays readable
      $IM "${wall}[0]" -resize '1920x1080^' -gravity center -extent 1920x1080 -blur 0x12 \
        \( -size 1920x1080 xc:"$bg" \) -compose blend -define compose:args=55 -composite "$tmp/base.png"
    else
      $IM -size 1920x1080 radial-gradient:"$accent"-"$bg" -fill "$bg" -colorize 88 "$tmp/base.png"
    fi
    logo_layer "$tmp/logo.png" "$accent" "$text" 120 60
    $IM "$tmp/base.png" "$tmp/logo.png" -gravity north -geometry +0+70 -compose over -composite \
      -quality 88 -strip "$out"
    ;;
  *) echo "usage: render-boot-art unlock|preview|limine ..." >&2; exit 1 ;;
esac
QUATTRO_BOOT_ART
  cat > "$T/bin/omarchy-boot-theme" <<'QUATTRO_BOOT_THEME'
#!/bin/bash

# omarchy:summary=Style the boot menu (Limine) and boot splash (Plymouth) after the current theme
# omarchy:args=[--limine] [--plymouth] [--quiet]
# omarchy:examples=omarchy boot theme | omarchy-boot-theme --limine --quiet

set -uo pipefail
export LC_ALL=C.UTF-8

do_limine=0 do_plymouth=0 quiet=0
for arg in "$@"; do
  case "$arg" in
    --limine) do_limine=1 ;;
    --plymouth) do_plymouth=1 ;;
    --quiet|-q) quiet=1 ;;
    *) echo "Usage: omarchy-boot-theme [--limine] [--plymouth] [--quiet]" >&2; exit 1 ;;
  esac
done
(( do_limine || do_plymouth )) || { do_limine=1; do_plymouth=1; }

say() { (( quiet )) || echo "$@"; }

theme="$HOME/.local/state/omarchy/current/theme"
colors="$theme/colors.toml"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/boot"
mkdir -p "$cache"

# color <key> [fallback keys...] -> RRGGBB (no #)
color() {
  local key v
  for key in "$@"; do
    v=$(awk -F= -v k="$key" '
      { f=$1; gsub(/^[ \t]+|[ \t]+$/, "", f) }
      f == k { v=$2; gsub(/^[ \t"]+|[ \t"]+$/, "", v); sub(/^#/, "", v); print v; exit }' "$colors" 2>/dev/null)
    [[ $v =~ ^[0-9a-fA-F]{6}$ ]] && { echo "${v,,}"; return; }
  done
  echo ""
}

[[ -f $colors ]] || { echo "No current theme found ($colors)." >&2; exit 1; }
bg=$(color background); fg=$(color foreground); accent=$(color accent blue foreground)
[[ -n $bg && -n $fg && -n $accent ]] || { echo "Theme is missing background/foreground/accent colours." >&2; exit 1; }

brand="Arch Linux"
[[ -r ${OMARCHY_PATH:-/usr/share/omarchy}/default/omarchy/brand ]] &&
  brand=$(head -c 40 "${OMARCHY_PATH:-/usr/share/omarchy}/default/omarchy/brand" | tr -cd 'A-Za-z0-9 ._+-')

status=0

if (( do_limine )); then
  if ! pacman -Qq limine >/dev/null 2>&1; then
    say "Limine isn't installed; skipping the boot menu."
  else
    wall=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)
    case "${wall,,}" in *.jpg|*.jpeg|*.png|*.webp) ;; *) wall="" ;; esac
    if omarchy-boot-art limine "$cache/limine.jpg.new" "$bg" "$accent" "$fg" ${wall:+"$wall"} 2>"$cache/render.log"; then
      mv -f "$cache/limine.jpg.new" "$cache/limine.jpg"
      p() { echo "$(color "$@")"; }
      {
        echo "interface_branding: $brand"
        echo "interface_branding_colour: $accent"
        echo "interface_help_colour: $(p dark_foreground foreground)"
        echo "interface_help_colour_bright: $accent"
        echo "term_palette: $(p darker_background dark_background background);$(p red);$(p green);$(p yellow);$(p blue);$(p magenta);$(p cyan);$fg"
        echo "term_palette_bright: $(p muted dark_foreground);$(p bright_red red);$(p bright_green green);$(p bright_yellow yellow);$(p bright_blue blue);$(p bright_magenta magenta);$(p bright_cyan cyan);$(p bright_foreground foreground)"
        echo "term_foreground: $fg"
        echo "term_foreground_bright: $(p bright_foreground foreground)"
        echo "term_background: 40$bg"
        echo "term_background_bright: $(p lighter_background background)"
        echo "backdrop: $bg"
      } > "$cache/limine-theme.conf"
      if sudo -n /usr/bin/omarchy-limine-apply 2>"$cache/apply.log" || { [[ -t 0 ]] && (( ! quiet )) && sudo /usr/bin/omarchy-limine-apply; }; then
        say "Boot menu (Limine) styled."
      else
        echo "Couldn't apply the Limine theme: $(tail -n1 "$cache/apply.log" 2>/dev/null)" >&2
        status=1
      fi
    else
      echo "Couldn't render the boot menu art: $(tail -n1 "$cache/render.log")" >&2
      status=1
    fi
  fi
fi

if (( do_plymouth )); then
  art="$theme/unlock.png"
  if [[ ! -f $art ]] || ! cmp -s <(head -c 4 "$art" | od -An -tx1) <(printf ' 89 50 4e 47\n'); then
    art="$cache/unlock.png"
    omarchy-boot-art unlock "$art" "$accent" "$fg" || { echo "Couldn't render the splash art." >&2; exit 1; }
  fi
  say "Styling the boot splash (Plymouth) -- this rebuilds the initramfs and asks for your password..."
  omarchy-plymouth-set "#$bg" "#$fg" "$art" || status=1
fi

exit $status
QUATTRO_BOOT_THEME
  cat > "$T/bin/omarchy-limine-apply" <<'QUATTRO_LIMINE_APPLY'
#!/bin/bash

# omarchy:summary=Apply the rendered boot menu theme to limine.conf (root helper for omarchy-boot-theme)
# omarchy:requires-sudo=true
# omarchy:hidden=true
#
# Runs as root via a NOPASSWD sudoers rule, takes no arguments, and only
# reads two files the invoking user rendered into their cache:
#   ~/.cache/omarchy/boot/limine.jpg          (validated JPEG, < 8 MiB)
#   ~/.cache/omarchy/boot/limine-theme.conf   (validated key: value lines)
# It edits only the global section of each limine.conf, inside a marked
# block, keeps a backup, and refuses to touch a config whose checksum is
# enrolled into the Limine EFI binary (editing that would stop booting).

set -euo pipefail
export PATH=/usr/bin:/bin LC_ALL=C

fail() { echo "omarchy-limine-apply: $*" >&2; exit 1; }
(( EUID == 0 )) || fail "must run as root (via sudo)"
(( $# == 0 )) || fail "takes no arguments"

user=${SUDO_USER:-}
[[ $user =~ ^[a-z_][a-z0-9_-]*$ && $user != root ]] || fail "run through sudo as your user"
uid=$(id -u "$user") || fail "unknown user"
home=$(getent passwd "$user" | cut -d: -f6)
src="$home/.cache/omarchy/boot"

check_user_file() {
  local f=$1 max=$2
  [[ -f $f && ! -L $f ]] || fail "missing $f"
  [[ $(stat -c %u -- "$f") == "$uid" ]] || fail "$f is not owned by $user"
  (( $(stat -c %s -- "$f") > 0 && $(stat -c %s -- "$f") < max )) || fail "$f has an unexpected size"
}
check_user_file "$src/limine.jpg" $((8 * 1024 * 1024))
check_user_file "$src/limine-theme.conf" 4096
[[ $(head -c 3 "$src/limine.jpg" | od -An -tx1 | tr -d ' \n') == ffd8ff ]] || fail "limine.jpg is not a JPEG"

# Whitelisted keys only, values must be colours or a short plain name.
theme_lines=()
while IFS= read -r line; do
  [[ -z $line ]] && continue
  key=${line%%:*}; val=${line#*: }
  case "$key" in
    interface_branding)
      [[ $val =~ ^[A-Za-z0-9\ ._+-]{1,40}$ ]] || fail "bad branding" ;;
    interface_branding_colour|interface_help_colour|interface_help_colour_bright|term_foreground|term_foreground_bright|term_background_bright|backdrop)
      [[ $val =~ ^[0-9a-f]{6}$ ]] || fail "bad colour for $key" ;;
    term_background)
      [[ $val =~ ^[0-9a-f]{8}$ ]] || fail "bad colour for $key" ;;
    term_palette|term_palette_bright)
      [[ $val =~ ^([0-9a-f]{6};){7}[0-9a-f]{6}$ ]] || fail "bad palette for $key" ;;
    *) fail "unexpected key $key" ;;
  esac
  theme_lines+=("$key: $val")
done < "$src/limine-theme.conf"

# Refuse if any Limine EFI binary on an ESP has an enrolled config checksum.
for esp in /boot /efi /boot/efi; do
  [[ -d $esp/EFI ]] || continue
  while IFS= read -r -d '' efi; do
    sum=$(grep -aoE '\+\+CONFIG_B2SUM_SIGNATURE\+\+[0-9a-fA-F]{128}' "$efi" 2>/dev/null | head -1 | sed 's/.*++//')
    if [[ -n $sum && $sum =~ [1-9a-fA-F] ]]; then
      fail "$efi has an enrolled config checksum (Secure Boot setup); not editing limine.conf"
    fi
  done < <(find "$esp/EFI" -maxdepth 3 -type f -iname '*.efi' -print0 2>/dev/null)
done

# Config locations Limine searches (relative to the partition), for each
# place an ESP / boot partition is commonly mounted.
configs=()
for mnt in /boot /efi /boot/efi; do
  mountpoint -q "$mnt" 2>/dev/null || [[ $mnt == /boot && -d /boot ]] || continue
  for rel in EFI/limine/limine.conf EFI/BOOT/limine.conf boot/limine/limine.conf boot/limine.conf limine/limine.conf limine.conf; do
    f="$mnt/$rel"
    [[ -f $f && ! -L $f ]] || continue
    real=$(realpath -e -- "$f")
    [[ " ${configs[*]} " == *" $real "* ]] || configs+=("$real")
  done
done
(( ${#configs[@]} > 0 )) || fail "no limine.conf found under /boot, /efi or /boot/efi"

limine_major=$(pacman -Q limine 2>/dev/null | awk '{print $2}' | cut -d. -f1 | tr -cd '0-9')

for conf in "${configs[@]}"; do
  dir=${conf%/*}
  part=$(findmnt -n -o TARGET -T "$dir")
  relpath=${dir#"$part"}; relpath=${relpath#/}
  install -m 0644 -o 0 -g 0 -- "$src/limine.jpg" "$dir/theme-wallpaper.jpg"
  wpath="${relpath:+$relpath/}theme-wallpaper.jpg"
  if [[ -n $limine_major ]] && (( limine_major < 8 )); then
    wall="boot:///$wpath"
  else
    wall="boot():/$wpath"
  fi

  [[ -f $conf.pre-theme ]] || cp -a -- "$conf" "$conf.pre-theme"
  cp -a -- "$conf" "$conf.bak"

  tmp=$(mktemp)
  {
    echo "# >>> theme (managed by omarchy-boot-theme; original saved as ${conf##*/}.pre-theme)"
    echo "wallpaper: $wall"
    echo "wallpaper_style: stretched"
    printf '%s\n' "${theme_lines[@]}"
    echo "# <<< theme"
    # Drop any previous managed block; in the global section (before the
    # first entry line starting with "/"), comment out keys the block sets.
    awk '
      BEGIN {
        n = split("wallpaper wallpaper_style backdrop interface_branding interface_branding_colour interface_branding_color interface_help_colour interface_help_color interface_help_colour_bright interface_help_color_bright term_palette term_palette_bright term_foreground term_foreground_bright term_background term_background_bright", k, " ")
        for (i = 1; i <= n; i++) managed[k[i]] = 1
      }
      /^# >>> theme/ { skip = 1; next }
      skip && /^# <<< theme/ { skip = 0; next }
      skip { next }
      /^[ \t]*\// { entries = 1 }
      !entries && /^[ \t]*[A-Za-z_]+[ \t]*:/ {
        key = tolower($0); sub(/^[ \t]*/, "", key); sub(/[ \t]*:.*/, "", key)
        if (key in managed) { print "#theme-off# " $0; next }
      }
      { print }
    ' "$conf"
  } > "$tmp"
  cat "$tmp" > "$conf"
  rm -f "$tmp"
  echo "Styled $conf"
done
QUATTRO_LIMINE_APPLY
  cat > "$T/etc/sudoers.d/omarchy-limine-theme" <<'QUATTRO_LIMINE_SUDOERS'
# Lets omarchy-boot-theme restyle the Limine boot menu on theme switch
# without a password. The helper takes no arguments and only applies
# validated colours and a validated JPEG from the invoking user's cache.
%wheel ALL=(root) NOPASSWD: /usr/bin/omarchy-limine-apply
QUATTRO_LIMINE_SUDOERS
  chmod 0755 "$T/bin/omarchy-boot-art" "$T/bin/omarchy-boot-theme" "$T/bin/omarchy-limine-apply"
  if [[ $BRAND == Arch ]]; then echo "Arch Linux"; else echo "$BRAND"; fi > "$T/default/omarchy/brand"
  export BOOT_WORDMARK; BOOT_WORDMARK="$(cat "$T/default/omarchy/brand")"

  # Style menu: one entry to restyle both boot screens from the current theme.
  local menu="$T/default/omarchy/omarchy-menu.jsonc"
  if [[ -f $menu ]] && ! grep -q '"style.boot"' "$menu"; then
    sed -i '/"style.unlock":/a\  "style.boot": {"icon":"󰒲","label":"Boot screens","aliases":["boot","limine","plymouth"],"action":"omarchy-launch-floating-terminal-with-presentation omarchy-boot-theme"},' "$menu"
  fi

  # Render the art (needs ImageMagick + the Nerd Font installed earlier).
  local art="$T/bin/omarchy-boot-art" jobs
  jobs=$(nproc 2>/dev/null || echo 2)
  if ! "$art" unlock "$STAGE_DIR/probe.png" 7aa2f7 a9b1d6 >/dev/null 2>&1; then
    warn "Couldn't render boot art (ImageMagick or Nerd Font missing); keeping Omarchy's splash art."
    return 0
  fi
  render_theme() {
    local dir=$1 c bg fg accent
    c="$dir/colors.toml"
    get() { awk -F= -v k="$1" '{f=$1; gsub(/^[ \t]+|[ \t]+$/,"",f)} f==k {v=$2; gsub(/^[ \t"]+|[ \t"]+$/,"",v); sub(/^#/,"",v); print v; exit}' "$c"; }
    bg=$(get background); fg=$(get foreground); accent=$(get accent)
    [[ -n $bg && -n $fg && -n $accent ]] || return 0
    "$art" unlock "$dir/unlock.png" "$accent" "$fg" && "$art" preview "$dir/preview-unlock.png" "$bg" "$fg" "$dir/unlock.png"
  }
  export -f render_theme; export art
  find "$T/themes" -mindepth 1 -maxdepth 1 -type d -print0 |
    xargs -0 -r -P "$jobs" -I{} bash -c 'render_theme "$1" || echo "  (art failed for ${1##*/})" >&2' _ {}
  # Default splash (Style > Unlock > default, and omarchy-plymouth-reset): Tokyo Night colours.
  "$art" unlock "$T/default/plymouth/logo.png" 7aa2f7 a9b1d6 &&
    "$art" preview "$T/default/plymouth/preview-unlock.png" 1a1b26 a9b1d6 "$T/default/plymouth/logo.png" || true
  if [[ -f $T/default/plymouth/logos/oma.png ]]; then cp -f "$T/default/plymouth/logo.png" "$T/default/plymouth/logos/oma.png"; fi
  return 0
}

rebrand_tree() {
  # Shown text says "$BRAND" instead of "Omarchy": menu entries, keybind
  # descriptions, command output, notifications, tooltips, window titles.
  # Whole-word only, and applied to the whole runtime at once, so things
  # that match on that text (window rules, the keybindings list) stay in
  # step. Command names (omarchy-*), paths and internal IDs are lowercase or
  # embedded in identifiers and are not touched.
  [[ $BRAND == "Omarchy" ]] && return 0
  log "Naming: showing \"$BRAND\" instead of \"Omarchy\""
  (( DRY_RUN )) && return 0
  local esc
  esc="$(printf '%s' "$BRAND" | sed 's/[\/&|]/\\&/g')"
  find "$STAGE_ROOT/bin" "$STAGE_ROOT/shell" "$STAGE_ROOT/default/hypr" "$STAGE_ROOT/default/omarchy" \
       "$STAGE_ROOT/etc/fastfetch" -type f \
       \( -path "$STAGE_ROOT/bin/*" -o -name '*.qml' -o -name '*.js' -o -name '*.lua' -o -name '*.jsonc' -o -name '*.json' \) \
       -print0 2>/dev/null |
    xargs -0 -r grep -lIZ 'Omarchy' 2>/dev/null |
    xargs -0 -r perl -pi -e "s/\\bOmarchy\\b/$esc/g"
}

migrate_old_layout() {
  # Earlier versions of this script installed to /usr/local/share/omarchy-quattro
  # with symlinks in /usr/local/bin. Those links come first on PATH and would
  # shadow the packaged /usr/bin commands, and the user environment.d file
  # pinned OMARCHY_PATH to the old tree.
  [[ -e $OLD_INSTALL_ROOT || -e $OLD_ENV_FILE || -e $USER_ENV_FILE ]] || return 0
  log "Removing the old /usr/local layout from earlier runs"

  if [[ -d $BIN_DIR ]]; then
    run sudo find "$BIN_DIR" -maxdepth 1 -type l -lname "$OLD_INSTALL_ROOT/*" -delete
  fi
  run sudo rm -rf -- "$OLD_INSTALL_ROOT"
  run sudo rm -f -- "$OLD_ENV_FILE"
  run rm -f -- "$USER_ENV_FILE"
}

build_runtime_package() {
  # Packages the staged tree with the same layout as the official omarchy +
  # omarchy-settings packages: commands in /usr/bin, root-owned runtime in
  # /usr/share/omarchy (whose bin/ links back to /usr/bin), themes for SDDM and
  # Plymouth, the session file, and the /etc drop-ins the menus rely on
  # (passwordless DNS/theme sudo rules, resolved, ...).
  #
  # Deliberately NOT shipped from upstream etc/: mkinitcpio HOOKS (would
  # replace yours with encrypt + btrfs-overlayfs and can leave the system
  # unbootable), Limine/Snapper config, nsswitch/faillock/cups overrides,
  # Docker, zswap/oomd tuning, USB autosuspend and power-button changes.
  log "Building and installing the $PKG_NAME package"

  if (( DRY_RUN )); then
    echo "+ (makepkg a package from the staged tree, then sudo pacman -U it)"
    return 0
  fi

  local ver build pkgfile
  ver="$(tr -d '[:space:]' < "$STAGE_ROOT/version" 2>/dev/null || true)"
  ver="$(printf '%s' "${ver:-0}" | sed 's/[^A-Za-z0-9._]/./g')"
  build="$STAGE_DIR/pkgbuild"
  mkdir -p "$build"

  cat > "$build/PKGBUILD" <<EOF
pkgname=$PKG_NAME
pkgver=$ver
pkgrel=$(date +%Y%m%d%H%M)
pkgdesc='Omarchy Quattro desktop layer for plain Arch (no AI, web apps or provisioning)'
arch=(any)
url='https://github.com/omacom/omarchy'
license=(MIT)
provides=("omarchy=$ver" "omarchy-settings=$ver")
conflicts=(omarchy omarchy-settings omarchy-dev omarchy-settings-dev)
options=(!strip !debug)
_stage='$STAGE_ROOT'
EOF

  cat >> "$build/PKGBUILD" <<'EOF'

package() {
  local s=$_stage d=$pkgdir f name

  # optional source -> dest, mode; skips files a future revision dropped
  _put() { [[ -f $s/$1 ]] || return 0; install -Dm"$3" "$s/$1" "$d/$2"; }

  # Commands: real files in /usr/bin, links in /usr/share/omarchy/bin.
  install -d "$d/usr/bin" "$d/usr/share/omarchy/bin"
  for f in "$s"/bin/*; do
    [[ -f $f ]] || continue
    name=${f##*/}
    install -m755 "$f" "$d/usr/bin/$name"
    ln -s "/usr/bin/$name" "$d/usr/share/omarchy/bin/$name"
  done

  # The rest of the runtime tree.
  for f in "$s"/*; do
    [[ -e $f ]] || continue
    name=${f##*/}
    [[ $name == bin ]] && continue
    cp -a "$f" "$d/usr/share/omarchy/"
  done
  find "$d/usr/share/omarchy" -type d -exec chmod 755 {} +
  find "$d/usr/share/omarchy" -type f -exec chmod go-w {} +

  # Session environment (sets OMARCHY_PATH=/usr/share/omarchy for uwsm + shells).
  _put default/uwsm/env.d/10-omarchy usr/share/uwsm/env.d/10-omarchy 644
  _put etc/profile.d/omarchy.sh etc/profile.d/omarchy.sh 644
  _put default/environment.d/10-omarchy-fcitx.conf usr/lib/environment.d/10-omarchy-fcitx.conf 644
  _put default/xdg-terminal-exec/hyprland-xdg-terminals.list usr/share/xdg-terminal-exec/hyprland-xdg-terminals.list 644
  _put default/wayland-sessions/omarchy.desktop usr/share/wayland-sessions/omarchy.desktop 644
  _put default/systemd/system-sleep/unmount-fuse usr/lib/systemd/system-sleep/unmount-fuse 755

  # Fonts (the menu's "omarchy" icon font) and fontconfig defaults.
  _put default/fonts/omarchy/omarchy.ttf usr/share/fonts/omarchy/omarchy.ttf 644
  if [[ -f $s/default/fontconfig/conf.avail/50-omarchy.conf ]]; then
    _put default/fontconfig/conf.avail/50-omarchy.conf usr/share/fontconfig/conf.avail/50-omarchy.conf 644
    install -d "$d/etc/fonts/conf.d"
    ln -s /usr/share/fontconfig/conf.avail/50-omarchy.conf "$d/etc/fonts/conf.d/50-omarchy.conf"
  fi

  # SDDM and Plymouth themes.
  if [[ -d $s/default/sddm/omarchy ]]; then
    install -d "$d/usr/share/sddm/themes"
    cp -a "$s/default/sddm/omarchy" "$d/usr/share/sddm/themes/"
    find "$d/usr/share/sddm/themes/omarchy" -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
  fi
  _put default/sddm/hyprland.lua usr/share/sddm/hyprland.lua 644
  if [[ -d $s/default/plymouth ]]; then
    install -d "$d/usr/share/plymouth/themes/omarchy"
    cp -a "$s/default/plymouth/." "$d/usr/share/plymouth/themes/omarchy/"
    find "$d/usr/share/plymouth/themes/omarchy" -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
  fi

  # Safe /etc drop-ins.
  for f in \
    systemd/resolved.conf.d/10-disable-multicast.conf \
    NetworkManager/conf.d/omarchy-wifi-powersave.conf \
    sysctl.d/90-omarchy-file-watchers.conf \
    systemd/system.conf.d/10-faster-shutdown.conf \
    systemd/system.conf.d/20-omarchy-nofile.conf \
    systemd/user.conf.d/20-omarchy-nofile.conf \
    systemd/system/user@.service.d/10-faster-shutdown.conf \
    systemd/logind.conf.d/20-inhibit-delay.conf \
    tmpfiles.d/omarchy-nopasswd-sudo.conf \
    fastfetch/config.jsonc; do
    _put "etc/$f" "etc/$f" 644
  done

  # sudoers rules the menus depend on: one-click DNS switching, browser
  # theming, timezone, and the passwordless-sudo helper's retry count.
  for f in omarchy-dns omarchy-theme-browser omarchy-tzupdate omarchy-passwd-tries omarchy-limine-theme; do
    _put "etc/sudoers.d/$f" "etc/sudoers.d/$f" 440
  done
  [[ -d $d/etc/sudoers.d ]] && chmod 750 "$d/etc/sudoers.d"
  return 0
}
EOF

  (cd "$build" && makepkg -f --noconfirm >/dev/null) ||
    die "Building the $PKG_NAME package failed (see makepkg output above)."
  pkgfile="$(cd "$build" && makepkg --packagelist | head -1)"
  [[ -f "$pkgfile" ]] || die "makepkg did not produce $pkgfile"

  # Older runs of this script copied the SDDM/Plymouth themes in unowned.
  run sudo pacman -U --noconfirm \
    --overwrite '/usr/share/sddm/themes/omarchy/*' \
    --overwrite '/usr/share/sddm/hyprland.lua' \
    --overwrite '/usr/share/plymouth/themes/omarchy/*' \
    "$pkgfile"

  # Validate the sudoers drop-ins we just installed; a broken one would lock
  # sudo for everyone, so remove any that fail rather than leave them.
  local rule
  for rule in /etc/sudoers.d/omarchy-*; do
    [[ -f $rule ]] || continue
    if ! sudo visudo -cqf "$rule"; then
      warn "sudoers rule $rule failed validation; removing it."
      sudo rm -f -- "$rule"
    fi
  done
}

configure_auth() {
  # Ports the auth bits of Omarchy's installer that the runtime depends on.
  log "Configuring lock screen authentication (PAM) and login lockout"

  # The Quickshell lock screen authenticates through
  # /etc/pam.d/omarchy-lock-password, which full Omarchy writes at install time
  # (install/config/lockscreen-pam.sh -> omarchy-apply-lock). Without it PAM
  # falls back to "other" (deny all) and the correct password is rejected.
  if [[ -x /usr/bin/omarchy-apply-lock ]] || (( DRY_RUN )); then
    run sudo env OMARCHY_INSTALL_USER="$USER" /usr/bin/omarchy-apply-lock
  else
    warn "omarchy-apply-lock missing; the lock screen will reject every password."
  fi

  # Arch's faillock default locks an account for 10 minutes after 3 failed
  # attempts, after which even the right password fails. Omarchy uses 10
  # attempts / 2 minutes (install/config/increase-lockout-limit.sh).
  if grep -q 'pam_faillock.so' /etc/pam.d/system-auth 2>/dev/null; then
    run sudo sed -i \
      -e 's|^\(auth\s\+required\s\+pam_faillock.so\)\s\+preauth.*$|\1 preauth silent deny=10 unlock_time=120|' \
      -e 's|^\(auth\s\+\[default=die\]\s\+pam_faillock.so\)\s\+authfail.*$|\1 authfail deny=10 unlock_time=120|' \
      /etc/pam.d/system-auth
  fi
  # Clear any lockout left by failed attempts before this fix.
  run sudo faillock --user "$USER" --reset || true

  # Admin prompts (polkit dialog, Omarchy's NOPASSWD rules) are wheel-based.
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx wheel; then
    warn "$USER is not in the 'wheel' group. Password dialogs from the desktop will ask for an"
    warn "administrator's password, and Omarchy's one-click DNS/theme rules won't apply. Fix with:"
    warn "  sudo usermod -aG wheel $USER   (then log out and back in)"
  fi

  # Remaining small system fixes from Omarchy's installer.
  if [[ -f /usr/bin/powerprofilesctl ]]; then
    # mise's python can shadow the system one that has the dbus bindings.
    run sudo sed -i '1s|^#!/usr/bin/env python3$|#!/usr/bin/python3|' /usr/bin/powerprofilesctl
  fi
  if [[ -d /usr/share/icons/Yaru ]]; then
    run sudo mkdir -p /usr/share/icons/Yaru/scalable/actions
    run sudo ln -snf /usr/share/icons/Adwaita/symbolic/actions/go-previous-symbolic.svg \
      /usr/share/icons/Yaru/scalable/actions/go-previous-symbolic.svg
    run sudo ln -snf /usr/share/icons/Adwaita/symbolic/actions/go-next-symbolic.svg \
      /usr/share/icons/Yaru/scalable/actions/go-next-symbolic.svg
  fi
}

install_user_configs() {
  log "Installing Quattro user configuration"

  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  run mkdir -p "$cfg"

  # xdg-terminal-exec reads this preference list for Hyprland's terminal bindings.
  if [[ -f "$INSTALL_ROOT/default/xdg-terminal-exec/hyprland-xdg-terminals.list" ]]; then
    run mkdir -p "$cfg/xdg-terminal-exec"
    backup_existing "$cfg/xdg-terminal-exec/hyprland-xdg-terminals.list"
    run cp -f "$INSTALL_ROOT/default/xdg-terminal-exec/hyprland-xdg-terminals.list" \
      "$cfg/xdg-terminal-exec/hyprland-xdg-terminals.list"
    run sudo mkdir -p /etc/xdg/xdg-terminal-exec
    run sudo install -m 0644 "$INSTALL_ROOT/default/xdg-terminal-exec/hyprland-xdg-terminals.list" \
      /etc/xdg/xdg-terminal-exec/hyprland-xdg-terminals.list
  fi

  local dirs=(
    alacritty
    autostart
    btop
    fcitx5
    foot
    ghostty
    hypr
    hyprland-preview-share-picker
    imv
    kitty
    lazygit
    omarchy
    starship.toml
    tmux
    wireplumber
  )

  local item
  for item in "${dirs[@]}"; do
    if [[ "$item" == *.toml ]]; then
      # Only back up / copy if the source file actually exists; unlike a
      # directory check (the elif below), this branch previously had no
      # existence guard, so a missing starship.toml aborted the whole install.
      if [[ -e "$INSTALL_ROOT/config/$item" ]]; then
        backup_existing "$cfg/$item"
        run cp -a "$INSTALL_ROOT/config/$item" "$cfg/$item"
      fi
    elif [[ -d "$INSTALL_ROOT/config/$item" ]]; then
      backup_existing "$cfg/$item"
      run cp -a "$INSTALL_ROOT/config/$item" "$cfg/"
    fi
  done

  # Screensaver + About branding. The official package seeds these through
  # /etc/skel; without screensaver.txt, ttfx spams "Error reading input file"
  # as soon as the screensaver starts. Only created when missing, so your own
  # (omarchy branding screensaver image|text) survives re-runs.
  local branding="$cfg/omarchy/branding"
  run mkdir -p "$branding"
  # Replace Omarchy's own art (seeded by earlier runs) but keep custom files.
  if [[ ! -s "$branding/screensaver.txt" ]] || cmp -s "$branding/screensaver.txt" "$SOURCE_DIR/logo.txt"; then
    if (( DRY_RUN )); then echo "+ (write $BRAND wordmark to $branding/screensaver.txt)"; else arch_wordmark > "$branding/screensaver.txt"; fi
  fi
  if [[ ! -s "$branding/about.txt" ]] || cmp -s "$branding/about.txt" "$SOURCE_DIR/icon.txt"; then
    if (( DRY_RUN )); then echo "+ (write Arch logo to $branding/about.txt)"; else arch_logo > "$branding/about.txt"; fi
  fi

  # Do NOT install:
  #   config/chromium
  #   config/chromium-flags.conf
  #   config/opencode
  #
  # opencode is AI-related; Chromium flags are only copied if Chromium is the
  # chosen browser (omarchy-install-browser handles that).

  # Standalone XDG defaults: the chosen browser for web, native Quattro apps
  # for everything else.
  local browser_desktop
  browser_desktop="$(browser_desktop_id "$BROWSER")"
  local mimeapps="$cfg/mimeapps.list"
  backup_existing "$mimeapps"
  {
    printf '[Default Applications]\ninode/directory=org.gnome.Nautilus.desktop\n'
    if [[ -n $browser_desktop ]]; then
      printf '\nx-scheme-handler/http=%s\nx-scheme-handler/https=%s\ntext/html=%s\n' \
        "$browser_desktop" "$browser_desktop" "$browser_desktop"
    fi
    cat <<'MIME'


image/png=imv.desktop
image/jpeg=imv.desktop
image/gif=imv.desktop
image/webp=imv.desktop
image/bmp=imv.desktop
image/tiff=imv.desktop

application/pdf=org.gnome.Evince.desktop

video/mp4=mpv.desktop
video/x-msvideo=mpv.desktop
video/x-matroska=mpv.desktop
video/x-flv=mpv.desktop
video/x-ms-wmv=mpv.desktop
video/mpeg=mpv.desktop
video/ogg=mpv.desktop
video/webm=mpv.desktop
video/quicktime=mpv.desktop
video/3gpp=mpv.desktop
video/3gpp2=mpv.desktop
video/x-ms-asf=mpv.desktop
video/x-ogm+ogg=mpv.desktop
video/x-theora+ogg=mpv.desktop
application/ogg=mpv.desktop

text/plain=nvim.desktop
text/english=nvim.desktop
text/x-makefile=nvim.desktop
text/x-c++hdr=nvim.desktop
text/x-c++src=nvim.desktop
text/x-chdr=nvim.desktop
text/x-csrc=nvim.desktop
text/x-java=nvim.desktop
text/x-moc=nvim.desktop
text/x-pascal=nvim.desktop
text/x-tcl=nvim.desktop
text/x-tex=nvim.desktop
application/x-shellscript=nvim.desktop
text/x-c=nvim.desktop
text/x-c++=nvim.desktop
application/xml=nvim.desktop
text/xml=nvim.desktop
MIME
  } | run tee "$mimeapps" >/dev/null

  # Only copy Quattro's custom native desktop files. The rest are either
  # PWAs/webapps or menu entries for software we deliberately do not install.
  local app_dir="$cfg/applications"
  run mkdir -p "$app_dir"

  local desktop
  for desktop in foot.desktop imv.desktop mpv.desktop; do
    if [[ -f "$INSTALL_ROOT/applications/$desktop" ]]; then
      run cp -f "$INSTALL_ROOT/applications/$desktop" "$app_dir/"
    fi
  done

  # Make the chosen browser win even if another desktop set different defaults.
  if [[ -n $browser_desktop ]] && command -v xdg-settings >/dev/null 2>&1; then
    run env -u BROWSER xdg-settings set default-web-browser "$browser_desktop" || true
  fi
}

prune_user_desktop_entries() {
  log "Removing stale web-app/agent launchers from the application menu"

  local app_dir="${XDG_CONFIG_HOME:-$HOME/.config}/applications"
  [[ -d "$app_dir" ]] || return 0

  find "$app_dir" -maxdepth 1 -type f -name '*.desktop' -print0 |
    while IFS= read -r -d '' desktop; do
      if grep -qE 'omarchy-launch-(or-focus-)?webapp|omarchy-webapp-|omarchy-agent|omarchy-default-agent|omarchy-launch-docker-tui' "$desktop"; then
        run rm -f "$desktop"
      fi
    done
}


install_user_systemd_units() {
  log "Installing safe Quattro user services"

  local src="$INSTALL_ROOT/default/systemd/user"
  local dst="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  run mkdir -p "$dst"

  # These are desktop plumbing, not the Omarchy provisioning stack.
  local units=(
    omarchy-fcitx5.service
    omarchy-sleep-lock.service
    omarchy-recover-internal-monitor.service
    omarchy-crash-watch.service
  )

  local unit
  for unit in "${units[@]}"; do
    if [[ -f "$src/$unit" ]]; then
      backup_existing "$dst/$unit"
      run cp -f "$src/$unit" "$dst/$unit"
    fi
  done

  run systemctl --user daemon-reload || true

  if systemctl --user list-unit-files 2>/dev/null | grep -q '^omarchy-fcitx5.service'; then
    run systemctl --user enable --now omarchy-fcitx5.service || true
  fi
}

enable_desktop_services() {
  log "Enabling desktop services"

  # These are the services the standalone desktop actually owns. PipeWire's
  # user units are socket/desktop-session activated and do not need a system
  # service here.
  run sudo systemctl enable --now NetworkManager.service
  run sudo systemctl enable --now bluetooth.service || true
  run sudo systemctl enable --now power-profiles-daemon.service || true

  # Printing and .local hostnames (cups/avahi/nss-mdns were installed but
  # never switched on).
  run sudo systemctl enable --now cups.socket || true
  run sudo systemctl enable --now avahi-daemon.service || true
  if ! grep -q 'mdns' /etc/nsswitch.conf 2>/dev/null; then
    run sudo sed -i -E 's/^(hosts:.*)\bresolve\b/\1mdns_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf
  fi

  # Setup > Network > DNS writes NetworkManager global DNS *and*
  # systemd-resolved config, then reloads resolved. Like full Omarchy, run
  # systemd-resolved and point resolv.conf at its stub so the choice applies
  # and survives reboots. NetworkManager picks resolved up automatically.
  run sudo systemctl enable --now systemd-resolved.service
  if [[ "$(readlink /etc/resolv.conf 2>/dev/null)" != *stub-resolv.conf ]]; then
    run sudo ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    run sudo systemctl restart NetworkManager.service || true
  fi
  run sudo systemctl mask NetworkManager-wait-online.service || true
}

install_sddm() {
  log "Installing styled SDDM login session"

  # The theme and /usr/share/sddm/hyprland.lua come from the package.
  if (( ! DRY_RUN )); then
    [[ -f /usr/share/sddm/themes/omarchy/Main.qml ]] || die "Quattro SDDM theme missing (package not installed?)."
    [[ -f /usr/share/sddm/hyprland.lua ]] || die "Quattro SDDM Hyprland config missing (package not installed?)."
  fi

  run sudo mkdir -p /etc/sddm.conf.d
  run sudo tee /etc/sddm.conf.d/10-quattro-theme.conf >/dev/null <<'EOF'
[Theme]
Current=omarchy
EOF
  run sudo tee /etc/sddm.conf.d/10-quattro-wayland.conf >/dev/null <<'EOF'
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua
EOF

  # The Quattro login theme has no username field: it always logs in as SDDM's
  # remembered "last user" (/var/lib/sddm/state.conf). Full Omarchy fills that
  # in with a one-time autologin on first boot; on plain Arch it's empty, so
  # every password is rejected. Record the installing user instead -- only if
  # no valid regular user is remembered yet, so later logins aren't overridden.
  local state=/var/lib/sddm/state.conf last="" last_uid=""
  last="$(sudo sed -n 's/^User=//p' "$state" 2>/dev/null | head -1 || true)"
  [[ -n $last ]] && last_uid="$(id -u "$last" 2>/dev/null || true)"
  if [[ -z $last_uid ]] || (( last_uid < 1000 )); then
    log "Setting $USER as the login screen's user"
    run sudo install -d -m 0755 /var/lib/sddm
    printf '[Last]\nUser=%s\nSession=/usr/share/wayland-sessions/omarchy.desktop\n' "$USER" |
      run sudo tee "$state" >/dev/null
    if getent passwd sddm >/dev/null; then
      run sudo chown sddm:sddm /var/lib/sddm "$state"
    fi
  elif [[ $last != "$USER" ]]; then
    warn "The login screen will log in as '$last' (the last SDDM user), not $USER."
    warn "To change it: sudo sed -i 's/^User=.*/User=$USER/' $state"
  fi

  # Auto-login (optional, asked by choose_boot_options) is set up later by
  # apply_boot_setup; otherwise SDDM shows the login screen.
  run sudo systemctl enable --force sddm.service
}

install_xdg_user_dirs() {
  log "Creating XDG user directories"
  run xdg-user-dirs-update
  run mkdir -p "$HOME/Videos" "$HOME/Pictures" "$HOME/Downloads" "$HOME/Documents" "$HOME/Desktop"
}

install_themes() {
  log "Installing Quattro themes"

  local theme_dest="$INSTALL_ROOT/themes"
  if (( ! DRY_RUN )); then
    [[ -d "$theme_dest" ]] || die "Theme directory missing from source."
  fi

  # Theme command expects all themes to live in OMARCHY_PATH/themes.
  # No separate installation is necessary.
  run sudo chmod -R a+rX "$theme_dest"

  # Start with Quattro's bundled Tokyo Night theme if no theme has been chosen.
  # Do not rely on the installer's inherited OMARCHY_PATH or PATH here:
  # /etc/profile.d is not sourced into this already-running process, and an
  # older system omarchy-theme-set may exist on PATH. Invoke Quattro's own
  # command explicitly and give it the runtime theme root.
  local state="$HOME/.local/state/omarchy/current/theme.name"
  local theme_set="$INSTALL_ROOT/bin/omarchy-theme-set"
  if [[ ! -s "$state" ]] && { [[ -x "$theme_set" ]] || (( DRY_RUN )); }; then
    run env OMARCHY_PATH="$INSTALL_ROOT" OMARCHY_THEME_HEADLESS=1 \
      "$theme_set" "Tokyo Night"
  fi
}

materialize_builtin_profile() {
  # Writes a profile that ships inside this script to a temp dir and points
  # PROFILE_DIR at it, so `--profile fabian` needs no extra files.
  local name="$1"
  case "$name" in
    fabian) ;;
    *) return 1 ;;
  esac
  PROFILE_TMP="$(mktemp -d)"
  PROFILE_DIR="$PROFILE_TMP/$name"
  write_profile_fabian "$PROFILE_DIR"

  # The wallpaper is Omarchy 3.2.1's own Tokyo Night image; fetch it rather
  # than embedding 270 KB, and only keep it if it's byte-for-byte that file.
  local rel=".config/omarchy/backgrounds/tokyo-night/3-Milad-Fakurian-Abstract-Purple-Blue.jpg"
  local sum="2868c67434bce109a4863a47f37f302596fe36df33430b508b74c800c368f25a"
  local url dest="$PROFILE_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  for url in \
    "https://raw.githubusercontent.com/basecamp/omarchy/v3.2.1/themes/tokyo-night/backgrounds/3-Milad-Fakurian-Abstract-Purple-Blue.jpg" \
    "https://github.com/basecamp/omarchy/raw/v3.2.1/themes/tokyo-night/backgrounds/3-Milad-Fakurian-Abstract-Purple-Blue.jpg"; do
    if curl -fsSL -m 60 -o "$dest" "$url" 2>/dev/null &&
       [[ $(sha256sum "$dest" | cut -d' ' -f1) == "$sum" ]]; then
      return 0
    fi
  done
  rm -f "$dest"
  warn "Couldn't download the profile wallpaper; everything else in the profile still applies."
  return 0
}

apply_profile() {
  # Personal overlay: every file in the profile directory is copied to the same
  # path under $HOME (existing files are backed up first), then the optional
  # profile.sh runs as you for things that need logic (bar layout, wallpaper).
  [[ -n $PROFILE_DIR ]] || return 0
  log "Applying personal profile: $PROFILE_DIR"

  local f rel dest mode
  while IFS= read -r -d '' f; do
    rel="${f#"$PROFILE_DIR"/}"
    case "$rel" in
      profile.sh|README*|.git/*) continue ;;
    esac
    dest="$HOME/$rel"
    if (( DRY_RUN )); then
      echo "+ (install $rel -> $dest)"
      continue
    fi
    mode="$(stat -c %a "$f")"
    [[ $rel == .config/omarchy/hooks/* ]] && mode=755
    if [[ -e $dest ]] && ! cmp -s "$f" "$dest"; then
      backup_existing "$dest"
    fi
    install -D -m "$mode" "$f" "$dest"
    # Files that passed through Windows can carry CRLF line endings, which
    # break shell scripts and Lua/QML parsing. Strip them from text files.
    if grep -qI . "$dest" 2>/dev/null && grep -q $'\r' "$dest"; then
      sed -i 's/\r$//' "$dest"
    fi
  done < <(find "$PROFILE_DIR" -type f -print0)

  if [[ -f $PROFILE_DIR/profile.sh ]]; then
    if (( DRY_RUN )); then
      echo "+ bash $PROFILE_DIR/profile.sh"
    else
      env OMARCHY_PATH="$INSTALL_ROOT" bash <(tr -d '\r' < "$PROFILE_DIR/profile.sh") ||
        warn "The profile's profile.sh reported a problem; the copied files are in place."
    fi
  fi
}

set_control_center_mode() {
  # Initial control center mode; the sidebar button changes it later.
  # Without the flag an existing choice is kept (default: full).
  [[ -n $CONTROL_CENTER_MODE ]] || return 0
  local state="$HOME/.local/state/omarchy/control-center.json"
  log "Control center mode: $CONTROL_CENTER_MODE"
  run mkdir -p "$(dirname "$state")"
  printf '{\n  "mode": "%s"\n}\n' "$CONTROL_CENTER_MODE" | run tee "$state" >/dev/null
}

create_desktop_launcher() {
  # This is intentionally a tiny convenience command, not a full Omarchy
  # installer. It makes it easy to start Quickshell manually for debugging.
  local launcher="$BIN_DIR/quattro-shell"
  run sudo tee "$launcher" >/dev/null <<EOF
#!/usr/bin/env bash
export OMARCHY_PATH="$INSTALL_ROOT"
exec quickshell -n -p "\$OMARCHY_PATH/shell"
EOF
  run sudo chmod 0755 "$launcher"
}

verify_install() {
  if (( DRY_RUN )); then
    log "Dry run: skipping verification"
    return 0
  fi

  log "Verifying installation"

  local required=(
    "$INSTALL_ROOT/shell/shell.qml"
    "$INSTALL_ROOT/default/hypr/bootstrap.lua"
    "$INSTALL_ROOT/default/hypr/omarchy.lua"
    "$INSTALL_ROOT/config/hypr/hyprland.lua"
    "$INSTALL_ROOT/config/omarchy/shell.json"
    "$INSTALL_ROOT/default/sddm/omarchy/Main.qml"
  )

  local p
  for p in "${required[@]}"; do
    [[ -e "$p" ]] || die "Installation is incomplete; missing $p"
  done

  [[ ! -e "$INSTALL_ROOT/shell/plugins/agents" ]] ||
    die "AI plugin was not removed correctly."

  [[ -x /usr/bin/omarchy-dns && -x /usr/bin/omarchy-plymouth-set ]] ||
    die "Packaged commands missing from /usr/bin."
  [[ -f /etc/pam.d/omarchy-lock-password ]] ||
    die "Lock screen PAM config missing; the lock screen would reject every password."
  [[ $(stat -c %u "$INSTALL_ROOT") == 0 ]] ||
    die "$INSTALL_ROOT is not root-owned; Quattro's privileged commands will refuse to run."
  if [[ -n $(type -P omarchy-dns) && $(type -P omarchy-dns) != /usr/bin/omarchy-dns ]]; then
    warn "$(type -P omarchy-dns) shadows /usr/bin/omarchy-dns on PATH; remove it."
  fi

  if find /usr/bin -maxdepth 1 \
      \( -name 'omarchy-agent*' -o -name 'omarchy-webapp-*' \) \
      -print -quit | grep -q .; then
    die "AI/web-app commands remain in the runtime tree."
  fi

  log "Installation verified."
}

setup_firewall() {
  log "Configuring the firewall (ufw), matching Omarchy's default-deny stance"

  if (( DRY_RUN )); then
    echo "+ (ufw: default deny incoming / allow outgoing, allow 53317 for LocalSend, prompt before allowing SSH, lock down Docker if present, enable)"
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not installed (it should be in PACKAGES already). Skipping firewall setup."
    return 1
  fi

  local via_ssh=0
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]] && via_ssh=1

  run sudo ufw default deny incoming
  run sudo ufw default allow outgoing
  run sudo ufw allow 53317/tcp comment 'LocalSend'
  run sudo ufw allow 53317/udp comment 'LocalSend'

  local allow_ssh=0
  if [[ -t 0 ]]; then
    (( via_ssh )) && warn "This session looks like it's connected over SSH."
    local reply
    read -r -p "Allow SSH in too? Rate-limited on port 22. [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] && allow_ssh=1
  elif (( via_ssh )); then
    warn "Non-interactive session over SSH: rules are set but ufw is NOT being enabled, so you can't lock yourself out. Review with 'sudo ufw status' and run 'sudo ufw enable' yourself once you're sure."
    return 0
  else
    warn "Non-interactive: leaving SSH blocked by default (matches upstream Omarchy). Run 'sudo ufw limit 22/tcp && sudo ufw enable' yourself to change that."
  fi

  if (( allow_ssh )); then
    run sudo ufw limit 22/tcp comment 'SSH (rate limited)'
  elif (( via_ssh )); then
    warn "SSH left blocked and this looks like an SSH session -- NOT enabling ufw so you don't get disconnected. Run 'sudo ufw enable' yourself once you've confirmed another way in."
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    log "Docker detected: locking it down with ufw-docker (chaifeng/ufw-docker)"
    local tmp_bin
    tmp_bin="$(mktemp)"
    if curl -fsSL https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker -o "$tmp_bin"; then
      run sudo install -m 0755 "$tmp_bin" /usr/local/bin/ufw-docker
      run sudo ufw-docker install
      run sudo systemctl reload ufw || true
    else
      warn "Could not fetch ufw-docker from GitHub; skipping Docker lockdown. Containers may bypass ufw until you set this up manually: https://github.com/chaifeng/ufw-docker"
    fi
    rm -f "$tmp_bin"
  fi

  run sudo ufw --force enable
  log "Firewall enabled. Check it any time with 'sudo ufw status verbose'."
}

write_boot_setup() {  # <out>: root helper for the splash / auto-login steps
  cat > "$1" <<'QUATTRO_BOOT_SETUP'
#!/bin/bash
# Root part of the installer's boot setup. Usage (as root):
#   boot-setup.sh splash             add Plymouth to the initramfs + "quiet splash" to the kernel cmdline
#   boot-setup.sh autologin <user>   SDDM auto-login (+ keyring/PAM tweaks)
#   boot-setup.sh no-autologin       remove the auto-login drop-in
# ROOT=/some/dir runs against a fake root (tests); then nothing is regenerated.
# NO_REBUILD=1 skips the initramfs rebuild (the caller rebuilds afterwards).
set -euo pipefail
R=${ROOT:-}
say() { echo "  $*"; }
backup() { [[ -f $1 ]] && cp -a -- "$1" "$1.bak-boot-$(date +%Y%m%d-%H%M%S)"; return 0; }

add_tokens() {  # add_tokens "<cmdline string>" -> prints it with quiet/splash appended if missing
  local line=" $1 " t
  for t in quiet splash; do [[ $line == *" $t "* ]] || line="$line$t "; done
  line=${line# }; echo "${line% }"
}

limine_enrolled() {
  local esp efi sum
  for esp in "$R/boot" "$R/efi" "$R/boot/efi"; do
    [[ -d $esp/EFI ]] || continue
    while IFS= read -r -d '' efi; do
      sum=$(grep -aoE '\+\+CONFIG_B2SUM_SIGNATURE\+\+[0-9a-fA-F]{128}' "$efi" 2>/dev/null | head -1 | sed 's/.*++//')
      [[ -n $sum && $sum =~ [1-9a-fA-F] ]] && return 0
    done < <(find "$esp/EFI" -maxdepth 3 -type f -iname '*.efi' -print0 2>/dev/null)
  done
  return 1
}

splash() {
  local conf="$R/etc/mkinitcpio.conf" changed_boot=0
  # 1. Plymouth hook (before encrypt/sd-encrypt so it draws the LUKS prompt).
  local hooks_file=""
  for f in "$conf" "$R"/etc/mkinitcpio.conf.d/*.conf; do
    [[ -f $f ]] && grep -qE '^HOOKS=' "$f" && hooks_file=$f
  done
  if [[ -z $hooks_file ]]; then
    say "No HOOKS= line found in mkinitcpio config; skipping the Plymouth hook."
  elif grep -qE '^HOOKS=.*[( ]plymouth[ )]' "$hooks_file"; then
    say "Plymouth hook already present ($hooks_file)."
  else
    backup "$hooks_file"
    if grep -qE '^HOOKS=.*[( ](encrypt|sd-encrypt)[ )]' "$hooks_file"; then
      sed -i -E 's/^(HOOKS=\([^)]*[( ])(encrypt|sd-encrypt)([ )])/\1plymouth \2\3/' "$hooks_file"
    elif grep -qE '^HOOKS=.*[( ](udev|systemd)[ )]' "$hooks_file"; then
      sed -i -E 's/^(HOOKS=\([^)]*[( ](udev|systemd))([ )])/\1 plymouth\3/' "$hooks_file"
    else
      say "Couldn't place the Plymouth hook in $hooks_file; leaving it alone."
    fi
    grep -qE '^HOOKS=.*[( ]plymouth[ )]' "$hooks_file" && say "Added Plymouth to $hooks_file"
  fi

  # 2. "quiet splash" on the kernel command line, wherever this system keeps it.
  # Limine (plain config and the limine-mkinitcpio-hook defaults file)
  local lconfs=() f
  for f in "$R"/boot/limine.conf "$R"/boot/limine/limine.conf "$R"/boot/EFI/limine/limine.conf "$R"/boot/EFI/BOOT/limine.conf \
           "$R"/efi/limine.conf "$R"/efi/EFI/limine/limine.conf "$R"/boot/efi/EFI/limine/limine.conf; do
    [[ -f $f ]] && lconfs+=("$f")
  done
  if (( ${#lconfs[@]} )); then
    if limine_enrolled; then
      say "Limine config checksum is enrolled (Secure Boot); not editing limine.conf -- add 'quiet splash' yourself and re-enroll."
    else
      for f in "${lconfs[@]}"; do
        if grep -qE '^[[:space:]]*(kernel_)?cmdline:' "$f" && grep -E '^[[:space:]]*(kernel_)?cmdline:' "$f" | grep -vqE '(^|[[:space:]])splash([[:space:]]|$)'; then
          backup "$f"
          awk '
            /^[[:space:]]*(kernel_)?cmdline:/ {
              line = $0
              if (line !~ /(:|[ \t])quiet([ \t]|$)/) line = line " quiet"
              if (line !~ /(:|[ \t])splash([ \t]|$)/) line = line " splash"
              print line; next
            }
            { print }' "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
          say "Added quiet splash to $f"; changed_boot=1
        fi
      done
    fi
  fi
  f="$R/etc/default/limine"
  if [[ -f $f ]] && grep -qE '^KERNEL_CMDLINE' "$f" && ! grep -E '^KERNEL_CMDLINE' "$f" | grep -qE '[" ]splash[" ]'; then
    backup "$f"
    sed -i -E '/^KERNEL_CMDLINE/ { /[" ]quiet[" ]/! s/"$/ quiet"/; s/"$/ splash"/ }' "$f"
    say "Added quiet splash to $f (limine-mkinitcpio-hook)"; changed_boot=1
  fi
  # UKI
  f="$R/etc/kernel/cmdline"
  if [[ -f $f ]] && ! grep -qE '(^|[[:space:]])splash([[:space:]]|$)' "$f"; then
    backup "$f"; add_tokens "$(tr '\n' ' ' < "$f" | sed 's/ *$//')" > "$f.tmp" && mv -f "$f.tmp" "$f"
    say "Added quiet splash to $f (UKI)"; changed_boot=1
  fi
  # GRUB
  f="$R/etc/default/grub"
  if [[ -f $f ]] && grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f" && ! grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f" | grep -qE '[" ]splash[" ]'; then
    backup "$f"
    local cur; cur=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=["'"'"']\(.*\)["'"'"']$/\1/p' "$f" | head -1)
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$(add_tokens "$cur")\"|" "$f"
    say "Added quiet splash to $f"; changed_boot=1
    if [[ -z $R ]] && command -v grub-mkconfig >/dev/null; then grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 && say "Regenerated grub.cfg"; fi
  fi
  # systemd-boot
  for f in "$R"/boot/loader/entries/*.conf "$R"/efi/loader/entries/*.conf; do
    [[ -f $f ]] || continue
    if grep -q '^options' "$f" && ! grep '^options' "$f" | grep -qE '(^|[[:space:]])splash([[:space:]]|$)'; then
      backup "$f"
      awk '/^options/ { if ($0 !~ /[ \t]quiet([ \t]|$)/) $0 = $0 " quiet"; $0 = $0 " splash" } { print }' "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
      say "Added quiet splash to $f"; changed_boot=1
    fi
  done
  (( changed_boot )) || say "Kernel command line already has splash (or no known bootloader config found)."

  # 3. Rebuild the initramfs (and UKIs) so Plymouth is in it.
  if [[ -z $R && -z ${NO_REBUILD:-} ]]; then
    if command -v limine-mkinitcpio >/dev/null 2>&1; then limine-mkinitcpio; else mkinitcpio -P; fi
  fi
}

autologin() {
  local user=$1
  [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "bad user" >&2; exit 1; }
  mkdir -p "$R/etc/sddm.conf.d"
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$user" > "$R/etc/sddm.conf.d/autologin.conf"
  say "Auto-login enabled for $user"
}

no_autologin() {
  rm -f "$R/etc/sddm.conf.d/autologin.conf"
  say "Auto-login disabled"
}

case "${1:-}" in
  splash) splash ;;
  autologin) autologin "${2:-}" ;;
  no-autologin) no_autologin ;;
  *) echo "usage: boot-setup.sh splash | autologin <user> | no-autologin" >&2; exit 1 ;;
esac
QUATTRO_BOOT_SETUP
  chmod 0755 "$1"
}

disk_encrypted() {
  local f
  for f in /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf; do
    [[ -f $f ]] && grep -qE '^HOOKS=.*[( ](encrypt|sd-encrypt)[ )]' "$f" && return 0
  done
  lsblk -rno TYPE 2>/dev/null | grep -qx crypt
}

ask_yes_no() {  # <question> <default y|n> -> 0 for yes
  local reply hint="[y/N]"
  [[ $2 == y ]] && hint="[Y/n]"
  read -r -p "$1 $hint " reply || reply=""
  reply="${reply:-$2}"
  [[ $reply =~ ^[Yy] ]]
}

choose_boot_options() {
  # Asked up front so the long install that follows runs without questions.
  ENCRYPTED=0
  disk_encrypted && ENCRYPTED=1
  local tty=0
  [[ -t 0 ]] && (( ! DRY_RUN )) && tty=1

  if [[ -z $BOOT_SPLASH ]]; then
    BOOT_SPLASH=no
    if (( tty )); then
      echo
      if (( ENCRYPTED )); then
        echo "Your disk is encrypted. The unlock prompt can be the themed $BRAND splash"
        echo "(logo + password field in your theme colours) instead of a black text prompt."
        ask_yes_no "Use the themed disk-unlock screen?" y && BOOT_SPLASH=yes
      else
        echo "A themed $BRAND boot splash (Plymouth) can replace the scrolling boot text."
        ask_yes_no "Use the themed boot splash?" y && BOOT_SPLASH=yes
      fi
    fi
  fi

  if [[ -z $AUTOLOGIN ]]; then
    AUTOLOGIN=""
    if (( tty && ENCRYPTED )); then
      echo
      echo "With auto-login, the disk password is the only one you type at boot: after"
      echo "unlocking, you go straight to the desktop (the lock screen still uses your"
      echo "account password). Anyone who knows the disk password gets your session."
      if ask_yes_no "Log in automatically after unlocking the disk?" y; then AUTOLOGIN=yes; else AUTOLOGIN=no; fi
    fi
  elif [[ $AUTOLOGIN == yes ]] && (( ! ENCRYPTED )); then
    warn "Auto-login on an unencrypted disk: anyone who can power on this machine gets your desktop."
  fi
  log "Boot splash: $BOOT_SPLASH; auto-login: ${AUTOLOGIN:-unchanged}; disk encryption: $( (( ENCRYPTED )) && echo yes || echo no)"
}

apply_boot_setup() {
  [[ $BOOT_SPLASH == yes || -n $AUTOLOGIN ]] || return 0
  log "Configuring boot splash / auto-login"
  local helper
  helper="$(mktemp --suffix=-boot-setup.sh)"
  write_boot_setup "$helper"

  if [[ $BOOT_SPLASH == yes ]]; then
    if (( ! DRY_RUN )) && { [[ ! -f /etc/mkinitcpio.conf ]] || ! command -v plymouth >/dev/null 2>&1; }; then
      warn "Boot splash needs mkinitcpio and plymouth; skipping it."
    else
      # Plymouth hook (before encrypt/sd-encrypt) + "quiet splash" on the kernel
      # cmdline for Limine / GRUB / systemd-boot / UKI, each file backed up next
      # to itself (*.bak-boot-<date>). The initramfs is rebuilt once, by the
      # boot theme step below.
      run sudo env NO_REBUILD=1 bash "$helper" splash && SPLASH_NEEDS_REBUILD=1
    fi
  fi

  case "$AUTOLOGIN" in
    yes)
      run sudo bash "$helper" autologin "$USER"
      setup_autologin_keyring
      ;;
    no)
      [[ -f /etc/sddm.conf.d/autologin.conf ]] && run sudo bash "$helper" no-autologin
      ;;
  esac
  rm -f "$helper"
}

setup_autologin_keyring() {
  # Auto-login has no password to unlock the login keyring with, so apps
  # (browsers, Nextcloud, ...) would prompt for it. Like Omarchy: a default
  # keyring without a password. Existing keyrings are left alone.
  local dir="$HOME/.local/share/keyrings"
  [[ -f $dir/Default_keyring.keyring ]] && return 0
  if (( DRY_RUN )); then echo "+ (create a password-less default keyring in $dir)"; return 0; fi
  mkdir -p "$dir"; chmod 700 "$dir"
  cat > "$dir/Default_keyring.keyring" <<EOF
[keyring]
display-name=Default keyring
ctime=$(date +%s)
mtime=0
lock-on-idle=false
lock-after=false
EOF
  chmod 600 "$dir/Default_keyring.keyring"
  [[ -f $dir/default ]] || { echo "Default_keyring" > "$dir/default"; chmod 644 "$dir/default"; }
}

rebuild_initramfs() {
  if command -v limine-mkinitcpio >/dev/null 2>&1; then run sudo limine-mkinitcpio; else run sudo mkinitcpio -P; fi
}

apply_boot_theme() {
  # Limine menu + Plymouth splash in the active theme, with the logo art from
  # add_boot_theming. Re-applied on every theme switch (Limine only; the splash
  # needs an initramfs rebuild, so that's on menu > Style > Boot screens).
  log "Styling the boot menu and splash in the current theme"
  local hook="$HOME/.config/omarchy/hooks/theme-set.d/40-boot-theme"
  if (( DRY_RUN )); then
    echo "+ (install $hook, run omarchy-boot-theme)"
    return 0
  fi
  mkdir -p "${hook%/*}"
  if [[ ! -e $hook ]]; then
    cat > "$hook" <<'EOF'
#!/bin/bash
# Restyle the Limine boot menu to match the new theme (no-op without Limine).
command -v omarchy-boot-theme >/dev/null 2>&1 || exit 0
(omarchy-boot-theme --limine --quiet </dev/null >/dev/null 2>&1 &)
EOF
    chmod +x "$hook"
  fi
  run sudo mkdir -p /usr/share/plymouth/themes/omarchy
  if [[ -x /usr/bin/omarchy-boot-theme ]] &&
     run env OMARCHY_PATH="$INSTALL_ROOT" /usr/bin/omarchy-boot-theme; then
    SPLASH_NEEDS_REBUILD=0   # omarchy-plymouth-set rebuilt the initramfs
    return 0
  fi
  warn "Boot theme step failed; the boot screens keep their previous look (retry: menu > Style > Boot screens)."
  return 1
}

usage() {
  cat <<EOF
Quattro Desktop for Arch Linux

Usage:
  $SCRIPT_NAME                      Install
  $SCRIPT_NAME --dry-run            Show actions without changing the system
  $SCRIPT_NAME --uninstall          Remove the $PKG_NAME package (runtime, commands)
  $SCRIPT_NAME --setup-firewall     Also configure ufw (default-deny incoming,
                                    allow LocalSend, prompt before allowing SSH,
                                    lock down Docker via ufw-docker if present)
  $SCRIPT_NAME --boot-splash yes|no Themed Plymouth splash: adds the plymouth hook
                                    (before encrypt/sd-encrypt, so it also draws the
                                    disk-unlock prompt) and "quiet splash" to the
                                    kernel cmdline (Limine, GRUB, systemd-boot, UKI;
                                    files backed up as *.bak-boot-<date>), then
                                    rebuilds the initramfs. Asked if omitted.
                                    (--enable-plymouth = --boot-splash yes)
  $SCRIPT_NAME --autologin yes|no   Log straight into the desktop after boot. Asked
                                    only on encrypted disks (then the disk password
                                    is the only one at boot); off otherwise.

  $SCRIPT_NAME --no-omarchy-repo    Don't add Omarchy's package repo (pkgs.omarchy.org).
                                    Install-menu apps then build from the AUR instead.
  $SCRIPT_NAME --no-drivers         Skip GPU driver / Vulkan / firmware setup.
  $SCRIPT_NAME --profile DIR|NAME   Apply a personal profile after installing: files in
                                    DIR are copied to the same paths under your home
                                    (existing ones backed up), then DIR/profile.sh runs.
                                    Built-in profiles (no folder needed): fabian
  $SCRIPT_NAME --brand NAME         Name shown in menus, keybind list, tooltips and command
                                    output instead of "Omarchy" (default: Archy).
  $SCRIPT_NAME --control-center full|mixed
                                    Control center mode. full: every page in its own
                                    window (default). mixed: Audio, Display, Power,
                                    Network, Bluetooth, Weather, Calendar open
                                    Omarchy's bar panels. Switchable in the sidebar.
  $SCRIPT_NAME --browser NAME       Browser to install + make default, without asking:
                                    edge, firefox, chromium, chrome, brave,
                                    brave-origin, zen, or none. (Asks if omitted;
                                    Edge when there's no terminal to ask on.)

Running as root (e.g. a fresh Arch install without sudo set up):
  $SCRIPT_NAME --user NAME          Install the desktop for NAME (asks if omitted;
                                    uses the sudo caller with "sudo ./install.sh").
                                    Creates the user if missing, installs sudo, adds
                                    the user to wheel, then runs the install as that
                                    user with a temporary password-free sudo grant
                                    that is removed when the run ends.

By default the installer enables [multilib] (Steam, Wine, lib32 drivers),
adds Omarchy's signed package repo AFTER the Arch repos (so Arch packages
always win), and installs the right GPU drivers for the detected hardware.

The firewall is off by default. The boot splash and auto-login are asked on a terminal and
left alone in an unattended run unless given as flags.

Environment:
  OMARCHY_SOURCE_DIR=/path/to/omarchy
      Use an existing Omarchy checkout instead of fetching.

  OMARCHY_REF=quattro
      Git branch/tag/commit used when fetching.

Recommended exact-source workflow:
  git clone --branch quattro https://github.com/omacom/omarchy.git
  cd omarchy
  /path/to/install.sh

The installer keeps:
  Hyprland + Quickshell + themes + desktop shell + useful native apps

The installer removes:
  AI/agents + agent skills + OpenCode + web apps/PWAs + distro provisioning
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --setup-firewall) SETUP_FIREWALL=1 ;;
      --enable-plymouth|--enable-plymouth-luks) BOOT_SPLASH=yes ;;
      --boot-splash) shift; BOOT_SPLASH="${1:-}" ;;
      --boot-splash=*) BOOT_SPLASH="${1#*=}" ;;
      --autologin) shift; AUTOLOGIN="${1:-}" ;;
      --autologin=*) AUTOLOGIN="${1#*=}" ;;
      --no-omarchy-repo) USE_OMARCHY_REPO=0 ;;
      --no-drivers) INSTALL_DRIVERS=0 ;;
      --browser) shift; BROWSER="${1:-}" ;;
      --browser=*) BROWSER="${1#*=}" ;;
      --brand) shift; BRAND="${1:-}" ;;
      --brand=*) BRAND="${1#*=}" ;;
      --control-center) shift; CONTROL_CENTER_MODE="${1:-}" ;;
      --control-center=*) CONTROL_CENTER_MODE="${1#*=}" ;;
      --profile) shift; PROFILE_DIR="${1:-}" ;;
      --profile=*) PROFILE_DIR="${1#*=}" ;;
      --user) shift; TARGET_USER="${1:-}" ;;
      --user=*) TARGET_USER="${1#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

main() {
  ORIGINAL_ARGS=("$@")
  parse_args "$@"
  [[ $BRAND =~ ^[A-Za-z0-9][A-Za-z0-9\ ._+-]{0,30}$ ]] ||
    die "--brand must be a short name (letters, digits, spaces, . _ + -)."
  case "$CONTROL_CENTER_MODE" in
    ""|full|mixed) ;;
    *) die "--control-center must be 'full' or 'mixed' (got '$CONTROL_CENTER_MODE')." ;;
  esac
  [[ $BOOT_SPLASH =~ ^(|yes|no)$ ]] || die "--boot-splash must be 'yes' or 'no'."
  [[ $AUTOLOGIN =~ ^(|yes|no)$ ]] || die "--autologin must be 'yes' or 'no'."
  if [[ -n $PROFILE_DIR ]]; then
    if [[ ! -d $PROFILE_DIR ]]; then
      materialize_builtin_profile "$PROFILE_DIR" ||
        die "No profile directory or built-in profile called '$PROFILE_DIR' (built-in: ${BUILTIN_PROFILES[*]})."
    fi
    PROFILE_DIR="$(cd "$PROFILE_DIR" && pwd)"
  fi

  if (( EUID == 0 )); then
    root_handoff
  fi
  [[ -z $TARGET_USER || $TARGET_USER == "$USER" ]] ||
    die "--user is for running as root; as a normal user the desktop is installed for yourself ($USER)."

  if (( UNINSTALL )); then
    uninstall
    exit 0
  fi

  require_user
  bootstrap_prereqs
  find_source
  choose_browser
  choose_boot_options

  log "Using source: $SOURCE_DIR"
  log "Installing standalone Quattro desktop layer"
  log "AI/agents: disabled"
  log "Web apps/PWAs: disabled"
  log "Browser: $(browser_label "$BROWSER")"
  log "Runtime: pacman package $PKG_NAME at $INSTALL_ROOT"
  log "Repos: multilib on, Omarchy package repo $( (( USE_OMARCHY_REPO )) && echo on || echo off)"
  log "ufw installed but left disabled; enable it yourself once you've reviewed your network needs (sudo systemctl enable --now ufw), or via the Omarchy menu's Setup > Security"

  enable_multilib
  enable_omarchy_repo
  install_packages
  install_omarchy_keyring
  prune_previous_extras
  install_yay
  install_aur_desktop_packages
  install_gpu_drivers
  install_hardware_extras
  install_hyprmon
  install_omarchy_nvim
  install_ttfx
  stage_runtime_tree
  patch_arch_updates
  patch_pkg_helpers
  patch_direct_boot
  patch_hyprland
  patch_standalone_menu
  patch_shell_config
  add_quattro_extras
  patch_bar_colors
  add_boot_theming
  rebrand_tree
  migrate_old_layout
  build_runtime_package
  configure_auth
  install_browser
  install_xdg_user_dirs
  install_user_configs
  prune_user_desktop_entries
  install_user_systemd_units
  enable_desktop_services
  install_sddm
  install_themes
  apply_boot_setup || warn "Boot splash / auto-login setup did not complete."
  apply_boot_theme || true
  if (( SPLASH_NEEDS_REBUILD )); then rebuild_initramfs || warn "Initramfs rebuild failed; run 'sudo mkinitcpio -P' before rebooting."; fi
  apply_profile
  set_control_center_mode
  create_desktop_launcher
  verify_install

  if (( SETUP_FIREWALL )); then
    setup_firewall || warn "Firewall setup did not complete; system left as-is."
  fi

  # Use printf for the color escape so it's interpreted, not printed literally
  # (a `cat <<EOF` heredoc does not expand \033 escapes).
  printf '\n\033[1;32mQuattro desktop installed.\033[0m\n'
  cat <<EOF

Next:
  1. Reboot.
  2. SDDM starts automatically with the Quattro-styled login screen.
  3. Log in with the "Omarchy (Hyprland uwsm)" session. Log out and back in
     (or reboot) after re-running this script so the session picks up
     OMARCHY_PATH=/usr/share/omarchy.
  4. Hyprland starts Quickshell automatically.
  5. $(browser_label "$BROWSER") is the default browser (change it any time:
     menu > Setup > Defaults > Browser).
  6. Super+Return uses xdg-terminal-exec and launches Foot.
  7. Screen recordings go to ~/Videos.

Useful commands:
  omarchy menu
  omarchy theme list
  omarchy theme set "Tokyo Night"
  omarchy shell shell ping
  omarchy restart shell

The standalone runtime is the pacman package $PKG_NAME:
  $INSTALL_ROOT (commands in /usr/bin)
  Update everything (repos + AUR): omarchy-update, or menu > Update > System

Backups are:
  $BACKUP_ROOT
EOF

  if (( ! SETUP_FIREWALL )); then
    echo
    echo "Firewall not configured. Re-run with --setup-firewall to enable ufw (default-deny, LocalSend allowed, SSH opt-in)."
  fi
  if [[ $BOOT_SPLASH != yes ]]; then
    echo "Boot splash not enabled. Re-run with --boot-splash yes for the themed splash (and disk-unlock screen on encrypted disks)."
  fi
}

main "$@"