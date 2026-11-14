/* A few seconds of real audio for the end-to-end checks: two parts of one
   recording, each an AAC `.m4a` that plays on its own, as the app exports
   them.

   They are made on the spot — a tone synthesised here, encoded by macOS's own
   `afconvert` — so that no binary is kept in the repository and nothing
   anyone recorded is ever used as a fixture. The checks need a real MPEG-4
   file only so that what is uploaded is what would be uploaded; nothing here
   or in the city's server decodes it. */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const RATE = 16_000;

/* A mono 16-bit WAV of one steady tone. */
function tone(hz, ms) {
  const n = Math.round((RATE * ms) / 1000), wav = Buffer.alloc(44 + n * 2);
  wav.write("RIFF", 0); wav.writeUInt32LE(36 + n * 2, 4); wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(RATE, 24); wav.writeUInt32LE(RATE * 2, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
  wav.write("data", 36); wav.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) wav.writeInt16LE(Math.round(Math.sin((2 * Math.PI * hz * i) / RATE) * 12_000), 44 + i * 2);
  return wav;
}

/* The parts, in order: where each file is, its bytes, the name the city
   stores it under (the SHA-256 of the bytes), its place on the recording's
   timeline in milliseconds, and one loudness digit per second. */
export function parts(dir) {
  mkdirSync(dir, { recursive: true });
  let t0 = 0;
  return [{ hz: 440, dur: 3000, lv: "468" }, { hz: 660, dur: 2000, lv: "53" }].map(({ hz, dur, lv }, n) => {
    const wav = join(dir, `part-${n}.wav`), path = join(dir, `part-${n}.m4a`);
    writeFileSync(wav, tone(hz, dur));
    const made = spawnSync("afconvert", ["-f", "m4af", "-d", "aac", "-b", "32000", wav, path], { encoding: "utf8" });
    if (made.error || made.status !== 0) {
      console.error("afconvert (part of macOS) could not encode the audio fixture: " + (made.error?.message || made.stderr));
      process.exit(2);
    }
    const bytes = readFileSync(path);
    const part = { n, path, bytes, file: createHash("sha256").update(bytes).digest("hex"), size: bytes.length, t0, dur, lv };
    t0 += dur;
    return part;
  });
}

/* What the driver hands the Rust side: where the files are and where they sit. */
export const asEnv = (list) => JSON.stringify(list.map(({ path, t0, dur, lv }) => ({ path, t0, dur, lv })));

/* The city's reading of a take's parts, reduced to what was signed. */
export const read = (take) => take.parts.map(({ n, file, size, t0, dur, mime, lv }) => ({ n, file, size, t0, dur, mime, lv }));
/* The same for the fixture: what the city should read back. */
export const signed = (list) => list.map(({ n, file, size, t0, dur, lv }) => ({ n, file, size, t0, dur, mime: "audio/mp4", lv }));

/* Asks a server for a stored file the way a player does, and says what came back. */
export async function fetched(origin, file, headers = {}) {
  const r = await fetch(`${origin}/files/${file}`, { headers });
  return { status: r.status, type: r.headers.get("content-type"), cache: r.headers.get("cache-control") || "", range: r.headers.get("content-range"), bytes: Buffer.from(await r.arrayBuffer()) };
}
