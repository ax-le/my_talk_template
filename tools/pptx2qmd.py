#!/usr/bin/env python3
"""Convert the PhD-defense .pptx into a Quarto reveal.js deck (hybrid style).

- Titles / text  -> Markdown (headings, lists, bold/italic, $LaTeX$ math)
- Shapes / tensors / arrows -> absolutely positioned divs (+ inline SVG for non-rect geometry)
- Pictures      -> ![](media/..){.absolute ...}  (cropped with PIL when PowerPoint cropped them)
- Audio         -> clickable speaker icon (.audio-btn data-audio=...)
- Morph         -> reveal.js auto-animate (data-id = PowerPoint creationId, chains via auto-animate-id)
- Click builds  -> fragments with data-fragment-index
- Speaker notes -> ::: notes
"""
import colorsys, hashlib, os, re, shutil, subprocess, sys
from collections import Counter
from lxml import etree
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from omml import omml_to_latex

if len(sys.argv) < 3:
    sys.exit("usage: python pptx2qmd.py talk.pptx OUTDIR   (env: SKIP=1,2 TEST=1 BACKUP_FROM=67 FK=0.93)")
SRC, OUT = sys.argv[1], sys.argv[2]
if SRC.lower().endswith(".pptx"):
    import tempfile, zipfile
    _tmp = tempfile.mkdtemp(prefix="pptx_")
    zipfile.ZipFile(SRC).extractall(_tmp)
    SRC = _tmp
MEDIA = os.path.join(OUT, "media")
os.makedirs(MEDIA, exist_ok=True)

NS = {
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "mc": "http://schemas.openxmlformats.org/markup-compatibility/2006",
    "a14": "http://schemas.microsoft.com/office/drawing/2010/main",
    "p14": "http://schemas.microsoft.com/office/powerpoint/2010/main",
    "p159": "http://schemas.microsoft.com/office/powerpoint/2015/09/main",
    "a16": "http://schemas.microsoft.com/office/drawing/2014/main",
    "asvg": "http://schemas.microsoft.com/office/drawing/2016/SVG/main",
    "m": "http://schemas.openxmlformats.org/officeDocument/2006/math",
}
def Q(t):
    p, n = t.split(":"); return "{%s}%s" % (NS[p], n)

EMU_W = 12192000
F = 1280 / EMU_W          # px per EMU
FK = float(os.environ.get('FK', '0.93'))   # Libre Franklin is wider than Franklin Gothic Book
PT = 4 / 3 * FK           # px per pt (font sizes)

def parse(path):
    return etree.parse(path).getroot()

def rels(path):
    d = os.path.dirname(path); b = os.path.basename(path)
    rp = os.path.join(d, "_rels", b + ".rels")
    out = {}
    if os.path.exists(rp):
        for r in parse(rp):
            tgt = r.get("Target")
            if r.get("TargetMode") != "External":
                tgt = os.path.normpath(os.path.join(d, tgt))
            out[r.get("Id")] = tgt
    return out

def resolve_ac(root):
    """Replace mc:AlternateContent by its Choice (all features we need are supported) ."""
    for ac in list(root.iter(Q("mc:AlternateContent"))):
        ch = ac.find(Q("mc:Choice"))
        use = ch if ch is not None else ac.find(Q("mc:Fallback"))
        parent = ac.getparent()
        idx = parent.index(ac)
        parent.remove(ac)
        if use is not None:
            for i, c in enumerate(list(use)):
                parent.insert(idx + i, c)
    return root

# ---------------------------------------------------------------- theme / colours
PRS = os.path.join(SRC, "ppt")
theme = parse(os.path.join(PRS, "theme/theme1.xml"))
SCHEME = {}
for c in theme.find(".//a:clrScheme", NS):
    v = c[0]
    SCHEME[etree.QName(c).localname] = v.get("lastClr") or v.get("val")
CLRMAP = {"bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"}
LNW = [int(l.get("w", 9525)) for l in theme.find(".//a:lnStyleLst", NS)]
MAJOR = theme.find(".//a:majorFont/a:latin", NS).get("typeface")

def apply_mods(hexc, el):
    r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (0, 2, 4))
    alpha = 1.0
    for m in el:
        n = etree.QName(m).localname; v = int(m.get("val", 0)) / 100000
        if n in ("lumMod", "lumOff", "satMod"):
            h, l, s = colorsys.rgb_to_hls(r, g, b)
            if n == "lumMod": l *= v
            elif n == "lumOff": l += v
            else: s *= v
            r, g, b = colorsys.hls_to_rgb(h, min(max(l, 0), 1), min(max(s, 0), 1))
        elif n == "tint":
            r, g, b = (x + (1 - x) * (1 - v) for x in (r, g, b))
        elif n == "shade":
            r, g, b = (x * v for x in (r, g, b))
        elif n == "alpha":
            alpha = v
    return "#%02X%02X%02X" % tuple(round(min(max(x, 0), 1) * 255) for x in (r, g, b)), alpha

def color_of(parent, ph=None):
    """parent = element containing a colour child. Returns css colour or None."""
    if parent is None: return None
    for c in parent:
        n = etree.QName(c).localname
        if n == "srgbClr": base = c.get("val")
        elif n == "schemeClr":
            v = c.get("val")
            if v == "phClr":
                if ph is None: return None
                base = ph.lstrip("#")
            else:
                base = SCHEME.get(CLRMAP.get(v, v), "000000")
        elif n == "sysClr": base = c.get("lastClr", "000000")
        elif n == "prstClr": base = {"black": "000000", "white": "FFFFFF", "red": "FF0000"}.get(c.get("val"), "000000")
        elif n == "scrgbClr":
            base = "%02X%02X%02X" % tuple(round(int(c.get(k)) / 100000 * 255) for k in "rgb")
        else: continue
        hx, a = apply_mods(base, c)
        if a < 1:
            return "rgba(%d,%d,%d,%.2f)" % (int(hx[1:3], 16), int(hx[3:5], 16), int(hx[5:7], 16), a)
        return hx
    return None

# ---------------------------------------------------------------- media handling
_media_cache = {}
def media(path, crop=None):
    """Copy (and maybe crop) a media file into OUT/media, returning the relative url."""
    key = (path, crop)
    if key in _media_cache: return _media_cache[key]
    name = os.path.basename(path)
    base, ext = os.path.splitext(name)
    ext = ext.lower()
    if ext == ".wav":
        dst = os.path.join(MEDIA, base + ".mp3")
        if not os.path.exists(dst):
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-b:a", "160k", dst], check=True)
        url = "media/" + base + ".mp3"
    elif crop and ext in (".png", ".jpg", ".jpeg", ".gif") and any(crop):
        l, t, r, b = crop
        im = Image.open(path)
        W, H = im.size
        box = (round(W * l), round(H * t), round(W * (1 - r)), round(H * (1 - b)))
        box = (max(box[0], 0), max(box[1], 0), min(box[2], W), min(box[3], H))
        h = hashlib.md5(repr(crop).encode()).hexdigest()[:6]
        nm = "%s_c%s%s" % (base, h, ".png" if ext == ".gif" else ext)
        if box[2] > box[0] and box[3] > box[1]:
            im.crop(box).save(os.path.join(MEDIA, nm))
            url = "media/" + nm
        else:
            shutil.copy(path, os.path.join(MEDIA, name)); url = "media/" + name
    else:
        shutil.copy(path, os.path.join(MEDIA, name))
        url = "media/" + name
    _media_cache[key] = url
    return url

# ---------------------------------------------------------------- inheritance helpers
master = resolve_ac(parse(os.path.join(PRS, "slideMasters/slideMaster1.xml")))
TXSTYLE = {"title": master.find(".//p:titleStyle", NS), "body": master.find(".//p:bodyStyle", NS),
           "other": master.find(".//p:otherStyle", NS)}

def ph_info(sp):
    ph = sp.find(".//p:nvPr/p:ph", NS)
    if ph is None: return None
    return ph.get("type", "body"), ph.get("idx")

def find_ph(tree, typ, idx):
    cands = []
    for sp in tree.iter(Q("p:sp")):
        pi = ph_info(sp)
        if pi is None: continue
        t, i = pi
        norm = lambda x: "title" if x in ("title", "ctrTitle") else x
        if idx is not None and i == idx and typ not in ("title", "ctrTitle"): return sp
        if norm(t) == norm(typ): cands.append(sp)
    if cands: return cands[0]
    if typ in ("body", "subTitle", "obj"):
        for sp in tree.iter(Q("p:sp")):
            pi = ph_info(sp)
            if pi and pi[0] in ("body", "obj"): return sp
    return None

def xfrm_of(sp):
    x = sp.find("./p:spPr/a:xfrm", NS)
    if x is None: x = sp.find("./p:grpSpPr/a:xfrm", NS)
    if x is None: x = sp.find("./p:xfrm", NS)
    return x

