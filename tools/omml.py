"""Minimal OMML (Office Math) -> LaTeX converter, sufficient for this deck."""
import re
import unicodedata

M = "http://schemas.openxmlformats.org/officeDocument/2006/math"


def q(tag):
    return "{%s}%s" % (M, tag)


SYM = {
    "≈": r"\approx ", "×": r"\times ", "⊗": r"\otimes ", "∑": r"\sum ", "∏": r"\prod ",
    "∫": r"\int ", "≥": r"\geq ", "≤": r"\leq ", "≠": r"\neq ", "∈": r"\in ", "∉": r"\notin ",
    "⇔": r"\Leftrightarrow ", "⇒": r"\Rightarrow ", "→": r"\rightarrow ", "←": r"\leftarrow ",
    "⟺": r"\Longleftrightarrow ", "∞": r"\infty ", "∀": r"\forall ", "∂": r"\partial ",
    "α": r"\alpha ", "β": r"\beta ", "γ": r"\gamma ", "δ": r"\delta ", "ε": r"\varepsilon ",
    "θ": r"\theta ", "λ": r"\lambda ", "μ": r"\mu ", "σ": r"\sigma ", "Σ": r"\Sigma ",
    "ψ": r"\psi ", "Ψ": r"\Psi ", "φ": r"\varphi ", "ω": r"\omega ", "Ω": r"\Omega ",
    "Δ": r"\Delta ", "Γ": r"\Gamma ", "π": r"\pi ", "τ": r"\tau ", "ν": r"\nu ", "ρ": r"\rho ",
    "⋯": r"\cdots ", "…": r"\ldots ", "⋮": r"\vdots ", "⋱": r"\ddots ", "·": r"\cdot ",
    "−": "-", "∗": "*", "‖": r"\| ", "∖": r"\setminus ", "⊂": r"\subset ", "∪": r"\cup ",
    "∩": r"\cap ", "°": r"^\circ ", "′": "'", "∥": r"\| ", "⊙": r"\odot ", "∘": r"\circ ",
    "{": r"\{", "}": r"\}", "%": r"\%", "#": r"\#", "&": r"\&", "_": r"\_", "~": r"\sim ",
    "\\": r"\backslash ", "⁡": "", "⁢": "", "​": "", "ℝ": r"\mathbb{R}",
    "ℕ": r"\mathbb{N}", "ℤ": r"\mathbb{Z}", "ℒ": r"\mathcal{L}", "ℱ": r"\mathcal{F}",
    "ℋ": r"\mathcal{H}", "ℬ": r"\mathcal{B}", "ℰ": r"\mathcal{E}", "ℳ": r"\mathcal{M}",
    "ℛ": r"\mathcal{R}", "ℐ": r"\mathcal{I}", "ℎ": "h", " ": " ",
}


def char(c):
    if c in SYM:
        return SYM[c]
    o = ord(c)
    if o < 128:
        return c
    try:
        n = unicodedata.name(c)
    except ValueError:
        return c
    if n.startswith("MATHEMATICAL"):
        letter = n.split()[-1]
        small = "SMALL" in n
        base = letter.lower() if small else letter
        if len(letter) > 1:  # greek names e.g. ALPHA
            letter = {"LAMDA": "LAMBDA", "EPSILON": "VAREPSILON" if "SYMBOL" not in n else "EPSILON"}.get(letter, letter)
            if "PARTIAL" in n: return r"\partial "
            if "NABLA" in n: return r"\nabla "
            g = "\\" + (letter.lower() if small else letter.capitalize()) + " "
            return g
        if "SCRIPT" in n or "CALLIGRAPHIC" in n:
            return r"\mathcal{%s}" % base
        if "DOUBLE-STRUCK" in n:
            return r"\mathbb{%s}" % base
        if "FRAKTUR" in n:
            return r"\mathfrak{%s}" % base
        if "BOLD" in n and "ITALIC" not in n:
            return r"\mathbf{%s}" % base
        return base
    return c


def text_of(r):
    return "".join(t.text or "" for t in r.iter(q("t")))


