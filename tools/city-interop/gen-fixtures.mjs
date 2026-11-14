#!/usr/bin/env node
/* Writes the fixtures the vt-city tests are checked against.

   Every expected value in them is computed by the city's own code, loaded
   from a checkout (CITY_SRC): canonical JSON and fingerprints, keys and
   inceptions, signed records and the verdicts on damaged ones, the device
   link exchange, sentence marks, what becomes of a part of a recording's
   audio, and the city's reduction of a set of event and channel records.
   The Rust tests then run offline against the files.

     CITY_SRC=<city checkout> node tools/city-interop/gen-fixtures.mjs

   All keys are derived from fixed bytes chosen here, all names are invented,
   and the output is the same on every run. */
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import * as city from "./city.mjs";

const { did, sign, record, link, box, tape, ev, arc, polis, hex, b64url, seed } = city;
const out = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "crates", "vt-city", "tests", "fixtures");
mkdirSync(out, { recursive: true });
const write = (name, value) => { writeFileSync(join(out, name), JSON.stringify(value, null, 1) + "\n"); console.log("wrote", name); };

const T0 = 1_780_000_000_000, HOUR = 3600e3, DAY = 24 * HOUR;
const sha = (bytes) => createHash("sha256").update(bytes).digest();

/* ---------- canonical JSON ---------- */
{
  const texts = [
    "{}", "[]", "null", "true", "false", "0", "\"\"",
    "\"\\u20ac$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"",
    "{\"b\":1,\"a\":2,\"aa\":3,\"A\":4,\"\":5,\"a b\":6}",
    "{\"\\ud83d\\ude00\":1,\"\\ufb01\":2,\"\\u00e9\":3,\"e\\u0301\":4,\"z\":5,\"\\ue000\":6,\"\\ud7ff\":7}",
    "[0,-0,0.0,-0.0,1,-1,1.0,1.5,100,1e2,1E2,1e21,1e-7,0.000001,0.0000001,123456789012345680000,9007199254740993,18446744073709551615,-9223372036854775808,5e-324,1.7976931348623157e308,0.1,0.30000000000000004,1e+30,4.50,2.5e-10,333333333.33333329,1E23,1e22,0.1e1,123456789012345678901234567890,9007199254740991,-9007199254740992]",
    "{\"e\":{\"v\":3,\"type\":\"x/y\",\"by\":null,\"deps\":[],\"links\":[\"a\"],\"body\":{\"z\":[1,{\"k\":\"v\"}],\"a\":\"\\u0000\\u001f\\u007f\\u2028\\u2029\\b\\f\\r\\t\"},\"at\":1794528000123}}",
    "{\"a\":1,\"a\":2}",
    "{\"标题\":\"清迈 🌏 เชียงใหม่\",\"タイトル\":\"テスト\",\"제목\":\"시험\"}",
    "[[[[[[[[[[]]]]]]]]]]",
    " { \"spaced\" : [ 1 , 2 ] } ",
  ];
  const cases = [];
  for (const text of texts) {
    const value = JSON.parse(text);
    cases.push({ text, canonical: sign.jcs(value), fingerprint: await sign.fingerprint(value) });
  }
  write("jcs.json", { cases });
}

/* ---------- keys and identities ---------- */
const ada = await city.person(seed(0x21));          // hosts events
const ben = await city.person(seed(0x22));          // co-host
const cai = await city.person(seed(0x23));          // recorder
const dov = await city.person(seed(0x24));          // a stranger to the city
const mo = await city.migrated(seed(0x25), { now: T0 - 30 * DAY });   // moved to did:webvh
const eve = await city.person(seed(0x26));          // signs under other people's names
const gus = await city.person(seed(0x27));          // their inception is never included
const fen = await city.person(seed(0x31));          // founded the city
{
  const key = await did.keyString(ada.key);
  const bare = key.slice(did.KEY_PREFIX.length);
  const flipped = key.slice(0, -1) + (key.endsWith("2") ? "3" : "2");
  const head = Uint8Array.from([0x96, 0x01]);
  const upstream = did.base58(Buffer.concat([head, ada.seed, sha(Buffer.concat([head, ada.seed])).subarray(0, 4)]));
  if ((await did.restoreKey(upstream)).did !== ada.key.did) throw new Error("upstream backup code does not restore the same key");
  const badUpstream = upstream.slice(0, -1) + (upstream.endsWith("2") ? "3" : "2");
  const rejects = async (text) => { try { await did.restoreKey(did.keyIn(text)); return false; } catch (e) { return true; } };
  for (const text of [flipped, badUpstream, "", "sibian-key-1:0OIl"]) if (!(await rejects(text))) throw new Error("the city accepted a bad key: " + text);
  write("identity.json", {
    people: await Promise.all([ada, ben].map(async (p) => ({ seed: hex(p.seed), key_string: await did.keyString(p.key), did_key: p.key.did, id: p.id, inception: p.inception }))),
    spellings: [key, bare, bare.match(/.{1,4}/g).join(" "), "\n  " + key.replace(":", ":\t") + "\n", upstream],
    spellings_id: ada.id,
    rejected: [flipped, badUpstream, "", "sibian-key-1:0OIl", bare.slice(0, 20)],
    migrated: { bundle: mo.bundle, id: mo.id, did_key: mo.device.did, controller: mo.webvh, inception_key: mo.key.did },
  });
}

