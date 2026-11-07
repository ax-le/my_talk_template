"""Last step of build_deck.sh: make the generated deck short and readable.

The converter writes every value explicitly (style="left:…;top:…;padding:…;font-size:…px;
color:…"). The template has defaults for the usual cases and short attributes for the rest, so
this pass rewrites each attribute block:

  style="left:144px;top:184px;width:1008px;height:76px"   →  left=144 top=184 width=1008 height=76
  default inner margin of a text box (4.8px 9.6px)        →  dropped (CSS default of .tb)
  title / content placeholder / text box defaults         →  .ttl / .body / .tb  (44 / 20 / 18 pt)
  font-size:22.3px                                        →  size=18   (points, × --talk-pt)
  color:#1A2E40 / #69A1AB / #EBE7DD / #000000             →  color=text / accent / background / black
  text-align:center                                       →  align=center
  background / border / border-radius                     →  background= / border= / radius=
  white-space:nowrap                                      →  .nowrap
  data-id used by a single element (no Morph partner)     →  dropped
  a group (.grp) holding a single object                  →  that object, at its absolute place
  a picture fading out under one fading in, same place     →  stays (no dark flash in the fade)

Only blocks that contain style= or data-id= are touched (so LaTeX like \\sqrt[3]{x} is safe).
usage: python3 tidy.py slides.md        (in place)
"""
import re
import sys
from collections import Counter

sys.path.insert(0, __import__("os").path.dirname(__file__))
from shared import parse, fmt, PT, theme_names          # noqa: E402

NAMES = dict(theme_names(), **{"#000000": "black", "#FFFFFF": "white"})
TB_PAD = "4.8px 9.6px 4.8px 9.6px"
DEFAULTS = {                            # role → (font-size px, colour, line-height): CSS defaults
    "ttl": ("54.6px", "#1A2E40", "1.07"),
    "body": ("24.8px", "#1A2E40", "1.13"),
    "tb": ("22.3px", "#000000", None),
}


def colour(v):
    return NAMES.get(v.upper(), v)


def points(px):
    m = re.fullmatch(r'([\d.]+)px', px)
    if not m: return None
    p = round(float(m.group(1)) / PT * 2) / 2
    if abs(p * PT - float(m.group(1))) > 0.08: return None
    return ("%g" % p)


def tidy(attr, single_ids):
    ident, classes, kv = parse(attr)
    d = dict(kv)
    st = []
    if "style" in d:
        for part in d["style"].split(";"):
            if ":" in part:
                k, v = part.split(":", 1)
                st.append([k.strip(), v.strip()])
    sd = dict(st)
    new_kv = []
    for k, v in kv:
        if k == "style": continue
        if k == "data-id" and v in single_ids: continue
        new_kv.append([k, v])
    # positions → Quarto's own attributes (the filter turns them back into a style)
    pos = []
    if ".absolute" in classes:
        for k in ("left", "top", "width", "height"):
            v = sd.get(k)
            if v is not None and (re.fullmatch(r'-?[\d.]+(px|%)', v) or v == "0"):
                pos.append([k, v[:-2] if v.endswith("px") else v]); del sd[k]
    # text boxes: role and defaults
    if ".tb" in classes:
        if sd.get("padding") == TB_PAD: del sd["padding"]
        if ".ttl" in classes: role = "ttl"
        elif sd.get("color", "").upper() == "#1A2E40" and sd.get("line-height") == "1.13":
            role = "body"; classes.insert(classes.index(".tb") + 1, ".body")
        else: role = "tb"
        fs, col, lh = DEFAULTS[role]
        if sd.get("font-size") == fs: del sd["font-size"]
        if sd.get("color", "").upper() == col: del sd["color"]
        if lh and sd.get("line-height") == lh: del sd["line-height"]
    extra = []
    if "font-size" in sd and points(sd["font-size"]):
        extra.append(["size", points(sd.pop("font-size"))])
    if "color" in sd: extra.append(["color", colour(sd.pop("color"))])
    if "background" in sd: extra.append(["background", colour(sd.pop("background"))])
    if "border" in sd:
        b = sd.pop("border")
        extra.append(["border", re.sub(r'#[0-9A-Fa-f]{6}', lambda m: colour(m.group(0)), b)])
    if "border-radius" in sd: extra.append(["radius", sd.pop("border-radius")])
    if sd.get("text-align") in ("center", "right"): extra.append(["align", sd.pop("text-align")])
    if sd.get("white-space") == "nowrap":
        del sd["white-space"]; classes.append(".nowrap")
    if "line-height" in sd: extra.append(["line-height", sd.pop("line-height")])
    rest = [[k, v] for k, v in st if k in sd and sd[k] == v]
    out_kv = pos + extra + new_kv
    if rest: out_kv.append(["style", ";".join("%s:%s" % (k, v) for k, v in rest)])
    return fmt(ident, classes, out_kv)


