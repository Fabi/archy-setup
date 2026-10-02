# archy-setup

Turns a plain Arch Linux install into **Archy**: the Omarchy *Quattro* desktop (Hyprland, Quickshell, themes, menus, lock screen) without the AI agents, web apps and distro provisioning. It adds a CachyOS-style app launcher, a control center and themed boot screens.

It's still Arch. Packages and updates come from the Arch repos (plus the AUR via `yay`). Omarchy only provides the look and the desktop tooling.

<img width="957" height="572" alt="Archy desktop" src="https://github.com/user-attachments/assets/fccb89d1-323a-4f48-8233-1a84593d708a" />
<img width="942" height="582" alt="Archy launcher" src="https://github.com/user-attachments/assets/fa8b63d8-5d75-4400-87a8-e243e82ff2ec" />
<img width="942" height="582" alt="Archy control center" src="https://github.com/user-attachments/assets/125c2811-4d50-40cb-adec-87256549d68f" />

## Quick start

On a fresh Arch install (e.g. from `archinstall`, any profile, no desktop needed), with a working internet connection:

```bash
curl -fsSLo archy_setup.sh https://raw.githubusercontent.com/Fabi/archy-setup/master/archy_setup.sh
chmod +x archy_setup.sh
./archy_setup.sh
```

That's it. The script asks a few questions up front (browser, boot splash, auto-login), then runs unattended. Reboot when it's done.

- **Logged in as root, no sudo set up yet?** Run the same commands as root. The script asks which user should get the desktop, or you can pass `--user NAME`. It creates that user if needed, installs `sudo`, and adds the user to `wheel`.
- **Want to see what it would do first?** `./archy_setup.sh --dry-run`
- **Don't use `curl … | bash`.** The script needs your terminal to ask its questions and to re-run itself as your user, so download it first as shown above.

> **Tip:** if you choose disk encryption in `archinstall`, the script can turn the unlock prompt into the themed boot splash and log you in automatically afterwards. Then the disk password is the only one you type at boot.

## What you get

- **Desktop:** Hyprland (Lua config), Quickshell bar and widgets, Omarchy's menus, keybinds and themes, and the themed lock and login screens (SDDM).
- **Launcher** (`Super+Space`): an app launcher with categories, recent apps and search. The Archy menu moves to `Super+Alt+Space`.
- **Control center:** a bar button that opens Home, Media, Audio, Display, System, Power, Network, Bluetooth, Weather, Calendar and Notifications pages. Bluetooth headphones become the audio output automatically when they connect.
- **Boot screens:** the Limine boot menu and the Plymouth splash and disk-unlock prompt use your current theme's colours with the Arch logo. The boot menu follows theme switches automatically; refresh the splash via *Menu → Style → Boot screens*.
- **Updates:** *Menu → Update* runs `yay -Syu` (Arch repos and AUR). The install menu (Steam, etc.) works, with an AUR fallback.
- **Drivers:** GPU drivers (NVIDIA, AMD, Intel), Vulkan, `multilib` and firmware are detected and installed.
- **Browser of your choice:** Edge, Firefox, Chromium, Chrome, Brave, Brave Origin, Zen, or none.

**Removed compared to Omarchy:** AI agents and agent skills, OpenCode, web apps/PWAs, and the distro provisioning and migrations.

## Example

The setup I use myself (personal theme tweaks, firewall, themed unlock screen and auto-login on an encrypted disk):

```bash
./archy_setup.sh --profile fabian --setup-firewall --control-center full --boot-splash yes --autologin yes
```

## Options

Everything is optional. Anything that's asked interactively can also be given as a flag, so you can run the script unattended.

