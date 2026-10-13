# QuickArchy

A macOS-style file previewer for the Omarchy shell — select a file in Files, press **Space**, and the file appears, rendered. Press **P** and it goes to your printer.

A fork of [andreconde21/omarchy-quick-look](https://github.com/andreconde21/omarchy-quick-look) that adds printing and fixes two defects that stopped the original from working at all on Omarchy 4.

![QuickArchy previewing an image](preview.png)

## What it does

QuickArchy puts a themed, full-screen preview card behind the Space key. It renders the file rather than describing it, and it is the same card for every kind of file:

| Kind | What you see |
|---|---|
| Images | the image, fitted to the screen, with pixel dimensions, format and colour space |
| PDF | the real pages, rendered (the first 8), with page count and file size |
| Video | a still frame, duration, resolution and codec |
| Audio | the embedded cover art, title/artist/album, duration |
| Text and code | the contents, syntax-agnostic, up to 400 lines |
| Markdown | the source, shown literally (see Notes) |
| Folders | the contents, subfolders first |
| Archives | the entry list |
| Anything else | its type, its size, and what `file` makes of it |

Three things it does that a previewer usually does not:

- **It prints.** `P` (or Ctrl+P) sends the file you are looking at to the CUPS default printer — images fitted to the page, PDFs as they are, text through the CUPS filter chain. Everything that would come out blank (folders, archives, video, audio, binaries) is refused *before* a job is queued, and the card tells you what CUPS answered.
- **It knows its own metadata.** Every preview carries a header with the file's name, size, and the format-specific facts: dimensions and colour space for an image, page count for a PDF, duration and codec for a video, artist and album for audio.
- **It is themed.** The card is drawn from the shell palette (background, foreground, accent, corner radius), so it follows your Omarchy theme like the bar and the launcher do.

## Keys

| Key | Action |
|---|---|
| **Space** on a selected file in Files | open the preview |
| **Space**, **Esc** or **Q** | close it |
| **Enter** | open the file in its default application |
| **P** or **Ctrl+P** | print it |

## How the Space key works

Nautilus does not let extensions bind keys. What it does is D-Bus activate the well-known name `org.gnome.NautilusPreviewer` when Space is pressed on a selection. This plugin ships a small bridge that owns that name and forwards the request to the Omarchy overlay — the supported way to put your own previewer behind the Space key.

Ways in:

- **Space** on a selected file in Files
- **Right-click → QuickArchy** (a Nautilus extension, for discoverability)
- `omarchy-shell sairons.quickarchy show /path/to/file`

## Printing

Press **P** (or Ctrl+P) inside the preview: the file goes to the **CUPS default printer**.

- Images are scaled to the page (`fit-to-page`), PDFs are sent unchanged, plain text is converted by the CUPS filter chain.
- Folders, archives, videos, audio and binaries are **refused before a job is queued** — a job that comes out blank only wastes paper.
- The card reports the outcome: `Sent to <printer>`, or the reason it refused. The line clears itself after a few seconds.
- Change the default printer with `lpoptions -d <name>`; list printers with `lpstat -p`.
- Print to a specific printer without touching the default: `bin/quick-look-print <file> --printer <name>`.
- From a script or a keybinding: `omarchy-shell sairons.quickarchy printFile /path/to/file` (the last outcome is `printResult`).

## Requirements

- Omarchy 4 (Quattro) with Quickshell plugin support
- `python3` with PyGObject (`python-gobject`) — required for the Space-key bridge
- `file` — required; without it nothing is classified and every file falls back to "no preview"
- `imagemagick` — **required for image previews**: it is what measures an image before decoding it, so without it images are refused rather than shown
- `poppler` (PDF pages), `ffmpeg` and `ffmpegthumbnailer` (video stills, cover art), `bsdtar`/libarchive (archive listings) — optional, each affects only its own file type
- `xdg-open` for the Open button, `nautilus-python` for the right-click entry — both optional
- `cups` (`lp`, `lpstat`) with a configured default printer — required for printing; without it the Print button is still shown and the card says no default printer is configured

## Install

```bash
omarchy plugin add https://github.com/Sairons/quickarchy --enable --yes
```

Then register the Space-key bridge:

```bash
mkdir -p ~/.local/share/dbus-1/services
cat > ~/.local/share/dbus-1/services/org.gnome.NautilusPreviewer.service <<EOF
[D-BUS Service]
Name=org.gnome.NautilusPreviewer
Exec=$HOME/.config/omarchy/plugins/sairons.quickarchy/bin/quick-look-previewer
EOF
nautilus -q
dbus-send --session --dest=org.freedesktop.DBus --type=method_call /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig
```

The last line matters the first time: the session bus reads its service list **when it starts**, so without the reload the system previewer (sushi, which Omarchy ships) keeps answering the Space key instead of this plugin. After the first run, the user-level service file shadows sushi at every login.

Optionally also the right-click entry:

```bash
mkdir -p ~/.local/share/nautilus-python/extensions
cp ~/.config/omarchy/plugins/sairons.quickarchy/nautilus/quick_look.py \
   ~/.local/share/nautilus-python/extensions/
nautilus -q
```

## Troubleshooting

**Space opens GNOME's previewer, or nothing at all.** Something else owns the D-Bus name, or a bridge process from an earlier install is still holding it:

```bash
pgrep -af quick-look-previewer   # this plugin's bridge (which path is it running from?)
pgrep -x sushi                   # GNOME's own previewer
pkill -f quick-look-previewer    # free the name; the next Space press restarts it
```

Then re-run the `dbus-send … ReloadConfig` line above.

**The card opens but says "Preview helper not found".** The plugin cannot locate its own helper scripts. It resolves them from its public id under `$XDG_CONFIG_HOME/omarchy/plugins/sairons.quickarchy`; if you installed it elsewhere, that is why.

## Notes

- Previews render as plain text, including Markdown. A preview shows files this shell did not author, and Qt's rich-text formats resolve image and raw-HTML references themselves inside a long-lived process; plain text cannot reference an external resource at all. That is a deliberate trade of formatting for a property that holds by construction.
- Rendered pages, stills and cover art are cached under `~/.cache/omarchy/quick-look`, keyed by path and modification time, and pruned after 7 days. Reopening a file is instant; changing it re-renders.
- Video is previewed as a still frame rather than played. Press Enter to open it in a real player.
- All format handling lives in `bin/quick-look-probe`, which prints JSON. Run it against a file to see exactly what the card will draw.

## Differences from the original

1. **Printing** — `P` / `Ctrl+P` and a button in the card; the original has no printing. The job goes through `bin/quick-look-print`, which refuses non-printable kinds before queueing anything.
2. **The plugin can find its own scripts** — the original built its paths from `manifest.__sourceDir`, a field the shell **deletes** from third-party manifests (`publicPluginManifest` in `shell.qml`). Every preview therefore failed with "Preview helper not found". This fork derives the directory from the public plugin id (`$XDG_CONFIG_HOME/omarchy/plugins/<id>`) and still prefers `__sourceDir` when a host provides it.
3. **The footer sits inside the card** — the body height was computed by subtracting `footer.implicitHeight`, which is 0 because the footer has an explicit height. The body stayed 28 px too tall, so the footer (file name + Print/Open) was laid out past the card's bottom edge. This fork subtracts the siblings' real heights.
4. **Renamed** — `sairons.quickarchy` / "QuickArchy", with the Wayland layer namespace and the Nautilus menu entry aligned.
5. **Documentation** — this README, plus an Italian copy in [README.it.md](README.it.md).

## Uninstall

```bash
omarchy plugin remove sairons.quickarchy --yes
```

To hand the Space key back to GNOME's previewer (sushi) and drop the render cache:

```bash
rm -f ~/.local/share/dbus-1/services/org.gnome.NautilusPreviewer.service
rm -f ~/.local/share/nautilus-python/extensions/quick_look.py
rm -rf ~/.cache/omarchy/quick-look
nautilus -q
dbus-send --session --dest=org.freedesktop.DBus --type=method_call /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig
```

## Credits and license

Built on [andreconde21/omarchy-quick-look](https://github.com/andreconde21/omarchy-quick-look) by André Conde.

MIT — see [LICENSE](LICENSE).
