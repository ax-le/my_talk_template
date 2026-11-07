"""Rewrite a converted deck into the short, hand-editable style of the talk template (objective 2).
   usage: python3 tools/simplify.py in.qmd out.qmd      (last step of tools/build_deck.sh)
   Prints what it left untouched. Section colour names come from tools/_header.yml (talk: highlight: colors)."""
import re, sys, math
from collections import Counter

REPORT = Counter()
sys.path.insert(0, __import__('os').path.dirname(__file__))
from shared import parse, theme_names, deck_palette          # noqa: E402

THEME = theme_names()

# ---------------------------------------------------------------- attribute blocks
def parse_attrs(s):
    """'{.a .b k=v k2="x y"}' -> (classes list, id, ordered dict of the values as written)"""
    s = s.strip()
    if s.startswith('{'): s = s[1:-1]
    ident, cls, kv = parse(s, raw=True)
    return [c[1:] for c in cls], ident[1:] if ident else None, dict(kv)

def fmt_attrs(cls, ident, kv):
    parts = (['#' + ident] if ident else []) + ['.' + c for c in cls] + [f'{k}={v}' for k, v in kv.items()]
    return '{' + ' '.join(parts) + '}'

def unq(v): return v[1:-1] if v and v.startswith('"') else v
def q(v): return v if re.fullmatch(r'[\w.%#-]+', v) else f'"{v}"'
def num(v): return float(re.match(r'-?[\d.]+', unq(v)).group())

# ---------------------------------------------------------------- block parser
def parse_blocks(lines):
    """Top-level items: ('div', opener_attrs_str, colons, inner_lines) | ('text', lines) | ('blank',)"""
    out, i = [], 0
    while i < len(lines):
        l = lines[i]
        m = re.match(r'^(:{3,})\s*(\{.*\}|[\w-]+)\s*$', l)
        if m:
            depth, j = 1, i + 1
            while j < len(lines):
                if re.match(r'^:{3,}\s*$', lines[j]): depth -= 1
                elif re.match(r'^:{3,}\s*(\{.*\}|[\w-]+)\s*$', lines[j]): depth += 1
                if depth == 0: break
                j += 1
            a = m.group(2) if m.group(2).startswith('{') else '{.' + m.group(2) + '}'
            out.append(['div', a, lines[i + 1:j]]); i = j + 1
        elif l.strip() == '':
            out.append(['blank']); i += 1
        else:
            j = i
            while j < len(lines) and lines[j].strip() != '' and not re.match(r'^:{3,}', lines[j]): j += 1
            out.append(['text', lines[i:j]]); i = j
    return out

def strip_blank(ls):
    while ls and ls[0].strip() == '': ls = ls[1:]
    while ls and ls[-1].strip() == '': ls = ls[:-1]
    return ls

# ---------------------------------------------------------------- objects
class Obj:
    """One positioned object: kind 'div' | 'span' | 'raw' (shortcode / image line); frag = (kind, index) or None"""
    def __init__(self, kind, cls=None, ident=None, kv=None, body=None, raw=None, frag=None):
        self.kind, self.cls, self.ident, self.kv = kind, cls or [], ident, kv or {}
        self.body, self.raw, self.frag = body or [], raw, frag
    def groupable(self):
        if self.kind == 'move':
            kv = {k: v for k, v in self.kv.items() if not (k == 'dy' and v in ('0', '1', '-1'))}
            lines = []
            for blk in self.body: lines += blk
            return ['::: ' + fmt_attrs(self.cls, None, kv)] + lines + [':::']
        if self.kind == 'raw': return True
        bad = {'move', 'audio-btn', 'annot', 'section-panel', 'section-ref', 'appendix', 'notes'}
        return not (bad & set(self.cls)) and not any(k in self.kv for k in ('data-audio', 'data-id', 'data-play', 'data-stop-audio'))
    def render(self, with_frag=True):
        cls, kv = list(self.cls), dict(self.kv)
        if with_frag and self.frag:
            fk, fi, dl = self.frag
            cls += ['fragment'] + (['fade-in-then-out'] if fk == 'once' else ['fade-out'] if fk == 'out' else [])
            kv['fragment-index'] = str(fi)
            if dl: kv['delay'] = dl
        if self.kind == 'move':
            kv = {k: v for k, v in self.kv.items() if not (k == 'dy' and v in ('0', '1', '-1'))}
            lines = []
            for blk in self.body: lines += blk
            return ['::: ' + fmt_attrs(self.cls, None, kv)] + lines + [':::']
        if self.kind == 'raw':
            if with_frag and self.frag:
                return [fmt_frag(self.frag)] + self.raw + [':::']
            return list(self.raw)
        if self.kind == 'span':
            return [f'[{" ".join(self.body)}]' + fmt_attrs(cls, self.ident, kv)]
        return ['::: ' + fmt_attrs(cls, self.ident, kv)] + strip_blank(self.body) + [':::']

