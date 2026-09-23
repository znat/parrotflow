// The run viewer: runs on the left, the selected run's timeline under them,
// the selected row on the right. Data comes from serve.py.
import { h, render } from "preact";
import { useEffect } from "preact/hooks";
import { signal, computed, effect } from "@preact/signals";
import htm from "htm";
import { Picture } from "./overlay.js";
import { CallPanel, StepPanel, TreeDiff } from "./panels.js";

const html = htm.bind(h);

const runs = signal([]);
const runId = signal(null);
const run = signal(null);          // /api/run/<id>
const calls = signal({});          // n -> call
const steps = signal({});
const looks = signal({});
const grounds = signal({});
const trees = signal({});          // n -> tree
const selected = signal(null);     // "call:3" | "step:2"
const live = signal(false);
const failed = signal("");
// A run whose run.json has not moved for this long is not live: a crashed
// runner never writes `ended`.
const STALE_SECONDS = 120;

async function get(path) {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}

const number = (file) => parseInt(file, 10);
const fileUrl = (path) => `/runs/${runId.value}/${path}`;

async function loadRuns() {
  try {
    runs.value = await get("/api/runs");
    failed.value = "";
  } catch (error) {
    failed.value = String(error);
  }
}

async function fetchMissing(part, store, files) {
  const have = store.value;
  const missing = files.filter((f) => f.endsWith(".json") && !(number(f) in have));
  if (!missing.length) return;
  const got = await Promise.all(missing.map((f) => get(fileUrl(`${part}/${f}`)).catch(() => null)));
  const next = { ...store.value };
  got.forEach((record) => { if (record) next[record.n] = record; });
  store.value = next;
}

async function loadRun(id) {
  const fresh = id !== runId.value;
  if (fresh) {
    runId.value = id;
    calls.value = {}; steps.value = {}; looks.value = {}; grounds.value = {}; trees.value = {};
    selected.value = null;
  }
  const rows = timeline.value;
  const wasLast = !selected.value || (rows.length && selected.value === rows[rows.length - 1].key);
  try {
    const found = await get(`/api/run/${encodeURIComponent(id)}`);
    if (runId.value !== id) return;
    run.value = found;
    await Promise.all([
      fetchMissing("calls", calls, found.files.calls),
      fetchMissing("steps", steps, found.files.steps),
      fetchMissing("looks", looks, found.files.looks),
      fetchMissing("grounds", grounds, found.files.grounds || []),
    ]);
  } catch (error) {
    failed.value = String(error);
    return;
  }
  const now = timeline.value;
  if (now.length && (fresh || (live.value && wasLast))) selected.value = now[now.length - 1].key;
}

async function loadTree(n) {
  if (n == null || n in trees.value || !runId.value) return;
  const file = `trees/${String(n).padStart(2, "0")}.json`;
  if (!run.value?.files.trees.includes(file.slice(6))) return;
  try {
    const tree = await get(fileUrl(file));
    trees.value = { ...trees.value, [n]: tree };
  } catch (error) {
    failed.value = String(error);
  }
}

// Calls and steps in the order they happened.
const timeline = computed(() => {
  const rows = [
    ...Object.values(calls.value).map((c) => ({ key: `call:${c.n}`, seq: c.seq, call: c })),
    ...Object.values(steps.value).map((s) => ({ key: `step:${s.n}`, seq: s.seq, step: s })),
  ];
  return rows.sort((a, b) => a.seq - b.seq);
});

const current = computed(() => timeline.value.find((r) => r.key === selected.value) || null);

function isLive(entry) {
  return entry && entry.end == null && entry.age != null && entry.age < STALE_SECONDS;
}

// The hash keeps the place across a reload: #<run id>/<row key>.
async function start() {
  await loadRuns();
  const [id, key] = decodeURIComponent(location.hash.slice(1)).split("/");
  const newest = runs.value[0];
  if (id && runs.value.some((r) => r.id === id)) {
    await loadRun(id);
    if (key && timeline.value.some((r) => r.key === key)) selected.value = key;
  } else if (newest) {
    live.value = isLive(newest);
    await loadRun(newest.id);
  }
  effect(() => {
    if (runId.value) history.replaceState(null, "", `#${runId.value}/${selected.value || ""}`);
  });
}

let timer = null;
effect(() => {
  clearInterval(timer);
  if (!live.value) return;
  timer = setInterval(async () => {
    const before = runs.value[0]?.id;
    await loadRuns();
    const newest = runs.value[0];
    // A new run started: follow it.
    if (newest && newest.id !== before && newest.id !== runId.value) await loadRun(newest.id);
    else if (runId.value) await loadRun(runId.value);
  }, 1000);
});

function move(by) {
  const rows = timeline.value;
  if (!rows.length) return;
  const at = rows.findIndex((r) => r.key === selected.value);
  const next = Math.max(0, Math.min(rows.length - 1, (at < 0 ? 0 : at) + by));
  selected.value = rows[next].key;
  document.querySelector(`[data-key="${rows[next].key}"]`)?.scrollIntoView({ block: "nearest" });
}

// Views

function mark(end) {
  if (end == null) return html`<span class="mark live" title="in progress">●</span>`;
  if (["done", "ready", "planned"].includes(end)) return html`<span class="mark ok" title=${end}>✓</span>`;
  if (end === "failed") return html`<span class="mark bad" title="failed">✗</span>`;
  return html`<span class="mark stop" title=${end}>■</span>`;
}

function when(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const today = new Date().toDateString() === d.toDateString();
  return today ? d.toLocaleTimeString() : d.toLocaleString();
}