def box_emu(x):
    off = x.find("a:off", NS); ext = x.find("a:ext", NS)
    return [int(off.get("x")), int(off.get("y")), int(ext.get("cx")), int(ext.get("cy"))]

class Ctx:  # per-slide context
    pass

def chain_for(sp, ctx):
    """lstStyle chain (most specific first) + txStyle kind."""
    chain = []
    ls = sp.find("./p:txBody/a:lstStyle", NS)
    if ls is not None: chain.append(ls)
    pi = ph_info(sp)
    kind = "other"
    if pi:
        t, i = pi
        kind = "title" if t in ("title", "ctrTitle") else "body"
        for tree in (ctx.layout, master):
            p = find_ph(tree, t, i)
            if p is not None:
                l2 = p.find("./p:txBody/a:lstStyle", NS)
                if l2 is not None: chain.append(l2)
    chain.append(TXSTYLE[kind])
    return chain, kind

def lvl_ppr(chain, lvl):
    out = []
    for ls in chain:
        x = ls.find("a:lvl%dpPr" % (lvl + 1), NS)
        if x is not None: out.append(x)
    return out

def inherited_bodypr(sp, ctx):
    res = {}
    pi = ph_info(sp)
    trees = []
    if pi:
        for tree in (master, ctx.layout):
            p = find_ph(tree, *pi)
            if p is not None: trees.append(p.find("./p:txBody/a:bodyPr", NS))
    trees.append(sp.find("./p:txBody/a:bodyPr", NS))
    for bp in trees:
        if bp is None: continue
        for k, v in bp.attrib.items(): res[k] = v
        for c in bp:
            n = etree.QName(c).localname
            if n in ("normAutofit", "spAutoFit", "noAutofit"):
                res["autofit"] = n; res["fontScale"] = c.get("fontScale"); res["lnSpcReduction"] = c.get("lnSpcReduction")
    return res

# ---------------------------------------------------------------- markdown text
MD_ESC = re.compile(r"([\\`*_\[\]{}<>$#|~^@])")
def md_escape(s):
    s = MD_ESC.sub(r"\\\1", s)
    s = re.sub(r" {2,}", lambda m: "\u00a0" * len(m.group()), s)   # keep PowerPoint spacing
    return s

def wrap_md(text, b, i):
    if not text.strip(): return text
    lead = text[:len(text) - len(text.lstrip())]; trail = text[len(text.rstrip()):]
    core = text.strip()
    if b and i: core = "***%s***" % core
    elif b: core = "**%s**" % core
    elif i: core = "*%s*" % core
    return lead + core + trail

WING = {"à": "➔", "è": "➔", "ð": "⇨", "ü": "✓", "û": "✗", "Ø": "➢", "§": "■", "l": "●", "n": "■", "q": "❑", "J": "☺", "ß": "⇦", "ç": "⬅", "ê": "⬆", "é": "⬇", "Þ": "➝"}

def run_props(r, defaults, ph_color):
    rp = r.find("a:rPr", NS)
    p = dict(defaults)
    if rp is not None:
        for k in ("b", "i"):
            if rp.get(k) is not None: p[k] = rp.get(k) == "1"
        if rp.get("u") is not None: p["u"] = rp.get("u") != "none"
        if rp.get("sz"): p["sz"] = int(rp.get("sz")) / 100
        if rp.get("baseline"): p["baseline"] = int(rp.get("baseline"))
        c = color_of(rp.find("a:solidFill", NS))
        if c: p["color"] = c
        if rp.find("a:hlinkClick", NS) is not None: p["u"] = True
    return p

def defaults_from(pprs, base):
    d = dict(base)
    for ppr in reversed(pprs):  # least specific first
        dr = ppr.find("a:defRPr", NS)
        if dr is None: continue
        for k in ("b", "i"):
            if dr.get(k) is not None: d[k] = dr.get(k) == "1"
        if dr.get("sz"): d["sz"] = int(dr.get("sz")) / 100
        if dr.get("cap"): d["cap"] = dr.get("cap")
        c = color_of(dr.find("a:solidFill", NS))
        if c: d["color"] = c
    return d

def para_attr(pprs, name, default=None):
    for ppr in pprs:
        if ppr.get(name) is not None: return ppr.get(name)
    return default

def bullet_of(pprs):
    for ppr in pprs:
        if ppr.find("a:buNone", NS) is not None: return None
        bc = ppr.find("a:buChar", NS)
        if bc is not None: return bc.get("char")
        if ppr.find("a:buAutoNum", NS) is not None: return "1."
    return None

