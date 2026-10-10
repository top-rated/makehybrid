// Shared fetch helper for the dashboard pages.
//
// Unlike the extension (extension/api.js), these pages are served from the
// SAME origin as the API, so the browser attaches the BetterAuth session
// cookie automatically -- no bearer token dance needed. `credentials:
// "include"` is set explicitly anyway, since same-origin default behavior is
// easy to get wrong if this ever moves behind a different host/port.

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

async function call(path, { method = "GET", body } = {}) {
  const hasBody = method !== "GET" && method !== "HEAD";
  const res = await fetch(path, {
    method,
    credentials: "include",
    headers: { "content-type": "application/json" },
    // BetterAuth rejects a body-less POST as invalid JSON even when it
    // ignores the content (verified against the running server) -- always
    // send at least "{}".
    body: hasBody ? JSON.stringify(body ?? {}) : undefined,
  });

  let payload = null;
  try {
    payload = await res.json();
  } catch {
    /* empty body, e.g. some 204s */
  }

  if (!res.ok) {
    const message = payload?.message || payload?.error || `Request failed (${res.status})`;
    throw new ApiError(res.status, payload?.error ?? payload?.code ?? "error", message);
  }
  return payload;
}

export const auth = {
  signUp: (email, password, name) =>
    call("/api/auth/sign-up/email", { method: "POST", body: { email, password, name } }),
  signIn: (email, password) =>
    call("/api/auth/sign-in/email", { method: "POST", body: { email, password } }),
  signOut: () => call("/api/auth/sign-out", { method: "POST" }),
};

export const api = {
  me: () => call("/v1/me"),
  accounts: () => call("/v1/me/accounts"),
  removeAccount: (id) => call(`/v1/me/accounts/${id}`, { method: "DELETE" }),
  keys: {
    list: () => call("/v1/me/keys"),
    create: (name, permissions) => call("/v1/me/keys", { method: "POST", body: { name, permissions } }),
    revoke: (id) => call(`/v1/me/keys/${id}`, { method: "DELETE" }),
  },
};

/** Redirects to sign-in if there is no active session. Call at the top of any
 * page that requires auth. Returns the resolved `me` payload on success. */
export async function requireAuth() {
  try {
    return await api.me();
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) {
      window.location.href = "/login.html";
      return null;
    }
    throw e;
  }
}
