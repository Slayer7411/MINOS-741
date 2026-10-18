"""Erzeugt die Ende-zu-Ende-Fixture in einem Ordner: Audio mit Klickspur und eine collection.nml.

Aufruf:  python3 -I build_fixture.py <ziel>      (Ziel: leer oder neu; legt music/ und collection/ an)
Die Dateien entstehen bei jedem Lauf neu (kein Binärmaterial im Repo). Pfade in der NML: absoluter Musikordner
des Ziels, Volume "E2E" (Schlüssel = VOLUME + DIR + FILE, wie in der Collection-Software).

Klickspur: Sinus-Klick (1 kHz, 30 ms, abklingend) je Schlag, erster Schlag bei `offset` Sekunden, `bpm` Schläge/min.
"""
import json
import math
import os
import struct
import sys
import wave
from xml.sax.saxutils import quoteattr

RATE = 22050
# Länge der Testdateien (s); E2E_FIXTURE_SECONDS: längere Dateien für Messungen (Standard 8)
SECONDS = float(os.environ.get("E2E_FIXTURE_SECONDS", "8"))

# Schlüssel: Schlüsselnummer wie MUSICAL_KEY (0–11 Dur, 12–23 Moll). Kommentar + Tags (RATING), Cues in ms.
TRACKS = [
    dict(file="t01.wav", artist="Alpha", title="Kick One", bpm=120.0, offset=0.25, key=21, genre="Techno",
         comment="warm", tags="BASIS DRUMS", cues=[("Grid", 4, 250.0, 0.0, -1), ("Intro", 0, 2000.0, 0.0, 0)]),
    dict(file="t02.wav", artist="Beta", title="Bass Two", bpm=128.0, offset=0.10, key=0, genre="House",
         comment="", tags="BASIS", cues=[]),
    dict(file="t03.wav", artist="Gamma", title="Hat Three", bpm=174.0, offset=0.05, key=12, genre="Techno",
         comment="dark peak", tags="VOLL", cues=[]),
    dict(file="t04.wav", artist="Delta", title="Pad Four", bpm=90.0, offset=0.30, key=4, genre="Ambient",
         comment="soft", tags="ATMO", cues=[]),
    dict(file="t05.wav", artist="Alpha", title="Lead Five", bpm=100.0, offset=0.00, key=9, genre="Techno",
         comment="hain", tags="SYNTH", cues=[]),
    dict(file="t06.wav", artist="Beta", title="Sweep Six", bpm=140.0, offset=0.20, key=14, genre="Techno",
         comment="", tags="VOLL", cues=[("A", 0, 1000.0, 0.0, 0), ("B", 0, 4000.0, 0.0, 1)]),
    dict(file="t07.wav", artist="Epsilon", title="Chord Seven", bpm=124.0, offset=0.15, key=2, genre="House",
         comment="warm", tags="", cues=[]),
    dict(file="t08.wav", artist="Delta", title="Sub Eight", bpm=96.0, offset=0.40, key=16, genre="Dub",
         comment="", tags="BASIS", cues=[]),
    dict(file="t09.wav", artist="Zeta", title="Snare Nine", bpm=110.0, offset=0.08, key=7, genre="House",
         comment="tagged", tags="DRUMS", cues=[]),
    dict(file="t10.wav", artist="Gamma", title="Riser Ten", bpm=130.0, offset=0.22, key=5, genre="Techno",
         comment="peak", tags="SYNTH ATMO", cues=[]),
]

PLAYLISTS = [("Warmup", ["t01.wav", "t04.wav", "t08.wav"]), ("Peak", ["t03.wav", "t06.wav", "t10.wav"])]
# Smartlists: Vergleich mit Zahl (>), Gleichheit mit | (oder), Enthält (%), Klammern, Negation (!)
SMARTLISTS = [("Techno Or Dark", '$GENRE == "Techno" | $COMMENT % "dark"'),
              ("Fast 125", "$BPM > 125"),
              ("Not Ambient", '!($GENRE == "Ambient")')]
