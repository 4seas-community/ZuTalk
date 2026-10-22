"""Builds the Thai/Chinese/English test corpora with macOS speech synthesis:
16 kHz mono WAV plus a manifest of every segment's voice, language,
reference text and time span.

    python3 scripts/multilingual/make_suite.py <outdir>

Corpora: turns (quick alternating turns), mixed (English terms, numbers and
names inside Thai and Chinese), long (monologues), fast (turns and terms at a
faster rate), noisy (turns under babble, pink noise and room echo, pitched
down). Also all (the five in a row), core (turns, mixed and part of fast and
long, for one configuration of the matrix) and pair-thzh, pair-then,
pair-zhen (two-language corpora for the two-way modes).
"""
import json, os, subprocess, sys, wave, struct, random

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

TH, ZH, ZH_M, EN, EN_M = "Kanya", "Tingting", "Eddy (中文（中國大陸）)", "Samantha", "Daniel"

TURNS = [
    (TH, "th", "สวัสดีค่ะทุกคน วันนี้เราจะคุยเรื่องงานตลาดนัดวันเสาร์นี้นะคะ"),
    (EN, "en", "Great. Do we already have a list of the stalls?"),
    (TH, "th", "มีแล้ว ตอนนี้มีร้านลงชื่อสิบแปดร้าน"),
    (ZH_M, "zh", "那场地够不够？上次有人说太挤了。"),
    (TH, "th", "รอบนี้เราย้ายไปลานจอดรถด้านหลัง พื้นที่ใหญ่กว่าเดิมเกือบเท่าตัว"),
    (EN_M, "en", "And what about parking for the visitors?"),
    (ZH, "zh", "我们可以和对面的学校商量，借他们的停车场。"),
    (TH, "th", "ดีมากเลย ใครจะเป็นคนไปคุยกับโรงเรียน"),
    (ZH, "zh", "我去吧，我认识他们的校长。"),
    (EN, "en", "Thanks. I can design the poster tonight."),
    (TH, "th", "อย่าลืมใส่สามภาษานะคะ ไทย จีน และอังกฤษ"),
    (EN, "en", "Of course."),
    (ZH_M, "zh", "还有一个问题，下雨怎么办？"),
    (TH, "th", "เราเตรียมเต็นท์ไว้สิบหลัง น่าจะพอสำหรับร้านส่วนใหญ่"),
    (EN_M, "en", "Ten tents should be fine. Who is paying for them?"),
    (TH, "th", "เงินมาจากค่าเช่าร้าน ร้านละสองร้อยบาท"),
    (ZH, "zh", "好的，那我把预算表更新一下，晚上发到群里。"),
    (EN, "en", "Perfect. Let's meet again on Thursday to check everything."),
    (TH, "th", "ตกลงค่ะ วันพฤหัสบ่ายสามโมงนะคะ"),
    (ZH_M, "zh", "没问题，周四见。"),
]

MIXED = [
    (TH, "th", "พรุ่งนี้เรามี workshop เรื่อง open source ตอนบ่ายสองโมงครึ่ง ที่ co-working space ชั้นสาม ค่าลงทะเบียนสามร้อยห้าสิบบาท ใครสนใจให้กรอก Google Form ในกลุ่ม LINE ได้เลย"),
    (ZH, "zh", "我们下周三下午三点在 Punspace 开会，主题是 DAO 治理和链上投票，预计有二十五个人参加，请大家提前安装 MetaMask。"),
    (EN, "en", "The budget for October is twelve thousand five hundred baht, and we still need four volunteers for the Loy Krathong night market on the fifteenth of November."),
    (TH, "th", "คุณหลี่เหวินจากเซี่ยงไฮ้จะมาพูดเรื่อง AI กับการแปลภาษา ส่วนคุณ Sarah จากลอนดอนจะเล่าเรื่องการทำ podcast ภาษาไทย"),
    (ZH_M, "zh", "这次的 hackathon 一共有十二个团队报名，奖金池是五万泰铢，第一名可以拿到两万。"),
    (EN_M, "en", "Our Wi-Fi password changed to nimman twenty twenty six, all lowercase, and the printer on the second floor is out of toner again."),
    (TH, "th", "ช่วงนี้ค่าไฟขึ้นเป็นหน่วยละห้าบาทสี่สิบสตางค์ เราเลยต้องปิดแอร์หลังสี่ทุ่ม"),
    (ZH, "zh", "清迈到曼谷的夜班火车是晚上六点出发，第二天早上七点到，二等卧铺大概九百泰铢。"),
    (EN, "en", "If you are joining from Chiang Rai or Lampang, the shuttle leaves from the Maya mall at eight thirty in the morning."),
    (TH, "th", "ขอบคุณคุณจางเหว่ยที่ช่วยแปลเอกสาร ทั้งภาษาจีนและภาษาอังกฤษ รวมแล้วเกือบสี่สิบหน้า"),
]

