#!/usr/bin/env python3
"""Add an editable, vector-glass tool artboard to the quiet companion source.
All silhouettes share 96 vertices. Native state transitions interpolate geometry,
reflections and tool details; there are no raster swaps or scripts at runtime.
"""
from pathlib import Path
import copy
import math
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT/'DesignAssets/MarrCompanion/scene.rml'
FORMS = ['orb', 'pen', 'translate', 'rectangle', 'arrow', 'number']
COUNT = 96
NEXT = 20000


def node(parent, tag, **attrs):
    return E.SubElement(parent, tag, {k:str(v) for k,v in attrs.items()})


def ident():
    global NEXT
    NEXT += 1
    return f'0:{NEXT}'


def keys(animation, target, **properties):
    obj=node(animation,'KeyedObject',objectId=target)
    for prop,value in properties.items():
        track=node(obj,'KeyedProperty',property=prop)
        samples=value if isinstance(value,list) else [(0,value)]
        for frame,v in samples:
            key=node(track,'KeyFrameDouble',frame=frame,value=round(v,5),interpolationType='cubic')
            node(key,'CubicEaseInterpolator',x1=.32,y1=0,x2=.22,y2=1)


def gradient(shape, kind, stops, **attrs):
    paint=node(shape, 'Fill')
    g=node(paint, kind, **attrs)
    for position,color in stops: node(g,'GradientStop',position=position,colorValue=color)
    return g


def stroke(shape, color, thickness=1):
    node(node(shape,'Stroke',thickness=thickness,cap='round',join='round'), 'SolidColor',colorValue=color)


def sample(points):
    # Closed Catmull-Rom, then equal arc-length samples for predictable correspondence.
    dense=[]
    for i,p1 in enumerate(points):
        p0,p2,p3=points[i-1],points[(i+1)%len(points)],points[(i+2)%len(points)]
        for j in range(24):
            t=j/24
            dense.append(tuple(.5*((2*p1[d])+(-p0[d]+p2[d])*t+
                (2*p0[d]-5*p1[d]+4*p2[d]-p3[d])*t*t+
                (-p0[d]+3*p1[d]-3*p2[d]+p3[d])*t*t*t) for d in [0,1]))
    dense.append(dense[0]); lengths=[0]
    for a,b in zip(dense,dense[1:]): lengths.append(lengths[-1]+math.dist(a,b))
    out=[]; j=0
    for i in range(COUNT):
        distance=lengths[-1]*i/COUNT
        while lengths[j+1]<distance: j+=1
        f=(distance-lengths[j])/(lengths[j+1]-lengths[j])
        out.append(tuple(dense[j][d]*(1-f)+dense[j+1][d]*f for d in [0,1]))
    return out


def turn(point, angle=math.pi/4):
    x,y=point
    return (x*math.cos(angle)-y*math.sin(angle), x*math.sin(angle)+y*math.cos(angle))


def squircle(a,b,n=4):
    return [(a*math.copysign(abs(math.sin(t))**(2/n),math.sin(t)),
             -b*math.copysign(abs(math.cos(t))**(2/n),math.cos(t)))
            for t in [i*2*math.pi/COUNT for i in range(COUNT)]]


def droplet(direction, extension, width, rx=40, ry=40):
    # Match every vertex by polar angle. Most of the character's body stays round;
    # only a local patch of glass is pulled into a functional tip.
    result=[]
    for i in range(COUNT):
        t=i*2*math.pi/COUNT
        d=math.atan2(math.sin(t-direction),math.cos(t-direction))
        pull=extension*math.exp(-.5*(d/width)**2)
        result.append(((rx+pull)*math.sin(t),(ry+pull)*-math.cos(t)))
    return result


def conversation():
    # A fused pair of round speech volumes with a shallow waist, not flat cards.
    circles=[(-18,-4,34),(18,4,34)]
    result=[]
    for i in range(COUNT):
        t=i*2*math.pi/COUNT; dx,dy=math.sin(t),-math.cos(t)
        radii=[]
        for cx,cy,r in circles:
            projection=cx*dx+cy*dy
            radii.append(projection+math.sqrt(r*r-cx*cx-cy*cy+projection*projection))
        radius=max(radii)
        result.append((radius*dx,radius*dy))
    # Smooth only the seam in the union; preserve the rounded silhouette.
    for _ in range(3):
        result=[tuple((result[i-1][d]+2*p[d]+result[(i+1)%COUNT][d])/4 for d in [0,1]) for i,p in enumerate(result)]
    return result


