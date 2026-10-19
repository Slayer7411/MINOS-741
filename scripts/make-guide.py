#!/usr/bin/env python3
"""User guide as one static page: docs/MANUAL.md + settings.md + controllers.md + CHANGELOG.md -> docs/guide/index.html.

Figures with numbered pins: docs/guide/figures.json ("at": "CHAPTER" or "CHAPTER/section").
Run: python3 scripts/make-guide.py
"""

import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = DOCS / "guide"
BLOB = "https://github.com/Slayer7411/MINOS-741/blob/main/docs/"

GROUPS = [
    ("SETUP", ["INSTALL", "FIRST START", "SCREEN"]),
    ("DECKS", ["DECKS", "WAVEFORM + GRID", "SYNC / CLOCK / LINK"]),
    ("MIXER & FX", ["MIXER + AUDIO", "FX"]),
    ("LIBRARY", ["BROWSER", "TAGS + SMARTLISTS", "HISTORY + PREPARATION", "FILES + FOLDERS"]),
    ("REFERENCE", ["SETTINGS", "CONTROLLERS", "KEYS", "RECORDING", "TROUBLESHOOTING", "FAQ", "RECENT CHANGES"]),
]
SKIP = {"ui test", "live load test (interface)"}


def chapters_from(md, level="## "):
    """[(title, intro_lines, [(section, lines)])] aus ##/###."""
    out, cur, sec = [], None, None
    fence = False
    for ln in md.splitlines():
        if ln.startswith("```"):
            fence = not fence
        if not fence and ln.startswith(level):
            title = re.sub(r"^◆\s*(\d+\s*·\s*)?", "", ln[len(level):]).strip()
            cur = (title, [], [])
            out.append(cur)
            sec = None
            continue
        if cur is None:
            continue
        if not fence and ln.startswith("### "):
            sec = (ln[4:].strip(), [])
            cur[2].append(sec)
            continue
        (sec[1] if sec else cur[1]).append(ln)
    return out


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


class Render:
    def __init__(self, anchors):
        self.anchors = anchors

    def inline(self, s):
        parts = re.split(r"(`[^`]+`)", s)
        out = []
        for p in parts:
            if p.startswith("`") and p.endswith("`") and len(p) > 1:
                out.append(f"<code>{html.escape(p[1:-1])}</code>")
                continue
            p = html.escape(p, quote=False)
            p = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", p)
            p = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", self.link, p)
            p = p.replace("-&gt;", "→")
            out.append(p)
        return "".join(out)

    def link(self, m):
        text, href = m.group(1), m.group(2)
        if href.startswith("#"):
            a = self.anchors.get(href[1:].lstrip("-"))
            return f'<a href="#{a}">{text}</a>' if a else text
        if href.startswith("http"):
            return f'<a href="{href}" target="_blank" rel="noopener">{text}</a>'
        name = href.split("#")[0]
        if name in ("settings.md", "controllers.md"):
            return f'<a href="#{self.anchors.get(name, "")}">{text}</a>'
        return f'<a href="{BLOB}{href}" target="_blank" rel="noopener">{text}</a>'

    def block(self, lines):  # noqa: C901
        out, i = [], 0
        while i < len(lines):
            ln = lines[i]
            if ln.startswith("```"):
                j = i + 1
                while j < len(lines) and not lines[j].startswith("```"):
                    j += 1
                out.append("<pre>" + html.escape("\n".join(lines[i + 1:j])) + "</pre>")
                i = j + 1
                continue
            if ln.startswith("#### "):
                out.append(f"<h4>{self.inline(ln[5:])}</h4>")
                i += 1
                continue
            if ln.strip() == "---" or not ln.strip():
                i += 1
                continue
            if ln.startswith("|"):
                rows = []
                while i < len(lines) and lines[i].startswith("|"):
                    rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                    i += 1
                head, body = rows[0], [r for r in rows[1:] if not re.fullmatch(r"[-: ]+", "".join(r))]
                t = "<div class=tw><table><thead><tr>" + "".join(f"<th>{self.inline(c)}</th>" for c in head) + "</tr></thead><tbody>"
                t += "".join("<tr>" + "".join(f"<td>{self.inline(c)}</td>" for c in r) + "</tr>" for r in body)
                out.append(t + "</tbody></table></div>")
                continue
            if re.match(r"\s*([*-]|\d+\.)\s", ln):
                j = i
                while j < len(lines) and lines[j].strip() and (re.match(r"\s*([*-]|\d+\.)\s", lines[j]) or lines[j].startswith(" ")):
                    j += 1
                out.append(self.lst(lines[i:j]))
                i = j
                continue
            j = i
            para = []
            while j < len(lines) and lines[j].strip() and not re.match(r"\s*([*-]|\d+\.)\s|```|\||#### ", lines[j]):
                para.append(lines[j].strip())
                j += 1
            out.append(f"<p>{self.inline(' '.join(para))}</p>")
            i = j
        return "\n".join(out)

    def lst(self, lines):
        items, base = [], len(lines[0]) - len(lines[0].lstrip())
        tag = "ol" if re.match(r"\s*\d+\.", lines[0]) else "ul"
        for ln in lines:
            ind = len(ln) - len(ln.lstrip())
            m = re.match(r"\s*([*-]|\d+\.)\s+(.*)", ln)
            if m and ind <= base + 1:
                items.append([m.group(2), []])
            elif items:
                items[-1][1].append(ln)
        out = []
        for text, sub in items:
            inner = self.inline(text)
            if sub:
                if re.match(r"\s*([*-]|\d+\.)\s", sub[0]):
                    inner += self.lst(sub)
                else:
                    inner += " " + self.inline(" ".join(s.strip() for s in sub))
            out.append(f"<li>{inner}</li>")
        return f"<{tag}>" + "".join(out) + f"</{tag}>"