def fmt_frag(frag):
    fk, fi, dl = frag
    extra = ' .fade-in-then-out' if fk == 'once' else ' .fade-out' if fk == 'out' else ''
    return f'::: {{.fragment{extra} fragment-index={fi}' + (f' delay={dl}' if dl else '') + '}'

def take_frag(cls, kv):
    """remove .fragment/.fade-out/.fade-in-then-out + index from an object; return frag key"""
    if 'fragment' not in cls: return None
    fk = 'out' if 'fade-out' in cls else 'once' if 'fade-in-then-out' in cls else 'in'
    other = [c for c in cls if c not in ('fragment', 'fade-out', 'fade-in-then-out')]
    if any(c in ('fade-up', 'fade-down', 'grow', 'shrink', 'strike', 'highlight-red', 'semi-fade-out', 'move') for c in other): return None
    fi = kv.get('data-fragment-index') or kv.get('fragment-index')
    if fi is None: return None
    cls[:] = other
    kv.pop('data-fragment-index', None); kv.pop('fragment-index', None)
    return (fk, int(unq(fi)), kv.pop('delay', None))

# ---------------------------------------------------------------- svg lines → arrows
def svg_line_to_arrow(svg, L, T, extra=''):
    vb = re.search(r'viewBox="(-?[\d.]+) (-?[\d.]+)', svg); vx, vy = float(vb.group(1)), float(vb.group(2))
    ln = re.search(r'<line x1="([-\d.]+)" y1="([-\d.]+)" x2="([-\d.]+)" y2="([-\d.]+)" stroke="([^"]+)" stroke-width="([\d.]+)"([^>]*)>', svg)
    if not ln: return None
    x1, y1, x2, y2 = (float(ln.group(i)) for i in range(1, 5)); col, w, rest = ln.group(5), float(ln.group(6)), ln.group(7)
    X1, Y1, X2, Y2 = L - vx + x1, T - vy + y1, L - vx + x2, T - vy + y2
    o = []
    c = THEME.get(col.upper(), col)
    if c == 'accent': c = 'var(--talk-accent)'
    if c != '#000000': o.append(f'color="{c}"')
    ww = round(w) if w >= 1.5 else 1
    if ww != 2: o.append(f'width={ww}')
    end, start = 'marker-end' in rest, 'marker-start' in rest
    dash = re.search(r'stroke-dasharray="([^"]+)"', rest)
    if dash: o.append('dash="%s"' % ' '.join('%g' % round(float(v)) for v in dash.group(1).split()))
    circle = 'circle' in svg
    if not end and not start: o.append('head=none')
    elif circle:
        sz = re.search(r'markerWidth="([\d.]+)"', svg); k = round(float(sz.group(1)) / max(w, 1)) if sz else 4
        if start and not end: o += ['head=circle', 'head-start=true', 'head-end=false', f'size={k}']
        else: o += ['head=circle', f'size={k}'] + (['head-start=true'] if start else [])
    else:
        sz = re.search(r'markerWidth="([\d.]+)"', svg)
        k = max(1, round(float(sz.group(1)) / max(ww, 1))) if sz else 6
        o.append(f'size={k}')
        if start and end: o.append('head-start=true')
        elif start and not end:  # head at the start only: swap
            X1, Y1, X2, Y2 = X2, Y2, X1, Y1
        # quarto-arrows: 'to' is the base of the head; move it back so the tip stays where it was
        Lh = math.hypot(X2 - X1, Y2 - Y1); h = ww * k
        if Lh > h: X2, Y2 = X2 - (X2 - X1) * h / Lh, Y2 - (Y2 - Y1) * h / Lh
    return '{{< arrow from="%d,%d" to="%d,%d" %s position="absolute" >}}' % (round(X1), round(Y1), round(X2), round(Y2), ' '.join(o + ([extra] if extra else [])))

