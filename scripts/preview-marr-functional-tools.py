#!/usr/bin/env python3
"""Functional pen / translation study, preserving the approved selection morph."""
from pathlib import Path
import argparse
import math
import shutil
import subprocess
import xml.etree.ElementTree as E
from concurrent.futures import ThreadPoolExecutor
from fontTools.ttLib import TTFont
from fontTools.pens.basePen import BasePen
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('study', ROOT/'scripts/preview-marr-rounded-tools.py')
study = importlib.util.module_from_spec(spec)
spec.loader.exec_module(study)
tools, preview = study.tools, study.preview
OUT = ROOT/'output/marr-functional-tools-study'


def extra_tracks(animation, target, **properties):
    obj = next((o for o in animation.findall('KeyedObject') if o.get('objectId') == target), None)
    if obj is None:
        tools.keys(animation, target, **properties)
        return
    temporary = E.Element('LinearAnimation')
    tools.keys(temporary, target, **properties)
    for track in temporary.find('KeyedObject'):
        assert not any(p.get('property') == track.get('property') for p in obj)
        obj.append(track)


class OutlinePen(BasePen):
    def __init__(self, glyphs):
        super().__init__(glyphs)
        self.contours = []
    def _moveTo(self, point):
        self.contours.append([point])
    def _lineTo(self, point):
        self.contours[-1].append(point)
    def _qCurveToOne(self, control, end):
        start = self.contours[-1][-1]
        for i in range(1, 9):
            t = i/8
            self._lineTo(tuple((1-t)**2*start[d]+2*t*(1-t)*control[d]+t*t*end[d] for d in (0, 1)))
    def _curveToOne(self, a, b, end):
        start = self.contours[-1][-1]
        for i in range(1, 13):
            t = i/12
            self._lineTo(tuple((1-t)**3*start[d]+3*t*(1-t)**2*a[d]+3*t*t*(1-t)*b[d]+t**3*end[d] for d in (0, 1)))
    def _closePath(self):
        pass
    def _endPath(self):
        pass


def word(parent, value):
    # Export only these demonstration words as native paths; no font is embedded.
    font = TTFont('/System/Library/Fonts/STHeiti Light.ttc', fontNumber=0)
    glyphs, cmap = font.getGlyphSet(), font.getBestCmap()
    names = [cmap[ord(c)] for c in value]
    width = sum(glyphs[name].width for name in names)
    scale = min(57/width, 17/font['head'].unitsPerEm)
    group = tools.node(parent, 'Node', id=tools.ident(), name=value, opacity=0, y=12)
    shape = tools.node(group, 'Shape', name='Word outline')
    advance = -width/2
    for name in names:
        pen = OutlinePen(glyphs)
        glyphs[name].draw(pen)
        for contour in pen.contours:
            path = tools.node(shape, 'PointsPath', isClosed='true')
            for x, y in contour:
                tools.node(path, 'StraightVertex', x=(x+advance)*scale, y=-y*scale)
        advance += glyphs[name].width
    tools.node(tools.node(shape, 'Fill'), 'SolidColor', colorValue='FF424A54')
    font.close()
    return group


