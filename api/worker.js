// WreckBox account service (Cloudflare Worker + D1 + KV).
//
// Accounts: email + password. The app turns the password into a key on the device (PBKDF2-SHA256, 200k rounds,
// salted with the email) and sends only that key; the server stores SHA-256(server salt || key). Sessions are random
// tokens; only their SHA-256 is stored.
// Library sync: the app uploads library / state / analysis JSON (KV, one value per user + name).
// Google sign-in: the server runs the OAuth flow (the client secret never ships in an app) and hands the app a
// one-time code bound to a PKCE challenge, which the app swaps for a session.
// Linking: a signed-in computer shows a QR code with a one-time link code (10 min); the phone that scans it is
// signed in to the same account — no password typed on the phone.
// Computers: each desktop registers its current tunnel URL + a private ticket secret. Phones never see that secret:
// they ask for a short-lived ticket (HMAC-signed with it) and present that to the computer.
// Requests: phones can queue "download this" for a computer that's offline; it collects them when it comes back.

const JSON_HEADERS = { "content-type": "application/json" };
const BLOBS = new Set(["library", "state", "analysis"]);
const MAX_BLOB = 20 * 1024 * 1024;
const LOGIN_LIMIT = 10; // failed attempts per email / IP per hour
const TICKET_HOURS = 12;
const APP_REDIRECTS = new Set(["wreckbox://auth"]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    try {
      if (route === "GET /") return json({ ok: true, service: "wreckbox-api" });
      if (route === "POST /v1/signup") return await signup(request, env);
      if (route === "POST /v1/login") return await login(request, env);
      if (route === "GET /v1/auth/google/start") return await googleStart(url, env);
      if (route === "GET /v1/auth/google/callback") return await googleCallback(url, env, request);
      if (route === "POST /v1/auth/exchange") return await exchange(request, env);
      if (route === "POST /v1/link/claim") return await claimLink(request, env);

      const user = await authed(request, env);
      if (!user) return json({ error: "Please sign in again." }, 401);

      if (route === "GET /v1/me") return json({ user: publicUser(user) });
      if (route === "POST /v1/logout") {
        await env.DB.prepare("DELETE FROM sessions WHERE hash = ?").bind(await sha256(bearer(request))).run();
        return json({ ok: true });
      }
      if (route === "POST /v1/password") return await changePassword(request, env, user);
      if (route === "POST /v1/link/start") {
        const code = b64url(crypto.getRandomValues(new Uint8Array(16)));
        await env.LIBRARY.put(`link:${code}`, JSON.stringify({ user: user.id }), { expirationTtl: 600 });
        return json({ code, expires: Date.now() + 600000 });
      }
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
          "SELECT id, name, platform, url, last_seen AS lastSeen FROM devices WHERE user = ? ORDER BY last_seen DESC",
        ).bind(user.id).all();
        return json({ devices: results, now: Date.now() });
      }
      if (route === "POST /v1/devices") {
        const d = await request.json();
        if (!d.id || !d.name) return json({ error: "id and name required" }, 400);
        await env.DB.prepare(
          "INSERT INTO devices (user, id, name, platform, url, sync_token, ticket_secret, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT (user, id) DO UPDATE SET name = excluded.name, platform = excluded.platform, url = excluded.url, " +
            "sync_token = excluded.sync_token, ticket_secret = COALESCE(excluded.ticket_secret, devices.ticket_secret), last_seen = excluded.last_seen",
        ).bind(user.id, clip(d.id, 64), clip(d.name, 80), clip(d.platform || "", 20), d.url ? clip(d.url, 300) : null,
          // Older desktop apps (Windows ≤ 0.2) still share a fixed token; kept only for them.
          !d.ticketSecret && d.syncToken ? clip(d.syncToken, 100) : null,
          /^[0-9a-f]{64}$/.test(d.ticketSecret || "") ? d.ticketSecret : null, Date.now()).run();
        return json({ ok: true });
      }
      const tick = url.pathname.match(/^\/v1\/devices\/([^/]+)\/ticket$/);
      if (tick && request.method === "POST") return await ticket(env, user, decodeURIComponent(tick[1]));
      if (route === "POST /v1/requests") return await addRequest(request, env, user);
      if (route === "GET /v1/requests") return await takeRequests(url, env, user);
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

