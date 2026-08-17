const tokenInput = document.getElementById("admin-token");
const pageTitle = document.getElementById("page-title");
const pageKicker = document.getElementById("page-kicker");
const livePill = document.getElementById("live-pill");

const TITLES = {
  overview: ["Workspace", "Overview"],
  models: ["Workspace", "Models"],
  endpoints: ["Workspace", "Endpoints & keys"],
  stats: ["Data", "Audit"],
  tables: ["Data", "Tables"],
  docs: ["Data", "Documents"],
  stack: ["System", "OpenClaw stack"],
  logs: ["System", "Logs"],
};

if (tokenInput) {
  tokenInput.value = localStorage.getItem("medlock_admin") || "";
  tokenInput.onchange = () => {
    localStorage.setItem("medlock_admin", tokenInput.value.trim());
    loadOverview();
  };
}

function token() {
  return (tokenInput && tokenInput.value.trim()) || localStorage.getItem("medlock_admin") || "";
}

const headers = (json = true) => ({
  ...(json ? { "Content-Type": "application/json" } : {}),
  ...(token() ? { "X-MedLock-Token": token() } : {}),
});

async function api(path, opts = {}) {
  const res = await fetch(path, { credentials: "same-origin", headers: headers(), ...opts });
  if (res.status === 401) {
    throw new Error("Admin API 401 — paste MEDLOCK_ADMIN_TOKEN from .env into the sidebar, then retry.");
  }
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function formatCell(v) {
  if (v == null) return "";
  if (typeof v === "object") return JSON.stringify(v);
  return String(v);
}

function card(title, body, extra = "") {
  return `<article class="card ${extra}"><h3>${title}</h3>${body}</article>`;
}

function metric(title, value, sub) {
  return card(title, `<div class="metric"><div class="value">${escapeHtml(String(value))}</div><div class="sub">${sub}</div></div>`);
}

function setPanel(name) {
  document.querySelectorAll("nav button").forEach((b) => b.classList.toggle("active", b.dataset.panel === name));
  document.querySelectorAll(".panel").forEach((p) => p.classList.toggle("active", p.id === name));
  const t = TITLES[name] || ["Workspace", name];
  pageKicker.textContent = t[0];
  pageTitle.textContent = t[1];
}

document.querySelectorAll("nav button").forEach((btn) => {
  btn.onclick = () => {
    setPanel(btn.dataset.panel);
    if (btn.dataset.panel === "overview") loadOverview();
    if (btn.dataset.panel === "endpoints") loadKeys();
    if (btn.dataset.panel === "stats") loadStats();
    if (btn.dataset.panel === "tables") loadTables();
    if (btn.dataset.panel === "stack") loadStack();
    if (btn.dataset.panel === "logs") loadLogs();
  };
});

async function loadOverview() {
  const el = document.getElementById("overview");
  try {
    const d = await api("/api/admin/overview");
    const g = d.gpu || {};
    const s = d.stats || {};
    const e = d.endpoints || {};
    const llamaOk = Boolean(d.llama?.ok);
    livePill.innerHTML = `<span class="dot"></span> ${llamaOk ? "Inference up" : "Inference down"}`;
    livePill.classList.toggle("fail", !llamaOk);
    el.innerHTML = `
      <div class="cards">
        ${metric("Conversations", s.conversations ?? 0, "stored locally")}
        ${metric("Messages", s.messages ?? 0, "user + assistant")}
        ${metric("Audit events", s.audit_events ?? 0, "control-plane log")}
        ${metric("Avg latency", s.avg_latency_ms != null ? `${s.avg_latency_ms} ms` : "—", "assistant replies")}
      </div>
      <div class="grid-2" style="margin-top:1rem">
        ${card("Policy", `
          <div class="stat-line"><span>Cloud LLM</span><span class="${d.cloud_llm_blocked ? "ok" : "fail"}">${d.cloud_llm_blocked ? "blocked" : "enabled"}</span></div>
          <div class="stat-line"><span>Demo mode</span><span>${d.demo ? "on" : "off"}</span></div>
          <div class="stat-line"><span>ServiceNow</span><span>${d.servicenow_enabled ? "on" : "off"}</span></div>
        `)}
        ${card("Hardware", `
          <div class="stat-line"><span>Arch</span><span>${escapeHtml(g.arch || "unknown")}</span></div>
          <div class="stat-line"><span>GB10</span><span>${g.is_gb10 ? "yes" : "no"}</span></div>
          <div class="stat-line"><span>NVIDIA GPU</span><span>${g.nvidia_gpu_present ? "yes" : "no"}</span></div>
          <div class="stat-line"><span>CUDA</span><span>${escapeHtml(g.cuda_version || "n/a")}</span></div>
        `)}
        ${card("Inference", `
          <div class="stat-line"><span>llama-server</span><span class="${llamaOk ? "ok" : "fail"}">${llamaOk ? "healthy" : "down"}</span></div>
          <div class="stat-line"><span>Model file</span><span>${d.models?.ok ? "ok" : "missing"}</span></div>
        `)}
      </div>
    `;
    document.getElementById("endpoint-urls").innerHTML = `
      <h3>URLs</h3>
      <dl>
        <div><dt>Chat</dt><dd>${escapeHtml(e.chat || "")}</dd></div>
        <div><dt>Admin</dt><dd>${escapeHtml(e.admin || "")}</dd></div>
        <div><dt>OpenAI-compatible</dt><dd>${escapeHtml(e.openai || "")}</dd></div>
        <div><dt>llama.cpp</dt><dd>${escapeHtml(e.llama || "")}</dd></div>
      </dl>`;
  } catch (err) {
    livePill.innerHTML = `<span class="dot"></span> Unauthorized`;
    livePill.classList.add("fail");
    el.innerHTML = `<p class="fail">${escapeHtml(err.message)}</p>`;
  }
}

document.getElementById("upload-form").onsubmit = async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const res = await fetch("/api/admin/models/upload", {
    method: "POST",
    credentials: "same-origin",
    headers: token() ? { "X-MedLock-Token": token() } : {},
    body: fd,
  });
  document.getElementById("upload-out").textContent = await res.text();
};

