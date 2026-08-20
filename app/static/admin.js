const pageTitle = document.getElementById("page-title");
const pageKicker = document.getElementById("page-kicker");
const livePill = document.getElementById("live-pill");

const TITLES = {
  overview: ["Workspace", "Overview"],
  models: ["Workspace", "Models"],
  endpoints: ["Workspace", "Endpoints & keys"],
  users: ["People", "Users"],
  stats: ["Data", "Audit"],
  tables: ["Data", "Tables"],
  docs: ["Data", "Documents"],
  stack: ["System", "OpenClaw stack"],
  logs: ["System", "Logs"],
};

const headers = (json = true) => ({
  ...(json ? { "Content-Type": "application/json" } : {}),
});

async function api(path, opts = {}) {
  const res = await fetch(path, { credentials: "same-origin", headers: headers(!(opts.body instanceof FormData)), ...opts });
  if (res.status === 401) {
    location.href = "/login?next=/admin";
    throw new Error("Login required");
  }
  if (res.status === 403) {
    location.href = "/";
    throw new Error("Admin access required");
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
    if (btn.dataset.panel === "users") loadUsers();
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
        ? `<div class="table-wrap"><table><thead><tr><th>Time</th><th>User</th><th>Event</th><th>Status</th><th>ms</th></tr></thead><tbody>${
            recent.map((r) => `<tr>
              <td>${escapeHtml((r.created_at || "").replace("T", " ").slice(0, 19))}</td>
              <td>${escapeHtml(r.username || "—")}</td>
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
  const inf = d.inference || {};
  const bin = (name) => {
    const row = d[name] || {};
    return row.installed ? `yes (${row.path || ""})` : "no";
  };
  document.getElementById("stack-view").innerHTML = `
    <div class="kv">
      <div class="stat-line"><span>OpenShell</span><span>${escapeHtml(bin("openshell"))}</span></div>
      <div class="stat-line"><span>NemoClaw</span><span>${escapeHtml(bin("nemoclaw"))}</span></div>
      <div class="stat-line"><span>OpenClaw</span><span>${escapeHtml(bin("openclaw"))}</span></div>
      <div class="stat-line"><span>Local copy</span><span>${d.vendor_ready ? "vendor/nemoclaw/bin" : "missing — run ./scripts/fetch_nemoclaw.sh"}</span></div>
      <div class="stat-line"><span>Onboarded</span><span>${d.onboarded ? "yes" : "no"}</span></div>
      <div class="stat-line"><span>Gateway</span><span>${d.gateway && d.gateway.running ? "yes · 127.0.0.1:" + escapeHtml(String(d.gateway.port || "")) : "stopped"}</span></div>
      <div class="stat-line"><span>Docker</span><span>${d.docker ? "yes" : "no"}</span></div>
      <div class="stat-line"><span>Driver</span><span>${escapeHtml((d.gateway && d.gateway.driver) || (d.docker ? "docker" : "vm"))}${d.docker ? "" : " (KVM, no GPU)"}</span></div>
      <div class="stat-line"><span>Sandbox</span><span>${escapeHtml(d.sandbox_name || "")} · ${escapeHtml(d.lifecycle || "unknown")}</span></div>
      <div class="stat-line"><span>Provider</span><span>${escapeHtml(d.provider || "llama-cpp")}</span></div>
      <div class="stat-line"><span>Inference</span><span>${escapeHtml(inf.host || "127.0.0.1")}:${escapeHtml(String(inf.port || 8081))} · ${escapeHtml(inf.served_model_name || "medlock-llm")}</span></div>
      <div class="stat-line"><span>Cloud LLM</span><span>blocked</span></div>
    </div>
    <p class="muted">${escapeHtml(d.note || "")}</p>`;
  try {
    const logs = await api("/api/admin/nemoclaw/logs");
    document.getElementById("stack-log").textContent = (logs.lines || []).join("\n") || "(empty)";
  } catch {
    document.getElementById("stack-log").textContent = "";
  }
}

document.getElementById("stack-refresh").onclick = loadStack;
document.getElementById("stack-onboard").onclick = async () => {
  const out = document.getElementById("stack-out");
  out.textContent = "Onboarding… this can take several minutes. Stay on this page.";
  try {
    const data = await api("/api/admin/nemoclaw/onboard", { method: "POST" });
    out.textContent = JSON.stringify(data, null, 2);
    loadStack();
  } catch (err) {
    out.textContent = err.message || "Onboard failed";
  }
};
document.getElementById("stack-start").onclick = async () => {
  document.getElementById("stack-out").textContent = JSON.stringify(await api("/api/admin/nemoclaw/start", { method: "POST" }), null, 2);
  loadStack();
};
document.getElementById("stack-stop").onclick = async () => {
  document.getElementById("stack-out").textContent = JSON.stringify(await api("/api/admin/nemoclaw/stop", { method: "POST" }), null, 2);
  loadStack();
};

document.getElementById("agent-form").onsubmit = async (e) => {
  e.preventDefault();
  const prompt = document.getElementById("agent-prompt").value.trim();
  const out = document.getElementById("agent-out");
  const btn = document.getElementById("agent-send");
  if (!prompt) return;
  btn.disabled = true;
  out.textContent = "Thinking… first reply can take a minute.";
  try {
    const data = await api("/api/admin/nemoclaw/prompt", {
      method: "POST",
      body: JSON.stringify({ prompt }),
    });
    const text = (data && data.text) || "";
    const via = data && data.via ? `via ${data.via}\n\n` : "";
    out.textContent = text ? via + text : JSON.stringify(data, null, 2);
  } catch (err) {
    out.textContent = err.message || "Prompt failed";
  } finally {
    btn.disabled = false;
  }
};

async function loadLogs() {
  const name = document.getElementById("log-name").value;
  const d = await api(`/api/admin/logs?name=${encodeURIComponent(name)}`);
  document.getElementById("log-view").textContent = (d.lines || []).join("\n") || "(empty)";
}
document.getElementById("log-name").onchange = loadLogs;
document.getElementById("log-refresh").onclick = loadLogs;

async function loadUsers() {
  const box = document.getElementById("user-list");
  if (!box) return;
  const data = await api("/api/admin/users");
  const rows = data.users || [];
  if (!rows.length) {
    box.innerHTML = "<p class='muted'>No accounts yet.</p>";
    return;
  }
  box.innerHTML = rows.map((u) => {
    const created = u.created_at ? new Date(u.created_at).toLocaleDateString() : "";
    const bits = [u.role, created, u.disabled ? "disabled" : ""].filter(Boolean);
    return `
    <div class="stat-line">
      <span>${escapeHtml(u.username)} <small class="muted">${escapeHtml(bits.join(" · "))}</small></span>
      <span>
        <button type="button" data-reset="${u.id}">Reset password</button>
        ${u.disabled
          ? `<button type="button" data-enable="${u.id}">Enable</button>`
          : `<button type="button" data-disable="${u.id}">Disable</button>`}
      </span>
    </div>`;
  }).join("");
  box.querySelectorAll("[data-disable]").forEach((btn) => {
    btn.onclick = async () => {
      await api(`/api/admin/users/${btn.dataset.disable}/disable`, { method: "POST" });
      loadUsers();
    };
  });
  box.querySelectorAll("[data-enable]").forEach((btn) => {
    btn.onclick = async () => {
      await api(`/api/admin/users/${btn.dataset.enable}/enable`, { method: "POST" });
      loadUsers();
    };
  });
  box.querySelectorAll("[data-reset]").forEach((btn) => {
    btn.onclick = async () => {
      const pw = window.prompt("New password (min 8 characters)");
      if (!pw) return;
      try {
        await api(`/api/admin/users/${btn.dataset.reset}/password`, {
          method: "POST",
          body: JSON.stringify({ password: pw }),
        });
        document.getElementById("user-out").textContent = "Password updated";
      } catch (err) {
        document.getElementById("user-out").textContent = err.message || "Reset failed";
      }
    };
  });
}

const userForm = document.getElementById("user-form");
if (userForm) {
  userForm.onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    try {
      const row = await api("/api/admin/users", {
        method: "POST",
        body: JSON.stringify({ username: fd.get("username"), password: fd.get("password") }),
      });
      document.getElementById("user-out").textContent = `Created ${row.username}`;
      e.target.reset();
      loadUsers();
    } catch (err) {
      document.getElementById("user-out").textContent = err.message || "Could not create user";
    }
  };
}

(async () => {
  try {
    const me = await api("/api/auth/me");
    const who = document.getElementById("whoami");
    if (who) who.textContent = me.username;
    if (me.role !== "owner") {
      location.href = "/";
      return;
    }
  } catch {
    return;
  }
  const logoutBtn = document.getElementById("logout-btn");
  if (logoutBtn) {
    logoutBtn.onclick = async () => {
      await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" });
      location.href = "/login";
    };
  }
  const panel = new URLSearchParams(location.search).get("panel");
  if (panel && TITLES[panel]) {
    setPanel(panel);
    if (panel === "stack") loadStack();
    else if (panel === "overview") loadOverview();
    else if (panel === "users") loadUsers();
    else if (panel === "stats") loadStats();
    else if (panel === "logs") loadLogs();
  } else {
    loadOverview();
  }
})();