/* ---------- signed records ---------- */
const EVENT = "ab".repeat(32);
{
  const made = [];
  const add = async (who, signer, by, type, body, opts) => {
    const x = await record.make(signer, by, type, body, opts);
    if ((await record.intrinsic(x.rec)) !== "ok") throw new Error("the city rejects its own record");
    made.push({ who, kind: type, body, links: opts.links || [], deps: opts.deps || [], at: opts.at, id: x.id, rec: x.rec, signature: sign.sigOf(x.rec) });
    return x;
  };
  await add("v1", ada.signer, ada.id, "tape/take", { mime: "", started: T0 }, { deps: [ada.id], links: [EVENT], at: T0 + 123 });
  await add("v1", ada.signer, ada.id, "tape/text", { segs: [{ t: 0, d: 1500, sp: "1", text: "Good morning — สวัสดี — 早上好 🌏" }, { t: 2500, d: 900.5, sp: "", text: "quote \" backslash \\ tab \t" }] }, { deps: [ada.id, EVENT], links: [EVENT], at: 0 });
  await add("v1", ada.signer, ada.id, "arc/connect", {}, { deps: [EVENT], links: [EVENT, "cd".repeat(32)], at: 253402300799999 });
  await add("v2", mo.signer, mo.id, "arc/block", { kind: "audio", title: "Recording · Signed after moving", take: EVENT, dur: 5400000 }, { deps: [mo.id], links: [EVENT], at: T0 + 456 });
  await add("v2", mo.signer, mo.id, "tape/end", {}, { deps: [EVENT], links: [EVENT], at: T0 + 457 });
  const spoken = await record.makeV2(ada.signer, ada.id, record.PRESENT, {}, { deps: [], at: T0 + 789 });
  made.push({ who: "v1", kind: record.PRESENT, body: {}, links: [], deps: [], at: T0 + 789, id: spoken.id, rec: spoken.rec, signature: sign.sigOf(spoken.rec) });

  /* Records that have been damaged, or were never right, each with the
     city's verdict. */
  const verdicts = [];
  const judge = async (note, rec) => verdicts.push({ note, rec, verdict: await record.intrinsic(rec) });
  const good = made[0].rec, clone = (x) => JSON.parse(JSON.stringify(x));
  const edit = (fn) => { const r = clone(good); fn(r); return r; };
  await judge("an inception", ada.inception);
  await judge("a record as signed", good);
  await judge("a record signed under a did:webvh controller", made[3].rec);
  await judge("a spoken statement", spoken.rec);
  await judge("body changed after signing", edit((r) => { r.e.body.started += 1; }));
  await judge("time changed after signing", edit((r) => { r.e.at += 1; }));
  await judge("a link added after signing", edit((r) => { r.e.links.push(EVENT); }));
  await judge("signed by another key than it names", edit((r) => { r.e.key = ben.key.did; r.proof[0].verificationMethod = ben.key.did + "#" + ben.key.did.slice(8); }));
  await judge("proof option changed after signing", edit((r) => { r.proof[0].created = "2026-01-01T00:00:00.000Z"; }));
  await judge("a member added to the proof after signing", edit((r) => { r.proof[0].note = "added"; }));
  await judge("a version 3 record that also carries s", edit((r) => { r.s = ada.inception.s; }));
  await judge("no author proof", edit((r) => { r.proof = []; }));
  await judge("proof is not a list", edit((r) => { r.proof = r.proof[0]; }));
  await judge("type longer than 64", edit((r) => { r.e.type = "x".repeat(65); }));
  await judge("empty type", edit((r) => { r.e.type = ""; }));
  await judge("by is missing", edit((r) => { delete r.e.by; }));
  await judge("by is a number", edit((r) => { r.e.by = 7; }));
  await judge("body is missing", edit((r) => { delete r.e.body; }));
  await judge("time is a string", edit((r) => { r.e.at = "0"; }));
  await judge("65 dependencies", edit((r) => { r.e.deps = Array(65).fill(ada.id); }));
  await judge("a dependency longer than 128", edit((r) => { r.e.deps = ["a".repeat(129)]; }));
  await judge("a link that is not text", edit((r) => { r.e.links = [1]; }));
  await judge("created with four fractional digits", edit((r) => { r.proof[0].created = "2026-05-28T00:00:00.0000Z"; }));
  await judge("proof value too short", edit((r) => { r.proof[0].proofValue = "z" + "1".repeat(40); }));
  await judge("proof value not base58", edit((r) => { r.proof[0].proofValue = "z" + "0".repeat(88); }));
  await judge("a version 3 inception", edit((r) => { r.e.type = "id/inception"; }));
  await judge("someone else's did:webvh in front of the key", edit((r) => { r.proof[0].verificationMethod = "did:webvh:" + "1".repeat(46) + ":city.example:u:" + ben.id.slice(0, 16) + "#" + ada.key.did.slice(8); }));
  await judge("key with another multicodec prefix", edit((r) => { const mk = "z" + did.base58(Uint8Array.from([0xec, 0x01, ...did.unbase58(ada.key.did.slice(9)).slice(2)])); r.e.key = "did:key:" + mk; r.proof[0].verificationMethod = "did:key:" + mk + "#" + mk; }));
  await judge("key that is not a did:key", edit((r) => { r.e.key = "did:web:city.example"; }));
  /* The proof carries a witness receipt next to the author's own entry. */
  {
    const config = { type: "DataIntegrityProof", cryptosuite: "eddsa-jcs-2022", verificationMethod: ben.key.did + "#" + ben.key.did.slice(8), created: "2026-05-28T00:00:01.000Z", proofPurpose: "assertionMethod" };
    const receipt = { ...config, proofValue: "z" + did.base58(await did.signBytes(ben.signer, await sign.diBytes(config, good.e))) };
    await judge("a witness receipt before the author's proof", edit((r) => { r.proof = [receipt, r.proof[0]]; }));
    await judge("only a witness receipt", edit((r) => { r.proof = [receipt]; }));
  }
  /* A proof option this client has never heard of, present when signed. */
  {
    const e = clone(good.e);
    const config = { type: "DataIntegrityProof", cryptosuite: "eddsa-jcs-2022", verificationMethod: ada.key.did + "#" + ada.key.did.slice(8), created: sign.createdOf(e.at), proofPurpose: "assertionMethod", domain: "city.example" };
    await judge("an unknown proof option that was signed", { e, proof: [{ ...config, proofValue: "z" + did.base58(await did.signBytes(ada.signer, await sign.diBytes(config, e))) }] });
  }
  /* Version 2 spellings and the shapes Ed25519 engines disagree on. */
  const inc = ada.inception, sigBytes = sign.unb64url(inc.s);
  const second = "AQgw".replace(inc.s.at(-1), "")[0];
  await judge("a second spelling of the same signature", { e: inc.e, s: inc.s.slice(0, -1) + String.fromCharCode(inc.s.charCodeAt(85) + 1) });
  await judge("a different final signature byte", { e: inc.e, s: inc.s.slice(0, -1) + second });
  await judge("signature with padding", { e: inc.e, s: inc.s + "==" });
  {
    const L = 2n ** 252n + 27742317777372353535851937790883648493n;
    const le = (b) => b.reduceRight((n, x) => (n << 8n) | BigInt(x), 0n);
    const toLe = (n) => Uint8Array.from({ length: 32 }, (_, i) => Number((n >> BigInt(8 * i)) & 0xffn));
    const high = Uint8Array.from([...sigBytes.slice(0, 32), ...toLe(le(sigBytes.slice(32)) + L)]);
    await judge("S not reduced below the group order", { e: inc.e, s: b64url(high) });
    const keyOf = (bytes) => "did:key:z" + did.base58(Uint8Array.from([0xed, 0x01, ...bytes]));
    const identity = Uint8Array.from([1, ...Array(31).fill(0)]);
    const forged = (pub, r) => ({ e: { ...inc.e, key: keyOf(pub) }, s: b64url(Uint8Array.from([...r, ...Array(32).fill(0)])) });
    await judge("a small-order key with S = 0", forged(identity, identity));
    await judge("the same with the sign bit set", forged(Uint8Array.from([1, ...Array(30).fill(0), 0x80]), identity));
    const order2 = Uint8Array.from([0xec, ...Array(30).fill(0xff), 0x7f]);
    await judge("a key of order two", forged(order2, identity));
    await judge("a key encoded above the field prime", forged(Uint8Array.from([0xef, ...Array(30).fill(0xff), 0x7f]), identity));
    await judge("a small-order R under an honest key", { e: inc.e, s: b64url(Uint8Array.from([...identity, ...sigBytes.slice(32)])) });
  }
  write("records.json", { event: EVENT, made, verdicts });
}

