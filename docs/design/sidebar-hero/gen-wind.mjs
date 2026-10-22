import { readFileSync, writeFileSync } from 'node:fs';

const sourceURL = new URL('./g-states.html', import.meta.url);
const swiftURL = new URL('../../../Tivano/UI/Common/HeroWeatherGeometry.swift', import.meta.url);
const mockupURL = new URL('./v3-skylight.html', import.meta.url);
const source = readFileSync(sourceURL, 'utf8').match(/const cloth=\{([\s\S]*?)\n\};/)[1];
const cloth = Object.fromEntries([...source.matchAll(/(\w+):'([^']+)'/g)].map(([, name, path]) => [name, path]));
const poses = [[0.7, 0], [1, 0.25], [0.7, 0.5], [0.35, 0.75]];
const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));
const half = n => Math.round(n * 2) / 2;
const commands = path => path.match(/[a-z]/gi).join('');
const running = Object.fromEntries(Object.entries(cloth).map(([name, base]) => [name, poses.map(([g, phase], i) => {
    const path = base.replace(/(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)/g, (_, sx, sy) => {
        const x = Number(sx), y = Number(sy);
        const t = clamp((y - 49) / 42, 0, 1), u = clamp((x - 186) / 30, -1, 1);
        if (t === 0) return `${sx} ${sy}`;
        let dx = 9 * g * t ** 1.6 * (0.55 + 0.45 * u);
        if (u < 0) dx += 3 * g * t * -u;
        let dy = -6 * g * t ** 2 * Math.max(u, 0) ** 1.2;
        dx += 2 * g * t ** 2 * Math.max(u, 0);
        dy += 1.6 * t ** 2 * Math.sin(2 * Math.PI * phase - 2.2 * u);
        return `${half(186 + (x + dx - 186) * (1 + 0.15 * Math.min(1, t)))} ${half(y + dy)}`;
    });
    if (commands(path) !== commands(base)) {
        console.error(`FAIL: ${name} pose ${'ABCD'[i]} command structure differs from base`);
        process.exit(1);
    }
    return path;
})]));

let panel = 0;
const paths = Object.values(running);
const swift = readFileSync(swiftURL, 'utf8').replace(/running: \[([\s\S]*?)\n              \]/g, (block) => {
    let pose = 0;
    return block.replace(/path\("[^"]*"\)/g, () => `path("${paths[panel][pose++]}")`).replace(/$/, () => { panel++; return ''; });
});
writeFileSync(swiftURL, swift);
const declaration = `const running=Object.fromEntries(Object.entries(${JSON.stringify(running, null, 2)}).map(([name,paths])=>[name,paths.map(geometry)]));`;
const mockup = readFileSync(mockupURL, 'utf8').replace(/const running=[\s\S]*?;\nconst wet=/, `${declaration}\nconst wet=`);
writeFileSync(mockupURL, mockup);
console.log('Command-structure check passed: 9 panels × 4 running poses. Updated Swift and mockup paths.');