document.getElementById("hf-search").onclick = async () => {
  const q = document.querySelector("#hf-form [name=q]").value;
  const data = await api(`/api/admin/models/huggingface/search?q=${encodeURIComponent(q)}`);
  const box = document.getElementById("hf-results");
  box.innerHTML = "";
  for (const m of data.results || []) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "hf-item";
    b.textContent = m.id;
    b.onclick = () => { document.querySelector("#hf-form [name=repo_id]").value = m.id; };
    box.appendChild(b);
  }
};

document.getElementById("hf-form").onsubmit = async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const data = await api("/api/admin/models/huggingface", {
    method: "POST",
    body: JSON.stringify({
      repo_id: fd.get("repo_id"),
      filename: fd.get("filename"),
      confirm: fd.get("confirm") === "on",
    }),
  });
  document.getElementById("hf-out").textContent = JSON.stringify(data, null, 2);
};

async function loadKeys() {
  const rows = await api("/api/admin/keys");
  const el = document.getElementById("key-list");
  if (!rows.length) {
    el.innerHTML = "<p class='muted'>No keys yet.</p>";
    return;
  }
  el.innerHTML = rows.map((r) =>
    `<div class="key-row ${r.revoked ? "revoked" : ""}">
      <div><strong>${escapeHtml(r.name)}</strong><br><code>${escapeHtml(r.key_prefix)}…</code></div>
      <span class="muted">${r.revoked ? "revoked" : "active"}</span>
      ${r.revoked ? "" : `<button data-id="${r.id}" class="revoke danger">Revoke</button>`}
    </div>`
  ).join("");
  document.querySelectorAll(".revoke").forEach((b) => {
    b.onclick = async () => {
      await api(`/api/admin/keys/${b.dataset.id}/revoke`, { method: "POST" });
      loadKeys();
    };
  });
}

document.getElementById("key-form").onsubmit = async (e) => {
  e.preventDefault();
  const name = new FormData(e.target).get("name");
  const data = await api("/api/admin/keys", { method: "POST", body: JSON.stringify({ name }) });
  document.getElementById("key-out").textContent = `${data.key}\n${data.warning}`;
  loadKeys();
};

