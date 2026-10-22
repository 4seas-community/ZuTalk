"""Scores one recorded run of the three-language suite against its manifest.

    python3 scripts/multilingual/suite_eval.py <recording.jsonl> <manifest.json> <review-out.txt>

The recording is what LiveCaptureReplayTests writes with "record"; the
manifest is make_suite.py's. The review file lists every script segment
with the rows it became and their translations, for reading by eye.
"""
import json, os, re, sys, statistics as st, unicodedata

REC, MAN, REVIEW = sys.argv[1:4]
manifest = json.load(open(MAN))
# A single corpus's manifest has no corpus field; name it after its file.
for m in manifest:
    m.setdefault("corpus", os.path.splitext(os.path.basename(MAN))[0])

rows, cues = {}, {}
first_text, final_at, src_final_at = {}, {}, {}
for line in open(REC):
    d = json.loads(line)
    at = d["atMs"]
    for kind in ("event", "preview"):
        e = d.get(kind)
        if not e:
            continue
        if kind == "event":
            if e.get("isFullSnapshot"):
                rows = {u["sequence"]: u for u in e["utterances"]}
            else:
                for s in e.get("removedSequences", []):
                    rows.pop(s, None)
                for u in e["utterances"]:
                    cur = rows.get(u["sequence"])
                    if cur is None or u["revision"] >= cur["revision"]:
                        rows[u["sequence"]] = u
            for c in e.get("translationCues", []):
                k = (c["targetLanguage"], c["groupEpoch"], c["providerSequence"])
                if c.get("withdrawn"):
                    cues.pop(k, None)
                else:
                    cues[k] = c
        for u in e.get("utterances", []):
            for v in u.get("languageVariants", []):
                if not v.get("text"):
                    continue
                key = (u["sequence"], v["language"])
                if v["role"] == "source":
                    if v.get("completion") == "complete":
                        src_final_at.setdefault(u["sequence"], at)
                    continue
                first_text.setdefault(key, at)
                if kind == "event" and v.get("completion") == "complete":
                    final_at.setdefault(key, at)

rows = [rows[k] for k in sorted(rows)]
timed = [u for u in rows if u.get("sourceStartMs") is not None and u.get("sourceEndMs") is not None]
offs = [src_final_at[u["sequence"]] - u["sourceEndMs"] for u in timed if u["sequence"] in src_final_at]
clock = min(offs) - 300 if offs else 0  # recording ms of audio position 0


def _grams(text):
    t = [c for c in unicodedata.normalize("NFC", text).lower() if c.isalnum()]
    return {"".join(t[i:i + 2]) for i in range(len(t) - 1)} or set(t)


for _s in manifest:
    _s["_grams"] = _grams(_s["text"])
_seg_cache = {}


def seg_of(start_ms, end_ms, text=None):
    """The manifest segment a row belongs to: by its words when it has any —
    a lane whose clock is off must not be judged by it — else by time."""
    if text:
        key = (start_ms, text)
        if key in _seg_cache:
            return _seg_cache[key]
        grams = _grams(text)
        best, best_score = None, 0.0
        for s in manifest:
            if abs(s["start"] * 1000 - start_ms) > 15000 and abs(s["end"] * 1000 - end_ms) > 15000:
                continue
            score = len(grams & s["_grams"]) / max(1, len(grams))
            if score > best_score:
                best, best_score = s, score
        if best is not None and best_score >= 0.3:
            _seg_cache[key] = best
            return best
    best, best_overlap = None, 0
    for s in manifest:
        lo, hi = max(start_ms, s["start"] * 1000), min(end_ms, s["end"] * 1000)
        if hi - lo > best_overlap:
            best, best_overlap = s, hi - lo
    return best


def segs_touched(start_ms, end_ms, min_ms=400):
    return [s for s in manifest
            if min(end_ms, s["end"] * 1000) - max(start_ms, s["start"] * 1000) >= min_ms]


def norm(text, lang):
    text = unicodedata.normalize("NFC", text).lower()
    if lang == "en":
        return re.sub(r"[^a-z0-9 ]", " ", text).split()
    return [c for c in text if c.isalnum()]


def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]


print(f"rows {len(rows)}, cues {len(cues)}")
# Coverage
langs = sorted({m["lang"] for m in manifest})
missing = []
for u in rows:
    for lang in langs:
        if lang == u["sourceLanguage"]:
            continue
        v = next((v for v in u["languageVariants"] if v["language"] == lang), None)
        if not v or v.get("state") != "ready" or not v.get("text"):
            missing.append((u["sequence"], lang, v and v.get("state")))
lanes = sum(1 for u in rows for lang in langs if lang != u["sourceLanguage"])
print(f"translation lanes {lanes}, filled {lanes - len(missing)}; missing: {missing[:8]}")

# Labels and recognition by corpus/language
by_seg = {}
for u in timed:
    s = seg_of(u["sourceStartMs"], u["sourceEndMs"], u["sourceText"])
    if s:
        by_seg.setdefault(s["i"] + 1000 * sorted({m["corpus"] for m in manifest}).index(s["corpus"]), []).append(u)