def text_body(sp, ctx, frag_paras=None):
    """Return (markdown_lines, css dict, info) for the txBody of sp."""
    tb = sp.find("./p:txBody", NS)
    if tb is None: tb = sp.find("./a:txBody", NS)
    if tb is None: return None
    chain, kind = chain_for(sp, ctx)
    base = {"b": False, "i": False, "u": False, "sz": 18.0, "color": color_of(TXSTYLE["other"].find(".//a:defRPr/a:solidFill", NS)) or "#000000", "baseline": 0}
    style = sp.find("./p:style", NS)
    fontref = None
    if style is not None:
        fontref = color_of(style.find("a:fontRef", NS))
    bp = inherited_bodypr(sp, ctx)
    scale = int(bp.get("fontScale") or 100000) / 100000
    paras = []
    for pi_, p in enumerate(tb.findall("a:p", NS)):
        ppr = p.find("a:pPr", NS)
        lvl = int(ppr.get("lvl", 0)) if ppr is not None else 0
        pprs = ([ppr] if ppr is not None else []) + lvl_ppr(chain, lvl)
        if kind == "other" and fontref:
            d = defaults_from(pprs[-1:], base); d["color"] = fontref
            d = defaults_from(pprs[:-1], d)
        else:
            d = defaults_from(pprs, base)
        algn = para_attr(pprs, "algn", "l")
        bullet = bullet_of(pprs)
        runs = []
        for c in p:
            n = etree.QName(c).localname
            if n in ("r", "fld"):
                t = "".join(x.text or "" for x in c.findall("a:t", NS))
                sym = c.find("a:rPr/a:sym", NS)
                if sym is not None and "Wingdings" in sym.get("typeface", ""):
                    t = "".join(WING.get(chr(ord(ch) - 0xF000), ch) if ord(ch) >= 0xF000 else ch for ch in t)
                pr = run_props(c, d, None)
                lat = c.find("a:rPr/a:latin", NS)
                if (lat is not None and "Script" in lat.get("typeface", "") and t.strip().isalpha()
                        and t.strip().isupper() and len(t.strip()) <= 3):
                    # a capital typed in a script font ("French Script MT"): tensor notation, as in
                    # the equations (omml.py) → $\mathscr{X}$, same look everywhere
                    pr = dict(pr); pr["math"] = "".join(r"\mathscr{%s}" % ch for ch in t.strip())
                    t = ""
                runs.append((t, pr))
            elif n == "br":
                runs.append(("\n", run_props(c, d, None)))
            elif n == "m":  # a14:m
                om = c.find(".//m:oMathPara", NS)
                if om is None: om = c.find(".//m:oMath", NS)
                if om is not None:
                    pr = dict(d); pr["math"] = omml_to_latex(om)
                    pr["display"] = etree.QName(om).localname == "oMathPara"
                    # size of math: take from first m:r rPr a:rPr
                    ar = om.find(".//a:rPr", NS)
                    if ar is not None:
                        if ar.get("sz"): pr["sz"] = int(ar.get("sz")) / 100
                        if ar.get("i") is not None: pr["i"] = ar.get("i") == "1"
                        if ar.get("b") is not None: pr["b"] = ar.get("b") == "1"
                        cc = color_of(ar.find("a:solidFill", NS))
                        if cc: pr["color"] = cc
                    runs.append(("", pr))
        epr = p.find("a:endParaRPr", NS)
        esz = int(epr.get("sz")) / 100 if (epr is not None and epr.get("sz")) else d["sz"]
        lnspc = None
        for x in pprs:
            l = x.find("a:lnSpc/a:spcPct", NS)
            if l is not None: lnspc = int(l.get("val")) / 100000; break
        spcb = 0
        for x in pprs:
            sb = x.find("a:spcBef/a:spcPts", NS)
            if sb is not None: spcb = int(sb.get("val")) / 100; break
        spca = None
        for x in pprs:
            sa = x.find("a:spcAft/a:spcPts", NS)
            if sa is not None: spca = int(sa.get("val")) / 100; break
        marl = para_attr(pprs, "marL"); indent = para_attr(pprs, "indent")
        paras.append(dict(lvl=lvl, algn=algn, bullet=bullet, runs=runs, esz=esz, lnspc=lnspc, default=d, spcb=spcb,
                          spca=spca, marl=int(marl) / 9525 if marl is not None else None,
                          indent=int(indent) / 9525 if indent is not None else None, cap=d.get("cap")))
    if not any(r[0].strip() or r[1].get("math") for p in paras for r in p["runs"]):
        return None
    # dominant size / colour
    szc, colc = Counter(), Counter()
    for p in paras:
        for t, pr in p["runs"]:
            w = max(len(t.strip()), 1 if pr.get("math") else 0)
            szc[pr["sz"]] += w; colc[pr["color"]] += w
    dsz = szc.most_common(1)[0][0] if szc else 18
    dcol = colc.most_common(1)[0][0] if colc else base["color"]
    algns = Counter(p["algn"] for p in paras if p["runs"])
    dal = algns.most_common(1)[0][0] if algns else "l"
    # build markdown
    lines = []
    in_list = False
    bullets_used = Counter()
    for k, p in enumerate(paras):
        md = runs_md(p["runs"], dsz, dcol, scale)
        real = [r for r in p["runs"] if r[0].strip() or r[1].get("math")]
        if len(real) == 1 and real[0][1].get("display") and md.startswith("$") and md.endswith("$") and not md.startswith("$$"):
            md = "$" + md + "$"     # equation paragraph → display math (centred, like PowerPoint)
        frag = frag_paras.get(k) if frag_paras else None
        if frag and md.strip():
            for f in ([frag] if isinstance(frag, str) else frag[::-1]):   # outermost first in the list
                md = "[%s]{%s}" % (md, f)
        if not md.strip():
            if in_list: lines.append("")
            in_list = False
            gap = round(p["esz"] * scale * 4 / 3 * (p["lnspc"] or 1) * 1.2 + p["spcb"] * 4 / 3)
            lines.append('<div class="gap" style="height:%dpx"></div>' % gap)
            lines.append("")
            continue
        extra = ""
        if p["algn"] != dal and p["algn"] in ("ctr", "r"):
            md = "[%s]{.%s}" % (md, {"ctr": "pc", "r": "pr"}[p["algn"]])
        if p["bullet"]:
            bullets_used[(p["lvl"], p["bullet"])] += 1
            if not in_list and lines and lines[-1] != "": lines.append("")
            ind = "  " * p["lvl"] if p["lvl"] < 4 else "      "
            mark = "1." if p["bullet"] == "1." else "-"
            if p["lvl"] > 0 and not in_list:
                # orphan sub-level bullet: render as level class instead of nested list
                lines.append("- [%s]{.l%d}" % (md, min(p["lvl"], 2)))
            else:
                lines.append(ind + mark + " " + md.lstrip(" \t").replace("\n", "\\\n" + ind + "  "))
            in_list = True
        else:
            if in_list: lines.append("")
            in_list = False
            md = md.lstrip(" \t")
            if p["lvl"] > 0: md = "[%s]{.ind%d}" % (md, p["lvl"])
            lines.append(md.replace("\n", "\\\n"))
            lines.append("")
    while lines and lines[-1] == "": lines.pop()
    while lines and lines[-1].startswith('<div class="gap"'):
        lines.pop()
        while lines and lines[-1] == "": lines.pop()
    css = {"font-size": "%gpx" % round(dsz * scale * PT, 1), "color": dcol}
    if dal in ("ctr", "r", "just"): css["text-align"] = {"ctr": "center", "r": "right", "just": "justify"}[dal]
    ls = next((p["lnspc"] for p in paras if p["lnspc"]), None)
    if ls: css["line-height"] = "%.2f" % (1.2 * ls * (1 - int(bp.get("lnSpcReduction") or 0) / 100000))
    cls = []
    # list geometry of the template (= master of the thesis deck); other values → CSS variables
    LIST_DEFAULT = {"mar": [40.3, 96, 144, 192], "ind": [-40.3] * 4, "spcb": [10, 5, 5, 5]}
    for lv in range(4):
        ps = [p for p in paras if p["bullet"] and p["lvl"] == lv and p["runs"]]
        if not ps: continue
        for key, var, conv in (("marl", "mar", lambda v: v), ("indent", "ind", lambda v: v), ("spcb", "spcb", lambda v: v)):
            vals = Counter(round(p[key], 1) for p in ps if p[key] is not None)
            if not vals: continue
            v = vals.most_common(1)[0][0]
            if abs(v - LIST_DEFAULT[var][lv]) > 0.6:
                css["--talk-%s%d" % (var, lv + 1)] = "%gpx" % round(v * 4 / 3 if var == "spcb" else v, 1)
    sa = Counter(p["spca"] for p in paras if p["bullet"] and p["spca"] is not None)
    if sa and abs(sa.most_common(1)[0][0] - 2) > 0.3:
        css["--talk-spca"] = "%gpx" % round(sa.most_common(1)[0][0] * 4 / 3, 1)
    # all caps (PowerPoint cap="all", e.g. the title of the title layout)
    if paras and all(p["cap"] == "all" for p in paras if p["runs"]):
        cls.append("caps")
    # custom bullets
    for (lvl, ch), _ in bullets_used.items():
        # the master's markers (■ – ■ –) are "default": the deck then takes the template's
        # five markers (■ – • ○ ►); other characters are kept with a class
        std = {0: "■", 1: "–", 2: "■", 3: "–"}.get(lvl)
        if ch != std and ch != "1.":
            cls.append({"•": "b-dot", "-": "b-dash", "–": "b-dash", "■": "b-sq", "▪": "b-sq", "Ø": "b-arrow", "§": "b-sq", "o": "b-circ", "○": "b-circ", "►": "b-tri", "✓": "b-check"}.get(ch, "b-dot") + str(lvl))
    info = dict(kind=kind, bodypr=bp, has_bullets=bool(bullets_used))
    return lines, css, cls, info

def runs_md(runs, dsz, dcol, scale):
    # merge runs with identical formatting
    merged = []
    for t, pr in runs:
        key = (pr["b"], pr["i"], pr["u"], pr["sz"], pr["color"], pr.get("baseline", 0), pr.get("math"))
        if merged and merged[-1][1] == key and not pr.get("math") and t != "\n" and merged[-1][0] != "\n":
            merged[-1][0] += t
        else:
            merged.append([t, key])
    out = []
    for t, (b, i, u, sz, col, bl, math) in merged:
        if t == "\n":
            out.append("\n"); continue
        if math:
            s = "$%s$" % math.strip()
            if b: s = "**%s**" % s
        else:
            if not t: continue
            s = wrap_md(md_escape(t), b, i)
        st = []
        if col != dcol: st.append("color:%s" % col)
        if abs(sz - dsz) > 0.4: st.append("font-size:%gpx" % round(sz * scale * PT, 1))
        cls = []
        if u and not math: cls.append(".underline")
        if bl > 0 and not math:
            s = "^%s^" % s.strip().replace(" ", "\\ ")
        elif bl < 0 and not math:
            s = "~%s~" % s.strip().replace(" ", "\\ ")
        if st or cls:
            lead = s[:len(s) - len(s.lstrip())]; trail = s[len(s.rstrip()):]
            attrs = " ".join(cls + (['style="%s"' % ";".join(st)] if st else []))
            s = "%s[%s]{%s}%s" % (lead, s.strip(), attrs, trail)
        out.append(s)
    res = "".join(out)
    # glue: avoid '**a****b**' artefacts
    res = res.replace("****", "").replace("\n", "\n")
    # two inline equations separated only by spaces → one equation (PowerPoint never breaks the
    # line there; KaTeX is wider than Cambria Math and the browser would wrap between them)
    prev = None
    while prev != res:
        prev = res
        res = re.sub(r"(?<![$\\])\$([^$\n]+)\$([ \t]+)\$([^$\n]+)\$(?!\$)", lambda m: "$%s\\ %s$" % (m.group(1).rstrip(), m.group(3).lstrip()), res)
    return res

# ---------------------------------------------------------------- geometry
def fill_of(spPr, style, ctx):
    """css background or None ('none' when explicitly no fill)."""
    if spPr is None: return None
    for c in spPr:
        n = etree.QName(c).localname
        if n == "noFill": return "none"
        if n == "solidFill": return color_of(c)
        if n == "gradFill":
            stops = []
            for gs in c.findall("a:gsLst/a:gs", NS):
                stops.append("%s %g%%" % (color_of(gs), int(gs.get("pos")) / 1000))
            lin = c.find("a:lin", NS)
            ang = (int(lin.get("ang", 0)) / 60000 + 90) if lin is not None else 180
            return "linear-gradient(%gdeg, %s)" % (ang, ", ".join(stops))
        if n == "blipFill":
            emb = c.find("a:blip", NS).get(Q("r:embed"))
            return "url(%s) center/100%% 100%% no-repeat" % media(ctx.rels[emb])
        if n == "grpFill":
            return ctx.grpfill or "none"
    if style is not None:
        fr = style.find("a:fillRef", NS)
        if fr is not None and fr.get("idx") not in ("0", None):
            return color_of(fr)
    return None

