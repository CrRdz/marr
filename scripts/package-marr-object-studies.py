#!/usr/bin/env python3
"""Author foreground-object Rive studies; generated bitmaps remain untouched."""
from pathlib import Path
import copy
import math
import shutil
import xml.etree.ElementTree as E
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'DesignAssets/MarrObjectStudies'
ASSETS = PROJECT / 'assets'
counter = 100


def el(parent, tag, **attrs):
    return E.SubElement(parent, tag, {k: str(v) for k, v in attrs.items()})


def obj(parent, tag, **attrs):
    global counter
    counter += 1
    return el(parent, tag, id=f'0:{counter}', **attrs)


def solid(parent, color):
    el(el(parent, 'Fill'), 'SolidColor', colorValue=color)


def gradient(parent, stops, start=(-20, -20), end=(20, 20)):
    g = el(el(parent, 'Fill'), 'LinearGradient', startX=start[0], startY=start[1], endX=end[0], endY=end[1])
    for position, color in stops:
        el(g, 'GradientStop', position=position, colorValue=color)


def ellipse(parent, x, y, w, h, color, **attrs):
    n = obj(parent, 'Shape', x=x, y=y, **attrs)
    el(n, 'Ellipse', width=w, height=h)
    if color: solid(n, color)
    return n


def keys(anim, node, **props):
    keyed = el(anim, 'KeyedObject', objectId=node.get('id'))
    for prop, pairs in props.items():
        track = el(keyed, 'KeyedProperty', property=prop)
        for f, v in pairs:
            key = el(track, 'KeyFrameDouble', frame=f, value=v, interpolationType='cubic')
            el(key, 'CubicEaseInterpolator', x1=.42, y1=0, x2=.58, y2=1)


def text(art, value, x, y, size, color='FFE8EBF0', center=False):
    node = obj(art, 'Text', x=x, y=y, originX=.5 if center else 0, originY=.5, name=value)
    style = obj(node, 'TextStylePaint', fontSize=size, fontAssetId='0:900003')
    solid(style, color)
    el(node, 'TextValueRun', styleId=style.get('id'), text=value)


def image_at(parent, asset, filename, width, x=0, y=0):
    """Only read alpha bounds to fit a prop; never modify its pixels."""
    with Image.open(ASSETS / filename) as image:
        alpha = image.getchannel('A')
        box = alpha.point(lambda a: 255 if a > 32 else 0).getbbox()
        scale = width / (box[2] - box[0])
        center_x = (box[0] + box[2]) / 2
        center_y = (box[1] + box[3]) / 2
        offset_x = (image.width / 2 - center_x) * scale
        offset_y = (image.height / 2 - center_y) * scale
    return obj(parent, 'Image', assetId=asset, x=x+offset_x, y=y+offset_y,
               scaleX=scale, scaleY=scale, name=filename)


def state_machine(art, name):
    sm = obj(art, 'StateMachine', name=name)
    art.set('defaultStateMachineId', sm.get('id'))
    layer = el(sm, 'StateMachineLayer', name='Physical scene')
    el(layer, 'AnyState'); el(layer, 'ExitState')
    entry = el(layer, 'EntryState')
    state = obj(layer, 'AnimationState')
    el(entry, 'StateTransition', stateToId=state.get('id'))
    anim = obj(art, 'LinearAnimation', name='Read, inspect, compose', duration=360, fps=60, loopValue='loop')
    state.set('animationId', anim.get('id'))
    return anim


