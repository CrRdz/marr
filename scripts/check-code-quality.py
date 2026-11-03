#!/usr/bin/env python3
"""Check source naming, file-size budgets and selected architectural boundaries.

Run from any directory. Existing oversized files have explicit, non-growing
budgets in code-quality-baseline.json; new Swift source files are capped at 800
lines. Lower a budget after extraction instead of raising it to fit new code.
"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOTS = ("Marr", "Packages/MarrModules/Sources")
DEFAULT_LIMIT = 800
SERVICE_NAME = re.compile(r"openai|codex|chatgpt|anthropic|deeplx", re.IGNORECASE)
# Pure projections and leaf algorithms must remain independent of their callers.
FORBIDDEN_DEPENDENCIES = {
    "Marr/Workspace/RuntimeHistoryProjection.swift": ("RuntimeWorkspaceController", "SwiftUI", "MarrToolActivityPresentation"),
    "Marr/Workspace/RuntimeWorkspaceModels.swift": ("RuntimeWorkspaceController", "MarrToolActivityPresentation", "SwiftUI"),
    "Marr/Translation/ImageTranslationModels.swift": ("ConversationSession", "SwiftUI", "MarrNetworking"),
    "Marr/Translation/ImageTranslationResponseParser.swift": ("ConversationSession", "SwiftUI", "MarrNetworking"),
    "Marr/Translation/ImageTranslationMerger.swift": ("ConversationSession", "SwiftUI", "MarrNetworking"),
    "Marr/Translation/TranslationColorSampling.swift": ("ImageTranslationRenderer", "TranslationTypography", "TranslationBackgroundRestoration"),
    "Marr/Translation/TranslationBackgroundRestoration.swift": ("ImageTranslationRenderer", "TranslationTypography"),
    "Marr/Translation/TranslationTypography.swift": ("ImageTranslationRenderer", "TranslationBackgroundRestoration"),
}


def check():
    budgets = json.loads((ROOT / "scripts/code-quality-baseline.json").read_text())
    errors = []
    sources = {str(path.relative_to(ROOT)): path for directory in SOURCE_ROOTS
               for path in (ROOT / directory).rglob("*.swift")}
    project = (ROOT / "Marr.xcodeproj/project.pbxproj").read_text()
    for relative, path in sorted(sources.items()):
        text = path.read_text()
        count = len(text.splitlines())
        limit = budgets.get(relative, DEFAULT_LIMIT)
        if count > limit:
            errors.append(f"{relative}: {count} lines exceeds {limit}; extract a cohesive responsibility")
        if path.parent == ROOT / "Marr":
            errors.append(f"{relative}: place app source in its feature directory")
        if relative.startswith("Packages/MarrModules/Sources/MarrText/"):
            imports = re.findall(r"^import (\w+)", text, re.MULTILINE)
            for module in set(imports) - {"Foundation", "CoreGraphics"}:
                errors.append(f"{relative}: MarrText must remain independent ({module})")
        if SERVICE_NAME.search(relative):
            errors.append(f"{relative}: use a capability/protocol name instead of a service name")
        if relative.startswith("Marr/") and f"/* {path.name} in Sources */" not in project:
            errors.append(f"{relative}: missing Xcode source registration")
        if relative.startswith("Packages/MarrModules/Sources/"):
            for module in re.findall(r"^import (\w+)", text, re.MULTILINE):
                if module in {"AppKit", "SwiftUI"}:
                    errors.append(f"{relative}: shared packages must not import UI modules ({module})")
        for forbidden in FORBIDDEN_DEPENDENCIES.get(relative, ()):
            if re.search(r"\b" + re.escape(forbidden) + r"\b", text):
                errors.append(f"{relative}: must not depend on {forbidden}")
    for relative in budgets:
        if relative not in sources:
            errors.append(f"{relative}: remove obsolete size budget")
    for relative in FORBIDDEN_DEPENDENCIES:
        if relative not in sources:
            errors.append(f"{relative}: update boundary check for moved source")
    for directory in ("MarrTests", "Packages/MarrModules/Tests"):
        for path in (ROOT / directory).rglob("*.swift"):
            if SERVICE_NAME.search(path.name):
                errors.append(f"{path.relative_to(ROOT)}: test filenames must follow source naming")
    if errors:
        print("Code quality checks failed:\n" + "\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print(f"Code quality checks passed: {len(sources)} Swift source files; "
          f"{len(budgets)} explicit legacy size budgets.")
    return 0


if __name__ == "__main__":
    raise SystemExit(check())
