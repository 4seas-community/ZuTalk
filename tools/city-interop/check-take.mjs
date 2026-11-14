#!/usr/bin/env node
/* Runs the city's own code over what vt-city signs for a recording.

   A small city is assembled in memory with the city's libraries (a founder,
   two residents, an event one of them hosts, an open channel the other
   owns). The Rust example `emit_take` then signs the sample recording as the
   host — once holding a recovery key, once as someone who moved to
   did:webvh — and every record it prints is put through the city's
   verifier, its fact set, its recording reducer and its archive reducer.
   That includes the records for the parts of the recording's audio; the
   limits vt-city holds itself to are compared with the ones the city's
   source states.

     CITY_SRC=<city checkout> node tools/city-interop/check-take.mjs

   Nothing leaves this machine. Exits non-zero on the first disagreement. */
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import * as city from "./city.mjs";

const { record, tape, ev, arc, polis, link, box, did, hex, seed } = city;
const repo = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const NOW = 1_794_528_000_000, DAY = 864e5;

let checks = 0;
const ok = (cond, what) => { checks++; if (!cond) { console.error("✗ " + what); process.exit(1); } };
const same = (a, b, what) => { checks++; if (!isDeepStrictEqual(a, b)) { console.error("✗ " + what + "\n  city: " + JSON.stringify(a) + "\n  want: " + JSON.stringify(b)); process.exit(1); } };

