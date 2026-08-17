const threadsEl = document.getElementById("threads");
const messagesEl = document.getElementById("messages");
const emptyEl = document.getElementById("empty");
const form = document.getElementById("composer");
const promptEl = document.getElementById("prompt");
const ragEl = document.getElementById("use-rag");
const modelPill = document.getElementById("model-pill");
const sendBtn = document.getElementById("send");
const sidebar = document.getElementById("sidebar");
const scrim = document.getElementById("scrim");
const menuBtn = document.getElementById("menu-btn");

let conversationId = null;
let messages = [];
let busy = false;
let pending = [];

const fileInput = document.getElementById("file-input");
const attachRow = document.getElementById("attach-row");
const composer = document.getElementById("composer");

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(errorMessage(t, res.statusText));
  }
  return res.json();
}

function errorMessage(raw, fallback = "Request failed") {
  const text = (raw || "").trim();
  if (!text) return fallback;
  try {
    const obj = JSON.parse(text);
    const err = obj.error;
    if (typeof err === "string" && err.trim()) return err;
    if (err && typeof err === "object" && err.message) return String(err.message);
    if (obj.detail) return typeof obj.detail === "string" ? obj.detail : JSON.stringify(obj.detail);
  } catch {
    /* plain text */
  }
  return text;
}

function closeSidebar() {
  sidebar.classList.remove("open");
  scrim.hidden = true;
}

menuBtn.onclick = () => {
  const open = sidebar.classList.toggle("open");
  scrim.hidden = !open;
};
scrim.onclick = closeSidebar;

function resizePrompt() {
  promptEl.style.height = "auto";
  promptEl.style.height = `${Math.min(promptEl.scrollHeight, 180)}px`;
}
promptEl.addEventListener("input", resizePrompt);

function relativeTime(iso) {
  if (!iso) return "";
  const then = new Date(iso).getTime();
  const sec = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (sec < 60) return "now";
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatMessage(text) {
  let s = escapeHtml(text || "").replace(/\r\n/g, "\n").trim();
  if (!s) return "";
  s = s.replace(/```[\s\S]*?```/g, (block) => {
    const inner = block.replace(/^```[a-zA-Z0-9_-]*\n?/, "").replace(/```$/, "");
    return `<pre><code>${inner}</code></pre>`;
  });
  s = s.replace(/^######?\s+(.+)$/gm, "<h4>$1</h4>");
  s = s.replace(/^###\s+(.+)$/gm, "<h4>$1</h4>");
  s = s.replace(/^##\s+(.+)$/gm, "<h3>$1</h3>");
  s = s.replace(/^#\s+(.+)$/gm, "<h3>$1</h3>");
  s = s.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^\*])\*(?!\s)([^*]+?)\*(?!\*)/g, "$1<em>$2</em>");
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/^(?:[-•]\s+.+(?:\n|$))+/gm, (block) => {
    const items = block.trim().split("\n").map((line) => `<li>${line.replace(/^[-•]\s+/, "")}</li>`);
    return `<ul>${items.join("")}</ul>\n`;
  });
  s = s.replace(/^(?:\d+\.\s+.+(?:\n|$))+/gm, (block) => {
    const items = block.trim().split("\n").map((line) => `<li>${line.replace(/^\d+\.\s+/, "")}</li>`);
    return `<ol>${items.join("")}</ol>\n`;
  });
  return s
    .split(/\n{2,}/)
    .map((part) => {
      const trimmed = part.trim();
      if (!trimmed) return "";
      if (/^<(h3|h4|ul|ol|pre)\b/.test(trimmed)) return trimmed;
      return `<p>${trimmed}</p>`;
    })
    .join("");
}

function letterKind(userText, assistantText) {
  const q = (userText || "").toLowerCase();
  const a = (assistantText || "").toLowerCase();
  const blob = `${q}\n${a}`;
  const rules = [
    [/referral|\brefer (the )?patient|\brefer to\b/, "referral", "Referral letter"],
    [/discharge (letter|summary|note|report)|\bdischarged\b/, "discharge", "Discharge letter"],
    [/admission (letter|record|note|report)|admitting (letter|note)/, "admission", "Admission record"],
    [/clinic letter|outpatient letter|outcome letter/, "clinic", "Clinic letter"],
    [/admin(istrative)? (letter|note|work)|sick note|fit note|correspondence/, "admin", "Administrative letter"],
    [/\b(draft|write|compose)\b.{0,40}\bletter\b|\bletter to\b/, "letter", "Clinical letter"],
  ];
  for (const [re, kind, label] of rules) {
    if (re.test(q) || re.test(blob)) return { kind, label };
  }
  if (/\bdear\b/.test(a) && /yours (sincerely|faithfully)|kind regards|respectfully/.test(a)) {
    return { kind: "letter", label: "Clinical letter" };
  }
  return null;
}

function setFormatted(el, text) {
  el.classList.add("prose");
  el.innerHTML = formatMessage(text);
}

function attachLetterAction(bodyEl, userText, assistantText) {
  const found = letterKind(userText, assistantText);
  if (!found || !assistantText.trim()) return;
  const bubbleEl = bodyEl.closest(".bubble");
  if (!bubbleEl || bubbleEl.querySelector(".letter-actions")) return;
  bubbleEl.classList.add("letter");
  const bar = document.createElement("div");
  bar.className = "letter-actions";
  const kind = document.createElement("span");
  kind.className = "kind";
  kind.textContent = found.label;
  const btn = document.createElement("button");
  btn.type = "button";
  btn.textContent = "Download PDF";
  btn.onclick = async () => {
    btn.disabled = true;
    try {
      await downloadLetterPdf(found.kind, found.label, assistantText);
    } catch (err) {
      btn.textContent = err.message || "PDF failed";
      return;
    } finally {
      btn.disabled = false;
      btn.textContent = "Download PDF";
    }
  };
  bar.append(kind, btn);
  bubbleEl.appendChild(bar);
}

async function downloadLetterPdf(kind, title, content) {
  const res = await fetch("/api/letters/pdf", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ kind, title, content, conversation_id: conversationId }),
  });
  if (!res.ok) throw new Error(errorMessage(await res.text(), "Could not create PDF"));
  const blob = await res.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `${kind || "letter"}-${new Date().toISOString().slice(0, 10)}.pdf`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function bubble(role, text, extra = "", files = []) {
  const row = document.createElement("div");
  row.className = `row ${role}`;
  const div = document.createElement("div");
  div.className = `bubble ${role}${extra ? ` ${extra}` : ""}`;
  if (files.length) {
    const box = document.createElement("div");
    box.className = "files";
    for (const f of files) {
      if (f.preview_url) {
        const a = document.createElement("a");
        a.href = f.preview_url;
        a.target = "_blank";
        a.rel = "noopener";
        a.textContent = f.filename;
        box.appendChild(a);
      } else {
        const s = document.createElement("span");
        s.textContent = f.filename || f;
        box.appendChild(s);
      }
    }
    div.appendChild(box);
  }
  const body = document.createElement("div");
  if (role === "assistant" && extra !== "streaming" && extra !== "fail" && text) {
    setFormatted(body, text);
  } else {
    body.textContent = text;
  }
  div.appendChild(body);
  row.appendChild(div);
  emptyEl.style.display = "none";
  messagesEl.appendChild(row);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return body;
}

