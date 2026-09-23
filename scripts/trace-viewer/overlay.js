// The picture: the screenshot of one tree read, with the tree drawn over it
// in SVG. Everything is in the image's pixels: a point (x, y) on screen is
// ((x - frame.x) * scale, (y - frame.y) * scale), with the shot's frame and
// scale as the recorder stored them. Items carry their centre and size.
import { h } from "preact";
import { useEffect } from "preact/hooks";
import { signal } from "@preact/signals";
import htm from "htm";

const html = htm.bind(h);

const LAYERS = [
  ["all", "all items"],
  ["shown", "shown to the model"],
  ["target", "target and click"],
  ["under", "hit test"],
  ["popup", "pop-ups"],
  ["ocr", "looked (OCR)"],
  ["ground", "grounded"],
  ["seen", "seen at the read"],
  ["change", "change"],
];

function stored(key, fallback) {
  try {
    const value = JSON.parse(localStorage.getItem(key));
    return value ?? fallback;
  } catch {
    return fallback;
  }
}

function store(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private window */ }
}

const layers = signal(stored("trace-viewer.layers",
  { all: true, shown: true, target: true, under: true, popup: true, ocr: true, seen: true,
    change: true, ground: true }));
const fade = signal(stored("trace-viewer.fade", 1));
const side = signal("before");
const hover = signal(null);

const keyOf = (item) => `${item.kind}\u0001${item.name}`;
const lineKey = (line) => `${String(line.text).split(/\s+/).join(" ")}@${Math.round(line.x)},${Math.round(line.y)}`;

// The seen lines the step reported: text not in the tree, and controls
// still on screen that left it. Only for the read after the step.
function reported(step, n) {
  const kept = new Set();
  if (!step || step.tree_after !== n || !step.change) return kept;
  for (const block of step.change.seen || []) for (const line of block.lines) kept.add(lineKey(line));
  for (const line of step.change.still || []) kept.add(lineKey(line));
  return kept;
}

function geometry(tree) {
  const shot = tree.shot;
  if (shot && shot.frame && shot.w && shot.frame.w) {
    return { x: shot.frame.x, y: shot.frame.y, scale: shot.w / shot.frame.w,
             w: shot.w, h: shot.h, image: shot.file };
  }
  const f = tree.snapshot.frame || { x: 0, y: 0, w: 1000, h: 800 };
  return { x: f.x, y: f.y, scale: 1, w: f.w || 1000, h: f.h || 800, image: null };
}

function box(g, item) {
  const w = item.w || 0, hh = item.h || 0;
  return { x: (item.x - w / 2 - g.x) * g.scale, y: (item.y - hh / 2 - g.y) * g.scale,
           w: w * g.scale, h: hh * g.scale };
}

// The drawing grows past the window for items outside it: Outlook draws its
// suggestion list there.
function viewBox(g, items) {
  let x0 = 0, y0 = 0, x1 = g.w, y1 = g.h;
  for (const item of items) {
    const b = box(g, item);
    if (!isFinite(b.x) || !isFinite(b.y)) continue;
    x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y);
    x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h);
  }
  const pad = 4 * g.scale;
  return [x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad];
}

function same(a, b) {
  return a && b && a.name === b.name && Math.abs(a.x - b.x) < 2 && Math.abs(a.y - b.y) < 2
    && Math.abs((a.w || 0) - (b.w || 0)) < 2 && Math.abs((a.h || 0) - (b.h || 0)) < 2;
}

function Rect({ g, item, cls, label, dash }) {
  const b = box(g, item);
  if (!(b.w > 0 && b.h > 0)) return null;
  const size = 11 * g.scale;
  return html`<g class=${cls}>
    <rect x=${b.x} y=${b.y} width=${b.w} height=${b.h} vector-effect="non-scaling-stroke"
      stroke-dasharray=${dash ? "4 3" : null}
      onMouseMove=${(e) => (hover.value = { item, x: e.clientX, y: e.clientY })}
      onMouseLeave=${() => (hover.value = null)} />
    ${label != null && html`<text x=${b.x + 1} y=${b.y - 2} font-size=${size}>${label}</text>`}
  </g>`;
}

