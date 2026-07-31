#!/usr/bin/env python3
"""Remove stale bare-executable AppleMusicBar entries from Control Center."""

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
from urllib.parse import unquote, urlparse


APP_PROCESS_NAME = "AppleMusicBar"
APP_EXECUTABLE_NAME = "AppleMusicBar"
PRESERVED_BUNDLE_ID = "dev.local.AppleMusicBar"
INCORRECT_OWNER_BUNDLE_ID = "com.openai.codex"
CONTROL_CENTER_PREFERENCES = (
    Path.home()
    / "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences"
    / "group.com.apple.controlcenter.plist"
)


def enum_value(value: Any, key: str) -> str | None:
    if not isinstance(value, dict) or key not in value:
        return None

    payload = value[key]
    if isinstance(payload, str):
        return payload
    if isinstance(payload, dict):
        inner = payload.get("_0")
        if isinstance(inner, str):
            return inner
    return None


def bundle_identifier(value: Any) -> str | None:
    return enum_value(value, "bundle")


def adhoc_binary_url(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None

    payload = value.get("adhocBinary")
    if not isinstance(payload, dict):
        return None
    inner = payload.get("_0")
    if not isinstance(inner, dict):
        return None
    relative = inner.get("relative")
    return relative if isinstance(relative, str) else None


def record_location(value: Any) -> Any:
    if isinstance(value, dict) and "location" in value:
        return value["location"]
    return value


def is_bare_applemusicbar_location(value: Any) -> bool:
    url = adhoc_binary_url(value)
    if not url:
        return False

    parsed = urlparse(url)
    path = unquote(parsed.path) if parsed.scheme == "file" else url
    candidate = Path(path)
    if any(part.endswith(".app") for part in candidate.parts):
        return False
    return candidate.name == APP_EXECUTABLE_NAME


def decoded_applications(outer: dict[str, Any]) -> list[Any]:
    encoded = outer.get("trackedApplications")
    if not isinstance(encoded, bytes):
        raise ValueError("trackedApplications is missing or is not plist data")

    applications = plistlib.loads(encoded)
    if not isinstance(applications, list):
        raise ValueError("trackedApplications did not decode to an array")
    return applications


def read_outer(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not a plist dictionary")
    return value


def write_outer(path: Path, value: dict[str, Any]) -> None:
    with path.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)


def location_description(value: Any) -> str:
    url = adhoc_binary_url(value)
    if url:
        return f"adhocBinary:{url}"
    bundle = bundle_identifier(value)
    if bundle:
        return f"bundle:{bundle}"
    return repr(value)


def matching_ghost_locations(path: Path) -> list[str]:
    matches: list[str] = []
    for record in decoded_applications(read_outer(path)):
        if not isinstance(record, dict):
            continue
        location = record_location(record)
        if is_bare_applemusicbar_location(location):
            matches.append(location_description(location))
    return matches


def matching_incorrect_associations(path: Path) -> list[str]:
    matches: list[str] = []
    for record in decoded_applications(read_outer(path)):
        if not isinstance(record, dict):
            continue
        if bundle_identifier(record_location(record)) != INCORRECT_OWNER_BUNDLE_ID:
            continue
        locations = record.get("menuItemLocations")
        if not isinstance(locations, list):
            continue
        for location in locations:
            if bundle_identifier(location) == PRESERVED_BUNDLE_ID:
                matches.append(
                    f"association:{INCORRECT_OWNER_BUNDLE_ID}->{PRESERVED_BUNDLE_ID}"
                )
    return matches


def preserved_bundle_exists(path: Path) -> bool:
    for record in decoded_applications(read_outer(path)):
        if not isinstance(record, dict):
            continue
        if bundle_identifier(record_location(record)) == PRESERVED_BUNDLE_ID:
            return True
    return False


def remove_ghost_records(
    outer: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    applications = decoded_applications(outer)
    kept: list[Any] = []
    removed: list[str] = []

    for record in applications:
        if not isinstance(record, dict):
            kept.append(record)
            continue

        location = record_location(record)
        if is_bare_applemusicbar_location(location):
            removed.append(location_description(location))
            continue

        if bundle_identifier(location) == INCORRECT_OWNER_BUNDLE_ID:
            menu_locations = record.get("menuItemLocations")
            if isinstance(menu_locations, list):
                filtered_locations: list[Any] = []
                for menu_location in menu_locations:
                    if bundle_identifier(menu_location) == PRESERVED_BUNDLE_ID:
                        removed.append(
                            "association:"
                            f"{INCORRECT_OWNER_BUNDLE_ID}->{PRESERVED_BUNDLE_ID}"
                        )
                    else:
                        filtered_locations.append(menu_location)
                record["menuItemLocations"] = filtered_locations

        kept.append(record)

    updated = dict(outer)
    updated["trackedApplications"] = plistlib.dumps(
        kept,
        fmt=plistlib.FMT_BINARY,
        sort_keys=False,
    )
    return updated, removed


def app_is_running() -> bool:
    result = subprocess.run(
        ["/usr/bin/pgrep", "-x", APP_PROCESS_NAME],
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
    if app_is_running():
        print("Quit AppleMusicBar before running this repair.", file=sys.stderr)
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
    backup = (
        Path.home()
        / "Desktop"
        / f"AppleMusicBar-ControlCenter-backup-{timestamp}.plist"
    )

    with tempfile.TemporaryDirectory(
        prefix="applemusicbar-control-center-repair-"
    ) as directory:
        fixed = Path(directory) / "group.com.apple.controlcenter.fixed.plist"
        shutil.copy2(CONTROL_CENTER_PREFERENCES, backup)

        outer = read_outer(CONTROL_CENTER_PREFERENCES)
        updated, removed = remove_ghost_records(outer)
        if not removed:
            print(
                "No unwanted AppleMusicBar records were found; nothing was changed.\n"
                f"Backup: {backup}",
                file=sys.stderr,
            )
            return 3

        write_outer(fixed, updated)
        subprocess.run(["/usr/bin/plutil", "-lint", str(fixed)], check=True)
        unwanted_after_repair = matching_ghost_locations(
            fixed
        ) + matching_incorrect_associations(fixed)
        if unwanted_after_repair:
            raise RuntimeError(
                "The repaired plist still contains unwanted records: "
                + ", ".join(unwanted_after_repair)
            )
        if preserved_bundle_exists(CONTROL_CENTER_PREFERENCES) and not preserved_bundle_exists(
            fixed
        ):
            raise RuntimeError(f"The repair would remove {PRESERVED_BUNDLE_ID}")

        print("The following unwanted records will be removed:")
        for location in dict.fromkeys(removed):
            print(f"  - {location}")
        print(f"The normal bundle record {PRESERVED_BUNDLE_ID} will be preserved.")
        print(f"Backup: {backup}")
        confirmation = input('Type "CLEAN APPLEMUSICBAR" to continue: ')
        if confirmation != "CLEAN APPLEMUSICBAR":
            print("Cancelled; the system preferences were not changed.")
            return 4

        try:
            restart_preferences_services()
            import_preferences(CONTROL_CENTER_PREFERENCES, fixed)
            time.sleep(2)
            remaining = matching_ghost_locations(
                CONTROL_CENTER_PREFERENCES
            ) + matching_incorrect_associations(CONTROL_CENTER_PREFERENCES)
            if remaining:
                raise RuntimeError(
                    "Verification failed; ghost records remain: " + ", ".join(remaining)
                )
        except Exception:
            print("Repair failed; restoring the original backup...", file=sys.stderr)
            restart_preferences_services()
            import_preferences(CONTROL_CENTER_PREFERENCES, backup)
            raise

    print("Repair completed and verified.")
    print("Launch only dist/AppleMusicBar.app; do not run the bare SwiftPM executable.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Repair aborted safely: {error}", file=sys.stderr)
        raise SystemExit(1)
