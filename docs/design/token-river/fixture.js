// Shared synthetic fixture for the token-river mockups. Never real user data.
// Rows mirror the TokenUsageSnapshot row: one per day x tool x model.
// total = input + cachedInput + cacheWrite + output; reasoning is a subset of output.
(function () {
  const SEED = 0x7e11a;
  let s = SEED;
  const rand = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);

  const END = Date.UTC(2026, 10, 8);
  const DAYS = 365;

  // [start, end) day indexes; models ramp in and out over ~10 days, so switches overlap.
  const tools = [
    { id: 'claude', name: 'Claude', weight: 1.0,
      mix: { input: .06, cachedInput: .78, cacheWrite: .08, output: .08, reasoningOfOutput: .30 },
      models: [['Sonnet 4.5', 0, 365, .50], ['Opus 4.1', 0, 200, .35], ['Opus 4.5', 190, 365, .40], ['Haiku 4.5', 120, 365, .10]] },
    { id: 'codex', name: 'Codex', weight: .80,
      mix: { input: .18, cachedInput: .70, cacheWrite: 0, output: .12, reasoningOfOutput: .50 },
      models: [['GPT-5', 0, 150, .60], ['GPT-5-Codex', 60, 300, .70], ['GPT-5.5', 280, 365, .80]] },
    { id: 'gemini', name: 'Gemini', weight: .40,
      mix: { input: .40, cachedInput: .45, cacheWrite: 0, output: .15, reasoningOfOutput: .40 },
      models: [['Gemini 2.5 Pro', 0, 260, .70], ['Gemini 3 Pro', 250, 365, .75], ['Gemini 2.5 Flash', 0, 365, .30]] },
    { id: 'opencode', name: 'OpenCode', weight: .32,
      mix: { input: .25, cachedInput: .60, cacheWrite: .05, output: .10, reasoningOfOutput: .20 },
      models: [['Kimi K2', 0, 365, .45], ['GLM-4.6', 100, 365, .55]] },
    { id: 'cursor', name: 'Cursor', weight: .28,
      mix: { input: .20, cachedInput: .65, cacheWrite: .05, output: .10, reasoningOfOutput: .20 },
      models: [['Sonnet 4.5', 0, 365, .60], ['Composer', 180, 365, .50]] },
    { id: 'kimi', name: 'Kimi', weight: .20,
      mix: { input: .30, cachedInput: .55, cacheWrite: .05, output: .10, reasoningOfOutput: .30 },
      models: [['Kimi K2', 0, 240, .80], ['Kimi K2.5', 230, 365, .90]] },
  ];

  // Illustrative USD per million tokens: [input, cachedInput, cacheWrite, output].
  const rates = {
    'Sonnet 4.5': [3, .3, 3.75, 15], 'Opus 4.1': [15, 1.5, 18.75, 75], 'Opus 4.5': [5, .5, 6.25, 25],
    'Haiku 4.5': [1, .1, 1.25, 5], 'GPT-5': [1.25, .125, 0, 10], 'GPT-5-Codex': [1.25, .125, 0, 10],
    'GPT-5.5': [1.5, .15, 0, 12], 'Gemini 2.5 Pro': [1.25, .31, 0, 10], 'Gemini 3 Pro': [2, .5, 0, 12],
    'Gemini 2.5 Flash': [.3, .075, 0, 2.5], 'Kimi K2': [.6, .15, .6, 2.5], 'Kimi K2.5': [.6, .15, .6, 3],
    'GLM-4.6': [.6, .11, .6, 2.2], 'Composer': null, // Composer is unpriced on purpose.
  };

  const ramp = (d, a, b) => Math.max(0, Math.min(1, (d - a + 5) / 10, (b - d + 5) / 10));
  const bursts = [[40, 6, 2.2], [96, 4, 1.8], [150, 9, 2.6], [262, 5, 3.0], [318, 7, 2.4], [349, 4, 2.0]];
  const vacation = [205, 214];
  const iso = t => new Date(t).toISOString().slice(0, 10);

  const days = [];
  for (let d = 0; d < DAYS; d++) {
    const date = iso(END - (DAYS - 1 - d) * 86400000);
    const weekday = new Date(date + 'T00:00:00Z').getUTCDay();
    const rhythm = weekday === 0 ? .25 : weekday === 6 ? .4 : 1;
    const growth = .55 + .45 * d / DAYS;
    const burst = bursts.reduce((m, [c, w, h]) => m * (1 + (h - 1) * Math.exp(-((d - c) ** 2) / (2 * w * w))), 1);
    const away = d >= vacation[0] && d <= vacation[1] ? .03 : 1;
    const rows = [];
    for (const tool of tools) {
      const toolDay = 3.2e6 * tool.weight * rhythm * growth * burst * away * (.7 + rand() * .6);
      for (const [model, a, b, share] of tool.models) {
        const on = ramp(d, a, b);
        if (on <= 0) continue;
        const total = Math.round(toolDay * share * on * (.8 + rand() * .4));
        if (total < 1000) continue;
        const m = tool.mix, j = () => .9 + rand() * .2;
        const input = Math.round(total * m.input * j());
        const cacheWrite = Math.round(total * m.cacheWrite * j());
        const output = Math.round(total * m.output * j());
        const cachedInput = Math.max(0, total - input - cacheWrite - output);
        const reasoning = Math.round(output * m.reasoningOfOutput * j());
        const r = rates[model];
        const costUSD = r ? (input * r[0] + cachedInput * r[1] + cacheWrite * r[2] + output * r[3]) / 1e6 : null;
        rows.push({ day: date, tool: tool.id, model, input, cachedInput, cacheWrite, output, reasoning, total, costUSD });
      }
    }
    days.push({ date, rows });
  }

  window.TokenFixture = {
    seed: SEED,
    tools: tools.map(({ id, name }) => ({ id, name })),
    days, // oldest first; last entry is 2026-11-08
    // Last n days, oldest first.
    range(n) { return days.slice(-n); },
  };
})();