| Option | What it does |
|---|---|
| `--dry-run` | Print every action without changing anything. |
| `--browser NAME` | `edge`, `firefox`, `chromium`, `chrome`, `brave`, `brave-origin`, `zen` or `none`. Asked if omitted (Edge when there's no terminal to ask on). |
| `--boot-splash yes\|no` | Themed Plymouth splash. Adds the `plymouth` hook (before `encrypt`/`sd-encrypt`, so it also draws the disk-unlock prompt) and `quiet splash` to the kernel command line for Limine, GRUB, systemd-boot or UKI, then rebuilds the initramfs. Edited files are backed up as `*.bak-boot-<date>`. Asked if omitted. `--enable-plymouth` does the same as `--boot-splash yes`. |
| `--autologin yes\|no` | Log straight into the desktop after boot. Asked only on encrypted disks. On an unencrypted disk it's off unless you pass `yes`. |
| `--setup-firewall` | Configure ufw: deny incoming by default, allow LocalSend, ask before allowing SSH, and lock down Docker via ufw-docker if Docker is present. |
| `--control-center full\|mixed` | `full`: every page in the control-center window (default). `mixed`: Audio, Display, Power, Network, Bluetooth, Weather and Calendar open Omarchy's own bar panels. Switchable later in the sidebar. |
| `--profile NAME\|DIR` | Apply a personal profile afterwards (see below). Built in: `fabian`. |
| `--brand NAME` | The name shown in menus, tooltips and the boot screens instead of "Omarchy". Default `Archy`; `--brand Arch` shows "Arch Linux". |
| `--user NAME` | Only when running as root: the account that gets the desktop. |
| `--no-drivers` | Skip GPU driver, Vulkan and firmware setup. |
| `--no-omarchy-repo` | Don't add Omarchy's package repo. Install-menu apps then build from the AUR instead. |
| `--uninstall` | Remove the desktop package and the login-screen settings. Your `~/.config` and apps stay. |

Environment variables:

- `OMARCHY_SOURCE_DIR=/path/to/omarchy` uses a local Omarchy checkout instead of fetching it.
- `OMARCHY_REF=quattro` sets the branch, tag or commit to fetch (default `quattro`).

## Profiles

A profile is a folder whose files are copied to the same paths under your home, for example `.config/hypr/monitors.lua`. Existing files are backed up first. If the folder has a `profile.sh`, it runs afterwards and can do things like set bar colours or the wallpaper.

```bash
./archy_setup.sh --profile ~/my-profile
```

`--profile fabian` is built into the script as an example: monitor layout, keyboard layouts, Nord-ish bar colours and a wallpaper.

## How it works

- **The desktop is a normal pacman package.** The script fetches Omarchy's `quattro` branch, removes the agent, web-app and provisioning parts, applies the Arch-specific patches, and installs the result as the local package `omarchy-quattro-standalone`. Files go to `/usr/share/omarchy`, with commands in `/usr/bin`. Re-running the script updates it.
- **Repositories.** It enables `[multilib]` and appends Omarchy's signed repo (`pkgs.omarchy.org`) *after* the Arch repos, so an Arch package always wins over a same-named one. Use `--no-omarchy-repo` if you'd rather not have it.
- **Boot changes are opt-in and backed up.** Nothing in your bootloader or initramfs changes unless you answer yes or pass `--boot-splash yes`.
- **Your files.** Existing configs that the script replaces are backed up to `~/.local/state/omarchy-quattro/backups`.

## Uninstall

```bash
./archy_setup.sh --uninstall
```

This removes the desktop package, the SDDM settings and the auto-login. Your home folder and installed apps stay. To get the plain-text boot back, restore the `*.bak-boot-*` files next to your bootloader config and `mkinitcpio.conf`, then run `sudo mkinitcpio -P`.

## Credits

- [Omarchy](https://github.com/omacom/omarchy) by DHH and contributors: the desktop, themes and tooling this builds on.
- [CachyOS](https://cachyos.org) and [Noctalia](https://github.com/noctalia-dev/noctalia-shell): inspiration for the launcher and control center.
- Arch Linux and the Arch logo are trademarks of Arch Linux. This project is not affiliated with or endorsed by Arch Linux, Omarchy/Basecamp or CachyOS.

## License

MIT. See [LICENSE](LICENSE).
