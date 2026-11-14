#!/usr/bin/env node
/* ZuTalk's own path, end to end, against the city's real server on this
   machine only.

   Where e2e.mjs drives the protocol crate, this drives the app's core the way
   the app does: it runs the ignored test
   `city_api::tests::files_a_recording_into_a_city_on_this_machine`, which
   signs in through the device-link relay (this script plays the device that
   is already signed in), reads the calendar, is turned away from an event it
   may not file to, files a recording under an imported event whose recorder a
   coordinator named, files again, is held back from sending audio while the
   recording is set to go without, then files the audio a part at a time,
   withdraws, and signs out. After each step the hub is read back and judged
   with the city's own reducers, and the audio is fetched from the server's
   file store.

   The recording carries a mark; nothing about it may reach the city. The
   audio is a tone made on the spot (audio.mjs; needs macOS's afconvert).

   The imported event is the case that matters most in practice: most of a
   real city's calendar is brought in from an outside calendar, and there the
   city treats its reviewers, not the importing key, as hosts.

     CITY_SRC=<city checkout> CITY_E2E_DIR=<empty scratch dir> node tools/city-interop/e2e-app.mjs

   No deployed city is contacted: every address used is on this machine. */
import { spawn } from "node:child_process";
import { createServer } from "node:net";
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
const chain = (p) => {
  let dep = p.id;
  return async (type, body, links, at) => { const x = await record.make(p.signer, p.id, type, body, { deps: [dep], links, at }); dep = x.id; return x; };
};

const port = await freePort(), origin = `http://127.0.0.1:${port}`, name = `city.localhost:${port}`;
const keep = join(scratch, `app-${Date.now()}-${port}`);
mkdirSync(keep, { recursive: true });
const NOW = Date.now(), DAY = 864e5, HOUR = 3600e3;
const founder = await city.person(seed(0x41)), recorder = await city.person(seed(0x42)), owner = await city.person(seed(0x43));
const sound = audio.parts(join(keep, "audio"));
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

/* ---- a city; its founder, who coordinates it; two residents ---- */
const F = chain(founder), R = chain(recorder), O = chain(owner);
const town = await F("polis/found", { name: "Harbour Town" }, [], NOW - 60 * DAY);
const cityTag = polis.tagOf ? polis.tagOf(town.id) : "polis:" + town.id.slice(0, 16);
await post(cityTag, [founder.inception, town.rec], "the founding");
writeFileSync(join(keep, "home.txt"), town.id + "\n");
for (const [p, sign] of [[recorder, R], [owner, O]]) {
  const joined = await sign("polis/join", {}, [town.id], NOW - 50 * DAY);
  await post(cityTag, [p.inception, joined.rec], "an application");
  await post(cityTag, [founder.inception, (await F("polis/admit", {}, [town.id, joined.id, p.id], NOW - 49 * DAY)).rec], "an admission");
}

/* ---- an imported event the coordinator names a recorder for; someone else's event; a channel ---- */
const imported = await F("ev/event", {
  title: "Language Exchange", place: "Event Space", start: NOW - HOUR, end: NOW + HOUR, tz: "Asia/Bangkok", scope: "public", polis: town.id,
  src: { from: "Outside Calendar", id: "lang-exchange-1", url: "https://calendar.example/lang-exchange-1", group: "Harbour Town", host: "A visiting teacher", seen: NOW - DAY },
}, [], NOW - DAY);
const importedTag = ev.tagOf(imported.id);
const named = await F("ev/edit", { crew: [recorder.id] }, [imported.id], NOW - 2 * HOUR);
await post(importedTag, [founder.inception, imported.rec, named.rec], "the imported event");
await post(cityTag, [founder.inception, imported.rec, named.rec], "the imported event");
const other = await O("ev/event", { title: "Evening walk", start: NOW - HOUR, end: NOW + HOUR, tz: "Asia/Bangkok", scope: "public", polis: town.id }, [], NOW - DAY);
const otherTag = ev.tagOf(other.id);
await post(otherTag, [owner.inception, other.rec], "someone else's event");
await post(cityTag, [owner.inception, other.rec], "someone else's event");
const channel = await O("arc/channel", { title: "Field notes", about: "", status: "open", polis: town.id }, [], NOW - DAY);
await post(cityTag, [owner.inception, channel.rec], "a channel");
/* An event the coordinator deleted. A recording filed under it would be placed nowhere, so ZuTalk must not offer it. */
const mistake = await F("ev/event", { title: "Created by mistake", start: NOW - HOUR, end: NOW + HOUR, tz: "Asia/Bangkok", scope: "public", polis: town.id }, [], NOW - DAY);
const deleted = await F("polis/trash", { on: true }, [town.id, mistake.id], NOW - 3 * HOUR);
await post(cityTag, [founder.inception, mistake.rec, deleted.rec], "an event and its deletion");

