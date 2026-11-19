"""Finder layout for the drag-to-install disk image, used by dmgbuild."""
from pathlib import Path

app = Path(defines["app"]).resolve(strict=True)
if app.name != "Notch Tray.app":
    raise ValueError("Expected the signed Notch Tray.app release bundle")

format = "UDZO"
filesystem = "HFS+"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
window_rect = ((160, 140), (520, 230))
icon_locations = {app.name: (135, 95), "Applications": (385, 95)}
icon_size = 100
text_size = 14