LONG = [
    (TH, "th", "ก่อนอื่นต้องขอบคุณทุกคนที่มาในวันนี้ ฉันอยากเล่าเรื่องการเดินทางของชุมชนเราในช่วงสามปีที่ผ่านมา ตอนเริ่มต้นเรามีกันแค่ห้าคน นั่งประชุมกันในร้านกาแฟเล็กๆ แถวคูเมือง ไม่มีงบประมาณ ไม่มีสถานที่ มีแต่ความตั้งใจที่อยากให้คนที่ย้ายมาอยู่เชียงใหม่ได้รู้จักกัน ปีแรกเราจัดกิจกรรมเดือนละครั้ง ส่วนใหญ่เป็นการพบปะพูดคุยธรรมดา แต่สิ่งที่เราเรียนรู้คือคนไม่ได้ต้องการแค่การพบปะ พวกเขาต้องการทำอะไรบางอย่างร่วมกัน ปีที่สองเราจึงเริ่มโครงการอาสาสมัคร สอนภาษาให้เด็กในชุมชน ปลูกผักบนดาดฟ้า และซ่อมจักรยานให้คนในละแวกนั้น จากห้าคนกลายเป็นห้าสิบคน และจากร้านกาแฟกลายเป็นพื้นที่ทำงานร่วมกันที่เรามีอยู่ทุกวันนี้ ปีที่สามเป็นปีที่ยากที่สุด เพราะเมื่อคนมากขึ้น การตัดสินใจก็ยากขึ้น เราต้องเรียนรู้วิธีการลงคะแนน วิธีการรับฟังเสียงส่วนน้อย และวิธีการบันทึกทุกการตัดสินใจให้โปร่งใส"),
    (ZH, "zh", "我想接着刚才的话题，谈一谈透明的问题。我们社区的每一个决定，从预算到活动安排，都会写成记录，并且由提出的人签名。这样做一开始很麻烦，很多人觉得没必要，但是半年以后大家发现，有了这些记录，新来的成员可以很快了解过去发生了什么，争论也少了很多。因为每个人都可以回去看，当时是谁提出的，理由是什么，谁同意了，谁反对了。我觉得这是我们三年来最重要的一个改变。"),
    (EN, "en", "Let me add the perspective of someone who joined only last year. When I arrived, I did not speak any Thai, and very little Chinese. What surprised me most was how quickly the written records helped me catch up. I could read every decision, in my own language, and see who had argued for what. That made it much easier to trust people I had never met. I think this is something many communities could learn from, not only here in Chiang Mai, but anywhere people from different countries try to build something together."),
    (TH, "th", "ขอบคุณมากค่ะ ฉันเห็นด้วยทั้งหมด และอยากเพิ่มอีกเรื่องหนึ่ง คือเรื่องภาษา ในการประชุมใหญ่ครั้งล่าสุด เรามีคนพูดสามภาษาในห้องเดียวกัน ถ้าไม่มีระบบแปลแบบเรียลไทม์ การประชุมคงใช้เวลานานกว่าเดิมสามเท่า และหลายคนคงไม่กล้าพูด ตอนนี้ทุกคนพูดภาษาของตัวเองได้ และคนอื่นอ่านคำแปลบนจอได้ทันที นี่คือสิ่งที่ทำให้ชุมชนของเราเป็นชุมชนจริงๆ ไม่ใช่แค่กลุ่มคนที่บังเอิญอยู่ในเมืองเดียวกัน"),
]


def tts(voice, text, path, rate=None):
    aiff = path + ".aiff"
    cmd = ["say", "-v", voice, "-o", aiff]
    if rate:
        cmd += ["-r", str(rate)]
    subprocess.run(cmd + [text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, path], check=True)
    os.remove(aiff)


def read(path):
    with wave.open(path) as w:
        return w.readframes(w.getnframes())


