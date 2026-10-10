# dmgbuild settings used to (re)bake release/dmg/installer-DS_Store.base64 (the
# baked volume's .DS_Store, base64-encoded so it lives in git as text).
# Not used at release time — see release/dmg/README.md for when and how to run it.
#
# Geometry must stay in lockstep with generate_installer_background.swift:
#   designed content: 660x400; WindowBounds 660x480 leaves room for macOS 27's
#   titlebar, tab bar and an optional path bar
#   Tivano.app at (165, 200), Applications at (495, 200), icon size 128
import os.path

# dmgbuild exec()s this file without __file__; pass -D here=<this directory>.
HERE = os.path.abspath(defines.get("here", "."))  # noqa: F821 - injected by dmgbuild

volume_name = "Tivano"
format = "UDZO"
filesystem = "HFS+"

# Any minimal stub named Tivano.app works: only the NAME is baked into .DS_Store.
files = [os.path.join(HERE, "stub", "Tivano.app")]
symlinks = {"Applications": "/Applications"}

# dmgbuild copies this to /.background.tiff on the volume and the baked alias
# points there; scripts/package_dmg.sh must keep staging it at that path.
background = os.path.join(HERE, "installer-background.tiff")

window_rect = ((420, 200), (660, 480))

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 12
show_icon_preview = False
arrange_by = None

icon_locations = {
    "Tivano.app": (165, 200),
    "Applications": (495, 200),
}
