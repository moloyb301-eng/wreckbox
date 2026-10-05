// WreckBox bug-report relay (Cloudflare Worker).
//
// The apps POST a report here; the worker creates an issue in the private code repo (GitHub then emails
// the owner) and commits any screenshots to bug-reports/<date>-<id>/ so the issue can show them.
// The GitHub token lives only in the worker's secrets — never in the apps.
//
// Secrets / vars (see wrangler.toml and README.md):
//   GITHUB_TOKEN  fine-grained token: Issues read/write + Contents read/write on the code repo only
//   GITHUB_REPO   "owner/wreckbox"
//   APP_KEY       shared string the apps send in X-WreckBox-Key (stops casual spam; not a real secret)
//   RATE_LIMIT    optional KV namespace binding for per-IP limits

const MAX_SCREENSHOTS = 3;
const MAX_SCREENSHOT_BYTES = 3 * 1024 * 1024;
const MAX_TEXT = 20_000;
const REPORTS_PER_IP_PER_HOUR = 10;

export default {
  async fetch(request, env) {
    if (request.method === "GET") return json({ ok: true, service: "wreckbox-bug-relay" });
    if (request.method !== "POST") return json({ ok: false, error: "POST a report" }, 405);
    if (request.headers.get("X-WreckBox-Key") !== env.APP_KEY) return json({ ok: false, error: "unauthorised" }, 401);

    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    if (env.RATE_LIMIT) {
      const key = `ip:${ip}:${new Date().toISOString().slice(0, 13)}`;
      const n = parseInt((await env.RATE_LIMIT.get(key)) || "0", 10);
      if (n >= REPORTS_PER_IP_PER_HOUR) return json({ ok: false, error: "too many reports, try again later" }, 429);
      await env.RATE_LIMIT.put(key, String(n + 1), { expirationTtl: 3600 });
    }

    let report;
    try {
      report = await request.json();
    } catch {
      return json({ ok: false, error: "invalid JSON" }, 400);
    }
    const title = clip(report.title || "Bug report", 120);
    const description = clip(report.description || "", MAX_TEXT);
    if (!description.trim()) return json({ ok: false, error: "description is required" }, 400);

    const id = crypto.randomUUID().slice(0, 8);
    const folder = `bug-reports/${new Date().toISOString().slice(0, 10)}-${id}`;
    const images = [];
    for (const [i, shot] of (report.screenshots || []).slice(0, MAX_SCREENSHOTS).entries()) {
      const b64 = String(shot.data || "").replace(/^data:image\/\w+;base64,/, "");
      if (b64.length * 0.75 > MAX_SCREENSHOT_BYTES) continue;
      const ext = shot.type === "image/jpeg" ? "jpg" : "png";
      const path = `${folder}/screenshot-${i + 1}.${ext}`;
      const res = await gh(env, `/repos/${env.GITHUB_REPO}/contents/${path}`, "PUT", {
        message: `Bug report ${id}: screenshot ${i + 1}`,
        content: b64,
      });
      if (res.ok) images.push(path);
    }

    const meta = [
      ["App", `${clip(report.app || "WreckBox", 40)} ${clip(report.version || "?", 30)}`],
      ["Platform", clip(report.platform || "?", 80)],
      ["Reporter", clip(report.reporter || "anonymous", 80)],
      ["Contact", clip(report.contact || "—", 120)],
      ["Report id", id],
    ];
    const body = [
      description,
      "",
      "| | |", "|---|---|",
      ...meta.map(([k, v]) => `| ${k} | ${v.replace(/\|/g, "\\|")} |`),
      ...(images.length ? ["", "### Screenshots", ...images.map((p) => `![screenshot](https://github.com/${env.GITHUB_REPO}/blob/main/${p}?raw=true)`)] : []),
      ...(report.logs ? ["", "<details><summary>Recent log</summary>", "", "```", clip(report.logs, MAX_TEXT), "```", "</details>"] : []),
    ].join("\n");

    const issue = await gh(env, `/repos/${env.GITHUB_REPO}/issues`, "POST", {
      title: `[bug] ${title}`,
      body,
      labels: ["bug", "from-app", clip(report.platform || "unknown", 30).split(" ")[0].toLowerCase()],
    });
    if (!issue.ok) return json({ ok: false, error: `GitHub said ${issue.status}` }, 502);
    const created = await issue.json();
    return json({ ok: true, id, issue: created.number });
  },
};

function clip(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n) + "…" : s;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

function gh(env, path, method, body) {
  return fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: "application/vnd.github+json",
      "user-agent": "wreckbox-bug-relay",
      "x-github-api-version": "2022-11-28",
    },
    body: JSON.stringify(body),
  });
}
