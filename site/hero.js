// A terrestrial laser scan, drawn live: points on a small building and the
// rings a tripod scanner leaves on the ground, revealed as the scanner head
// sweeps round. Decorative; pauses off screen and for reduced motion.
const canvas = document.querySelector(".scan canvas");
const counter = document.querySelector(".scan .count");
const ctx = canvas.getContext("2d");
const still = matchMedia("(prefers-reduced-motion: reduce)");

let seed = 7;
const rand = () => {
  seed = (seed * 16807) % 2147483647;
  return (seed - 1) / 2147483646;
};

const SCANNER = { x: 2.0, z: 1.55 };
const TAU = Math.PI * 2;
const points = [];

function add(x, y, z, kind = "wall") {
  let az = Math.atan2(z - SCANNER.z, x - SCANNER.x);
  if (az < 0) az += TAU;
  points.push({ x, y, z, az, kind });
}

function inOpening(u, y) {
  const windows = [[-0.72, -0.32], [0.32, 0.72]];
  if (y > 0.42 && y < 0.74 && windows.some(([a, b]) => u > a && u < b)) return true;
  return Math.abs(u) < 0.14 && y < 0.62;
}

// Walls: a 2 x 1.4 box, 1 high, with a door and two windows on the front.
for (let i = 0; i < 1500; i++) {
  const side = rand();
  const y = rand();
  if (side < 0.36) {
    const x = rand() * 2 - 1;
    if (!inOpening(x, y)) add(x, y, 0.7);
  } else if (side < 0.62) {
    add(rand() * 2 - 1, y, -0.7);
  } else if (side < 0.81) {
    add(1, y, rand() * 1.4 - 0.7);
  } else {
    add(-1, y, rand() * 1.4 - 0.7);
  }
}

// Gable roof and the two gable ends.
for (let i = 0; i < 900; i++) {
  const t = rand();
  const x = rand() * 2.16 - 1.08;
  const sideZ = rand() < 0.5 ? -1 : 1;
  add(x, 1 + 0.55 * t, sideZ * 0.76 * (1 - t), "roof");
}
for (let i = 0; i < 260; i++) {
  const y = 1 + rand() * 0.55;
  const half = 0.7 * (1 - (y - 1) / 0.55);
  add(rand() < 0.5 ? -1 : 1, y, (rand() * 2 - 1) * half);
}

// Ground: the concentric rings around the tripod, denser close to it.
for (let k = 1; k <= 16; k++) {
  const r = 0.22 * k;
  const n = Math.round(150 - k * 5);
  for (let i = 0; i < n; i++) {
    const a = (i / n) * TAU + rand() * 0.01;
    const x = SCANNER.x + Math.cos(a) * r;
    const z = SCANNER.z + Math.sin(a) * r;
    if (Math.abs(x) < 1.02 && Math.abs(z) < 0.72) continue; // shadowed by the building
    if (Math.hypot(x, z) > 3.6) continue;
    add(x, 0, z, "ground");
  }
}

counter.textContent = points.length.toLocaleString("en-US");

let ink = "#141414";
let signal = "#ff4f00";
function readColors() {
  const css = getComputedStyle(document.documentElement);
  ink = css.getPropertyValue("--ink").trim() || ink;
  signal = css.getPropertyValue("--signal").trim() || signal;
}
readColors();
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", readColors);

let width = 0;
let height = 0;
let dpr = 1;
function resize() {
  dpr = Math.min(window.devicePixelRatio || 1, 2);
  const box = canvas.getBoundingClientRect();
  width = box.width;
  height = box.height;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
new ResizeObserver(() => {
  resize();
  if (still.matches) draw(0.6, TAU + 1);
}).observe(canvas);

const SWEEP_SECONDS = 7;
const HOLD_SECONDS = 2.5;

function draw(yaw, sweep) {
  ctx.clearRect(0, 0, width, height);
  const cx = width / 2;
  const cy = height * 0.64;
  const focal = Math.min(width, height) * 2.05;
  const distance = 6.2;
  const pitch = 0.42;
  const cosY = Math.cos(yaw), sinY = Math.sin(yaw);
  const cosP = Math.cos(pitch), sinP = Math.sin(pitch);

  const project = (x, y, z) => {
    const rx = x * cosY - z * sinY;
    const rz = x * sinY + z * cosY;
    const py = (y - 0.45) * cosP - rz * sinP;
    const pz = (y - 0.45) * sinP + rz * cosP;
    const s = focal / (distance + pz);
    return [cx + rx * s, cy - py * s, s];
  };

  for (const p of points) {
    const captured = p.az <= sweep;
    const edge = captured && sweep - p.az < 0.09;
    const [sx, sy, s] = project(p.x, p.y, p.z);
    const size = (p.kind === "ground" ? 0.85 : 1.15) * (s / focal) * 6.2;
    ctx.globalAlpha = edge ? 1 : captured ? (p.kind === "ground" ? 0.45 : 0.82) : 0.07;
    ctx.fillStyle = edge ? signal : ink;
    ctx.fillRect(sx - size / 2, sy - size / 2, size, size);
  }

  // The scanner on its tripod, and its beam.
  const [tx, ty] = project(SCANNER.x, 0.32, SCANNER.z);
  const [fx, fy] = project(SCANNER.x, 0, SCANNER.z);
  ctx.globalAlpha = 1;
  ctx.strokeStyle = ink;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (const dx of [-9, 0, 9]) {
    ctx.moveTo(tx, ty);
    ctx.lineTo(fx + dx, fy + 4);
  }
  ctx.stroke();
  ctx.fillStyle = signal;
  ctx.fillRect(tx - 3, ty - 6, 6, 6);
  if (sweep < TAU) {
    const reach = 3.4;
    const [bx, by] = project(SCANNER.x + Math.cos(sweep) * reach, 0.5, SCANNER.z + Math.sin(sweep) * reach);
    const beam = ctx.createLinearGradient(tx, ty - 3, bx, by);
    beam.addColorStop(0, signal);
    beam.addColorStop(1, "transparent");
    ctx.strokeStyle = beam;
    ctx.globalAlpha = 0.7;
    ctx.beginPath();
    ctx.moveTo(tx, ty - 3);
    ctx.lineTo(bx, by);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

let visible = true;
new IntersectionObserver(([entry]) => {
  visible = entry.isIntersecting;
}).observe(canvas);

const start = performance.now();
function frame(now) {
  const t = (now - start) / 1000;
  if (visible && !still.matches) {
    const cycle = t % (SWEEP_SECONDS + HOLD_SECONDS);
    const sweep = Math.min(cycle / SWEEP_SECONDS, 1) * (TAU + 0.2);
    draw(0.55 + t * 0.06, sweep);
  }
  requestAnimationFrame(frame);
}

resize();
if (still.matches) draw(0.6, TAU + 1);
requestAnimationFrame(frame);
