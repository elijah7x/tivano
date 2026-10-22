from pathlib import Path
import math
import runpy
OUTLINES = runpy.run_path(str(Path(__file__).with_name('text_outlines.py')))['OUTLINES']
import random

ROOT = Path(__file__).resolve().parent.parent
HEAD = 'M302 165 C302 192 282 211 256 211 C229 211 210 192 210 166 C210 140 230 122 256 122 C282 122 302 140 302 165 Z'
TAG = 'M130 42H382Q418 42 418 78V447Q418 482 383 482H129Q94 482 94 447V78Q94 42 130 42Z'
HEM_X = [153,177,204,232,259,286,312,338,368]
HEM_Y = [337,351,361,355,367,360,349,343,320]
BANDS = [0,.65,1.55,2.8,3.45,4.65,5.55,6.9,8]
DEPTH = [.55,.87,.66,1,.72,.95,.62,.83]

# A's silhouette and proportions remain exact; only the interior fold field turns.
def pt(u,t):
    i=min(7,int(u)); f=u-i
    xe=HEM_X[i]*(1-f)+HEM_X[i+1]*f
    ye=HEM_Y[i]*(1-f)+HEM_Y[i+1]*f+math.sin(math.pi*f)*3
    return (256+(u-4)*2.5+(xe-256-(u-4)*2.5)*t**1.16+9*math.sin(math.pi*t)*t,
            214+(ye-214)*t)

def cloth(u,t):
    turn=(.42*math.exp(-((u-2.65)/.65)**2)-.48*math.exp(-((u-5.6)/.7)**2))
    return pt(u+turn*math.sin(math.pi*t)*math.sin(math.pi*u/8),t)

def path(points,close=False):
    return 'M'+'L'.join(f'{x:.2f},{y:.2f}' for x,y in points)+('Z' if close else '')

def fold(u,a=0,b=1,n=25):
    return [cloth(u,a+(b-a)*j/(n-1)) for j in range(n)]

CLOTH=path([pt(0,j/22) for j in range(23)]+[pt(j/20,1) for j in range(161)]+[pt(8,1-j/22) for j in range(23)],True)

def light(u,t):
    i=next((i for i in range(8) if u<=BANDS[i+1]),7)
    f=(u-BANDS[i])/(BANDS[i+1]-BANDS[i])
    return 1-DEPTH[i]*(.5+.5*t)*(math.sin(math.pi*f)**6)


def region(a,b):
    return path(fold(a,n=40)+[cloth(a+(b-a)*j/32,1) for j in range(33)]+fold(b,n=40)[::-1],True)


# Both boundaries converge at the ends; the inflection gives the light a silk-like sweep.
SWEEP_UP = 'M121 352 C166 326 178 294 245 298 C315 302 347 276 396 250'
SWEEP_DOWN = 'M121 352 C176 351 194 320 257 326 C327 332 363 281 396 250'
SWEEP = SWEEP_UP + ' C363 281 327 332 257 326 C194 320 176 351 121 352Z'


