#!/usr/bin/env python3
"""Author the five-state quiet-glass companion; no raster editing or remote assets."""
from pathlib import Path
import runpy
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'DesignAssets/MarrCompanion'
PHASES = ['waiting', 'observing', 'processing', 'settled', 'attention']


def node(parent, tag, **attrs):
    return E.SubElement(parent, tag, {key: str(value) for key, value in attrs.items()})


def solid(parent, color):
    node(node(parent, 'Fill'), 'SolidColor', colorValue=color)


def ellipse(parent, ident, x, y, width, height, name):
    shape = node(parent, 'Shape', id=f'0:{ident}', x=x, y=y, name=name)
    node(shape, 'Ellipse', width=width, height=height)
    return shape


def soft_light(parent, ident, x, y, width, height, color, name):
    shape = ellipse(parent, ident, x, y, width, height, name)
    gradient = node(node(shape, 'Fill'), 'RadialGradient',
                    startX=0, startY=0, endX=width / 2, endY=0)
    node(gradient, 'GradientStop', position=0, colorValue=color)
    node(gradient, 'GradientStop', position=.42, colorValue='10EDF3FA')
    node(gradient, 'GradientStop', position=1, colorValue='00EDF3FA')
    return shape


def keyed(animation, ident, **properties):
    obj = node(animation, 'KeyedObject', objectId=f'0:{ident}')
    for prop, keys in properties.items():
        track = node(obj, 'KeyedProperty', property=prop)
        for frame, value in sorted(dict(keys).items()):
            key = node(track, 'KeyFrameDouble', frame=frame, value=value, interpolationType='cubic')
            node(key, 'CubicEaseInterpolator', x1=.42, y1=0, x2=.58, y2=1)


root = E.Element('Rive', version='1', kind='fragment')
art = node(root, 'Artboard', name='Marr Companion', id='0:2', width=128, height=128,
           styleId='0:5', defaultStateMachineId='0:7', viewModelId='0:40', viewModelInstanceId='0:41')
node(art, 'LayoutComponentStyle', id='0:5', name='Companion bounds')
body = node(art, 'Node', id='0:10', x=64, y=64, name='Glass body')
# Front-to-back paint order. The external aim offset and authored expression are separate.
aim = node(body, 'Node', id='0:16', x=0, y=0, name='EyeAim')
node(aim, 'DataBindContext', sourcePathIds='0:40-0:46', propertyKey=13)
node(aim, 'DataBindContext', sourcePathIds='0:40-0:47', propertyKey=14)
gaze = node(aim, 'Node', id='0:11', x=0, y=-1, name='Gaze')
for index, x in enumerate([-11, 11]):
    pivot = node(gaze, 'Node', id=f'0:{12+index}', x=x, y=0, name=f'Eye {index+1}')
    # Highlights are children of the lid transform, so they close with the eye.
    reflection = ellipse(pivot, 22+index, -1.7, -5.3, 1.7, 3.1, 'Eye reflection')
    solid(reflection, '307D7E78')
    eye = ellipse(pivot, 20+index, 0, 0, 10, 19, 'Dark oval eye')
    gradient = node(node(eye, 'Fill'), 'LinearGradient', startX=-4, startY=-9, endX=4, endY=9)
    for position, color in [(0, 'FF666762'), (.45, 'FF42433F'), (1, 'FF30312E')]:
        node(gradient, 'GradientStop', position=position, colorValue=color)

# All added light stays within the upper hemisphere. Soft edges avoid a separate icon or mouth.
light_group = node(body, 'Node', id='0:30', opacity=0, name='Internal glass light')
soft_light(light_group, 31, -13, -22, 49, 34, '32E8F0FA', 'Soft left refraction')
soft_light(light_group, 32, 12, -15, 43, 31, '24F5FAFF', 'Soft right refraction')
scan_group = node(light_group, 'Node', id='0:33', opacity=0, name='Recognition light strength')
node(scan_group, 'DataBindContext', sourcePathIds='0:40-0:48', propertyKey=18)
soft_light(scan_group, 34, -18, -20, 22, 37, '36F4F8FD', 'Recognition light')
node(body, 'Image', assetId='0:60', scaleX=.112, scaleY=.112, name='Approved glass material')

