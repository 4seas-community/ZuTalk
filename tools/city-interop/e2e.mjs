#!/usr/bin/env node
/* End to end against the city's real server, on this machine only.

   Starts the server from a checkout (local-city.py: bound to 127.0.0.1, all
   state under CITY_E2E_DIR), founds a city and admits residents with the
   city's own libraries, then lets the Rust example `link_publish` do what
   ZuTalk will do — sign in through the device-link relay while this script
   plays the device that is already signed in, find the city and the event,
   publish a recording, correct a sentence, add its audio a part at a time.
   Afterwards the hub is read back and judged with the city's reducers, and
   the audio is fetched from the server's file store the way a player would.

   The audio is a tone made on the spot (audio.mjs; needs macOS's afconvert).

     CITY_SRC=<city checkout> CITY_E2E_DIR=<empty scratch dir> node tools/city-interop/e2e.mjs

   No deployed city is contacted: every address used is on this machine. */
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { request } from "node:http";
import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import * as city from "./city.mjs";
import * as audio from "./audio.mjs";

const { record, tape, ev, arc, polis, link, box, did, seed } = city;
const here = dirname(fileURLToPath(import.meta.url)), repo = join(here, "..", "..");
const scratch = process.env.CITY_E2E_DIR;
if (!scratch) { console.error("Set CITY_E2E_DIR to a scratch directory for the server's state."); process.exit(2); }

let checks = 0;
const children = [];
const stop = () => { for (const c of children) c.kill(); };
const fail = (what, extra = "") => { console.error("✗ " + what + (extra ? "\n  " + extra : "")); stop(); process.exit(1); };
const ok = (cond, what, extra) => { checks++; if (!cond) fail(what, extra); };
const same = (a, b, what) => { checks++; if (!isDeepStrictEqual(a, b)) fail(what, "got:  " + JSON.stringify(a) + "\n  want: " + JSON.stringify(b)); };

const freePort = () => new Promise((done) => { const s = createServer(); s.listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => done(port)); }); });
const sound = audio.parts(join(scratch, `audio-${Date.now()}`));
const chain = (p, signer = p.signer) => {
  let dep = p.id;
  return async (type, body, links, at) => { const x = await record.make(signer, p.id, type, body, { deps: [dep], links, at }); dep = x.id; return x; };
};