mislabel = [(u["sequence"], u["sourceLanguage"], seg_of(u["sourceStartMs"], u["sourceEndMs"], u["sourceText"])["lang"])
            for u in timed if seg_of(u["sourceStartMs"], u["sourceEndMs"], u["sourceText"]) and
            u["sourceLanguage"] != seg_of(u["sourceStartMs"], u["sourceEndMs"], u["sourceText"])["lang"]]
print(f"rows whose label differs from the spoken language: {mislabel}")
for corpus in sorted({m["corpus"] for m in manifest}):
    parts = []
    for lang in langs:
        ref, hyp = [], []
        for s in manifest:
            if s["corpus"] != corpus or s["lang"] != lang:
                continue
            ref.append(s["text"])
            hyp += [u["sourceText"] for u in timed if seg_of(u["sourceStartMs"], u["sourceEndMs"], u["sourceText"]) is s]
        if not ref:
            continue
        R, H = norm(" ".join(ref), lang), norm(" ".join(hyp), lang)
        parts.append(f"{lang} {100 * lev(R, H) / max(1, len(R)):.1f}%")
    print(f"recognition error {corpus:6}: " + ", ".join(parts))

# Canonical clock against the script: the first row of each segment
starts = []
for _k, _rows in sorted(by_seg.items()):
    _first = min(_rows, key=lambda r: r["sourceStartMs"])
    _seg = seg_of(_first["sourceStartMs"], _first["sourceEndMs"], _first["sourceText"])
    starts.append((_seg["start"], _first["sourceStartMs"] / 1000 - _seg["start"]))
starts.sort()
if starts:
    third = max(1, len(starts) // 3)
    early = sorted(d for _, d in starts[:third]); late = sorted(d for _, d in starts[-third:])
    print(f"canonical row start minus script: early {early[len(early)//2]:+.2f}s, late {late[len(late)//2]:+.2f}s")

# Rows: length and splits inside one spoken segment
lengths = [(u["sourceEndMs"] - u["sourceStartMs"]) / 1000 for u in timed]
print(f"row length s: median {st.median(lengths):.1f}, p90 {sorted(lengths)[int(len(lengths) * .9)]:.1f}, max {max(lengths):.1f}; rows > 15 s: {sum(l > 15 for l in lengths)}")
multi = {k: v for k, v in by_seg.items() if len(v) > 1}
print(f"spoken segments cut into several rows: {len(multi)}")

# Facts that span two spoken segments: where a translation spills onto a neighbour's row
straddle = []
for c in cues.values():
    if c.get("sourceStartMs") is None or c.get("sourceEndMs") is None:
        continue
    touched = segs_touched(c["sourceStartMs"], c["sourceEndMs"])
    if len(touched) > 1:
        straddle.append((c["targetLanguage"], c["sourceStartMs"] / 1000, c["sourceEndMs"] / 1000,
                         [f"{t['corpus']}#{t['i']}" for t in touched], c["text"][-40:]))
print(f"translation segments spanning two spoken segments: {len(straddle)} of {len(cues)}")
for s in straddle[:12]:
    print("   ", s)

# Latency
lat = {}
for (seq, lang), at in final_at.items():
    u = next((r for r in timed if r["sequence"] == seq), None)
    if not u or lang == u["sourceLanguage"]:
        continue
    lat.setdefault(f"{u['sourceLanguage']}->{lang}", []).append((at - clock - u["sourceEndMs"]) / 1000)
src_lat = {}
for u in timed:
    if u["sequence"] in src_final_at:
        src_lat.setdefault(u["sourceLanguage"], []).append((src_final_at[u["sequence"]] - clock - u["sourceEndMs"]) / 1000)
print("final after speech ends, median s: " + ", ".join(f"{k} {st.median(v):.1f}" for k, v in sorted(lat.items())))
print("source final after speech ends, median/max s: " + ", ".join(f"{k} {st.median(v):.1f}/{max(v):.1f}" for k, v in sorted(src_lat.items())))

# Text shape
han_space = {}
particles = 0
for u in rows:
    for v in u["languageVariants"]:
        t = v.get("text") or ""
        if v["role"] == "translation" and v["language"] == "zh":
            han_space[u["sourceLanguage"]] = han_space.get(u["sourceLanguage"], 0) + len(re.findall(r"[一-鿿] +[一-鿿]", t))
        if v["role"] == "translation" and v["language"] == "th":
            particles += len(re.findall(r"(ค่ะ|คะ|ครับ)(?=\s|$|[.,!?:])", t))
print(f"spaces between Han characters in Chinese translations, by source: {han_space}")
print(f"Thai politeness particles added in translations: {particles}")

# Review table
with open(REVIEW, "w") as out:
    for s in manifest:
        mine = [u for u in timed if seg_of(u["sourceStartMs"], u["sourceEndMs"], u["sourceText"]) is s]
        out.write(f"\n=== {s['corpus']}#{s['i']} [{s['start']:.1f}-{s['end']:.1f}] {s['lang']} ({s['voice']})\nREF: {s['text']}\n")
        for u in mine:
            out.write(f"  row {u['sequence']} [{u['sourceStartMs']/1000:.1f}-{u['sourceEndMs']/1000:.1f}] {u['sourceLanguage']}: {u['sourceText']}\n")
            for v in u["languageVariants"]:
                if v["role"] == "translation":
                    out.write(f"     {v['language']}: {v.get('text')}\n")
print("review:", REVIEW)
