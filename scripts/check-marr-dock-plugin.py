#!/usr/bin/env python3
"""Validate a built distributable, without changing the bundle or Dock settings."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--universal", action="store_true")
args = parser.parse_args()
app = args.app.resolve()
root = Path(__file__).resolve().parent.parent

def read_info(bundle):
    return plistlib.loads((bundle / "Contents/Info.plist").read_bytes())

info = read_info(app)
assert info.get("NSDockTilePlugIn") == "MarrDockTile.docktileplugin", "Missing host registration"
plugin = app / "Contents/PlugIns" / info["NSDockTilePlugIn"]
plugin_info = read_info(plugin)
assert plugin_info.get("NSPrincipalClass") == "MarrDockTilePlugIn", "Invalid principal class"
art_name = "Marr-Dock-512@2x.png"
art = plugin / "Contents/Resources" / art_name
assert art.read_bytes() == (root / "Marr/Assets.xcassets/AppIcon.appiconset" / art_name).read_bytes(), "Stale artwork"
for bundle, metadata in ((app, info), (plugin, plugin_info)):
    executable = bundle / "Contents/MacOS" / metadata["CFBundleExecutable"]
    architectures = set(subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split())
    if args.universal:
        assert {"arm64", "x86_64"} <= architectures, f"Missing architecture: {bundle}"
    attributes = set(subprocess.check_output(["xattr", str(bundle)], text=True).splitlines())
    assert not {"com.apple.FinderInfo", "com.apple.ResourceFork"} & attributes, "Finder override must not ship"
subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)
with tempfile.TemporaryDirectory(prefix="marr-dock-check-") as directory:
    checker = str(Path(directory) / "check-render")
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "AppKit",
                    str(root / "scripts/check-marr-dock-render.m"), "-o", checker], check=True)
    subprocess.run([checker, str(plugin)], check=True)
print("PASS: Dock plug-in registration, embedded artwork, architectures and strict signing")
