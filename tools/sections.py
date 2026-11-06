"""Rewrite the section slides of the converted PhD deck with the talk extension:
   .section-header / .section-summary pairs, and .side-panel slides."""
import re, sys

SECTIONS = {
 14: dict(title="Barwise spectrograms", drop=["bb001586", "7d5e2de6"]),
 22: dict(title="Convolutive Block-Matching (CBM) algorithm", summary_title="CBM algorithm",
          sub=["[@marmoret2022cbm]", "(with open-source code)"],
          panel=["[@marmoret2022cbm]", "*(with open-source code)*"],
          drop=["bb001586", "df56f131", "bc5681b5", "7d5e2de6", "ee1b5fee", "1f2f37b8"]),
 33: dict(title="Nonnegative Tucker Decomposition",
          sub=["[@kim2007nonnegative; @smith2018nonnegative; @marmoret2020uncovering; @marmoret2022gretsi]"],
          drop=["bb001586", "ac8feebe", "7d5e2de6", "b78c9b32"], extra=" ref-size=11"),
 52: dict(title="Linear and Nonlinear Barwise Compression Schemes",
          sub=["[@marmoret2022barwise]"],
          drop=["bb001586", "f5579281", "7d5e2de6"]),
 57: dict(title="AE-NTD", sub=["Autoencoder & NTD"], drop=["bb001586", "52719cac"], extra=" subtitle-size=30"),
}
# static blue left panel (no transition)
PANELS = {
 3: dict(title="PhD,<br>in a nutshell", drop=["bb001586", "4a4b3465"]),
 9: dict(title="Machine Learning?", drop=["bb001586", "63ab7761"]),
}

def slide_span(s, n):
    a = s.index("## {#s%02d" % n)
    b = s.index("\n## ", a + 3) + 1
    return a, b

def chunks(body):
    """split slide body into top-level element chunks (list of strings)."""
    out, cur, depth = [], [], 0
    for line in body.split("\n"):
        if depth == 0 and not cur and line.strip() == "":
            out.append(line); continue
        cur.append(line)
        if re.match(r"^:{3,} \{", line) or re.match(r"^:{3,} notes$", line): depth += 1
        elif re.match(r"^:{3,}$", line): depth -= 1
        if depth == 0:
            out.append("\n".join(cur)); cur = []
    if cur: out.append("\n".join(cur))
    return out

def did(chunk):
    m = re.search(r'data-id="([^"]+)"', chunk.split("\n")[0])
    return m.group(1) if m else None

def rewrite_summary(s, n, title, cfg, cls):
    a, b = slide_span(s, n)
    body = s[a:b]
    head_line, rest = body.split("\n", 1)
    cm = re.search(r"<!-- pptx slide \d+ -->", rest).group(0)
    keep = [c for c in chunks(rest) if did(c) not in cfg["drop"] and not c.startswith("<!-- pptx")]
    parts = ["## %s {#s%02d .%s}" % (title, n, cls), "", cm, ""]
    if cfg.get("panel") or cfg.get("sub"):
        parts += ["::: {.section-panel}", "\n\n".join(cfg.get("panel", cfg.get("sub"))), ":::", ""]
    new = "\n".join(parts) + "\n".join(keep).strip("\n") + "\n\n"
    return s[:a] + new + s[b:]

def rewrite_header(s, n, cfg):
    a, b = slide_span(s, n)
    body = s[a:b]
    m = re.search(r"<!-- pptx slide \d+ -->", body)
    parts = ["## %s {#s%02d .section-header%s}" % (cfg["title"], n, cfg.get("extra", "")), "", m.group(0), ""]
    if cfg.get("sub"): parts += ["\n\n".join(cfg["sub"]), ""]
    parts += [c for c in chunks(body.split("\n", 1)[1]) if c.startswith("::: notes")]
    return s[:a] + "\n".join(parts).rstrip("\n") + "\n\n" + s[b:]

def convert(s):
    for n in sorted(list(SECTIONS) + list(PANELS), reverse=True):
        if n in SECTIONS:
            cfg = SECTIONS[n]
            s = rewrite_summary(s, n + 1, cfg.get("summary_title", cfg["title"]), cfg, "section-summary")
            s = rewrite_header(s, n, cfg)
        else:
            cfg = PANELS[n]
            s = rewrite_summary(s, n, cfg["title"], cfg, "side-panel")
    return re.sub(r"\n{3,}", "\n\n", s)

if __name__ == "__main__":
    p = sys.argv[1]
    txt = convert(open(p).read())
    open(p, "w").write(txt)
    print("ok")