# ---------------------------------------------------------------- svg geometry → shape=
def geom_to_shape(svg, W, H, rot):
    """returns (attrs dict, new (W,H) swap flag) or None"""
    paths = re.findall(r'<path d="([^"]+)"([^>]*)>', svg)
    if not paths:
        if '<ellipse' in svg:
            e = re.search(r'<ellipse[^>]*>', svg).group(0)
            kv = {'radius': '50%'}
            f = re.search(r'fill="([^"]+)"', e); s = re.search(r'stroke="([^"]+)"', e); sw = re.search(r'stroke-width="([\d.]+)"', e)
            if f and f.group(1) != 'none': kv['background'] = q(THEME.get(f.group(1).upper(), f.group(1)))
            if s and s.group(1) != 'none': kv['border'] = '"%gpx solid %s"' % (round(float(sw.group(1)), 1) if sw else 1, THEME.get(s.group(1).upper(), s.group(1)))
            return kv, rot
        return None
    d, style = paths[0]
    nums = [float(x) for x in re.findall(r'-?[\d.]+', d)]
    pts = list(zip(nums[0::2], nums[1::2]))
    kv = {}
    sub = d.count('M')
    def close(a, b, tol=0.6): return abs(a - b) <= tol
    if sub == 1 and len(pts) == 7 and close(pts[0][0], 0) and close(pts[3][0], W) and close(pts[3][1], H / 2):
        a, b = pts[0][1], pts[1][0]
        kv['shape'] = 'arrow-right'; head = (W - b) / W * 100; shaft = (H - 2 * a) / H * 100
    elif sub == 1 and len(pts) == 7 and close(pts[4][1], H) and close(pts[4][0], W / 2):
        a, b = pts[0][0], pts[2][1]           # down arrow preset: (a,0) (W-a,0) (W-a,b) (W,b) (W/2,H) (0,b) (a,b)
        kv['shape'] = 'arrow-down'; head = (H - b) / H * 100; shaft = (W - 2 * a) / W * 100
    elif sub == 1 and len(pts) == 4 and close(pts[0][0], 0) and close(pts[0][1], H) and close(pts[1][1], 0) and close(pts[3][0], W):
        x1, x2 = pts[1][0], pts[2][0]          # trapezoid, wide side at the bottom
        kv['shape'] = 'trap'; head = None; taper = (x2 - x1) / W * 100
    elif sub == 1 and len(pts) == 4 and close(pts[0][1], 0) and close(pts[3][0], 0) and close(pts[3][1], H) and close(pts[1][0], W):
        kv['shape'] = 'parallelogram'; head = None; slant = pts[0][0] / W * 100
    elif (sub >= 3 or len(paths) >= 3) and close(pts[0][0], 0) and close(pts[1][1], pts[0][1]):
        kv['shape'] = 'cube'; head = None; depth = pts[0][1]
    else:
        return None
    # rotation: quarter turns become a direction; anything else stays a rotation
    r = (round(rot) % 360) if rot else 0
    swap = r in (90, 270)
    shp = kv['shape']
    if shp == 'arrow-right' and r in (90, 180, 270): kv['shape'] = {90: 'arrow-down', 180: 'arrow-left', 270: 'arrow-up'}[r]; r = 0
    elif shp == 'arrow-down' and r in (90, 180, 270): kv['shape'] = {90: 'arrow-left', 180: 'arrow-up', 270: 'arrow-right'}[r]; r = 0
    elif shp == 'trap':
        if r == 90: kv['shape'] = 'shrink'; r = 0
        elif r == 270: kv['shape'] = 'grow'; r = 0
        else: return None
    if shp.startswith('arrow'):
        if abs(head - 30) > 2: kv['head'] = '%g' % round(head)
        if abs(shaft - 50) > 2: kv['shaft'] = '%g' % round(shaft)
    if shp == 'trap': kv['taper'] = '%g%%' % round(taper)
    if shp == 'parallelogram' and abs(slant - 25) > 2: kv['slant'] = '%g' % round(slant)
    if shp == 'cube': kv['depth'] = '%g' % round(depth)
    f = re.search(r'fill="([^"]+)"', style); s = re.search(r'stroke="([^"]+)"', style); sw = re.search(r'stroke-width="([\d.]+)"', style)
    if f and f.group(1) != 'none': kv['background'] = q(THEME.get(f.group(1).upper(), f.group(1)))
    if s and s.group(1) != 'none':
        w = float(sw.group(1)) if sw else 1
        if not (s.group(1) == '#000000' and close(w, 1, 0.3)): kv['border'] = '"%gpx solid %s"' % (round(w, 1), THEME.get(s.group(1).upper(), s.group(1)))
    else: kv['border'] = '0'
    if r: kv['rotate-z'] = '%g' % round(r, 1)
    return kv, (swap and r == 0)

# ---------------------------------------------------------------- one slide
GAP_RE = re.compile(r'^<div class="gap" style="height:(\d+)px"></div>$')
LIST_RE = re.compile(r'^\s*([-*]|\d+\.)( |$)')

