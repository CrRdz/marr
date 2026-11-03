# Marr app identity

`glass-companion.png` is the approved imagegen master (2026-10-30): a smoky-gray
to white translucent sphere, with two eyes near the center looking slightly left.
Keep the original gradients, highlights and alpha. The older blue viewfinder
master `artwork.png` is retained for reference and is no longer packaged.

Run `swift scripts/package-marr-app-icon.swift` from the repository root to generate:

- Ten macOS Dock assets in `Marr/Assets.xcassets/AppIcon.appiconset` (16–1024 px).
- Three status-bar assets in `Marr/Assets.xcassets/MarrStatusIcon.imageset`
  (18, 36 and 54 px, displayed at 18 pt).
- An ignored `dock-preview.png` for visual inspection.

The packager measures the artwork's visible bounds to normalize transparent
padding, then resamples the original pixels without recoloring or adding a tile.
An antialiased circular clipping mask removes only exterior pixels. The source
master, eye positions, gradients, highlights and interior transparency are unchanged.
The Dock silhouette occupies 864/1024 of its canvas; the menu-bar silhouette
occupies 16/18. The status image uses original-color rendering: marking this
translucent sphere as a template would erase the eyes and glass shading.

The app loads the status asset separately from functional capture/UI icons.
Changing this identity does not change screenshot-button artwork or actions.

## Dock rendering and distribution

On macOS 26, transparent application artwork alone does not prevent the system's
rounded-square backing. Marr supplies the same circular artwork through two public
AppKit paths:

- While running, `MarrAppDelegate` sets `NSApp.dockTile.contentView` to an
  autoresizing `NSImageView`, loading raw ICNS pixels directly.
- While not running, `MarrDockTile.docktileplugin` supplies a content view from
  a separate system host. The app's `NSDockTilePlugIn` Info.plist entry registers
  it. Its image is the same 1024 px circular asset, embedded at build time.

The plug-in target is a dependency of Marr and is embedded with CodeSignOnCopy.
Both Debug and Release builds include it. It does not launch Marr, write to the
app bundle, change user preferences, access the network, or use private APIs.
The plug-in has no dependency on the main process, including its quit handlers.

This supports the project's direct DMG distribution, not Mac App Store distribution.
It changes the Dock only; Finder and Spotlight retain system rendering. The system
must allow the Dock plug-in to run. This is not a guarantee for disabled background
items, every future macOS release, or transient frames before the system loads it.

An existing pinned entry created before this plug-in was added may cache
`dock-extra = false`. Remove that old Dock entry, launch the updated app, and pin
it again. New installations include plug-in registration from their first launch.
Do not make all users run a Finder override script or clear system caches.

### Release checks

Before creating a DMG, both release workflows run:

```sh
python3 scripts/check-marr-dock-plugin.py path/to/Marr.app --universal
```

`--universal` is required for the universal release and omitted for the single-arch
nightly. The check validates host registration, the embedded principal class,
exact artwork bytes, CPU architectures, strict recursive signing, dynamic plug-in
loading, circular transparency, resizing, and attach/detach ownership.
It does not replace a live Dock check or Developer ID notarization.

For release acceptance, install on a clean supported macOS account, pin the app,
then check launch, normal quit, force quit, Dock restart and login. Test both CPU
architectures. An update from the old version must also be checked for stale pins.

Never apply Finder custom-icon metadata to a build product, archive or release.
FinderInfo/resource forks can cause strict signing failures. The legacy
`set-marr-custom-icon.swift` helper is not part of the build or release process.