/* The city's own reading of that calendar: the recorder may put things in the imported event. */
{
  const w = await city.world(await read(cityTag));
  const cities = polis.cities(w.query), events = ev.events(w.query, { cities });
  ok(!!events.get(imported.id)?.src, "the city itself treats the event as imported");
  ok(ev.canPut(events.get(imported.id), recorder.id), "and its coordinator's choice of recorder stands");
  ok(!ev.canPut(events.get(other.id), recorder.id), "but the recorder has no place in the other event");
  ok(!ev.events(w.query, { cities }).has(mistake.id) || events.get(mistake.id)?.removed, "the city no longer lists the deleted event");
}

/* ---- ZuTalk's core does what the app does ---- */
const proceed = join(keep, "proceed");
const rust = spawn("cargo", ["test", "--quiet", "--manifest-path", join(repo, "Cargo.toml"), "-p", "vt-ffi", "--lib",
  "city_api::tests::files_a_recording_into_a_city_on_this_machine", "--", "--ignored", "--exact", "--nocapture"],
  { env: { ...process.env, ZUTALK_CITY_E2E_BASE: `http://${name}`, ZUTALK_CITY_RESOLVE: `city.localhost=127.0.0.1:${port}`, ZUTALK_CITY_E2E_PROCEED: proceed, ZUTALK_CITY_E2E_AUDIO: audio.asEnv(sound) }, stdio: ["ignore", "pipe", "pipe"] });
children.push(rust);
let rustErr = "";
rust.stderr.on("data", (d) => { rustErr += d; });
const steps = {};
let shared = null, room = "";
const say = async (msg) => { const r = await fetch(`${origin}/relay/${room}`, { method: "POST", body: JSON.stringify(msg) }); ok(r.ok, "the relay takes a message"); };

/* What the event's tag and the city's tag hold now, as the city's reducers see it. */
const judged = async () => {
  const onEvent = await read(importedTag), onCity = await read(cityTag);
  const w = await city.world([...onCity, ...onEvent]);
  const cities = polis.cities(w.query), events = ev.events(w.query, { cities });
  return { onEvent, onCity, w, cities, events, archive: arc.archive(w.query, { cities, events }) };
};

