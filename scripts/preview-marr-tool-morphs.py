#!/usr/bin/env python3
"""Native Rive recordings of the production morph artboard."""
from pathlib import Path
import argparse, copy, os, shutil, subprocess
import xml.etree.ElementTree as E
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/marr-tool-morphs-v2'
CLI='/tmp/marr-rive-tools/bin/rive'
ENV=dict(os.environ,RIVE_HOME='/tmp/marr-rive-tools')
NEXT=900000


def n(parent,tag,**attrs):
    return E.SubElement(parent,tag,{k:str(v) for k,v in attrs.items()})


def text(parent,value,x,y,size,color):
    global NEXT
    NEXT+=1
    t=n(parent,'Text',id=f'0:{NEXT}',name=value,x=x,y=y,originX=.5,originY=.5)
    NEXT+=1
    s=n(t,'TextStylePaint',id=f'0:{NEXT}',fontSize=size,fontAssetId='0:999990')
    n(n(s,'Fill'),'SolidColor',colorValue=color)
    n(t,'TextValueRun',styleId=s.get('id'),text=value)
    return t


def author(source_path=None):
    OUT.mkdir(exist_ok=True,parents=True); (OUT/'assets').mkdir(exist_ok=True)
    source_path=source_path or ROOT/'DesignAssets/MarrCompanion/scene.rml'
    root=E.parse(source_path).getroot()
    for art in list(root.findall('Artboard')):
        if art.get('name')!='Marr Tool': root.remove(art)
    art=root.find('Artboard'); art.set('name','Tool morph'); art.set('width','720'); art.set('height','560'); art.set('x','0')
    scene_nodes=art.findall('Node')
    for scene_node in scene_nodes: art.remove(scene_node)
    holder=n(art,'Node',x=168,y=58,scaleX=3,scaleY=3)
    holder.extend(scene_nodes)
    text(art,'MARR / LIVING TOOLS',360,52,14,'FF9CA5B4')
    text(art,'Still Marr. Now at work.',360,445,25,'FFF0F3F8')
    text(art,'Gather. Reach. Settle.',360,493,13,'FF909AAA')
    n(n(art,'Fill'),'SolidColor',colorValue='FF181C23')
    for asset in root:
        if asset.get('file'):
            src=source_path.parent/asset.get('file')
            shutil.copy2(src,OUT/'assets'/src.name);asset.set('file','assets/'+src.name)
    shutil.copy2(ROOT/'DesignAssets/MarrMotionPreview/assets/Inter.ttf',OUT/'assets/Inter.ttf')
    n(root,'FontAsset',id='0:999990',file='assets/Inter.ttf',name='Inter')
    E.indent(root,space='  ');E.ElementTree(root).write(OUT/'scene.rml',encoding='unicode')
    (OUT/'rive.yaml').write_text('name: MarrToolMorphPreview\n')
    (OUT/'preview.command').write_text('#!/bin/zsh\ncd "${0:A:h}"\nexport RIVE_HOME=/tmp/marr-rive-tools\nexec /tmp/marr-rive-tools/bin/rive . --data=tool=2\n')
    (OUT/'preview.command').chmod(0o755)


def render(sequence,frame,path):
    command=[CLI,str(OUT)]
    for j,tool in enumerate(sequence):
        command += [f'--data=tool={tool}',f'--advance={int(round(frame)) if j==len(sequence)-1 else 120}']
    subprocess.run(command+[f'--screenshot={path}'],env=ENV,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


def stills():
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda i:render([i],60,OUT/f'form-{i}.png'),range(6)))


def record():
    frames=OUT/'frames';frames.mkdir(exist_ok=True)
    # Two seconds each: the native 700 ms gesture, then a readable held pose.
    sequence=[0,1,0,2,0,4,3,5,0]
    jobs=[]
    for i in range(len(sequence)):
        for f in range(48): jobs.append((sequence[:i+1],f*120/48,frames/f'{i*48+f:04d}.png'))
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda args:render(*args),jobs))
    for ext,options in [('gif',['-filter_complex','split[a][b];[a]palettegen[p];[b][p]paletteuse','-loop','0']),('mp4',['-c:v','libx264','-pix_fmt','yuv420p','-movflags','+faststart'])]:
        subprocess.run(['ffmpeg','-y','-loglevel','error','-framerate','24','-i',str(frames/'%04d.png'),*options,str(OUT/f'marr-tool-morphs.{ext}')],check=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--record',action='store_true');args=parser.parse_args()
    author();stills()
    if args.record:record()
