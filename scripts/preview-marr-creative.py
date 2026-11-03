#!/usr/bin/env python3
"""Build a native Rive eight-expression motion sheet and optional rendered preview.

The sheet clones production geometry/keyframes. Each clip is time-normalized to
four seconds for comparison; the app keeps each authored duration and loop mode.
"""
from __future__ import annotations
import argparse
import copy
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'DesignAssets/MarrCompanion/scene.rml'
OUTPUT = ROOT / 'output/marr-creative-preview'
PHASES = [
    ('curious', 'Curious', 'A little closer.'),
    ('thinking', 'Thinking', 'Give me a moment.'),
    ('delighted', 'Delighted', 'That worked!'),
    ('shy', 'Shy', 'Oh, hello there.'),
    ('sleepy', 'Sleepy', 'Just resting my eyes.'),
    ('surprised', 'Surprised', 'Wait, really?'),
    ('playful', 'Playful', 'Catch me looking.'),
    ('greeting', 'Greeting', 'Good to see you.'),
]


def sub(parent, tag, **attrs):
    return E.SubElement(parent, tag, {k: str(v) for k, v in attrs.items()})


def solid(parent, color):
    sub(sub(parent, 'Fill'), 'SolidColor', colorValue=color)


def author(dark=False):
    src = E.parse(SOURCE).getroot()
    board = src.find('Artboard')
    by_name = {a.get('name'): a for a in board.findall('LinearAnimation')}
    missing = [n for n, _, _ in PHASES if n not in by_name]
    if missing:
        raise SystemExit('Production states not ready: ' + ', '.join(missing))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / 'assets').mkdir(exist_ok=True)
    root = E.Element('Rive', version='1', kind='fragment')
    art = sub(root, 'Artboard', id='0:900000', name='Marr — personality studies',
              width=1120, height=790, styleId='0:900001', defaultStateMachineId='0:900002')
    sub(art, 'LayoutComponentStyle', id='0:900001', name='Motion sheet')
    ink = 'FFF4F2ED' if dark else 'FF383A38'
    muted = 'FFAAAFA9' if dark else 'FF858B83'
    card = 'FF262B2A' if dark else 'FFFEFDFB'
    background = 'FF1B201F' if dark else 'FFF1F0EA'
    next_id = 910000

    def text(value, x, y, size, color=ink, origin=0):
        nonlocal next_id
        next_id += 1
        tid, sid = f'0:{next_id}', f'0:{next_id+1000}'
        node = sub(art, 'Text', id=tid, name=value, x=x, y=y, originX=origin, originY=.5)
        style = sub(node, 'TextStylePaint', id=sid, fontSize=size, fontAssetId='0:900010')
        solid(style, color)
        sub(node, 'TextValueRun', styleId=sid, text=value)

    text('MARR  /  MOTION STUDIES', 40, 42, 12, muted)
    text('A little more personality.', 40, 91, 36)
    text('Eight expressions. Two eyes. A world of character.', 40, 132, 15, muted)
    text('01 — 08', 1080, 87, 14, muted, origin=1)
    text('Glass companion  /  Native Rive animation', 40, 744, 12, muted)
    text('Mouthless by design.', 1080, 744, 12, muted, origin=1)

    sm = sub(art, 'StateMachine', id='0:900002', name='Showcase')
    layer = sub(sm, 'StateMachineLayer', name='All expressions')
    sub(layer, 'AnyState')
    sub(layer, 'ExitState')
    sub(sub(layer, 'EntryState'), 'StateTransition', stateToId='0:900003')
    sub(layer, 'AnimationState', id='0:900003', animationId='0:900004')
    merged = sub(art, 'LinearAnimation', id='0:900004', name='Personality sheet', duration=240, fps=60, loopValue='loop')
    ignored = {'LayoutComponentStyle', 'StateMachine', 'LinearAnimation', 'Fill'}
    visuals = [n for n in board if n.tag not in ignored]
    for index, (name, title, caption) in enumerate(PHASES):
        col, row = index % 4, index // 4
        cx, cy = 164 + col * 264, 270 + row * 264
        text(title, cx, cy+96, 18, origin=.5)
        text(caption, cx, cy+120, 12, muted, origin=.5)
        text(f'{index+1:02}', cx-104, cy-76, 11, muted)
        scale = 1.35
        wrapper = sub(art, 'Node', name=f'{title} panel', x=cx-64*scale, y=cy-64*scale, scaleX=scale, scaleY=scale)
        # Asset IDs are shared; drawable IDs are distinct for each panel.
        mapping = {}
        for visual in visuals:
            for n in visual.iter():
                if n.get('id'):
                    mapping[n.get('id')] = f'0:{10000*(index+1)+int(n.get("id").split(":")[1])}'
        for visual in visuals:
            clone = copy.deepcopy(visual)
            for n in clone.iter():
                for key, value in list(n.attrib.items()):
                    if key != 'assetId' and value in mapping:
                        n.set(key, mapping[value])
            wrapper.append(clone)
        anim = by_name[name]
        duration = float(anim.get('duration', 240))
        for keyed in anim.findall('KeyedObject'):
            clone = copy.deepcopy(keyed)
            original = clone.get('objectId')
            if original not in mapping:
                raise ValueError(f'{name}: keyed object {original} has no copied visual')
            clone.set('objectId', mapping[original])
            for n in clone.iter():
                if n.get('frame'):
                    n.set('frame', str(round(float(n.get('frame'))*240/duration)))
            merged.append(clone)
        tile = sub(art, 'Shape', name=f'{title} tile', x=cx, y=cy+22)
        sub(tile, 'Rectangle', width=248, height=246, cornerRadiusTL=18,
            cornerRadiusTR=18, cornerRadiusBL=18, cornerRadiusBR=18)
        solid(tile, card)
    sub(sub(art, 'Fill', name='Background'), 'SolidColor', colorValue=background)
    for asset in src:
        if asset.tag.endswith('Asset'):
            clone = copy.deepcopy(asset)
            location = asset.get('file')
            if location:
                asset_path = (SOURCE.parent / location).resolve()
                shutil.copy2(asset_path, OUTPUT/'assets'/asset_path.name)
                clone.set('file', f'assets/{asset_path.name}')
            root.append(clone)
    font = ROOT/'DesignAssets/MarrMotionPreview/assets/Inter.ttf'
    shutil.copy2(font, OUTPUT/'assets/Inter.ttf')
    sub(root, 'FontAsset', id='0:900010', file='assets/Inter.ttf', name='Inter')
    E.indent(root, space='  ')
    E.ElementTree(root).write(OUTPUT/'scene.rml', encoding='unicode')
    (OUTPUT/'rive.yaml').write_text('name: MarrCreativeStudies\n')
    (OUTPUT/'preview.command').write_text('#!/bin/zsh\ncd "${0:A:h}"\nexport RIVE_HOME=/tmp/marr-rive-tools\nexec /tmp/marr-rive-tools/bin/rive .\n')
    (OUTPUT/'preview.command').chmod(0o755)
    print(OUTPUT/'scene.rml', flush=True)