for await (const line of createInterface({ input: rust.stdout })) {
  if (!line.startsWith("E2E ")) continue;
  const s = JSON.parse(line.slice(4));
  steps[s.step] = s.value;
  if (s.step === "code") {
    const target = link.parseLink(s.value);
    same(target?.dir, "r", "the city's scanner reads ZuTalk's code");
    room = target.room;
    const mine = await link.answer();
    shared = await link.agree(mine.priv, mine.pub, target.pub);
    await say({ t: "hi", pub: mine.pub });
  } else if (s.step === "check") {
    same(s.value, shared.check, "both devices show the same digits");
    await say({ t: "recs", i: 0, box: await box.seal(shared.key, [recorder.inception]) });
    await say({ t: "key", box: await box.seal(shared.key, { key: await did.keyString(recorder.key), name: "Ada of the Garden", saved: true, heads: [], parts: 1 }) });
  } else if (s.step === "signed-in") {
    same([s.value.id, s.value.name, s.value.city, s.value.roles], [recorder.id, "Ada of the Garden", "Harbour Town", ["resident"]], "signed in as the recorder, a resident of the city");
  } else if (s.step === "calendar") {
    same([...s.value].sort((a, b) => a.title.localeCompare(b.title)), [{ title: "Evening walk", mine: false }, { title: "Language Exchange", mine: true }],
      "both events are on the calendar, the deleted one is not; the recorder the coordinator named sees the imported one as theirs");
  } else if (s.step === "channels") {
    same(s.value, ["Field notes"], "the open city channel is offered");
  } else if (s.step === "not-allowed") {
    same(s.value, { state: "Failed", error: "city.error.not_allowed" }, "filing under someone else's event is turned down before anything is sent");
    const there = await read(otherTag);
    ok(!there.some((r) => r.e.by === recorder.id), "and nothing of the recorder's reached that event's tag");
  } else if (s.step === "filed") {
    same([s.value.state, s.value.error, s.value.channel, s.value.signer], ["Filed", null, "Field notes", "Ada of the Garden"], "filed under the imported event, into the topic's channel, as the recorder");
    same(s.value.tags, [importedTag, cityTag], "posted to the event's tag and the city's");
    same(s.value.url, `http://${name}/archive/c/${imported.id}/b/${s.value.block}`, "the link opens the item in the archive");
    const { onEvent, onCity, w, cities, events, archive } = await judged();
    ok(onEvent.some((r) => r.e.type === "tape/take" && r.e.by === recorder.id) && !onCity.some((r) => r.e.type.startsWith("tape/")), "the transcript is on the event tag only");
    ok(!onEvent.some((r) => r.e.type === "tape/part") && !onCity.some((r) => r.e.type === "tape/part"), "filing the text files no audio part by itself");
    ok(!onEvent.some((r) => r.e.type === "tape/mark") && !onCity.some((r) => r.e.type === "tape/mark"), "the recording's mark was not filed");
    same(onCity.filter((r) => r.e.type.startsWith("arc/") && r.e.by === recorder.id).map((r) => r.e.type).sort(), ["arc/block", "arc/connect", "arc/connect"], "the city tag has the item and its two placements");
    const tp = tape.tape(w.query, s.value.take, { event: (id) => events.get(id), cities });
    ok(!!tp && tp.segs.length > 0, "the city finds the take and its sentences");
    ok(tp.segs.every((x) => x.text.trim().length > 0), "every sentence has text");
    same(tp.marks, [], "the city has no highlight for the take");
    const filedLanguages = Object.fromEntries(s.value.languages);
    for (const lang of [...tp.langs.keys()]) {
      const lines = tape.trLines(tp, lang);
      ok(lines.some((x) => x.state === "ok"), `${lang}: the city reads translations as current`);
      ok(lines.every((x) => x.state !== "stale"), `${lang}: nothing stale`);
      ok(filedLanguages[lang] > 0, `${lang}: ZuTalk counted what it filed`);
    }
    ok(tp.langs.size > 0, "at least one translation language was filed");
    ok(tp.ended > 0 && tape.onAir(w.query, events.get(imported.id), Date.now()).length === 0, "the take is ended and nobody is on air");
    const block = archive.blocks.get(s.value.block);
    same([block?.kind, block?.take, block?.state], ["audio", s.value.take, "open"], "the archive item");
    same(block.in.map((x) => x.chan).sort(), [imported.id, channel.id].sort(), "placed in the event and in the channel");
    ok(arc.visible(archive, block, owner.id), "another resident sees it");
    steps.counts = { event: onEvent.length, city: onCity.length };
    writeFileSync(proceed, "go\n");
  } else if (s.step === "audio-withheld") {
    same(s.value, { wanted: false, error: "city.error.audio_withheld", upload: false, hold: "city.error.audio_withheld", pending: [] },
      "a recording set to go without audio: the core refuses to send any, and does not list it as pending");
    const { onEvent, onCity } = await judged();
    ok(![...onEvent, ...onCity].some((r) => r.e.type === "tape/part"), "and no part record reached the city");
    for (const p of sound) same((await audio.fetched(origin, p.file)).status, 404, `nor part ${p.n}'s file`);
    writeFileSync(proceed + ".withheld", "go\n");
  } else if (s.step === "audio-plan") {
    same(s.value, { upload: true, due: true, part_ms: tape.PART_MS, max: city.fileRules.fileMax, mime: "audio/mp4", filed: [] },
      "allowed again, the plan is the city's own: its part length, its size limit, a type it serves");
    ok(city.fileRules.mime.test(s.value.mime), "the server serves that type as itself");
  } else if (s.step === "audio") {
    same(s.value.parts, sound.map((_, n) => ({ state: "Filed", planned: sound.length, filed: n + 1, error: null })), "each part is filed in turn; the filing stays filed throughout");
    same([s.value.again, s.value.filed, s.value.pending], [sound.length, sound.map((p) => p.n), []], "filing a part again changes nothing; nothing is left pending");
    const { onEvent, onCity, w, cities, events } = await judged();
    const partRecs = onEvent.filter((r) => r.e.type === "tape/part");
    same(partRecs.length, sound.length, "one record per part on the event tag");
    ok(partRecs.every((r) => r.e.by === recorder.id && isDeepStrictEqual(r.e.links, [steps.filed.take])) && !onCity.some((r) => r.e.type === "tape/part"), "signed by the take's author, about the take, and not on the city tag");
    const tp = tape.tape(w.query, steps.filed.take, { event: (id) => events.get(id), cities });
    same(audio.read(tp), audio.signed(sound), "the city reads both parts as signed, in order");
    same(tp.dur, sound.reduce((n, p) => n + p.dur, 0), "and they add up to the audio's length");
    same([0, 2_999, 3_000, 4_200].map((ms) => { const at = tape.locate(tp, ms); return [at.part.file, at.at]; }),
      [[sound[0].file, 0], [sound[0].file, 2_999], [sound[1].file, 0], [sound[1].file, 1_200]], "a player finds any moment in its part");
    for (const p of sound) {
      const got = await audio.fetched(origin, p.file);
      same([got.status, got.type], [200, "audio/mp4"], `part ${p.n}: served as AAC in MPEG-4`);
      ok(got.bytes.equals(p.bytes), `part ${p.n}: the bytes served are the bytes the app exported`);
    }
    ok(tp.segs.length > 0 && tp.ended > 0 && tape.onAir(w.query, events.get(imported.id), Date.now()).length === 0, "the transcript is as it was and nobody is on air");
    same(onEvent.filter((r) => r.e.type === "tape/take" && r.e.by === recorder.id).length, 1, "posting the take again with each part added no second take");
    ok(!onEvent.some((r) => r.e.type === "tape/mark"), "still no mark");
    /* Bytes nobody claimed are refused, whoever sends them. */
    const stray = Buffer.from("bytes nobody claimed");
    const put = await fetch(`${origin}/files/${createHash("sha256").update(stray).digest("hex")}`, { method: "PUT", body: stray });
    same([put.status, String((await put.json().catch(() => ({}))).type || "").split("#")[1]], [403, "unclaimed"], "a PUT without a claim is refused as unclaimed");
    writeFileSync(proceed + ".audio", "go\n");
  } else if (s.step === "withdrawn") {
    same(s.value, { state: "Withdrawn", error: null }, "withdrawn");
    const { archive, onEvent } = await judged();
    const block = archive.blocks.get(steps.filed.block);
    ok(!block || block.state === "drop", "the item is gone from the archive");
    /* Withdrawing hides the item. What was filed stays: the transcript and
       the part records in the event's log, the audio in the file store. */
    same(onEvent.filter((r) => r.e.type === "tape/part").length, sound.length, "the part records are still in the event's log");
    ok(onEvent.some((r) => r.e.type === "tape/text" && r.e.by === recorder.id), "and so is the transcript");
    for (const p of sound) {
      const got = await audio.fetched(origin, p.file);
      ok(got.status === 200 && got.bytes.equals(p.bytes), `part ${p.n}'s audio is still served after the withdrawal`);
    }
  }
}
const code = await new Promise((done) => rust.exitCode !== null ? done(rust.exitCode) : rust.on("exit", done));
ok(code === 0, "the app's test ran to the end", rustErr.trim().split("\n").slice(-30).join("\n"));
for (const step of ["code", "check", "signed-in", "calendar", "channels", "not-allowed", "filed", "audio-withheld", "audio-plan", "audio", "withdrawn", "signed-out"]) ok(step in steps, `reached: ${step}`);

stop();
console.log(`\n✓ ${checks} checks: ZuTalk's core against a city server on this machine`);