/* ---------- device link ---------- */
{
  const newScalar = seed(0x11), oldScalar = seed(0x12);
  const fresh = await city.linkKey(newScalar), old = await city.linkKey(oldScalar);
  const oldSide = await link.agree(old.priv, old.pub, fresh.pub), newSide = await link.agree(fresh.priv, fresh.pub, old.pub);
  if (oldSide.check !== newSide.check) throw new Error("the two sides disagree");
  /* The city keeps the derived key unextractable; derive the same bytes
     once more by the same recipe to record what the key is. */
  const enc = new TextEncoder();
  const bits = await crypto.subtle.deriveBits({ name: "ECDH", public: await crypto.subtle.importKey("raw", sign.unb64url(old.pub), { name: "ECDH", namedCurve: "P-256" }, false, []) }, fresh.priv, 256);
  const base = await crypto.subtle.importKey("raw", bits, "HKDF", false, ["deriveBits"]);
  const key = new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: enc.encode([fresh.pub, old.pub].sort().join(".")), info: enc.encode("sibian-link-1 key") }, base, 256));
  const value = { greeting: "สวัสดี 🌏", n: [1, 2.5, null], nested: { ok: true } };
  const room = "0f".repeat(16);
  const say = (msg) => city.steady(() => box.seal(oldSide.key, msg));
  const sealed = await say(value);
  if (JSON.stringify(await box.unseal(await box.boxKeyRaw(key), sealed)) !== JSON.stringify(value)) throw new Error("recorded key does not open the city's box");
  write("link.json", {
    new_scalar: hex(newScalar), old_scalar: hex(oldScalar), new_public: fresh.pub, old_public: old.pub,
    code: `os:link:${room}.${fresh.pub}`, room, key: hex(key), check: newSide.check, value, sealed,
    sessions: [
      { note: "a recovery-key identity, with its history offered first",
        msgs: [{ t: "hi", pub: old.pub }, { t: "recs", i: 0, box: await say([ada.inception]) },
          { t: "key", box: await say({ key: await did.keyString(ada.key), name: "  Ada of the Garden  ", saved: true, heads: [], parts: 1 }) }],
        id: ada.id, did_key: ada.key.did, controller: null, name: "Ada of the Garden" },
      { note: "an identity that moved to did:webvh",
        msgs: [{ t: "hi", pub: old.pub }, { t: "key", box: await say({ v2: mo.bundle, name: "Mo", saved: true, heads: [], parts: 0 }) }],
        id: mo.id, did_key: mo.device.did, controller: mo.webvh, name: "Mo" },
      { note: "a name longer than the city shows",
        msgs: [{ t: "hi", pub: old.pub }, { t: "key", box: await say({ key: await did.keyString(ben.key), name: "x".repeat(39) + "😀yz", saved: false }) }],
        id: ben.id, did_key: ben.key.did, controller: null, name: "x".repeat(39) },
    ],
  });
}