def fix_text(lines):
    """inside a text box: gaps → empty list items / &nbsp;, split runs, trailing spaces"""
    out = []
    for l in lines: out.append(l.rstrip())
    # gaps
    res, i = [], 0
    while i < len(out):
        if GAP_RE.match(out[i]):
            prev = next((x for x in reversed(res) if x.strip()), '')
            nxt = next((x for x in out[i + 1:] if x.strip() and not GAP_RE.match(x)), '')
            in_list = LIST_RE.match(prev) or prev.startswith('  ') or LIST_RE.match(nxt)
            while res and res[-1].strip() == '': res.pop()
            if in_list and res and (LIST_RE.match(res[-1]) or res[-1].startswith('  ') or res[-1].strip() == '-'):
                # PowerPoint's empty paragraph: 43 px = a level-1 line, 37 px = a level-2 line
                lvl2 = int(GAP_RE.match(out[i]).group(1)) < 40
                # `  -` right under a level-1 item's text would read as a setext heading underline
                if lvl2 and not re.match(r'^\s+([-*]|\d+\.)( |$)', res[-1]): lvl2 = False
                res.append('  -' if lvl2 else '-')
            else:
                if res: res.append('')
                res.append('&nbsp;')
            i += 1
            while i < len(out) and out[i].strip() == '': i += 1
            if i < len(out) and not GAP_RE.match(out[i]):
                if res[-1].strip() == '-' and LIST_RE.match(out[i]): pass      # same list, no blank line
                else: res.append('')
            continue
        res.append(out[i]); i += 1
    # merge split runs [a]{X}[b]{X} and [a]{X} [b]{X}
    s = '\n'.join(res)
    for _ in range(6):
        s2 = re.sub(r'\[([^\[\]]*)\](\{[^{}]*\})( ?)\[([^\[\]]*)\]\2', lambda m: '[' + m.group(1) + m.group(3) + m.group(4) + ']' + m.group(2), s)
        if s2 == s: break
        s = s2
    s = re.sub(r'\[\]\{size=[\d.]+\}', '', s)
    return [l.rstrip() for l in s.split('\n')]

SIMPLE_MATH = re.compile(r'^\${1,2}[^$]+\${1,2}$')
def simple_inline(body):
    b = [l for l in body if l.strip()]
    if len(b) != 1: return None
    l = b[0].strip()
    if l.startswith(('-', '*', '#', '<', '!', '|', '>')) or LIST_RE.match(l): return None
    if SIMPLE_MATH.match(l): return l
    if re.search(r'[\[\]*$\\<`_^]', l): return None
    return l