// MARK: Google sign-in

async function googleStart(url, env) {
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) return page("Google sign-in isn't set up yet. Use email and password for now.", 503);
  const redirect = url.searchParams.get("redirect") || "";
  const challenge = url.searchParams.get("challenge") || "";
  if (!APP_REDIRECTS.has(redirect) || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) return page("Bad sign-in request.", 400);
  const state = b64url(crypto.getRandomValues(new Uint8Array(24)));
  await env.LIBRARY.put(`oauth:${state}`, JSON.stringify({ redirect, challenge }), { expirationTtl: 600 });
  const g = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  g.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID, redirect_uri: callbackUrl(url), response_type: "code",
    scope: "openid email profile", state, prompt: "select_account",
  });
  return Response.redirect(g.toString(), 302);
}

async function googleCallback(url, env, request) {
  const state = url.searchParams.get("state") || "";
  const saved = state && (await env.LIBRARY.get(`oauth:${state}`, "json"));
  if (!saved) return page("This sign-in link expired. Go back to WreckBox and try again.", 400);
  await env.LIBRARY.delete(`oauth:${state}`);
  const back = (params) => Response.redirect(`${saved.redirect}?${new URLSearchParams(params)}`, 302);
  const code = url.searchParams.get("code");
  if (!code) return back({ error: url.searchParams.get("error") || "cancelled" });
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code, client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: callbackUrl(url), grant_type: "authorization_code",
    }),
  });
  const tok = await r.json().catch(() => ({}));
  if (!r.ok || !tok.id_token) return back({ error: "google_failed" });
  // The ID token came straight from Google over TLS, so its claims can be read without re-checking the signature
  // (Google's guidance); still check who it's for, who issued it, and that it's current.
  const claims = JSON.parse(new TextDecoder().decode(unb64url(tok.id_token.split(".")[1])));
  const okIss = claims.iss === "https://accounts.google.com" || claims.iss === "accounts.google.com";
  if (claims.aud !== env.GOOGLE_CLIENT_ID || !okIss || claims.exp * 1000 < Date.now() || !claims.sub) return back({ error: "google_failed" });
  if (!claims.email || claims.email_verified !== true) return back({ error: "email_not_verified" });
  const email = normEmail(claims.email);
  let user = await env.DB.prepare("SELECT * FROM users WHERE google_sub = ?").bind(claims.sub).first();
  if (!user) {
    user = await env.DB.prepare("SELECT * FROM users WHERE email = ?").bind(email).first();
    if (user) {
      // Same verified email as an existing password account: link it.
      await env.DB.prepare("UPDATE users SET google_sub = ? WHERE id = ?").bind(claims.sub, user.id).run();
    } else {
      const id = crypto.randomUUID();
      // No password: a random salt and an empty hash can never match a login attempt.
      await env.DB.prepare("INSERT INTO users (id, email, name, salt, hash, created, google_sub) VALUES (?, ?, ?, ?, '', ?, ?)")
        .bind(id, email, clip(claims.name || "", 80), hex(crypto.getRandomValues(new Uint8Array(16))), Date.now(), claims.sub).run();
      user = { id };
    }
  }
  const once = b64url(crypto.getRandomValues(new Uint8Array(24)));
  await env.LIBRARY.put(`authcode:${once}`, JSON.stringify({ user: user.id, challenge: saved.challenge }), { expirationTtl: 300 });
  return back({ code: once });
}

async function exchange(request, env) {
  const { code, verifier } = await request.json();
  const saved = code && (await env.LIBRARY.get(`authcode:${code}`, "json"));
  if (!saved) return json({ error: "This sign-in expired — try again." }, 400);
  await env.LIBRARY.delete(`authcode:${code}`);
  const digest = b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(verifier || "")))));
  if (!timingSafeEqual(digest, saved.challenge)) return json({ error: "Sign-in check failed — try again." }, 400);
  const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(saved.user).first();
  if (!user) return json({ error: "Account not found." }, 404);
  return json({ token: await newSession(env, user.id, request), user: publicUser(user) });
}

