#!/usr/bin/env python3
"""Design study derived from the approved selection morph; no production writes."""
from pathlib import Path
import argparse
import importlib.util
import math
import shutil
import subprocess
import xml.etree.ElementTree as E
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/marr-rounded-tools-study'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tools = load('tool_shapes', 'package-marr-tool-morphs.py')
preview = load('tool_preview', 'preview-marr-tool-morphs.py')


def rounded_polygon(points, rounding=.3):
    """Rounded geometric silhouettes sampled on the same rays as the approved box."""
    dense = []
    for i, p in enumerate(points):
        before, after = points[i-1], points[(i+1) % len(points)]
        amount = rounding[i] if isinstance(rounding, (list, tuple)) else rounding
        a = tuple(p[d]*(1-amount)+before[d]*amount for d in (0, 1))
        b = tuple(p[d]*(1-amount)+after[d]*amount for d in (0, 1))
        for step in range(33):
            t = step/32
            dense.append(tuple((1-t)**2*a[d]+2*t*(1-t)*p[d]+t*t*b[d] for d in (0, 1)))
    cross = lambda a, b: a[0]*b[1]-a[1]*b[0]
    outline = []
    for i in range(tools.COUNT):
        angle = i*2*math.pi/tools.COUNT
        direction = (math.sin(angle), -math.cos(angle))
        hits = []
        for p, q in zip(dense, dense[1:]+dense[:1]):
            edge = (q[0]-p[0], q[1]-p[1])
            denominator = cross(direction, edge)
            if abs(denominator) < 1e-8:
                continue
            distance = cross(p, edge)/denominator
            along = cross(p, direction)/denominator
            if distance > 0 and 0 <= along <= 1:
                hits.append(distance)
        assert hits, (i, points)
        outline.append(tuple(min(hits)*d for d in direction))
    return outline


def track(animation, target, prop, values):
    obj = next(o for o in animation.findall('KeyedObject') if o.get('objectId') == target)
    old = next(p for p in obj if p.get('property') == prop)
    obj.remove(old)
    temporary = E.Element('LinearAnimation')
    tools.keys(temporary, target, **{prop: values})
    obj.append(temporary.find('KeyedObject/KeyedProperty'))


def author():
    source = OUT / '.source'
    (source / 'assets').mkdir(parents=True, exist_ok=True)
    pen = [(x*(1-.32*(max(0, y)/47)**2), y) for x, y in tools.squircle(25, 47, 3.6)]
    tools.outlines[1] = [tools.turn(p, -.22) for p in pen]
    tools.outlines[2] = tools.squircle(49, 32, 3.6)
    # Index 3 is deliberately untouched: the approved selection geometry and timeline.
    tools.outlines[4] = rounded_polygon([(-38, -23), (49, -43), (22, 42)], .28)
    tools.outlines[5] = rounded_polygon([(0, -43), (37, -23), (37, 23),
                                         (0, 43), (-37, 23), (-37, -23)], .32)
    root = E.parse(ROOT / 'DesignAssets/MarrCompanion/scene.rml').getroot()
    for art in list(root.findall('Artboard')):
        if art.get('name') == 'Marr Tool':
            root.remove(art)
    model = root.find('ViewModel')
    for item in list(model):
        if item.get('name') == 'tool':
            model.remove(item)
    instance = model.find('ViewModelInstance')
    for item in list(instance):
        if item.get('viewModelPropertyId') == '0:49':
            instance.remove(item)
    tools.add_tools(root)
    art = next(a for a in root.findall('Artboard') if a.get('name') == 'Marr Tool')
    surface = next(s for s in art.iter('Shape') if s.get('name') == 'Continuous glass volume')
    groups = {g.get('name'): g for g in art.iter('Node')}
    pen_group = groups['pen details']
    for child in list(pen_group):
        pen_group.remove(child)
    for x in (-7, 7):
        points = [tools.turn((x, 31), -.22), tools.turn((x*.85, 42), -.22)]
        tools.line(pen_group, points, 'A03A414B', 1.5)
    translation = groups['translate details']
    for language in translation.findall('Node'):
        language.set('x', '-36' if language.get('name') == 'Language A' else '36')
        language.set('y', '2')
        language.set('scaleX', '.38')
        language.set('scaleY', '.38')
    arrow = groups['arrow details']
    for child in list(arrow):
        arrow.remove(child)
    # A tiny inset corner follows the tip; the whole body carries direction.
    tools.line(arrow, [(25, -27), (33, -29), (30, -20)], '803A414B', 1.4)
    number = groups['number details'].find('Node')
    number.set('x', '22'); number.set('y', '18')
    for group in (pen_group, arrow):
        for shape in group.iter('Shape'):
            tools.node(shape, 'ClippingShape', sourceId=surface.get('id'))
    face = groups['Face follows gesture'].get('id')
    gesture = groups['Anticipation and follow through'].get('id')
    for name, fx, fy in [('pen', 5, -10), ('translate', 8, -1), ('arrow', 14, -6), ('number', 8, -3)]:
        animation = next(a for a in art.findall('LinearAnimation') if a.get('name') == 'form-'+name)
        track(animation, face, 'x', [(0, 2), (6, fx), (25, fx), (42, fx)])
        track(animation, face, 'y', [(0, 0), (6, fy), (25, fy), (42, fy)])
        track(animation, gesture, 'rotation', [(0, 0), (6, 0), (19, 0), (29, 0), (42, 0)])
    for asset in root:
        if asset.get('file'):
            src = ROOT / 'DesignAssets/MarrCompanion' / asset.get('file')
            shutil.copy2(src, source / 'assets' / src.name)
            asset.set('file', 'assets/'+src.name)
    E.indent(root, space='  ')
    E.ElementTree(root).write(source / 'scene.rml', encoding='unicode')
    (source / 'rive.yaml').write_text('name: MarrRoundedToolsStudy\n')
    # Reuse presentation layout, retaining identical framing for the approved box.
    preview.OUT = OUT
    preview.author(source / 'scene.rml')
    preview.stills()


def record():
    frames = OUT / 'frames'
    frames.mkdir(exist_ok=True)
    # Show the approved baseline first, then direct comparisons with the new family.
    sequence = [0, 3, 0, 2, 0, 1, 0, 4, 0, 5, 0]
    jobs = [(sequence[:i+1], f*120/32, frames/f'{i*32+f:04d}.png')
            for i in range(len(sequence)) for f in range(32)]
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda args: preview.render(*args), jobs))
    for ext, options in [('gif', ['-filter_complex', 'split[a][b];[a]palettegen[p];[b][p]paletteuse', '-loop', '0']),
                         ('mp4', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart'])]:
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '16', '-i', str(frames/'%04d.png'),
                        *options, str(OUT/f'rounded-tools.{ext}')], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    author()
    if args.record:
        record()
