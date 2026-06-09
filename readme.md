# Screensaver

An mpv-based photo & video screensaver with an offline location/landmark HUD,
animated month title cards, a now-playing music marquee, and a chronological
slideshow built from your own media.

## Install

```
curl -s https://raw.githubusercontent.com/Wonhochoi123/screensaver/main/ScreenSaverMaster.sh | bash
```

That one file installs everything (deps, config, scripts, autostart).

## Development

`ScreenSaverMaster.sh` is **generated — do not edit it directly.** The real
sources live under `src/`:

```
src/
  installer.tmpl              orchestration skeleton (deps, folders, autostart,
                              and the single-source-of-truth config export block)
  config/                     → installed to ~/Screensaver-App/config/
    screensaver.conf          central config template (expanded at install)
    photo.lua                 the mpv HUD / slideshow script
    mpv.conf  input.conf
    build-title.sh  build-minimap.sh  build-geodb.sh  geo-resolve.sh
    trash-media.sh
  app/                        → installed to ~/Screensaver-App/
    launch.sh  xmp-police.sh  vid-daemon.sh  idle-watcher.sh
  desktop/                    → ~/.config & ~/.local (autostart + launcher)
  fontconfig/                 → ~/.config/fontconfig (font path registration)
```

Edit the files under `src/`, then regenerate the installer:

```
./build.sh
```

`build.sh` stitches `src/installer.tmpl` and the file sources back into
`ScreenSaverMaster.sh`. Each file's heredoc quoting is kept in the template, so
literal `<< 'EOF'` blocks stay literal and the unquoted ones
(`screensaver.conf`, the `.desktop` files, the fontconfig file) still expand
their `$VARS` at install time.

Commit `ScreenSaverMaster.sh` together with your `src/` changes — the install
one-liner fetches that built file from `main`.