def line_of(spPr, style):
    ln = spPr.find("a:ln", NS) if spPr is not None else None
    col, w, dash = None, None, "solid"
    if style is not None:
        lr = style.find("a:lnRef", NS)
        if lr is not None and lr.get("idx") not in ("0", None):
            col = color_of(lr); w = LNW[min(int(lr.get("idx")) - 1, len(LNW) - 1)]
    if ln is not None:
        if ln.find("a:noFill", NS) is not None: return None
        c = color_of(ln.find("a:solidFill", NS))
        if c: col = c
        if ln.get("w"): w = int(ln.get("w"))
        pd = ln.find("a:prstDash", NS)
        if pd is not None and pd.get("val") != "solid":
            dash = "dotted" if "Dot" in pd.get("val") and "Dash" not in pd.get("val") else "dashed"
            if pd.get("val") == "sysDot": dash = "dotted"
    if col is None: return None
    if w is None: w = 9525
    return dict(color=col, w=max(round(w * F, 2), 0.75), dash=dash, ln=ln)

def adj(sp, name, default):
    for gd in sp.findall(".//a:prstGeom/a:avLst/a:gd", NS):
        if gd.get("name") == name:
            m = re.search(r"val (-?\d+)", gd.get("fmla", ""))
            if m: return int(m.group(1))
    return default

def shade(hexc, f):
    if not hexc or not hexc.startswith("#"): return hexc
    r, g, b = (int(hexc[i:i + 2], 16) for i in (1, 3, 5))
    if f > 1:
        t = f - 1; r, g, b = (x + (255 - x) * t for x in (r, g, b))
    else:
        r, g, b = (x * f for x in (r, g, b))
    return "#%02X%02X%02X" % (round(r), round(g), round(b))

def svg_geom(prst, w, h, sp, fill, line):
    ss = min(w, h)
    paths = []  # (d, fill)
    if prst == "rightArrow":
        a1, a2 = adj(sp, "adj1", 50000) / 1e5, adj(sp, "adj2", 50000) / 1e5
        y1, y2, x1 = h / 2 - h * a1 / 2, h / 2 + h * a1 / 2, w - ss * a2
        paths.append(("M0,%g L%g,%g L%g,0 L%g,%g L%g,%g L%g,%g L0,%g Z" % (y1, x1, y1, x1, w, h / 2, x1, h, x1, y2, y2), fill))
    elif prst == "leftArrow":
        a1, a2 = adj(sp, "adj1", 50000) / 1e5, adj(sp, "adj2", 50000) / 1e5
        y1, y2, x1 = h / 2 - h * a1 / 2, h / 2 + h * a1 / 2, ss * a2
        paths.append(("M%g,%g L%g,%g L%g,%g L%g,%g L%g,%g L%g,%g L0,%g Z" % (w, y1, x1, y1, x1, 0, x1, 0, x1, h, x1, y2, h / 2), fill))
        paths[-1] = ("M%g,%g L%g,%g L%g,0 L0,%g L%g,%g L%g,%g L%g,%g Z" % (w, y1, x1, y1, x1, h / 2, x1, h, x1, y2, w, y2), fill)
    elif prst == "downArrow":
        a1, a2 = adj(sp, "adj1", 50000) / 1e5, adj(sp, "adj2", 50000) / 1e5
        x1, x2, y1 = w / 2 - w * a1 / 2, w / 2 + w * a1 / 2, h - ss * a2
        paths.append(("M%g,0 L%g,0 L%g,%g L%g,%g L%g,%g L0,%g L%g,%g Z" % (x1, x2, x2, y1, w, y1, w / 2, h, y1, x1, y1), fill))
    elif prst == "upArrow":
        a1, a2 = adj(sp, "adj1", 50000) / 1e5, adj(sp, "adj2", 50000) / 1e5
        x1, x2, y1 = w / 2 - w * a1 / 2, w / 2 + w * a1 / 2, ss * a2
        paths.append(("M%g,%g L%g,%g L%g,%g L%g,%g L%g,0 L0,%g L%g,%g Z" % (x1, h, x2, h, x2, y1, w, y1, w / 2, y1, x1, y1), fill))
    elif prst == "parallelogram":
        o = ss * adj(sp, "adj", 25000) / 1e5
        paths.append(("M%g,0 L%g,0 L%g,%g L0,%g Z" % (o, w, w - o, h, h), fill))
    elif prst == "trapezoid":
        o = ss * adj(sp, "adj", 25000) / 1e5
        paths.append(("M0,%g L%g,0 L%g,0 L%g,%g Z" % (h, o, w - o, w, h), fill))
    elif prst == "cube":
        d = ss * adj(sp, "adj", 25000) / 1e5
        f = fill if fill and fill != "none" else None
        paths.append(("M0,%g L%g,%g L%g,%g L0,%g Z" % (d, w - d, d, w - d, h, h), f or "none"))
        paths.append(("M0,%g L%g,0 L%g,0 L%g,%g Z" % (d, d, w, w - d, d), shade(f, 1.2) if f else "none"))
        paths.append(("M%g,%g L%g,0 L%g,%g L%g,%g Z" % (w - d, d, w, w, h - d, w - d, h), shade(f, 0.8) if f else "none"))
    elif prst == "bentArrow":
        a1, a2, a3, a4 = (adj(sp, n, dv) / 1e5 for n, dv in (("adj1", 25000), ("adj2", 25000), ("adj3", 25000), ("adj4", 43750)))
        th = ss * a1; hd = ss * a2; hl = ss * a3; rr = ss * a4
        y_c = hd  # centre line of horizontal shaft
        x0, x1 = 0, th
        yt, yb = y_c - th / 2, y_c + th / 2
        xh = w - hl
        r_out = rr; r_in = max(rr - th, 0)
        paths.append(("M0,%g L0,%g A%g,%g 0 0 1 %g,%g L%g,%g L%g,0 L%g,%g L%g,%g L%g,%g L%g,%g A%g,%g 0 0 0 %g,%g L%g,%g Z" % (
            h, yt + r_out, r_out, r_out, r_out, yt, xh, yt, xh, w, y_c, xh, 2 * y_c, xh, yb, th + r_in, yb, r_in, r_in, th, yb + r_in, th, h), fill))
    elif prst == "custom":
        return cust_path(sp, w, h, fill, line)
    elif prst in ("ellipse", "flowChartConnector"):
        return '<ellipse cx="%g" cy="%g" rx="%g" ry="%g" %s/>' % (w / 2, h / 2, w / 2, h / 2, stroke_attr(fill, line))
    else:
        return None
    return "".join('<path d="%s" %s/>' % (d, stroke_attr(f, line)) for d, f in paths)

def cust_path(sp, w, h, fill, line):
    import math
    out = []
    for path in sp.findall(".//a:custGeom/a:pathLst/a:path", NS):
        pw = int(path.get("w", 0)) or 1; ph = int(path.get("h", 0)) or 1
        kx, ky = w / pw, h / ph
        d = []; cur = (0, 0)
        for c in path:
            n = etree.QName(c).localname
            pts = [(int(p_.get("x")) * kx, int(p_.get("y")) * ky) for p_ in c.findall("a:pt", NS)]
            if n == "moveTo": d.append("M%.1f,%.1f" % pts[0]); cur = pts[0]
            elif n == "lnTo": d.append("L%.1f,%.1f" % pts[0]); cur = pts[0]
            elif n == "cubicBezTo": d.append("C" + " ".join("%.1f,%.1f" % q_ for q_ in pts)); cur = pts[-1]
            elif n == "quadBezTo": d.append("Q" + " ".join("%.1f,%.1f" % q_ for q_ in pts)); cur = pts[-1]
            elif n == "close": d.append("Z")
            elif n == "arcTo":
                wr, hr = int(c.get("wR")) * kx, int(c.get("hR")) * ky
                st, sw = int(c.get("stAng")) / 60000, int(c.get("swAng")) / 60000
                a0, a1 = math.radians(st), math.radians(st + sw)
                cx_, cy_ = cur[0] - wr * math.cos(a0), cur[1] - hr * math.sin(a0)
                ex, ey = cx_ + wr * math.cos(a1), cy_ + hr * math.sin(a1)
                d.append("A%.1f,%.1f 0 %d %d %.1f,%.1f" % (wr, hr, 1 if abs(sw) > 180 else 0, 1 if sw > 0 else 0, ex, ey)); cur = (ex, ey)
        f = fill if path.get("fill") != "none" else None
        ln_ = line if path.get("stroke") != "false" else None
        out.append('<path d="%s" %s/>' % (" ".join(d), stroke_attr(f, ln_)))
    return "".join(out) or None

def stroke_attr(fill, line):
    s = 'fill="%s"' % (fill if fill and fill != "none" and not fill.startswith(("linear", "url")) else "none")
    if line:
        s += ' stroke="%s" stroke-width="%g" vector-effect="non-scaling-stroke"' % (line["color"], line["w"])
        if line["dash"] == "dashed": s += ' stroke-dasharray="%g %g"' % (4 * line["w"], 3 * line["w"])
        if line["dash"] == "dotted": s += ' stroke-dasharray="%g %g"' % (line["w"], 2 * line["w"])
    return s