function emit(ask) {
  const r = spawnSync("cargo", ["run", "--quiet", "--manifest-path", join(repo, "Cargo.toml"), "-p", "vt-city", "--example", "emit_take"],
    { input: JSON.stringify(ask), encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) { console.error(r.stderr); process.exit(1); }
  return JSON.parse(r.stdout);
}

const chain = (p, signer = p.signer) => {
  let dep = p.id;
  return async (type, body, links, at) => { const x = await record.make(signer, p.id, type, body, { deps: [dep], links, at }); dep = x.id; return x; };
};

async function scenario(host, label) {
  console.log(`\n${label}`);
  const founder = await city.person(seed(0x31)), owner = await city.person(seed(0x22)), reader = await city.person(seed(0x24));
  const F = chain(founder), H = chain(host), O = chain(owner);
  const base = [founder.inception, host.inception, owner.inception, ...(host.didRec ? [host.didRec] : [])];
  const put = (x) => { base.push(x.rec); return x; };
  const town = put(await F("polis/found", { name: "Harbour Town" }, [], NOW - 60 * DAY));
  for (const [p, sign] of [[host, H], [owner, O]]) {
    const join = put(await sign("polis/join", {}, [town.id], NOW - 50 * DAY));
    put(await F("polis/admit", {}, [town.id, join.id, p.id], NOW - 49 * DAY));
  }
  const event = put(await H("ev/event", { title: "Morning circle", start: NOW - 2 * 3600e3, end: NOW - 3600e3, tz: "Asia/Bangkok", scope: "public", polis: town.id }, [], NOW - DAY));
  const channel = put(await O("arc/channel", { title: "Field notes", about: "", status: "open", polis: town.id }, [], NOW - DAY));

  /* The link exchange with fixed keys on both sides: this side plays the
     device that is already signed in. */
  const rustScalar = seed(0x41), old = await city.linkKey(seed(0x42)), rustPub = (await city.linkKey(rustScalar)).pub;
  const out = emit({ ...(host.bundle ? { bundle: host.bundle } : { key: await did.keyString(host.key) }), event_id: event.id, channel_ids: [channel.id],
    now_ms: NOW, started_ms: NOW - 2 * 3600e3, link: { scalar: hex(rustScalar), peer: old.pub } });
  const want = out.expected;

  same(out.id, host.id, "the identity is the host's");
  same(out.inception, host.inception, "the inception is the city's own, byte for byte");
  same(out.controller, host.webvh ?? null, "the controller is the person's did:webvh, when they have one");
  const shared = await link.agree(old.priv, old.pub, rustPub);
  same(shared.check, out.sealed.check, "both sides show the same check digits");
  same(await box.unseal(shared.key, out.sealed.box), want, "the city opens a box sealed by vt-city");

  for (const [name, list] of Object.entries({ records: out.records, fix: out.fix, retranslate: out.retranslate, withdraw: out.withdraw }))
    for (const [i, rec] of list.entries()) same(await record.intrinsic(rec), "ok", `${name}[${i}] (${rec.e.type}) passes the city's verifier`);
  if (host.webvh) ok(out.records.every((r) => r.proof[0].verificationMethod.startsWith(host.webvh + "#") && r.e.key === host.device.did), "records name the did:webvh controller and the device key");

  /* The fact set keeps every record: authorship holds and nothing waits. */
  const merged = async (extra) => {
    const w = await city.world([...base, ...extra]);
    for (const rec of extra) ok(w.facts.has(await record.idOf(rec)), `the fact set keeps ${rec.e.type}`);
    const cities = polis.cities(w.query), events = ev.events(w.query, { cities });
    const tp = tape.tape(w.query, out.take_id, { event: (id) => events.get(id), cities });
    return { ...w, cities, events, tp, archive: arc.archive(w.query, { cities, events }) };
  };

  /* ---- the recording as published ---- */
  let w = await merged(out.records);
  const tp = w.tp;
  ok(!!tp, "the city finds the take");
  same([tp.by, tp.event, tp.started], [host.id, event.id, NOW - 2 * 3600e3], "the take is the host's, of this event, started when said");
  same(tp.segs.map(({ t, d, sp, text }) => ({ t, d, sp, text })), want.sentences, "sentences");
  same(Object.fromEntries(tp.names), want.names, "speaker names");
  same(tp.segs.map((s) => tape.speaker(tp, s.sp)), want.sentences.map((s) => want.names[s.sp]), "each sentence shows its speaker's name");
  ok(tp.marks.length === 0 && ![...out.records, ...out.fix, ...out.retranslate, ...out.withdraw, ...out.parts].some((r) => r.e.type === "tape/mark"), "no highlight is signed: where someone marked a recording is not filed");
  same([...tp.langs.keys()].sort(), Object.keys(want.languages).sort(), "languages");
  for (const [lang, lines] of Object.entries(want.languages)) {
    const got = tape.trLines(tp, lang);
    same(Object.fromEntries(got.filter((s) => s.state === "ok").map((s) => [s.t, s.tr])), lines, `${lang}: every translation is current`);
    ok(got.every((s) => s.state === (String(s.t) in lines ? "ok" : "none")), `${lang}: untranslated sentences are marked so, none stale`);
  }
  ok(tp.ended > 0, "the take is ended");
  same(tape.onAir(w.query, w.events.get(event.id), NOW + 1000), [], "nobody is shown as still recording");
  /* What a take without audio comes to. */
  same([tp.parts.length, tp.dur, tape.bars(tp).length, tape.gaps(tp).length, tape.locate(tp, 0)], [0, 0, 0, 0, null], "no audio: no parts, no length of its own, no waveform, nothing to fill, nowhere to seek");

  /* ---- the audio: one record per part, on the take ---- */
  {
    const rules = city.fileRules, lim = out.limits;
    same([lim.file_max, lim.part_ms, lim.upload_bytes_per_sec, lim.upload_grace_secs, lim.levels_max, lim.mime_max],
      [rules.fileMax, tape.PART_MS, rules.uploadBytesPerSec, rules.uploadGraceSecs, rules.levelsMax, rules.mimeMax],
      "file size, part length, upload allowance and what readers keep are the city's own numbers");
    ok(rules.mime.test(lim.mime), "the server serves the type vt-city signs as itself");
    for (const [i, rec] of [...out.parts, out.part_again].entries()) same(await record.intrinsic(rec), "ok", `part record ${i} passes the city's verifier`);
    ok([...out.parts, out.part_again].every((r) => r.e.type === "tape/part" && r.e.by === host.id && isDeepStrictEqual(r.e.links, [out.take_id]) && isDeepStrictEqual(r.e.deps, [out.take_id])),
      "each part is the take author's, about the take, and stands on the take alone");
    const read = (t) => t.parts.map(({ n, file, size, t0, dur, mime, lv }) => ({ n, file, size, t0, dur, mime, lv }));
    const heard = await merged([...out.records, ...out.parts]);
    same(read(heard.tp), want.parts, "the city reads both parts as signed, in order");
    same(read((await merged([...out.records, ...[...out.parts].reverse()])).tp), want.parts, "whichever part arrives first");
    same(heard.tp.dur, want.duration_ms, "the parts add up to the length of the recording");
    same([0, 19_999, 20_000, 25_500, 99_000].map((ms) => { const at = tape.locate(heard.tp, ms); return [at.part.n, at.at]; }),
      [[0, 0], [0, 19_999], [1, 0], [1, 5_500], [1, 10_000]], "any moment is found in its part; past the end is the end of the last");
    same(tape.bars(heard.tp, 30).map((v) => Math.round(v * 9)).join(""), want.parts.map((p) => p.lv).join(""), "the waveform is the loudness as signed");
    same(tape.gaps(heard.tp).length, 0, "the transcript covers the audio: nothing for the city to transcribe again");
    same(heard.archive.blocks.get(out.block_id)?.take, out.take_id, "the archive item plays that take");
    /* A part exported a second time, its first file never having arrived:
       the city keeps the first record it meets for a part number, and it
       meets the earlier-dated one first. */
    const again = await merged([...out.records, ...out.parts, out.part_again]);
    same(read(again.tp), [want.parts[0], want.part_again], "of two records for one part the city plays the earlier-dated");
    ok(out.part_again.e.at < out.parts[1].e.at, "which is why a second export is dated before the first");
  }

  const block = w.archive.blocks.get(out.block_id);
  ok(!!block, "the city finds the archive item");
  same([block.kind, block.take, block.dur, block.title, block.state, block.private, block.by], ["audio", out.take_id, want.duration_ms, want.title, "open", false, host.id], "the archive item");
  same(block.in.map((x) => x.chan).sort(), [event.id, channel.id].sort(), "placed in the event and in the channel");
  ok(w.archive.chans.get(event.id).list.some((x) => x.block === out.block_id), "the event's channel lists it");
  ok(w.archive.chans.get(channel.id).list.some((x) => x.block === out.block_id), "the channel lists it");
  ok(arc.visible(w.archive, block, reader.id), "a stranger sees it");

  /* ---- which records go where ---- */
  same(out.for_city.map((r) => r.e.type), ["arc/block", "arc/connect", "arc/connect"], "the city tag gets the item and its placements");
  ok(out.for_event.every((r) => r.e.type !== "arc/connect" || r.e.links[0] === event.id) && out.for_event.length === out.records.length - 1, "the event tag gets all but the placement elsewhere");
  /* Only the city-tag records: the item is there, placed, with no transcript to show. */
  const cityOnly = await merged(out.for_city);
  ok(cityOnly.archive.blocks.get(out.block_id)?.in.length === 2 && !cityOnly.tp, "from the city tag alone the item is placed and the take is absent");

  /* ---- batches: each stands on its own in order ---- */
  ok(out.batches.length > 2, "the sample splits into several batches at a small limit");
  {
    const facts = new city.Facts();
    await facts.merge(base);
    for (const [i, part] of out.batches.entries()) {
      same(part[0], host.inception, `batch ${i} starts with the inception`);
      ok(JSON.stringify(part).length <= 4000 || part.length === 2, `batch ${i} fits the limit`);
      const report = await facts.merge(part);
      ok(report.rejected.length === 0 && report.bad.length === 0 && report.pending === 0, `batch ${i} is kept whole when it arrives`);
    }
    ok((await Promise.all(out.records.map(async (r) => facts.has(await record.idOf(r))))).every(Boolean), "all batches together carry every record");
  }

  /* ---- a correction, then translations made from it ---- */
  const at = want.fixed.t;
  w = await merged([...out.records, ...out.fix]);
  same(w.tp.segs.find((s) => s.t === at).text, want.fixed.text, "the corrected sentence reads as corrected");
  for (const lang of ["zh", "th"]) same(tape.trLines(w.tp, lang).find((s) => s.t === at).state, "stale", `${lang}: the old translation is now stale`);
  same(tape.trTodo(w.tp, "zh").map((s) => s.t), [at], "the city would ask for exactly that sentence again");
  w = await merged([...out.records, ...out.fix, ...out.retranslate]);
  for (const lang of ["zh", "th"]) {
    const line = tape.trLines(w.tp, lang).find((s) => s.t === at);
    same([line.state, line.tr], ["ok", want.fixed[lang]], `${lang}: the new translation is current`);
  }
  ok(tape.trLines(w.tp, "zh").every((s) => s.state === "ok"), "zh: nothing left stale");

  /* ---- withdrawal ---- */
  w = await merged([...out.records, ...out.withdraw]);
  const gone = w.archive.blocks.get(out.block_id);
  same(gone.state, "drop", "the withdrawn item is marked dropped");
  ok(!arc.visible(w.archive, gone, reader.id) && !arc.visible(w.archive, gone, host.id), "nobody sees it, the author included");
}

await scenario(await city.person(seed(0x21)), "signing with a recovery key");
await scenario(await city.migrated(seed(0x25), { now: NOW - 30 * DAY }), "signing with a device key, after moving to did:webvh");
console.log(`\n✓ ${checks} checks: the city reads what vt-city signs`);