def paper_turn(parent, anim):
    # A thin pearl-glass leaf flexes around the spine; a refractive edge retains its shape.
    leaf = obj(parent, 'Node', name='Turning translucent glass leaf', opacity=0)
    shape = obj(leaf, 'Shape', name='Curved pearl-glass face')
    path = el(shape, 'PointsPath', isClosed='true')
    for x, y, incoming, outgoing, din, dout in [
        (0, -27, 1.57, -.55, 0, 23), (64, -49, 3.0, .06, 24, 24),
        (126, -44, 3.14, 1.67, 16, 17), (121, 11, -1.57, 3.0, 18, 25),
        (57, 18, -.1, 2.8, 26, 25), (0, 40, -.6, -1.57, 18, 0)]:
        el(path, 'CubicDetachedVertex', x=x, y=y, inRotation=incoming, outRotation=outgoing,
           inDistance=din, outDistance=dout)
    gradient(shape, [(0, 'BEB9C4D5'), (.24, 'D8F2F6FC'), (.55, '82C9D2E1'),
                     (.78, 'BAE8EDF5'), (1, '8A7D8B9F')], (0, 0), (126, -10))
    stroke = el(shape, 'Stroke', thickness=.8)
    edge = el(stroke, 'LinearGradient', startX=0, startY=-35, endX=126, endY=25)
    for pos, col in [(0, 'D0F8FBFF'), (.55, '70B9D2F4'), (1, 'B6E1EBFC')]:
        el(edge, 'GradientStop', position=pos, colorValue=col)
    keys(anim, leaf, opacity=[(0, 0), (167, 0), (175, .95), (222, .95), (238, 0), (360, 0)],
         scaleX=[(0, 1), (170, 1), (197, .06), (231, -.98), (240, -.98), (250, 1), (360, 1)],
         scaleY=[(0, 1), (170, 1), (197, 1.28), (231, 1), (360, 1)])


def lens(parent, anim):
    group = obj(parent, 'Node', x=-45, y=39, rotation=-.25, name='Physical magnifying glass')
    # Front-to-back paint order: glint, thick beveled glass rim, lens, glass handle, shadow.
    glint = ellipse(group, -12, -13, 24, 5, 'A0F5F8FF', rotation=-.7)
    outer = ellipse(group, 0, 0, 64, 64, None, name='Thick smoky glass rim')
    stroke = el(outer, 'Stroke', thickness=7.5)
    g = el(stroke, 'LinearGradient', startX=-28, startY=-28, endX=28, endY=28)
    for pos, col in [(0, 'DDEBF2FD'), (.22, '92717D90'), (.43, 'EFF8FAFF'),
                     (.69, '887B8AA0'), (1, 'CFBACDEC')]:
        el(g, 'GradientStop', position=pos, colorValue=col)
    inner = ellipse(group, 0, 0, 56, 56, None)
    el(el(inner, 'Stroke', thickness=1.2), 'SolidColor', colorValue='B5E7F0FF')
    ellipse(group, 0, 0, 53, 53, '28C2D5EF', name='Transparent glass lens')
    handle = obj(group, 'Shape', x=35, y=39, rotation=-.68, name='Rounded translucent glass handle')
    el(handle, 'Rectangle', width=15, height=56, cornerRadiusTL=7.5, cornerRadiusTR=7.5,
       cornerRadiusBL=7.5, cornerRadiusBR=7.5)
    gradient(handle, [(0, 'D4F1F6FF'), (.22, 'ADCFDAEC'), (.5, '846C788D'),
                      (.8, 'B3D6E0F1'), (1, 'D8F5F8FE')], (-8, 0), (8, 0))
    el(el(handle, 'Stroke', thickness=.9), 'SolidColor', colorValue='98E5EFFF')
    keys(anim, glint, opacity=[(0, .65), (155, .95), (290, .65), (360, .65)])
    ellipse(group, 3, 4, 69, 69, '22000000', name='Lens contact shadow')
    keys(anim, group, x=[(0, -65), (85, 6), (155, 51), (220, -8), (290, -65), (360, -65)],
         y=[(0, 37), (85, 23), (155, 34), (220, 49), (290, 37), (360, 37)],
         rotation=[(0, -.25), (155, -.06), (290, -.25), (360, -.25)])