def figure(f):
    pins = "".join(
        f'<button class=pin style="left:{x / f["w"] * 100:.2f}%;top:{y / f["h"] * 100:.2f}%" data-n="{n}" '
        f'aria-label="{html.escape(t)}">{n}</button>'
        for n, (x, y, t, _) in enumerate(f["pins"], 1))
    legend = "".join(
        f'<li data-n="{n}"><span class=num>{n}</span><span><b>{html.escape(t)}</b>{" · " + html.escape(d) if d else ""}</span></li>'
        for n, (_, _, t, d) in enumerate(f["pins"], 1))
    return (f'<figure class=fig><div class=shot><img src="img/{f["img"]}" width="{f["w"]}" height="{f["h"]}" '
            f'loading=lazy alt="{html.escape(f["caption"])}">{pins}</div>'
            f'<figcaption>{html.escape(f["caption"])}</figcaption><ol class=legend>{legend}</ol></figure>')


def main():  # noqa: C901
    manual = chapters_from((DOCS / "MANUAL.md").read_text())
    by = {c[0]: c for c in manual}
    for name, title in (("settings.md", "SETTINGS"), ("controllers.md", "CONTROLLERS")):
        secs = chapters_from((DOCS / name).read_text())
        by[title] = (title, [], [(s[0].lower(), s[1] + sum((["#### " + x[0]] + x[1] for x in s[2]), [])) for s in secs])
    log = chapters_from((ROOT / "CHANGELOG.md").read_text())
    rel = [c for c in log if not c[0].startswith("[UNRELEASED")][:3]
    by["RECENT CHANGES"] = ("RECENT CHANGES", [], [(c[0].replace("[", "").replace("]", ""),
                                                    c[1] + sum((["#### " + x[0]] + x[1] for x in c[2]), [])) for c in rel])
    version = re.search(r"\[(\d+\.\d+\.\d+)\]", (ROOT / "CHANGELOG.md").read_text()).group(1)
    figs = {f["at"]: f for f in json.loads((OUT / "figures.json").read_text())}

    order, anchors = [], {"settings.md": "", "controllers.md": ""}
    n = 0
    for g, names in GROUPS:
        for name in names:
            n += 1
            ch = by[name]
            cid = f"c{n}"
            secs = [(s, ln) for s, ln in ch[2] if s.lower() not in SKIP]
            order.append((g, n, cid, name, ch[1], [(f"c{n}-{k}", s, ln) for k, (s, ln) in enumerate(secs, 1)]))
            anchors[slug(name)] = cid
            if name == "SETTINGS":
                anchors["settings.md"] = cid
            if name == "CONTROLLERS":
                anchors["controllers.md"] = cid
            for k, (s, _) in enumerate(secs, 1):
                anchors.setdefault(slug(s), f"c{n}-{k}")
    r = Render(anchors)

    nav, pages, index = [], [], []
    for gi, (g, n, cid, name, intro, secs) in enumerate(order):
        if gi == 0 or order[gi - 1][0] != g:
            nav.append(f'<div class=grp>{g}</div>')
        sub = "".join(f'<a class=sec href="#{sid}"><i>{n}.{k}</i>{html.escape(s)}</a>'
                      for k, (sid, s, _) in enumerate(secs, 1))
        nav.append(f'<a class=ch href="#{cid}" data-ch="{cid}"><i>{n:02d}</i>{html.escape(name)}</a><div class=subs data-for="{cid}">{sub}</div>')
        body = [f'<section class=chap id="{cid}" data-ch="{cid}"><header class=chead><span class=kicker>{g}</span>'
                f'<h1><b>{n:02d}</b>{html.escape(name)}</h1></header>']
        if figs.get(name):
            body.append(figure(figs[name]))
        if any(x.strip() for x in intro):
            body.append(f'<div class=intro>{r.block(intro)}</div>')
        if secs:
            body.append('<ol class=toc>' + "".join(f'<li><a href="#{sid}"><i>{n}.{k}</i>{html.escape(s)}</a></li>'
                                                   for k, (sid, s, _) in enumerate(secs, 1)) + "</ol>")
        for k, (sid, s, ln) in enumerate(secs, 1):
            f = figs.get(f"{name}/{s}")
            body.append(f'<article id="{sid}"><h2><i>{n}.{k}</i>{html.escape(s)}</h2>{figure(f) if f else ""}{r.block(ln)}</article>')
            index.append({"id": sid, "t": f"{n}.{k} {s}", "c": name,
                          "x": re.sub(r"[`*|#>\[\]()]", " ", " ".join(ln))[:1500].lower()})
        index.append({"id": cid, "t": f"{n:02d} {name}", "c": g, "x": " ".join(intro)[:800].lower()})
        prev = order[gi - 1] if gi else None
        nxt = order[gi + 1] if gi + 1 < len(order) else None
        body.append('<nav class=pn>' + (f'<a href="#{prev[2]}">← {prev[1]:02d} {html.escape(prev[3])}</a>' if prev else '<span></span>')
                    + (f'<a href="#{nxt[2]}">{nxt[1]:02d} {html.escape(nxt[3])} →</a>' if nxt else "") + '</nav></section>')
        pages.append("\n".join(body))

    about = (f'<section class=chap id="c0" data-ch="c0"><header class=chead><span class=kicker>USER GUIDE · {version}</span>'
             f'<h1><b>◆</b>MINOS-741</h1></header>'
             '<p class=lead>every mode, control and setting of MINOS-741: from install and first start to decks, mixer, fx, '
             'the library, settings and controllers. terms in CAPS are shown like on screen.</p><div class=cards>'
             + "".join(f'<a class=card href="#{o[2]}"><span>{o[0]}</span><b>{o[1]:02d}</b>{html.escape(o[3])}</a>' for o in order)
             + '</div><p class=meta>made by 741 · free + open source · macos 15+ · '
             '<a href="https://github.com/Slayer7411/MINOS-741" target="_blank" rel="noopener">github</a></p></section>')
    nav.insert(0, '<a class=ch href="#c0" data-ch="c0"><i>i</i>ABOUT THIS GUIDE</a>')

    tpl = (OUT / "template.html").read_text()
    page = (tpl.replace("{{NAV}}", "\n".join(nav)).replace("{{PAGES}}", about + "\n".join(pages))
            .replace("{{INDEX}}", json.dumps(index, ensure_ascii=False).replace("</", "<\\/"))
            .replace("{{VERSION}}", version).replace("{{CHAPTERS}}", str(len(order))))
    (OUT / "index.html").write_text(page)
    print(OUT / "index.html", len(order), "chapters", sum(len(o[5]) for o in order), "sections")


if __name__ == "__main__":
    main()
