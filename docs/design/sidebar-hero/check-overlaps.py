#!/usr/bin/env python3
"""Sample the source paths, without building or launching Tivano."""
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
source = (ROOT / 'Tivano/UI/Common/HeroWeatherGeometry.swift').read_text()
view = (ROOT / 'Tivano/UI/Common/HeroWeatherView.swift').read_text()

def samples(data, steps=160):
    tokens = re.findall(r'[MLHVCZmlhvcz]|[-+]?(?:\d*\.\d+|\d+)', data)
    p = start = (0., 0.)
    paths = []
    i = 0
    while i < len(tokens):
        cmd = tokens[i]; i += 1
        relative = cmd.islower(); cmd = cmd.upper()
        n = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'Z': 0}[cmd]
        a = list(map(float, tokens[i:i+n])); i += n
        if relative:
            a = [v + p[k % 2] for k, v in enumerate(a)]
        if cmd == 'M':
            p = start = tuple(a); paths.append([p]); continue
        if cmd == 'Z': end = start
        elif cmd == 'H': end = (a[0], p[1])
        elif cmd == 'V': end = (p[0], a[0])
        else: end = tuple(a[-2:])
        for j in range(1, steps + 1):
            t = j / steps; u = 1-t
            if cmd == 'C':
                q = tuple(u**3*p[k] + 3*u*u*t*a[k] + 3*u*t*t*a[k+2] + t**3*end[k] for k in range(2))
            else: q = tuple(p[k]*u + end[k]*t for k in range(2))
            paths[-1].append(q)
        p = end
    return paths

def named(name):
    return re.search(r'static let '+name+r' = path\("([^"]+)"\)', source)[1]

def flat(data): return [p for sub in samples(data) for p in sub]
def box(points): return min(x for x,y in points), min(y for x,y in points), max(x for x,y in points), max(y for x,y in points)
def inside(p, polygon):
    x,y = p; hit = False
    for a,b in zip(polygon, polygon[1:]+polygon[:1]):
        dx,dy = b[0]-a[0],b[1]-a[1]
        t = max(0,min(1,((x-a[0])*dx+(y-a[1])*dy)/(dx*dx+dy*dy))) if dx*dx+dy*dy else 0
        if math.hypot(x-a[0]-t*dx,y-a[1]-t*dy) < .015: return True
        if (a[1]>y)!=(b[1]>y) and x < a[0]+(y-a[1])*dx/dy: hit = not hit
    return hit

cloth = {}
for name, block in re.findall(r'ClothPath\(name: "([^"]+)",(.*?)(?=ClothPath\(name:|\n    \])', source, re.S):
    cloth[name] = re.findall(r'path\("([^"]+)"\)', block)
poses = ['idle', 'running A', 'running B', 'running C', 'running D', 'done', 'fail']
head = flat(named('head')); hx0,hy0,hx1,hy1=box(head)
cx,cy=(hx0+hx1)/2,(hy0+hy1)/2
radius=max(hx1-hx0,hy1-hy0)/2
failures=0

def report(label, bad, detail=''):
    global failures
    failures += bool(bad)
    print(f'{"FAIL" if bad else "PASS"} {label}' + (f': {detail}' if detail else ''))