/* ---------- sentence marks ---------- */
{
  const texts = ["", "a", "Good morning.", "สวัสดีตอนเช้า", "早上好，大家。", "😀", "a\u0301 vs \u00e1", " leading and trailing ", "x".repeat(2000), "Line one\nLine two\ttabbed"];
  write("marks.json", { marks: texts.map((text) => ({ text, mark: tape.textMark(text) })) });
}

/* ---------- the parts of a recording's audio ---------- */
/* One candidate `tape/part` at a time, signed with the city's library and put
   through the city's reader: `read` is the part as the reader hands it on
   (null when it drops the record), `served` whether the server serves that
   media type as itself, `stored` whether it stores a file of that size. */
{
  const rules = city.fileRules;
  const take = await record.make(ada.signer, ada.id, "tape/take", { mime: "", started: T0 }, { deps: [ada.id], links: [EVENT], at: T0 });
  const good = { n: 0, file: "5a".repeat(32), size: 2_400_000, t0: 0, dur: 300_000, mime: "audio/mp4", lv: "0123456789" };
  const bodies = [
    good,
    { ...good, n: 7, t0: 2_100_000, dur: 12_345 },
    { ...good, lv: "" },
    { ...good, lv: "9".repeat(rules.levelsMax) },
    { ...good, lv: "9".repeat(rules.levelsMax + 1) },
    { ...good, lv: "12a4" },
    { ...good, lv: "1 2" },
    { ...good, lv: "１２" },
    { ...good, mime: "audio/webm;codecs=opus" },
    { ...good, mime: "audio/ogg; codecs=opus" },
    { ...good, mime: "audio/x-m4a" },
    { ...good, mime: "audio/mp4;" },
    { ...good, mime: "audio/wav" },
    { ...good, mime: "audio/mp4a" },
    { ...good, mime: "Audio/MP4" },
    { ...good, mime: "video/mp4" },
    { ...good, mime: "audio/mp4;codecs=\"mp4a.40.2\"" },
    { ...good, mime: "audio/mp4;a=1;b=2" },
    { ...good, mime: "audio/mp4;" + "a".repeat(rules.mimeMax - "audio/mp4;".length) },
    { ...good, mime: "audio/mp4;" + "a".repeat(rules.mimeMax) },
    { ...good, mime: "" },
    { ...good, file: "5A".repeat(32) },
    { ...good, file: "5a".repeat(31) },
    { ...good, file: "5a".repeat(32) + "0" },
    { ...good, file: "5g".repeat(32) },
    { ...good, t0: -1 },
    { ...good, dur: -1 },
    { ...good, dur: 0 },
    { ...good, dur: 1 },
    { ...good, size: 0 },
    { ...good, size: 1 },
    { ...good, size: rules.fileMax },
    { ...good, size: rules.fileMax + 1 },
  ];
  const cases = [];
  for (const body of bodies) {
    const part = await record.make(ada.signer, ada.id, "tape/part", body, { deps: [take.id], links: [take.id], at: T0 + 1000 });
    const w = await city.world([ada.inception, take.rec, part.rec]);
    const read = tape.tape(w.query, take.id).parts[0];
    cases.push({
      body,
      read: read ? { n: read.n, file: read.file, size: read.size, t0: read.t0, dur: read.dur, mime: read.mime, lv: read.lv } : null,
      served: rules.mime.test(body.mime),
      stored: body.size > 0 && body.size <= rules.fileMax,
    });
  }
  if (!cases[0].read || !cases[0].served || !cases[0].stored) throw new Error("the city does not keep a plain part");
  write("parts.json", { file_max: rules.fileMax, levels_max: rules.levelsMax, mime_max: rules.mimeMax, part_ms: tape.PART_MS, cases });
}