outlines = [
    [(44*math.sin(i*2*math.pi/COUNT),-44*math.cos(i*2*math.pi/COUNT)) for i in range(COUNT)],
    droplet(2.38,22,.19,39,38),
    conversation(),
    squircle(41,35,3.6),
    droplet(.78,23,.23,38,38),
    squircle(37,41,2.7)
]


def line(parent, points, color, width=1.8):
    shape=node(parent,'Shape',name='Etched detail')
    path=node(shape,'PointsPath',isClosed='false')
    for x,y in points: node(path,'StraightVertex',x=x,y=y)
    stroke(shape,color,width)
    return shape


def add_tools(root):
    original=next(a for a in root.findall('Artboard') if a.get('name')=='Marr Companion')
    art=copy.deepcopy(original)
    mapping={n.get('id'):f'0:{int(n.get("id").split(":")[1])+10000}' for n in art.iter() if n.get('id')}
    for n in art.iter():
        for k,v in list(n.attrib.items()):
            if v in mapping: n.set(k,mapping[v])
    art.set('name','Marr Tool')
    art.set('x','180')
    art.set('y','0')
    root.insert(1,art)
    body=next(n for n in art.iter('Node') if n.get('name')=='Glass body')
    for img in list(body.findall('Image')): body.remove(img)
    # Tool anatomy remains part of the character. The face is never replaced by a glyph.
    aim=next(n for n in body.iter('Node') if n.get('name')=='EyeAim')
    gaze=aim.find('Node');aim.remove(gaze)
    face=node(aim,'Node',id=ident(),name='Face follows gesture');face.append(gaze)
    details=node(body,'Node',name='Small functional details')
    detail_groups=[]
    for name in FORMS[1:]:
        group=node(details,'Node',id=ident(),name=name+' details',opacity=0)
        detail_groups.append(group)
    pen,translation,rectangle,arrow,number=detail_groups
    ink='D03A414B'
    # A short nib grows from the rounded body. No long slit through its face.
    line(pen,[(29,27),(39,40)],ink,1.5)
    line(pen,[(26,30),(39,40)],'A0FFFFFF',1.3)
    tip=node(pen,'Shape',x=39,y=40)
    node(tip,'Ellipse',width=3.2,height=3.2)
    node(node(tip,'Fill'),'SolidColor',colorValue='FF414750')
    # Discreet language marks sit on the outer lower cheeks, away from the face.
    latin=node(translation,'Node',x=-30,y=16,scaleX=.32,scaleY=.32,name='Language A')
    line(latin,[(-10,10),(-2,-10),(2,-10),(10,10)],ink,3)
    line(latin,[(-6,3),(6,3)],ink,3)
    han=node(translation,'Node',x=30,y=23,scaleX=.32,scaleY=.32,name='Language Wen')
    line(han,[(0,-12),(0,-8)],ink,3)
    line(han,[(-12,-5),(12,-5)],ink,3)
    line(han,[(-7,-3),(-2,5),(7,12),(12,14)],ink,3)
    line(han,[(7,-3),(3,5),(-6,12),(-12,14)],ink,3)
    # Selection corners frame the character itself rather than a pasted rectangle.
    for x,y,sx,sy in [(-27,-23,1,1),(27,-23,-1,1),(-27,23,1,-1),(27,23,-1,-1)]:
        line(rectangle,[(x,y+sy*7),(x,y),(x+sx*7,y)],'A03A414B',1.6)
    line(arrow,[(33,-25),(41,-42),(25,-33)],'A03A414B',1.3)
    tag=node(number,'Node',x=23,y=23,scaleX=.38,scaleY=.38,name='Number mark')
    for points in [[(-4,-13),(-8,13)],[(8,-13),(4,13)],[(-13,-4),(14,-4)],[(-15,5),(12,5)]]:
        line(tag,points,ink,2.6)

    geometry=[]
    def shell(parent, name, factor=1):
        shape=node(parent,'Shape',id=ident(),name=name)
        path=node(shape,'PointsPath',isClosed='true',isClockwise='true')
        vertices=[]
        for x,y in outlines[0]:
            v=node(path,'StraightVertex',id=ident(),x=x*factor,y=y*factor)
            vertices.append(v.get('id'))
        geometry.append((vertices,factor))
        return shape

    # First-declared is frontmost. Each optical layer follows the same silhouette.
    rim=shell(body,'Sharp cool glass edge')
    paint=node(rim,'Stroke',thickness=.85)
    g=node(paint,'LinearGradient',startX=-37,startY=-42,endX=35,endY=44)
    for p,c in [(0,'FFF5F8FF'),(.22,'FF98A0AF'),(.48,'E0FFFFFF'),(.72,'FF879BBC'),(1,'FFDCE7FF')]:
        node(g,'GradientStop',position=p,colorValue=c)
    inside=shell(body,'Inner bevel',.968)
    paint=node(inside,'Stroke',thickness=.85)
    g=node(paint,'LinearGradient',startX=0,startY=-44,endX=0,endY=44)
    for p,c in [(0,'A0FFFFFF'),(.3,'10FFFFFF'),(.65,'20B9C9DD'),(1,'D0FFFFFF')]:
        node(g,'GradientStop',position=p,colorValue=c)
    surface=shell(body,'Continuous glass volume')
    gradient(surface,'LinearGradient',[(0,'FF424A58'),(.17,'FF596475'),(.36,'FF8B96A7'),(.51,'FFD8DFE9'),(.7,'FFF7F8FC'),(.9,'FFE8EDF8'),(1,'FFB6C9E9')],startX=0,startY=-46,endX=0,endY=46)
    gradient(surface,'RadialGradient',[(0,'B0FFFFFF'),(.4,'50FFFFFF'),(1,'00FFFFFF')],startX=-27,startY=-34,endX=3,endY=-7)
    gradient(surface,'RadialGradient',[(0,'50FFFFFF'),(.5,'10FFFFFF'),(1,'00FFFFFF')],startX=36,startY=3,endX=64,endY=22)
    # The broad reflection is also a vertex-morphed patch, not a stretched PNG.
    reflection=node(body,'Shape',id=ident(),name='Softbox reflection')
    body.remove(reflection); body.insert(list(body).index(rim),reflection)
    patch=node(reflection,'PointsPath',isClosed='true')
    patch_vertices=[]
    # A curved softbox reflection, tapered by an oval contour rather than a ring.
    specs=[]
    for i in range(64):
        t=i*2*math.pi/64
        u,v=22*math.cos(t),10*math.sin(t)
        x=-16+u*math.cos(-.6)-v*math.sin(-.6)
        y=-25+u*math.sin(-.6)+v*math.cos(-.6)
        angle=math.atan2(x,-y)%(2*math.pi)
        specs.append((angle/(2*math.pi)*COUNT,math.hypot(x,y)/44))
    def projected(outline, index, factor):
        a=int(index)%COUNT; b=(a+1)%COUNT; f=index-int(index)
        return tuple((outline[a][d]*(1-f)+outline[b][d]*f)*factor for d in [0,1])
    for j,factor in specs:
        x,y=projected(outlines[0],j,factor)
        v=node(patch,'StraightVertex',id=ident(),x=x,y=y)
        patch_vertices.append(v.get('id'))
    gradient(reflection,'LinearGradient',[(0,'D0FFFFFF'),(.45,'70FFFFFF'),(1,'00FFFFFF')],startX=-32,startY=-38,endX=1,endY=-10)
    gradient(surface,'RadialGradient',[(0,'44363F54'),(.55,'10363F54'),(1,'00363F54')],startX=17,startY=-29,endX=45,endY=-3)
    gradient(surface,'RadialGradient',[(0,'42D2E2FF'),(.55,'16C8DDFF'),(1,'00C8DDFF')],startX=20,startY=40,endX=-4,endY=12)
    gradient(surface,'RadialGradient',[(0,'30FFF0D7'),(1,'00FFF0D7')],startX=-36,startY=18,endX=-14,endY=1)

    # Etching and reflections are clipped to the current interpolated contour.
    # This matters when an outgoing pen slit crosses a concave target shape.
    for shape in list(details.iter('Shape'))+[reflection]:
        node(shape,'ClippingShape',sourceId=surface.get('id'))

    gesture=node(body,'Node',id=ident(),name='Anticipation and follow through')
    for child in list(body):
        if child is not gesture:
            body.remove(child);gesture.append(child)

    machine=art.find('StateMachine')
    layer=node(machine,'StateMachineLayer',name='Tool silhouette')
    node(layer,'AnyState',x=0,y=240)
    node(layer,'ExitState',x=1600,y=240)
    states=[ident() for _ in FORMS]; anims=[ident() for _ in FORMS]
    node(node(layer,'EntryState',x=0,y=400),'StateTransition',stateToId=states[0])
    for index,name in enumerate(FORMS):
        state=node(layer,'AnimationState',id=states[index],animationId=anims[index],x=200+index*230,y=400,reset='true')
        for target in range(len(FORMS)):
            if target==index: continue
            transition=node(state,'StateTransition',stateToId=states[target],duration=420 if target==0 else 120,enableEarlyExit='true',interpolationType='cubic')
            node(transition,'CubicEaseInterpolator',x1=.22,y1=0,x2=.24,y2=1)
            condition=node(transition,'TransitionViewModelCondition',opValue='equal')
            value=node(node(condition,'TransitionPropertyViewModelComparator'),'BindablePropertyNumber')
            node(value,'DataBindContext',sourcePathIds='0:40-0:49',propertyKey=636)
            node(condition,'TransitionValueNumberComparator',value=target)
        anim=node(art,'LinearAnimation',id=anims[index],name='form-'+name,duration=42,fps=60,loopValue='oneShot')
        # 0–100 ms: return to a compact core. 100–320 ms: pull the tool out.
        # 320–700 ms: a restrained overshoot and a slower settle.
        def positions(point, neutral):
            x,y=point; ox,oy=neutral
            return ([(0,ox),(6,ox*.98),(19,x*1.055),(29,x*.985),(42,x)],
                    [(0,oy),(6,oy*.98),(19,y*1.055),(29,y*.985),(42,y)])
        for vertices,factor in geometry:
            for j,(v,point) in enumerate(zip(vertices,outlines[index])):
                xs,ys=positions(point,outlines[0][j])
                keys(anim,v,x=[(f,x*factor) for f,x in xs],y=[(f,y*factor) for f,y in ys])
        for v,(j,factor) in zip(patch_vertices,specs):
            xs,ys=positions(projected(outlines[index],j,factor),projected(outlines[0],j,factor))
            # Reflections catch up two frames after the body, producing a little depth.
            keys(anim,v,x=[(f+2 if f not in [0,42] else f,x) for f,x in xs],
                 y=[(f+2 if f not in [0,42] else f,y) for f,y in ys])
        lean=[0,-.11,.025,0,.09,-.025][index]
        keys(anim,gesture.get('id'),
             scaleX=[(0,1),(6,1.075),(18,.97),(29,1.012),(42,1)],
             scaleY=[(0,1),(6,.90),(18,1.055),(29,.99),(42,1)],
             rotation=[(0,0),(6,-lean*.4),(19,lean*1.2),(29,lean*.9),(42,lean)],
             y=[(0,0),(6,2),(18,-2.5),(29,.5),(42,0)])
        # Eyes remain visible. Their gaze anticipates the nib, pointer or other lobe.
        fx,fy=[(2,0),(5,3),(7,-3),(5,-1),(6,-5),(4,-3)][index]
        keys(anim,face.get('id'),x=[(0,2),(6,fx),(25,fx),(42,fx)],
             y=[(0,0),(6,fy),(25,fy),(42,fy)],
             scaleX=[(0,1),(6,.94),(20,.9 if index else 1),(42,.9 if index else 1)],
             scaleY=[(0,1),(6,.8),(20,.95),(42,1)])
        keys(anim,'0:10016',opacity=1,scaleX=1,scaleY=1)
        keys(anim,'0:10030',scaleX=.85,scaleY=.85)
        for i,group in enumerate(detail_groups,1):
            active=index==i
            # Reveal etching at its final position. Scaling around the body's
            # center would briefly drag the nib slit across the face like a mouth.
            keys(anim,group.get('id'),opacity=[(0,0),(18,0),(27,1 if active else 0),(42,1 if active else 0)],
                 scaleX=1,scaleY=1)
    model=root.find('ViewModel')
    node(model,'ViewModelPropertyNumber',id='0:49',name='tool')
    node(model.find('ViewModelInstance'),'ViewModelInstanceNumber',viewModelPropertyId='0:49',propertyValue=0)


if __name__=='__main__':
    root=E.parse(SOURCE).getroot()
    # Repeatable without accumulating duplicate artboards or property definitions.
    for art in list(root.findall('Artboard')):
        if art.get('name')=='Marr Tool': root.remove(art)
    for n in list(root.find('ViewModel')):
        if n.get('name')=='tool': root.find('ViewModel').remove(n)
    inst=root.find('ViewModel/ViewModelInstance')
    for n in list(inst):
        if n.get('viewModelPropertyId')=='0:49': inst.remove(n)
    add_tools(root)
    E.indent(root,space='  ')
    E.ElementTree(root).write(SOURCE,encoding='unicode')
    print(SOURCE)