# ---------------------------------------------------------------- animations
def parse_timing(sld):
    """Return {spid: {'in': k, 'out': k, 'paras': {pidx: (kind,k)}}} for main-sequence click builds."""
    res = {}
    seq = sld.find(".//p:timing//p:cTn[@nodeType='mainSeq']", NS)
    if seq is None: return res, 0
    k = 0
    for grp in seq.findall("p:childTnLst/p:par", NS):
        effs = grp.findall(".//p:cTn[@presetClass]", NS)
        if not effs: continue
        first_nt = effs[0].get("nodeType")
        if first_nt == "clickEffect" or k > 0 or True:
            if first_nt == "clickEffect": k += 1
        # delay of each effect inside its click (PowerPoint "after previous" + delay): the
        # start condition of the sub-group that holds it, in ms
        when = {}
        has_media = any(e.get("presetClass") == "mediacall" for e in effs)
        for sub in grp.findall("p:cTn/p:childTnLst/p:par", NS):
            c = sub.find("p:cTn/p:stCondLst/p:cond", NS)
            dl = c.get("delay") if c is not None else "0"
            for e in sub.iter(Q("p:cTn")):
                when[id(e)] = int(dl) if dl and dl.isdigit() else 0
        for e in effs:
            cls = e.get("presetClass")
            if cls == "path":
                for mo in e.iter(Q("p:animMotion")):
                    nums = re.findall(r"-?\d+(?:\.\d+)?(?:E-?\d+)?", mo.get("path", ""), re.I)
                    if len(nums) >= 2:
                        dx, dy = float(nums[-2]) * 1280, float(nums[-1]) * 720
                        for tgt in e.findall(".//p:spTgt", NS):
                            res.setdefault(tgt.get("spid"), {"paras": {}}).setdefault("moves", []).append((k, dx, dy))
                        break
                continue
            if cls == "mediacall":      # PowerPoint "play" command → autoplay / trigger fragment
                for tgt in e.findall(".//p:spTgt", NS):
                    res.setdefault(tgt.get("spid"), {"paras": {}}).setdefault("media", []).append(k)
                continue
            if cls not in ("entr", "exit"): continue
            if k == 0 and cls == "entr":
                continue            # plays automatically when the slide opens → simply visible
            for tgt in e.findall(".//p:spTgt", NS):
                spid = tgt.get("spid")
                d = res.setdefault(spid, {"paras": {}})
                pr = tgt.find("p:txEl/p:pRg", NS)
                key = "in" if cls == "entr" else "out"
                if pr is not None:
                    for pi in range(int(pr.get("st")), int(pr.get("end")) + 1):
                        d["paras"].setdefault(pi, {})[key] = k
                else:
                    if key not in d:
                        d[key] = k
                        if key == "in" and when.get(id(e), 0) > 0:
                            # appears so long after the click; after a sound played at the same
                            # click, PowerPoint's delay is the sound's length → delay=end
                            d["delay"] = "end" if has_media else when[id(e)] / 1000
    return res, k

def frag_attrs(a):
    """attributes for an element with entrance index a['in'] (no exit)."""
    return ".fragment data-fragment-index=%d" % a

