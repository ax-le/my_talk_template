"""deck_patches.py — hand-made rewrites of the PhD-defense deck, applied after the converter.

Overlays that cannot be guessed automatically (ellipses drawn over parts of an equation,
halos around boxes) are replaced here by native highlights:
  * equations:  \\hlo{steps}{colour}{part}  (oval)   /  \\hl{steps}{colour}{part}  (rounded box)
  * objects:    hl="6- purple" hl-shape=round hl-pad=12px

Ops per slide id: replace (text), sub (regex), drop (data-ids), attrs (added to a data-id's
block), append (before the notes), colour-names.

Usage:  python3 deck_patches.py deck.qmd
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from highlights import parse  # noqa: E402

PATCHES = {
    "s01": {   # test slide: the sound check as an audio shortcode (hand edit of index.qmd, 5 Nov.)
        "sub": [
            (r'\[\]\{[^}\n]*#aud-0770e834[^}\n]*\}', '{{< audio media/media1.mp3 id=snd >}}'),
            (r'data-play="aud-0770e834"', 'data-play="snd"'),
        ],
    },
    "s08": {   # Practical example: the section labels take the palette colours of the overlay
        "colour-names": True,
    },
    "s60": {   # NTD matricisation
        "replace": [(
            r"$${\Longleftrightarrow \mathscr{X}}_{(2)}\approx {Q\mathscr{G}}_{\left( 2 \right)}{\left( W\otimes H \right)}^{T}$$",
            r"$$\mathrel{\eqmark{iff}{\Longleftrightarrow}} \hlo[x2]{2-}{teal}{\mathscr{X}_{(2)}} "
            r"\mathrel{\hlo[approx]{3-}{orange}{\approx}} \hlo[q]{4-}{purple}{Q}\,"
            r"\hlo[gwh]{4-}{purple}{\mathscr{G}_{\left( 2 \right)}{\left( W\mathbin{\eqmark{kron}{\otimes}} H \right)}^{T}}$$",
        )],
        "drop": [
            # ellipses over the equation, halos around G(2) and (W⊗H)^T
            "c48729b2", "01f95268", "89774131", "7ebf9a25", "76c1fffe", "35564bd9",
            # labels and arrows placed by hand → annotations attached to the equation
            "b589db09", "ed711296", "688fa25f", "50f03fba", "bb32412a", "90748793",
            "313b2597", "51d0e9d1", "3cd9975e", "73f86c2f", "4223bc1c",
            "f0557c4b", "0a49d3ef", "656d9aea",
        ],
        "attrs": {
            "b91f3b62": ' #ann-g2 hl="6- purple" hl-shape=round hl-radius=21 hl-pad=12',
            "a6e78c2b": ' #ann-wh hl="6- purple" hl-shape=round hl-radius=34 hl-pad=20',
        },
        "append": r"""
::: {.annot to=iff pos=below dist=2 steps=1 arrow=none box=false color=black}
“Matricisation”
:::

::: {.annot to=kron pos=above dist=36 steps=1 arrow=thin box=false color=black size=19.8}
Kronecker product
:::

::: {.annot to=x2 pos=below dist=58 steps=2- sub="(“unfolding” of the tensor)"}
Barwise TF matrix
:::

::: {.annot to=approx pos=above dist=58 steps=3-}
Latent<br>representation
:::

::: {.annot to="q gwh" pos=below dist=70 shift=75 steps=4-}
2 matrix products
:::

::: {.annot to="ann-g2 ann-wh" x=553 y=639 steps=6-}
2 fully-connected<br>layers
:::
""",
    },
}

def colour_names(lines):
    """text boxes coloured with a palette colour (background:rgba(…) + rounded corners) → the same
    colour by name, as a highlight under their text: hl="0- intro" hl-radius=10.7, so that they
    match the coloured cells of the overlay (same names, same transparency)."""
    from segments import colour_name
    out = []
    for l in lines:
        m = re.match(r'^(:::+ \{.*style=")([^"]*)(".*\})\s*$', l)
        if m and "background:" in m.group(2) and " .tb" in m.group(1):      # labels, not the overlay
            st = dict(x.split(":", 1) for x in m.group(2).split(";") if ":" in x)
            name, alpha = colour_name(st.get("background", ""))
            if name and not name.startswith("#"):
                rad = st.pop("border-radius", None)
                del st["background"]
                extra = ' hl="0- %s"' % name + (" hl-radius=%s" % rad.replace("px", "") if rad else "")
                if alpha is not None and abs(alpha - 0.5) > 0.01: extra += " hl-opacity=%g" % alpha
                l = m.group(1) + ";".join("%s:%s" % kv for kv in st.items()) + m.group(3)[:-1] + extra + "}"
        out.append(l)
    return out


def patch_slide(lines, p):
    if p.get("colour-names"): lines = colour_names(lines)
    text = "\n".join(lines)
    for old, new in p.get("replace", []):
        if old not in text:
            print("deck_patches: text not found:", old[:60])
        text = text.replace(old, new)
    for pat, new in p.get("sub", []):          # regular expressions
        text, n = re.subn(pat, lambda m: new, text)
        if not n: print("deck_patches: pattern not found:", pat[:60])
    lines = text.split("\n")
    objs = parse(lines)
    for o in objs:
        m = re.search(r'data-id="([^"]+)"', o.attrs)
        did = m.group(1) if m else None
        if did in p.get("attrs", {}):
            k = o.start
            i = lines[k].rstrip().rfind("}")
            lines[k] = lines[k][:i].rstrip() + p["attrs"][did] + lines[k][i:]
    for o in sorted(objs, key=lambda o: -o.start):
        m = re.search(r'data-id="([^"]+)"', o.attrs)
        if m and m.group(1).removesuffix("-w") in p.get("drop", []):
            end = o.end + 1
            if end < len(lines) and not lines[end].strip():
                end += 1
            del lines[o.start:end]
    if p.get("append"):
        k = next((i for i, l in enumerate(lines) if l.startswith("::: notes")), len(lines))
        lines[k:k] = p["append"].strip("\n").split("\n") + [""]
    return lines


def main(path):
    src = open(path, encoding="utf-8").read().split("\n")
    out, slide, sid = [], [], None
    for l in src + ["## {#__END__}"]:
        if l.startswith("## "):
            out += patch_slide(slide, PATCHES[sid]) if sid in PATCHES else slide
            m = re.search(r"\{#(\w+)", l)
            sid, slide = (m.group(1) if m else None), []
        slide.append(l)
    open(path, "w", encoding="utf-8").write("\n".join(out))
    print("deck_patches: %d slide(s) patched" % len(PATCHES))


if __name__ == "__main__":
    main(sys.argv[1])
