// The text panels: a model call, a step, and the difference between two reads.
import { h } from "preact";
import htm from "htm";

const html = htm.bind(h);

const role = (item) => (item?.role || "").replace(/^AX/, "") || "Item";

export function describe(item) {
  if (!item) return "—";
  let text = `${role(item)} “${item.name || ""}”`;
  if (item.value && item.value !== item.name) text += ` = “${String(item.value).slice(0, 80)}”`;
  if (item.in) text += ` (in the ${item.in})`;
  return text;
}

const frame = (item) => item && item.x != null
  ? `${Math.round(item.x)},${Math.round(item.y)} ${Math.round(item.w || 0)}×${Math.round(item.h || 0)} pt`
  : "";

const pretty = (value) => (typeof value === "string" ? value : JSON.stringify(value, null, 1));

// Pydantic AI sends some contents as a list of parts. A picture is its file.
const textOf = (content) => (Array.isArray(content)
  ? content.map((part) => part?.text ?? part?.image_url?.url ?? part?.image_url ?? "").join("")
  : String(content ?? ""));

// A chat message (older runs), or a Responses input item: [label, text].
function said(m) {
  if (m.type === "function_call") return [`call ${m.name}`, m.arguments ?? ""];
  if (m.type === "function_call_output") return ["result", textOf(m.output)];
  if (m.type === "reasoning") return ["reasoning", textOf(m.summary)];
  return [m.role, m.content != null ? textOf(m.content) : m.tool_calls ? pretty(m.tool_calls) : ""];
}

const MARKS = { pending: "[ ]", in_progress: "[~]", completed: "[x]", cancelled: "[-]", blocked: "[!]" };

function Messages({ messages }) {
  // The newest screen is the last message that lists [ID] lines.
  let newest = -1;
  messages.forEach((m, i) => { if (/^\[\d+\] /m.test(said(m)[1])) newest = i; });
  return html`<div class="messages">
    ${messages.map((m, i) => {
      const [label, text] = said(m);
      return html`<details key=${i} open=${i === newest}>
        <summary><b>${label}</b> <span class="muted">${text.split("\n")[0].slice(0, 120)}</span>
          <span class="muted small"> · ${text.length} chars</span></summary>
        <pre>${text}</pre>
      </details>`;
    })}
  </div>`;
}

export function CallPanel({ call, tree }) {
  const byId = new Map((tree?.snapshot.items || []).map((i) => [i.id, i]));
  const target = (id) => {
    if (id == null) return "";
    const item = byId.get(call.ids?.[id]) || call.seen?.[id];
    return item ? describe(item) : "";
  };
  return html`<section class="panel">
    <h3>Call ${call.n} <span class="muted small">· ${call.kind} · ${call.ms} ms ·
      ${call.tokens?.in ?? 0} tokens in, ${call.tokens?.out ?? 0} out · screen from tree ${call.tree ?? "—"}</span></h3>
    ${call.error && html`<p class="error">${call.error}</p>`}
    ${call.steer?.length > 0 && html`<details open><summary>the user said, during the run</summary>
      <pre>${call.steer.join("\n")}</pre>
    </details>`}
    ${call.plan?.length > 0 && html`<details open><summary>plan after the call</summary>
      <pre>${call.plan.map((t, k) => `${k + 1}. ${MARKS[t.status] || t.status} ${t.content}`).join("\n")}</pre>
    </details>`}
    ${(call.tools || []).map((tool, n) => html`<div class="tool" key=${n}>
      <p><b>${tool.name}</b>${tool.args?.why ? html` — <i>${tool.args.why}</i>` : ""}</p>
      ${tool.name === "act" && Array.isArray(tool.args?.steps) ? html`<table class="kv">
        ${tool.args.steps.map((s, k) => html`<tr key=${k}><td>${s.do}</td><td>[${s.id ?? ""}]</td>
          <td>${s.value ?? ""}</td><td class="muted">${target(s.id)}</td>
          <td class="muted">${s.expect ? `→ ${s.expect}` : ""}</td></tr>`)}
      </table>` : html`<pre>${pretty(tool.args)}</pre>`}
      ${call.results?.[n] && html`<details open><summary>result</summary>
        <pre>${call.results[n].result}</pre></details>`}
    </div>`)}
    ${call.reply != null && html`<details open><summary>answer</summary>
      <pre>${(() => { try { return pretty(JSON.parse(call.reply)); } catch { return pretty(call.reply); } })()}</pre>
    </details>`}
    <h4>Messages as sent (${call.messages.length})</h4>
    <${Messages} messages=${call.messages} />
  </section>`;
}