def vignette(art, anim, index, cx, cy):
    group = obj(art, 'Node', x=cx, y=cy, name=['Read a real book', 'Inspect the page', 'Work at a laptop'][index])
    if index == 1: lens(group, anim)
    # Foreground prop appears before the sphere in Rive's front-to-back paint order.
    prop = obj(group, 'Node', x=0, y=47 if index < 2 else 61, name='Foreground physical prop')
    if index == 0: paper_turn(prop, anim)
    image_at(prop, '0:900001' if index < 2 else '0:900002', 'open-book-glass.png' if index < 2 else 'laptop-glass.png',
             295 if index < 2 else 280)
    if index < 2:
        keys(anim, prop, rotation=[(0, -.018 if index == 0 else .035), (170, -.008 if index == 0 else .035),
                                  (235, .012 if index == 0 else .028), (310, -.018 if index == 0 else .035),
                                  (360, -.018 if index == 0 else .035)])
    else:
        keys(anim, prop, y=[(0, 61), (28, 61.7), (45, 61), (68, 61.7), (82, 61), (108, 61.7),
                           (123, 61), (170, 61), (190, 61.7), (210, 61), (260, 61), (360, 61)])
    body = obj(group, 'Node', x=0, y=-35, name='Glass companion behind prop')
    gaze = obj(body, 'Node', x=-15, y=6, name='Eyes directed at the object')
    eye_nodes = []
    for x in [-22, 22]:
        eye = ellipse(gaze, x, 0, 19, 35, None)
        gradient(eye, [(0, 'FF6A6C64'), (.4, 'FF444740'), (1, 'FF2E342E')], (-8, -16), (8, 16))
        eye_nodes.append(eye)
    obj(body, 'Image', assetId='0:900000', scaleX=.224, scaleY=.224, name='Approved glass body')
    keys(anim, body, y=[(0, -35), (105, -38), (170, -35), (235, -33), (300, -35), (360, -35)],
         rotation=[(0, -.025 if index != 2 else .02), (160, .025 if index != 2 else -.02),
                   (300, -.025 if index != 2 else .02), (360, -.025 if index != 2 else .02)])
    if index == 0:
        keys(anim, gaze, x=[(0, -25), (65, 1), (80, -25), (143, 1), (167, -12), (238, -25), (295, 1), (315, -25), (360, -25)],
             y=[(0, 7), (65, 7), (80, 11), (143, 11), (167, 5), (238, 7), (360, 7)])
    elif index == 1:
        keys(anim, gaze, x=[(0, -27), (85, -12), (155, 3), (220, -13), (290, -27), (360, -27)],
             y=[(0, 10), (85, 7), (155, 10), (220, 12), (290, 10), (360, 10)])
    else:
        keys(anim, gaze, x=[(0, -14), (90, -3), (140, -14), (205, -3), (260, -14), (360, -14)],
             y=[(0, 8), (90, 8), (135, 3), (180, 8), (360, 8)])
    for j, eye in enumerate(eye_nodes):
        keys(anim, eye, scaleY=[(0, .88 if index != 1 else .76), (133+j*3, .88 if index != 1 else .76),
                               (140+j*3, .09), (148+j*3, .88 if index != 1 else .76),
                               (302, .88 if index != 1 else .76), (309, .09),
                               (317, .88 if index != 1 else .76), (360, .88 if index != 1 else .76)])
    ellipse(group, 0, 145 if index == 2 else 110, 245, 20, '22000000', name='Grounding shadow')
    return group


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    for name in ['open-book-glass.png', 'laptop-glass.png']:
        if not (ASSETS / name).exists(): raise SystemExit(f'Missing generated asset: {name}')
    shutil.copy2(ROOT/'DesignAssets/MarrCompanion/assets/glass-body.png', ASSETS/'glass-body.png')
    shutil.copy2(ROOT/'DesignAssets/MarrMotionPreview/assets/Inter.ttf', ASSETS/'Inter.ttf')
    root = E.Element('Rive', version='1', kind='fragment')
    art = obj(root, 'Artboard', name='Marr object studies', width=1200, height=730)
    layout = obj(art, 'LayoutComponentStyle', name='Physical vignette board')
    art.set('styleId', layout.get('id'))
    text(art, 'MARR / AT WORK', 46, 42, 14, 'FFAAB1BD')
    text(art, 'A little companion. Real things to do.', 46, 98, 36)
    text(art, 'Reading, looking closer, and putting thoughts into words.', 46, 143, 17, 'FFB8C0CD')
    text(art, 'Glass object studies / Native Rive', 46, 689, 14, 'FFA4AEBC')
    text(art, 'Two eyes. No mouth.', 1154, 689, 14, 'FFA4AEBC', center=False)
    # Keep the footer at a safe right margin without relying on text width.
    art[-1].set('x', '955')
    anim = state_machine(art, 'Object studies')
    titles = [('Read & translate', 'One passage at a time.'), ('Look a little closer', 'Find the word that matters.'),
              ('Put it into words', 'A small desk. A thoughtful reply.')]
    groups = []
    for index, cx in enumerate([230, 600, 970]):
        text(art, f'0{index+1}', cx-143, 216, 13, 'FFB8C2CF')
        text(art, titles[index][0], cx, 552, 23, center=True)
        text(art, titles[index][1], cx, 590, 16, 'FFADB9CA', center=True)
        groups.append(vignette(art, anim, index, cx, 350))
        panel = obj(art, 'Shape', x=cx, y=413, name='Quiet stage')
        el(panel, 'Rectangle', width=346, height=458, cornerRadiusTL=24, cornerRadiusTR=24,
           cornerRadiusBL=24, cornerRadiusBR=24)
        gradient(panel, [(0, 'FF30353D'), (1, 'FF242830')], (0, -220), (0, 220))
    solid(art, 'FF191C22')
    # A second artboard presents the reading scene at reviewable hero scale.
    hero = obj(root, 'Artboard', name='Translation detail', width=640, height=640)
    layout = obj(hero, 'LayoutComponentStyle', name='Reading detail')
    hero.set('styleId', layout.get('id'))
    text(hero, 'MARR / READ & TRANSLATE', 320, 50, 15, 'FFADB9CA', center=True)
    text(hero, 'Lost in a good translation.', 320, 99, 27, center=True)
    text(hero, 'A real book. A curious pair of eyes.', 320, 582, 16, 'FFADB9CA', center=True)
    hero_anim = state_machine(hero, 'Reading')
    clone = copy.deepcopy(groups[0])
    mapping = {}
    for node in clone.iter():
        if node.get('id'):
            mapping[node.get('id')] = '0:' + str(int(node.get('id').split(':')[1])+10000)
    for node in clone.iter():
        for key, val in list(node.attrib.items()):
            if key != 'assetId' and val in mapping: node.set(key, mapping[val])
    clone.set('x', '320'); clone.set('y', '351'); clone.set('scaleX', '1.5'); clone.set('scaleY', '1.5')
    hero.append(clone)
    for keyed in anim.findall('KeyedObject'):
        if keyed.get('objectId') in mapping:
            item = copy.deepcopy(keyed)
            item.set('objectId', mapping[keyed.get('objectId')])
            hero_anim.append(item)
    solid(hero, 'FF252A33')
    for ident, name, kind in [('900000', 'glass-body.png', 'ImageAsset'), ('900001', 'open-book-glass.png', 'ImageAsset'),
                              ('900002', 'laptop-glass.png', 'ImageAsset'), ('900003', 'Inter.ttf', 'FontAsset')]:
        el(root, kind, id='0:'+ident, file='assets/'+name, name=name)
    E.indent(root, space='  ')
    E.ElementTree(root).write(PROJECT/'scene.rml', encoding='unicode')
    (PROJECT/'rive.yaml').write_text('name: MarrObjectStudies\n')
    (PROJECT/'.gitignore').write_text('build/\n')
    print(PROJECT/'scene.rml')


if __name__ == '__main__': main()
