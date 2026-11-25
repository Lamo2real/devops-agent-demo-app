/* Starfall Dodge: game rules. No DOM here, so the rules run in Node tests.
 *
 * Dodge the meteors, collect crystals. Each crystal is worth 10 x combo (the
 * combo grows to 5 and resets when a meteor hits you). You have 3 lives.
 * Surviving earns 5 points per second. The best possible rate is about 45
 * points per second, below the API's plausibility limit of 60 per second.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.Starfall = factory();
})(typeof self !== "undefined" ? self : this, function () {
  const W = 480;
  const H = 720;
  const PLAYER_RADIUS = 16;
  const KEY_SPEED = 420; // px per second with the keyboard
  const POINTER_SPEED = 900; // px per second towards the pointer
  const LIVES = 3;
  const INVULNERABLE_MS = 1200;
  const MAX_COMBO = 5;
  const CRYSTAL_POINTS = 10;
  const SURVIVAL_POINTS_PER_SECOND = 5;
  const CRYSTAL_EVERY_MS = 1250;
  const RAMP_MS = 90000; // time to full difficulty
  const MAX_STEP_MS = 50; // a long frame (background tab) never skips through objects

  function mulberry32(seed) {
    let a = seed | 0;
    return function () {
      a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function createState(seed) {
    return {
      w: W,
      h: H,
      rng: mulberry32(seed),
      player: { x: W / 2, y: H - 70, r: PLAYER_RADIUS },
      objects: [],
      lives: LIVES,
      scoreFloat: 0,
      score: 0,
      combo: 1,
      elapsedMs: 0,
      invulnerableMs: 0,
      meteorTimerMs: 600,
      crystalTimerMs: CRYSTAL_EVERY_MS,
      over: false,
      nextId: 1,
    };
  }

  function difficulty(state) {
    return Math.min(1, state.elapsedMs / RAMP_MS);
  }

  function spawnMeteor(state) {
    const d = difficulty(state);
    const r = 12 + state.rng() * 14;
    state.objects.push({
      id: state.nextId++,
      kind: "meteor",
      x: r + state.rng() * (W - 2 * r),
      y: -r,
      r,
      vy: 140 + 260 * d + state.rng() * 90,
      spin: (state.rng() - 0.5) * 3,
    });
  }

  function spawnCrystal(state) {
    const r = 10;
    state.objects.push({
      id: state.nextId++,
      kind: "crystal",
      x: r + state.rng() * (W - 2 * r),
      y: -r,
      r,
      vy: 150 + state.rng() * 60,
      spin: 0,
    });
  }

  /* Advance the game by dtMs. input: { dir: -1|0|1, targetX: number|null }.
   * Returns the events that happened: "crystal", "hit", "over". */
  function step(state, dtMs, input) {
    const events = [];
    if (state.over) return events;
    const dt = Math.min(Math.max(dtMs, 0), MAX_STEP_MS);
    const seconds = dt / 1000;
    const p = state.player;

    if (input && typeof input.targetX === "number") {
      const delta = input.targetX - p.x;
      const move = Math.min(Math.abs(delta), POINTER_SPEED * seconds);
      p.x += Math.sign(delta) * move;
    } else if (input && input.dir) {
      p.x += input.dir * KEY_SPEED * seconds;
    }
    p.x = Math.min(W - p.r, Math.max(p.r, p.x));

    state.elapsedMs += dt;
    state.invulnerableMs = Math.max(0, state.invulnerableMs - dt);
    state.scoreFloat += SURVIVAL_POINTS_PER_SECOND * seconds;

    const d = difficulty(state);
    state.meteorTimerMs -= dt;
    while (state.meteorTimerMs <= 0) {
      spawnMeteor(state);
      state.meteorTimerMs += Math.max(250, 700 - 450 * d);
    }
    state.crystalTimerMs -= dt;
    while (state.crystalTimerMs <= 0) {
      spawnCrystal(state);
      state.crystalTimerMs += CRYSTAL_EVERY_MS;
    }

    const kept = [];
    for (const o of state.objects) {
      o.y += o.vy * seconds;
      const dx = o.x - p.x;
      const dy = o.y - p.y;
      const touching = Math.hypot(dx, dy) < p.r + o.r * 0.85;
      if (touching && o.kind === "crystal") {
        state.scoreFloat += CRYSTAL_POINTS * state.combo;
        state.combo = Math.min(MAX_COMBO, state.combo + 1);
        events.push("crystal");
        continue;
      }
      if (touching && o.kind === "meteor") {
        if (state.invulnerableMs <= 0) {
          state.lives -= 1;
          state.combo = 1;
          state.invulnerableMs = INVULNERABLE_MS;
          events.push("hit");
          if (state.lives <= 0) {
            state.over = true;
            events.push("over");
          }
        }
        continue; // the meteor breaks either way
      }
      if (o.y - o.r <= H) kept.push(o);
    }
    state.objects = kept;
    state.score = Math.floor(state.scoreFloat);
    return events;
  }

  /* What the API wants after a game. */
  function result(state) {
    return { score: state.score, duration_ms: Math.max(1000, Math.round(state.elapsedMs)) };
  }

  return { W, H, LIVES, MAX_COMBO, createState, step, result, difficulty, mulberry32 };
});