def convert_div(attr_s, body):
    """→ list of Obj (or None to keep the raw div)"""
    cls, ident, kv = parse_attrs(attr_s)
    body = list(body)
    # motion path wrapper (.fragment.move) around objects: one block, dx= dy=
    if 'move' in cls:
        st = unq(kv.get('style', ''))
        dx = re.search(r'--dx:\s*(-?[\d.]+)px', st); dy = re.search(r'--dy:\s*(-?[\d.]+)px', st)
        fi = unq(kv.get('data-fragment-index') or kv.get('fragment-index') or '')
        inner_lines = []
        for b in parse_blocks(strip_blank(body)):
            if b[0] == 'blank': continue
            if b[0] == 'div':
                r = convert_div(b[1], b[2])
                if r:
                    for o in r: inner_lines.append(o.render())
                else: inner_lines.append(['::: ' + b[1]] + strip_blank(b[2]) + [':::'])
            else: inner_lines.append(b[1])
        o = Obj('move', ['fragment', 'move'], None, {'fragment-index': fi, 'dx': dx.group(1) if dx else '0', 'dy': dy.group(1) if dy else '0'}, inner_lines)
        return [o]
    # nested wrapper: outer positioned fragment around one inner object
    inner = parse_blocks(strip_blank(body))
    inner = [b for b in inner if b[0] != 'blank']
    if 'absolute' in cls and len(inner) == 1 and not ({'tb', 'shp', 'ln-box', 'grp', 'caption-top', 'caption-bottom'} & set(cls)) \
       and not ({'cols', 'rows'} & set(kv)):
        b = inner[0]
        if b[0] == 'div':
            icls, iid, ikv = parse_attrs(b[1])
            st = unq(ikv.get('style', ''))
            if 'width:100%;height:100%' in st.replace(' ', ''):
                rot = re.search(r'rotate\(([-\d.]+)deg\)', st)
                st2 = re.sub(r'width:100%;height:100%;?|transform:rotate\([-\d.]+deg\);?', '', st.replace(' ', '')).strip(';')
                ikv.pop('style', None)
                if st2: ikv['style'] = q(st2)
                ofrag = take_frag(cls, kv); ifrag = take_frag(icls, ikv)
                frag = ofrag
                if ofrag and ifrag:
                    if ifrag[0] == 'out' and ifrag[1] == ofrag[1] + 1: frag = ('once', ofrag[1], ofrag[2] or ifrag[2])
                    else: return None
                elif ifrag and not ofrag: frag = ifrag
                merged_cls = ['absolute'] + [c for c in icls if c not in ('absolute',)] + [c for c in cls if c != 'absolute']
                merged_kv = {**{k: v for k, v in kv.items()}, **ikv}
                if rot: merged_kv['rotate-z'] = '%g' % float(rot.group(1))
                objs = convert_div(fmt_attrs(merged_cls, iid or ident, merged_kv), b[2])
                if objs:
                    for o in objs: o.frag = o.frag or frag
                    return objs
                return None
        elif b[0] == 'text' and len(b[1]) == 1 and b[1][0].startswith('!['):
            m = re.match(r'^!\[(.*?)\]\(([^)]+)\)\{(.*)\}$', b[1][0])
            if m:
                icls, iid, ikv = parse_attrs(m.group(3))
                st = unq(ikv.pop('style', '')).replace(' ', '')
                ofrag = take_frag(cls, kv); ifrag = take_frag(icls, ikv)
                frag = ofrag
                if ofrag and ifrag:
                    if ifrag[0] == 'out' and ifrag[1] == ofrag[1] + 1: frag = ('once', ofrag[1], ofrag[2] or ifrag[2])
                    else: return None
                flip = 'rotate(180deg)scaleX(-1)' in st
                src = m.group(2)
                if flip: src = FLIP(src)
                elif re.sub(r'width:100%;height:100%;?', '', st): return None
                ik = {**kv, **ikv}
                o = Obj('raw', raw=['![%s](%s)%s' % (m.group(1), src, fmt_attrs(['absolute'] + icls, iid, ik))], frag=frag)
                o.image = True
                return [o]
        return None
    # geometry: svg.geom as first content of a box
    geo_i = next((k for k, l in enumerate(body) if l.startswith('<svg class="geom"')), None)
    if geo_i is not None and 'absolute' in cls:
        W, H = num(kv.get('width', '0')), num(kv.get('height', '0'))
        rot = kv.pop('rotate-z', None)
        res = geom_to_shape(body[geo_i], W, H, float(rot) if rot else 0)
        if not res:
            REPORT['geometry kept'] += 1
            if rot: kv['rotate-z'] = rot
            return None
        skv, swap = res
        if swap and any(l.strip() for k, l in enumerate(body) if k != geo_i):
            cls.append('rot-r' if round(float(rot)) % 360 == 90 else 'rot-l')   # its text turns with it
        if swap:   # quarter turn absorbed in the shape: the visible box is the rotated one
            L, T = num(kv['left']), num(kv['top'])
            kv['left'], kv['top'] = '%g' % round(L + (W - H) / 2), '%g' % round(T + (H - W) / 2)
            kv['width'], kv['height'] = '%g' % round(H), '%g' % round(W)
        body = body[:geo_i] + body[geo_i + 1:]
        cls = [c for c in cls if c != 'shp']
        kv.update(skv)
    # ln-box → arrow
    if 'ln-box' in cls:
        svg = next((l for l in body if l.startswith('<svg class="ln"')), None)
        frag = take_frag(cls, kv)
        a = svg_line_to_arrow(svg, num(kv['left']), num(kv['top'])) if svg else None
        if not a: REPORT['ln-box kept'] += 1; return None
        return [Obj('raw', raw=[a], frag=frag)]
    # simple boxes
    if 'absolute' not in cls: return None
    frag = take_frag(cls, kv)
    cls = [c for c in cls if c != 'shp']
    body = fix_text(strip_blank(body))
    # framed, centred text box → .box
    if 'tb' in cls and 'va-ctr' in cls and unq(kv.get('border', '')) == '1px solid black' and unq(kv.get('align', '')) == 'center' and kv.get('background') == 'background':
        cls = [c for c in cls if c not in ('tb', 'va-ctr')] + ['box']
        for k in ('border', 'align', 'background'): kv.pop(k)
        cls = ['absolute', 'box'] + [c for c in cls if c not in ('absolute', 'box')]
    # PowerPoint's default shape style (accent fill, darker outline, centred) → .filled
    if unq(kv.get('border', '')).replace('3.7px', '3.67px') == '3.67px solid #345056' and kv.get('background') == 'accent' \
       and ('shape' in kv or ('tb' in cls and 'va-ctr' in cls and unq(kv.get('align', '')) == 'center')):
        cls = [c for c in cls if c not in ('tb', 'va-ctr')]
        cls = ['absolute', 'filled'] + [c for c in cls if c != 'absolute']
        for k in ('border', 'background', 'align'): kv.pop(k, None)
        if kv.get('color') == 'background': kv.pop('color')
    if {'cols', 'rows'} & set(kv) or {'caption-top', 'caption-bottom'} & set(cls):
        return [Obj('div', cls, ident, kv, body, frag=frag)]
    if not [l for l in body if l.strip()]:
        return [Obj('span', cls, ident, kv, [], frag=frag)]
    si = simple_inline(body)
    if si is not None and 'shape' not in kv and not any(c.startswith('b-') for c in cls) and 'caption-top' not in cls and 'caption-bottom' not in cls:
        kv.pop('line-height', None)      # a div's paragraph had reveal's 1.3 anyway, as a span has
        return [Obj('span', cls, ident, kv, [si], frag=frag)]
    return [Obj('div', cls, ident, kv, body, frag=frag)]

FLIPPED = {}
def FLIP(src):
    FLIPPED[src] = re.sub(r'(\.\w+)$', r'_flipped\1', src)
    return FLIPPED[src]