def build(name, segments, gap_s, rate=None):
    parts = os.path.join(OUT, name + ".parts")
    os.makedirs(parts, exist_ok=True)
    pcm = bytearray()
    manifest = []
    for i, (voice, lang, text) in enumerate(segments):
        path = os.path.join(parts, f"{i:03}.wav")
        tts(voice, text, path, rate)
        data = read(path)
        start = len(pcm) / 32000
        pcm += data
        manifest.append({"i": i, "voice": voice, "lang": lang, "text": text,
                         "start": round(start, 3), "end": round(len(pcm) / 32000, 3)})
        pcm += b"\0\0" * int(16000 * gap_s)
    out = os.path.join(OUT, name + ".wav")
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(pcm))
    json.dump(manifest, open(os.path.join(OUT, name + ".json"), "w"), ensure_ascii=False, indent=1)
    print(f"{name}: {len(segments)} segments, {len(pcm)/32000:.1f} s")
    return out


def noisy(src, name):
    """Café-like conditions: pink noise and a low babble of other voices,
    some room echo, and Thai pitched down as a different speaker would be."""
    babble = os.path.join(OUT, name + ".babble.wav")
    lines = [t for _, _, t in MIXED]
    tts(ZH_M, " ".join(lines[1::3]), babble + ".a.wav")
    tts(EN_M, " ".join(lines[2::3]), babble + ".b.wav")
    out = os.path.join(OUT, name + ".wav")
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", src, "-i", babble + ".a.wav", "-i", babble + ".b.wav",
        "-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.02:sample_rate=16000",
        "-filter_complex",
        "[0]aecho=0.8:0.6:40:0.25,asetrate=16000*0.94,aresample=16000,atempo=1.0638[v];"
        "[1]volume=0.07,aloop=loop=-1:size=2e9[b1];[2]volume=0.07,aloop=loop=-1:size=2e9[b2];"
        "[v][b1][b2][3]amix=inputs=4:duration=first:normalize=0[m]",
        "-map", "[m]", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out,
    ], check=True)
    manifest = json.load(open(src.replace(".wav", ".json")))
    json.dump(manifest, open(os.path.join(OUT, name + ".json"), "w"), ensure_ascii=False, indent=1)
    print(f"{name}: noisy copy of {os.path.basename(src)}")


turns = build("turns", TURNS, gap_s=0.4)
build("mixed", MIXED, gap_s=0.8)
build("long", LONG, gap_s=1.0)
build("fast", TURNS + MIXED[:5], gap_s=0.3, rate=230)
noisy(turns, "noisy")


def combine(name, chosen, gap):
    pcm = bytearray()
    manifest = []
    parts = {c: os.path.join(OUT, c + ".parts") for c in ("turns", "mixed", "long", "fast")}
    for seg in chosen:
        with wave.open(os.path.join(parts[seg["corpus"]], f"{seg['i']:03}.wav")) as w:
            data = w.readframes(w.getnframes())
        start = len(pcm) / 32000
        pcm += data
        manifest.append(dict(seg, start=round(start, 3), end=round(len(pcm) / 32000, 3)))
        pcm += b"\0\0" * int(16000 * gap)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(pcm))
    json.dump(manifest, open(os.path.join(OUT, name + ".json"), "w"), ensure_ascii=False, indent=1)
    print(f"{name}: {len(manifest)} segments, {len(pcm)/32000:.1f} s")


def corpus(name):
    return [dict(s, corpus=name) for s in json.load(open(os.path.join(OUT, name + ".json")))]


# all: the five corpora in a row, two seconds apart.
pcm, manifest = bytearray(), []
for name in ["turns", "mixed", "long", "fast", "noisy"]:
    offset = len(pcm) / 32000
    with wave.open(os.path.join(OUT, name + ".wav")) as w:
        pcm += w.readframes(w.getnframes())
    for seg in corpus(name):
        manifest.append(dict(seg, start=round(seg["start"] + offset, 3), end=round(seg["end"] + offset, 3)))
    pcm += b"\0\0" * 32000
with wave.open(os.path.join(OUT, "all.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(pcm))
json.dump(manifest, open(os.path.join(OUT, "all.json"), "w"), ensure_ascii=False, indent=1)
print(f"all: {len(manifest)} segments, {len(pcm)/32000:.1f} s")

combine("core", corpus("turns") + corpus("mixed") + corpus("fast")[:12] + corpus("long")[:1], 0.4)
pool = corpus("turns") + corpus("mixed") + corpus("long")
for a, b in [("th", "zh"), ("th", "en"), ("zh", "en")]:
    combine(f"pair-{a}{b}", [s for s in pool if s["lang"] in (a, b)], 0.4)
