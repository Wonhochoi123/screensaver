# Screensaver

An mpv-based photo & video screensaver with an offline location/landmark HUD,
animated month title cards, a now-playing music marquee + progress bar, and a
chronological slideshow built from your own media.

## Install

```
curl -fsSL https://raw.githubusercontent.com/Wonhochoi123/screensaver/main/install.sh | bash
```

`install.sh` installs the dependencies, downloads the rest of the repo, and
copies everything into `~/Screensaver-App/` (plus an autostart entry and a
"Start Screensaver" launcher). Re-run it any time to update.

You can also clone and run it locally — it uses the checkout's files directly:

```
git clone https://github.com/Wonhochoi123/screensaver
cd screensaver && ./install.sh
```

## Repository layout

There is no generated bundle — these are the real files, installed as-is:

```
install.sh        orchestration: deps, folders, fonts, autostart, and the
                  single-source-of-truth config (the export block at the top
                  is written to ~/Screensaver-App/config/screensaver.conf,
                  which every script then sources)
config/           → ~/Screensaver-App/config/
  photo.lua         the mpv HUD / slideshow script
  mpv.conf  input.conf
  build-title.sh  build-minimap.sh  build-geodb.sh  geo-resolve.sh
  trash-media.sh
app/              → ~/Screensaver-App/
  launch.sh  xmp-police.sh  vid-daemon.sh  idle-watcher.sh
```

To change behaviour, edit the file under `config/` or `app/` and re-run
`install.sh` (locally or via the curl one-liner once pushed). To change a
setting (durations, volume, idle timeout, GeoNames countries…), edit the export
block at the top of `install.sh` — it is the single source for
`screensaver.conf`.

When piped from `curl`, `install.sh` has no local files next to it, so it
downloads the repo tarball from `main` and installs from that; when run from a
clone it uses the local files. Either way the same files land in
`~/Screensaver-App/`.