def simplify_slide(text, auto_animate):
    lines = text.split('\n')
    head, rest = lines[0], lines[1:]
    rest = [l for l in rest if not re.match(r'^<!-- pptx slide \d+ -->$', l)]
    items = parse_blocks(rest)
    objs = []          # Obj or ('lines', [...])
    for it in items:
        if it[0] == 'blank': continue
        if it[0] == 'text':
            ls = it[1]
            if len(ls) == 1 and re.match(r'^!\[.*\]\(.*\)\{.*\}$', ls[0]):
                m = re.match(r'^(!\[.*?\]\([^)]+\))(\{.*\})$', ls[0])
                c, i_, kv = parse_attrs(m.group(2))
                if not auto_animate: kv.pop('data-id', None)
                fr = take_frag(c, kv) if not any(k in kv for k in ('data-audio', 'data-id')) else None
                o = Obj('raw', raw=[m.group(1) + fmt_attrs(c, i_, kv)], frag=fr); objs.append(o); continue
            if all(re.match(r'^\[.*\]\{.*\}$', l) for l in ls):    # spans (audio buttons…)
                for l in ls:
                    m = re.match(r'^\[(.*)\](\{.*\})$', l)
                    c, i_, kv = parse_attrs(m.group(2))
                    if not auto_animate: kv.pop('data-id', None)
                    if 'data-fragment-index' in kv: kv['fragment-index'] = kv.pop('data-fragment-index')
                    objs.append(('lines', ['[%s]%s' % (m.group(1), fmt_attrs(c, i_, kv))]))
                continue
            objs.append(('lines', fix_text(ls))); continue
        attr_s, body = it[1], it[2]
        c, i_, kv = parse_attrs(attr_s)
        if not auto_animate and 'data-id' in kv:
            kv.pop('data-id'); attr_s = fmt_attrs(c, i_, kv)
        if c and c[0] in ('notes',) or 'section-panel' in c or 'section-ref' in c or 'annot' in c or 'appendix' in c:
            objs.append(('lines', ['::: ' + attr_s] + strip_blank(body) + [':::'])); continue
        res = convert_div(attr_s, body)
        if res is None:
            REPORT['div kept'] += 1
            c, i_, kv = parse_attrs(attr_s)
            if 'data-fragment-index' in kv: kv['fragment-index'] = kv.pop('data-fragment-index')
            inner = '\n'.join(strip_blank(body))
            inner = re.sub(r'data-fragment-index=', 'fragment-index=', inner)
            objs.append(('lines', ['::: ' + fmt_attrs(c, i_, kv)] + inner.split('\n') + [':::']))
        else:
            objs.extend(res)
    # a title box on a slide without heading text → the heading itself (## Title {top=…})
    hm = re.match(r'^## (\{.*\})\s*$', head)
    if hm:
        for n, o in enumerate(objs):
            titlelike = 'ttl' in o.cls or ('tb' in o.cls and o.kv.get('size') == '44' and o.kv.get('color') == 'text') if isinstance(o, Obj) else False
            if isinstance(o, Obj) and titlelike and not o.frag and o.ident is None and not ({'va-ctr', 'va-b', 'nowrap', 'fragment'} & set(o.cls)) \
               and set(o.kv) <= {'left', 'top', 'width', 'height', 'size', 'color', 'line-height'} \
               and (len(re.sub(r'\{[^}]*\}|[\[\]*$\\]', '', ' '.join(o.body))) * 0.47 * (num(o.kv.get('size', '44')) * 1.24)
                    < 0.95 * num(o.kv.get('width', '1008'))):     # one-line titles only (a heading has another line height)
                if o.kv.get('size') == '44': o.kv.pop('size')
                body = [l for l in (o.body if o.kind == 'div' else [' '.join(o.body)])]
                txt = ' '.join(l.strip() for l in body if l.strip()).rstrip('\\').strip()
                if o.kind == 'div' and len([b for b in parse_blocks(strip_blank(o.body)) if b[0] != 'blank']) != 1: break
                if txt.startswith(('-', '$$')) or '::: ' in txt or '$' in txt: break   # maths changes a heading's line box
                txt = txt.replace('\\ ', '<br>').replace(' \\', '<br>')
                hc, hi, hkv = parse_attrs(hm.group(1))
                # a text box's paragraph has reveal's line height 1.3, the title 1.07: same text 6 px lower
                for k, d, off in (('top', 72, 6), ('left', 144, 0), ('width', 1008, 0)):
                    if k in o.kv and abs(num(o.kv[k]) + off - d) > 2: hkv[k] = '%g' % (num(o.kv[k]) + off)
                if 'size' in o.kv: hkv['size'] = o.kv['size']
                head = '## ' + txt + ' ' + fmt_attrs(hc, hi, hkv)
                del objs[n]; REPORT['title → heading'] += 1
                break
    # consecutive motion wrappers with the same move: one block
    merged = []
    for o in objs:
        if isinstance(o, Obj) and o.kind == 'move' and merged and isinstance(merged[-1], Obj) and merged[-1].kind == 'move' and merged[-1].kv == o.kv:
            merged[-1].body += o.body
        else: merged.append(o)
    objs = merged
    # group consecutive objects of the same click
    out, k = [], 0
    while k < len(objs):
        o = objs[k]
        if isinstance(o, Obj) and o.frag and o.groupable():
            j = k
            while j + 1 < len(objs) and isinstance(objs[j + 1], Obj) and objs[j + 1].frag == o.frag and objs[j + 1].groupable(): j += 1
            grp = objs[k:j + 1]
            if len(grp) == 1 and o.kind != 'raw':
                out.append(o.render())
            else:
                body = []
                for g in grp: body += g.render(with_frag=False)
                out.append([fmt_frag(o.frag)] + body + [':::'])
            k = j + 1; continue
        out.append(o.render() if isinstance(o, Obj) else o[1])
        k += 1
    # a .fade-in-then-out at click n hides at click n+1: that click must exist on the slide
    alltxt = '\n'.join('\n'.join(b) for b in out)
    used = {int(x) for x in re.findall(r'fragment-index=(\d+)', alltxt)}
    used |= {int(x) for x in re.findall(r'steps="?(\d+)', alltxt)} | {int(x) for x in re.findall(r'[";] ?(\d+)-?\d*@', alltxt)}
    once = {int(x) for x in re.findall(r'fade-in-then-out[^}]*?fragment-index=(\d+)', alltxt)}
    for n in sorted(once):
        if n + 1 not in used:
            out.append([f'[]{{.fragment fragment-index={n + 1}}}  <!-- click {n + 1}: hides what appeared at click {n} -->'])
            used.add(n + 1)
    # join: one-line objects without blank lines between them, blocks separated by blank lines
    res = [head, '']
    prev_one = False
    for blk in out:
        one = len(blk) == 1 and (blk[0].startswith('[') or blk[0].startswith('{{<') or blk[0].startswith('!['))
        if res[-1] != '' and not (one and prev_one): res.append('')
        res += blk
        prev_one = one
    return '\n'.join(res).rstrip('\n') + '\n\n'

