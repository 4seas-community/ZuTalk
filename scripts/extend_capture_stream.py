"""Loop a recorded capture callback stream into a longer one.

Each loop shifts sequences, ids, capture-timeline times, revisions and wall
time so the store sees one continuous recording. Session ids become the
placeholder REPLAY-SESSION, replaced at play time.
"""
import json, sys

src, dst, loops = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = [json.loads(l) for l in open(src)]
ACTIVE = {"recording", "paused"}

def walk_rows(rows, fn):
    for r in rows or []:
        fn(r)

max_seq = max_ev = max_pv = max_prov = max_loro = max_ms = 0
for d in lines:
    for kind in ("event", "preview"):
        x = d.get(kind)
        if not x: continue
        if kind == "event":
            max_ev = max(max_ev, x["eventRevision"])
            max_loro = max(max_loro, x.get("realtimeLoroAppliedRevision", 0))
            for s in x.get("removedSequences", []): max_seq = max(max_seq, s)
        else:
            max_pv = max(max_pv, x["previewRevision"])
        for u in x.get("utterances", []):
            max_seq = max(max_seq, u["sequence"])
            max_ms = max(max_ms, u.get("sourceEndMs") or 0)
            max_loro = max(max_loro, u.get("sourceProjectionRevision", 0))
            for v in u.get("languageVariants", []):
                max_loro = max(max_loro, v.get("projectionRevision", 0))
        for c in x.get("translationCues", []):
            max_prov = max(max_prov, c["providerSequence"])
            max_ms = max(max_ms, c.get("sourceEndMs") or 0)
wall = lines[-1]["atMs"]
seq_step, ev_step, pv_step = max_seq + 1, max_ev + 1, max_pv + 1
prov_step, loro_step, ms_step, wall_step = max_prov + 1, max_loro + 1, max_ms + 2000, wall + 500

def shift_ms(obj, key, k):
    if obj.get(key) is not None: obj[key] += k * ms_step

out = open(dst, "w")
count = 0
# With `--coalesced`, every event says it covers everything since the one
# before it, as the merging dispatcher's events do: the recording was made
# with a dispatcher that dropped deltas, and replaying those drops as gaps
# would measure the old dispatcher's repairs.
coalesced = "--coalesced" in sys.argv
last_revision = None
for k in range(loops):
    for d in lines:
        d = json.loads(json.dumps(d))
        d["atMs"] += k * wall_step
        for kind in ("event", "preview"):
            x = d.get(kind)
            if not x: continue
            x["sessionId"] = "REPLAY-SESSION"
            if kind == "event":
                if x["captureState"] not in ACTIVE:
                    d[kind] = None
                    continue
                x["eventRevision"] += k * ev_step
                if k > 0: x["isFullSnapshot"] = False
                if x.get("realtimeLoroAppliedRevision"):
                    x["realtimeLoroAppliedRevision"] += k * loro_step
                x["removedSequences"] = [s + k * seq_step for s in x.get("removedSequences", [])]
                if coalesced and last_revision is not None and x["eventRevision"] > last_revision + 1:
                    x["coversFromRevision"] = last_revision + 1
                last_revision = x["eventRevision"]
            else:
                x["previewRevision"] += k * pv_step
            for u in x.get("utterances", []):
                u["sessionId"] = "REPLAY-SESSION"
                u["sequence"] += k * seq_step
                u["id"] = f'{u["id"]}~{k}'
                shift_ms(u, "sourceStartMs", k); shift_ms(u, "sourceEndMs", k)
                if u.get("sourceProjectionRevision"): u["sourceProjectionRevision"] += k * loro_step
                for v in u.get("languageVariants", []):
                    if v.get("projectionRevision"): v["projectionRevision"] += k * loro_step
            for c in x.get("translationCues", []):
                c["providerSequence"] += k * prov_step
                shift_ms(c, "sourceStartMs", k); shift_ms(c, "sourceEndMs", k)
            for h in x.get("laneHealth", []):
                shift_ms(h, "finalAudioProcMs", k); shift_ms(h, "totalAudioProcMs", k)
        if d.get("event") or d.get("preview"):
            out.write(json.dumps(d, ensure_ascii=False) + "\n"); count += 1
print(f"{count} callbacks, {loops} loops, {(lines[-1]['atMs'] + (loops-1)*wall_step)/60000:.1f} min wall, {loops*seq_step} sequences")