machine = node(art, 'StateMachine', name='Companion', id='0:7')
layer = node(machine, 'StateMachineLayer', name='Quiet life')
node(layer, 'AnyState', x=0, y=-160)
node(layer, 'ExitState', x=800, y=-160)
node(node(layer, 'EntryState', x=0, y=0), 'StateTransition', stateToId='0:100')
for index, name in enumerate(PHASES):
    state = node(layer, 'AnimationState', id=f'0:{100+index}', animationId=f'0:{300+index}',
                 x=200+index*220, y=0, reset='true')
    for target in range(len(PHASES)):
        if target == index:
            continue
        transition = node(state, 'StateTransition', stateToId=f'0:{100+target}', duration=200,
                          enableEarlyExit='true')
        condition = node(transition, 'TransitionViewModelCondition', opValue='equal')
        value = node(node(condition, 'TransitionPropertyViewModelComparator'), 'BindablePropertyNumber')
        node(value, 'DataBindContext', sourcePathIds='0:40-0:45', propertyKey=636)
        node(condition, 'TransitionValueNumberComparator', value=target)

for index, name in enumerate(PHASES):
    loops = index in [0, 1, 2]
    duration = 360 if loops else 150
    animation = node(art, 'LinearAnimation', id=f'0:{300+index}', name=name,
                     duration=duration, fps=60, loopValue='loop' if loops else 'oneShot')
    body_keys = dict(x=[(0,64)], y=[(0,64)], scaleX=[(0,1)], scaleY=[(0,1)], rotation=[(0,0)])
    gaze_keys = dict(x=[(0,-8)], y=[(0,-1)])
    left_height = right_height = 1
    left_rotation = right_rotation = 0
    light = [(0,0)]
    if index == 0:
        body_keys['scaleY'] = [(0,1), (170,1.006), (300,1), (360,1)]
    elif index == 1:
        # Attentiveness mostly comes from the host-provided gaze rather than wandering eyes.
        body_keys.update(y=[(0,63.7)], scaleX=[(0,1.012)], scaleY=[(0,1.012)], rotation=[(0,-.018)])
        gaze_keys.update(x=[(0,-7.5)], y=[(0,-.5)])
        left_height = right_height = 1.035
        light = [(0,.12)]
    elif index == 2:
        # An almost still outline with internal movement and a thoughtful upward glance.
        body_keys.update(y=[(0,64), (180,63.2), (360,64)], rotation=[(0,-.01), (180,.01), (360,-.01)])
        gaze_keys.update(x=[(0,-8), (130,-6.8), (230,-6.8), (320,-8), (360,-8)],
                         y=[(0,-2.2), (130,-3.6), (230,-3.6), (320,-2.2), (360,-2.2)])
        left_height = right_height = .93
        light = [(0,.6), (165,.9), (285,.6), (360,.6)]
    elif index == 3:
        # One quiet release, then stillness; there is no hop, sparkle or repeated celebration.
        body_keys.update(y=[(0,63.6), (45,64.4), (100,64), (150,64)],
                         scaleX=[(0,1.008), (45,1.002), (100,1), (150,1)],
                         scaleY=[(0,1.01), (45,.994), (100,1), (150,1)])
        gaze_keys.update(y=[(0,-.4), (65,-1), (150,-1)])
        left_height = right_height = .87
        light = [(0,.55), (70,.2), (120,0), (150,0)]
    else:
        # A restrained question: small head tilt and softly asymmetric eyelids.
        body_keys.update(rotation=[(0,-.035), (80,-.028), (150,-.028)], y=[(0,64.3)])
        gaze_keys.update(x=[(0,-8.5)], y=[(0,1)])
        left_height, right_height = .8, .93
        left_rotation, right_rotation = .035, -.02
        light = [(0,.08)]
    keyed(animation, 10, **body_keys)
    # Legacy poses were authored eight units left of the face center. Remove
    # that bias so positive and negative pointer inputs can look both ways.
    gaze_keys['x'] = [(frame, x + 8) for frame, x in gaze_keys['x']]
    keyed(animation, 11, **gaze_keys)
    for ident, height, rotation in [(12,left_height,left_rotation), (13,right_height,right_rotation)]:
        blink = [(0,height)]
        if loops:
            blink_at = 267 if index == 0 else 242 if index == 1 else 275
            blink = [(0,height), (blink_at,height), (blink_at+6,.09), (blink_at+14,height), (360,height)]
        keyed(animation, ident, scaleX=[(0,1)], scaleY=blink, rotation=[(0,rotation)])
    keyed(animation, 30, opacity=light)
    # Each state fully resets the light positions to avoid residue during interrupted transitions.
    if index == 2:
        keyed(animation, 31, x=[(0,-16),(170,-8),(290,-16),(360,-16)],
              y=[(0,-24),(170,-21),(290,-24),(360,-24)], rotation=[(0,-.08),(170,.06),(360,-.08)])
        keyed(animation, 32, x=[(0,15),(170,8),(290,15),(360,15)],
              y=[(0,-14),(170,-18),(290,-14),(360,-14)], rotation=[(0,.08),(170,-.06),(360,.08)])
        keyed(animation, 34, x=[(0,-22),(130,18),(160,18),(195,-22),(325,18),(360,-22)], y=[(0,-21)])
    else:
        keyed(animation, 31, x=[(0,-13)], y=[(0,-22)], rotation=[(0,0)])
        keyed(animation, 32, x=[(0,12)], y=[(0,-15)], rotation=[(0,0)])
        keyed(animation, 34, x=[(0,-18)], y=[(0,-20)])

