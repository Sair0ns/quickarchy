"""Nautilus context-menu entry for Omarchy Quick Look.

The primary way in is the Space key, which Nautilus routes over D-Bus to
whichever process owns org.gnome.NautilusPreviewer (see the plugin's
bin/quick-look-previewer). This extension only adds a discoverable
right-click entry for the same preview, so the feature is findable without
knowing the shortcut.
"""

import subprocess

from gi.repository import GObject, Nautilus

IPC_TARGET = "andreconde.quick-look"


class QuickLookExtension(GObject.GObject, Nautilus.MenuProvider):
    def _preview(self, _menu, path):
        subprocess.Popen(
            ["omarchy-shell", IPC_TARGET, "show", path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def _local_path(self, file_info):
        location = file_info.get_location()
        if location is None:
            return None
        return location.get_path()

    def _menu_item(self, path):
        item = Nautilus.MenuItem(
            name="AndreCondeQuickLook::quick_look",
            label="Quick Look",
            tip="Preview this item in Omarchy Quick Look (or press Space)",
        )
        item.connect("activate", self._preview, path)
        return [item]

    def get_file_items(self, files):
        if len(files) != 1:
            return []
        path = self._local_path(files[0])
        return self._menu_item(path) if path else []

    def get_background_items(self, current_folder):
        path = self._local_path(current_folder)
        return self._menu_item(path) if path else []