function Tip() {
  const at = hover.value;
  if (!at) return null;
  const i = at.item;
  const state = (i.state || []).join(", ");
  return html`<div class="tip" style=${{ left: `${at.x + 14}px`, top: `${at.y + 14}px` }}>
    <b>${(i.role || "").replace(/^AX/, "") || "Item"}</b> ${i.name ? `“${i.name}”` : ""}
    ${i.value && html`<div>= “${String(i.value).slice(0, 200)}”</div>`}
    ${state && html`<div>state: ${state}</div>`}
    ${i.in && html`<div>in: ${i.in}</div>`}
    <div class="muted">${i.kind || ""}${i.id != null ? ` · id ${i.id}` : ""} ·
      ${Math.round(i.x)},${Math.round(i.y)} ${Math.round(i.w || 0)}×${Math.round(i.h || 0)} pt</div>
  </div>`;
}

function Legend({ isStep, hasShot }) {
  const set = (key, on) => {
    layers.value = { ...layers.value, [key]: on };
    store("trace-viewer.layers", layers.value);
  };
  return html`<div class="legend">
    ${isStep && html`<span class="seg">
      ${["before", "after"].map((s) => html`<button class=${side.value === s ? "on" : ""}
        onClick=${() => (side.value = s)}>${s}</button>`)}
    </span>`}
    ${LAYERS.map(([key, name]) => html`<label class=${`layer ${key}`}>
      <input type="checkbox" checked=${layers.value[key]}
        onChange=${(e) => set(key, e.currentTarget.checked)} />
      <i></i>${name}</label>`)}
    ${hasShot && html`<label class="fade">screenshot
      <input type="range" min="0" max="1" step="0.05" value=${fade.value}
        onInput=${(e) => { fade.value = +e.currentTarget.value; store("trace-viewer.fade", fade.value); }} />
    </label>`}
  </div>`;
}