function renderPending() {
  attachRow.hidden = pending.length === 0;
  attachRow.innerHTML = "";
  for (const item of pending) {
    const chip = document.createElement("div");
    chip.className = "file-chip";
    if (item.preview_url) {
      const img = document.createElement("img");
      img.src = item.preview_url;
      img.alt = "";
      chip.appendChild(img);
    }
    const name = document.createElement("span");
    name.textContent = item.filename;
    chip.appendChild(name);
    const meta = document.createElement("span");
    meta.className = "meta";
    meta.textContent = item.has_text ? "text ready" : (item.kind === "image" ? "image" : "file");
    chip.appendChild(meta);
    const x = document.createElement("button");
    x.type = "button";
    x.textContent = "×";
    x.onclick = () => {
      pending = pending.filter((p) => p.id !== item.id);
      renderPending();
    };
    chip.appendChild(x);
    attachRow.appendChild(chip);
  }
}

async function uploadFiles(fileList) {
  const files = [...fileList];
  for (const file of files) {
    const fd = new FormData();
    fd.append("file", file);
    if (conversationId) fd.append("conversation_id", conversationId);
    const res = await fetch("/api/attachments", { method: "POST", body: fd });
    if (!res.ok) throw new Error(await res.text());
    const row = await res.json();
    conversationId = row.conversation_id;
    pending.push(row);
  }
  renderPending();
  loadThreads();
}

fileInput.onchange = async () => {
  try {
    await uploadFiles(fileInput.files);
  } catch (err) {
    bubble("assistant", err.message || "Upload failed", "fail");
  }
  fileInput.value = "";
};

["dragenter", "dragover"].forEach((ev) => {
  composer.addEventListener(ev, (e) => {
    e.preventDefault();
    composer.classList.add("drop");
  });
});
["dragleave", "drop"].forEach((ev) => {
  composer.addEventListener(ev, (e) => {
    e.preventDefault();
    composer.classList.remove("drop");
  });
});
composer.addEventListener("drop", async (e) => {
  const files = e.dataTransfer?.files;
  if (!files || !files.length) return;
  try {
    await uploadFiles(files);
  } catch (err) {
    bubble("assistant", err.message || "Upload failed", "fail");
  }
});

function showEmpty() {
  messagesEl.innerHTML = "";
  messagesEl.appendChild(emptyEl);
  emptyEl.style.display = "";
}

