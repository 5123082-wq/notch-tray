# Notch Tray

A standalone, modified, tray-only macOS application created on 2026-10-26.
This is not an official release of NotchDrop, boring.notch, or NotchNook.

Notch Tray is distributed under GNU GPL version 3. See LICENSE.
You may use, modify, and redistribute it under those terms. There is no warranty.
Complete corresponding source and build scripts accompany this application.

## NotchDrop

- Copyright (c) 2024 Lakr Aream.
- https://github.com/Lakr233/NotchDrop
- Revision consulted: e70b3d715a99e47de6eb823540282eafc7401a3a
- MIT license: Licenses/NotchDrop-MIT.txt.
- The notch geometry in Sources/NotchPanel.swift adapts Ext+NSScreen.swift.
- The private, copy-backed storage design was informed by TrayDrop+DropItem.swift.

## boring.notch

- TheBoredTeam and contributors.
- https://github.com/TheBoredTeam/boring.notch
- Revision consulted: 23e7705a4ffcb5d97a54fb1d4135e180084a566d
- GNU GPL version 3: LICENSE.
- BoringNotchWindow.swift (Harsh Vardhan Goswami, 2024-08-06) informed
  the nonactivating panel in Sources/NotchPanel.swift.
- DragDetector.swift (Alexander, 2025-11-20) adapted into the mouse-only DragObserver.
- ShelfItemView.swift informed the drag threshold, multi-selection, native
  NSDraggingSession lifecycle, and cancellation handling in Sources/ShelfView.swift.
- Modified: no music, media frameworks, AirDrop, calendar, HUDs or other widgets;
  copy-only file export; file URL pasteboard without plain-text path fallback;
  new storage, Russian UI, thumbnails, file promises and independent build scripts.

Only macOS system frameworks are linked. The application checks the public
GitHub Releases API for version updates. Automatic checks can be disabled.