FOLDER = ("Crates", ["Fast 125", "Not Ambient"])   # Smartlists im Ordner (Namen wie oben)


def write_click(path, bpm, offset):
    n = int(SECONDS * RATE)
    buf = [0.0] * n
    period = 60.0 / bpm
    click_len = int(0.030 * RATE)
    t = offset
    while t < SECONDS:
        start = int(t * RATE)
        for i in range(click_len):
            if start + i >= n:
                break
            env = math.exp(-i / (0.006 * RATE))
            buf[start + i] += 0.6 * env * math.sin(2 * math.pi * 1000.0 * i / RATE)
        t += period
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in buf))


def dir_string(path):
    """/tmp/x/music/ -> /:tmp/:x/:music/:  (NML-Schreibweise)"""
    parts = [p for p in path.strip("/").split("/") if p]
    return "/:" + "".join(p + "/:" for p in parts)


def node_playlist(name, uuid, keys):
    entries = "".join(f'<ENTRY><PRIMARYKEY TYPE="TRACK" KEY={quoteattr(k)}/></ENTRY>' for k in keys)
    return (f'<NODE TYPE="PLAYLIST" NAME={quoteattr(name)}><PLAYLIST ENTRIES="{len(keys)}" TYPE="LIST" UUID="{uuid}">'
            f'{entries}</PLAYLIST></NODE>')


def node_smart(name, uuid, query):
    return (f'<NODE TYPE="SMARTLIST" NAME={quoteattr(name)}><SMARTLIST UUID="{uuid}">'
            f'<SEARCH_EXPRESSION QUERY={quoteattr(query)}/></SMARTLIST></NODE>')


def write_audio(music):
    """Klickspur-Dateien (ein Ordner, schreibgeschützt benutzt)"""
    os.makedirs(music, exist_ok=True)
    for t in TRACKS:
        write_click(os.path.join(music, t["file"]), t["bpm"], t["offset"])
    return music


def build(root, music=None):
    """Collection unter root/collection/collection.nml. music: gemeinsamer Audio-Ordner (sonst root/music, wird
    dann geschrieben). Gleicher Musikordner = gleiche Track-Schlüssel, wie zwei Macs mit derselben Collection"""
    root = os.path.abspath(root)
    coll = os.path.join(root, "collection")
    os.makedirs(coll, exist_ok=True)
    music = os.path.abspath(music) if music else write_audio(os.path.join(root, "music"))
    d = dir_string(music + "/")
    key = lambda f: "E2E" + d + f

    entries = []
    for i, t in enumerate(TRACKS):
        cues = "".join(
            f'<CUE_V2 NAME={quoteattr(n)} DISPL_ORDER="0" TYPE="{ty}" START="{ms}" LEN="{ln}" REPEATS="-1" HOTCUE="{hc}"/>'
            for (n, ty, ms, ln, hc) in t["cues"])
        entries.append(
            f'<ENTRY TITLE={quoteattr(t["title"])} ARTIST={quoteattr(t["artist"])} MODIFIED_DATE="2026/10/01" MODIFIED_TIME="0">'
            f'<LOCATION DIR={quoteattr(d)} FILE={quoteattr(t["file"])} VOLUME="E2E" VOLUMEID="E2E"/>'
            f'<ALBUM TITLE="E2E Fixture" TRACK="{i + 1}"/>'
            f'<INFO GENRE={quoteattr(t["genre"])} COMMENT={quoteattr(t["comment"])} RATING={quoteattr(t["tags"])} '
            f'KEY="" PLAYTIME_FLOAT="{SECONDS}" PLAYTIME="{int(SECONDS)}" IMPORT_DATE="2026/10/01" BITRATE="705600" '
            f'FILESIZE="{int(SECONDS * RATE * 2 / 1024)}"/>'
            f'<TEMPO BPM="{t["bpm"]}" BPM_QUALITY="100"/>'
            f'<MUSICAL_KEY VALUE="{t["key"]}"/>'
            f'{cues}</ENTRY>')

    nodes = []
    uid = 1
    for name, members in PLAYLISTS:
        nodes.append(node_playlist(name, f"00000000-0000-4000-8000-{uid:012d}",
                                   [key(f) for f in dict(PLAYLISTS)[name]]))
        uid += 1
    for name, query in SMARTLISTS:
        if name in FOLDER[1]:
            continue
        nodes.append(node_smart(name, f"00000000-0000-4000-8000-{uid:012d}", query))
        uid += 1
    sub = []
    for name in FOLDER[1]:
        query = dict(SMARTLISTS)[name]
        sub.append(node_smart(name, f"00000000-0000-4000-8000-{uid:012d}", query))
        uid += 1
    nodes.append(f'<NODE TYPE="FOLDER" NAME={quoteattr(FOLDER[0])}><SUBNODES COUNT="{len(sub)}">{"".join(sub)}</SUBNODES></NODE>')

    xml = ('<?xml version="1.0" encoding="UTF-8" standalone="no" ?>\n'
           '<NML VERSION="19"><HEAD COMPANY="www.native-instruments.com" PROGRAM="Traktor"/>'
           f'<COLLECTION ENTRIES="{len(entries)}">{"".join(entries)}</COLLECTION>'
           f'<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="{len(nodes)}">{"".join(nodes)}</SUBNODES></NODE></PLAYLISTS>'
           '</NML>\n')
    with open(os.path.join(coll, "collection.nml"), "w", encoding="utf-8") as f:
        f.write(xml)
    return os.path.join(coll, "collection.nml")


