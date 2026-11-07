"""Helpers shared by the converter passes (one copy of each):

  parse / fmt     an attribute block {#id .class key=value key="v w"}  <->  (ident, classes, [[k, v]])
  BLOCK           a one-level ::: {attrs} … ::: block of a converted slide
  style_of        the CSS declarations of a style= attribute, as a dict
  px              "12" / "12px" -> 12.0 (None otherwise)
  PT, FK          px per pt of the template (= --talk-pt in talk/talk.scss)
  template_palette, theme_names, deck_palette   colour names; the template's are read from
                  talk/talk.scss (single source), the deck's from tools/_header.yml
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SCSS = os.path.join(HERE, "..", "talk", "talk.scss")
HEADER = os.path.join(HERE, "_header.yml")

FK = float(os.environ.get("FK", "0.93"))   # Libre Franklin is wider than Franklin Gothic Book
PT = 4 / 3 * FK                            # px per pt (font sizes); talk.scss --talk-pt: 1.24px

# ---------------------------------------------------------------- attribute blocks
TOKEN = re.compile(r'(#[^\s{}]+)|(\.[^\s{}=]+)|([\w:-]+)=("[^"]*"|[^\s{}]+)')


def parse(attr, raw=False):
    """'#id .a .b k=v k2="x y"' -> ('#id', ['.a', '.b'], [['k', 'v'], ['k2', 'x y']])
    (raw: values as written, quotes kept)"""
    ident, classes, kv = None, [], []
    for m in TOKEN.finditer(attr):
        if m.group(1): ident = m.group(1)
        elif m.group(2): classes.append(m.group(2))
        else:
            v = m.group(4)
            if v.startswith('"') and not raw: v = v[1:-1]
            kv.append([m.group(3), v])
    return ident, classes, kv


def fmt(ident, classes, kv):
    """the inverse of parse (values quoted when needed)"""
    out = ([ident] if ident else []) + classes
    for k, v in kv:
        out.append('%s=%s' % (k, v) if re.fullmatch(r'[\w.%-]+', v) else '%s="%s"' % (k, v))
    return " ".join(out)


BLOCK = re.compile(r'^::: \{([^{}\n]*)\}\n((?:(?!:::)[^\n]*\n)*?):::\n', re.M)


def style_of(kv):
    """CSS declarations of the style= of kv (a dict, or a list of [key, value])"""
    d = dict(kv)
    out = {}
    for part in d.get("style", "").split(";"):
        if ":" in part:
            k, v = part.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def px(v):
    m = re.fullmatch(r'(-?[\d.]+)(px)?', v or "")
    return float(m.group(1)) if m else None


# ---------------------------------------------------------------- colour names
def _hex6(h):
    h = h.upper()
    return h if len(h) == 7 else "#" + "".join(c * 2 for c in h[1:])


def _scss():
    with open(SCSS, encoding="utf8") as f:
        return f.read()


def template_palette():
    """[(name, "#RRGGBB")] of the template's highlight palette (talk.scss --hl-NAME), in file order"""
    return [(k, _hex6(v)) for k, v in re.findall(r'--hl-([a-z]+):\s*(#[0-9A-Fa-f]{3,6})\b', _scss())]


def theme_names():
    """{"#RRGGBB": name} of the theme colours (talk.scss :root --talk-text / -accent / -bg)"""
    s = _scss()
    sass = {k: _hex6(v) for k, v in re.findall(r'^\$(\w+):\s*(#[0-9A-Fa-f]{3,6})\b', s, re.M)}
    out = {}
    for var, name in (("text", "text"), ("accent", "accent"), ("bg", "background")):
        m = re.search(r'--talk-%s:\s*#\{\$(\w+)\}' % var, s)
        if m and m.group(1) in sass: out[sass[m.group(1)]] = name
    return out


def deck_palette():
    """[(name, "#RRGGBB")] of the deck's own colour names (_header.yml, talk: highlight: colors)"""
    try:
        txt = open(HEADER, encoding="utf8").read()
    except OSError:
        return []
    m = re.search(r'\n  highlight:\n(?:    .*\n)*?    colors:[^\n]*\n((?:      [\w-]+:.*\n)+)', txt)
    if not m: return []
    return [(k, v.upper()) for k, v in re.findall(r'^\s+([\w-]+):\s*"?(#[0-9A-Fa-f]{6})"?', m.group(1), re.M)]
