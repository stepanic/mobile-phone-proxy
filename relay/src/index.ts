import { DurableObject } from "cloudflare:workers";

/**
 * Relay for "rotate the phone's public IP" commands.
 *
 *   caller ──POST /v1/phones/:id/rotate──▶ Worker ──▶ Phone DO ──WebSocket──▶ iPhone app
 *   caller ◀──GET  /v1/phones/:id/jobs/:jobId──────────── job state ◀── ack / result
 *
 * The relay is a mailbox, not a point of trust: commands are the same
 * HMAC-signed "MPP-ROTATE v1 <ts> <nonce> <hmac>" strings the iMessage path
 * uses, and only the phone holds the key to verify them. The relay checks the
 * shape and freshness (to drop junk early) and authenticates the phone's
 * WebSocket with a per-phone token, so nobody else can sit on the phone's
 * mailbox and swallow commands.
 */

export interface Env {
  PHONE: DurableObjectNamespace<Phone>;
  /** JSON {"<phoneId>": "<hex token>"}; token = HMAC(secret, "MPP-RELAY|v1|<phoneId>"). */
  PHONE_TOKENS: string;
}

type JobStatus = "queued" | "sent" | "accepted" | "rejected" | "rotating" | "done" | "failed";
const TERMINAL: JobStatus[] = ["rejected", "done", "failed"];

interface Job {
  id: string;
  command: string;
  status: JobStatus;
  createdAt: number;
  updatedAt: number;
  detail?: string;
  oldIP?: string;
  newIP?: string;
}

/** A rotation is ~97 s end to end; past this a non-terminal job is dead. */
const JOB_TIMEOUT_MS = 6 * 60_000;
/** Same window as RotateAuth on the phone (300 s + 60 s skew). */
const MAX_COMMAND_AGE_S = 300;
const MAX_FUTURE_SKEW_S = 60;
const COMMAND_RE = /^MPP-ROTATE v1 (\d{9,11}) [A-Za-z0-9]{8,64} [0-9a-fA-F]{64}$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const m = url.pathname.match(/^\/v1\/phones\/([A-Za-z0-9_-]{1,64})(\/.*)?$/);
    if (!m) return json({ error: "not found" }, 404);
    const [, phoneId, rest = ""] = m;
    // Only known phones get a Durable Object; anything else would let strangers
    // create storage under arbitrary names.
    if (!(phoneId in phoneTokens(env))) return json({ error: "unknown phone" }, 404);
    const stub = env.PHONE.getByName(phoneId);

    if (rest === "/connect") {
      if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expected websocket" }, 426);
      if (!(await phoneTokenValid(env, phoneId, request.headers.get("Authorization")))) {
        return json({ error: "unauthorized" }, 401);
      }
      return stub.fetch(request);
    }
    if (rest === "/rotate" && request.method === "POST") {
      const body = await request.json<{ command?: string }>().catch(() => ({} as { command?: string }));
      const command = (body.command ?? "").trim();
      const shape = checkCommand(command);
      if (shape) return json({ error: shape }, 400);
      const { status, body: out } = await stub.submit(command);
      return json(out, status);
    }
    const jm = rest.match(/^\/jobs\/([a-f0-9-]{36})$/);
    if (jm && request.method === "GET") {
      const job = await stub.job(jm[1]);
      return job ? json(publicJob(job)) : json({ error: "no such job" }, 404);
    }
    if (rest === "" && request.method === "GET") {
      return json(await stub.state());
    }
    return json({ error: "not found" }, 404);
  },
} satisfies ExportedHandler<Env>;

