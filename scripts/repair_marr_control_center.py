#!/usr/bin/env python3
"""Remove Marr's accidental ownership by ChatGPT from macOS Control Center."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any


TARGET_OWNER = "com.openai.codex"
TARGET_PREFIX = "com.marr.Marr"
RESULT_PATH = Path("/private/tmp/marr-control-center-repair-result.plist")
CONTROL_CENTER_PREFERENCES = (
    Path.home()
    / "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences"
    / "group.com.apple.controlcenter.plist"
)


def bundle_identifier(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None

    bundle = value.get("bundle")
    if isinstance(bundle, str):
        return bundle
    if isinstance(bundle, dict):
        identifier = bundle.get("_0")
        if isinstance(identifier, str):
            return identifier
    return None


def decoded_applications(outer: dict[str, Any]) -> list[Any]:
    encoded = outer.get("trackedApplications")
    if not isinstance(encoded, bytes):
        raise ValueError("trackedApplications is missing or is not plist data")

    applications = plistlib.loads(encoded)
    if not isinstance(applications, list):
        raise ValueError("trackedApplications did not decode to an array")
    return applications


def remove_marr_from_chatgpt(
    outer: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    applications = decoded_applications(outer)
    removed: list[str] = []

    for record in applications:
        if not isinstance(record, dict):
            continue
        if bundle_identifier(record.get("location")) != TARGET_OWNER:
            continue

        locations = record.get("menuItemLocations")
        if not isinstance(locations, list):
            continue

        kept_locations: list[Any] = []
        for location in locations:
            identifier = bundle_identifier(location)
            if identifier and identifier.startswith(TARGET_PREFIX):
                removed.append(identifier)
            else:
                kept_locations.append(location)
        record["menuItemLocations"] = kept_locations

    updated = dict(outer)
    updated["trackedApplications"] = plistlib.dumps(
        applications,
        fmt=plistlib.FMT_BINARY,
        sort_keys=False,
    )
    return updated, removed


def read_outer(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not a plist dictionary")
    return value


def write_outer(path: Path, value: dict[str, Any]) -> None:
    with path.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)


def matching_associations(path: Path) -> list[str]:
    applications = decoded_applications(read_outer(path))
    matches: list[str] = []
    for record in applications:
        if not isinstance(record, dict):
            continue
        if bundle_identifier(record.get("location")) != TARGET_OWNER:
            continue
        locations = record.get("menuItemLocations")
        if not isinstance(locations, list):
            continue
        for location in locations:
            identifier = bundle_identifier(location)
            if identifier and identifier.startswith(TARGET_PREFIX):
                matches.append(identifier)
    return matches


def app_is_running(process_name: str) -> bool:
    result = subprocess.run(
        ["/usr/bin/pgrep", "-x", process_name],
        stdout=subprocess.PIPE,
        text=True,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        return False

    for process_id in result.stdout.split():
        state = subprocess.run(
            ["/bin/ps", "-p", process_id, "-o", "state="],
            stdout=subprocess.PIPE,
            text=True,
            stderr=subprocess.DEVNULL,
            check=False,
        ).stdout.strip()
        if state and not state.startswith("Z"):
            return True
    return False


def write_result(status: str, **details: Any) -> None:
    value = {"status": status, "timestamp": datetime.now().isoformat(), **details}
    with RESULT_PATH.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def restart_preferences_services() -> None:
    user_id = str(os.getuid())
    for process_name in ("ControlCenter", "cfprefsd"):
        subprocess.run(
            ["/usr/bin/pkill", "-9", "-u", user_id, "-x", process_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def import_preferences(source: Path, imported: Path) -> None:
    subprocess.run(
        ["/usr/bin/defaults", "import", str(source), str(imported)],
        check=True,
    )


def main() -> int:
    write_result("started")
    if app_is_running("Marr"):
        write_result("blocked", reason="Marr is running")
        print("Quit Marr before running this repair.", file=sys.stderr)
        return 2

    if not CONTROL_CENTER_PREFERENCES.is_file():
        print(f"Preferences file not found: {CONTROL_CENTER_PREFERENCES}", file=sys.stderr)
        return 2
    if not os.access(CONTROL_CENTER_PREFERENCES, os.R_OK | os.W_OK):
        print(
            "Terminal cannot access the Control Center ledger. Grant Terminal Full Disk "
            "Access, quit Terminal completely, reopen it, and try again.",
            file=sys.stderr,
        )
        return 2

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = Path.home() / "Desktop" / f"Marr-ControlCenter-backup-{timestamp}.plist"

    with tempfile.TemporaryDirectory(prefix="marr-control-center-repair-") as directory:
        fixed = Path(directory) / "group.com.apple.controlcenter.fixed.plist"
        shutil.copy2(CONTROL_CENTER_PREFERENCES, backup)

        outer = read_outer(CONTROL_CENTER_PREFERENCES)
        updated, removed = remove_marr_from_chatgpt(outer)
        if not removed:
            write_result("no_change", backup=str(backup))
            print(
                "No Marr association was found under com.openai.codex; nothing was changed.\n"
                f"Backup: {backup}",
                file=sys.stderr,
            )
            return 3

        write_outer(fixed, updated)
        subprocess.run(["/usr/bin/plutil", "-lint", str(fixed)], check=True)
        if matching_associations(fixed):
            raise RuntimeError("The repaired plist still contains the unwanted association")

        print("The following associations will be removed from com.openai.codex:")
        for identifier in sorted(set(removed)):
            print(f"  - {identifier}")
        print(f"Backup: {backup}")
        confirmation = "REPAIR MARR" if "--yes" in sys.argv[1:] else input(
            'Type "REPAIR MARR" to continue: '
        )
        if confirmation != "REPAIR MARR":
            write_result("cancelled", backup=str(backup))
            print("Cancelled; the system preferences were not changed.")
            return 4

        try:
            restart_preferences_services()
            import_preferences(CONTROL_CENTER_PREFERENCES, fixed)
            time.sleep(2)
            remaining = matching_associations(CONTROL_CENTER_PREFERENCES)
            if remaining:
                raise RuntimeError(
                    "Verification failed; associations remain: " + ", ".join(remaining)
                )
        except Exception:
            print("Repair failed; restoring the original backup...", file=sys.stderr)
            restart_preferences_services()
            import_preferences(CONTROL_CENTER_PREFERENCES, backup)
            raise

    write_result(
        "success",
        backup=str(backup),
        removed=sorted(set(removed)),
    )
    print("Repair completed and verified.")
    print("Launch Marr directly from Xcode or Finder, not from ChatGPT/Codex.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        write_result("error", error=str(error))
        print(f"Repair aborted safely: {error}", file=sys.stderr)
        raise SystemExit(1)
