"""How far each auxiliary lane's clock is from the canonical lane's, word by word.

Every lane transcribes the same speech, so a word the canonical lane heard at
t appears on an auxiliary lane at t + offset. The trace is the file a debug
build writes when ZUTALK_LANE_TRACE names one: every provider event of every
lane, and the provider's clock next to the audio sent.

    python3 scripts/multilingual/trace_offset.py <trace.jsonl>
"""
import json, sys, bisect, collections

canon = collections.defaultdict(list)  # text -> [start]
aux = collections.defaultdict(list)    # target -> [(start, text)]
finalizes = collections.defaultdict(list)
progress = collections.defaultdict(list)
first_at = None
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if "canonical" not in d:
        continue
    first_at = first_at or d["at"]
    lane = "canonical" if d["canonical"] else d.get("target")
    if d["kind"] == "finalized":
        finalizes[lane].append(d["at"])
    if d["kind"] == "progress":
        progress[lane].append((d["at"], d.get("final_ms")))
    if d["kind"] != "tokens":
        continue
    for t in d["tokens"]:
        if not t["f"] or t["tr"] == "Translation" or t["s"] is None:
            continue
        word = t["t"].strip().lower()
        if len(word) < 2 or word == "<end>":
            continue
        if d["canonical"]:
            canon[word].append(t["s"])
        else:
            aux[d["target"]].append((t["s"], word))

for target, words in aux.items():
    offsets = []
    for start, word in words:
        candidates = canon.get(word, [])
        if not candidates:
            continue
        best = min(candidates, key=lambda c: abs(start - c))
        if abs(start - best) < 8000:
            offsets.append((best, start - best))
    offsets.sort()
    meds = []
    tmp = collections.defaultdict(list)
    for at, off in offsets:
        tmp[int(at // 30000)].append(off)
    for b in sorted(tmp):
        v = sorted(tmp[b]); meds.append(v[len(v) // 2])
    print(f"-> {target}: {len(offsets)} words matched, {len(finalizes[target])} finalizes, "
          f"offset first {meds[0]/1000 if meds else 0:+.2f}s last {meds[-1]/1000 if meds else 0:+.2f}s "
          f"worst {max(meds, key=abs)/1000 if meds else 0:+.2f}s")
    buckets = collections.defaultdict(list)
    for at, off in offsets:
        buckets[int(at // 30000)].append(off)
    for b in sorted(buckets):
        values = sorted(buckets[b])
        print(f"   {b*30:4}-{b*30+30:4}s  median offset {values[len(values)//2]/1000:+.2f}s  (n={len(values)})")
print("canonical finalizes:", len(finalizes["canonical"]))