def main(src, dst):
    t = open(src).read()
    head_end = t.index('\n---', 4) + 5 if t.startswith('---') else 0     # YAML header, if any
    header, body = t[:head_end], t[head_end:]
    parts = re.split(r'(?m)^(?=## )', body)
    pre, slides = parts[0], parts[1:]
    out = [header, pre.strip('\n') + '\n\n' if pre.strip() else '\n']
    for s in slides:
        h = s.split('\n', 1)[0]
        # pixel styles → short attributes (size= in pt, padding=)
        s = re.sub(r'style="padding:\s*0px\s*0px\s*0px\s*0px"', 'padding=0', s)
        s = re.sub(r'style="font-size:([\d.]+)px"', lambda m: 'size=%g' % round(float(m.group(1)) / 1.24, 1), s)
        aa = 'auto-animate=true' in h
        out.append(simplify_slide(s.rstrip('\n'), aa))
    r = ''.join(out)
    r = re.sub(r'data-fragment-index=', 'fragment-index=', r)
    r = diagonals(r)
    # an empty framed box on the slide background → .box
    r = re.sub(r'^\[\]\{\.absolute ([^}]*?)background=background border="1px solid black"([^}]*)\}$',
               lambda m: '[]{.absolute .box ' + m.group(1).rstrip() + m.group(2) + '}', r, flags=re.M)
    # an icon shown from the start + its trigger at click N → play=N on the icon (its id dropped)
    for m in re.finditer(r'^\[\]\{\.fragment data-play="([\w-]+)" fragment-index=(\d+)\}\n', r, re.M):
        aid, n = m.group(1), m.group(2)
        if r.count(aid) == 2:
            r = r.replace(m.group(0), '', 1)
            r = re.sub(r'\[\]\{#' + re.escape(aid) + r' ((?:\.absolute )?\.audio-btn [^}]*)\}', lambda mm: '[]{' + mm.group(1) + ' play=' + n + '}', r)
    # PowerPoint's default shape style in another colour → .filled background=…
    r = re.sub(r'\{\.absolute \.tb \.va-ctr ([^}]*?)background=("[^"]+"|\S+) border="3\.67px solid #345056" align=center([^}]*)\}',
               lambda m: '{.absolute .filled ' + m.group(1) + 'background=' + m.group(2) + m.group(3) + '}', r)
    r = final_syntax(r)
    r = re.sub(r'\n{3,}', '\n\n', r)
    # a fenced div opener right after a paragraph line would be read as part of that paragraph
    L = r.split('\n')
    for n in range(len(L) - 1, 0, -1):
        if re.match(r'^:{3,} \{', L[n]) and L[n - 1].strip() and not re.match(r'^:{3,}', L[n - 1]):
            L.insert(n, '')
    r = '\n'.join(L)
    open(dst, 'w').write(r)
    for src, dstimg in FLIPPED.items():          # pictures flipped by PowerPoint: save them flipped
        try:
            from PIL import Image
            import os
            if os.path.exists(src) and not os.path.exists(dstimg):
                Image.open(src).transpose(Image.FLIP_TOP_BOTTOM).save(dstimg)
        except ImportError:
            print('flip by hand (PIL missing):', src, '->', dstimg)
    print(dict(REPORT)); print('flipped:', FLIPPED)


