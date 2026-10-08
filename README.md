# update

One command to bring an Ubuntu or Fedora machine up to date (system packages,
snaps, Flatpak apps and Homebrew), with a tidy animated display while it works.

```
  ✓ Refreshing package lists   00:04
  ✓ Upgrading packages         01:23
    ↳ 12 upgraded, 1 newly installed, 0 removed
  ✓ Updating Flatpak apps      00:41
    ↳ 3 updated, 0 newly installed, 1 removed
  ✓ Updating Homebrew          00:06
  ✓ Upgrading brew packages    00:19
    ↳ Upgraded: gh, jq
  ✓ Restarting Tailscale       00:02
    ↳ Connected again as 100.x.y.z

  ! A reboot is required to finish the update.
  All done in 02:35
```

## What it does

It runs whichever of these are installed, in this order:

1. **System packages**, without stopping to ask questions:
   - Ubuntu and Debian: `apt-get update`, then `apt-get upgrade`. If you've
     edited a package's config file, your version is kept.
   - Fedora (and other dnf systems): `dnf makecache`, then `dnf upgrade`.
   - Fedora Atomic desktops (Silverblue, Kinoite and others):
     `rpm-ostree upgrade`. The new system image takes over at the next boot.
2. **Snaps**: `snap refresh`.
3. **Flatpak apps**: first those installed for everyone, then any you installed
   just for yourself (with `--user`), which are updated as you. Flatpak removes
   runtimes that reached end of life once no app installed for everyone uses
   them; if one of your own apps still does, Flatpak installs it again for you.
4. **Homebrew**: `brew update`, then `brew upgrade`. Homebrew refuses to run as
   root, so it runs as whoever owns its folder (normally you), never as root. It
   runs in a clean environment, so `HOMEBREW_*` settings exported by your shell
   don't apply; put them in `~/.homebrew/brew.env` instead (and settings such as
   `brew analytics off` are kept by brew itself).
5. **Tailscale**: restarted if it's installed **and running**, then the script
   waits for it to reconnect. If you've stopped Tailscale, it's left alone.

On Fedora, Fedora Atomic and other dnf systems, when the update needs a restart
to finish (see below), it asks whether to restart now, with a 30-second
countdown. Only `y` (or `Y`) followed by Enter restarts, so a command you're
already typing can't answer by accident; anything else, Ctrl+C, or no answer
before the countdown ends means no. Set `RESTART_COUNTDOWN` near the top of the
script to change the countdown, or to `0` to turn the question off. It's only
asked when the script runs in a terminal.

It asks for your sudo password once, at the start. At the end it tells you if a
reboot is needed: on Ubuntu when the system says so, on Fedora Atomic when a new
system image is waiting, and on Fedora when a core package such as the kernel or
glibc has been installed since boot (the core-package part of what
`dnf needs-restarting` checks).

## Usage

```bash
./update.sh
```

- While a step runs, a spinner shows the latest line of its output. The full
  output is saved to a log.
- If a step fails, the script stops and shows the last lines of output, plus the
  path to the full log.
- Ctrl+C stops the step that's running. dnf first finishes the transaction
  it's in, and apt the dpkg run it's in, setup scripts and kernel installs
  included, so nothing is left half installed. Flatpak and Homebrew stop right
  away.
- When it isn't run in a terminal (from cron, or with output sent to a file), it
  skips the animation and prints plain output instead.

The animation is written to stay out of the way: the spinner doesn't start any
new processes, and the intro plays while the first step works.

## Colors

All colors come from your terminal's theme, so they follow it, light or dark.
The accent defaults to your theme's blue. In [Ptyxis](https://gitlab.gnome.org/chergert/ptyxis),
with a palette that follows the desktop accent (such as Ubuntu or GNOME), it uses
your accent color from Settings > Appearance, as Ptyxis does.

To pick a color yourself, set `ACCENT` near the top of the script to one of
1 red, 2 green, 3 yellow, 4 blue, 5 magenta or 6 cyan.

## Requirements

Bash 5 or newer, on Ubuntu, Debian, Fedora, or another Debian- or Fedora-based
distribution. Snap, Flatpak, Homebrew and Tailscale are all optional. Homebrew
is found in its standard location, `/home/linuxbrew/.linuxbrew` (or
`~/.linuxbrew` on older installs).

## License

[MIT](LICENSE)
