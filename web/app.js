/* Starfall Dodge: drawing, controls, leaderboard. The rules are in game.js. */
(function () {
  "use strict";
  const { W, H, createState, step, result } = window.Starfall;
  const cfg = window.STARFALL_CONFIG || {};
  const API = String(cfg.apiUrl || "").replace(/\/$/, "");
  const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,15}$/;

  const canvas = document.getElementById("game");
  const ctx = canvas.getContext("2d");
  const overlay = document.getElementById("overlay");
  const message = document.getElementById("message");
  const scoreForm = document.getElementById("scoreForm");
  const nameInput = document.getElementById("name");
  const submitButton = document.getElementById("submit");
  const playButton = document.getElementById("play");
  const boardList = document.getElementById("board");

  // --- sizing -------------------------------------------------------------------
  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize();

  // --- state ----------------------------------------------------------------------
  let state = createState(1);
  let mode = "ready"; // ready | playing | over
  let lastRun = null;
  let last = 0;
  let flash = 0;
  const input = { dir: 0, targetX: null };
  const stars = Array.from({ length: 70 }, (_, i) => ({ x: (i * 97) % W, y: (i * 211) % H, s: 0.5 + (i % 3) * 0.6 }));

  // --- storage (may be blocked) -------------------------------------------------------
  function loadName() {
    try { return localStorage.getItem("starfall-name") || ""; } catch (e) { return ""; }
  }
  function saveName(value) {
    try { localStorage.setItem("starfall-name", value); } catch (e) { /* private mode */ }
  }
  nameInput.value = loadName();

  // --- leaderboard ----------------------------------------------------------------------
  function setMessage(text, isError) {
    message.textContent = text;
    message.className = isError ? "error" : "";
  }

  function renderBoard(entries, highlight) {
    boardList.replaceChildren();
    for (const e of entries) {
      const li = document.createElement("li");
      const who = document.createElement("span");
      const pts = document.createElement("span");
      who.textContent = `${e.rank}. ${e.player}`; // textContent: names are never HTML
      pts.textContent = String(e.score);
      li.append(who, pts);
      if (highlight && e.player === highlight.player && e.score === highlight.score) li.className = "me";
      boardList.append(li);
    }
  }

  async function loadBoard(highlight) {
    if (!API) { boardList.replaceChildren(); return; }
    try {
      const response = await fetch(`${API}/leaderboard?limit=10`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      renderBoard((await response.json()).entries || [], highlight);
    } catch (err) {
      console.warn("leaderboard unavailable", err);
      boardList.replaceChildren();
      if (mode !== "playing") setMessage("The leaderboard is not reachable right now.", true);
    }
  }

  async function submitScore(event) {
    event.preventDefault();
    const player = nameInput.value.trim();
    if (!NAME_RE.test(player)) {
      setMessage("Use 1 to 16 letters, digits, space, _ . -", true);
      return;
    }
    saveName(player);
    submitButton.disabled = true;
    try {
      const response = await fetch(`${API}/scores`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ player, ...lastRun }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      scoreForm.hidden = true;
      setMessage("Score submitted. Nice flying!");
      await loadBoard({ player, score: lastRun.score });
    } catch (err) {
      console.warn("submit failed", err);
      setMessage("Could not submit your score. Try again.", true);
      submitButton.disabled = false;
    }
  }

  // --- flow --------------------------------------------------------------------------------
  function start() {
    state = createState((Date.now() ^ (Math.random() * 0xffffffff)) >>> 0);
    mode = "playing";
    lastRun = null;
    flash = 0;
    overlay.hidden = true;
    last = performance.now();
  }

  function gameOver() {
    mode = "over";
    lastRun = result(state);
    overlay.hidden = false;
    playButton.textContent = "Play again";
    setMessage(`Game over. You scored ${lastRun.score}.`);
    if (API) {
      scoreForm.hidden = false;
      submitButton.disabled = false;
      loadBoard();
    }
  }

  playButton.addEventListener("click", start);
  scoreForm.addEventListener("submit", submitScore);

  // --- controls ------------------------------------------------------------------------------
  const KEYS = { ArrowLeft: -1, a: -1, A: -1, ArrowRight: 1, d: 1, D: 1 };
  const held = new Set();
  function syncDir() {
    let dir = 0;
    for (const k of held) dir += KEYS[k];
    input.dir = Math.max(-1, Math.min(1, dir));
  }
  window.addEventListener("keydown", (e) => {
    if (e.target instanceof HTMLInputElement) return;
    if (e.key in KEYS) { held.add(e.key); syncDir(); input.targetX = null; e.preventDefault(); }
    if ((e.key === " " || e.key === "Enter") && mode !== "playing" && document.activeElement === document.body) { start(); e.preventDefault(); }
  });
  window.addEventListener("keyup", (e) => { held.delete(e.key); syncDir(); });
  window.addEventListener("blur", () => { held.clear(); syncDir(); });

  function pointerX(e) {
    const rect = canvas.getBoundingClientRect();
    return ((e.clientX - rect.left) / rect.width) * W;
  }
  canvas.addEventListener("pointermove", (e) => { input.targetX = pointerX(e); });
  canvas.addEventListener("pointerdown", (e) => { canvas.setPointerCapture(e.pointerId); input.targetX = pointerX(e); });
  canvas.addEventListener("pointerup", (e) => { if (e.pointerType !== "mouse") input.targetX = null; });
  canvas.addEventListener("pointercancel", () => { input.targetX = null; });
  document.addEventListener("visibilitychange", () => { last = performance.now(); });

  // --- drawing ----------------------------------------------------------------------------------
  function drawBackground(t) {
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, "#0a1030");
    g.addColorStop(1, "#1a1148");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    ctx.fillStyle = "#cfe3ff";
    for (const s of stars) {
      const y = (s.y + t * 0.02 * s.s * 10) % H;
      ctx.globalAlpha = 0.35 + s.s * 0.25;
      ctx.fillRect(s.x, y, s.s * 1.6, s.s * 1.6);
    }
    ctx.globalAlpha = 1;
  }

  function drawShip(p, blinking) {
    if (blinking && Math.floor(performance.now() / 90) % 2 === 0) return;
    ctx.save();
    ctx.translate(p.x, p.y);
    ctx.fillStyle = "#5ee7ff";
    ctx.beginPath();
    ctx.moveTo(0, -p.r * 1.3);
    ctx.lineTo(p.r, p.r);
    ctx.lineTo(0, p.r * 0.5);
    ctx.lineTo(-p.r, p.r);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = "#ffb347";
    ctx.beginPath();
    ctx.moveTo(-p.r * 0.35, p.r * 0.75);
    ctx.lineTo(0, p.r * (1.5 + Math.random() * 0.5));
    ctx.lineTo(p.r * 0.35, p.r * 0.75);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  function drawObject(o) {
    ctx.save();
    ctx.translate(o.x, o.y);
    if (o.kind === "crystal") {
      ctx.shadowColor = "#7dffb0";
      ctx.shadowBlur = 14;
      ctx.fillStyle = "#7dffb0";
      ctx.beginPath();
      ctx.moveTo(0, -o.r * 1.3);
      ctx.lineTo(o.r, 0);
      ctx.lineTo(0, o.r * 1.3);
      ctx.lineTo(-o.r, 0);
      ctx.closePath();
      ctx.fill();
    } else {
      ctx.rotate(o.y * 0.01 * (o.spin || 1));
      ctx.fillStyle = "#8a6f5c";
      ctx.beginPath();
      ctx.arc(0, 0, o.r, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "rgba(0,0,0,.25)";
      ctx.beginPath();
      ctx.arc(-o.r * 0.3, -o.r * 0.2, o.r * 0.25, 0, Math.PI * 2);
      ctx.arc(o.r * 0.35, o.r * 0.3, o.r * 0.18, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  function drawHud() {
    ctx.fillStyle = "#e8ecff";
    ctx.font = "600 22px system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.fillText(String(state.score), 14, 32);
    ctx.textAlign = "right";
    ctx.fillStyle = state.combo > 1 ? "#7dffb0" : "#9aa6d6";
    ctx.font = "600 16px system-ui, sans-serif";
    ctx.fillText(`x${state.combo}`, W - 14, 30);
    ctx.fillStyle = "#ff6b8b";
    for (let i = 0; i < state.lives; i++) {
      ctx.beginPath();
      ctx.arc(W - 20 - i * 22, 52, 7, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function draw(t) {
    drawBackground(t);
    for (const o of state.objects) drawObject(o);
    drawShip(state.player, mode === "playing" && state.invulnerableMs > 0);
    if (flash > 0) {
      ctx.fillStyle = `rgba(255, 80, 80, ${Math.min(0.4, flash / 400)})`;
      ctx.fillRect(0, 0, W, H);
    }
    drawHud();
  }

  // --- loop ------------------------------------------------------------------------------------------
  function frame(now) {
    const dt = now - last;
    last = now;
    if (mode === "playing") {
      const events = step(state, dt, input);
      if (events.includes("hit")) flash = 400;
      if (events.includes("over")) gameOver();
    }
    flash = Math.max(0, flash - dt);
    draw(now);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame((now) => { last = now; frame(now); });

  // --- first screen ---------------------------------------------------------------------------------------
  setMessage(API ? "" : "Offline mode: scores are not saved.");
  loadBoard();

  // Exposed for automated checks only.
  window.__starfall = { get state() { return state; }, get mode() { return mode; } };
})();