def author(source=None, preview_enabled=True):
    source = source or OUT/'.source'
    (source/'assets').mkdir(parents=True, exist_ok=True)
    # The entire body becomes a pencil: parallel barrel, tapered wood and writing tip.
    tools.outlines[1] = [tools.turn(p, -.55) for p in study.rounded_polygon(
        [(-15, -46), (15, -46), (15, 22), (0, 49), (-15, 22)], [.2, .2, .08, .10, .08])]
    tools.outlines[2] = tools.squircle(49, 32, 3.6)
    root = E.parse(ROOT/'DesignAssets/MarrCompanion/scene.rml').getroot()
    for art in list(root.findall('Artboard')):
        if art.get('name') == 'Marr Tool': root.remove(art)
    model = root.find('ViewModel')
    for item in list(model):
        if item.get('name') == 'tool': model.remove(item)
    instance = model.find('ViewModelInstance')
    for item in list(instance):
        if item.get('viewModelPropertyId') == '0:49': instance.remove(item)
    tools.add_tools(root)
    art = next(a for a in root.findall('Artboard') if a.get('name') == 'Marr Tool')
    groups = {g.get('name'): g for g in art.iter('Node')}
    surface = next(s for s in art.iter('Shape') if s.get('name') == 'Continuous glass volume')
    pen_group = groups['pen details']
    for child in list(pen_group): pen_group.remove(child)
    tools.line(pen_group, [tools.turn(p, -.55) for p in [(-13, 23), (13, 23)]], '80545B64', .8)
    tip = tools.node(pen_group, 'Shape', name='Writing tip')
    path = tools.node(tip, 'PointsPath', isClosed='true')
    for p in [(-3.4, 42), (0, 48), (3.4, 42)]:
        x, y = tools.turn(p, -.55)
        tools.node(path, 'StraightVertex', x=x, y=y)
    tools.node(tools.node(tip, 'Fill'), 'SolidColor', colorValue='FF414A54')
    translation = groups['translate details']
    for child in list(translation): translation.remove(child)
    english, chinese = word(translation, 'Hello'), word(translation, '你好')
    scan = tools.node(translation, 'Node', id=tools.ident(), name='Translation passes over the text', opacity=0)
    light = tools.node(scan, 'Shape')
    tools.node(light, 'Rectangle', width=18, height=66)
    tools.gradient(light, 'LinearGradient', [(0, '00FFFFFF'), (.5, 'A0FFFFFF'), (1, '00FFFFFF')], startX=-9, startY=0, endX=9, endY=0)
    for group in (pen_group, translation):
        for shape in group.iter('Shape'):
            tools.node(shape, 'ClippingShape', sourceId=surface.get('id'))
    # A short ink trail is the result of drawing, not an accessory held by the mascot.
    ink = tools.node(art, 'Node', id=tools.ident(), name='Demonstration ink', x=64, y=64, opacity=0)
    line = tools.node(ink, 'Shape')
    path = tools.node(line, 'PointsPath', isClosed='false')
    ink_vertices = [tools.node(path, 'StraightVertex', id=tools.ident(), x=x, y=y)
                    for x, y in [(25, 43), (31, 44), (37, 43)]]
    tools.stroke(line, 'D03A414B', 1.4)
    face, gesture = groups['Face follows gesture'].get('id'), groups['Anticipation and follow through'].get('id')
    for animation in art.findall('LinearAnimation'):
        name = animation.get('name')
        if not name.startswith('form-'): continue
        is_pen, is_translation = name == 'form-pen', name == 'form-translate'
        tools.keys(animation, english.get('id'), opacity=[(0, 0), (24, 0), (34, 1), (55, 1), (65, 0), (90, 0)] if is_translation else 0)
        tools.keys(animation, chinese.get('id'), opacity=[(0, 0), (57, 0), (68, 1), (90, 1)] if is_translation else 0)
        tools.keys(animation, scan.get('id'), opacity=[(0, 0), (36, 0), (42, .7), (67, .7), (76, 0), (90, 0)] if is_translation else 0,
                   x=[(0, -46), (36, -46), (74, 46), (90, 46)] if is_translation else -46)
        tools.keys(animation, ink.get('id'), opacity=[(0, 0), (46, 0), (49, 1), (78, 1)] if is_pen else 0)
        if is_pen:
            animation.set('duration', '78')
            study.track(animation, gesture, 'rotation', [(0, 0), (42, 0), (78, 0)])
            extra_tracks(animation, gesture, x=[(0, 0), (42, 0), (48, 3), (65, 12), (69, 12), (78, 0)])
            study.track(animation, gesture, 'y', [(0, 0), (6, 2), (18, -2.5), (29, .5), (42, 0), (48, 2), (65, 2), (69, -4), (78, 0)])
            study.track(animation, face, 'x', [(0, 2), (6, -1), (42, -1)])
            study.track(animation, face, 'y', [(0, 0), (6, -15), (42, -15)])
            study.track(animation, face, 'scaleX', [(0, 1), (6, .85), (28, .50), (42, .50)])
            study.track(animation, face, 'scaleY', [(0, 1), (6, .80), (28, .66), (42, .66)])
            extra_tracks(animation, face, rotation=[(0, 0), (28, -.55), (42, -.55)])
            for i, vertex in enumerate(ink_vertices):
                tools.keys(animation, vertex.get('id'), x=[(0, 25), (46, 25), (65, 25+i*6), (78, 25+i*6)])
        else:
            extra_tracks(animation, gesture, x=0)
            extra_tracks(animation, face, rotation=0)
        if is_translation:
            animation.set('duration', '90')
            study.track(animation, gesture, 'rotation', [(0, 0), (42, 0), (90, 0)])
            study.track(animation, face, 'x', [(0, 2), (6, 8), (28, 8), (42, 8)])
            study.track(animation, face, 'y', [(0, 0), (6, -10), (28, -21), (42, -21)])
            study.track(animation, face, 'scaleX', [(0, 1), (6, .85), (28, .45), (42, .45)])
            study.track(animation, face, 'scaleY', [(0, 1), (6, .80), (28, .45), (42, .45)])
    for asset in root:
        if asset.get('file'):
            src = ROOT/'DesignAssets/MarrCompanion'/asset.get('file')
            destination = source/'assets'/src.name
            if src.resolve() != destination.resolve():
                shutil.copy2(src, destination)
            asset.set('file', 'assets/'+src.name)
    E.indent(root, space='  ')
    E.ElementTree(root).write(source/'scene.rml', encoding='unicode')
    if not preview_enabled:
        return
    (source/'rive.yaml').write_text('name: MarrFunctionalToolsStudy\n')
    preview.OUT = OUT
    preview.author(source/'scene.rml')
    # The stills show the completed action; selection remains pixel-identical.
    for form in (1, 2, 3): preview.render([form], 100 if form != 3 else 60, OUT/f'form-{form}.png')


def render(sequence, frame, path):
    command = [preview.CLI, str(OUT)]
    for i, tool in enumerate(sequence):
        command += [f'--data=tool={tool}', f'--advance={int(round(frame)) if i == len(sequence)-1 else 180}']
    subprocess.run(command+[f'--screenshot={path}'], env=preview.ENV, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def record():
    frames = OUT/'frames'; frames.mkdir(exist_ok=True)
    sequence = [3, 2, 1, 0]
    jobs = []; index = 0
    for i, form in enumerate(sequence):
        for f in range(48 if form == 0 else 72):
            jobs.append((sequence[:i+1], f*2.5, frames/f'{index:04d}.png'))
            index += 1
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda args: render(*args), jobs))
    for ext, options in [('gif', ['-filter_complex', 'split[a][b];[a]palettegen[p];[b][p]paletteuse', '-loop', '0']),
                         ('mp4', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart'])]:
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '24', '-i', str(frames/'%04d.png'),
                        *options, str(OUT/f'functional-tools.{ext}')], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    author()
    if args.record: record()