def track_key(music, file):
    """Schlüssel eines Tracks in der NML für einen Musikordner (wie build)"""
    return "E2E" + dir_string(os.path.abspath(music) + "/") + file


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("aufruf: build_fixture.py <ziel>", file=sys.stderr)
        sys.exit(2)
    print(build(sys.argv[1]))


FAKE_IPS_HEADER = {"app_name": "MINOS-741", "app_version": "9.9.9", "build_version": "4242", "bug_type": "309",
                   "os_version": "macOS 26.0 (25A100)", "timestamp": "2026-10-17 10:00:00.00 +0200",
                   "bundleID": "com.github.slayer7411.minos741"}
FAKE_IPS_BODY = {"procName": "minos741",
                 "procPath": "/Users/cs.privat/Applications/MINOS-741.app/Contents/MacOS/minos741",
                 "captureTime": "2026-10-17 10:00:00.00 +0200", "osVersion": {"train": "macOS 26.0", "build": "25A100"},
                 "cpuType": "ARM-64", "hardwareModel": "Mac15,7", "crashReporterKey": "6F3C2A1B-1111-2222-3333-444455556666",
                 "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"}, "faultingThread": 0,
                 "threads": [{"triggered": True, "frames": [
                     {"imageOffset": 4096, "symbol": "mixer_process", "symbolLocation": 12, "imageIndex": 0},
                     {"imageOffset": 99, "imageIndex": 1}]}],
                 "usedImages": [{"path": "/Users/cs.privat/Applications/MINOS-741.app/Contents/MacOS/minos741",
                                 "name": "minos741"}]}


def write_fake_crash(root):
    """Ein Absturzbericht im isolierten Berichtsordner der Instanz (<root>/diagnostic-reports), Szenario fake_crash"""
    import json
    d = os.path.join(root, "diagnostic-reports")
    os.makedirs(d, exist_ok=True)
    text = json.dumps(FAKE_IPS_HEADER) + "\n" + json.dumps(FAKE_IPS_BODY, indent=2) + "\n"
    with open(os.path.join(d, "MINOS-741_2026-10-17-100000_E2E.ips"), "w", encoding="utf-8") as f:
        f.write(text)
