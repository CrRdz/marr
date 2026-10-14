#!/usr/bin/env python3
"""Check the static Pages artifact without third-party dependencies."""

import os
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


SITE_ROOT = Path(__file__).resolve().parents[1] / "dist"
CSS_COMMENTS = re.compile(r"/\*.*?\*/", re.DOTALL)
CSS_URLS = re.compile(
    r"url\(\s*(?:([\"'])(.*?)\1|([^\"')]*))\s*\)",
    re.IGNORECASE | re.DOTALL,
)


def css_references(source):
    for match in CSS_URLS.finditer(CSS_COMMENTS.sub("", source)):
        yield match.group(2) if match.group(1) else match.group(3).strip()


class ResourceParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.references = []
        self.in_style = False

    def handle_starttag(self, tag, attrs):
        self.in_style = self.in_style or tag == "style"
        for name, value in attrs:
            if value is None:
                continue
            if name in ("src", "href"):
                self.references.append(value)
            elif name == "style":
                self.references.extend(css_references(value))

    def handle_endtag(self, tag):
        if tag == "style":
            self.in_style = False

    def handle_data(self, data):
        if self.in_style:
            self.references.extend(css_references(data))


def check_site(root):
    root = Path(root).absolute()
    errors = []
    checked = 0
    if root.is_symlink():
        return ["dist must not be a symbolic link"], checked
    if not root.is_dir():
        return ["dist directory does not exist"], checked
    root = root.resolve()
    if not (root / "index.html").is_file():
        errors.append("index.html is missing")

    files = []
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = Path(directory) / name
            if path.is_symlink():
                errors.append(f"symbolic link is not allowed: {path.relative_to(root)}")
            elif name in names:
                files.append(path)

    for path in files:
        if path.suffix.lower() not in (".html", ".css"):
            continue
        label = path.relative_to(root)
        try:
            source = path.read_text(encoding="utf-8")
            if path.suffix.lower() == ".html":
                parser = ResourceParser()
                parser.feed(source)
                parser.close()
                references = parser.references
            else:
                references = css_references(source)
            for reference in references:
                reference = reference.strip()
                try:
                    url = urlsplit(reference)
                except ValueError as error:
                    errors.append(f"{label}: invalid URL {reference!r}: {error}")
                    continue
                if url.scheme or url.netloc or not url.path:
                    continue
                checked += 1
                local_path = unquote(url.path)
                base = root if local_path.startswith("/") else path.parent
                try:
                    target = (base / local_path.lstrip("/")).resolve()
                    target.relative_to(root)
                except (ValueError, OSError, RuntimeError):
                    errors.append(f"{label}: reference escapes dist or is invalid: {reference!r}")
                    continue
                if target.is_dir():
                    target /= "index.html"
                if not target.is_file():
                    errors.append(f"{label}: missing local resource: {reference!r}")
        except (OSError, UnicodeError) as error:
            errors.append(f"{label}: cannot read resource: {error}")
    return sorted(set(errors)), checked


def main():
    errors, checked = check_site(SITE_ROOT)
    if errors:
        print(f"FAIL: static site validation found {len(errors)} problem(s).", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(f"PASS: index.html exists; {checked} local references resolve inside dist; no symbolic links.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
