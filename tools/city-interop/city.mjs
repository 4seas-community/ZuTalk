/* Loads the city's own modules from a checkout, so that every interop check
   in this directory is judged by the city's code and not by a copy of it.

   The checkout is found through the CITY_SRC environment variable and is
   only ever read. Nothing here talks to a deployed city. */
import { pathToFileURL } from "node:url";
import { join, resolve } from "node:path";
import { existsSync } from "node:fs";
import { createECDH } from "node:crypto";

const root = process.env.CITY_SRC;
if (!root || !existsSync(join(root, "src", "lib", "record.js"))) {
  console.error("Set CITY_SRC to a checkout of the city software (the directory that holds src/lib/record.js).");
  process.exit(2);
}
const load = (path) => import(pathToFileURL(resolve(root, path)).href);

export const did = await load("src/lib/did.js");
export const sign = await load("src/lib/sign.js");
export const record = await load("src/lib/record.js");
export const link = await load("src/lib/link.js");
export const box = await load("src/lib/box.js");
export const tape = await load("src/lib/tape.js");
export const ev = await load("src/lib/ev.js");
export const arc = await load("src/lib/arc.js");
export const polis = await load("src/lib/polis.js");
export const keyroot = await load("src/lib/keyroot.js");
export const didwebvh = await load("src/lib/didwebvh.js");
export const { Facts } = await load("src/kernel/facts-core.js");

export const hex = (bytes) => Buffer.from(bytes).toString("hex");
export const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
export const seed = (byte) => new Uint8Array(32).fill(byte);

/* A record as the city's apps see it. */
export const view = (id, rec) => ({ id, type: rec.e.type, by: rec.e.by, key: rec.e.key, at: rec.e.at, links: rec.e.links, deps: rec.e.deps, body: rec.e.body });

/* The city's fact set over a list of records, and the query its reducers
   take. Records the set would not keep are left out exactly as a browser
   would leave them out. */
export async function world(recs) {
  const facts = new Facts();
  const report = await facts.merge(recs);
  const query = (pattern) => facts.query(pattern).map(([id, rec]) => view(id, rec));
  return { facts, query, report };
}

/* A version 1 person: the recovery seed is the key. */
export async function person(seedBytes) {
  const key = await did.fromSeed(seedBytes);
  const inc = await record.inception(key);
  return { seed: seedBytes, key, id: inc.id, inception: inc.rec, signer: { did: key.did, privateKey: key.privateKey } };
}

/* The same person after moving to did:webvh: a device key derived from the
   seed, the DID log that names it, and the id/did record that carries the
   log. `host` only shapes the identifier; nothing is fetched. */
export async function migrated(seedBytes, { host = "city.example", now }) {
  const p = await person(seedBytes);
  const account = p.id.slice(0, 16);
  const first = await didwebvh.createLog(p.signer, account, host);
  const log = await didwebvh.migrateLog(first, { S: seedBytes, k0: p.key, account, host, now });
  const device = await keyroot.signKeyOf(seedBytes, 1);
  const webvh = log[log.length - 1].state.id;
  const signer = { did: device.did, privateKey: device.privateKey, controller: webvh };
  const didRec = await record.make(signer, p.id, "id/did", { log, witness: [] }, { deps: [p.id], at: now + 1000 });
  return { ...p, account, log, webvh, device, signer, didRec: didRec.rec,
    bundle: { id: p.id, j: 1, webvh, sign: b64url(await did.seedOf(device)), root: b64url(await keyroot.rootOf(seedBytes)), inc: p.inception,
      legacy: Object.fromEntries(Object.entries(await keyroot.legacyBoxes(seedBytes)).map(([k, v]) => [k, { box: b64url(v.box), file: b64url(v.file), nonce: b64url(v.nonce) }])) } };
}

/* A P-256 key pair from a fixed scalar, as WebCrypto wants it. */
export async function linkKey(scalar) {
  const ecdh = createECDH("prime256v1");
  ecdh.setPrivateKey(Buffer.from(scalar));
  const pub = ecdh.getPublicKey();
  const jwk = { kty: "EC", crv: "P-256", d: b64url(scalar), x: b64url(pub.subarray(1, 33)), y: b64url(pub.subarray(33)) };
  const priv = await crypto.subtle.importKey("jwk", jwk, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  return { priv, pub: b64url(pub) };
}

/* Runs `fn` with a counting stand-in for the random source, so that a sealed
   box (random IV) comes out the same on every run and fixtures do not churn. */
export async function steady(fn) {
  const real = crypto.getRandomValues.bind(crypto);
  let n = 0;
  crypto.getRandomValues = (a) => { for (let i = 0; i < a.length; i++) a[i] = (n = (n + 37) & 0xff); return a; };
  try { return await fn(); } finally { crypto.getRandomValues = real; }
}
