"""highlights.py — replace PowerPoint highlight overlays by native highlights (hl=…).

In the PowerPoint decks, a part of a matrix / image is highlighted by a second shape,
half-transparent red, laid over it and shown on some clicks. This script finds those
overlays in a converted deck, finds the object under each one, and writes the
highlight on that object instead:

    ::: {.absolute .shp … style="left:686px;top:192px;width:98px;height:23px;…" cols=4 hl="2@1; 3@2; 4@3; 5-@4"}

  * regions that fall on a regular grid of the object become grid cells (cols= / rows= + @k / @c,r);
  * other regions become rectangles in % of the object: @(37.8,29.9,6.3,18.8);
  * an overlay covering (almost) the whole object highlights the whole object.

Usage:  python3 highlights.py deck.qmd [--color "rgba(192,0,0,0.50)"]
"""
import re
import sys

COLOR = "rgba(192,0,0,0.50)"
TOL = 3.0          # px: an overlay may stick out of its object by this much

OPEN = re.compile(r"^(:{3,})\s*\{(.*)\}\s*$")
CLOSE = re.compile(r"^:{3,}\s*$")
IMG = re.compile(r"^!\[[^\]]*\]\([^)]*\)\{(.*)\}\s*$")


def style_rect(attrs):
    m = re.search(r'style="([^"]*)"', attrs)
    st = m.group(1) if m else ""
    v = {}
    for k in ("left", "top", "width", "height"):
        mm = re.search(r"(?:^|;)\s*" + k + r"\s*:\s*([-\d.]+)px", st)
        if mm:
            v[k] = float(mm.group(1))
    if len(v) < 4:
        for k in ("left", "top", "width", "height"):
            mm = re.search(r"(?:^|\s)" + k + r"=([-\d.]+)", attrs)
            if mm and k not in v:
                v[k] = float(mm.group(1))
    if len(v) < 4:
        return None
    return (v["left"], v["top"], v["width"], v["height"])


def frag(attrs):
    cls = re.findall(r"(?:^|\s)\.([\w-]+)", attrs)
    m = re.search(r"data-fragment-index=(\d+)", attrs)
    return cls, (int(m.group(1)) if m else None)


class Obj:
    def __init__(self, start, end, lines):
        self.start, self.end, self.lines = start, end, lines
        first = lines[0]
        m = OPEN.match(first) or IMG.match(first)
        self.attrs = m.group(2) if OPEN.match(first) else m.group(1)
        self.is_img = bool(IMG.match(first))
        self.rect = style_rect(self.attrs)
        # wrapper form (outer box = position + entrance, inner box = look + exit)
        self.inner = None
        if not self.is_img and len(lines) > 1 and OPEN.match(lines[1]):
            self.inner = OPEN.match(lines[1]).group(2)
        self.look = self.inner if self.inner is not None else self.attrs
        body = [l for l in lines[1:] if l.strip() and not OPEN.match(l) and not CLOSE.match(l)]
        self.empty = not body
        self.overlay = (not self.is_img and self.empty and ".shp" in self.look
                        and COLOR in self.look.replace(" ", "") and self.rect is not None)
        rot = re.search(r"transform:\s*rotate\((-?[\d.]+)deg\)", self.look)
        if self.overlay and rot:
            ang = float(rot.group(1)) % 180
            if abs(ang - 90) < 0.5:              # a shape turned by 90°: its visible box is swapped
                x, y, w, h = self.rect
                cx, cy = x + w / 2, y + h / 2
                self.rect = (cx - h / 2, cy - w / 2, h, w)
            elif abs(ang) > 0.5:
                self.overlay = False
        self.transformed = "transform" in self.attrs or "rotate-" in self.attrs or "face=" in self.attrs \
            or (self.inner is not None and "transform" in self.inner)

    def steps(self):
        """(first, last) step during which the overlay is visible; last None = to the end; None = unsupported."""
        cls_o, idx_o = frag(self.attrs)
        cls_i, idx_i = frag(self.inner) if self.inner is not None else ([], None)
        if "move" in cls_o or "move" in cls_i:
            return None
        start, stop = 0, None
        for cls, idx in ((cls_o, idx_o), (cls_i, idx_i)):
            if "fragment" not in cls:
                continue
            if any(c.startswith("fade-out") or c.startswith("semi-fade") for c in cls):
                stop = (idx or 1) - 1
            elif any(c in cls for c in ("fade-in-then-out", "current-visible", "fade-in-then-semi-out")):
                start, stop = idx or 1, idx or 1
            else:
                start = idx or 1
        return start, stop


def parse(lines):
    objs, i = [], 0
    while i < len(lines):
        l = lines[i]
        if IMG.match(l):
            objs.append(Obj(i, i, [l]))
            i += 1
            continue
        m = OPEN.match(l)
        if m:
            depth, j = 1, i + 1
            while j < len(lines) and depth:
                if OPEN.match(lines[j]):
                    depth += 1
                elif CLOSE.match(lines[j]):
                    depth -= 1
                j += 1
            objs.append(Obj(i, j - 1, lines[i:j]))
            i = j
            continue
        i += 1
    return objs


def contains(h, o):
    return (o[0] >= h[0] - TOL and o[1] >= h[1] - TOL and
            o[0] + o[2] <= h[0] + h[2] + TOL and o[1] + o[3] <= h[1] + h[3] + TOL)


