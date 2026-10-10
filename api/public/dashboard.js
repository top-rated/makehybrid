import { auth, api, requireAuth, ApiError } from "/client.js";

const $ = (id) => document.getElementById(id);

function statusLabel(s) {
  return {
    healthy: "Healthy", needs_reconnect: "Needs reconnect", checkpoint: "Checkpoint required",
    paused: "Paused", halted: "Halted", banned: "Banned",
  }[s] ?? s;
}

async function loadAccounts() {
  const box = $("accounts");
  try {
    const { data } = await api.accounts();
    if (!data.length) {
      box.innerHTML = `<span class="muted">No accounts connected yet — install the extension above to connect one.</span>`;
      return;
    }
    // `label` is free-form text an org can set via the API-key-authed
    // PATCH/connect routes, not just this page's own session -- it must be
    // escaped exactly like key names below. A security audit confirmed the
    // unescaped version let a write-scoped key XSS anyone viewing this same
    // org's dashboard (e.g. to mint a fresh unrestricted key under their
    // session and exfiltrate it).
    box.innerHTML = data.map((a) => `
      <div class="row">
        <div>
          <span class="dot ${a.status}"></span>${escapeHtml(a.label ?? a.linkedin_urn ?? a.id)}
          <div class="muted">${statusLabel(a.status)}</div>
        </div>
        <button class="danger small" data-remove="${a.id}">Remove</button>
      </div>
    `).join("");

    box.querySelectorAll("[data-remove]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        await api.removeAccount(btn.dataset.remove).catch(() => {});
        await loadAccounts();
      });
    });
  } catch (e) {
    box.innerHTML = `<span class="muted">${e instanceof ApiError ? e.message : "Could not load accounts."}</span>`;
  }
}

function fmtDate(iso) {
  if (!iso) return "never";
  return new Date(iso).toLocaleString();
}

async function loadKeys() {
  const box = $("keysList");
  try {
    const { data } = await api.keys.list();
    if (!data.length) {
      box.innerHTML = `<span class="muted">No API keys yet.</span>`;
      return;
    }
    box.innerHTML = `
      <table>
        <thead><tr><th>Name</th><th>Key</th><th>Last used</th><th></th></tr></thead>
        <tbody>
          ${data.map((k) => `
            <tr>
              <td>${escapeHtml(k.name ?? "(unnamed)")}</td>
              <td class="mono">${k.start ?? k.prefix ?? ""}…</td>
              <td class="muted">${fmtDate(k.last_request)}</td>
              <td><button class="danger small" data-revoke="${k.id}">Revoke</button></td>
            </tr>
          `).join("")}
        </tbody>
      </table>
    `;
    box.querySelectorAll("[data-revoke]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        if (!confirm("Revoke this API key? Anything using it will stop working immediately.")) return;
        btn.disabled = true;
        await api.keys.revoke(btn.dataset.revoke).catch(() => {});
        await loadKeys();
      });
    });
  } catch (e) {
    box.innerHTML = `<span class="muted">${e instanceof ApiError ? e.message : "Could not load API keys."}</span>`;
  }
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

$("createKeyForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $("keyName").value.trim();
  if (!name) return;

  const submitBtn = e.target.querySelector("button");
  submitBtn.disabled = true;
  try {
    const { data } = await api.keys.create(name);
    $("newKeyValue").textContent = data.key;
    $("newKeyBox").classList.remove("hidden");
    $("keyName").value = "";
    await loadKeys();
  } catch (err) {
    alert(err instanceof ApiError ? err.message : "Could not create key.");
  } finally {
    submitBtn.disabled = false;
  }
});

$("copyKeyBtn").addEventListener("click", async () => {
  await navigator.clipboard.writeText($("newKeyValue").textContent);
  $("copyKeyBtn").textContent = "Copied";
  setTimeout(() => ($("copyKeyBtn").textContent = "Copy"), 1500);
});

$("signout").addEventListener("click", async (e) => {
  e.preventDefault();
  await auth.signOut().catch(() => {});
  window.location.href = "/login.html";
});

(async function init() {
  const me = await requireAuth();
  if (!me) return; // requireAuth already redirected to /login.html
  $("whoami").textContent = me.data.user.email;
  await Promise.all([loadAccounts(), loadKeys()]);
})();