def kids(el, tag):
    c = el.find(q(tag))
    return conv_children(c) if c is not None else ""


def prop(el, prtag, name, default=None):
    pr = el.find(q(prtag))
    if pr is None:
        return default
    x = pr.find(q(name))
    if x is None:
        return default
    return x.get(q("val"), default if default is not None else "on")


DELIM = {"(": "(", ")": ")", "[": "[", "]": "]", "{": r"\{", "}": r"\}", "|": "|",
         "‖": r"\|", "⌊": r"\lfloor ", "⌋": r"\rfloor ", "⌈": r"\lceil ", "⌉": r"\rceil ",
         "⟨": r"\langle ", "⟩": r"\rangle ", "": ".", "〈": r"\langle ", "〉": r"\rangle "}
ACC = {"̂": r"\hat", "̃": r"\tilde", "̅": r"\overline", "⃗": r"\vec", "̇": r"\dot",
       "̈": r"\ddot", "́": r"\acute", "̌": r"\check", "̄": r"\bar", "⃡": r"\overleftrightarrow"}


def conv(el):
    tag = el.tag.split("}")[-1]
    if tag == "r":
        t = text_of(el)
        rpr = el.find(q("rPr"))
        normal = rpr is not None and (rpr.find(q("nor")) is not None or
                                     (rpr.find(q("sty")) is not None and rpr.find(q("sty")).get(q("val")) == "p"))
        font = ""
        arpr = el.find("{http://schemas.openxmlformats.org/drawingml/2006/main}rPr")
        if arpr is not None:
            lat = arpr.find("{http://schemas.openxmlformats.org/drawingml/2006/main}latin")
            if lat is not None: font = lat.get("typeface", "")
        if normal and "Script" in font and t.strip().isalpha() and t.strip().isupper():
            # a capital typed in a script font (e.g. "French Script MT"): tensor notation
            return "".join(r"\mathscr{%s}" % c for c in t.strip())
        if normal and t.strip():
            t2 = t.replace("\\", "").replace("{", r"\{").replace("}", r"\}").replace("%", r"\%").replace("&", r"\&").replace("#", r"\#").replace("_", r"\_")
            return r"\text{%s}" % t2
        if " " in t and sum(c.isalpha() for c in t) >= 3:
            # words written inside an equation, e.g. "Euclidean norm"
            t2 = t.replace("\\", "").replace("{", r"\{").replace("}", r"\}").replace("_", r"\_")
            return r"\textit{%s}" % "".join(char(c) if ord(c) > 127 and not c.isalpha() else c for c in t2)
        # spaces typed in an equation are visible in PowerPoint (often used to align parts)
        out = "".join(r"\ " if c in " \xa0" else char(c) for c in t)
        return out
    if tag in ("oMath", "e", "num", "den", "sub", "sup", "fName", "lim", "deg", "oMathPara"):
        return conv_children(el)
    if tag == "sSub":
        return "{%s}_{%s}" % (kids(el, "e"), kids(el, "sub"))
    if tag == "sSup":
        return "{%s}^{%s}" % (kids(el, "e"), kids(el, "sup"))
    if tag == "sSubSup":
        return "{%s}_{%s}^{%s}" % (kids(el, "e"), kids(el, "sub"), kids(el, "sup"))
    if tag == "sPre":
        return "{}_{%s}^{%s}{%s}" % (kids(el, "sub"), kids(el, "sup"), kids(el, "e"))
    if tag == "f":
        t = prop(el, "fPr", "type", "bar")
        if t == "lin":
            return "%s/%s" % (kids(el, "num"), kids(el, "den"))
        if t == "noBar":
            return r"\genfrac{}{}{0pt}{}{%s}{%s}" % (kids(el, "num"), kids(el, "den"))
        return r"\frac{%s}{%s}" % (kids(el, "num"), kids(el, "den"))
    if tag == "d":
        beg = prop(el, "dPr", "begChr", "(")
        end = prop(el, "dPr", "endChr", ")")
        sep = prop(el, "dPr", "sepChr", "|")
        es = [conv_children(e) for e in el.findall(q("e"))]
        sep_l = r"\middle| " if sep == "|" else char(sep)
        if sep == ",":
            sep_l = ","
        inner = sep_l.join(es) if len(es) > 1 else (es[0] if es else "")
        return r"\left%s %s \right%s" % (DELIM.get(beg, beg), inner, DELIM.get(end, end))
    if tag == "nary":
        c = prop(el, "naryPr", "chr", "∫")
        op = {"∑": r"\sum", "∏": r"\prod", "∫": r"\int", "∬": r"\iint", "∮": r"\oint",
              "⋃": r"\bigcup", "⋂": r"\bigcap"}.get(c, char(c))
        s = op
        subhide = prop(el, "naryPr", "subHide") in ("on", "1", "true")
        suphide = prop(el, "naryPr", "supHide") in ("on", "1", "true")
        if not subhide and el.find(q("sub")) is not None:
            sb = kids(el, "sub")
            if sb:
                s += "_{%s}" % sb
        if not suphide and el.find(q("sup")) is not None:
            sp = kids(el, "sup")
            if sp:
                s += "^{%s}" % sp
        return s + " " + kids(el, "e")
    if tag == "acc":
        c = prop(el, "accPr", "chr", "̂")
        return "%s{%s}" % (ACC.get(c, r"\hat"), kids(el, "e"))
    if tag == "bar":
        pos = prop(el, "barPr", "pos", "bot")
        return (r"\overline{%s}" if pos == "top" else r"\underline{%s}") % kids(el, "e")
    if tag == "func":
        fn = el.find(q("fName"))
        name = conv_children(fn) if fn is not None else ""
        plain = "".join(t.text or "" for t in fn.iter(q("t"))) if fn is not None else ""
        if plain.isalpha() and len(plain) > 1 and fn.find(q("r")) is not None and len(list(fn)) == 1:
            name = r"\operatorname{%s}" % plain
        return name + r"\," + kids(el, "e")
    if tag == "limLow":
        return r"\underset{%s}{%s}" % (kids(el, "lim"), kids(el, "e"))
    if tag == "limUpp":
        return r"\overset{%s}{%s}" % (kids(el, "lim"), kids(el, "e"))
    if tag == "groupChr":
        return r"\underbrace{%s}" % kids(el, "e")
    if tag == "eqArr":
        rows = [conv_children(e) for e in el.findall(q("e"))]
        def one_amp(r):
            i = r.find("&")
            return r if i < 0 else r[:i] + "&" + r[i + 1:].replace("&", "")
        rows = [one_amp(r) for r in rows]
        n = max(r.count("&") for r in rows) + 1
        # PowerPoint centres the rows of an equation array, or aligns them at "&" (rl)
        cols = "c" if n == 1 else ("rl" * n)[:n]
        return r"\begin{array}{%s}" % cols + r" \\ ".join(rows) + r"\end{array}"
    if tag == "m":
        rows = []
        for mr in el.findall(q("mr")):
            rows.append(" & ".join(conv_children(e) for e in mr.findall(q("e"))))
        return r"\begin{matrix}" + r" \\ ".join(rows) + r"\end{matrix}"
    if tag == "rad":
        deg = el.find(q("deg"))
        d = conv_children(deg) if deg is not None else ""
        return (r"\sqrt[%s]{%s}" % (d, kids(el, "e"))) if d else (r"\sqrt{%s}" % kids(el, "e"))
    if tag == "box" or tag == "borderBox" or tag == "phant":
        return kids(el, "e")
    if tag.endswith("Pr") or tag == "ctrlPr":
        return ""
    return conv_children(el)


def conv_children(el):
    return "".join(conv(c) for c in el if isinstance(c.tag, str))


def omml_to_latex(el):
    s = conv(el)
    s = re.sub(r"^\s*(\\ \s*)+|(\\ \s*)+$", "", s)   # leading / trailing typed spaces
    s = " ".join(s.split())
    return s