// A phone scanned the computer's QR code: one use, then it's gone.
async function claimLink(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "?";
  const k = `l:${ip}:${new Date().toISOString().slice(0, 13)}`;
  const row = await env.DB.prepare("SELECT n FROM login_attempts WHERE key = ?").bind(k).first();
  if (row && row.n >= LOGIN_LIMIT) return json({ error: "Too many attempts — try again in an hour." }, 429);
  const { code } = await request.json();
  const saved = /^[A-Za-z0-9_-]{22}$/.test(code || "") && (await env.LIBRARY.get(`link:${code}`, "json"));
  if (!saved) {
    await env.DB.prepare("INSERT INTO login_attempts (key, n) VALUES (?, 1) ON CONFLICT (key) DO UPDATE SET n = n + 1").bind(k).run();
    return json({ error: "This code has expired — show a fresh one on your computer (Sync to phone)." }, 400);
  }
  await env.LIBRARY.delete(`link:${code}`);
  const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(saved.user).first();
  if (!user) return json({ error: "Account not found." }, 404);
  return json({ token: await newSession(env, user.id, request), user: publicUser(user) });
}

const callbackUrl = (url) => `${url.origin}/v1/auth/google/callback`;

// MARK: tickets + requests

async function ticket(env, user, deviceId) {
  const d = await env.DB.prepare("SELECT url, ticket_secret, sync_token FROM devices WHERE user = ? AND id = ?").bind(user.id, deviceId).first();
  if (!d) return json({ error: "No such computer." }, 404);
  if (!d.ticket_secret) {
    // A computer on an older WreckBox (Windows ≤ 0.2) only knows its fixed token: hand that over instead.
    if (d.sync_token) return json({ url: d.url, ticket: d.sync_token, expires: Date.now() + TICKET_HOURS * 3600000, legacy: true });
    return json({ error: "Update WreckBox on that computer first." }, 409);
  }
  const exp = Math.floor(Date.now() / 1000) + TICKET_HOURS * 3600;
  const payload = `${user.id}.${deviceId}.${exp}`;
  const sig = await hmacHex(d.ticket_secret, payload);
  return json({ url: d.url, ticket: `wbt1.${b64url(new TextEncoder().encode(payload))}.${sig}`, expires: exp * 1000 });
}

async function addRequest(request, env, user) {
  const r = await request.json();
  if (!r.device || !(r.id || (r.artist && r.title))) return json({ error: "device and a track are required" }, 400);
  const key = `req:${user.id}:${clip(r.device, 64)}`;
  const list = (await env.LIBRARY.get(key, "json")) || [];
  list.push({
    id: r.id ? clip(r.id, 100) : null, artist: r.artist ? clip(r.artist, 200) : null, title: r.title ? clip(r.title, 200) : null,
    query: r.query ? clip(r.query, 200) : null, at: Date.now(),
  });
  await env.LIBRARY.put(key, JSON.stringify(list.slice(-200)));
  return json({ ok: true, queued: list.length });
}

async function takeRequests(url, env, user) {
  const key = `req:${user.id}:${clip(url.searchParams.get("device") || "", 64)}`;
  const list = (await env.LIBRARY.get(key, "json")) || [];
  if (list.length) await env.LIBRARY.delete(key);
  return json({ requests: list });
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

async function hmacHex(secretHex, msg) {
  const raw = new Uint8Array(secretHex.match(/../g).map((h) => parseInt(h, 16)));
  const key = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg))));
}

const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64url = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));

function page(message, status = 200) {
  const esc = message.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
  return new Response(`<!doctype html><meta name=viewport content="width=device-width"><title>WreckBox</title>` +
    `<body style="font:16px system-ui;background:#111;color:#eee;padding:32px">${esc}</body>`, { status, headers: { "content-type": "text/html" } });
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: JSON_HEADERS });
}
