import { readFileSync, writeFileSync } from 'node:fs';

const source = readFileSync(new URL('./v4-awaiting.html', import.meta.url), 'utf8');
let seed = 173269;
const jitter = () => ((seed = (1664525 * seed + 1013904223) >>> 0) / 4294967296 - .5) * .32;
const pointPairs = /(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)/g;
const rough = path => path.replace(pointPairs, (_, x, y) => `${(+x + jitter()).toFixed(3)} ${(+y + jitter()).toFixed(3)}`);
const hatch = (x, y, count, length = 3) => Array.from({ length: count }, (_, i) => `M${x + i * 1.8} ${y - i * .7} L${x + i * 1.8 + length} ${y - i * .7 - length}`).join(' ');
const cloth = Object.fromEntries(Object.entries({
  body: source.match(/body:'([^']+)'/)[1],
  fold1: 'M183 49 C181.5 58 176 74.5 175 85.5',
  fold2: 'M185.5 49 C186 61.5 189.5 78.5 190 87.5',
  fold3: 'M188 49 C191 60 201.5 75.5 204.5 84.5',
  hatch1: hatch(188, 76, 4, 2.8),
  hatch2: hatch(200, 79, 4, 2.5),
  hatch3: hatch(205, 83.3, 3, 1.6),
}).map(([name, path]) => [name, rough(path)]));
const head = rough('M198 35 C198 41.5 192.5 47 186 47 C179.5 47 174 41.5 174 35 C174 28.5 179.5 23 186 23 C192.5 23 198 28.5 198 35 Z');
const headHatch = rough(hatch(188.2, 44, 4, 2.6));
const sun = rough('M265 26 C265.2 29.9 261.9 33.2 258 33 C254 33.2 251 29.9 251 26 C250.8 22 254 19 258 19 C262 18.8 265.1 22.1 265 26 Z');
const sunHatch = rough(hatch(258.5, 31, 3, 1.8));
const cloud = rough('M122 27 C114 27 114 16 121 14 C120 6 132 2 137 9 C142 0 156 2 158 12 C168 9 176 24 168 27 C153 27.3 136 26.7 122 27 Z');
const tails = rough('M119 33 C119 35.2 115 35.2 115 33 C115 30.8 119 30.8 119 33 Z M111 39 C111 40.4 108.6 40.4 108.6 39 C108.6 37.6 111 37.6 111 39 Z');
const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));
const half = n => Math.round(n * 2) / 2;
const poses = [[.7, 0], [1, .25], [.7, .5], [.35, .75]];
// Apply gen-wind's displacement to every endpoint and cubic control point.
// Fixed topology and seeded base jitter keep interpolation continuous.
const running = Object.fromEntries(Object.entries(cloth).map(([name, base]) => [name, poses.map(([g, phase]) => base.replace(pointPairs, (_, sx, sy) => {
  const x = +sx, y = +sy, t = clamp((y - 49) / 42, 0, 1), u = clamp((x - 186) / 30, -1, 1);
  if (t === 0) return `${sx} ${sy}`;
  let dx = 9 * g * t ** 1.6 * (.55 + .45 * u);
  if (u < 0) dx += 3 * g * t * -u;
  let dy = -6 * g * t ** 2 * Math.max(u, 0) ** 1.2;
  dx += 2 * g * t ** 2 * Math.max(u, 0);
  dy += 1.6 * t ** 2 * Math.sin(2 * Math.PI * phase - 2.2 * u);
  return `${half(186 + (x + dx - 186) * (1 + .15 * Math.min(1, t)))} ${half(y + dy)}`;
}))]));
let html = source.replace(/const cloth=\{[\s\S]*?\n\};/, `const cloth=${JSON.stringify(cloth)};`)
  .replace(/const running=[\s\S]*?;\nconst wet=/, `const running=Object.fromEntries(Object.entries(${JSON.stringify(running)}).map(([name,paths])=>[name,paths.map(geometry)]));\nconst wet=`);
