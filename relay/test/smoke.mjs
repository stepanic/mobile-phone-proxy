// End-to-end smoke test against `wrangler dev` (default http://127.0.0.1:8787).
// Plays the phone over the WebSocket and a caller over HTTP.
//   RELAY=http://127.0.0.1:8787 TOKEN=test-token node test/smoke.mjs
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";

const RELAY = process.env.RELAY ?? "http://127.0.0.1:8787";
const TOKEN = process.env.TOKEN ?? "test-token";
const PHONE = process.env.PHONE ?? "smoke";
const base = `${RELAY}/v1/phones/${PHONE}`;

// Shape-valid command; the relay can't check the HMAC, only the phone can.
const command = () =>
  `MPP-ROTATE v1 ${Math.floor(Date.now() / 1000)} ${randomBytes(8).toString("hex")} ${randomBytes(32).toString("hex")}`;
const post = (cmd) =>
  fetch(`${base}/rotate`, { method: "POST", body: JSON.stringify({ command: cmd }) })
    .then(async (r) => ({ status: r.status, body: await r.json() }));
const job = (id) => fetch(`${base}/jobs/${id}`).then((r) => r.json());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${base.replace(/^http/, "ws")}/connect`,
      { headers: token ? { Authorization: `Bearer ${token}` } : {} });
    const inbox = [];
    ws.onmessage = (e) => inbox.push(e.data);
    ws.onopen = () => resolve({ ws, inbox });
    ws.onerror = () => reject(new Error("ws error"));
  });
}
async function next(inbox, pred, ms = 3000) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(50)) {
    const i = inbox.findIndex(pred);
    if (i >= 0) return inbox.splice(i, 1)[0];
  }
  throw new Error("timed out waiting for message");
}

let r = await fetch(base).then((r) => r.json());
assert.equal(r.connected, false);

r = await post("MPP-ROTATE v1 nope");
assert.equal(r.status, 400, "malformed command rejected");
r = await post(`MPP-ROTATE v1 ${Math.floor(Date.now() / 1000) - 1000} abcdefgh12 ${"a".repeat(64)}`);
assert.equal(r.status, 400, "expired command rejected");

// Queued while the phone is offline, delivered on hello.
r = await post(command());
assert.equal(r.status, 202);
assert.equal(r.body.status, "queued");
assert.equal(r.body.phoneConnected, false);
const queuedId = r.body.jobId;
assert.equal((await post(command())).status, 409, "one job at a time");

await assert.rejects(connect("wrong-token"), "bad token refused");
await assert.rejects(connect(null), "missing token refused");

let { ws, inbox } = await connect(TOKEN);
ws.send(JSON.stringify({ type: "hello", publicIP: "86.33.1.1" }));
let m = JSON.parse(await next(inbox, (d) => d.includes('"rotate"')));
assert.equal(m.jobId, queuedId);
assert.equal((await job(queuedId)).status, "sent");

ws.send("ping");
assert.equal(await next(inbox, (d) => d === "pong"), "pong", "auto-response keepalive");

ws.send(JSON.stringify({ type: "ack", jobId: queuedId, verdict: "accepted", publicIP: "86.33.1.1" }));
ws.send(JSON.stringify({ type: "rotating", jobId: queuedId }));
await sleep(200);
assert.equal((await job(queuedId)).status, "rotating");

// Airplane mode: the socket drops, the phone reconnects and reports.
ws.close();
await sleep(200);
({ ws, inbox } = await connect(TOKEN));
ws.send(JSON.stringify({ type: "hello", publicIP: "86.33.2.2" }));
ws.send(JSON.stringify({ type: "result", jobId: queuedId, ok: true, oldIP: "86.33.1.1", newIP: "86.33.2.2" }));
await sleep(200);
r = await job(queuedId);
assert.deepEqual([r.status, r.oldIP, r.newIP], ["done", "86.33.1.1", "86.33.2.2"]);

// Delivered immediately while connected; a phone-side rejection is terminal.
r = await post(command());
assert.equal(r.body.phoneConnected, true);
m = JSON.parse(await next(inbox, (d) => d.includes('"rotate"')));
ws.send(JSON.stringify({ type: "ack", jobId: m.jobId, verdict: "rejected: bad signature" }));
await sleep(200);
r = await job(m.jobId);
assert.deepEqual([r.status, r.detail], ["rejected", "rejected: bad signature"]);

r = await fetch(base).then((r) => r.json());
assert.equal(r.connected, true);
assert.equal(r.publicIP, "86.33.2.2");
ws.close();
console.log("relay smoke test: all checks passed");
