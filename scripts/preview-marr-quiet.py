#!/usr/bin/env python3
"""Author a quiet-state sheet and record a workflow through the actual Rive machine."""
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
OUTPUT = ROOT / 'output/marr-quiet-preview'
CLI = Path('/tmp/marr-rive-tools/bin/rive')
MOODS = [('waiting', 'Waiting', 'Quietly present.'), ('observing', 'Observing', 'Attention follows you.'),
         ('processing', 'Processing', 'A little inner movement.'), ('settled', 'Settled', 'Everything falls into place.'),
         ('attention', 'Attention', 'A gentle pause.')]
STAGES = [('Select', 1, 0, 4, -2, 2), ('Read', 2, 1, -2, 0, 4),
          ('Translate', 2, 0, 0, 0, 6), ('Ready', 3, 0, 0, 0, 4)]
INK, MUTED, BG = 'FFE9EBEF', 'FF939BA8', 'FF1B1F26'
NEXT = 900000


def sub(parent, tag, **attrs):
    return E.SubElement(parent, tag, {k: str(v) for k, v in attrs.items()})


def obj(parent, tag, **attrs):
    global NEXT
    NEXT += 1
    return sub(parent, tag, id=f'0:{NEXT}', **attrs)


def fill(parent, color):
    sub(sub(parent, 'Fill'), 'SolidColor', colorValue=color)


def text(art, value, x, y, size, color=INK, centered=False):
    n = obj(art, 'Text', x=x, y=y, originX=.5 if centered else 0, originY=.5, name=value)
    style = obj(n, 'TextStylePaint', fontSize=size, fontAssetId='0:999990')
    fill(style, color)
    sub(n, 'TextValueRun', styleId=style.get('id'), text=value)
    return n


def keys(anim, node, prop, pairs):
    o = sub(anim, 'KeyedObject', objectId=node.get('id'))
    p = sub(o, 'KeyedProperty', property=prop)
    for f, v in pairs:
        sub(p, 'KeyFrameDouble', frame=f, value=v)


def static_machine(art, animation, name):
    sm = obj(art, 'StateMachine', name=name)
    art.set('defaultStateMachineId', sm.get('id'))
    layer = sub(sm, 'StateMachineLayer', name=name)
    sub(layer, 'AnyState'); sub(layer, 'ExitState')
    entry = sub(layer, 'EntryState')
    state = obj(layer, 'AnimationState', animationId=animation.get('id'))
    sub(entry, 'StateTransition', stateToId=state.get('id'))