html = html.replace(/function fabric\(id,state\)\{[^\n]+/, `function fabric(id,state){return Object.keys(cloth).map(name=>\`<path class="\${name==='body'?'cloth-outline paper':name.startsWith('hatch')?'hatch':'fold'} \${state==='running'?'fabric-motion fabric-'+name:''}" d="\${state==='fail'?wet[name]:state==='done'?keys[name][1]:state==='running'?running[name][0]:keys[name][0]}"/>\`).join('')}`);
const heroStart = html.indexOf(' const fade=');
const frameStart = html.indexOf(' <g fill="none" stroke-width=".5">', heroStart);
html = html.slice(0, heroStart) + ' return `<button class="hero" aria-label="新建会话" data-static="false"><svg viewBox="0 0 300 84" aria-hidden="true">\n' + html.slice(frameStart);
html = html.replace(/stroke="url\(#(?:frame|vertical|axis|arc|wind)-\$\{id\}\)"/g, 'stroke="rgba(var(--label),var(--hair))"');
html = html.replace('d="M90 ${y}H136"', 'd="M90 ${y}l11 -.4 M109 ${y-.3}l7 .5 M125 ${y+.2}l11 -.2"');
const sunStart = html.indexOf(' <g class="layer" data-for="done"><g class="sun-rise">');
const cloudStart = html.indexOf(' <g class="await-b', sunStart);
html = html.slice(0, sunStart) + ` <g class="layer" data-for="done"><g class="sun-rise"><path class="sketch" d="${sun}"/><path class="hatch" d="${sunHatch}"/><g class="sun-rays sketch">\${Array.from({length:12},(_,i)=>\`<path transform="rotate(\${i*30} 258 26)" d="M258 16L258.15 14"/>\`).join('')}</g></g></g>\n` + html.slice(cloudStart);
html = html.replace(/<g class="await-b await-mark"[\s\S]*?<\/g>/, `<g class="await-b await-mark" transform="translate(101 12)"><path class="await-cloud" pathLength="100" d="${cloud}"/><path class="sketch" d="${tails}"/><path class="hatch" d="${rough(hatch(151, 26, 3, 2))}"/></g>`);
const headStart = html.indexOf(' <path d="${geometry(\'M194 48');
const headEnd = html.indexOf(' </g></g></g>', headStart);
html = html.slice(0, headStart) + ` <path class="cloth-outline paper" d="\${geometry('${head}')}"/><path class="hatch" d="\${geometry('${headHatch}')}"/><path class="fold" d="\${geometry('M182 47.1 C184.2 48 187.8 48 190 47.1 M189.8 47.3 C190.7 48 190.9 49.3 190.6 50.6')}"/>\n` + html.slice(headEnd);
// Wallpaper remains the existing environmental reference; the drawing has no gradients or washes.
html = html.replace(/(?:-webkit-)?backdrop-filter:[^;}]+;?/g, '');
html = html.replace('</style>', `.hero{--paper:#e9edf0}.study.light .hero{--paper:#e9edf0}.study.dark .hero,body[data-appearance=dark] .window .hero{--paper:#25282b}
body[data-mode=performance] .hero,body[data-mode=performance] .study.light .hero{--paper:#ececec}body[data-mode=performance] .study.dark .hero,body[data-mode=performance][data-appearance=dark] .window .hero{--paper:#1f1f1f}
.sketch,.cloth-outline,.fold,.await-cloud{fill:none;stroke:rgba(var(--label),.7);stroke-width:.9;stroke-linecap:round;stroke-linejoin:round}.paper{fill:var(--paper)}.hatch{fill:none;stroke:rgba(var(--label),.35);stroke-width:.6;stroke-linecap:round}.awaiting-row{grid-template-columns:repeat(5,900px)}
</style>`);
html = html.replace('Hero v4 · Awaiting', 'Hero v5 · Sketchbook Hatching').replace('v4 · 待处理的三种提示', 'v5 · 手绘线条与排线').replace('data-awaiting="a"', 'data-awaiting="b"');
const states = [['fail','出错'],['wait','待处理'],['running','运行中'],['done','完成'],['idle','空闲']];
const zooms = ['light','dark'].map(theme=>`<div class="awaiting-row">${states.map(([state,label])=>`<figure class="study ${theme}"><figcaption>${theme==='light'?'浅色':'深色'} · ${label} · 3× · 跟随模式</figcaption><div class="stage" id="zoom-${theme}-${state}"></div></figure>`).join('')}</div>`).join('');
html = html.replace(/<section class="enlargements"[\s\S]*?<\/section><footer>[\s\S]*?<\/footer>/, `<section class="enlargements" aria-label="五种状态的浅色与深色三倍细节对照">${zooms}</section><footer><p>轮廓统一为 0.9px 侧栏墨色细线；固定种子的轻微偏移保留手绘痕迹。</p><p>头部右下、裙褶谷底与扬起的下摆仅以 0.6px 短排线表达体积；头与裙内使用平底色遮挡后方线条。</p><p>待处理采用线描云与两枚小圆尾，一次描绘后保持静止；雨、风、太阳均以线条表达，保留原有动效节奏与交互。</p><p>下方两行按出错、待处理、运行中、完成、空闲排列；性能模式和减少动态效果设置显示静态终态。</p></footer>`);
html = html.replace(/for\(const theme of \['light','dark'\]\)for\(const variant[^\n]+/, `for(const theme of ['light','dark'])for(const state of ['fail','wait','running','done','idle']){const id=\`zoom-\${theme}-\${state}\`;const stage=document.getElementById(id);stage.innerHTML=hero(id);stage.firstElementChild.dataset.previewState=state;}`);
html = html.replace("const state=card.dataset.variant?'wait':s", "const state=card.dataset.previewState||s").replace("card.dataset.variant||document.body.dataset.awaiting", "card.dataset.previewState?'b':document.body.dataset.awaiting");
html = html.replace("if(s==='running'&&!media.matches", "if(!media.matches");
// Keep only the selected thought cloud and its one-time drawing animation.
html = html.replace('transform-origin:258px 5px', 'transform-origin:258px 26px')
  .replace(/\.await-loop\{[\s\S]*?(?=body\[data-mode=transparent\] \.study\.light)/, `.await-cloud{stroke-dasharray:100;stroke-dashoffset:0}
.await-thought{display:none}
.hero[data-state=wait] .await-thought{display:inline}
.hero[data-state=wait] .await-cloud{animation:await-draw 1s ease-out both}
.hero[data-state=wait] .lift-doll{transform:none;transition:none}
@keyframes await-draw{from{stroke-dashoffset:100}to{stroke-dashoffset:0}}
.enlargements{overflow-x:auto}.awaiting-row{display:grid;grid-template-columns:repeat(5,900px);gap:24px}.awaiting-row .study{overflow:visible}
`)
  .replace('class="await-b await-mark"', 'class="await-thought await-mark"')
  .replace(/ <path class="await-c await-mark"[^\n]+\n/, '')
  .replace(/ <g class="await-a await-mark">[^\n]+\n/, '')
  .replace(/ data-awaiting="[abc]"/g, '')
  .replace("['awaiting','待处理样式：',[['a','A 批注圈'],['b','B 线描云'],['c','C 拉绳']]],", '')
  .replace("card.dataset.awaiting=card.dataset.previewState?'b':document.body.dataset.awaiting;", '')
  .replace('</style>', `body[data-appearance=dark] .window{--primary:rgba(255,255,255,.88);--secondary:rgba(255,255,255,.55)}
body[data-appearance=dark] .sidebar,.study.dark .stage{background:rgba(30,30,32,.62);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px)}
body[data-mode=transparent][data-appearance=dark] .sidebar,body[data-mode=transparent] .study.dark .stage{background:rgba(30,30,32,.30)}
body[data-mode=performance][data-appearance=dark] .sidebar,body[data-mode=performance] .study.dark .stage{background:#1f1f1f;-webkit-backdrop-filter:none;backdrop-filter:none}
body[data-appearance=dark] .window .hero .hatch,.study.dark .hero .hatch{stroke:rgba(var(--label),.5)}
body[data-appearance=dark] .window .hero .lift-doll .paper,.study.dark .hero .lift-doll .paper{fill:#c9cbc4}
body[data-appearance=dark] .window .hero .lift-doll .cloth-outline,body[data-appearance=dark] .window .hero .lift-doll .fold,.study.dark .hero .lift-doll .cloth-outline,.study.dark .hero .lift-doll .fold{stroke:rgba(34,37,41,.78)}
body[data-appearance=dark] .window .hero .lift-doll .hatch,.study.dark .hero .lift-doll .hatch{stroke:rgba(34,37,41,.45)}</style>`);
writeFileSync(new URL('./v5-hatch.html', import.meta.url), html);