# ---------------------------------------------------------------- the template's author syntax
# The earlier passes work with the converter's own classes; the written deck uses the template's
# attributes: .va-ctr / .va-b → valign=center / bottom; a sound []{.audio-btn data-audio="x"
# [data-autoplay=true]} → []{audio=x play=…}; a stop trigger → []{stop=N}.
ATTR_BLOCK = re.compile(r'\{([^{}\n]*)\}')

def _final_block(m):
    ident, cls, kv = parse(m.group(1), raw=True)
    if re.sub(r'(#[^\s{}]+)|(\.[^\s{}=]+)|([\w:-]+)=("[^"]*"|[^\s{}]+)', '', m.group(1)).strip():
        return m.group(0)                                   # not an attribute block (LaTeX…)
    d = dict(kv); changed = False
    def setkv(k, v):
        kv[:] = [x for x in kv if x[0] != k] + [[k, v]]
    for c, v in (('.va-ctr', 'center'), ('.va-b', 'bottom')):
        if c in cls: cls.remove(c); setkv('valign', v); changed = True
    if 'data-stop-audio' in d and '.fragment' in cls and 'fragment-index' in d:
        return '{stop=%s}' % d['fragment-index']
    if 'data-audio' in d:
        cls = [c for c in cls if c != '.audio-btn']
        play = d.get('play')
        rest = [x for x in kv if x[0] not in ('data-audio', 'data-autoplay', 'play')]
        if d.get('data-autoplay') == 'true':
            if '.fragment' in cls and 'fragment-index' in d:
                play = d['fragment-index']; rest = [x for x in rest if x[0] != 'fragment-index']
            else: play = '0'
        kv[:] = [['audio', d['data-audio']]] + rest + ([['play', play]] if play else [])
        changed = True
    if not changed: return m.group(0)
    return '{' + ' '.join(([ident] if ident else []) + cls + ['%s=%s' % (k, v) for k, v in kv]) + '}'

def final_syntax(r):
    return '\n'.join(ATTR_BLOCK.sub(_final_block, l) if '{' in l else l for l in r.split('\n'))


# ---------------------------------------------------------------- diagonal overlays → grid box with hl=@diag
PALETTE = {tuple(int(h[k:k + 2], 16) for k in (1, 3, 5)): name for name, h in reversed(deck_palette())}   # (r, g, b) → name

def diagonals(text):
    def repl(m):
        idx, body = m.group(1), m.group(2)
        sq = []
        for l in body.strip('\n').split('\n'):
            mm = re.match(r'^\[\]\{\.absolute left=(\d+) top=(\d+) width=(\d+) height=(\d+) background="rgba\((\d+),(\d+),(\d+),([\d.]+)\)"\}$', l)
            if not mm: return m.group(0)
            L, T, W, H, r, g, b, a = mm.groups()
            name = PALETTE.get((int(r), int(g), int(b)))
            if not name: return m.group(0)
            sq.append((int(L), int(T), int(W), int(H), name, float(a)))
        sq.sort()
        chains, cur = [], [sq[0]]
        for s in sq[1:]:
            p = cur[-1]
            if abs(s[0] - (p[0] + p[2])) <= 3 and abs(s[1] - (p[1] + p[3])) <= 3: cur.append(s)
            else: chains.append(cur); cur = [s]
        chains.append(cur)
        if any(len(c) < 4 for c in chains): return m.group(0)
        out = []
        for c in chains:
            xs = [s[0] for s in c] + [c[-1][0] + c[-1][2]]; ys = [s[1] for s in c] + [c[-1][1] + c[-1][3]]
            def units(v):       # sizes as small whole numbers (here: bars), if they fit
                d = [v[k + 1] - v[k] for k in range(len(v) - 1)]; tot = v[-1] - v[0]
                for n in range(len(d), 200):
                    u = tot / n; r = [round(x / u) for x in d]
                    if min(r) >= 1 and sum(r) == n and max(abs(x / u - round(x / u)) for x in d) < 0.35:
                        return ' '.join(map(str, r))
                return ' '.join(map(str, d))
            cols, rows = units(xs), units(ys)
            names = ' '.join(s[4] for s in c)
            out.append(f'::: {{.absolute left={xs[0]} top={ys[0]} width={xs[-1] - xs[0]} height={ys[-1] - ys[0]} cols="{cols}" rows="{rows}" hl="{idx}-@diag {names}" hl-opacity={c[0][5]:g}}}\n:::')
        REPORT['diagonal overlays → grid'] += len(c)
        return '\n\n'.join(out)
    return re.sub(r'::: \{\.fragment fragment-index=(\d+)\}\n((?:\[\]\{\.absolute left=\d+ top=\d+ width=\d+ height=\d+ background="rgba\([^)]*\)"\}\n)+):::', repl, text)

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