async function loadThreads() {
  let rows;
  try {
    rows = await api("/api/conversations");
  } catch (err) {
    threadsEl.innerHTML = "";
    const p = document.createElement("p");
    p.className = "muted";
    p.style.padding = "0.4rem 0.6rem";
    p.style.fontSize = "0.82rem";
    p.textContent = err.message || "Could not load conversations.";
    threadsEl.appendChild(p);
    return;
  }
  threadsEl.innerHTML = "";
  if (!rows.length) {
    const p = document.createElement("p");
    p.className = "muted";
    p.style.padding = "0.4rem 0.6rem";
    p.style.fontSize = "0.82rem";
    p.textContent = "No conversations yet.";
    threadsEl.appendChild(p);
    return;
  }
  for (const row of rows) {
    const wrap = document.createElement("div");
    wrap.className = "thread" + (row.id === conversationId ? " active" : "");
    const open = document.createElement("button");
    open.type = "button";
    open.className = "open";
    const title = document.createElement("span");
    title.className = "title";
    title.textContent = row.title || "Untitled";
    const when = document.createElement("span");
    when.className = "when";
    when.textContent = relativeTime(row.updated_at || row.created_at);
    open.append(title, when);
    open.onclick = () => {
      closeSidebar();
      openThread(row.id);
    };
    const del = document.createElement("button");
    del.type = "button";
    del.className = "del";
    del.setAttribute("aria-label", "Delete conversation");
    del.textContent = "×";
    del.onclick = async (ev) => {
      ev.stopPropagation();
      await api(`/api/conversations/${row.id}`, { method: "DELETE" });
      if (conversationId === row.id) {
        conversationId = null;
        messages = [];
        showEmpty();
      }
      loadThreads();
    };
    wrap.append(open, del);
    threadsEl.appendChild(wrap);
  }
}

async function openThread(id) {
  conversationId = id;
  pending = [];
  renderPending();
  const data = await api(`/api/conversations/${id}`);
  messages = data.messages.map((m) => ({ role: m.role, content: m.content }));
  showEmpty();
  if (messages.length) emptyEl.style.display = "none";
  let lastUser = "";
  for (const m of data.messages) {
    if (m.role === "system") continue;
    const body = bubble(m.role, m.content);
    if (m.role === "user") lastUser = m.content || "";
    if (m.role === "assistant") attachLetterAction(body, lastUser, m.content || "");
  }
  loadThreads();
}

document.getElementById("new-chat").onclick = async () => {
  try {
    const row = await api("/api/conversations", { method: "POST", body: JSON.stringify({ title: "New chat" }) });
    conversationId = row.id;
    messages = [];
    pending = [];
    renderPending();
    showEmpty();
    closeSidebar();
    promptEl.focus();
    loadThreads();
  } catch (err) {
    bubble("assistant", err.message || "Could not start a conversation.", "fail");
  }
};

document.getElementById("chips").onclick = (e) => {
  const btn = e.target.closest("button[data-prompt]");
  if (!btn) return;
  promptEl.value = btn.dataset.prompt;
  resizePrompt();
  form.requestSubmit();
};

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = promptEl.value.trim();
  if ((!text && !pending.length) || busy) return;
  busy = true;
  sendBtn.disabled = true;
  promptEl.value = "";
  resizePrompt();
  const attached = pending.slice();
  const display = text || (attached.length ? "Please review the attached file(s)." : "");
  bubble("user", display, "", attached);
  messages.push({ role: "user", content: display });
  const ids = attached.map((a) => a.id);
  pending = [];
  renderPending();
  const bot = bubble("assistant", "", "streaming");
  try {
    const res = await fetch("/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages,
        stream: true,
        rag: ragEl.checked,
        conversation_id: conversationId,
        attachment_ids: ids,
      }),
    });
    if (!res.ok) {
      bot.classList.remove("streaming");
      bot.classList.add("fail");
      bot.textContent = errorMessage(await res.text(), res.statusText);
      return;
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let acc = "";
    let buffer = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split("\n");
      buffer = parts.pop() || "";
      for (const line of parts) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const data = trimmed.slice(5).trim();
        if (data === "[DONE]") continue;
        try {
          const obj = JSON.parse(data);
          const delta = obj.choices?.[0]?.delta?.content || "";
          acc += delta;
          bot.textContent = acc;
          messagesEl.scrollTop = messagesEl.scrollHeight;
          if (obj.conversation_id) conversationId = obj.conversation_id;
        } catch (_) {
          /* ignore incomplete SSE */
        }
      }
    }
    bot.classList.remove("streaming");
    setFormatted(bot, acc);
    messages.push({ role: "assistant", content: acc });
    attachLetterAction(bot, display, acc);
    loadThreads();
  } catch (err) {
    bot.classList.remove("streaming");
    bot.classList.add("fail");
    bot.textContent = err.message || "Request failed";
  } finally {
    busy = false;
    sendBtn.disabled = false;
    promptEl.focus();
  }
});

promptEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    form.requestSubmit();
  }
});

(async () => {
  try {
    const h = await api("/health");
    const local = h.gpu?.is_gb10 ? "GB10" : h.gpu?.nvidia_gpu_present ? "GPU" : "CPU";
    modelPill.innerHTML = `<span class="dot"></span> ${local} local`;
    modelPill.classList.toggle("fail", h.status && h.status !== "ok");
    modelPill.classList.toggle("warn", h.status === "degraded");
  } catch {
    modelPill.innerHTML = `<span class="dot"></span> Offline`;
    modelPill.classList.add("fail");
  }
  await loadThreads();
})();