async function loadStats() {
  const d = await api("/api/admin/stats");
  const types = Object.entries(d.by_type || {});
  const recent = d.recent || [];
  document.getElementById("stats-view").innerHTML = `
    <div class="grid-2">
      ${card("By event", types.length
        ? types.map(([k, v]) => `<div class="stat-line"><span>${escapeHtml(k)}</span><span>${v}</span></div>`).join("")
        : "<p class='muted'>No events yet.</p>")}
      ${card("Latest", recent.length
        ? `<div class="table-wrap"><table><thead><tr><th>Time</th><th>Event</th><th>Status</th><th>ms</th></tr></thead><tbody>${
            recent.map((r) => `<tr>
              <td>${escapeHtml((r.created_at || "").replace("T", " ").slice(0, 19))}</td>
              <td>${escapeHtml(r.event_type || "")}</td>
              <td>${escapeHtml(String(r.status_code ?? ""))}</td>
              <td>${escapeHtml(String(r.latency_ms ?? ""))}</td>
            </tr>`).join("")
          }</tbody></table></div>`
        : "<p class='muted'>No audit rows.</p>")}
    </div>`;
}

let currentTable = null;
let tableOffset = 0;
const PAGE = 50;

async function loadTables() {
  const d = await api("/api/admin/tables");
  const tabs = document.getElementById("table-tabs");
  tabs.innerHTML = "";
  for (const t of d.tables) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = t;
    b.onclick = () => showTable(t, 0);
    tabs.appendChild(b);
  }
  if (d.tables[0]) showTable(d.tables[0], 0);
}

async function showTable(name, offset) {
  currentTable = name;
  tableOffset = offset;
  document.querySelectorAll("#table-tabs button").forEach((b) => b.classList.toggle("active", b.textContent === name));
  const d = await api(`/api/admin/tables/${encodeURIComponent(name)}?limit=${PAGE}&offset=${offset}`);
  const table = document.getElementById("table-view");
  const cols = d.column_names || [];
  table.innerHTML = `<thead><tr>${cols.map((c) => `<th>${escapeHtml(c)}</th>`).join("")}</tr></thead>` +
    `<tbody>${(d.rows || []).map((r) => `<tr>${cols.map((c) => `<td>${escapeHtml(formatCell(r[c]))}</td>`).join("")}</tr>`).join("")}</tbody>`;
  document.getElementById("table-pager").textContent = `${name}: ${d.total} rows · ${offset + 1}–${Math.min(offset + PAGE, d.total)}`;
  document.getElementById("table-prev").disabled = offset <= 0;
  document.getElementById("table-next").disabled = offset + PAGE >= d.total;
}

document.getElementById("table-prev").onclick = () => {
  if (currentTable) showTable(currentTable, Math.max(0, tableOffset - PAGE));
};
document.getElementById("table-next").onclick = () => {
  if (currentTable) showTable(currentTable, tableOffset + PAGE);
};

document.getElementById("doc-form").onsubmit = async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const res = await fetch("/api/admin/documents/ingest", {
    method: "POST",
    credentials: "same-origin",
    headers: token() ? { "X-MedLock-Token": token() } : {},
    body: fd,
  });
  document.getElementById("doc-out").textContent = await res.text();
};
document.getElementById("ingest-dir").onclick = async () => {
  const data = await api("/api/admin/documents/ingest", { method: "POST" });
  document.getElementById("doc-out").textContent = JSON.stringify(data, null, 2);
};

async function loadStack() {
  const d = await api("/api/admin/nemoclaw");
  const rows = Object.entries(d || {});
  document.getElementById("stack-view").innerHTML = `
    <div class="kv">
      ${rows.map(([k, v]) => `<div class="stat-line"><span>${escapeHtml(k)}</span><span>${escapeHtml(typeof v === "object" ? JSON.stringify(v) : String(v))}</span></div>`).join("") || "<p class='muted'>No stack status.</p>"}
    </div>`;
}

async function loadLogs() {
  const name = document.getElementById("log-name").value;
  const d = await api(`/api/admin/logs?name=${encodeURIComponent(name)}`);
  document.getElementById("log-view").textContent = (d.lines || []).join("\n") || "(empty)";
}
document.getElementById("log-name").onchange = loadLogs;
document.getElementById("log-refresh").onclick = loadLogs;

loadOverview();
