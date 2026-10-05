// WreckBox account service (Cloudflare Worker + D1 + KV).
//
// Accounts: email + password. The app turns the password into a key on the device (PBKDF2-SHA256, 200k rounds,
// salted with the email) and sends only that key; the server stores SHA-256(server salt || key). Sessions are random
// tokens; only their SHA-256 is stored.
// Library sync: the app uploads library / state / analysis JSON (KV, one value per user + name).
// Computers: each desktop registers its current tunnel URL + phone-sync token; the account's phones read them to
// stream and download from that computer from anywhere.

const JSON_HEADERS = { "content-type": "application/json" };
const BLOBS = new Set(["library", "state", "analysis"]);
const MAX_BLOB = 20 * 1024 * 1024;
const LOGIN_LIMIT = 10; // failed attempts per email / IP per hour

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    try {
      if (route === "GET /") return json({ ok: true, service: "wreckbox-api" });
      if (route === "POST /v1/signup") return await signup(request, env);
      if (route === "POST /v1/login") return await login(request, env);

      const user = await authed(request, env);
      if (!user) return json({ error: "Please sign in again." }, 401);

      if (route === "GET /v1/me") return json({ user: publicUser(user) });
      if (route === "POST /v1/logout") {
        await env.DB.prepare("DELETE FROM sessions WHERE hash = ?").bind(await sha256(bearer(request))).run();
        return json({ ok: true });
      }
      if (route === "POST /v1/password") return await changePassword(request, env, user);
      if (route === "GET /v1/blobs") {
        const { results } = await env.DB.prepare("SELECT name, updated, size, device FROM blobs WHERE user = ?").bind(user.id).all();
        return json({ blobs: results });
      }
      const blob = url.pathname.match(/^\/v1\/blob\/([a-z]+)$/);
      if (blob && BLOBS.has(blob[1])) {
        const key = `u:${user.id}:${blob[1]}`;
        if (request.method === "GET") {
          const v = await env.LIBRARY.get(key);
          return v == null ? json({ error: "nothing saved yet" }, 404) : new Response(v, { headers: JSON_HEADERS });
        }
        if (request.method === "PUT") {
          const body = await request.text();
          if (body.length > MAX_BLOB) return json({ error: "too large" }, 413);
          JSON.parse(body); // must be JSON
          await env.LIBRARY.put(key, body);
          await env.DB.prepare(
            "INSERT INTO blobs (user, name, updated, size, device) VALUES (?, ?, ?, ?, ?) " +
              "ON CONFLICT (user, name) DO UPDATE SET updated = excluded.updated, size = excluded.size, device = excluded.device",
          ).bind(user.id, blob[1], Date.now(), body.length, request.headers.get("x-wreckbox-device") || "").run();
          return json({ ok: true, updated: Date.now() });
        }
      }
      if (route === "GET /v1/devices") {
        // Forget computers not seen for 30 days.
        await env.DB.prepare("DELETE FROM devices WHERE user = ? AND last_seen < ?").bind(user.id, Date.now() - 30 * 86400000).run();
        const { results } = await env.DB.prepare(
          "SELECT id, name, platform, url, sync_token AS syncToken, last_seen AS lastSeen FROM devices WHERE user = ? ORDER BY last_seen DESC",
        ).bind(user.id).all();
        return json({ devices: results, now: Date.now() });
      }
      if (route === "POST /v1/devices") {
        const d = await request.json();
        if (!d.id || !d.name) return json({ error: "id and name required" }, 400);
        await env.DB.prepare(
          "INSERT INTO devices (user, id, name, platform, url, sync_token, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT (user, id) DO UPDATE SET name = excluded.name, platform = excluded.platform, url = excluded.url, " +
            "sync_token = excluded.sync_token, last_seen = excluded.last_seen",
        ).bind(user.id, clip(d.id, 64), clip(d.name, 80), clip(d.platform || "", 20), d.url ? clip(d.url, 300) : null,
          d.syncToken ? clip(d.syncToken, 100) : null, Date.now()).run();
        return json({ ok: true });
      }
      const dev = url.pathname.match(/^\/v1\/devices\/([^/]+)$/);
      if (dev && request.method === "DELETE") {
        await env.DB.prepare("DELETE FROM devices WHERE user = ? AND id = ?").bind(user.id, decodeURIComponent(dev[1])).run();
        return json({ ok: true });
      }
      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: "server error: " + (e && e.message) }, 500);
    }
  },
};