/* ---------- events ---------- */
/* Each person's records are chained the way a device chains them: the first
   depends on the identity number, each later one on the one before. */
const chain = (p, signer = p.signer) => {
  let dep = p.id;
  return async (type, body, links, at, opts = {}) => {
    const x = await record.make(signer, p.id, type, body, { deps: opts.deps ?? [dep], links, at });
    if (!opts.detached) dep = x.id;
    return x;
  };
};
{
  const recs = [ada, ben, cai, dov, mo, eve].map((p) => p.inception);
  const put = (x) => { recs.push(x.rec); return x; };
  const A = chain(ada), B = chain(ben), C = chain(cai), D = chain(dov), M = chain(mo), M0 = chain(mo, mo.signer0 = { did: mo.key.did, privateKey: mo.key.privateKey }), G = chain(gus);
  const CITY = fen.id.replace(/./g, "c").slice(0, 64);   // a city number nobody here holds the records of
  const start = T0 + DAY;

  /* A hosted event that changes hands. */
  const e1 = put(await A("ev/event", { title: "Morning circle", about: "Bring a cup.", place: "Garden", start, end: start + 2 * HOUR, tz: "Asia/Bangkok", scope: "public", polis: CITY, crew: [cai.id], mods: [ben.id] }, [], T0));
  put(await A("ev/edit", { title: "Morning circle (moved)", place: "Library", start: start + HOUR }, [e1.id], T0 + 1000));
  put(await D("ev/edit", { title: "Not the host" }, [e1.id], T0 + 2000));
  put(await B("ev/edit", { place: "Rooftop" }, [e1.id], T0 + 3000));
  /* Two hosts change the same field in the same millisecond: the record with the smaller name is applied first. */
  put(await A("ev/edit", { about: "tie", place: "Tie · host" }, [e1.id], T0 + 4000));
  put(await B("ev/edit", { place: "Tie · co-host" }, [e1.id], T0 + 4000));
  put(await A("ev/hosts", { hosts: [cai.id, "not-a-person", cai.id] }, [e1.id], T0 + 5000));
  put(await B("ev/edit", { title: "Signed after leaving the host list" }, [e1.id], T0 + 6000));
  put(await C("ev/edit", { crew: [ben.id, cai.id, "zz", ben.id], tz: "not a zone!", end: null }, [e1.id], T0 + 7000));
  put(await B("ev/hosts", { hosts: [ben.id] }, [e1.id], T0 + 8000));
  /* Someone else's key under the host's name: the signature is good, the authorship is not. */
  put(await record.make(eve.signer, ada.id, "ev/edit", { title: "Forged under the host's name", crew: [eve.id] }, { deps: [ada.id], links: [e1.id], at: T0 + 9000 }));
  /* A record with no dependencies is refused by every browser. */
  put(await A("ev/edit", { title: "Signed without dependencies" }, [e1.id], T0 + 9500, { deps: [], detached: true }));

  /* An event by someone who moved to did:webvh. */
  recs.push(mo.didRec);
  const e2 = put(await M("ev/event", { title: "Signed after moving", start: start + DAY, tz: "UTC", scope: "link" }, [], T0 + 10));
  put(await M("ev/edit", { place: "Workshop", end: start + DAY + HOUR }, [e2.id], T0 + 1010));
  put(await M0("ev/edit", { title: "Signed after moving, with the first key" }, [e2.id], T0 + 2010));
  put(await record.make(eve.signer, mo.id, "ev/edit", { title: "Forged under the moved person's name" }, { deps: [mo.id], links: [e2.id], at: T0 + 3010 }));
  /* The real log, carried by a record a stranger signed in the person's name: it proves nothing. */
  put(await record.make(eve.signer, mo.id, "id/did", { log: mo.log, witness: [] }, { deps: [mo.id], at: T0 + 3020 }));

  /* A log for the person's account that is rooted in a stranger's key. It verifies as a log; it is not theirs. */
  {
    const host = "city.example", now = T0 - 20 * DAY;
    const rooted = await city.didwebvh.migrateLog(await city.didwebvh.createLog(eve.signer, mo.account, host), { S: eve.seed, k0: eve.key, account: mo.account, host, now });
    const device = await city.keyroot.signKeyOf(eve.seed, 1), signer = { did: device.did, privateKey: device.privateKey };
    put(await record.make(signer, mo.id, "id/did", { log: rooted, witness: [] }, { deps: [mo.id], at: T0 + 3030 }));
    put(await record.make(signer, mo.id, "ev/edit", { title: "Forged with a log of the forger's own" }, { deps: [mo.id], links: [e2.id], at: T0 + 3040 }));
    /* The person's real log with the stranger's key written into its last entry. */
    const tampered = JSON.parse(JSON.stringify(mo.log)), last = tampered[tampered.length - 1].state, mk = eve.key.did.slice(8);
    last.verificationMethod.push({ id: `${last.id}#${mk}`, type: "Multikey", controller: last.id, publicKeyMultibase: mk });
    last.assertionMethod.push(`${last.id}#${mk}`);
    put(await record.make(eve.signer, mo.id, "id/did", { log: tampered, witness: [] }, { deps: [mo.id], at: T0 + 3050 }));
    put(await record.make(eve.signer, mo.id, "ev/edit", { title: "Forged with a tampered log" }, { deps: [mo.id], links: [e2.id], at: T0 + 3060 }));
  }

  /* Cancelled, removed, and never visible. */
  const e3 = put(await A("ev/event", { title: "Evening walk", start: start + 2 * DAY, end: start + 2 * DAY - 1, tz: "Europe/Lisbon", polis: CITY, scope: "polis" }, [], T0 + 20));
  put(await A("ev/state", { to: "cancelled" }, [e3.id], T0 + 1020));
  put(await D("ev/state", { to: "upcoming" }, [e3.id], T0 + 2020));
  const e4 = put(await A("ev/event", { title: "Created by mistake", start: start + 3 * DAY }, [], T0 + 30));
  put(await A("ev/state", { to: "removed" }, [e4.id], T0 + 1030));
  put(await A("ev/state", { to: "live" }, [e4.id], T0 + 2030));
  put(await G("ev/event", { title: "By someone whose inception is not here", start }, [], T0 + 40));

  /* Odd bodies, and a first host handing the list to someone else. */
  put(await A("ev/event", { title: 42, place: ["x"], start: "soon", end: start, scope: "everyone", polis: 9, crew: "all", mods: [cai.id, cai.id, "x"] }, [], T0 + 50));
  const e7 = put(await D("ev/event", { title: "Open mic", start: start + 4 * DAY, tz: "America/New_York" }, [], T0 + 60));
  put(await D("ev/hosts", { hosts: [ada.id] }, [e7.id], T0 + 1060));
  put(await A("ev/edit", { title: "Open mic, co-hosted" }, [e7.id], T0 + 2060));
  put(await A("ev/hosts", { hosts: [] }, [e7.id], T0 + 3060));
  put(await A("ev/state", { to: "ended" }, [e7.id], T0 + 4060));
  put(await A("ev/state", { to: "upcoming" }, [e7.id], T0 + 5060));

  const { query, report } = await city.world(recs);
  const events = [...ev.events(query, { cities: new Map() }).values()].map((e) => ({
    id: e.id, title: e.title, place: e.place, tz: e.tz, scope: e.scope, city: e.polis, by: e.host,
    start_ms: e.start, end_ms: ev.endOf(e), hosts: e.hosts, crew: e.crew, cancelled: e.state === "cancelled" }));
  if (events.length !== 5) throw new Error("expected five events, the city found " + events.length);
  write("calendar.json", { recs, events, kept: report.added.length });
}