def author():
    src = E.parse(SOURCE).getroot()
    board = src.find('Artboard')
    by_name = {a.get('name'): a for a in board.findall('LinearAnimation')}
    missing = [n for n, _, _ in MOODS if n not in by_name]
    if missing:
        raise SystemExit('Waiting for quiet production timelines: ' + ', '.join(missing))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT/'assets').mkdir(exist_ok=True)
    root = copy.deepcopy(src)
    hero = root.find('Artboard')
    hero.set('name', 'Translation flow'); hero.set('width', '760'); hero.set('height', '640')
    excluded = {'LayoutComponentStyle', 'StateMachine', 'LinearAnimation', 'Fill'}
    visuals = [n for n in hero if n.tag not in excluded]
    wrapper = obj(hero, 'Node', x=380-64*2.9, y=310-64*2.9, scaleX=2.9, scaleY=2.9, name='Production companion')
    for n in visuals:
        hero.remove(n); wrapper.append(n)
    text(hero, 'MARR / QUIET MOTION', 380, 48, 13, MUTED, True)
    text(hero, 'A little life, in the right moment.', 380, 100, 28, INK, True)
    text(hero, 'Observe. Read. Understand. Settle.', 380, 567, 15, MUTED, True)
    fill(hero, BG)
    # A preview-only state layer labels the externally driven workflow. Native
    # companion geometry, transitions and view-model bindings remain unchanged.
    vm = root.find('ViewModel')
    instance = vm.find('ViewModelInstance')
    property_node = obj(vm, 'ViewModelPropertyNumber', name='previewStage')
    sub(instance, 'ViewModelInstanceNumber', viewModelPropertyId=property_node.get('id'), propertyValue=0)
    labels = [text(hero, stage[0], 180+j*133, 505, 17, INK, True) for j, stage in enumerate(STAGES)]
    sm = hero.find('StateMachine')
    layer = sub(sm, 'StateMachineLayer', name='Workflow labels')
    sub(layer, 'AnyState'); sub(layer, 'ExitState')
    entry = sub(layer, 'EntryState')
    states = []
    for i, stage in enumerate(STAGES):
        anim = obj(hero, 'LinearAnimation', name='Label '+stage[0], duration=1, fps=60, loopValue='oneShot')
        for j, label in enumerate(labels): keys(anim, label, 'opacity', [(0, 1 if i == j else .28)])
        states.append(obj(layer, 'AnimationState', animationId=anim.get('id')))
    sub(entry, 'StateTransition', stateToId=states[0].get('id'))
    for i, state in enumerate(states):
        for j, dest in enumerate(states):
            if i == j: continue
            t = sub(state, 'StateTransition', stateToId=dest.get('id'), duration=180)
            c = sub(t, 'TransitionViewModelCondition', opValue='equal')
            b = sub(sub(c, 'TransitionPropertyViewModelComparator'), 'BindablePropertyNumber')
            sub(b, 'DataBindContext', sourcePathIds=vm.get('id')+'-'+property_node.get('id'), propertyKey=636)
            sub(c, 'TransitionValueNumberComparator', value=j)

    sheet = obj(root, 'Artboard', name='Quiet states', width=1120, height=440)
    style = obj(sheet, 'LayoutComponentStyle', name='Quiet sheet'); sheet.set('styleId', style.get('id'))
    text(sheet, 'MARR / FIVE STATES', 38, 39, 12, MUTED)
    text(sheet, 'Less movement. More meaning.', 38, 86, 30)
    text(sheet, 'One glass companion, responding to real work.', 38, 124, 14, MUTED)
    merged = obj(sheet, 'LinearAnimation', name='Five quiet states', duration=360, fps=60, loopValue='loop')
    static_machine(sheet, merged, 'Five states')
    values = {n.get('id'): n.get('name') for n in src.find('ViewModel').findall('ViewModelPropertyNumber')}
    source_visuals = [n for n in board if n.tag not in excluded]
    for i, (name, title, caption) in enumerate(MOODS):
        cx = 116+i*222
        text(sheet, title, cx, 338, 18, centered=True)
        text(sheet, caption, cx, 370, 12, MUTED, True)
        panel = obj(sheet, 'Node', x=cx-64*1.5, y=241-64*1.5, scaleX=1.5, scaleY=1.5, name=title)
        mapping = {n.get('id'): f'0:{10000*(i+1)+int(n.get("id").split(":")[1])}'
                   for v in source_visuals for n in v.iter() if n.get('id')}
        for visual in source_visuals:
            clone = copy.deepcopy(visual)
            for parent in clone.iter():
                for bind in list(parent):
                    if bind.tag == 'DataBindContext':
                        prop = values.get(bind.get('sourcePathIds', '').split('-')[-1])
                        value = 3 if prop == 'gazeX' and i == 1 else -1 if prop == 'gazeY' and i == 1 else 0
                        attribute = {'13':'x', '14':'y', '18':'opacity'}.get(bind.get('propertyKey'))
                        if attribute: parent.set(attribute, str(value))
                        parent.remove(bind)
                for key, value in list(parent.attrib.items()):
                    if key != 'assetId' and value in mapping: parent.set(key, mapping[value])
            panel.append(clone)
        anim = by_name[name]
        for keyed in anim.findall('KeyedObject'):
            clone = copy.deepcopy(keyed)
            clone.set('objectId', mapping[keyed.get('objectId')])
            # Preserve actual timing; a one-shot settles and holds its last pose.
            merged.append(clone)
    text(sheet, 'Gaze, glass light and pauses — no props or symbols.', 38, 413, 12, MUTED)
    fill(sheet, BG)
    for asset in root:
        if asset.tag.endswith('Asset') and asset.get('file'):
            source = (SOURCE.parent/asset.get('file')).resolve()
            shutil.copy2(source, OUTPUT/'assets'/source.name)
            asset.set('file', 'assets/'+source.name)
    shutil.copy2(ROOT/'DesignAssets/MarrMotionPreview/assets/Inter.ttf', OUTPUT/'assets/Inter.ttf')
    sub(root, 'FontAsset', id='0:999990', name='Inter', file='assets/Inter.ttf')
    E.indent(root, space='  '); E.ElementTree(root).write(OUTPUT/'scene.rml', encoding='unicode')
    (OUTPUT/'rive.yaml').write_text('name: MarrQuietPreview\n')
    (OUTPUT/'preview.command').write_text('#!/bin/zsh\ncd "${0:A:h}"\nexport RIVE_HOME=/tmp/marr-rive-tools\nexec /tmp/marr-rive-tools/bin/rive . --artboard="Translation flow" --data=phase=2 --data=previewStage=2\n')
    (OUTPUT/'preview.command').chmod(0o755)
    print(OUTPUT/'scene.rml', flush=True)


def encode(frames, stem):
    for suffix, extra in [('gif', ['-filter_complex', 'split[a][b];[a]palettegen[p];[b][p]paletteuse', '-loop', '0']),
                          ('mp4', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart'])]:
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '12', '-i', str(frames/'%04d.png'),
                        *extra, str(OUTPUT/f'{stem}.{suffix}')], check=True)
    shutil.copy2(frames/'0012.png', OUTPUT/f'{stem}.png')


def render():
    env = dict(os.environ, RIVE_HOME='/tmp/marr-rive-tools')
    frames = OUTPUT/'flow-frames'; frames.mkdir(exist_ok=True)
    number = 0
    for current, stage in enumerate(STAGES):
        for f in range(stage[5]*12):
            cmd = [str(CLI), str(OUTPUT), '--artboard=Translation flow']
            for j in range(current+1):
                _, phase, scan, x, y, duration = STAGES[j]
                cmd += [f'--data=phase={phase}', f'--data=scan={scan}', f'--data=gazeX={x}',
                        f'--data=gazeY={y}', f'--data=previewStage={j}',
                        f'--advance={f*5 if j==current else duration*60}']
            cmd += [f'--screenshot={frames}/{number:04d}.png']
            subprocess.run(cmd, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            number += 1
        print('Recorded '+stage[0], flush=True)
    encode(frames, 'marr-quiet-flow')
    frames = OUTPUT/'states-frames'; frames.mkdir(exist_ok=True)
    for f in range(72):
        subprocess.run([str(CLI), str(OUTPUT), '--artboard=Quiet states', f'--advance={f*5}',
                        f'--screenshot={frames}/{f:04d}.png'], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    encode(frames, 'marr-quiet-states')
    print('Quiet flow and state sheet exported.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--render', action='store_true')
    args = parser.parse_args()
    author()
    if args.render: render()