# ---------------------------------------------------------------- element emission
class Emitter:
    def __init__(self, ctx):
        self.ctx = ctx; self.lines = []; self.ids = Counter()

    def uid(self, sp):
        cnv = sp.find("./*/p:cNvPr", NS)
        spid = cnv.get("id") if cnv is not None else None
        if spid in self.ctx.idmap and self.ctx.idmap[spid] not in self.ids:
            self.ids[self.ctx.idmap[spid]] += 1
            return self.ctx.idmap[spid]
        cid = sp.find(".//a16:creationId", NS)
        name = sp.find("./*/p:cNvPr", NS)
        base = None
        if cid is not None:
            base = cid.get("id").strip("{}").split("-")[0].lower()
        elif name is not None:
            base = re.sub(r"[^A-Za-z0-9]+", "-", name.get("name", "x")).strip("-").lower()
        else: base = "el"
        self.ids[base] += 1
        return base if self.ids[base] == 1 else "%s-%d" % (base, self.ids[base])

    def box_px(self, x, T):
        bx, by, bw, bh = box_emu(x)
        ox, oy, sx, sy = T
        rot = (int(x.get("rot", 0)) / 60000) % 180
        if 45 <= rot < 135 and abs(sx - sy) > 1e-9:
            # rotated ~90°: the group scale applies to the visual (swapped) box
            cx, cy = ox + (bx + bw / 2) * sx, oy + (by + bh / 2) * sy
            w, h = bw * sy, bh * sx
            return (cx - w / 2, cy - h / 2, w, h)
        return (ox + bx * sx, oy + by * sy, bw * sx, bh * sy)

    def anim_wrap(self, sp, inner_attrs):
        """returns (extra classes/attrs for element, exit index or None)"""
        cnv = sp.find("./*/p:cNvPr", NS)
        spid = cnv.get("id") if cnv is not None else None
        a = self.ctx.anim.get(spid, {})
        att, out = "", None
        if a.get("in") is not None:
            att += " .fragment data-fragment-index=%d" % a["in"]
            if a.get("delay") == "end": att += " delay=end"
            elif a.get("delay"): att += " delay=%g" % round(a["delay"], 1)
        if a.get("out") is not None:
            if a.get("in") is not None and a["out"] >= a["in"]:
                out = a["out"]
            elif a.get("in") is None and a["out"] == 0:
                att += " .hidden-start"
            elif a.get("in") is None:
                att += " .fragment .fade-out data-fragment-index=%d" % a["out"]
        return att, out, a.get("paras", {})

    def emit(self, line=""):
        self.lines.append(line)

    def pos(self, l, t, w, h, with_h=True):
        s = "left=%d top=%d width=%d" % (round(l), round(t), max(round(w), 1))
        if with_h: s += " height=%d" % max(round(h), 1)
        return s

    def walk(self, tree, T):
        for el in tree:
            if not isinstance(el.tag, str): continue
            n = etree.QName(el).localname
            cnv = el.find("./*/p:cNvPr", NS)
            if cnv is not None and cnv.get("hidden") == "1": continue
            moves = self.ctx.anim.get(cnv.get("id") if cnv is not None else None, {}).get("moves", [])
            for (k, dx, dy) in moves:   # PowerPoint motion path → translate fragment wrapper
                self.emit('::: {.absolute .fragment .move data-fragment-index=%d style="left:0;top:0;width:100%%;height:100%%;--dx:%dpx;--dy:%dpx"}' % (k, round(dx), round(dy)))
                self.emit("")
            self._walk_one(el, n, T)
            for _ in moves:
                self.close_div(1)

    def _walk_one(self, el, n, T):
        if True:
            if n == "sp": self.shape(el, T)
            elif n == "pic": self.pic(el, T)
            elif n == "cxnSp": self.shape(el, T, connector=True)
            elif n == "grpSp": self.group(el, T)
            elif n == "graphicFrame": self.frame(el, T)

    def cpos(self, l, t, w, h, with_h=True):
        s = "left:%dpx;top:%dpx;width:%dpx" % (round(l), round(t), max(round(w), 1))
        if with_h: s += ";height:%dpx" % max(round(h), 1)
        return s

    def open_div(self, sp, attrs, l, t, w, h, style="", with_h=True):
        a, out, paras = self.anim_wrap(sp, attrs)
        did = self.uid(sp)
        pos = self.cpos(l, t, w, h, with_h)
        if out is not None:
            self.emit(':::: {.absolute%s data-id="%s" style="%s"}' % (a, did + "-w", pos))
            self.emit('::: {%s .fragment .fade-out data-fragment-index=%d data-id="%s" style="width:100%%;height:100%%;%s"}' % (attrs, out, did, style))
            return 2, paras
        if "transform:" in style:
            # own CSS transform (rotation/flip) on an inner box: reveal.js auto-animate
            # overrides the transform of the elements it animates (morph slides)
            self.emit(':::: {.absolute%s data-id="%s" style="%s"}' % (a, did, pos))
            self.emit('::: {%s style="width:100%%;height:100%%;%s"}' % (attrs, style))
            return 2, paras
        self.emit('::: {.absolute %s%s data-id="%s" style="%s%s"}' % (attrs, a, did, pos, (";" + style) if style else ""))
        return 1, paras

    def close_div(self, n):
        if self.lines and self.lines[-1] != "": self.emit("")
        for _ in range(n): self.emit(":::")
        self.emit("")

    def shape(self, sp, T, connector=False):
        ctx = self.ctx
        pi = ph_info(sp)
        if pi and pi[0] in ("sldNum", "dt", "ftr"): return
        x = xfrm_of(sp)
        if x is None and pi:
            for tree in (ctx.layout, master):
                p = find_ph(tree, *pi)
                if p is not None and xfrm_of(p) is not None:
                    x = xfrm_of(p); break
        if x is None: return
        l, t, w, h = self.box_px(x, T)
        spPr = sp.find("p:spPr", NS); style = sp.find("p:style", NS)
        geom = sp.find("p:spPr/a:prstGeom", NS)
        prst = geom.get("prst") if geom is not None else ("rect" if not connector else "line")
        if geom is None and sp.find("p:spPr/a:custGeom", NS) is not None: prst = "custom"
        fill = fill_of(spPr, style, ctx)
        line = line_of(spPr, style) if spPr is not None else None
        rot = int(x.get("rot", 0)) / 60000
        flipH, flipV = x.get("flipH") == "1", x.get("flipV") == "1"
        # ---- title placeholder → heading (if at default spot) or styled absolute div
        is_title = pi and pi[0] in ("title", "ctrTitle")
        if is_title and not ctx.title_done:
            tb = text_body(sp, ctx)
            if tb is None: return
            lines, css, cls, info = tb
            txt = " ".join(s for s in lines if s and not s.startswith('<div class="gap"'))
            dflt = abs(l - 144) < 6 and abs(t - 72) < 6 and abs(w - 1008) < 6 and pi[0] == "title" and abs(float(css["font-size"][:-2]) - 44 * PT) < 1
            a, out, _ = self.anim_wrap(sp, "")
            if dflt and not a and out is None and not ctx.anim.get(sp.find("./*/p:cNvPr", NS).get("id"), {}).get("moves") and "\\\n" not in txt and len(lines) == 1 and css.get("color", "").upper() == "#1A2E40":
                ctx.heading = txt; ctx.title_done = True
                return
        # ---- lines / connectors
        if prst in ("line", "straightConnector1", "bentConnector3", "curvedConnector3", "bentConnector2") or connector:
            if not line: return
            x1, y1, x2, y2 = (w, 0, 0, h) if flipH and not flipV else (0, h, w, 0) if flipV and not flipH else (w, h, 0, 0) if flipH and flipV else (0, 0, w, h)
            pad = 8
            lnel = line["ln"]
            mk, defs = "", ""
            mid = "m" + hashlib.md5(etree.tostring(sp)).hexdigest()[:8]
            for end in ("head", "tail"):
                e = lnel.find("a:%sEnd" % end, NS) if lnel is not None else None
                if e is not None and e.get("type") not in (None, "none"):
                    sc = {"sm": 2, "med": 3, "lg": 5}
                    ms = max(sc.get(e.get("w", "med"), 3) * line["w"], 6)
                    typ = e.get("type")
                    shape_ = {"oval": '<circle cx="5" cy="5" r="5" fill="%s"/>', "diamond": '<path d="M0,5 L5,0 L10,5 L5,10 z" fill="%s"/>',
                              "arrow": '<path d="M0,0 L10,5 L0,10" fill="none" stroke="%s" stroke-width="1.5"/>'}.get(typ, '<path d="M0,0 L10,5 L0,10 z" fill="%s"/>') % line["color"]
                    if typ in ("oval", "diamond"): ms = max(ms * 0.8, 6)
                    defs += ('<marker id="%s%s" viewBox="0 0 10 10" refX="%s" refY="5" markerWidth="%g" markerHeight="%g" markerUnits="userSpaceOnUse" orient="auto-start-reverse">'
                             '%s</marker>') % (mid, end, "5" if typ in ("oval", "diamond") else "9", ms, ms, shape_)
                    mk += ' marker-%s="url(#%s%s)"' % ("start" if end == "head" else "end", mid, end)
            dash = ""
            if line["dash"] == "dashed": dash = ' stroke-dasharray="%g %g"' % (4 * line["w"], 3 * line["w"])
            if line["dash"] == "dotted": dash = ' stroke-dasharray="%g %g"' % (line["w"], 2 * line["w"])
            svg = ('<svg class="ln" width="%g" height="%g" viewBox="%g %g %g %g" overflow="visible">%s'
                   '<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="%g"%s%s/></svg>') % (
                round(w) + 2 * pad, round(h) + 2 * pad, -pad, -pad, round(w) + 2 * pad, round(h) + 2 * pad,
                ("<defs>%s</defs>" % defs) if defs else "", round(x1, 1), round(y1, 1), round(x2, 1), round(y2, 1), line["color"], line["w"], dash, mk)
            n, _ = self.open_div(sp, ".ln-box", l - pad, t - pad, w + 2 * pad, h + 2 * pad, with_h=True)
            self.emit(svg)
            self.close_div(n)
            return
        # ---- generic shape: box + optional svg geometry + text
        _, _, paras_anim = self.anim_wrap(sp, "")
        cnv_ = sp.find("./*/p:cNvPr", NS)
        shape_in = self.ctx.anim.get(cnv_.get("id") if cnv_ is not None else None, {}).get("in")
        frag_paras = {}
        for pidx, d in paras_anim.items():
            if d.get("in") is not None and d.get("in") == shape_in:
                d = dict(d, **{"in": None})          # appears with its box: nothing of its own
                if d.get("out") is None: continue
            if d.get("in") is not None and d.get("out") is not None:
                if d["out"] == d["in"] + 1:          # reveal hides it at the next step
                    frag_paras[pidx] = ".fragment .fade-in-then-out data-fragment-index=%d" % d["in"]
                else:                                # appears at in, vanishes at out: two nested spans
                    frag_paras[pidx] = [".fragment data-fragment-index=%d" % d["in"],
                                        ".fragment .fade-out data-fragment-index=%d" % d["out"]]
            elif d.get("in") is not None:
                frag_paras[pidx] = ".fragment data-fragment-index=%d" % d["in"]
            elif d.get("out") == 0:
                frag_paras[pidx] = ".hidden-start"
            elif d.get("out") is not None:
                frag_paras[pidx] = ".fragment .fade-out data-fragment-index=%d" % d["out"]
        tb = text_body(sp, ctx, frag_paras)
        styles = []
        classes = [".tb" if tb else ".shp"]
        svg = None
        if prst in ("rect", "roundRect", "snip1Rect", "round2SameRect", "flowChartProcess", "flowChartAlternateProcess") or prst is None:
            if fill and fill != "none": styles.append("background:%s" % fill)
            if line:
                styles.append("border:%gpx %s %s" % (line["w"], line["dash"], line["color"]))
            if prst in ("roundRect", "flowChartAlternateProcess"):
                styles.append("border-radius:%gpx" % round(min(w, h) * adj(sp, "adj", 16667) / 1e5, 1))
        else:
            svg = svg_geom(prst, round(w, 1), round(h, 1), sp, fill if fill != "none" else None, line)
            if svg is None:  # unknown geometry: fall back to a box
                if fill and fill != "none": styles.append("background:%s" % fill)
                if line: styles.append("border:%gpx solid %s" % (line["w"], line["color"]))
        tr = []
        if rot: tr.append("rotate(%gdeg)" % rot)
        if flipH: tr.append("scaleX(-1)")
        if flipV: tr.append("scaleY(-1)")
        if tr: styles.append("transform:%s" % " ".join(tr))
        if not tb and not styles and not svg: return
        with_h = True
        if tb:
            lines, css, cls, info = tb
            classes += ["." + c for c in cls]
            bp = info["bodypr"]
            anchor = bp.get("anchor", "t")
            if anchor in ("ctr", "b"): classes.append(".va-" + anchor)
            ins = [int(bp.get(k, d)) * F for k, d in (("tIns", 45720), ("rIns", 91440), ("bIns", 45720), ("lIns", 91440))]
            styles.append("padding:%s" % " ".join("%gpx" % round(v, 1) for v in ins))
            for k, v in css.items(): styles.append("%s:%s" % (k, v))
            if bp.get("wrap") == "none": styles.append("white-space:nowrap")
            if bp.get("vert") in ("vert270",): classes.append(".v270")
            if bp.get("vert") in ("vert", "eaVert"): classes.append(".v90")
            if info["kind"] == "title": classes.append(".ttl")
            if info["bodypr"].get("autofit") == "spAutoFit" and not (fill and fill != "none") and not line and anchor == "t":
                with_h = False
            if flipH and tb:  # text should not mirror
                styles = [s for s in styles if not s.startswith("transform")]
        n, _ = self.open_div(sp, " ".join(classes), l, t, w, h, ";".join(styles), with_h)
        if svg:
            self.emit('<svg class="geom" viewBox="0 0 %g %g" preserveAspectRatio="none" overflow="visible">%s</svg>' % (round(w, 1), round(h, 1), svg))
            self.emit("")
        if tb:
            for ln_ in tb[0]: self.emit(ln_)
        self.close_div(n)

    def pic(self, pic, T):
        ctx = self.ctx
        x = xfrm_of(pic)
        if x is None: return
        l, t, w, h = self.box_px(x, T)
        blip = pic.find(".//a:blip", NS)
        if blip is None: return
        emb = blip.get(Q("r:embed"))
        svgb = blip.find(".//asvg:svgBlip", NS)
        src = ctx.rels.get(emb)
        sr = pic.find(".//a:srcRect", NS)
        crop = None
        if sr is not None:
            crop = tuple(int(sr.get(k, 0)) / 1e5 for k in ("l", "t", "r", "b"))
            if not any(crop): crop = None
        if svgb is not None and not crop:
            src = ctx.rels.get(svgb.get(Q("r:embed")), src)
        if not src or not os.path.exists(src): return
        url = media(src, crop)
        attrs = []
        audio = pic.find(".//p:nvPr/p:extLst//p14:media", NS)
        af = pic.find(".//p:nvPr/a:audioFile", NS)
        vf = pic.find(".//p:nvPr/a:videoFile", NS)
        mtarget = None
        if audio is not None: mtarget = ctx.rels.get(audio.get(Q("r:embed")))
        elif af is not None: mtarget = ctx.rels.get(af.get(Q("r:link")))
        tr = []
        rot = int(x.get("rot", 0)) / 60000
        if rot: tr.append("rotate(%gdeg)" % rot)
        if x.get("flipH") == "1": tr.append("scaleX(-1)")
        if x.get("flipV") == "1": tr.append("scaleY(-1)")
        cam = pic.find(".//a:scene3d/a:camera/a:rot", NS)
        if cam is not None:      # PowerPoint 3-D rotation → CSS 3D transform (talk filter: rotate-x/y/z)
            def deg(v):
                d = int(v or 0) / 60000.0
                return d - 360 if d > 180 else d
            # fitted on the PhD deck (Q matrix): in-plane angle = rev − rot + 180
            rz = (deg(cam.get("rev")) - (rot - 360 if rot > 180 else rot) + 180 + 180) % 360 - 180
            attrs.append("rotate-y=%.1f rotate-x=%.1f rotate-z=%.1f" % (deg(cam.get("lon")), deg(cam.get("lat")), rz))
            tr = [t_ for t_ in tr if not t_.startswith("rotate(")]
        a, out, _ = self.anim_wrap(pic, "")
        did = self.uid(pic)
        if mtarget and os.path.exists(mtarget):
            murl = media(mtarget)
            if vf is not None:
                line = '<video class="absolute" style="left:%dpx;top:%dpx;width:%dpx;height:%dpx" src="%s" controls></video>' % (l, t, w, h, murl)
                self.emit(line); self.emit(""); return
            attrs.append('.audio-btn data-audio="%s"' % murl)
            cnv_ = pic.find("./*/p:cNvPr", NS)
            an = self.ctx.anim.get(cnv_.get("id") if cnv_ is not None else None, {})
            appear = an.get("in", 0)
            for kk in an.get("media", []):
                if kk == appear:             # played when the icon appears (or when the slide opens)
                    attrs.append("data-autoplay=true")
                else:                        # played on its own click
                    attrs.append('#aud-%s' % did)
                    self.ctx.triggers.append((kk, "aud-%s" % did))
        st = ' style="transform:%s"' % " ".join(tr) if tr else ""
        if tr:
            st = ' style="%s;transform:%s"' % (self.cpos(l, t, w, h), " ".join(tr))
        # a sound object becomes the template's speaker icon (an empty span the filter fills),
        # placed at the top left of the PowerPoint picture; other pictures stay images
        is_audio = any(x_.startswith(".audio-btn") for x_ in attrs)
        def obj(attr_str):
            return ("[]{%s}" % attr_str) if is_audio else ("![](%s){%s}" % (url, attr_str))
        if is_audio:
            tr = []; st = ""
        if out is not None:
            self.emit(':::: {.absolute %s%s data-id="%s"}' % (self.pos(l, t, w, h), a, did + "-w"))
            self.emit(obj('.fragment .fade-out data-fragment-index=%d %s%s' % (out, " ".join(attrs), "" if is_audio else ' style="width:100%;height:100%"')))
            self.emit("::::"); self.emit(""); return
        if tr:
            self.emit(':::: {.absolute%s data-id="%s" style="%s"}' % (a, did, self.cpos(l, t, w, h)))
            self.emit(obj('%s style="width:100%%;height:100%%;transform:%s"' % (" ".join(attrs), " ".join(tr))))
            self.emit("::::"); self.emit(""); return
        if is_audio:
            self.emit(obj('.absolute left=%d top=%d%s %s data-id="%s"' % (round(l), round(t), a, " ".join(attrs), did)))
        else:
            self.emit(obj('.absolute %s%s %s data-id="%s"%s' % (self.pos(l, t, w, h), a, " ".join(attrs), did, st)))
        self.emit("")

    def group(self, g, T):
        x = g.find("p:grpSpPr/a:xfrm", NS)
        bx, by, bw, bh = box_emu(x)
        ch = x.find("a:chOff", NS); ce = x.find("a:chExt", NS)
        cx, cy, cw, chh = int(ch.get("x")), int(ch.get("y")), int(ce.get("cx")), int(ce.get("cy"))
        ox, oy, sx, sy = T
        l, t, w, h = ox + bx * sx, oy + by * sy, bw * sx, bh * sy
        ksx = sx * (bw / cw if cw else 1); ksy = sy * (bh / chh if chh else 1)
        old = self.ctx.grpfill
        gf = fill_of(g.find("p:grpSpPr", NS), None, self.ctx)
        if gf and gf != "none": self.ctx.grpfill = gf
        n, _ = self.open_div(g, ".grp", l, t, w, h)
        self.walk(g, (-cx * ksx, -cy * ksy, ksx, ksy))
        self.close_div(n)
        self.ctx.grpfill = old

    def frame(self, gf, T):
        tbl = gf.find(".//a:tbl", NS)
        x = gf.find("p:xfrm", NS)
        if tbl is None or x is None: return
        l, t, w, h = self.box_px(x, T)
        cols = [int(c.get("w")) * F for c in tbl.findall("a:tblGrid/a:gridCol", NS)]
        tpr = tbl.find("a:tblPr", NS)
        first = tpr is not None and tpr.get("firstRow") == "1"
        band = tpr is not None and tpr.get("bandRow") == "1"
        html = ['<table class="ptbl%s%s">' % (" first-row" if first else "", " band-row" if band else "")]
        for tr in tbl.findall("a:tr", NS):
            html.append('<tr style="height:%dpx">' % (int(tr.get("h")) * F))
            for ci, tc in enumerate(tr.findall("a:tc", NS)):
                if tc.get("hMerge") == "1" or tc.get("vMerge") == "1": continue
                tcpr = tc.find("a:tcPr", NS)
                bg = color_of(tcpr.find("a:solidFill", NS)) if tcpr is not None else None
                txt = []
                for p in tc.findall("a:txBody/a:p", NS):
                    s = "".join(r.text or "" for r in p.iter(Q("a:t")))
                    b = any(rp.get("b") == "1" for rp in p.iter(Q("a:rPr")))
                    sz = next((int(rp.get("sz")) / 100 for rp in p.iter(Q("a:rPr")) if rp.get("sz")), 14)
                    col = next((color_of(rp.find("a:solidFill", NS)) for rp in p.iter(Q("a:rPr")) if rp.find("a:solidFill", NS) is not None), None)
                    stl = "font-size:%gpx;%s%s" % (round(sz * PT, 1), "font-weight:bold;" if b else "", ("color:%s;" % col) if col else "")
                    txt.append('<span style="%s">%s</span>' % (stl, s.replace("&", "&amp;").replace("<", "&lt;")))
                span = ' colspan="%s"' % tc.get("gridSpan") if tc.get("gridSpan") else ""
                html.append('<td%s style="width:%dpx;%s">%s</td>' % (span, cols[ci] if ci < len(cols) else 0, ("background:%s" % bg) if bg else "", "<br>".join(txt)))
            html.append("</tr>")
        html.append("</table>")
        n, _ = self.open_div(gf, ".tbl", l, t, w, h)
        self.emit("".join(html))
        self.close_div(n)

