const test = require("node:test");
const assert = require("node:assert/strict");
const G = require("../game.js");

const idle = { dir: 0, targetX: null };

function run(state, ms, input = idle, stepMs = 16) {
  const events = [];
  for (let t = 0; t < ms; t += stepMs) events.push(...G.step(state, stepMs, input));
  return events;
}

function put(state, kind, x, y, r = 14) {
  state.objects.push({ id: state.nextId++, kind, x, y, r, vy: 0, spin: 0 });
}

test("the same seed gives the same game", () => {
  const a = G.createState(42);
  const b = G.createState(42);
  run(a, 20000, { dir: 1, targetX: null });
  run(b, 20000, { dir: 1, targetX: null });
  assert.equal(a.score, b.score);
  assert.equal(a.lives, b.lives);
  assert.deepEqual(a.objects, b.objects);
  assert.notEqual(G.createState(1).rng(), G.createState(2).rng());
});

test("the ship stays inside the screen", () => {
  const s = G.createState(1);
  s.lives = 1e9;
  run(s, 5000, { dir: -1, targetX: null });
  assert.equal(s.player.x, s.player.r);
  run(s, 5000, { dir: 1, targetX: null });
  assert.equal(s.player.x, G.W - s.player.r);
  run(s, 2000, { dir: 0, targetX: -500 });
  assert.equal(s.player.x, s.player.r);
});

test("the ship follows the pointer at a limited speed", () => {
  const s = G.createState(1);
  s.lives = 1e9;
  G.step(s, 16, { dir: 0, targetX: 10 });
  assert.ok(s.player.x < G.W / 2 && s.player.x > 10);
});

test("surviving earns points", () => {
  const s = G.createState(1);
  s.meteorTimerMs = s.crystalTimerMs = 1e9;
  run(s, 10000);
  assert.ok(s.score >= 49 && s.score <= 51, `score ${s.score}`);
});

test("a meteor costs a life, gives a moment of grace, and resets the combo", () => {
  const s = G.createState(1);
  s.meteorTimerMs = s.crystalTimerMs = 1e9;
  s.combo = 4;
  put(s, "meteor", s.player.x, s.player.y);
  put(s, "meteor", s.player.x, s.player.y);
  const events = G.step(s, 16, idle);
  assert.deepEqual(events, ["hit"]);
  assert.equal(s.lives, G.LIVES - 1);
  assert.equal(s.combo, 1);
  assert.equal(s.objects.length, 0, "both meteors break, only one hurts");
  put(s, "meteor", s.player.x, s.player.y);
  assert.deepEqual(G.step(s, 16, idle), []);
  assert.equal(s.lives, G.LIVES - 1, "no damage during grace");
});

test("three hits end the game", () => {
  const s = G.createState(1);
  s.meteorTimerMs = s.crystalTimerMs = 1e9;
  let last = [];
  for (let i = 0; i < 3; i++) {
    s.invulnerableMs = 0;
    put(s, "meteor", s.player.x, s.player.y);
    last = G.step(s, 16, idle);
  }
  assert.deepEqual(last, ["hit", "over"]);
  assert.equal(s.over, true);
  const before = s.score;
  assert.deepEqual(G.step(s, 1000, idle), []);
  assert.equal(s.score, before, "nothing changes after game over");
});

test("crystals are worth more with a growing combo, capped at 5", () => {
  const s = G.createState(1);
  s.meteorTimerMs = s.crystalTimerMs = 1e9;
  const gains = [];
  for (let i = 0; i < 7; i++) {
    const before = s.scoreFloat;
    put(s, "crystal", s.player.x, s.player.y, 10);
    assert.deepEqual(G.step(s, 0, idle), ["crystal"]);
    gains.push(Math.round(s.scoreFloat - before));
  }
  assert.deepEqual(gains, [10, 20, 30, 40, 50, 50, 50]);
  assert.equal(s.combo, G.MAX_COMBO);
});

test("objects that fall past the screen are removed", () => {
  const s = G.createState(1);
  s.meteorTimerMs = s.crystalTimerMs = 1e9;
  s.objects.push({ id: 1, kind: "meteor", x: 20, y: G.H + 100, r: 10, vy: 100, spin: 0 });
  G.step(s, 16, idle);
  assert.equal(s.objects.length, 0);
});

test("difficulty ramps up and stops at 1", () => {
  const s = G.createState(1);
  assert.equal(G.difficulty(s), 0);
  s.elapsedMs = 45000;
  assert.equal(G.difficulty(s), 0.5);
  s.elapsedMs = 1e9;
  assert.equal(G.difficulty(s), 1);
});

test("a long frame cannot skip through the world", () => {
  const s = G.createState(1);
  s.meteorTimerMs = s.crystalTimerMs = 1e9;
  G.step(s, 60000, idle);
  assert.equal(s.elapsedMs, 50);
});

test("the best possible player stays below the API's score limit", () => {
  // A perfect collector: teleports to the lowest crystal and cannot be hurt.
  const s = G.createState(7);
  s.lives = 1e9;
  for (let t = 0; t < 120000; t += 16) {
    const crystal = s.objects.filter((o) => o.kind === "crystal").sort((a, b) => b.y - a.y)[0];
    if (crystal) s.player.x = crystal.x;
    G.step(s, 16, idle);
  }
  const { score, duration_ms: ms } = G.result(s);
  const perSecond = score / (ms / 1000);
  assert.ok(perSecond < 55, `${perSecond.toFixed(1)} points per second`);
  assert.ok(score <= 60 * (ms / 1000) + 100, "must pass the API plausibility rule");
});

test("result reports at least the API's minimum duration", () => {
  const s = G.createState(1);
  assert.deepEqual(G.result(s), { score: 0, duration_ms: 1000 });
  run(s, 2500);
  assert.ok(G.result(s).duration_ms >= 2400);
});
