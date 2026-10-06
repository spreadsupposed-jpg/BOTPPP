/* Yetimmm bridge — Cloudflare Worker + Durable Object
   EA (MT5)  --POST /api/ea/sync-->  Worker  <--GET /state, POST /command--  Mini App (HTML)

   Secrets (wrangler secret put <NAME>):
     BRIDGE_KEY   same value as the EA input InpBrKey (8+ chars)
     BOT_TOKEN    Telegram bot token — used ONLY here to verify who opens the Mini App
     ALLOWED_IDS  Telegram user ids allowed to control the bot, comma separated (empty = nobody)
     DEV_KEY      (optional, testing in a normal browser only — delete it after testing)
*/
const EA_STALE_MS = 15000;   // EA counts as offline after this long without a sync
const CMD_TTL_MS  = 30000;   // a queued command that was not picked up in time is dropped
const CMDS   = new Set(["start", "stop", "close", "apply", "reset", "settings"]);
const NUMS   = ["buy", "sell", "risk", "target", "rr"];
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Dev-Key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (o, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...CORS } });

function safeEq(a, b) {
  a = String(a); b = String(b);
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

/* Telegram Mini App initData check (HMAC-SHA256, per Telegram docs) */
export async function verifyInitData(initData, botToken, maxAgeSec = 86400) {
  const p = new URLSearchParams(initData);
  const hash = p.get("hash");
  if (!hash) return null;
  p.delete("hash");
  const dcs = [...p.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([k, v]) => k + "=" + v).join("\n");
  const enc = new TextEncoder();
  const hmac = async (key, msg) =>
    crypto.subtle.sign("HMAC", await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), msg);
  const secret = await hmac(enc.encode("WebAppData"), enc.encode(botToken));
  const sig = await hmac(secret, enc.encode(dcs));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (!safeEq(hex, hash)) return null;
  if (!(Date.now() / 1000 - Number(p.get("auth_date")) < maxAgeSec)) return null;
  try { return JSON.parse(p.get("user") || "null"); } catch { return null; }
}

async function authUser(req, env) {
  const dev = req.headers.get("X-Dev-Key");
  if (env.DEV_KEY && dev && safeEq(dev, env.DEV_KEY)) return { id: "dev" };
  const allowed = String(env.ALLOWED_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!allowed.length || !env.BOT_TOKEN) return null;
  const a = req.headers.get("Authorization") || "";
  if (!a.startsWith("tma ")) return null;
  const u = await verifyInitData(a.slice(4), env.BOT_TOKEN);
  return u && allowed.includes(String(u.id)) ? u : null;
}

export default {
  async fetch(req, env) {
    const p = new URL(req.url).pathname.replace(/\/+$/, "") || "/";
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (p === "/" || p === "/health") return json({ ok: true, service: "yetimmm-bridge" });

    const stub = env.BRIDGE.get(env.BRIDGE.idFromName("main"));

    if (p === "/api/ea/sync" && req.method === "POST") {
      if (!env.BRIDGE_KEY || !safeEq(req.headers.get("X-Bridge-Key") || "", env.BRIDGE_KEY)) return json({ ok: false, error: "bad_key" }, 401);
      return stub.fetch(new Request(req.url, { method: "POST", body: await req.text() }));
    }
    if ((p === "/state" && req.method === "GET") || (p === "/command" && req.method === "POST")) {
      const who = await authUser(req, env);
      if (!who) return json({ ok: false, error: "unauthorized" }, 401);
      return stub.fetch(new Request(req.url, {
        method: req.method,
        body: req.method === "POST" ? await req.text() : undefined,
        headers: { "X-User": String(who.id) },
      }));
    }
    return json({ ok: false, error: "not_found" }, 404);
  },
};

/* One object holds the live state (memory) and the command queue (storage). */
export class Bridge {
  constructor(state) { this.state = state; this.d = null; }

  async load() {
    if (this.d) return;
    const q = (await this.state.storage.get("q")) || { cmds: [] };
    this.d = { st: null, seen: 0, cmds: q.cmds };
  }
  saveQueue() { return this.state.storage.put("q", { cmds: this.d.cmds }); }

  async fetch(req) {
    await this.load();
    const d = this.d, now = Date.now(), p = new URL(req.url).pathname.replace(/\/+$/, "");
    const age = d.seen ? now - d.seen : null;
    const online = age !== null && age < EA_STALE_MS;

    if (p === "/api/ea/sync") {                       // ---- from the EA
      let b; try { b = JSON.parse(await req.text()); } catch { b = null; }
      if (!b || typeof b.state !== "object" || !b.state) return json({ ok: false, error: "bad_body" }, 400);
      const ack = new Set((Array.isArray(b.ack) ? b.ack : []).map(String));
      const before = d.cmds.length;
      d.cmds = d.cmds.filter((c) => !ack.has(c.id) && now - c.ts < CMD_TTL_MS);
      d.st = b.state; d.seen = now;
      if (d.cmds.length !== before) await this.saveQueue();
      // "id" must be the first key: the EA splits the response on "id":"
      return json({ ok: true, commands: d.cmds.map((c) => ({ id: c.id, cmd: c.cmd, ...c.p })) });
    }

    if (p === "/state") {                             // ---- to the Mini App
      return json({ ...(d.st || {}), eaOnline: online, eaAge: age === null ? null : Math.round(age / 100) / 10, srvTime: now });
    }

    if (p === "/command") {                           // ---- from the Mini App
      let b; try { b = JSON.parse(await req.text()); } catch { b = null; }
      const cmd = String((b && b.cmd) || "").toLowerCase();
      if (!CMDS.has(cmd)) return json({ ok: false, error: "bad_cmd" }, 400);
      if (!online) return json({ ok: false, error: "ea_offline" }, 503);   // never queue for an offline EA
      const params = {};
      for (const k of NUMS) {
        if (b[k] === undefined || b[k] === null) continue;
        const n = Number(b[k]);
        if (!Number.isFinite(n)) return json({ ok: false, error: "bad_" + k }, 400);
        params[k] = Math.round(n * 1e8) / 1e8;
      }
      d.cmds = d.cmds.filter((c) => now - c.ts < CMD_TTL_MS);
      if (d.cmds.length >= 5) return json({ ok: false, error: "queue_full" }, 429);
      const id = Math.random().toString(36).slice(2, 8) + now.toString(36);
      d.cmds.push({ id, cmd, p: params, ts: now, by: req.headers.get("X-User") || "" });
      await this.saveQueue();
      return json({ ok: true, id });
    }
    return json({ ok: false, error: "not_found" }, 404);
  }
}