# ---------------------------------------------------------------- slides
pres = parse(os.path.join(PRS, "presentation.xml"))
prels = rels(os.path.join(PRS, "presentation.xml"))
order = [prels[s.get(Q("r:id"))] for s in pres.findall(".//p:sldIdLst/p:sldId", NS)]
SKIP = {int(x) for x in os.environ.get("SKIP", "").split(",") if x}
BACKUP_FROM = int(os.environ.get("BACKUP_FROM", "0") or 0)
TEST = {int(x) for x in os.environ.get("TEST", "").split(",") if x}      # test slides (clicker / sound check)

slides = []
for n, path in enumerate(order, 1):
    sld = resolve_ac(parse(path))
    sr = rels(path)
    trans = sld.find("p:transition", NS)
    tkind, tdir = None, None
    if trans is not None:
        for c in trans.iter():
            ln_ = etree.QName(c).localname
            if ln_ in ("morph", "push", "fade", "wipe", "split", "cover", "pull", "zoom"):
                tkind = ln_; tdir = c.get("dir"); break
    slides.append(dict(n=n, path=path, sld=sld, rels=sr, trans=tkind,
                       tdir={"u": "up", "d": "down", "r": "right", "l": "left"}.get(tdir if trans is not None and tkind else None, "left")))

# morph chains → auto-animate ids
chain_id, cid = {}, 0
for i, s in enumerate(slides):
    if s["trans"] == "morph" and i > 0:
        prev = slides[i - 1]["n"]
        if prev not in chain_id:
            cid += 1; chain_id[prev] = cid
        chain_id[s["n"]] = chain_id[prev]