node(root, 'ImageAsset', id='0:60', file='assets/glass-body.png', name='Approved glass body')
view_model = node(root, 'ViewModel', id='0:40', name='MarrCompanion', defaultInstanceId='0:41')
for ident, name in [(45,'phase'), (46,'gazeX'), (47,'gazeY'), (48,'scan')]:
    node(view_model, 'ViewModelPropertyNumber', id=f'0:{ident}', name=name)
instance = node(view_model, 'ViewModelInstance', id='0:41', name='Default', exports='true')
for ident in [45,46,47,48]:
    node(instance, 'ViewModelInstanceNumber', viewModelPropertyId=f'0:{ident}', propertyValue=0)
E.indent(root, space='  ')
PROJECT.mkdir(parents=True, exist_ok=True)
E.ElementTree(root).write(PROJECT/'scene.rml', encoding='unicode')
(PROJECT/'rive.yaml').write_text('name: MarrCompanion\nlogs:\n  file: build/rive.log\n  problems: build/problems.log\n')
runpy.run_path(str(ROOT/'scripts/package-marr-tool-morphs.py'), run_name='__main__')
functional_tools = runpy.run_path(str(ROOT/'scripts/preview-marr-functional-tools.py'))
functional_tools['author'](source=PROJECT, preview_enabled=False)

# The hero floats; functional tools must keep stable contours while morphing.
# Apply this after cloning the shared base into the tool artboard.
root = E.parse(PROJECT/'scene.rml').getroot()
hero = root.find("Artboard[@name='Marr Companion']")
idle = hero.find("LinearAnimation[@name='waiting']")
idle.remove(idle.find("KeyedObject[@objectId='0:10']"))
keyed(idle, 10, x=[(0,64)],
      y=[(0,64), (150,61.8), (300,64.5), (360,64)],
      rotation=[(0,0), (110,-.025), (260,.025), (360,0)],
      scaleX=[(0,1), (170,.992), (300,1), (360,1)],
      scaleY=[(0,1), (170,1.018), (300,1), (360,1)])
# Host-driven personality is additive to authored moods, and only on the hero.
vm = root.find('ViewModel')
inst = vm.find('ViewModelInstance')
for ident, name, default in [(70,'bodyX',64), (71,'bodyY',64), (72,'bodyTilt',0), (73,'eyeOpen',1)]:
    node(vm, 'ViewModelPropertyNumber', id=f'0:{ident}', name=name)
    node(inst, 'ViewModelInstanceNumber', viewModelPropertyId=f'0:{ident}', propertyValue=default)
body = hero.find("Node[@name='Glass body']")
hero.remove(body)
reaction = node(hero, 'Node', id='0:74', x=64, y=64, name='Curious body reaction')
for ident, key in [(70,13),(71,14),(72,15)]:
    node(reaction, 'DataBindContext', sourcePathIds=f'0:40-0:{ident}', propertyKey=key)
origin = node(reaction, 'Node', id='0:75', x=-64, y=-64, name='Centered reaction pivot')
origin.append(body)
face = next(n for n in body.iter('Node') if n.get('name') == 'Gaze')
eyes = list(face.findall('Node'))
lids = node(face, 'Node', id='0:76', name='Spontaneous blink')
node(lids, 'DataBindContext', sourcePathIds='0:40-0:73', propertyKey=17)
for eye in eyes:
    face.remove(eye)
    lids.append(eye)
E.indent(root, space='  ')
E.ElementTree(root).write(PROJECT/'scene.rml', encoding='unicode')