// MARK: accounts

async function signup(request, env) {
  const { email, key, name } = await request.json();
  const e = normEmail(email);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) return json({ error: "Please enter a valid email address." }, 400);
  if (!/^[0-9a-f]{64}$/.test(key || "")) return json({ error: "bad request" }, 400);
  if (await env.DB.prepare("SELECT 1 FROM users WHERE email = ?").bind(e).first()) {
    return json({ error: "There's already an account with this email — sign in instead." }, 409);
  }
  const id = crypto.randomUUID();
  const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
  await env.DB.prepare("INSERT INTO users (id, email, name, salt, hash, created) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(id, e, clip(name || "", 80), salt, await sha256(salt + key), Date.now()).run();
  return json({ token: await newSession(env, id, request), user: { id, email: e, name: clip(name || "", 80) } });
}

async function login(request, env) {
  const { email, key } = await request.json();
  const e = normEmail(email);
  const ip = request.headers.get("CF-Connecting-IP") || "?";
  const hour = new Date().toISOString().slice(0, 13);
  const keys = [`e:${e}:${hour}`, `i:${ip}:${hour}`];
  for (const k of keys) {
    const row = await env.DB.prepare("SELECT n FROM login_attempts WHERE key = ?").bind(k).first();
    if (row && row.n >= LOGIN_LIMIT) return json({ error: "Too many attempts — try again in an hour." }, 429);
  }
  const user = await env.DB.prepare("SELECT * FROM users WHERE email = ?").bind(e).first();
  const ok = user && /^[0-9a-f]{64}$/.test(key || "") && timingSafeEqual(await sha256(user.salt + key), user.hash);
  if (!ok) {
    for (const k of keys) {
      await env.DB.prepare("INSERT INTO login_attempts (key, n) VALUES (?, 1) ON CONFLICT (key) DO UPDATE SET n = n + 1").bind(k).run();
    }
    return json({ error: "Wrong email or password." }, 401);
  }
  return json({ token: await newSession(env, user.id, request), user: publicUser(user) });
}

async function changePassword(request, env, user) {
  const { oldKey, newKey } = await request.json();
  if (!timingSafeEqual(await sha256(user.salt + oldKey), user.hash)) return json({ error: "Current password is wrong." }, 401);
  if (!/^[0-9a-f]{64}$/.test(newKey || "")) return json({ error: "bad request" }, 400);
  const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
  await env.DB.prepare("UPDATE users SET salt = ?, hash = ? WHERE id = ?").bind(salt, await sha256(salt + newKey), user.id).run();
  // Sign out every other device.
  await env.DB.prepare("DELETE FROM sessions WHERE user = ? AND hash != ?").bind(user.id, await sha256(bearer(request))).run();
  return json({ ok: true });
}

async function newSession(env, userId, request) {
  const token = hex(crypto.getRandomValues(new Uint8Array(32)));
  await env.DB.prepare("INSERT INTO sessions (hash, user, device, created) VALUES (?, ?, ?, ?)")
    .bind(await sha256(token), userId, clip(request.headers.get("x-wreckbox-device") || "", 64), Date.now()).run();
  return token;
}

async function authed(request, env) {
  const t = bearer(request);
  if (!t) return null;
  return env.DB.prepare("SELECT u.* FROM sessions s JOIN users u ON u.id = s.user WHERE s.hash = ?").bind(await sha256(t)).first();
}

// MARK: helpers

const bearer = (r) => (r.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
const normEmail = (e) => String(e || "").trim().toLowerCase();
const clip = (s, n) => String(s).slice(0, n);
const publicUser = (u) => ({ id: u.id, email: u.email, name: u.name });
const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

async function sha256(s) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: JSON_HEADERS });
}
