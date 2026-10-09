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
// WreckBox Player: the Android player links to an account with a code it shows (entered in WreckBox, signed in). It
// then gets a token that can ONLY read and write its own playlists (u:<user>:player) — never the account itself.

const JSON_HEADERS = { "content-type": "application/json" };
const BLOBS = new Set(["library", "state", "analysis"]);
const MAX_BLOB = 20 * 1024 * 1024;
const LOGIN_LIMIT = 10; // failed attempts per email / IP per hour
const TICKET_HOURS = 12;
const APP_REDIRECTS = new Set(["wreckbox://auth"]);

export default {
  async fetch(request, env, ctx) {
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
      // Sharing: opened by friends (no account needed); the landing page for share links
      if (route === "POST /v1/shares/open") return await openShare(request, env);
      // The one link for friends: the newest Mac and Android downloads, whichever was released last.
      if (route === "GET /download") return await downloadPage(env, ctx);
      // WreckBox Player: the page friends get, and its linking (the Player has no account of its own)
      if (route === "GET /player") return await playerPage(env, ctx);
      if (route === "POST /v1/player/pair") return await playerPair(request, env);
      if (route === "POST /v1/player/claim") return await playerClaim(request, env);
      if (url.pathname === "/v1/player/playlists" && request.headers.get("x-wreckbox-player")) {
        const p = await playerAuthed(request, env);
        if (!p) return json({ error: "This player isn't linked any more — link it again." }, 401);
        if (request.method === "PUT") {
          const body = await request.text();
          if (body.length > 2 * 1024 * 1024) return json({ error: "too large" }, 413);
          const d = JSON.parse(body);
          if (!Array.isArray(d.playlists)) return json({ error: "playlists required" }, 400);
          const saved = { updated: Date.now(), player: p.name, playlists: d.playlists.slice(0, 500), likes: Array.isArray(d.likes) ? d.likes.slice(0, 5000) : [] };
          await env.LIBRARY.put(`u:${p.user}:player`, JSON.stringify(saved));
          return json({ ok: true, updated: saved.updated });
        }
        if (request.method === "GET") return new Response((await env.LIBRARY.get(`u:${p.user}:player`)) || "{}", { headers: JSON_HEADERS });
        if (request.method === "DELETE") {
          await env.LIBRARY.delete(`ptok:${await sha256(bearer(request))}`);
          return json({ ok: true });
        }
      }
      const landing = url.pathname.match(/^\/s\/([A-Za-z0-9-]{10,40})$/);
      if (landing && request.method === "GET") return sharePage(landing[1]);

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
      if (route === "POST /v1/shares") return await createShare(request, env, user, url);
      if (route === "GET /v1/shares") {
        const { results } = await env.DB.prepare(
          "SELECT id, computer, kind, playlist, label, created, expires, revoked, last_used AS lastUsed FROM shares WHERE owner = ? ORDER BY created DESC",
        ).bind(user.id).all();
        return json({ shares: results });
      }
      const share = url.pathname.match(/^\/v1\/shares\/([A-Za-z0-9_-]+)$/);
      if (share && request.method === "DELETE") {
        await env.DB.prepare("UPDATE shares SET revoked = 1 WHERE id = ? AND owner = ?").bind(share[1], user.id).run();
        return json({ ok: true });
      }
      // WreckBox (signed in) approves a Player's code, and reads what the Player saved.
      if (route === "POST /v1/player/approve") return await playerApprove(request, env, user);
      if (route === "GET /v1/player/playlists") return new Response((await env.LIBRARY.get(`u:${user.id}:player`)) || "{}", { headers: JSON_HEADERS });
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

// MARK: WreckBox Player linking

const PAIR_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I: easy to read and type

/// The Player asks for a code to show: 8 characters for a person to type, plus a long secret only the Player keeps
/// (the code alone can't claim the link). Valid 15 minutes.
async function playerPair(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "?";
  const k = `pp:${ip}:${new Date().toISOString().slice(0, 13)}`;
  const row = await env.DB.prepare("SELECT n FROM login_attempts WHERE key = ?").bind(k).first();
  if (row && row.n >= 30) return json({ error: "Too many codes — try again in an hour." }, 429);
  await env.DB.prepare("INSERT INTO login_attempts (key, n) VALUES (?, 1) ON CONFLICT (key) DO UPDATE SET n = n + 1").bind(k).run();
  const { name } = await request.json().catch(() => ({}));
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const code = [...bytes].map((b) => PAIR_ALPHABET[b % PAIR_ALPHABET.length]).join("");
  const secret = hex(crypto.getRandomValues(new Uint8Array(32)));
  await env.LIBRARY.put(`pair:${code}`, JSON.stringify({ secret: await sha256(secret), name: clip(name || "WreckBox Player", 60), user: null }), { expirationTtl: 900 });
  return json({ code: `${code.slice(0, 4)}-${code.slice(4)}`, secret, expires: Date.now() + 900000 });
}

const normPair = (c) => String(c || "").toUpperCase().replace(/[^A-Z0-9]/g, "");

/// Signed-in WreckBox enters the code the Player shows.
async function playerApprove(request, env, user) {
  const code = normPair((await request.json()).code);
  const key = `pair:${code}`;
  const saved = code.length === 8 && (await env.LIBRARY.get(key, "json"));
  if (!saved) return json({ error: "That code isn't valid any more — get a new one in WreckBox Player (Settings → Link to WreckBox)." }, 400);
  if (saved.user && saved.user !== user.id) return json({ error: "That code was already used." }, 409);
  saved.user = user.id;
  await env.LIBRARY.put(key, JSON.stringify(saved), { expirationTtl: 900 });
  return json({ ok: true, name: saved.name });
}

/// The Player checks back with its code + secret: once approved, it gets its playlists-only token (one use).
async function playerClaim(request, env) {
  const { code, secret } = await request.json();
  const key = `pair:${normPair(code)}`;
  const saved = await env.LIBRARY.get(key, "json");
  if (!saved || !timingSafeEqual(await sha256(String(secret || "")), saved.secret)) return json({ error: "That code expired — get a new one." }, 400);
  if (!saved.user) return json({ pending: true });
  await env.LIBRARY.delete(key);
  const token = hex(crypto.getRandomValues(new Uint8Array(32)));
  await env.LIBRARY.put(`ptok:${await sha256(token)}`, JSON.stringify({ user: saved.user, name: saved.name, created: Date.now() }));
  const u = await env.DB.prepare("SELECT email FROM users WHERE id = ?").bind(saved.user).first();
  return json({ token, email: u ? u.email : "" });
}

async function playerAuthed(request, env) {
  const t = bearer(request);
  return t ? env.LIBRARY.get(`ptok:${await sha256(t)}`, "json") : null;
}

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

// MARK: sharing

const SHARE_TICKET_HOURS = 6;
const SHARE_OPENS_PER_IP_PER_HOUR = 60;
// Crockford base32 without look-alikes, grouped: WBX-7K2QD-M9F4H-XR3TC
const KEY_CHARS = "23456789ABCDEFGHJKMNPQRSTVWXYZ";

function newShareKey() {
  const r = crypto.getRandomValues(new Uint8Array(15));
  const c = [...r].map((b) => KEY_CHARS[b % KEY_CHARS.length]).join("");
  return `WBX-${c.slice(0, 5)}-${c.slice(5, 10)}-${c.slice(10, 15)}`;
}
const normKey = (k) => String(k || "").trim().toUpperCase().replace(/^.*\/S\//, "").replace(/[^A-Z0-9-]/g, "");

async function createShare(request, env, user, url) {
  const b = await request.json();
  const kind = b.kind === "playlist" ? "playlist" : "library";
  if (!b.computer) return json({ error: "Which computer shares it?" }, 400);
  if (kind === "playlist" && !b.playlist) return json({ error: "Which playlist?" }, 400);
  const dev = await env.DB.prepare("SELECT id FROM devices WHERE user = ? AND id = ?").bind(user.id, clip(b.computer, 64)).first();
  if (!dev) return json({ error: "That computer isn't in your account." }, 404);
  const key = newShareKey();
  const id = b64url(crypto.getRandomValues(new Uint8Array(9)));
  const days = Math.max(0, Math.min(365, Number(b.days) || 0));
  await env.DB.prepare(
    "INSERT INTO shares (id, key_hash, owner, computer, kind, playlist, label, created, expires) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).bind(id, await sha256(key), user.id, dev.id, kind, kind === "playlist" ? clip(b.playlist, 200) : null, clip(b.label || "", 80),
    Date.now(), days ? Date.now() + days * 86400000 : 0).run();
  return json({ id, key, link: `${url.origin}/s/${key}` });
}

/// A friend opens a key / link: what it is, the computer's address, and a short-lived ticket for that computer.
async function openShare(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const rk = `shareopen:${ip}:${new Date().toISOString().slice(0, 13)}`;
  const n = parseInt((await env.LIBRARY.get(rk)) || "0", 10);
  if (n >= SHARE_OPENS_PER_IP_PER_HOUR) return json({ error: "Too many tries — wait a bit." }, 429);
  await env.LIBRARY.put(rk, String(n + 1), { expirationTtl: 3600 });
  const key = normKey((await request.json()).key);
  const s = await env.DB.prepare("SELECT * FROM shares WHERE key_hash = ?").bind(await sha256(key)).first();
  if (!s || s.revoked) return json({ error: "That key isn't valid (it may have been revoked)." }, 404);
  if (s.expires && s.expires < Date.now()) return json({ error: "That key has expired." }, 410);
  const d = await env.DB.prepare("SELECT name, url, ticket_secret, last_seen FROM devices WHERE user = ? AND id = ?").bind(s.owner, s.computer).first();
  const owner = await env.DB.prepare("SELECT name, email FROM users WHERE id = ?").bind(s.owner).first();
  if (!d || !d.ticket_secret) return json({ error: "The computer sharing this isn't set up for sharing yet." }, 409);
  await env.DB.prepare("UPDATE shares SET last_used = ? WHERE id = ?").bind(Date.now(), s.id).run();
  const exp = Math.floor(Date.now() / 1000) + SHARE_TICKET_HOURS * 3600;
  // The computer checks this itself (its own secret) and allows only what the share covers.
  const payload = `${s.id}|${s.computer}|${exp}|${s.kind}|${s.playlist || ""}`;
  const sig = await hmacHex(d.ticket_secret, payload);
  return json({
    id: s.id, kind: s.kind, playlist: s.playlist, label: s.label,
    owner: (owner && (owner.name || owner.email.split("@")[0])) || "a friend",
    computer: d.name, online: Date.now() - d.last_seen < 5 * 60000, url: d.url,
    ticket: `wbs1.${b64url(new TextEncoder().encode(payload))}.${sig}`, expires: exp * 1000,
  });
}

// MARK: downloads

const RELEASES_REPO = "moloyb301-eng/wreckbox-releases";
const MAC_ASSET = "WreckBox-mac-arm64.zip";
const PLAYER_ASSET_PREFIX = "WreckBox-Player"; // released as player-v…, never the "latest" release

/// Mac and Android ship separately (Mac releases are tagged mac-v…, phone releases v…), so the newest of each can
/// be in different releases: this page finds both. GitHub's answer is cached for 5 minutes.
async function downloadPage(env, ctx) {
  const cacheKey = new Request("https://wreckbox-cache/download-page");
  const cached = await caches.default.match(cacheKey);
  if (cached) return cached;
  const res = await fetch(`https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=40`, {
    headers: { accept: "application/vnd.github+json", "user-agent": "wreckbox-api" },
  });
  const releases = res.ok ? await res.json() : [];
  const ver = (r) => (r.tag_name || "").replace(/^mac-/, "").replace(/^v/, "");
  const newer = (a, b) => {
    const x = a.split(".").map(Number), y = b.split(".").map(Number);
    for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
    return false;
  };
  const pick = (test) => {
    let best = null;
    for (const r of releases) {
      if (r.draft || r.prerelease) continue;
      const a = (r.assets || []).find((x) => test(x.name));
      if (a && (!best || newer(ver(r), best.version))) best = { version: ver(r), url: a.browser_download_url, size: a.size, date: r.published_at };
    }
    return best;
  };
  const mac = pick((n) => n === MAC_ASSET);
  const android = pick((n) => n.endsWith(".apk") && !n.startsWith(PLAYER_ASSET_PREFIX));
  const mb = (n) => `${Math.round(n / 1048576)} MB`;
  const card = (title, sub, d, steps) => d ? `<div class="card"><h2>${title}</h2><p class="sub">${sub}</p>
<a class="b" href="${d.url}">Download ${title} · ${d.version}</a><p class="meta">${mb(d.size)} · ${new Date(d.date).toDateString().slice(4)}</p>
<ol>${steps.map((s) => `<li>${s}</li>`).join("")}</ol></div>` : `<div class="card"><h2>${title}</h2><p class="sub">Not available right now — try again soon.</p></div>`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Get WreckBox</title><link href="https://fonts.googleapis.com/css2?family=Doto:wght@700&family=Urbanist:wght@400;600;700&display=swap" rel="stylesheet">
<style>:root{color-scheme:dark}body{margin:0;background:#08080A;color:#f0f0f0;font:16px Urbanist,-apple-system,system-ui,sans-serif}
.w{max-width:880px;margin:0 auto;padding:48px 16px}h1{font:700 34px Doto,monospace;letter-spacing:3px;margin:0 0 6px}
.lead{color:#9a9a9a;margin:0 0 28px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px}
.card{background:rgba(255,255,255,.045);border:1px solid rgba(255,255,255,.08);border-radius:24px;padding:24px}
h2{margin:0;font-size:22px}.sub{color:#9a9a9a;margin:4px 0 18px}.meta{color:#666;font-size:13px;margin:8px 0 0}
a.b{display:inline-block;padding:12px 20px;border-radius:999px;background:#fff;color:#000;text-decoration:none;font-weight:700}
ol{color:#bbb;padding-left:20px;line-height:1.55;margin:18px 0 0}a{color:#BB96DA}.foot{color:#666;font-size:13px;margin-top:28px}</style></head>
<body><div class="w"><h1>WRECKBOX</h1><p class="lead">Your DJ library: every track in the best quality, sorted and tagged, on your Mac and your phone.</p>
<div class="grid">
${card("Mac", "Apple Silicon (M1 or newer), macOS 13+", mac, [
  "Unzip and drag WreckBox into Applications, then open it.",
  "macOS blocks it the first time: click <b>Done</b>, then <b>System Settings → Privacy &amp; Security → Open Anyway</b>.",
  "Setup walks you through Soulseek, YouTube and your own Spotify. Turn your VPN on before downloading.",
  `Full guide: <a href="https://github.com/moloyb301-eng/wreckbox-mac/blob/main/INSTALL.md">INSTALL.md</a>`])}
${card("Android", "Android 7+", android, [
  "Open the .apk. Allow installs from your browser or Files when asked.",
  "If Play Protect warns: <b>More details → Install anyway</b>.",
  "In the app, tap <b>Allow</b> for file access."])}
</div><p class="foot">Just want a light music player for your phone? <a href="/player">WreckBox Player</a> — your phone's songs, YouTube Music and Spotify in one queue.</p>
<p class="foot">Updates show up inside the apps. Free and open source — <a href="https://github.com/moloyb301-eng/wreckbox-mac">Mac</a> · <a href="https://github.com/moloyb301-eng/wreckbox">Android</a>.</p></div></body></html>`;
  const out = new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" } });
  if (res.ok) ctx.waitUntil(caches.default.put(cacheKey, out.clone()));
  return out;
}

/// The page to share WreckBox Player: what it is, the newest APK (releases tagged player-v…), how to install.
async function playerPage(env, ctx) {
  const cacheKey = new Request("https://wreckbox-cache/player-page");
  const cached = await caches.default.match(cacheKey);
  if (cached) return cached;
  const res = await fetch(`https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=40`, {
    headers: { accept: "application/vnd.github+json", "user-agent": "wreckbox-api" },
  });
  const releases = res.ok ? await res.json() : [];
  let apk = null;
  for (const r of releases) {
    if (r.draft || !/^player-v/.test(r.tag_name || "")) continue;
    const a = (r.assets || []).find((x) => x.name.startsWith(PLAYER_ASSET_PREFIX) && x.name.endsWith(".apk"));
    if (a) { apk = { version: r.tag_name.replace(/^player-v/, ""), url: a.browser_download_url, size: a.size, date: r.published_at }; break; }
  }
  const mb = (n) => `${(n / 1048576).toFixed(1)} MB`;
  const feats = [
    ["One queue, three sources", "Songs on your phone, YouTube Music and Spotify, mixed in one queue."],
    ["Plays with the screen off", "Lock screen, notification, headphone and Bluetooth controls."],
    ["Search everything at once", "By song, artist or a line from the lyrics."],
    ["Song radio", "Tap one song; it keeps going with music like it."],
    ["No ads on YouTube", "Ad blocking is on by default. Your own accounts, no keys, no sign-up."],
    ["Light", `About ${apk ? mb(apk.size) : "3 MB"}. EQ, widget, real-time spectrum, FLAC and bitrate shown.`],
  ];
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WreckBox Player</title><meta name="description" content="A light Android music player: your phone's songs, YouTube Music and Spotify in one queue.">
<meta property="og:title" content="WreckBox Player"><meta property="og:description" content="Your phone's songs, YouTube Music and Spotify in one queue. Free, no ads.">
<link href="https://fonts.googleapis.com/css2?family=Doto:wght@700;900&family=Urbanist:wght@400;600;700&display=swap" rel="stylesheet">
<style>:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#08080A;color:#f0f0f0;font:16px Urbanist,-apple-system,system-ui,sans-serif}
.w{max-width:880px;margin:0 auto;padding:48px 16px}
.hero{position:relative;overflow:hidden;border-radius:28px;padding:40px 28px;background:radial-gradient(120% 140% at 100% 0%,rgba(187,150,218,.22),transparent 60%),radial-gradient(90% 120% at 0% 100%,rgba(239,175,134,.14),transparent 60%),rgba(255,255,255,.035);border:1px solid rgba(255,255,255,.09)}
h1{font:900 clamp(28px,7vw,44px) Doto,monospace;letter-spacing:3px;margin:0 0 10px;background:linear-gradient(90deg,#A9C8F0,#EFAF86,#BB96DA);-webkit-background-clip:text;background-clip:text;color:transparent}
.lead{color:#b4b4b4;margin:0 0 26px;font-size:18px;max-width:560px;line-height:1.45}
a.b{display:inline-block;padding:14px 24px;border-radius:999px;background:linear-gradient(135deg,#A9C8F0,#EFAF86,#BB96DA);color:#0a0a0c;text-decoration:none;font-weight:700;box-shadow:0 8px 30px rgba(187,150,218,.25)}
.meta{color:#777;font-size:13px;margin:10px 0 0;font-family:Doto,monospace;letter-spacing:1px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin:22px 0}
.f{background:rgba(255,255,255,.045);border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:18px}
.f b{display:block;margin-bottom:4px}.f span{color:#9a9a9a;font-size:14px;line-height:1.45}
h2{font:700 13px Doto,monospace;letter-spacing:2px;color:#9a9a9a;margin:30px 0 10px;text-transform:uppercase}
ol{color:#c4c4c4;padding-left:20px;line-height:1.6;margin:0}a{color:#BB96DA}.foot{color:#666;font-size:13px;margin-top:28px;line-height:1.5}</style></head>
<body><div class="w"><div class="hero"><h1>WRECKBOX PLAYER</h1>
<p class="lead">A light music player for Android: your phone's songs, YouTube Music and Spotify in one queue — and it keeps playing with the screen off.</p>
${apk ? `<a class="b" href="${apk.url}">Download for Android · ${apk.version}</a><p class="meta">${mb(apk.size)} · ${new Date(apk.date).toDateString().slice(4)} · Android 8+</p>`
      : `<p class="meta">The first version is on its way — check back soon.</p>`}</div>
<div class="grid">${feats.map(([t, d]) => `<div class="f"><b>${t}</b><span>${d}</span></div>`).join("")}</div>
<h2>Install</h2><ol>
<li>Open the downloaded <b>.apk</b> and allow installs from your browser when asked (open this page in Chrome, not inside WhatsApp or Instagram).</li>
<li>If Play Protect warns, tap <b>More details → Install anyway</b>.</li>
<li>Open the app → <b>⚙</b> → sign in to YouTube Music and/or Spotify (optional — your phone's songs work without).</li>
<li>Tap <b>Keep playing with the screen off → Allow</b>. On Samsung, never put it in "deep sleeping apps".</li></ol>
<h2>Good to know</h2><ol>
<li>Signing in is only for YouTube Music and Spotify, inside the app — no WreckBox account needed.</li>
<li>Have the WreckBox app? Link the Player (⚙ → Link to WreckBox) and your playlists download in FLAC there.</li></ol>
<p class="foot">Free and open source. <a href="https://github.com/moloyb301-eng/wreckbox/tree/main/player">Source</a> · <a href="/download">WreckBox for Mac &amp; Android</a></p></div></body></html>`;
  const out = new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" } });
  if (res.ok) ctx.waitUntil(caches.default.put(cacheKey, out.clone()));
  return out;
}

/// What a share link shows in a browser: open it in WreckBox (or get the app).
function sharePage(key) {
  const k = normKey(key);
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WreckBox — shared music</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#08080A;color:#f0f0f0;font:16px -apple-system,system-ui,sans-serif}
.c{max-width:420px;padding:32px;text-align:center}h1{font-size:22px;margin:0 0 8px}p{color:#999;line-height:1.5}
a.b{display:inline-block;margin:14px 6px 0;padding:12px 20px;border-radius:999px;background:#fff;color:#000;text-decoration:none;font-weight:600}
a.g{background:transparent;color:#BB96DA;border:1px solid #BB96DA66}code{color:#EFAF86;font-size:15px}</style></head>
<body><div class="c"><h1>Someone shared music with you</h1>
<p>Open this in WreckBox to stream and download it. If the app doesn't open, add the key by hand: <br><code>${k}</code></p>
<a class="b" href="wreckbox://share?key=${encodeURIComponent(k)}">Open in WreckBox</a>
<a class="b g" href="https://github.com/moloyb301-eng/wreckbox-releases/releases/latest">Get WreckBox</a></div></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
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
