"""Turn the hand-written references of the converted deck into Quarto citations."""
import re, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from sections import chunks

REFS_SLIDE = """## References {#refs-slide .references-slide .no-slide-refs}

::: {#refs}
:::
"""

LABELS = {"Böc+16": "bock2016madmom", "FI11": "fevotte2011algorithms", "FBD09": "fevotte2009nonnegative",
          "Foo00": "foote2000automatic", "GG12": "gillis2012accelerated", "GS15": "grill2015music",
          "Got+02": "goto2002rwc", "KC07": "kim2007nonnegative", "Mar+20": "marmoret2020uncovering",
          "Mar+22": "marmoret2022gretsi", "MCB22a": "marmoret2022cbm", "MCB22b": "marmoret2022barwise",
          "ME14": "mcfee2014analyzing", "Nie+20": "nieto2020audio", "Ser+14": "serra2014unsupervised",
          "SG18": "smith2018nonnegative", "Smi+11": "smith2011design", "SB03": "smaragdis2003nonnegative",
          "S03": "smaragdis2003nonnegative", "Wu+22": "wu2022semi"}

def plain_label(x):
    """'[**Mar+20**]{.underline}' → 'Mar+20'"""
    x = x.strip()
    x = re.sub(r"\[\*\*(.+?)\*\*\]\{[^}]*\}", r"\1", x)
    x = re.sub(r"\[(.+?)\]\{[^}]*\}", r"\1", x)
    return x.strip("* ").replace("\\[", "").replace("\\]", "")

LAB_RE = r"(?:\[\*\*)?\\?\[?(?:\[\*\*)?(?:%s)(?:\*\*\]\{[^}]*\})?" % "|".join(re.escape(k) for k in sorted(LABELS, key=len, reverse=True))

def is_footer(chunk):
    first = chunk.split("\n")[0]
    m = re.search(r"font-size:([\d.]+)px", first)
    if not m or float(m.group(1)) > 14.5: return False
    body = "\n".join(chunk.split("\n")[1:])
    # a reference list: starts with a label followed by author names
    return bool(re.search(r"(\\\[|\[\*\*\\\[|\\\[\[\*\*)(%s)" % "|".join(re.escape(k) for k in LABELS), body))

GROUP = re.compile(r"(\[\*\*\\\[[^\]\\]+\\\]\*\*\]\{\.underline\})|\\\[(.+?)\\\]")

LABS = "|".join(re.escape(k) for k in sorted(LABELS, key=len, reverse=True))
# "[\[]{style=…}[**Wu+22**]{.underline style=…}[\]]{style=…}"  (brackets in separate runs)
SPLIT = re.compile(r"\[\\\[\]\{([^}]*)\}\s*\[\*{0,2}(%s)\*{0,2}\]\{[^}]*\}\s*\[\\\]\]\{[^}]*\}" % LABS)


def split_cite(m):
    # "[" label "]" written as three styled runs: keep their font size on the citation
    fs = re.search(r"font-size:\s*([\d.]+px)", m.group(1))
    c = "[@%s]" % LABELS[m.group(2)]
    return '[%s]{style="font-size:%s"}' % (c, fs.group(1)) if fs else c

def to_cite(m):
    if m.group(1):
        lab = plain_label(m.group(1))
        return "[@%s]" % LABELS[lab] if lab in LABELS else m.group(0)
    inner = m.group(2)
    parts = [plain_label(p) for p in inner.split(",")]
    if parts and all(p in LABELS for p in parts):
        return "[" + "; ".join("@" + LABELS[p] for p in parts) + "]"
    return m.group(0)

def convert(s):
    out = []
    # slides
    pieces = re.split(r"(?m)^(?=## )", s)
    for sl in pieces:
        if not sl.startswith("## "):
            out.append(sl); continue
        head, _, body = sl.partition("\n")
        cs = chunks(body)
        keep = [c for c in cs if not is_footer(c)]
        footer_keys = []
        for c in cs:
            if is_footer(c):
                for lab in re.findall(r"(%s)" % "|".join(re.escape(k) for k in sorted(LABELS, key=len, reverse=True)), c):
                    if LABELS[lab] not in footer_keys: footer_keys.append(LABELS[lab])
        body = "\n".join(keep)
        # inline labels → citations (not inside notes)
        parts = re.split(r"(::: notes\n.*?\n:::)", body, flags=re.S)
        parts = [p if p.startswith("::: notes") else GROUP.sub(to_cite, SPLIT.sub(split_cite, p)) for p in parts]
        body = "".join(parts)
        # references that were only in the PowerPoint footer (e.g. cited inside a chart image)
        missing = [k for k in footer_keys if "@" + k not in body]
        if missing:
            body = body.rstrip("\n") + "\n\n[[" + "; ".join("@" + k for k in missing) + "]]{.refs-only}\n\n"
        out.append(head + "\n" + body)
    return "".join(out)

if __name__ == "__main__":
    p = sys.argv[1]
    s = open(p).read()
    s = convert(s)
    # the three hand-made reference slides → one generated bibliography slide
    a = re.search(r"(?m)^## [^\n]*\{#s83", s).start()
    s = s[:a] + REFS_SLIDE
    open(p, "w").write(s)