# ---------------------------------------------------------------- morph matching
# PowerPoint's Morph pairs objects by name, then by identical text / picture / look.
# We reproduce that and give paired objects the same data-id so reveal.js
# auto-animate moves them exactly like Morph does.
def signature(el, srels):
    n = etree.QName(el).localname
    cnv = el.find("./*/p:cNvPr", NS)
    name = cnv.get("name", "") if cnv is not None else ""
    txt = " ".join("".join(t.text or "" for t in p.iter(Q("a:t"))) for p in el.iter(Q("a:p"))).strip()
    omath = "".join(t.text or "" for t in el.iter(Q("m:t")))
    img = None
    if n == "pic":
        b = el.find(".//a:blip", NS)
        if b is not None: img = srels.get(b.get(Q("r:embed")))
    geom = el.find(".//a:prstGeom", NS)
    g = geom.get("prst") if geom is not None else n
    spPr = el.find("p:spPr", NS)
    fill = None
    if spPr is not None:
        sf = spPr.find("a:solidFill", NS)
        fill = color_of(sf) if sf is not None else None
    x = xfrm_of(el)
    c = None
    if x is not None:
        bx, by, bw, bh = box_emu(x); c = (bx + bw / 2, by + bh / 2, bw, bh)
    pi = ph_info(el) if n == "sp" else None
    return dict(id=cnv.get("id") if cnv is not None else None, name=name, kind=n, text=txt + "|" + omath,
                img=img, geom=g, fill=fill, c=c, ph=pi[0] if pi else None)

def default_uid(el):
    cid = el.find(".//a16:creationId", NS)
    if cid is not None: return cid.get("id").strip("{}").split("-")[0].lower()
    cnv = el.find("./*/p:cNvPr", NS)
    return re.sub(r"[^A-Za-z0-9]+", "-", cnv.get("name", "x") if cnv is not None else "el").strip("-").lower()

def top_elements(sld):
    return [e for e in sld.find("p:cSld/p:spTree", NS) if isinstance(e.tag, str)
            and etree.QName(e).localname in ("sp", "pic", "grpSp", "cxnSp", "graphicFrame")]

IDMAP = {}  # slide n -> {spid: id}
for i, s_ in enumerate(slides):
    if s_["trans"] != "morph" or i == 0: continue
    A, B = slides[i - 1], s_
    amap = IDMAP.get(A["n"], {})
    ae = [(e, signature(e, A["rels"])) for e in top_elements(A["sld"])]
    be = [(e, signature(e, B["rels"])) for e in top_elements(B["sld"])]
    ae = [x for x in ae if x[1]["ph"] not in ("sldNum", "dt", "ftr")]
    be = [x for x in be if x[1]["ph"] not in ("sldNum", "dt", "ftr")]
    used, bmap = set(), {}
    def dist(a, b):
        if not a["c"] or not b["c"]: return 1e18
        return (a["c"][0] - b["c"][0]) ** 2 + (a["c"][1] - b["c"][1]) ** 2
    rules = [
        lambda a, b: a["name"] == b["name"] and a["name"].startswith("!!"),
        lambda a, b: a["ph"] and a["ph"] == b["ph"] and a["ph"] in ("title", "ctrTitle"),
        lambda a, b: a["kind"] == b["kind"] and a["text"] != "|" and a["text"] == b["text"],
        lambda a, b: a["kind"] == "pic" and b["kind"] == "pic" and a["img"] == b["img"],
        lambda a, b: a["kind"] == b["kind"] and a["text"] == "|" == b["text"] and a["geom"] == b["geom"] and a["fill"] == b["fill"],
        lambda a, b: a["kind"] == b["kind"] and a["name"] == b["name"] and a["kind"] != "pic",
    ]
    for rule in rules:
        for be_el, bs in be:
            if bs["id"] in bmap: continue
            cands = [(dist(as_, bs), ae_el, as_) for ae_el, as_ in ae if as_["id"] not in used and rule(as_, bs)]
            if not cands: continue
            _, ae_el, as_ = min(cands, key=lambda t: t[0])
            used.add(as_["id"])
            bmap[bs["id"]] = amap.get(as_["id"], default_uid(ae_el))
    # unmatched A ids that B inherited must stay unique: fine, ids are per slide
    IDMAP[B["n"]] = bmap
    # make sure A uses the ids we referenced (default ids unless A itself was mapped)
    IDMAP.setdefault(A["n"], {})
print("morph pairs matched:", {k: len(v) for k, v in IDMAP.items() if v})

out = []
APPENDIX_DONE = False
TITLE_SEEN = False
for s in slides:
    if s["n"] in SKIP: continue
    sld = s["sld"]
    ctx = Ctx(); ctx.rels = s["rels"]; ctx.grpfill = None; ctx.idmap = IDMAP.get(s["n"], {})
    lay_path = [v for v in s["rels"].values() if "slideLayout" in v][0]
    ctx.layout = resolve_ac(parse(lay_path)); ctx.layout_rels = rels(lay_path)
    ctx.anim, nclicks = parse_timing(sld)
    ctx.heading = ""; ctx.title_done = False
    em = Emitter(ctx)
    # layout decoration for title-layout slides
    lname = ctx.layout.find("p:cSld", NS).get("name")
    attrs = []
    is_title = ctx.layout.get("type") == "title" or lname == "Diapositive de titre"
    if is_title:
        # title layout → the template's title slide, filled from the YAML (tools/_header.yml:
        # title, author, institute, subtitle, date, talk: title-slide: {note, logos}); a later
        # one (closing slide) shows the title and the logos only. Only the notes are kept.
        attrs.append(".title-slide")
        if TITLE_SEEN: attrs.append('parts="title logos"')
        TITLE_SEEN = True
    else:
        ctx.triggers = []
        em.walk(sld.find("p:cSld/p:spTree", NS), (0, 0, F, F))
        for kk, aid in ctx.triggers:
            em.emit('[]{.fragment data-fragment-index=%d data-play="%s"}' % (kk, aid))
            em.emit("")
    bg = sld.find("p:cSld/p:bg", NS)
    bgc = None
    if bg is not None and not is_title: bgc = color_of(bg.find(".//a:solidFill", NS)) or color_of(bg.find("p:bgRef", NS))
    if bgc: attrs.append('background-color="%s"' % bgc)
    if s["n"] in chain_id:
        attrs.append('auto-animate=true auto-animate-id="m%d" auto-animate-duration=1.2' % chain_id[s["n"]])
    if s["trans"] == "push": attrs.append('push=%s' % s["tdir"])     # template push transition (both slides move)
    if s["n"] in TEST: attrs.append('.test-slide')                          # numbered "test slide"
    if BACKUP_FROM and s["n"] >= BACKUP_FROM and not APPENDIX_DONE:
        # appendix marker at the end of the last counted slide: every slide after it is numbered
        # additional-1, additional-2, … (template feature, like LaTeX \appendix)
        out += ["::: {.appendix}", ":::", "",
                "<!-- ↑ APPENDIX: every slide below is numbered additional-1, additional-2, … -->", ""]
        APPENDIX_DONE = True
    head = "## %s" % ctx.heading if ctx.heading else "##"
    attrs.insert(0, "#s%02d" % s["n"])
    out.append("%s {%s}" % (head, " ".join(attrs)))
    out.append("")
    out.append("<!-- pptx slide %d -->" % s["n"])
    out.append("")
    out += em.lines
    # notes
    npath = [v for v in s["rels"].values() if "notesSlide" in v]
    if npath:
        nt = parse(npath[0])
        for sp in nt.iter(Q("p:sp")):
            pi = ph_info(sp)
            if pi and pi[0] == "body":
                ps = ["".join(t.text or "" for t in p.iter(Q("a:t"))) for p in sp.findall(".//a:p", NS)]
                txt = "\n\n".join(md_escape(p) for p in ps if p.strip())
                if txt.strip():
                    out += ["::: notes", txt, ":::", ""]
    out.append("")

body = "\n".join(out)
body = re.sub(r"\n{3,}", "\n\n", body)
with open(os.path.join(OUT, "slides.md"), "w") as f:
    f.write(body)
hdr = os.path.join(OUT, "_header.yml")
if os.path.exists(hdr):   # assemble the final deck
    with open(os.path.join(OUT, "index.qmd"), "w") as f:
        f.write(open(hdr).read() + body)
print("slides:", len(slides), "chains:", cid)
