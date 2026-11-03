#!/usr/bin/env python3
"""Render eight native Rive translation studies using the shared motion-sheet author.

The production geometry and animation tracks are the source of truth. This only
changes the presentation sheet, and does not approximate motion in a video tool.
"""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'output/marr-translation-preview'
PHASES = [
    ('scanText', 'Scan text', 'Read it, line by line.'),
    ('translateFlow', 'Translate', 'Carry the meaning across.'),
    ('alignLayout', 'Arrange', 'Put every piece in place.'),
    ('compareSides', 'Compare', 'Look from both sides.'),
    ('focusText', 'Focus', 'Stay with this passage.'),
    ('languageSwitch', 'Switch language', 'A fresh point of view.'),
    ('translationReveal', 'Reveal', 'Your translation is ready.'),
    ('retryTranslation', 'Try again', 'Pause. Refocus. Retry.'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--render', action='store_true')
    parser.add_argument('--dark', action='store_true')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    output = args.output.resolve()
    spec = importlib.util.spec_from_file_location('marr_motion_sheet', ROOT/'scripts/preview-marr-creative.py')
    sheet = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sheet)
    sheet.OUTPUT = output
    sheet.PHASES = PHASES
    sheet.author(args.dark)

    scene = output/'scene.rml'
    tree = E.parse(scene)
    replacements = {
        'Marr — personality studies': 'Marr — translation studies',
        'MARR  /  MOTION STUDIES': 'MARR  /  TRANSLATION MOTION',
        'A little more personality.': 'From pixels to understanding.',
        'Eight expressions. Two eyes. A world of character.': 'Eight movements for capture, translation and review.',
        'Glass companion  /  Native Rive animation': 'Capture → Read → Translate → Review',
        'All expressions': 'Translation workflow studies',
        'Personality sheet': 'Translation sheet',
    }
    for node in tree.getroot().iter():
        for key, value in list(node.attrib.items()):
            if value in replacements:
                node.set(key, replacements[value])
    tree.write(scene, encoding='unicode')
    (output/'rive.yaml').write_text('name: MarrTranslationStudies\n')
    (output/'README.md').write_text(
        '# Marr translation motion studies\n\n'
        'Eight native Rive clips copied directly from the production asset. '
        'The sheet plays them together for visual comparison; the app chooses its current workflow state.\n\n'
        'Regenerate: `python3 scripts/preview-marr-translation.py --render` from the repository root.\n\n'
        'Open `preview.command` for the native live preview. '
        'The local Rive CLI at `/tmp/marr-rive-tools` and Metal access are required.\n\n'
        'Exports: `marr-translation.gif`, `marr-translation.mp4`, `marr-translation.png`. '
        '`--dark --output <directory>` creates a separate dark preview.\n'
    )
    if args.render:
        sheet.render()
        for suffix in ['gif', 'mp4', 'png']:
            (output/f'marr-personality.{suffix}').replace(output/f'marr-translation.{suffix}')


if __name__ == '__main__':
    main()