def build(dark=False,bare=False,back=False,variant='behind'):
    rng=random.Random(62026)
    sage='#729487'; white='#f7f9ed'
    ink=sage if bare else ('#e0eddf' if dark else '#4d7163')
    s=['<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img" aria-labelledby="title desc">',
       '<title id="title">Tivano · Early Supporter 2026 · '+('Back' if back else 'Front')+'</title>',
       '<desc id="desc">Transparent sage glass tag, eight uneven etched folds, quiet closed eyes, separate suspension ring and knotted cord. Fine drafting border.</desc>']
    def p(d,c=ink,w=.4,o=1,fill='none',extra=''):
        # The unlit drawing must read clearly before it is lit: one deeper sage, firmer lines.
        if bare and c!='none':c,o,w='#5d8273',max(o,.75),max(w,.6)
        s.append(f'<path d="{d}" fill="{fill}" stroke="{c}" stroke-width="{max(.35,w):.2f}" opacity="{o:.3f}" stroke-linecap="round" stroke-linejoin="round" {extra}/>')
    def outline(key,baseline,size,o=1):
        # Text outlined from SIL OFL fonts (outline_text.py), centred on the tag.
        t=OUTLINES[key];k=size/t['upem'];x=256-t['width']*k/2
        paint=f'fill="none" stroke="{ink}" stroke-width="{.35/k:.1f}"' if bare else f'fill="{ink}"'
        s.append(f'<path d="{t["d"]}" {paint} opacity="{o}" transform="translate({x:.2f} {baseline}) scale({k:.5f})"/>')
    def text(x,y,words,size=7,spacing=1,serif=True):
        font='Baskerville, Palatino, Georgia, serif' if serif else '-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif'
        paint=f'fill="none" stroke="{ink}" stroke-width=".35"' if bare else f'fill="{ink}"'
        s.append(f'<text x="{x}" y="{y}" text-anchor="middle" font-family="{font}" font-size="{size}" letter-spacing="{spacing}" {paint}>{words}</text>')
    s.append(f'''<defs>
<clipPath id="glassShape"><path d="{TAG}"/></clipPath>
<linearGradient id="frostBody" gradientUnits="userSpaceOnUse" x1="256" y1="214" x2="256" y2="367"><stop stop-color="#fffff3" stop-opacity=".43"/><stop offset=".35" stop-color="#fafbef" stop-opacity=".40"/><stop offset=".74" stop-color="#f7f9ed" stop-opacity=".37"/><stop offset="1" stop-color="#f2f6e9" stop-opacity=".35"/></linearGradient>
<radialGradient id="headFrost" cx=".29" cy=".24" r=".84"><stop stop-color="#f7f9ed" stop-opacity=".43"/><stop offset=".35" stop-color="#eef3e4" stop-opacity=".40"/><stop offset=".74" stop-color="#c1d2b9" stop-opacity=".37"/><stop offset="1" stop-color="#91ac96" stop-opacity=".35"/></radialGradient>
<linearGradient id="headEtch" gradientUnits="userSpaceOnUse" x1="226" y1="133" x2="281" y2="206"><stop stop-color="{sage if bare else white}" stop-opacity=".004"/><stop offset=".35" stop-color="{sage if bare else white}" stop-opacity=".025"/><stop offset=".7" stop-color="{sage if bare else white}" stop-opacity=".16"/><stop offset="1" stop-color="{sage if bare else white}" stop-opacity=".35"/></linearGradient>
<mask id="knotUnder" maskUnits="userSpaceOnUse" x="265" y="209" width="15" height="13"><rect x="265" y="209" width="15" height="13" fill="white"/><circle cx="271.5" cy="213.1" r="1.2" fill="black"/></mask>
<mask id="knotOver" maskUnits="userSpaceOnUse" x="265" y="209" width="15" height="13"><rect x="265" y="209" width="15" height="13" fill="white"/><circle cx="271.5" cy="216.9" r="1.2" fill="black"/></mask>
<filter id="frostInner" x="-12%" y="-12%" width="124%" height="124%"><feGaussianBlur stdDeviation="2.1"/></filter>
<linearGradient id="lightSweep" gradientUnits="userSpaceOnUse" x1="121" y1="352" x2="396" y2="250"><stop stop-color="#fff4db" stop-opacity="0"/><stop offset=".18" stop-color="#fff8e9" stop-opacity=".8"/><stop offset=".48" stop-color="#fffff6"/><stop offset=".78" stop-color="#edfaff" stop-opacity=".85"/><stop offset="1" stop-color="#dcefff" stop-opacity="0"/></linearGradient>
<filter id="sweepSoft" x="-12%" y="-30%" width="124%" height="160%"><feGaussianBlur stdDeviation="4.2"/></filter>
<filter id="sweepEdgeSoft" x="-12%" y="-30%" width="124%" height="160%"><feGaussianBlur stdDeviation=".85"/></filter>
<filter id="gapSoft" x="-15%" y="-15%" width="130%" height="130%"><feGaussianBlur stdDeviation="1.3"/></filter>
<mask id="dollGap" maskUnits="userSpaceOnUse" x="90" y="240" width="332" height="132"><rect x="90" y="240" width="332" height="132" fill="white"/><path d="{CLOTH}" fill="black" stroke="black" stroke-width="7" filter="url(#gapSoft)"/><path d="{CLOTH}" fill="black" stroke="black" stroke-width="2"/><path d="{HEAD}" fill="black"/></mask>
<clipPath id="cloth"><path d="{CLOTH}"/></clipPath><clipPath id="head"><path d="{HEAD}"/></clipPath>
<mask id="slab" maskUnits="userSpaceOnUse" x="90" y="38" width="332" height="448"><path d="{TAG}" fill="white"/><circle cx="256" cy="73" r="7" fill="black"/></mask>
<mask id="halo" maskUnits="userSpaceOnUse" x="150" y="65" width="215" height="210"><path d="M150 65H365V275H150Z" fill="white"/><path d="{HEAD}" fill="black" stroke="black" stroke-width="5"/><path d="{CLOTH}" fill="black" stroke="black" stroke-width="5"/><path d="M250 65H262V124H250Z" fill="black"/></mask>
<linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#a9c0ae" stop-opacity="{.69 if dark else .65}"/><stop offset=".45" stop-color="#6d9480" stop-opacity=".52"/><stop offset="1" stop-color="#aec5af" stop-opacity=".73"/></linearGradient>
<radialGradient id="haze" cx=".3" cy=".24" r=".8"><stop stop-color="#f8f5df" stop-opacity=".35"/><stop offset="1" stop-color="#6c9d91" stop-opacity="0"/></radialGradient>
<radialGradient id="sphere" cx=".29" cy=".24" r=".84"><stop stop-color="#f7f9ed" stop-opacity=".83"/><stop offset=".56" stop-color="#e8f0de" stop-opacity=".47"/><stop offset="1" stop-color="#e8f0de" stop-opacity=".13"/></radialGradient>
<linearGradient id="bevel" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#fffff0"/><stop offset=".4" stop-color="#d9eee4"/><stop offset=".65" stop-color="#608f88"/><stop offset="1" stop-color="#e4ead1"/></linearGradient>
<linearGradient id="ribbon"><stop stop-color="#405e52"/><stop offset=".4" stop-color="#91ad93"/><stop offset=".64" stop-color="#bdd0b1"/><stop offset="1" stop-color="#587566"/></linearGradient>
<filter id="shadow" x="-15%" y="-10%" width="130%" height="125%"><feGaussianBlur stdDeviation="3"/></filter>
<filter id="corner"><feGaussianBlur stdDeviation="1.5"/></filter>
<filter id="etchGlow" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="1.4"/></filter>
''')
    for i,(a,b) in enumerate(zip(BANDS,BANDS[1:])):
        s.append(f'<clipPath id="fold{i}"><path d="{region(a,b)}"/></clipPath>')
        s.append(f'<linearGradient id="shade{i}"><stop stop-color="{white}" stop-opacity=".38"/><stop offset=".42" stop-color="{white}" stop-opacity=".16"/><stop offset=".75" stop-color="{white}" stop-opacity="{.03+.07*(1-DEPTH[i]):.3f}"/><stop offset="1" stop-color="{white}" stop-opacity=".28"/></linearGradient>')
    s.append('</defs>')
    if not bare:
        p(TAG,'none',o=.18,fill='#293f35',extra='transform="translate(0 5)" filter="url(#shadow)"')
        s.append('<g mask="url(#slab)">')
        p(TAG,'none',fill='url(#glass)');p(TAG,'none',fill='url(#haze)')
        p(TAG,'#4b7367',1.2,.75)
        p('M416 79V447Q416 480 383 480H130','#adc9c6',2.6,.8)
        p('M413 82V446Q413 477 382 477H132','#dae4ca',.65,.8)
        p('M130 45H382Q415 45 415 78V447Q415 479 383 479H129Q97 479 97 447V78Q97 45 130 45Z','url(#bevel)',1.1,.92)
        p('M101 106V79Q101 49 131 49H166',white,.7,.78)
        p('M103 91Q100 52 139 52M373 473Q409 477 409 440',white,3,.24,extra='filter="url(#corner)"')
        s.append('</g>')
    else:
        p(TAG,w=.65)
        p('M130 45H382Q415 45 415 78V447Q415 479 383 479H129',w=.35,o=.55)
    ticks=[]
    for j in range(89):
        y=91+j*4; length=6 if j%10==0 else (3.7 if j%5==0 else 1.8)
        ticks.extend([f'M108,{y}h{length}',f'M404,{y}h{-length}'])
    for j in range(63):
        x=132+j*4; length=6 if j%10==0 else (3.7 if j%5==0 else 1.8)
        if abs(x-256)>15:ticks.append(f'M{x},57v{length}')
        ticks.append(f'M{x},466v{-length}')
    p(''.join(ticks),w=.35,o=.75)
    p('M119 91V76H134M378 76H393V91M119 439V454H134M378 454H393V439',w=.65,o=.9)
    if back:outline('footer',450,5.4,.9)
    elif not bare:outline('thanks',450,4.7,.9)
    # The rear ribbon enters the aperture; its return covers the upper rim only.
    p('M250 69L241 7L251 9L262 69Z',sage,.45,fill='none' if bare else 'url(#ribbon)')
    s.append(f'<circle cx="256" cy="73" r="8.6" fill="none" stroke="{sage if bare else "url(#bevel)"}" stroke-width="2.4"/>')
    p('M250 78Q256 82 262 78',sage if bare else '#4d7163',.65,.9)
    p('M253 75L258 78L268 13L259 10Z',sage,.45,fill='none' if bare else 'url(#ribbon)')
    p('M260 14L255 73',sage if bare else white,.45,.6)
    # Ring's rear arc is interrupted at the eyelet; cord loops over its lower arc.
    p('M253 82C250 85 251 91 256 92C261 91 262 85 259 82',sage if bare else white,.85,.85)
    p('M253 82Q256 84 259 82',sage if bare else '#55796a',.6,.85)
    p('M255 92Q255 100 256 107.5' if back else 'M255 92Q254 105 256 117',sage if bare else white,.75,.9)
    p('M255 94Q258 93 258 90Q256 88 255 91',sage if bare else white,.65,.95)
    def light_sweep():
        transform = ' transform="translate(512 0) scale(-1 1)"' if back else ''
        s.append(f'<g{transform} clip-path="url(#glassShape)">')
        if bare:
            p(SWEEP_UP,sage,.35,.25,extra='stroke-dasharray="3 5"')
            p(SWEEP_DOWN,sage,.35,.25,extra='stroke-dasharray="3 5"')
        else:
            if variant == 'behind':
                s.append('<g mask="url(#dollGap)">')
            else:
                s.append('<g style="mix-blend-mode:screen">')
            p(SWEEP,'none',o=.40 if dark else .32,fill='url(#lightSweep)',extra='filter="url(#sweepSoft)"')
            p(SWEEP_UP,'url(#lightSweep)',1.1,.46 if dark else .38,extra='filter="url(#sweepEdgeSoft)"')
            s.append('</g>')
        s.append('</g>')
    # The back carries the motto; the ribbon stays on the front only.
    if (variant == 'behind' and not back) or bare:light_sweep()
    # Seen from behind: mirrored, and shrunk toward the ring to make room for the motto.
    if back:s.append('<g transform="translate(256 92) scale(-.62 .62) translate(-256 -92)" opacity=".62">')
    # 144 rays have more than 2px separation at their inner radius.
    s.append('<g mask="url(#halo)">')
    for band in range(5):
        rays=[]
        for j in range(144):
            a=2*math.pi*j/144;reach=79+9*math.sin(j*2.399)**2
            lo=50+(reach-50)*band/5;hi=50+(reach-50)*(band+1)/5
            rays.append(path([(256+lo*math.cos(a),166.5+lo*math.sin(a)),(256+hi*math.cos(a),166.5+hi*math.sin(a))]))
        p(''.join(rays),sage if bare else white,.35,([.30,.24,.18,.11,.05] if bare else [.18,.13,.085,.045,.018])[band])
    s.append('</g>')
    if not bare:
        s.append('<g clip-path="url(#cloth)">')
        p(CLOTH,'none',fill='url(#frostBody)')
        p(CLOTH,'none',o=.045,fill=white,extra='filter="url(#frostInner)"')
        s.append('</g>')
    if not bare and dark:
        p(CLOTH,'none',o=.16,fill=white,extra='filter="url(#etchGlow)"')
        p(HEAD,'none',o=.16,fill=white,extra='filter="url(#etchGlow)"')
    for i,(a,b) in enumerate(zip(BANDS,BANDS[1:])):
        s.append(f'<g clip-path="url(#fold{i})">')
        if not bare:
            p(region(a,b),'none',fill=f'url(#shade{i})')
            buckets=[[] for _ in range(4)]
            n=max(3,int((cloth(b,1)[0]-cloth(a,1)[0])/3.4))
            for j in range(1,n):
                u=a+(b-a)*j/n
                points=[]
                # Omit converging strokes until the actual normal spacing exceeds 1.8px.
                for k in range(61):
                    t=.04+.95*k/60
                    x,y=cloth(u,t);x0,y0=cloth(u-(b-a)/n,t);x1,y1=cloth(u+(b-a)/n,t)
                    before=cloth(u,max(0,t-.002));after=cloth(u,min(1,t+.002))
                    dx=after[0]-before[0];dy=after[1]-before[1];length=math.hypot(dx,dy)
                    gap=min(abs((x-x0)*dy-(y-y0)*dx),abs((x1-x)*dy-(y1-y)*dx))/length
                    if gap>=1.8:points.append((x,y))
                if len(points)>1:
                    bucket=min(3,int(light(u,.65)*4))
                    buckets[bucket].append(path(points))
            for k,lines in enumerate(buckets):p(''.join(lines),white,.35+k*.09,.20+k*.16)
            dots=[]
            for j in range(190):
                u=rng.uniform(a,b);t=rng.uniform(.14,.98)
                if rng.random()<light(u,t)*.62:
                    x,y=cloth(u,t);dots.append(f'M{x:.2f},{y:.2f}h.01')
            p(''.join(dots),white,.4,.40)
        else:
            guides=[]
            for t in (.25,.5,.75):
                guides.append(path([cloth(a+(b-a)*j/20,t) for j in range(21)]))
            p(''.join(guides),w=.35,o=.45,extra='stroke-dasharray="2 3"')
        s.append('</g>')
    for u in BANDS:p(path(fold(u)),sage if bare else white,.5,.55)
    # Two turned lips overlay the adjoining fold; their fill occludes underlying etch.
    for u,direction in [(2.8,1),(5.55,-1)]:
        edge=fold(u,.30,1,35)
        lip=[cloth(u+direction*.26*math.sin(math.pi*(t-.30)/.70),t) for t in [.30+j*.70/34 for j in range(35)]]
        p(path(edge+lip[::-1],True),sage if bare else white,.45,.9,fill='none' if bare else '#8ba795')
        p(path(lip),sage if bare else white,.7,.8)
    p(CLOTH,sage if bare else white,.7,.85)
    if not bare:
        s.append('<g clip-path="url(#head)">')
        p(HEAD,'none',fill='url(#headFrost)')
        p(HEAD,'none',o=.045,fill=white,extra='filter="url(#frostInner)"')
        s.append('</g>')
    p(HEAD,sage if bare else white,.65)
    s.append('<g clip-path="url(#head)">')
    if not bare:
        dots=[]
        for j in range(1250):
            x=rng.uniform(-1,1);y=rng.uniform(-1,1)
            if x*x+y*y<.96 and rng.random()<.47-.16*x-.16*y:
                dots.append(f'M{256+46*x:.2f},{166.5+44.5*y:.2f}h.01')
        p(''.join(dots),white,.4,.40)
    s.append('</g>')
    p('M236 174q5 3 10 0M266 174q5 3 10 0',sage if bare else '#4d7163',.95,.9)
    # The small terminal knot sits above the head and hides the cord endpoint.
    p('M256 117C252 117 253 121 256 122C260 121 259 117 256 117Z',sage if bare else white,.65,fill='none' if bare else '#cbd9c7')
    # The three turns converge into the knot and end at its left edge.
    for y,end in ((209,211.0),(212.8,212.4),(216.6,213.8)):
        p(f'M244 {y}Q257 {y+3.2} 268.0 {end}',sage if bare else '#638675',1.55)
        p(f'M244 {y-.35}Q257 {y+2.85} 268.0 {end-.35}',sage if bare else white,.55,.95)
    # The tie: both tails start inside the knot, which is drawn over them and over
    # the ends of the three turns, so every strand visibly comes out of the knot.
    cord=sage if bare else '#638675'
    shine=sage if bare else white
    def tail(d_full,d_tip,tip,direction):
        p(d_full,cord,1.55,.85 if bare else 1)
        p(d_tip,cord,1.05,.85 if bare else 1)
        if not bare:
            p(d_full,shine,.5,.9,extra='transform="translate(-.3 -.2)"')
        x,y=tip;fibres=[]
        for spread,length in [(-28,2.2),(0,2.6),(26,2.0)]:
            a=math.radians(direction+spread)
            fibres.append(f'M{x:.2f} {y:.2f}l{length*math.cos(a):.2f} {length*math.sin(a):.2f}')
        p(''.join(fibres),shine,.35,.8)
    tail('M272.3 214.6 C271.6 220 270.4 226.5 269.1 232.5','M269.1 232.5 Q268.7 235 268.3 236.6',(268.3,236.6),100)
    tail('M273.5 214.6 C275.0 219 277.0 223.6 278.6 228','M278.6 228 Q279.1 229.8 279.5 231',(279.5,231),72)
    # A square knot seen from the front: two interlocking bights side by side, the
    # left bight passing over the right at the centre.
    def bight(cx,cy,rx,ry,rot):
        d=f'M{cx-rx:.2f} {cy:.2f}a{rx} {ry} 0 1 0 {2*rx:.2f} 0a{rx} {ry} 0 1 0 {-2*rx:.2f} 0Z'
        g=f'transform="rotate({rot} {cx} {cy})"'
        p(d,cord,1.5,.85 if bare else 1,extra=g)
        if not bare:
            p(d,white,.42,.9,extra=g)
            # the hole of the bight shows the cloth behind, not cord
    bight(275.0,213.0,2.9,2.2,28)
    bight(270.6,212.2,2.9,2.2,-22)
    if not bare:
        # Where the left bight crosses over the right one, its strand is drawn whole on top.
        p('M272.4 210.6 C273.4 211.6 273.6 213.0 273.1 214.4',cord,1.5)
        p('M272.2 210.7 C273.1 211.6 273.3 212.9 272.9 214.2',white,.42,.95)
    if back:s.append('</g>')
    if variant == 'veil' and not bare:light_sweep()
    if back:
        outline('motto1',318,14)
        outline('motto2',340,14)
        outline('motto3',362,14)
        p('M236 389H276',w=.35,o=.6)
    elif not bare:
        outline('title',408,19)
        p('M226 424H286',w=.35,o=.6)
    else:
        p('M210 114V105H302V114M210 101V109M302 101V109M153 375V384H368V375',w=.35,o=.75)
        text(256,99,'Ø 92',7,.6)
        text(256,397,'215 / 8 FOLDS',7,.7)
        text(256,416,'144 RAYS / HATCH ≥ 1.8',6,.6)
        text(256,434,'BEVEL 2.6 / CANVAS UNITS',6,.6)
    s.append('</svg>')
    return '\n'.join(s)


out=ROOT/'early-supporter'
out.mkdir(parents=True,exist_ok=True)
for name,dark,bare,back in [('front-lit.svg',False,False,False),('front-lit-dark.svg',True,False,False),('front-unlit.svg',False,True,False),('back-lit.svg',False,False,True),('back-lit-dark.svg',True,False,True)]:
    (out/name).write_text(build(dark,bare,back,'behind'),encoding='utf-8')
(out/'notes.md').write_text('# R9 · 收口头部与颈结（lead 手改）\n\n基于 round8b。头部：去掉随机经线与颈下七道“胡须”式收褶，改为 13 条真实球面经线：极点在绳结处、朝观者倾斜 20°，从颈绳下方等角度放射，中间长两侧短，沿程分 8 段渐隐，暗部（右下）略重。颈结：两条尾绳的起点都在结内部，结体与三圈颈绳末端压在尾绳上方，交叉处一上一下留断口；尾绳末段收细并沿走向散出三根纤维。其余继承 round8b。\n',encoding='utf-8')