def render():
    cli = Path('/tmp/marr-rive-tools/bin/rive')
    if not cli.exists():
        raise SystemExit('Install Rive CLI, or set up the existing /tmp/marr-rive-tools installation.')
    env = dict(os.environ, RIVE_HOME='/tmp/marr-rive-tools')
    frames = OUTPUT/'frames'
    frames.mkdir(exist_ok=True)
    for f in range(48):
        subprocess.run([str(cli), str(OUTPUT), f'--advance={f*5}',
                        f'--screenshot={frames}/{f:04d}.png'], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if f % 12 == 0:
            print(f'Rendered {f+1}/48', flush=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '12', '-i', str(frames/'%04d.png'),
                    '-filter_complex', 'split[a][b];[a]palettegen[p];[b][p]paletteuse', '-loop', '0',
                    str(OUTPUT/'marr-personality.gif')], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '12', '-i', str(frames/'%04d.png'),
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
                    str(OUTPUT/'marr-personality.mp4')], check=True)
    shutil.copy2(frames/'0006.png', OUTPUT/'marr-personality.png')
    print('Rendered native Rive GIF, MP4 and cover.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--render', action='store_true')
    parser.add_argument('--dark', action='store_true')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    OUTPUT = args.output.resolve()
    author(args.dark)
    if args.render:
        render()