export function StepPanel({ step }) {
  const how = step.pressed === true ? "accessibility press" : step.pressed === false ? "real click" : "—";
  return html`<section class="panel">
    <h3>Step ${step.n} <span class="muted small">· ${step.ms} ms${step.call != null ? ` · from call ${step.call}` : ""}
      · tree ${step.tree_before ?? "—"} → ${step.tree_after ?? "—"}</span></h3>
    ${step.error && html`<p class="error">${step.error}</p>`}
    <table class="kv">
      <tr><td>do</td><td><b>${step.do}</b>${step.value ? ` “${step.value}”` : ""}</td></tr>
      <tr><td>target</td><td>${describe(step.target)} <span class="muted">${frame(step.target)}</span>
        ${step.target?.state?.length ? html` <span class="muted">[${step.target.state.join(", ")}]</span>` : ""}</td></tr>
      <tr><td>how</td><td>${how}${step.point ? ` at ${step.point.map(Math.round).join(",")}` : ""}</td></tr>
      ${step.under && html`<tr><td>under</td><td>${describe(step.under)} <span class="muted">${frame(step.under)}</span></td></tr>`}
      <tr><td>change</td><td>${step.sentence || step.outcome || "—"}</td></tr>
      ${step.expect && html`<tr><td>expect</td><td>${step.expect} <span class="muted">· ${
        step.expect_p == null ? "not checked" : `${step.expect_p < 0.5 ? "no" : "yes"} ${step.expect_p.toFixed(2)}`}
        · ${step.expect_ms} ms</span></td></tr>`}
      ${step.lost && html`<tr><td>lost</td><td class="error">${step.lost}</td></tr>`}
    </table>
    ${step.asked?.length > 0 && html`<h4>Asked</h4>
      <table class="kv">${step.asked.map((a, i) => html`<tr key=${i}><td>${a.question}</td>
        <td><b>${a.answer ?? "no answer"}</b> <span class="muted">(${a.via})</span></td></tr>`)}</table>`}
    ${step.change && Object.keys(step.change).length > 0 && html`<details><summary>change data</summary>
      <pre>${pretty(step.change)}</pre></details>`}
    ${step.planned && html`<details><summary>the step as asked</summary><pre>${pretty(step.planned)}</pre></details>`}
    <details><summary>sent to the app (${step.actions.length})</summary>
      ${step.actions.map((a, i) => html`<pre key=${i}>${a.do} ${pretty(a.args)} → ${pretty(a.reply)} · ${a.ms} ms</pre>`)}
    </details>
  </section>`;
}

const identity = (i) => `${i.kind}\u0001${i.role}\u0001${i.name}`;

function diff(before, after) {
  const was = new Map(), now = new Map();
  for (const i of before) was.set(identity(i), [...(was.get(identity(i)) || []), i]);
  for (const i of after) now.set(identity(i), [...(now.get(identity(i)) || []), i]);
  const added = [], removed = [], changed = [];
  for (const [key, items] of now) {
    const old = was.get(key) || [];
    items.slice(old.length).forEach((i) => added.push(i));
    items.slice(0, old.length).forEach((i, n) => {
      const o = old[n];
      const state = (s) => (s.state || []).join(", ");
      if ((o.value || "") !== (i.value || "") || state(o) !== state(i)) changed.push([o, i]);
    });
  }
  for (const [key, items] of was) {
    const kept = (now.get(key) || []).length;
    items.slice(kept).forEach((i) => removed.push(i));
  }
  return { added, removed, changed };
}

export function TreeDiff({ before, after }) {
  if (!before || !after) return null;
  const { added, removed, changed } = diff(before.snapshot.items, after.snapshot.items);
  const window = before.snapshot.window !== after.snapshot.window
    ? `window “${before.snapshot.window}” → “${after.snapshot.window}”` : "";
  const list = (items) => html`<ul class="items">${items.map((i, n) =>
    html`<li key=${n}>${describe(i)} <span class="muted small">${frame(i)}</span></li>`)}</ul>`;
  return html`<section class="panel">
    <h3>Tree ${before.n} → ${after.n} <span class="muted small">${window}</span></h3>
    <details open=${added.length > 0 && added.length <= 30}><summary class="added-text">${added.length} added</summary>${list(added)}</details>
    <details open=${removed.length > 0 && removed.length <= 30}><summary class="gone-text">${removed.length} removed</summary>${list(removed)}</details>
    <details open=${changed.length > 0}><summary>${changed.length} changed</summary>
      <ul class="items">${changed.map(([o, i], n) => html`<li key=${n}>${role(i)} “${i.name}”:
        ${(o.value || "") !== (i.value || "") ? html` “${o.value || ""}” → “${i.value || ""}”` : ""}
        ${(o.state || []).join(",") !== (i.state || []).join(",")
          ? html` [${(o.state || []).join(", ")}] → [${(i.state || []).join(", ")}]` : ""}</li>`)}</ul>
    </details>
  </section>`;
}