export function Picture({ trees, loadTree, fileUrl, treeN, prevN, step, call, looks, grounds = [] }) {
  let n = treeN, prev = prevN;
  if (step) {
    const after = step.tree_after ?? step.tree_before;
    n = side.value === "after" ? after : step.tree_before;
    prev = side.value === "after" ? step.tree_before : (step.tree_before ?? 1) - 1;
  }
  useEffect(() => { loadTree(n); loadTree(prev); }, [n, prev]);
  const tree = trees[n];
  if (n == null) return html`<div class="picture empty muted">No window was read.</div>`;
  if (!tree) return html`<div class="picture empty muted">Loading tree ${n}…</div>`;

  const g = geometry(tree);
  const items = tree.snapshot.items || [];
  const before = trees[prev];
  const on = layers.value;
  const byId = new Map(items.map((i) => [i.id, i]));

  const shown = [];
  if (call) {
    for (const [label, id] of Object.entries(call.ids || {})) {
      if (byId.has(id)) shown.push([label, byId.get(id), false]);
    }
    if (call.tree === n) {
      for (const [label, item] of Object.entries(call.seen || {})) shown.push([label, item, true]);
    }
  }
  let added = [], gone = [];
  if (before && on.change) {
    const was = new Set(before.snapshot.items.map(keyOf));
    const now = new Set(items.map(keyOf));
    added = items.filter((i) => i.kind !== "more" && !was.has(keyOf(i)));
    gone = before.snapshot.items.filter((i) => i.kind !== "more" && !now.has(keyOf(i)));
  }
  const lines = on.ocr ? looks.flatMap((l) => l.lines || []) : [];
  const seen = on.seen ? tree.seen || [] : [];
  const kept = reported(step, n);
  const target = step?.target;
  const under = step?.under && step.under.w ? step.under : null;
  const everything = [...items, ...gone, ...lines, ...(target && target.w ? [target] : []), ...(under ? [under] : [])];
  const vb = viewBox(g, everything);
  const dot = step?.point && { x: (step.point[0] - g.x) * g.scale, y: (step.point[1] - g.y) * g.scale };
  const bySize = [...items].sort((a, b) => b.w * b.h - a.w * a.h);
  // A `ground` call: its crop, dashed, and the point it found, or a cross
  // at the crop's centre when it found nothing. A stuck turn's picture has
  // no point.
  const grounded = on.ground ? grounds.filter((gr) => gr.tree === n && gr.region) : [];
  const at = (p) => ({ x: (p[0] - g.x) * g.scale, y: (p[1] - g.y) * g.scale });

  return html`<div class="picture">
    <${Legend} isStep=${!!step} hasShot=${!!g.image} />
    <div class="canvas">
      <svg viewBox=${vb.join(" ")} preserveAspectRatio="xMidYMin meet">
        <rect class="window" x="0" y="0" width=${g.w} height=${g.h} />
        ${g.image && html`<image href=${fileUrl(g.image)} x="0" y="0" width=${g.w} height=${g.h}
          opacity=${fade.value} />`}
        ${on.all && bySize.map((i) => html`<${Rect} g=${g} item=${i} cls="all" />`)}
        ${on.popup && items.filter((i) => i.in).map((i) => html`<${Rect} g=${g} item=${i} cls="popup" />`)}
        ${added.map((i) => html`<${Rect} g=${g} item=${i} cls="added" />`)}
        ${gone.map((i) => html`<${Rect} g=${g} item=${i} cls="gone" dash />`)}
        ${on.shown && shown.map(([label, i, seen]) =>
          html`<${Rect} g=${g} item=${i} cls="shown" label=${`[${label}]`} dash=${seen} />`)}
        ${on.ocr && looks.map((l) => l.region && l.region.w &&
          html`<${Rect} g=${g} item=${l.region} cls="region" dash />`)}
        ${lines.map((i) => html`<${Rect} g=${g} item=${{ ...i, name: i.text, role: "Seen", kind: "seen" }} cls="ocr" />`)}
        ${seen.map((i) => html`<${Rect} g=${g} item=${{ ...i, name: i.text, role: "Seen", kind: "seen" }}
          cls=${kept.has(lineKey(i)) ? "seen" : "seen faint"} />`)}
        ${on.under && under && !same(under, target) && html`<${Rect} g=${g} item=${under} cls="under" label="under" />`}
        ${on.target && target && html`<${Rect} g=${g} item=${target} cls="target" />`}
        ${on.target && dot && html`<circle class="dot" cx=${dot.x} cy=${dot.y} r=${5 * g.scale} />`}
        ${grounded.map((gr) => html`<g class="ground">
          <${Rect} g=${g} item=${{ ...gr.region, name: gr.description, role: `ground: ${gr.method}`, kind: gr.why || "" }}
            dash label=${gr.method} />
          ${gr.point ? html`<circle cx=${at(gr.point).x} cy=${at(gr.point).y} r=${5 * g.scale} />`
            : gr.method !== "image" && html`<text class="miss" x=${at([gr.region.x, gr.region.y]).x}
                y=${at([gr.region.x, gr.region.y]).y} font-size=${14 * g.scale}>× not found</text>`}
        </g>`)}
      </svg>
    </div>
    <p class="muted small">Tree ${n}${step ? ` (${side.value} the step)` : ""} ·
      ${tree.snapshot.app} “${tree.snapshot.window}” · ${items.length} items ·
      ${g.image ? `screenshot ${g.w}×${g.h} px at ${g.scale.toFixed(2)} px/pt`
                : `no screenshot${tree.shot_error ? `: ${tree.shot_error}` : ""}`}
      ${tree.seen ? ` · ${tree.seen.length} lines seen in ${tree.seen_ms ?? "?"} ms, ${kept.size} reported` : ""}
      ${before && on.change ? ` · change from tree ${prev}: ${added.length} new, ${gone.length} gone` : ""}</p>
    <${Tip} />
  </div>`;
}