function RunList() {
  return html`<section class="runs">
    <header class="bar">
      <b>Runs</b>
      <label class="toggle"><input type="checkbox" checked=${live.value}
        onChange=${(e) => (live.value = e.currentTarget.checked)} /> live</label>
    </header>
    ${failed.value && html`<p class="error">${failed.value}</p>`}
    ${!runs.value.length && html`<p class="muted pad">No runs recorded yet.</p>`}
    <ul>
      ${runs.value.map((r) => html`<li key=${r.id} class=${r.id === runId.value ? "on" : ""}
          onClick=${() => loadRun(r.id)} title=${r.outcome}>
        ${mark(isLive(r) || r.end != null ? r.end : "stopped")}
        <span class="grow ellipsis">${r.request || "(nothing said)"}</span>
        <span class="muted small">${r.app} · ${when(r.started)} · ${r.steps} steps</span>
      </li>`)}
    </ul>
  </section>`;
}

function callSummary(call) {
  const tool = call.tools?.[0];
  if (call.error) return { ok: false, text: call.error };
  if (call.kind === "plan") return { ok: true, text: "plan" };
  if (!tool) return { ok: false, text: "no tool" };
  const result = String(call.results?.[0]?.result || "");
  const ok = !/^(Not run|Nothing ran|Could not)/.test(result) && !/— failed:/.test(result);
  const args = tool.args || {};
  let text = tool.name;
  if (tool.name === "act") {
    text += " " + (args.steps || []).map((s) => `${s.do} [${s.id ?? ""}] ${s.value ?? ""}`.trim()).join("; ");
  } else if (args.question || args.summary || args.why) {
    text += " " + (args.question || args.summary || args.why);
  }
  return { ok, text, why: tool.name === "act" ? args.why : "" };
}

function stepSummary(step) {
  const name = step.target?.name || step.value || "";
  const unchanged = step.outcome?.startsWith("the last step changed nothing");
  return {
    ok: !step.error, unchanged,
    text: `${step.do}${name ? ` “${name.slice(0, 50)}”` : ""}`,
    why: step.error || step.sentence,
  };
}

function Timeline() {
  const info = run.value?.run;
  if (!info) return null;
  return html`<section class="timeline">
    <header class="bar">
      ${mark(isLive(runs.value.find((r) => r.id === runId.value)) || info.end != null ? info.end : "stopped")}
      <b class="grow ellipsis" title=${info.request}>${info.request}</b>
    </header>
    <p class="muted small pad">${info.app} · ${info.kind || "?"} · ${info.model}
      ${info.outcome ? html` · ${info.outcome}` : ""}</p>
    <ol>
      ${timeline.value.map((row) => {
        const s = row.call ? callSummary(row.call) : stepSummary(row.step);
        return html`<li key=${row.key} data-key=${row.key}
            class=${`${row.call ? "call" : "step"} ${row.key === selected.value ? "on" : ""}`}
            onClick=${() => (selected.value = row.key)}>
          <span class=${`mark ${s.ok ? (s.unchanged ? "stop" : "ok") : "bad"}`}>${s.ok ? (s.unchanged ? "·" : "✓") : "✗"}</span>
          <span class="kind">${row.call ? `call ${row.call.n}` : `step ${row.step.n}`}</span>
          <span class="grow">
            <span class="ellipsis block">${s.text}</span>
            ${s.why && html`<span class="muted small ellipsis block">${s.why}</span>`}
          </span>
        </li>`;
      })}
    </ol>
  </section>`;
}

// Loads the trees a row needs; loadTree does nothing for one it has.
function Need({ ns }) {
  useEffect(() => { ns.forEach(loadTree); }, [ns.join(), runId.value]);
  return null;
}

function Detail() {
  const row = current.value;
  if (!row) return html`<main class="detail"><p class="muted pad">Pick a row.</p></main>`;
  const allLooks = Object.values(looks.value);
  const allGrounds = Object.values(grounds.value);
  const picture = { trees: trees.value, loadTree, fileUrl };
  if (row.call) {
    const call = row.call;
    const shown = allLooks.filter((l) => l.call === call.n && l.step == null);
    return html`<main class="detail">
      <${Need} ns=${[call.tree, call.tree - 1]} />
      <${Picture} ...${picture} key=${row.key} treeN=${call.tree}
        prevN=${call.tree ? call.tree - 1 : null} call=${call} looks=${shown}
        grounds=${allGrounds.filter((g) => g.call === call.n && g.step == null)} />
      <${CallPanel} call=${call} tree=${trees.value[call.tree]} />
      <${TreeDiff} before=${trees.value[call.tree - 1]} after=${trees.value[call.tree]} />
    </main>`;
  }
  const step = row.step;
  const call = step.call != null ? calls.value[step.call] : null;
  return html`<main class="detail">
    <${Need} ns=${[step.tree_before, step.tree_after]} />
    <${Picture} ...${picture} key=${row.key} step=${step} call=${call}
      looks=${allLooks.filter((l) => l.step === step.n)}
      grounds=${allGrounds.filter((g) => g.step === step.n)} />
    <${StepPanel} step=${step} />
    <${TreeDiff} before=${trees.value[step.tree_before]} after=${trees.value[step.tree_after]} />
  </main>`;
}

function App() {
  useEffect(() => {
    start();
    const onKey = (e) => {
      if (e.target.closest?.("input, textarea")) return;
      if (e.key === "ArrowDown") { move(1); e.preventDefault(); }
      if (e.key === "ArrowUp") { move(-1); e.preventDefault(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  return html`<div class="layout">
    <aside><${RunList} /><${Timeline} /></aside>
    <${Detail} />
  </div>`;
}

render(html`<${App} />`, document.getElementById("app"));