def fit_axis(spans, L, only=None):
    for n in ([only] if only else range(1, 13)):
        c = L / n
        if c < 5:
            break
        tol = max(1.5, min(5.0, 0.25 * c))
        ok = True
        for s, e in spans:
            a, b = round(s / c), round(e / c)
            if b <= a or abs(s - a * c) > tol or abs(e - b * c) > tol:
                ok = False
                break
        if ok:
            return n
    return None


def fmt(x):
    return ("%.1f" % x).rstrip("0").rstrip(".")


def steps_txt(st):
    a, b = st
    if b is None:
        return "%d-" % a
    if a == b:
        return "%d" % a
    return "%d-%d" % (a, b)


def spec_for(host, regs):
    hx, hy, hw, hh = host.rect
    entries, cells = [], []
    rel = []
    for o, st in regs:
        x, y, w, h = o.rect
        x0, y0 = max(0.0, x - hx), max(0.0, y - hy)
        x1, y1 = min(hw, x + w - hx), min(hh, y + h - hy)
        rel.append((x0, y0, x1, y1, st))
    whole = [((x1 - x0) * (y1 - y0) >= 0.9 * hw * hh) for x0, y0, x1, y1, _ in rel]
    part = [r for r, wh in zip(rel, whole) if not wh]
    cols = fit_axis([(r[0], r[2]) for r in part], hw) if part else None
    rows = fit_axis([(r[1], r[3]) for r in part], hh) if part else None
    if cols and rows and cols != rows and abs(hw / hh - 1) < 0.1:
        # square object (e.g. a self-similarity matrix): prefer a square grid when it fits
        n = max(cols, rows)
        if fit_axis([(r[0], r[2]) for r in part], hw, n) and fit_axis([(r[1], r[3]) for r in part], hh, n):
            cols = rows = n
    grid = cols is not None and rows is not None
    for (x0, y0, x1, y1, st), wh in zip(rel, whole):
        s = st
        if wh:
            entries.append((s, ""))
        elif grid:
            cw, ch = hw / cols, hh / rows
            c0, c1 = round(x0 / cw) + 1, round(x1 / cw)
            r0, r1 = round(y0 / ch) + 1, round(y1 / ch)
            rng = lambda a, b, n: "*" if (a == 1 and b == n and n > 1) else (str(a) if a == b else "%d-%d" % (a, b))
            if rows == 1:
                area = rng(c0, c1, 0)
            elif cols == 1:
                area = rng(r0, r1, 0)
            else:
                area = rng(c0, c1, cols) + "," + rng(r0, r1, rows)
            entries.append((s, "@" + area))
        else:
            entries.append((s, "@(%s,%s,%s,%s)" % (fmt(100 * x0 / hw), fmt(100 * y0 / hh),
                                                   fmt(100 * (x1 - x0) / hw), fmt(100 * (y1 - y0) / hh))))
    attrs = ""
    if grid:
        if cols > 1: attrs += ' cols=%d' % cols
        if rows > 1: attrs += ' rows=%d' % rows
    # the same area shown by several overlapping overlays → one entry
    merged = []
    for st, area in entries:
        for m in merged:
            a0, b0 = m[0]
            if m[1] == area and (b0 is None or st[0] <= b0 + 1) and (st[1] is None or a0 <= st[1] + 1):
                m[0] = (min(a0, st[0]), None if (b0 is None or st[1] is None) else max(b0, st[1]))
                break
        else:
            merged.append([st, area])
    attrs += ' hl="%s"' % "; ".join(steps_txt(st) + area for st, area in merged)
    return attrs


def add_attrs(line, extra):
    i = line.rstrip().rfind("}")
    return line[:i].rstrip() + extra + line[i:]


def process_slide(lines):
    objs = parse(lines)
    hosts = [o for o in objs if not o.overlay and o.rect and o.rect[2] > 0 and o.rect[3] > 0 and not o.transformed]
    found = {}
    drop = set()
    for o in objs:
        if not o.overlay:
            continue
        st = o.steps()
        if st is None:
            continue
        cand = [h for h in hosts if contains(h.rect, o.rect)]
        if not cand:
            continue
        h = min(cand, key=lambda h: h.rect[2] * h.rect[3])
        found.setdefault(id(h), (h, []))[1].append((o, st))
        drop.add(id(o))
    if not found:
        return lines, 0
    out = list(lines)
    for h, regs in found.values():
        regs.sort(key=lambda r: (r[1][0], r[0].rect[1], r[0].rect[0]))
        k = h.start + (1 if h.inner is not None else 0)
        out[k] = add_attrs(out[k], spec_for(h, regs))
    for o in sorted((o for o in objs if id(o) in drop), key=lambda o: -o.start):
        end = o.end + 1
        if end < len(out) and not out[end].strip():
            end += 1
        del out[o.start:end]
    return out, len(drop)


def main(path):
    text = open(path, encoding="utf-8").read().split("\n")
    out, slide, total = [], [], 0
    for l in text + ["## __END__"]:
        if l.startswith("## "):
            new, n = process_slide(slide)
            out += new
            total += n
            slide = []
        slide.append(l)
    open(path, "w", encoding="utf-8").write("\n".join(out))
    print("highlights: %d overlays turned into hl=…" % total)


if __name__ == "__main__":
    if "--color" in sys.argv:
        COLOR = sys.argv[sys.argv.index("--color") + 1].replace(" ", "")
    main(sys.argv[1])
