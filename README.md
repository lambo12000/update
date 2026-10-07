# update

One command to bring an Ubuntu machine up to date, with a tidy animated display
while it works.

```
  ✓ Refreshing package lists   00:04
  ✓ Upgrading packages         01:23
    ↳ 12 upgraded, 0 newly installed, 0 to remove and 0 not upgraded
  ✓ Refreshing snaps           00:31
    ↳ Refreshed: firefox, snapd
  ✓ Restarting Tailscale       00:02
    ↳ Connected again as 100.x.y.z

  All done in 02:00
```

## What it does

1. `apt-get update`
2. `apt-get upgrade`, without stopping to ask questions. If you've edited a
   package's config file, your version is kept.
3. `snap refresh`
4. Restarts Tailscale, if it's installed **and running**, then waits for it to
   reconnect. If you've stopped Tailscale, it's left alone.

It asks for your sudo password once, at the start. At the end it tells you if a
reboot is needed.

## Usage

```bash
./update.sh
```

- While a step runs, a spinner shows the latest line of its output. The full
  output is saved to a log.
- If a step fails, the script stops and shows the last lines of output, plus the
  path to the full log.
- Ctrl+C stops the step that's running.
- When it isn't run in a terminal (from cron, or with output sent to a file), it
  skips the animation and prints plain output instead.

The animation is written to stay out of the way: the spinner doesn't start any
new processes, and the intro plays while the package lists download.

## Colours

All colours come from your terminal's theme, so they follow it, light or dark.
The accent defaults to your theme's blue. In [Ptyxis](https://gitlab.gnome.org/chergert/ptyxis),
with a palette that follows the desktop accent (such as Ubuntu or GNOME), it uses
your accent colour from Settings > Appearance, as Ptyxis does.

To pick a colour yourself, set `ACCENT` near the top of the script to one of
1 red, 2 green, 3 yellow, 4 blue, 5 magenta or 6 cyan.

## Requirements

Ubuntu (it was written on 26.04) or another distribution with apt and snap, and
bash 5 or newer. Tailscale is optional.

## License

[MIT](LICENSE)