if __name__ == '__main__':
    string=flat(named('string'))
    intersections=[]
    for a,b in zip(head,head[1:]):
        if min(a[0],b[0]) <= 186 <= max(a[0],b[0]) and a[0]!=b[0]:
            intersections.append(a[1]+(186-a[0])*(b[1]-a[1])/(b[0]-a[0]))
    top=min(intersections)
    report('string / head boundary', abs(string[-1][1]-top)>.001, f'end={string[-1][1]:.6f}, outline={top:.6f}')
    for i,pose in enumerate(poses):
        polygon=samples(cloth['body'][i], 32)[0]
        intrusion=[p for paths in cloth.values() for p in flat(paths[i]) if math.hypot(p[0]-cx,p[1]-cy)<radius-.02]
        report(pose+' / head clearance',len(intrusion),f'{len(intrusion)} interior samples')
        outside=[]
        for name, paths in cloth.items():
            if name=='body': continue
            count=sum(not inside(p,polygon) for p in flat(paths[i]))
            if count: outside.append(f'{name}={count}')
        report(pose+' / folds and hatches',outside, ', '.join(outside) or 'all samples inside')
    structure=[name for name,paths in cloth.items() if len({''.join(re.findall('[MLCZ]',p)) for p in paths})!=1]
    report('identical pose command structure',structure)
    tie=flat(named('tie'))
    report('tie / seam', any(math.hypot(x-cx,y-cy)<radius-.9/.84 for x,y in tie))
    hem=max(y for p in cloth['body'] for x,y in flat(p))
    bottom=8+(hem-10.777778)*.84+3
    report('axis / below all hems', 'Geometry.lowestHem' not in view or 'min(bounds.height - 4' not in view, f'hem={hem:.3f}, tick starts at {bottom:.3f}pt (84pt hero)')
    # Static weather artwork is translated in scene space; evaluate ordinary sidebar widths.
    for width in [180,200,240,268,320,400,600]:
        anchor=round(width*.65)
        doll=[(anchor+(x-186)*.84,8+(y-10.777778)*.84) for data in [named('head'),cloth['body'][0],cloth['body'][5]] for x,y in flat(data)]
        dx0,dy0,dx1,dy1=box(doll)
        sunx=max(width*.86,anchor+46)
        cloudpoints=flat(named('cloud'))
        tailblock=source.split('static let cloudTail = [')[1].split(']')[0]
        cloudpoints += [p for data in re.findall(r'path\("([^"]+)"\)',tailblock) for p in flat(data)]
        weather=[(sunx+13*math.cos(t*.01),26+13*math.sin(t*.01)) for t in range(629)]
        weather += [(anchor-76+x,12+y) for x,y in cloudpoints]
        report(f'static sun/cloud/tails / width {width}',any(dx0-.6<x<dx1+.6 and dy0-.6<y<dy1+.6 for x,y in weather))
    paths=[head]+[flat(data) for data in cloth['body']]
    swept=[]
    for step in range(29):
        angle=math.radians(-12+step*.5)
        for points in paths:
            x0,y0,x1,y1=box(points)
            for x in [x0,x1]:
                for y in [y0,y1]:
                    px,py=(x-186)*.84,(y-10.777778)*.84
                    swept.append((px*math.cos(angle)-py*math.sin(angle),px*math.sin(angle)+py*math.cos(angle)))
    x0,y0,x1,y1=box(swept)
    mx,my=(x0+x1)/2,(y0+y1)/2
    rx,ry=((x1-x0)/2+4)*math.sqrt(2),((y1-y0)/2+4)*math.sqrt(2)
    escaped=0
    for step in range(141):
        angle=math.radians(-12+step*.1)
        for scale in [.84,.84*.98]:
            for hover in [0,-3]:
                for points in paths:
                    for x,y in points[::8]:
                        px,py=(x-186)*scale,(y-10.777778)*scale+hover
                        qx=px*math.cos(angle)-py*math.sin(angle)
                        qy=px*math.sin(angle)+py*math.cos(angle)
                        # Include the widest doll stroke, not only its centerline.
                        escaped += ((abs(qx-mx)+.6)/rx)**2+((abs(qy-my)+.6)/ry)**2>1
    report('rain and wind / swept ellipse coverage',escaped,f'{escaped} escaped samples, -12…+2 degrees, hover and pressed')
    report('rain and wind / exclusion mask wiring',not all(s in view for s in ['rain.mask = rainMask','wind.mask = windMask','mask.fillRule = .evenOdd','Geometry.weatherExclusion']))
    print(f'{"FAIL" if failures else "PASS"} summary: {failures} failing checks')
    raise SystemExit(bool(failures))