GROUP = re.compile(r'^(:{3,}) \{\.absolute \.grp left=(-?\d+) top=(-?\d+) width=\d+ height=\d+\}\n'
                   r'(:{3,}) \{\.absolute ([^\n]*?)left=(-?\d+) top=(-?\d+)([^\n]*)\}\n'
                   r'((?:(?!:::)[^\n]*\n)*?)\4\n\n?\1\n', re.M)


def flatten_groups(s):
    """a PowerPoint group that holds a single object (e.g. after its rows became one grid box)
    → that object alone, at its absolute place"""
    def one(m):
        return "%s {.absolute %sleft=%d top=%d%s}\n%s%s\n" % (
            m.group(4), m.group(5), int(m.group(2)) + int(m.group(6)), int(m.group(3)) + int(m.group(7)),
            m.group(8), m.group(9), m.group(4))
    return GROUP.sub(one, s)


IMG = re.compile(r'^!\[[^\]\n]*\]\([^)\s]+\)\{([^{}\n]*)\}[ \t]*$', re.M)


def keep_under(s):
    """a picture that fades out while another one fades in at the same place, same click (a chart
    and the same chart with more on it) → the old one stays underneath: two half-transparent
    pictures would show the background through them (a dark flash in the middle of the fade)"""
    def box(a):
        d = dict(parse(a)[2])
        try: return [float(d[k]) for k in ("left", "top", "width", "height")], d.get("data-fragment-index")
        except (KeyError, ValueError): return None, None
    out = []
    for part in re.split(r'(?m)^(?=## )', s):
        ims = [(m, parse(m.group(1))[1]) for m in IMG.finditer(part)]
        edits = []
        for m, cl in ims:
            if ".fade-out" not in cl or ".fragment" not in cl: continue
            b, k = box(m.group(1))
            if b is None: continue
            for m2, cl2 in ims:
                b2, k2 = box(m2.group(1))
                if (m2 is not m and ".fragment" in cl2 and ".fade-out" not in cl2 and k2 == k and b2
                        and all(abs(x - y) <= 3 for x, y in zip(b, b2))):
                    a = re.sub(r' \.fragment \.fade-out| data-fragment-index=\S+(?=\s|$)', '', m.group(1))
                    edits.append((m.start(1), m.end(1), a)); break
        for a, b, r in sorted(edits, reverse=True): part = part[:a] + r + part[b:]
        out.append(part)
    return "".join(out)


def main(path):
    s = open(path, encoding="utf8").read()
    ids = Counter(m[1] for m in re.findall(r'data-id=("?)([^"\s{}]+)\1', s))
    single = {k for k, n in ids.items() if n == 1}

    def div(m):
        a = m.group(2)
        if "style=" not in a and "data-id=" not in a: return m.group(0)
        return "%s {%s}" % (m.group(1), tidy(a, single))

    def inline(m):
        a = m.group(2)
        if "style=" not in a and "data-id=" not in a: return m.group(0)
        return "%s{%s}" % (m.group(1), tidy(a, single))

    n0 = len(s)
    s = re.sub(r'^(:{3,}) \{([^{}\n]*)\}[ \t]*$', div, s, flags=re.M)
    s = re.sub(r'([\])])\{([^{}\n]*)\}', inline, s)
    s = flatten_groups(s)
    s = keep_under(s)
    open(path, "w", encoding="utf8").write(s)
    print("tidy: %d → %d characters" % (n0, len(s)))


if __name__ == "__main__":
    main(sys.argv[1])
