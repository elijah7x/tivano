# Tivano installer (DMG) window styling

The Finder window users see when they open a Tivano DMG is styled by three
pre-baked assets in this directory. `scripts/package_dmg.sh` stages them
into every release DMG; nothing here runs at release time.

| Asset | Staged as | Purpose |
| --- | --- | --- |
| `installer-background.tiff` | `/.background.tiff` | HiDPI (1x+2x) window background |
| `installer-DS_Store.base64` | `/.DS_Store` (decoded) | Window geometry, icon positions, background wiring; kept as base64 text so git and reviews treat it as source rather than an opaque binary |
| built app's `AppIcon.icns` | `/.VolumeIcon.icns` | Mounted-volume icon (copied from the app at package time, so it always matches the shipped icon) |

## Load-bearing invariants

The baked `.DS_Store` references things **by name**. If any of these change,
the styling silently breaks (Finder falls back to a default window), so keep
them in lockstep:

- Volume name must stay `Tivano` (the background image alias stores it).
- The background must be staged at exactly `/.background.tiff`.
- The app must be `Tivano.app` and the symlink `Applications` (their icon
  positions are keyed by those names).
- The artwork is composed for 660x400 with icon centers at (165, 200) and
  (495, 200). `WindowBounds` is 660x480: macOS 27 Finder always shows a tab
  bar and honors the user's global path bar, leaving roughly 384-412pt of
  content, so the composition plus the image's bottom bleed covers every case
  without a scrollbar.
- Finder draws icon labels in dark text on this background in both light and
  dark appearance, so the paper must stay light.

The `.DS_Store` was baked against a throwaway volume, so the alias inside it
carries that volume's creation date. Finder resolves background aliases by
volume name + path, so it keeps working for every future DMG.

## Changing the design

1. Edit `generate_installer_background.swift` (all layout constants live at the
   top) and render:

   ```bash
   swift release/dmg/generate_installer_background.swift /tmp/dmg-art "/Applications/Tivano.app/Contents/Resources/AppIcon.icns"
   open /tmp/dmg-art/preview-mock.png   # judge the design with icons composited
   tiffutil -cathidpicheck /tmp/dmg-art/installer-background.png \
       /tmp/dmg-art/installer-background@2x.png \
       -out release/dmg/installer-background.tiff
   ```

2. Only if geometry changed (window size, icon positions, icon size, or any
   renamed path): re-bake the `.DS_Store` with [dmgbuild](https://pypi.org/project/dmgbuild/),
   keeping `dmgbuild_settings.py` in sync with the new constants first. Eject
   any mounted `Tivano` volume before baking: otherwise the bake volume
   mounts as `Tivano 1` and the alias records that name (check with
   `base64 -d < release/dmg/installer-DS_Store.base64 | strings | grep Volumes`,
   which must print `/Volumes/Tivano`; `package_dmg.sh` refuses an asset
   that fails this check):

   ```bash
   python3 -m venv /tmp/dmgvenv && /tmp/dmgvenv/bin/pip install dmgbuild
   rm -rf /tmp/dmgbake && mkdir -p "/tmp/dmgbake/stub/Tivano.app/Contents/MacOS"
   cp release/dmg/dmgbuild_settings.py release/dmg/installer-background.tiff /tmp/dmgbake/
   /tmp/dmgvenv/bin/dmgbuild -s /tmp/dmgbake/dmgbuild_settings.py \
       -D here=/tmp/dmgbake "Tivano" /tmp/dmgbake/baked.dmg
   mkdir -p /tmp/dmgbake/mnt && hdiutil attach -nobrowse -readonly -mountpoint /tmp/dmgbake/mnt /tmp/dmgbake/baked.dmg
   base64 -b 76 < /tmp/dmgbake/mnt/.DS_Store > release/dmg/installer-DS_Store.base64
   hdiutil detach /tmp/dmgbake/mnt
   ```

3. Verify by packaging a build with `scripts/package_dmg.sh --app "/Applications/Tivano.app" --output /tmp/tivano.dmg`.