async function scenario(label, makeHost) {
  console.log(`\n${label}`);
  const port = await freePort(), origin = `http://127.0.0.1:${port}`, name = `city.localhost:${port}`;
  const keep = join(scratch, `run-${Date.now()}-${port}`);
  mkdirSync(keep, { recursive: true });
  const NOW = Date.now(), DAY = 864e5;
  const founder = await city.person(seed(0x31)), owner = await city.person(seed(0x22)), forger = await city.person(seed(0x26));
  const host = await makeHost(NOW);
  /* Who may found a city here, and the server's own name (it opens the city's DID under it). */
  writeFileSync(join(keep, "founders.txt"), founder.id.slice(0, 16) + "\n");
  writeFileSync(join(keep, "base.txt"), name + "\n");

  const server = spawn("python3", ["-B", join(here, "local-city.py"), keep, String(port)], { env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" }, stdio: ["ignore", "pipe", "pipe"] });
  children.push(server);
  let serverLog = "";
  server.stderr.on("data", (d) => { serverLog += d; });
  await new Promise((ready, no) => {
    createInterface({ input: server.stdout }).on("line", (line) => { if (line === "ready") ready(); });
    server.on("exit", (code) => no(new Error("the city server did not start (exit " + code + ")\n" + serverLog)));
  }).catch((e) => fail(e.message));

  const hub = (tag) => `${origin}/hub/${encodeURIComponent(tag)}`;
  const post = async (tag, recs, what) => {
    const r = await fetch(hub(tag), { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(recs) });
    const j = await r.json().catch(() => ({}));
    ok(r.ok && !(j.refused || []).length, `the server keeps ${what} on ${tag.split(":")[0]}:`, `HTTP ${r.status} ${JSON.stringify(j)}`);
    return j;
  };
  const read = async (tag) => {
    const out = [];
    for (let since = 0; ;) {
      const j = await (await fetch(`${hub(tag)}?since=${since}&wait=0`)).json();
      out.push(...j.recs);
      if (!j.more) return out;
      since = j.n;
    }
  };

  /* ---- a city, two residents, two events, a channel ---- */
  const F = chain(founder), H = chain(host), O = chain(owner);
  const cardOf = (p) => [p.inception, ...(p.didRec ? [p.didRec] : [])];
  const town = await F("polis/found", { name: "Harbour Town" }, [], NOW - 60 * DAY);
  const cityTag = polis.tagOf ? polis.tagOf(town.id) : "polis:" + town.id.slice(0, 16);
  await post(cityTag, [founder.inception, town.rec], "the founding");
  writeFileSync(join(keep, "home.txt"), town.id + "\n");
  for (const [p, sign] of [[host, H], [owner, O]]) {
    const join = await sign("polis/join", {}, [town.id], NOW - 50 * DAY);
    await post(cityTag, [...cardOf(p), join.rec], "an application");
    await post(cityTag, [founder.inception, (await F("polis/admit", {}, [town.id, join.id, p.id], NOW - 49 * DAY)).rec], "an admission");
  }
  const event = await H("ev/event", { title: "Morning circle", start: NOW - 2 * 3600e3, end: NOW - 3600e3, tz: "Asia/Bangkok", scope: "public", polis: town.id }, [], NOW - DAY);
  const evTag = ev.tagOf(event.id);
  await post(evTag, [...cardOf(host), event.rec], "the event");
  await post(cityTag, [...cardOf(host), event.rec], "the event");
  const other = await O("ev/event", { title: "Evening walk", start: NOW + DAY, tz: "Asia/Bangkok", scope: "public", polis: town.id }, [], NOW - DAY);
  await post(cityTag, [owner.inception, other.rec], "someone else's event");
  const channel = await O("arc/channel", { title: "Field notes", about: "", status: "open", polis: town.id }, [], NOW - DAY);
  await post(cityTag, [owner.inception, channel.rec], "a channel");
  /* The event's tag keeps anything with a valid signature, including a
     rename signed by a stranger under the host's name. */
  const forged = await record.make(forger.signer, host.id, "ev/edit", { title: "Renamed by a stranger" }, { deps: [host.id], links: [event.id], at: NOW - 1000 });
  const kept = await post(evTag, [forger.inception, forged.rec], "even a forged edit");
  ok(kept.took >= 1, "the event tag stored the forged edit (it checks signatures only)");

  /* ---- vt-city signs in, finds its way, publishes ---- */
  const rust = spawn("cargo", ["run", "--quiet", "--manifest-path", join(repo, "Cargo.toml"), "-p", "vt-city", "--example", "link_publish"],
    { env: { ...process.env, CITY_BASE: `http://${name}`, CITY_RESOLVE: `city.localhost=127.0.0.1:${port}`, CITY_EVENT: "Morning circle", CITY_AUDIO: audio.asEnv(sound) }, stdio: ["ignore", "pipe", "pipe"] });
  children.push(rust);
  let rustErr = "";
  rust.stderr.on("data", (d) => { rustErr += d; });
  const steps = {};
  let shared = null, room = "";
  const say = async (msg) => { const r = await fetch(`${origin}/relay/${room}`, { method: "POST", body: JSON.stringify(msg) }); ok(r.ok, "the relay takes a message"); };
  for await (const line of createInterface({ input: rust.stdout })) {
    const s = JSON.parse(line);
    steps[s.step] = s;
    if (s.step === "code") {
      /* The device that is already signed in: scan the code, answer with a key of its own. */
      const target = link.parseLink(s.code);
      same(target?.dir, "r", "the city's scanner reads the code");
      room = target.room;
      const mine = await link.answer();
      shared = await link.agree(mine.priv, mine.pub, target.pub);
      await say({ t: "hi", pub: mine.pub });
    } else if (s.step === "check") {
      same(s.digits, shared.check, "both devices show the same digits");
      /* The person agrees; the old device hands over its records and then the identity. */
      await say({ t: "recs", i: 0, box: await box.seal(shared.key, [host.inception]) });
      const keyPart = host.bundle ? { v2: host.bundle } : { key: await did.keyString(host.key) };
      await say({ t: "key", box: await box.seal(shared.key, { ...keyPart, name: "Ada of the Garden", saved: true, heads: [], parts: 1 }) });
    }
  }
  const code = await new Promise((done) => rust.exitCode !== null ? done(rust.exitCode) : rust.on("exit", done));
  ok(code === 0, "the example ran to the end", rustErr.trim());

  same([steps["signed-in"].id, steps["signed-in"].name, steps["signed-in"].controller], [host.id, "Ada of the Garden", host.webvh ?? null], "signed in as the host");
  const found = steps.found;
  same([found.city, found.city_name, found.members], [town.id, "Harbour Town", 3], "the door leads to the city");
  same(found.roles, ["resident"], "the city vouches for a resident");
  same([...found.events].sort(), ["Evening walk", "Morning circle"], "both events are on the calendar");
  same(found.event, event.id, "the host's event is the one chosen");
  ok(found.same_from_event_tag, "the event tag tells the same story, forged rename ignored");
  same(found.may_put, [channel.id], "the open city channel may be added to");
  const pub = steps.published;
  same(pub.posted.map((p) => p.tag), [evTag, cityTag], "posted to the event's tag and the city's");
  ok(pub.posted.every((p) => p.refused.length === 0), "nothing was refused", JSON.stringify(pub.posted));
  same(pub.posted.map((p) => p.took), [pub.records - 1, 3], "the event tag took all but the placement elsewhere; the city tag the item and its two placements");
  same([pub.again.took, pub.again.refused], [0, []], "posting again is a no-op");
  same(pub.card, host.didRec ? ["id/inception", "id/did"] : ["id/inception"], "the card carries what readers need");
  same([steps.corrected.posted.took, steps.corrected.posted.refused], [3, []], "the correction and two translations were kept");

  /* The wire form of the role credentials, for the record: the founder, who is also a coordinator, holds three. */
  {
    const body = await new Promise((done, no) => request({ host: "127.0.0.1", port, path: `/p/${town.id.slice(0, 16)}/vc?id=${founder.id}`, headers: { host: name } }, (res) => {
      let text = ""; res.on("data", (d) => { text += d; }); res.on("end", () => done(text));
    }).on("error", no).end());
    const creds = JSON.parse(body).credentials;
    same(creds.map((c) => c.credentialSubject.role), ["resident", "founder", "steward"], "the city's credentials call a coordinator a steward");
    ok(creds.every((c) => c.credentialSubject.city.polis === town.id && c.type.includes("SibianCityRole") && c.proof?.cryptosuite === "eddsa-jcs-2022"), "each credential names the city in full and is signed by it");
  }

  /* ---- what the server now holds, judged by the city's reducers ---- */
  const onEvent = await read(evTag), onCity = await read(cityTag), want = steps.corrected.expected;
  ok(onEvent.some((r) => r.e.type === "tape/take") && !onCity.some((r) => r.e.type.startsWith("tape/")), "the transcript is on the event tag only");
  same(onCity.filter((r) => r.e.type.startsWith("arc/") && r.e.by === host.id).map((r) => r.e.type).sort(), ["arc/block", "arc/connect", "arc/connect"], "the city tag has the item and its placements");
  const w = await city.world([...onCity, ...onEvent]);
  const cities = polis.cities(w.query), events = ev.events(w.query, { cities });
  same(events.get(event.id)?.title, "Morning circle", "a browser, too, ignores the forged rename");
  const tp = tape.tape(w.query, pub.take, { event: (id) => events.get(id), cities });
  ok(!!tp, "the city finds the take");
  const fixed = want.sentences.map((s) => (s.t === want.fixed.t ? { ...s, text: want.fixed.text } : s));
  same(tp.segs.map(({ t, d, sp, text }) => ({ t, d, sp, text })), fixed, "sentences, the corrected one corrected");
  same(Object.fromEntries(tp.names), want.names, "speaker names");
  ok(tp.marks.length === 0 && !onEvent.some((r) => r.e.type === "tape/mark"), "no highlight was filed");
  for (const [lang, lines] of Object.entries(want.languages)) {
    const expect = { ...lines, ...(want.fixed[lang] ? { [want.fixed.t]: want.fixed[lang] } : {}) };
    const got = tape.trLines(tp, lang);
    /* English was not redone for the corrected sentence, and never had a line for it. */
    same(Object.fromEntries(got.filter((s) => s.state === "ok").map((s) => [s.t, s.tr])), expect, `${lang}: translations current`);
    ok(got.every((s) => s.state !== "stale"), `${lang}: nothing stale`);
  }
  ok(tp.ended > 0 && tape.onAir(w.query, events.get(event.id), Date.now()).length === 0, "the take is ended and nobody is on air");
  const a = arc.archive(w.query, { cities, events }), block = a.blocks.get(pub.block);
  same([block?.kind, block?.take, block?.dur, block?.title, block?.state], ["audio", pub.take, want.duration_ms, want.title, "open"], "the archive item");
  same(block.in.map((x) => x.chan).sort(), [event.id, channel.id].sort(), "placed in the event and in the channel");
  ok(arc.visible(a, block, owner.id), "another resident sees it");

  /* ---- the audio: claimed on the event's tag, then stored, then served ---- */
  {
    const sent = steps.audio;
    same(sent.unclaimed, "Err(Unclaimed)", "bytes no record claims are turned away");
    same(sent.parts.map((p) => [p.n, p.file]), sound.map((p) => [p.n, p.file]), "each part is named by the SHA-256 of its bytes");
    for (const p of sent.parts) {
      same([p.before, p.early], [false, "Err(Unclaimed)"], `part ${p.n}: the file is refused before its record is on the event's tag`);
      same([p.posted.took, p.posted.refused], [1, []], `part ${p.n}: the tag keeps the part's record (the take it already had)`);
      same([p.after, p.again], [true, "Ok(())"], `part ${p.n}: stored once the record is there; sending it again changes nothing`);
    }
    ok(onEvent.filter((r) => r.e.type === "tape/part").every((r) => r.e.by === host.id) && !onCity.some((r) => r.e.type === "tape/part"), "the parts are on the event tag only, signed by the take's author");
    same(audio.read(tp), audio.signed(sound), "the city reads both parts as signed, in order");
    same(tp.dur, sound.reduce((n, p) => n + p.dur, 0), "and they add up to the audio's length");
    same([0, 2_999, 3_000, 4_200].map((ms) => { const at = tape.locate(tp, ms); return [at.part.file, at.at]; }),
      [[sound[0].file, 0], [sound[0].file, 2_999], [sound[1].file, 0], [sound[1].file, 1_200]], "a player finds any moment in its part");
    for (const p of sound) {
      const whole = await audio.fetched(origin, p.file);
      same([whole.status, whole.type], [200, "audio/mp4"], `part ${p.n}: served as AAC in MPEG-4`);
      ok(whole.bytes.equals(p.bytes), `part ${p.n}: the bytes served are the bytes uploaded`);
      ok(whole.cache.includes("immutable"), `part ${p.n}: served to be cached for good`);
      const first = await audio.fetched(origin, p.file, { range: "bytes=0-0" });
      same([first.status, first.range, first.bytes.length], [206, `bytes 0-0/${p.size}`, 1], `part ${p.n}: a player can ask for a range`);
    }
    /* Anyone can ask; nobody but the take's author, with a record, can add. */
    const stray = Buffer.from("more bytes nobody claimed");
    const put = await fetch(`${origin}/files/${createHash("sha256").update(stray).digest("hex")}`, { method: "PUT", body: stray });
    const why = await put.json().catch(() => ({}));
    same([put.status, String(why.type || "").split("#")[1]], [403, "unclaimed"], "a PUT without a claim is refused as unclaimed");
    /* The same bytes as a part, claimed by someone else's record under the host's take: not a claim. */
    const squatter = await record.make(forger.signer, forger.id, "tape/part", { n: 9, file: createHash("sha256").update(stray).digest("hex"), size: stray.length, t0: 0, dur: 1000, mime: "audio/mp4", lv: "" }, { deps: [forger.id], links: [pub.take], at: NOW });
    await post(evTag, [forger.inception, squatter.rec], "a stranger's part record (the tag checks signatures only)");
    const squat = await fetch(`${origin}/files/${squatter.rec.e.body.file}`, { method: "PUT", body: stray });
    same(squat.status, 403, "a part signed by someone other than the take's author claims nothing");
    same((await audio.fetched(origin, squatter.rec.e.body.file)).status, 404, "and nothing was stored for it");
  }
  server.kill();
}

await scenario("a resident who signs with a recovery key", () => city.person(seed(0x21)));
if (process.argv.includes("--moved")) await scenario("a resident who moved to did:webvh", (now) => city.migrated(seed(0x25), { now: now - 30 * 864e5 }));
stop();
console.log(`\n✓ ${checks} checks against a city server on this machine`);