/* ---------- channels ---------- */
{
  const F = chain(fen), A = chain(ada), B = chain(ben);
  const recs = [fen, ada, ben, eve].map((p) => p.inception);
  const put = (x) => { recs.push(x.rec); return x; };
  const town = put(await F("polis/found", { name: "Harbour Town" }, [], T0 - 60 * DAY));
  for (const [p, sign] of [[ada, A], [ben, B]]) {
    const join = put(await sign("polis/join", {}, [town.id], T0 - 50 * DAY));
    put(await F("polis/admit", {}, [town.id, join.id, p.id], T0 - 49 * DAY));
  }
  const c1 = put(await A("arc/channel", { title: "Field notes", about: "", status: "open", polis: town.id }, [], T0));
  put(await A("arc/edit", { title: "Field notes, second season" }, [c1.id], T0 + 1000));
  put(await B("arc/edit", { title: "Renamed by a visitor" }, [c1.id], T0 + 2000));
  put(await A("arc/edit", { status: "closed" }, [c1.id], T0 + 3000));
  put(await record.make(eve.signer, ada.id, "arc/edit", { title: "Forged under the owner's name" }, { deps: [ada.id], links: [c1.id], at: T0 + 4000 }));
  put(await B("arc/channel", { title: "Open mic recordings", status: "open", polis: town.id }, [], T0 + 10));
  put(await F("arc/channel", { title: "Best of the season", about: "", set: true, polis: town.id }, [], T0 + 20));
  const c4 = put(await A("arc/channel", { title: "Personal", status: "closed" }, [], T0 + 30));
  put(await A("arc/edit", { status: "open", title: 7 }, [c4.id], T0 + 1030));
  put(await B("arc/channel", { status: "something else" }, [], T0 + 40));
  const { query } = await city.world(recs);
  const cities = polis.cities(query);
  const channels = [...arc.archive(query, { cities, events: new Map() }).chans.values()].map((c) => ({ id: c.id, title: c.title, by: c.by, city: c.city || null, open: c.status === "open", set: c.kind === "set" }));
  if (channels.length !== 5) throw new Error("expected five channels, the city found " + channels.length);
  write("channels.json", { city: town.id, recs, channels });
}