export class Phone extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY, command TEXT NOT NULL, status TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        detail TEXT, old_ip TEXT, new_ip TEXT)`);
    });
    // Keepalive pings from the app are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** WebSocket upgrade from the phone (already authenticated by the Worker). */
  async fetch(_request: Request): Promise<Response> {
    // One phone, one socket: a reconnect after airplane mode replaces the old one.
    for (const old of this.ctx.getWebSockets()) old.close(1000, "replaced");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    await this.ctx.storage.put("connectedAt", Date.now());
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw !== "string") return;
    let msg: PhoneMessage;
    try { msg = JSON.parse(raw); } catch { return; }
    const now = Date.now();
    await this.ctx.storage.put("lastSeen", now);

    switch (msg.type) {
      case "hello":
      case "ip":
        if (msg.publicIP) await this.ctx.storage.put({ publicIP: msg.publicIP, publicIPAt: now });
        if (msg.type === "hello") this.deliverQueued(ws);
        break;
      case "ack":
        this.update(msg.jobId, msg.verdict === "accepted" ? "accepted" : "rejected",
          { detail: msg.verdict, oldIP: msg.publicIP });
        break;
      case "rotating":
        this.update(msg.jobId, "rotating", {});
        break;
      case "result":
        this.update(msg.jobId, msg.ok ? "done" : "failed",
          { detail: msg.detail, oldIP: msg.oldIP, newIP: msg.newIP });
        if (msg.newIP) await this.ctx.storage.put({ publicIP: msg.newIP, publicIPAt: now });
        break;
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string) {
    try { ws.close(code, reason); } catch { /* already closed */ }
  }

  // MARK: RPC from the Worker

  async submit(command: string): Promise<{ status: number; body: unknown }> {
    this.expireStale();
    const busy = this.ctx.storage.sql.exec<{ id: string }>(
      `SELECT id FROM jobs WHERE status NOT IN ('rejected','done','failed') LIMIT 1`).toArray();
    if (busy.length) return { status: 409, body: { error: "a rotation is already in progress", jobId: busy[0].id } };

    const now = Date.now();
    const job: Job = { id: crypto.randomUUID(), command, status: "queued", createdAt: now, updatedAt: now };
    this.ctx.storage.sql.exec(
      `INSERT INTO jobs (id, command, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
      job.id, job.command, job.status, now, now);
    // Prune history; nothing reads jobs older than a day.
    this.ctx.storage.sql.exec(`DELETE FROM jobs WHERE created_at < ?`, now - 86_400_000);

    const ws = this.ctx.getWebSockets()[0];
    if (ws) this.send(ws, job);
    await this.ctx.storage.setAlarm(now + JOB_TIMEOUT_MS);
    const saved = this.job(job.id)!;
    return { status: 202, body: { ...publicJob(saved), phoneConnected: !!ws } };
  }

  job(id: string): Job | null {
    const r = this.ctx.storage.sql.exec<JobRow>(`SELECT * FROM jobs WHERE id = ?`, id).toArray()[0];
    return r ? fromRow(r) : null;
  }

  async state() {
    const [publicIP, publicIPAt, lastSeen, connectedAt] = await Promise.all(
      ["publicIP", "publicIPAt", "lastSeen", "connectedAt"].map(k => this.ctx.storage.get(k)));
    const last = this.ctx.storage.sql.exec<JobRow>(`SELECT * FROM jobs ORDER BY created_at DESC LIMIT 1`).toArray()[0];
    return {
      connected: this.ctx.getWebSockets().length > 0,
      connectedAt: iso(connectedAt), lastSeen: iso(lastSeen),
      publicIP: publicIP ?? null, publicIPAt: iso(publicIPAt),
      lastJob: last ? publicJob(fromRow(last)) : null,
    };
  }

  async alarm() {
    this.expireStale();
  }

  // MARK: helpers

  private deliverQueued(ws: WebSocket) {
    this.expireStale();
    for (const r of this.ctx.storage.sql.exec<JobRow>(`SELECT * FROM jobs WHERE status = 'queued'`).toArray()) {
      this.send(ws, fromRow(r));
    }
  }

  private send(ws: WebSocket, job: Job) {
    try {
      ws.send(JSON.stringify({ type: "rotate", jobId: job.id, command: job.command }));
      this.update(job.id, "sent", {});
    } catch {
      // Socket died between lookup and send; the job stays queued for the next hello.
    }
  }

  private update(id: string, status: JobStatus, f: { detail?: string; oldIP?: string; newIP?: string }) {
    const job = this.job(id);
    if (!job || TERMINAL.includes(job.status)) return;
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET status = ?, updated_at = ?, detail = COALESCE(?, detail),
         old_ip = COALESCE(?, old_ip), new_ip = COALESCE(?, new_ip) WHERE id = ?`,
      status, Date.now(), f.detail ?? null, f.oldIP ?? null, f.newIP ?? null, id);
  }

  private expireStale() {
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET status = 'failed', detail = 'timed out', updated_at = ?
         WHERE status NOT IN ('rejected','done','failed') AND created_at < ?`,
      Date.now(), Date.now() - JOB_TIMEOUT_MS);
  }
}

type PhoneMessage =
  | { type: "hello"; publicIP?: string; build?: string }
  | { type: "ip"; publicIP?: string }
  | { type: "ack"; jobId: string; verdict: string; publicIP?: string }
  | { type: "rotating"; jobId: string }
  | { type: "result"; jobId: string; ok: boolean; detail?: string; oldIP?: string; newIP?: string };

type JobRow = {
  id: string; command: string; status: JobStatus; created_at: number; updated_at: number;
  detail: string | null; old_ip: string | null; new_ip: string | null;
};

function fromRow(r: JobRow): Job {
  return {
    id: r.id, command: r.command, status: r.status, createdAt: r.created_at, updatedAt: r.updated_at,
    detail: r.detail ?? undefined, oldIP: r.old_ip ?? undefined, newIP: r.new_ip ?? undefined,
  };
}

function publicJob(j: Job) {
  return {
    jobId: j.id, status: j.status, createdAt: iso(j.createdAt), updatedAt: iso(j.updatedAt),
    detail: j.detail ?? null, oldIP: j.oldIP ?? null, newIP: j.newIP ?? null,
  };
}

function checkCommand(command: string): string | null {
  const m = command.match(COMMAND_RE);
  if (!m) return "command must be 'MPP-ROTATE v1 <unix-ts> <nonce> <hex hmac>'";
  const age = Date.now() / 1000 - Number(m[1]);
  if (age > MAX_COMMAND_AGE_S) return "command expired";
  if (age < -MAX_FUTURE_SKEW_S) return "command timestamp in the future";
  return null;
}

async function phoneTokenValid(env: Env, phoneId: string, auth: string | null): Promise<boolean> {
  const expected = phoneTokens(env)[phoneId];
  const given = auth?.match(/^Bearer (\S+)$/)?.[1];
  if (!expected || !given) return false;
  const a = new TextEncoder().encode(expected), b = new TextEncoder().encode(given);
  return a.byteLength === b.byteLength && crypto.subtle.timingSafeEqual(a, b);
}

function phoneTokens(env: Env): Record<string, string> {
  try { return JSON.parse(env.PHONE_TOKENS ?? "{}"); } catch { return {}; }
}

function iso(ms: unknown): string | null {
  return typeof ms === "number" ? new Date(ms).toISOString() : null;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}
