--[[
  talk.lua — Quarto filter of the "talk" extension (see README.md for the user guide).

  * Section slides with a Morph-like transition:   ## T {.section-header}  →  ## T {.section-summary}
  * Static side-panel slides:                       ## T {.side-panel}
  * Native highlights:                              {hl="2-3"}  {cols=4 hl="2@1; 3@2; 4-@4 purple"}  $\hlo{2-}{teal}{x}$
                                                    {hl="5@(37%,30%,7%,19%)"}  (any div, span or image)
  * 3D-tilted elements:                             ![](img.png){rotate-x=-35 rotate-y=-50 rotate-z=45 perspective=900}
  * Theme colours from YAML:                        talk: colors: {background, text, title, bar, accent}
  * Citations (bib files + [@key]) with biblatex-like labels ([MCB22a]), the references
    of each slide at its bottom, \fullcite-like [@key]{.fullcite}, and a ::: {#refs} slide.
  * Loads talk.js (audio, morph helpers) and the fonts.
]]

local stringify = pandoc.utils.stringify

-- ---------------------------------------------------------------------------- options
local VARS = {
  ["color"] = "--sec-color", ["text-color"] = "--sec-text", ["ref-color"] = "--sec-ref-color",
  ["panel-width"] = "--sec-panel-width", ["title-size"] = "--sec-title-size",
  ["summary-title-size"] = "--sec-summary-title-size", ["subtitle-size"] = "--sec-subtitle-size",
  ["ref-size"] = "--sec-ref-size", ["title-width"] = "--sec-title-width",
  ["title-weight"] = "--sec-title-weight", ["panel-padding"] = "--sec-panel-padding",
  ["panel-subtitle-size"] = "--sec-panel-subtitle-size",
  ["panel-top"] = "--sec-panel-top", ["border-width"] = "--sec-border-width",
  ["border-color"] = "--sec-border-color",
}
local LENGTH = { ["panel-width"] = 1, ["title-size"] = 1, ["summary-title-size"] = 1, ["subtitle-size"] = 1, ["panel-subtitle-size"] = 1,
  ["ref-size"] = 1, ["title-width"] = 1, ["panel-padding"] = 1, ["panel-top"] = 1, ["border-width"] = 1 }

local global = { duration = "1.2", easing = "ease-in-out", color = "#69A1AB",
                 ["title-size"] = "60", ["summary-title-size"] = "50", ["panel-width"] = "440",
                 ["subtitle-size"] = "24" }
-- sizes inside the panel follow its width: the summary title and the panel subtitle are given
-- for a 440 px panel and grow with panel-width, unless set explicitly (the padding stays);
-- source option → option of the summary layout
local PANEL_SIZES = { ["summary-title-size"] = "summary-title-size", ["subtitle-size"] = "panel-subtitle-size" }

local cite = { enabled = false, slide_refs = true, refs = nil, labels = {}, csl = nil, highlight = nil, used = {}, own = {} }

local function has_class(el, c)
  for _, k in ipairs(el.classes or {}) do if k == c then return true end end
  return false
end
local function css_size(v)
  if tostring(v):match("^%-?[%d%.]+$") then return v .. "px" end
  return v
end
local function px_number(v)
  local n = tostring(v or ""):match("^%s*([%d%.]+)%s*p?x?%s*$")
  return n and tonumber(n) or nil
end

-- ---------------------------------------------------------------------------- word splitting
local PUNCT = {}
for _, c in utf8.codes("()[]{},.;:!?«»\"“”‘’/|") do PUNCT[c] = true end

local function tokens(s)
  local out, cur = {}, {}
  local function flush() if #cur > 0 then out[#out + 1] = table.concat(cur); cur = {} end end
  for _, c in utf8.codes(s) do
    if PUNCT[c] then flush(); out[#out + 1] = utf8.char(c)
    else cur[#cur + 1] = utf8.char(c) end
  end
  flush()
  return out
end

local function keyof(tok)
  local k = tok:lower():gsub("[%s\"'<>&=]", "")
  if k == "" then k = "x" end
  return k
end

-- every word / punctuation mark → <span class="w" data-id="…">  (ids collected in `ids`)
local function wordify(inlines, prefix, ids)
  local occ = {}
  local function id_for(k)
    occ[k] = (occ[k] or 0) + 1
    local id = prefix .. "-w-" .. k .. "-" .. occ[k]
    if ids then ids[id] = true end
    return id
  end
  return pandoc.Inlines(inlines):walk({
    Str = function(s)
      local res = {}
      for _, tok in ipairs(tokens(s.text)) do
        res[#res + 1] = pandoc.Span({ pandoc.Str(tok) }, pandoc.Attr("", { "w" }, { { "data-id", id_for(keyof(tok)) } }))
      end
      if #res == 1 then return res end
      return pandoc.Span(res, pandoc.Attr("", { "wg" }))      -- "(CBM)" never broken across lines
    end,
    Math = function(m)
      return pandoc.Span({ m }, pandoc.Attr("", { "w" }, { { "data-id", id_for("m" .. keyof(m.text)) } }))
    end,
  })
end

local function wordify_blocks(blocks, prefix, ids)
  local i = 0
  return pandoc.Blocks(blocks):walk({
    Plain = function(b) i = i + 1; return pandoc.Plain(wordify(b.content, prefix .. "-" .. i, ids)) end,
    -- no <p>: reveal.js also pairs paragraphs by their text, which would move them twice
    Para = function(b) i = i + 1; return pandoc.Div({ pandoc.Plain(wordify(b.content, prefix .. "-" .. i, ids)) }, pandoc.Attr("", { "sec-p" })) end,
  })
end

-- keep data-id only where keep(id) is true (used for the invisible "ghost" copies)
local function filter_ids(blocks, keep)
  local function f(el)
    local id = el.attributes["data-id"]
    if id and not keep(id) then el.attributes["data-id"] = nil; return el end
  end
  return pandoc.Blocks(blocks):walk({ Span = f, Div = f })
end

-- ---------------------------------------------------------------------------- citations
-- biblatex "alphabetic"-like labels: Foo00, MCB22, Mar+20 (+ a/b suffixes). A `shorthand`
-- field in the .bib file always wins (so labels match the ones of a LaTeX thesis).
local function read_shorthands(paths)
  local map = {}
  for _, p in ipairs(paths) do
    local f = io.open(p, "r")
    if f then
      local txt = f:read("a"); f:close()
      for key, body in txt:gmatch("@%a+%s*{%s*([^,%s]+)%s*,(.-)\n%s*}") do
        local sh = body:match("[Ss]horthand%s*=%s*[{\"]([^}\"]+)[}\"]")
        if sh then map[key] = sh end
      end
    end
  end
  return map
end

local function first_chars(s, n)
  local out = {}
  for _, c in utf8.codes(s) do
    out[#out + 1] = utf8.char(c)
    if #out >= n then break end
  end
  return table.concat(out)
end

local function alpha_label(r)
  local names = {}
  for _, a in ipairs(r.author or r.editor or {}) do
    names[#names + 1] = stringify(a.family or a.literal or "")
  end
  local year = ""
  if r.issued and r.issued["date-parts"] and r.issued["date-parts"][1] then
    year = stringify(r.issued["date-parts"][1][1] or ""):sub(-2)
  end
  local lab
  if #names == 0 then lab = first_chars(stringify(r.id), 3)
  elseif #names == 1 then lab = first_chars(names[1], 3)
  elseif #names <= 3 then
    lab = ""
    for _, n in ipairs(names) do lab = lab .. first_chars(n, 1) end
  else lab = first_chars(names[1], 3) .. "+" end
  return lab .. year
end

local function setup_citations(doc, opts)
  local bib = doc.meta.bibliography
  if not bib then return end
  local paths = {}
  if bib.t == "MetaList" or (type(bib) == "table" and bib[1] ~= nil and bib.t ~= "MetaInlines") then
    for _, b in ipairs(bib) do paths[#paths + 1] = stringify(b) end
  else paths[1] = stringify(bib) end
  local refs = pandoc.utils.references(doc)
  if not refs or #refs == 0 then return end
  local short = read_shorthands(paths)
  -- labels
  local count, assigned = {}, {}
  for _, r in ipairs(refs) do
    local id = stringify(r.id)
    if short[id] then assigned[id] = short[id]
    else
      local l = alpha_label(r); assigned[id] = l; count[l] = (count[l] or 0) + 1
    end
  end
  local seen = {}
  for _, r in ipairs(refs) do
    local id = stringify(r.id)
    local l = assigned[id]
    if not short[id] and count[l] > 1 then
      seen[l] = (seen[l] or 0) + 1
      l = l .. string.char(96 + seen[l])
    end
    r["citation-label"] = l
    cite.labels[id] = l
    if opts["highlight-author"] then
      local hl = stringify(opts["highlight-author"])
      for _, a in ipairs(r.author or {}) do
        if stringify(a.family or "") == hl then cite.own[id] = true end
      end
    end
  end
  doc.meta.references = refs
  doc.meta.bibliography = nil
  if not doc.meta.csl then
    doc.meta.csl = pandoc.MetaString(quarto.utils.resolve_path("alphabetic.csl"))
  end
  cite.refs = refs
  cite.meta = doc.meta
  cite.enabled = true
  if opts["slide-refs"] ~= nil then cite.slide_refs = stringify(opts["slide-refs"]) ~= "false" end
  if opts["highlight-author"] then cite.highlight = stringify(opts["highlight-author"]) end
end

-- formatted bibliography entries for a list of keys → list of Blocks (one Div per entry)
local entry_cache = {}
local function entries_for(keys)
  if not cite.enabled or #keys == 0 then return {} end
  local todo = {}
  for _, k in ipairs(keys) do if not entry_cache[k] then todo[#todo + 1] = k end end
  if #todo > 0 then
    local cits = {}
    for _, k in ipairs(todo) do cits[#cits + 1] = pandoc.Citation(k, "NormalCitation") end
    local mini = pandoc.Pandoc({ pandoc.Para({ pandoc.Cite({ pandoc.Str("x") }, cits) }),
      pandoc.Div({}, pandoc.Attr("refs")) }, cite.meta)
    local ok, res = pcall(pandoc.utils.citeproc, mini)
    if ok then
      res.blocks:walk({ Div = function(d)
        local k = d.identifier:match("^ref%-(.+)$")
        if k then
          local blocks = d.content
          if cite.highlight then
            local lab = "[" .. (cite.labels[k] or "") .. "]"
            blocks = pandoc.Blocks(blocks):walk({ Str = function(s)
              if s.text:find(cite.highlight, 1, true) == 1 then return pandoc.Strong({ s }) end
              if cite.own[k] and s.text == lab then return pandoc.Strong({ s }) end
            end })
          end
          entry_cache[k] = blocks
        end
      end })
    end
  end
  local out = {}
  for _, k in ipairs(keys) do
    if entry_cache[k] then out[#out + 1] = pandoc.Div(entry_cache[k], pandoc.Attr("", { "talk-ref-entry" })) end
  end
  return out
end

local function cited_keys(blocks)
  local keys, seen = {}, {}
  pandoc.Blocks(blocks):walk({ Cite = function(c)
    for _, ci in ipairs(c.citations) do
      if not seen[ci.id] and cite.labels[ci.id] then seen[ci.id] = true; keys[#keys + 1] = ci.id end
    end
  end })
  return keys
end

-- Cite → "[KC07, **Mar+20**]" (own works in bold). Used in section titles (the words must
-- exist before citeproc) and, at the end, for every citation of the document.
local function render_cite(c)
  local inl = {}
  local bracket = c.citations[1] and c.citations[1].mode ~= "AuthorInText"
  if bracket then inl[#inl + 1] = pandoc.Str("[") end
  for j, ci in ipairs(c.citations) do
    cite.used[#cite.used + 1] = ci.id
    if j > 1 then inl[#inl + 1] = pandoc.Str(","); inl[#inl + 1] = pandoc.Space() end
    for _, x in ipairs(ci.prefix or {}) do inl[#inl + 1] = x end
    if ci.prefix and #ci.prefix > 0 then inl[#inl + 1] = pandoc.Space() end
    local lab = pandoc.Str(cite.labels[ci.id] or ci.id)
    inl[#inl + 1] = cite.own[ci.id] and pandoc.Strong({ lab }) or lab
    for _, x in ipairs(ci.suffix or {}) do inl[#inl + 1] = x end
  end
  if bracket then inl[#inl + 1] = pandoc.Str("]") end
  return pandoc.Span(inl, pandoc.Attr("", { "citation" }))
end

local function resolve_cites(blocks)
  return pandoc.Blocks(blocks):walk({ Cite = function(c)
    if not cite.enabled then return nil end
    return render_cite(c)
  end })
end

-- [@key]{.fullcite}  →  the full formatted entry (like biblatex \fullcite)
local function fullcites(blocks)
  return pandoc.Blocks(blocks):walk({ Span = function(s)
    if not has_class(s, "fullcite") or not cite.enabled then return nil end
    local keys = cited_keys({ pandoc.Plain(s.content) })
    local out = {}
    for _, e in ipairs(entries_for(keys)) do
      out[#out + 1] = pandoc.Span(pandoc.utils.blocks_to_inlines(e.content), pandoc.Attr("", { "fullcite" }))
    end
    return out
  end })
end

-- ---------------------------------------------------------------------------- section slides
local function take_options(h, inherited)
  local o = {}
  for k, v in pairs(inherited or {}) do o[k] = v end
  for k, _ in pairs(VARS) do
    if h.attributes[k] then o[k] = h.attributes[k]; h.attributes[k] = nil end
  end
  for _, k in ipairs({ "duration", "easing" }) do
    if h.attributes[k] then o[k] = h.attributes[k]; h.attributes[k] = nil end
  end
  if h.attributes["section-style"] then o.style = h.attributes["section-style"]; h.attributes["section-style"] = nil end
  return o
end

local function style_of(o)
  local parts = {}
  -- a panel-width of its own: the panel sizes not given scale with it (from the deck's values)
  local pw, gpw = px_number(o["panel-width"]), px_number(global["panel-width"])
  if pw and gpw and gpw > 0 and pw ~= gpw then
    for k, target in pairs(PANEL_SIZES) do
      if not o[k] and not o[target] and px_number(global[k]) then
        o[target] = string.format("%.4g", px_number(global[k]) * pw / gpw)
      end
    end
  end
  for k, var in pairs(VARS) do
    if o[k] then
      local v = o[k]
      if LENGTH[k] then v = css_size(v) end
      parts[#parts + 1] = var .. ":" .. v
    end
  end
  -- the summary title is the header title, scaled: no font-size change → pure-transform morph
  local t = px_number(o["title-size"] or global["title-size"])
  local s = px_number(o["summary-title-size"] or global["summary-title-size"])
  if t and s and t > 0 then parts[#parts + 1] = string.format("--sec-title-ratio:%.4f", s / t) end
  table.sort(parts)
  return table.concat(parts, ";")
end

local function split_body(body)
  local r = { ref = nil, panel = nil, notes = {}, rest = {} }
  for _, b in ipairs(body) do
    if b.t == "Div" and has_class(b, "section-ref") then r.ref = b.content
    elseif b.t == "Div" and has_class(b, "section-panel") then r.panel = b.content
    elseif b.t == "Div" and has_class(b, "notes") then r.notes[#r.notes + 1] = b
    else r.rest[#r.rest + 1] = b end
  end
  return r
end

-- text group (title + subtitle) and reference block, laid out as `layout` ("header"/"summary")
local function text_blocks(layout, title_inlines, subs, ref, prefix, ids)
  local out = {}
  local title = pandoc.Div({ pandoc.Plain(wordify(title_inlines, prefix, ids)) }, pandoc.Attr("", { "sec-title" }))
  local inner = { title }
  if subs and #subs > 0 then
    inner[#inner + 1] = pandoc.Div(wordify_blocks(subs, prefix .. "-s", ids), pandoc.Attr("", { "sec-sub" }))
  end
  out[#out + 1] = pandoc.Div(inner, pandoc.Attr("", { "sec-text", "lay-" .. layout }))
  if ref and #ref > 0 then
    out[#out + 1] = pandoc.Div(wordify_blocks(ref, prefix .. "-r", ids), pandoc.Attr("", { "sec-ref", "lay-" .. layout }))
  end
  return out
end

-- one section-like slide.  kind: header | summary | panel
local function section_info(h, body, kind)
  local parts = split_body(body)
  local info = { h = h, kind = kind, notes = parts.notes, rest = parts.rest }
  info.title = resolve_cites(pandoc.Blocks({ pandoc.Plain(h.content) }))[1].content
  if kind == "header" then
    info.subs = parts.rest; info.rest = {}
  else
    info.subs = parts.panel or {}
  end
  local keys = cited_keys(pandoc.Blocks({ pandoc.Plain(h.content) }) .. pandoc.Blocks(info.subs))
  info.subs = resolve_cites(info.subs)
  if parts.ref then info.ref = parts.ref
  elseif cite.enabled and cite.slide_refs and #keys > 0 then info.ref = entries_for(keys) end
  -- content of the slide body (summary/panel) keeps its own references at the bottom
  return info
end

local function slide_attrs(info, opts, pid)
  local h = info.h
  h.classes:insert("talk-sec"); h.classes:insert("talk-sec-" .. info.kind); h.classes:insert("nobar")
  -- header + summary count as ONE slide in the slide counter: the summary is "uncounted"
  -- (reveal.js then shows the header's number on it)
  if info.kind == "summary" and info.paired and not h.attributes["visibility"] then
    h.attributes["visibility"] = "uncounted"
  end
  if pid then
    h.attributes["auto-animate"] = "true"
    h.attributes["auto-animate-id"] = pid
    h.attributes["auto-animate-duration"] = opts.duration or global.duration
    h.attributes["auto-animate-easing"] = opts.easing or global.easing
  end
  -- (no slide background colour: the block itself reaches the screen edges, so the
  --  backward morph summary → header can grow it smoothly)
  local st = style_of(opts)
  if st ~= "" then h.attributes["style"] = (h.attributes["style"] and (h.attributes["style"] .. ";") or "") .. st end
end

local function layout_of(kind) return kind == "header" and "header" or "summary" end

local slide_refs_div -- forward

-- build one or two (header + summary) slides
local function build_section(a, b, opts_a, opts_b, pid)
  local out = {}
  local prefix = pid or ("talk-panel-" .. tostring(math.random(1e9)))
  local ids_a, ids_b = {}, {}
  local real_a = text_blocks(layout_of(a.kind), a.title, a.subs, a.ref, prefix, ids_a)
  local real_b = b and text_blocks(layout_of(b.kind), b.title, b.subs, b.ref, prefix, ids_b) or nil

  local function emit(info, opts, real, other, own_ids, other_ids, other_main)
    slide_attrs(info, opts, pid)
    out[#out + 1] = info.h
    -- colour block = a fill + four border bars, all animated with transforms only
    -- (GPU-composited: no re-layout of a huge box at every frame)
    out[#out + 1] = pandoc.Div({}, pandoc.Attr("", { "sec-block" }, { { "data-id", prefix .. "-block" } }))
    for _, e in ipairs({ "l", "t", "b", "r" }) do
      out[#out + 1] = pandoc.Div({}, pandoc.Attr("", { "sec-edge", "sec-edge-" .. e }, { { "data-id", prefix .. "-edge-" .. e } }))
    end
    for _, x in ipairs(real) do out[#out + 1] = x end
    if other then
      -- invisible copy of the other slide's text, at the other slide's place: words that
      -- exist only there fade in/out in place instead of popping
      local ghost = filter_ids(other, function(id) return not own_ids[id] end)
      out[#out + 1] = pandoc.Div(ghost, pandoc.Attr("", { "sec-ghost" }, { { "aria-hidden", "true" } }))
    end
    if info.kind == "header" and other_main and #other_main > 0 then
      -- the summary's content, hidden under the block: when going back (summary → header)
      -- the growing block covers it instead of it vanishing at once
      local function clean(d)
        d.identifier = ""
        local st = d.attributes["style"] or ""
        if st:find("transform", 1, true) or d.attributes["rotate-x"] or d.attributes["rotate-y"]
            or d.attributes["rotate-z"] or d.attributes["face"] then
          d.attributes["data-id"] = nil   -- reveal would override its own transform
        end
        for _, k in ipairs({ "data-audio", "data-autoplay", "data-play", "data-fragment-index", "fragment-index", "hl", "cols", "rows", "lines" }) do d.attributes[k] = nil end
        local keep = {}
        for _, c in ipairs(d.classes) do
          if c ~= "fragment" and c ~= "fade-out" and c ~= "move" and c ~= "audio-btn" then keep[#keep + 1] = c end
        end
        d.classes = keep
        return d
      end
      local copy = pandoc.Blocks(other_main):walk({ Div = clean, Span = clean, Image = clean })
      out[#out + 1] = pandoc.Div(copy, pandoc.Attr("", { "sec-main", "sec-main-copy" }, { { "aria-hidden", "true" } }))
    end
    if info.kind ~= "header" and #info.rest > 0 then
      local main = info.rest
      if cite.enabled and cite.slide_refs and not has_class(info.h, "no-slide-refs") then
        local extra = slide_refs_div(main)
        if extra then main = pandoc.Blocks(main) .. pandoc.Blocks({ extra }) end
      end
      out[#out + 1] = pandoc.Div(main, pandoc.Attr("", { "sec-main" }))
    end
    for _, n in ipairs(info.notes) do out[#out + 1] = n end
  end

  if b then
    -- the ghosts need the other slide's blocks rendered again (fresh copies, same ids)
    local ghost_of_b = text_blocks(layout_of(b.kind), b.title, b.subs, b.ref, prefix, nil)
    local ghost_of_a = text_blocks(layout_of(a.kind), a.title, a.subs, a.ref, prefix, nil)
    emit(a, opts_a, real_a, ghost_of_b, ids_a, ids_b, b.rest)
    emit(b, opts_b, real_b, ghost_of_a, ids_b, ids_a)
  else
    emit(a, opts_a, real_a, nil, ids_a, {})
  end
  return out
end

-- ---------------------------------------------------------------------------- per-slide refs
slide_refs_div = function(blocks)
  local keys = cited_keys(blocks)
  if #keys == 0 then return nil end
  local e = entries_for(keys)
  if #e == 0 then return nil end
  return pandoc.Div(e, pandoc.Attr("", { "slide-refs" }))
end


-- ---------------------------------------------------------------------------- highlights
-- hl="STEPS[@AREA]; …" on a div, span or image highlights the object itself (or a part of it)
-- during the given fragment steps. The highlight lives inside the object: it follows its
-- position, size and morphs, and borders stay on top.
--   STEPS : n (only at step n) | n-m | n- (from n to the end of the slide) ; 0 = before any click
--   AREA  : none (whole object) | k, k-l (cell numbers of the grid cols= / rows=, row-major)
--           | c,r with c and r = n, n-m or * (column, row) | (x,y,w,h) in % of the object, or px
local function trim(x) return (x:gsub("^%s+", ""):gsub("%s+$", "")) end
local function len(v)
  v = trim(v)
  if v:match("px$") or v:match("%%$") then return v end
  return v .. "%"
end
local function range(v, n)
  v = trim(v)
  if v == "*" then return 1, n end
  local a, b = v:match("^(%d+)%s*%-%s*(%d+)$")
  if a then return tonumber(a), tonumber(b) end
  local k = tonumber(v); return k, k
end
local function pct(x) return string.format("%.6g%%", x) end

-- grid geometry: g = { nc, nr, xs = {0, …, 100}, ys = {0, …, 100} } (cell boundaries in %)
local function boundaries(spec)
  -- "5" → 5 equal parts; "2 2 1 1" → relative sizes
  local parts = {}
  for w in tostring(spec or "1"):gmatch("[^%s,]+") do parts[#parts + 1] = tonumber(w) or 1 end
  if #parts == 1 and parts[1] >= 1 and math.floor(parts[1]) == parts[1] then
    local n = parts[1]; parts = {}
    for i = 1, n do parts[i] = 1 end
  end
  local tot = 0
  for _, w in ipairs(parts) do tot = tot + w end
  local out, acc = { 0 }, 0
  for _, w in ipairs(parts) do acc = acc + w; out[#out + 1] = acc * 100 / tot end
  out[#out] = 100
  return out
end
local function grid_of(cols, rows)
  local xs, ys = boundaries(cols), boundaries(rows)
  return { nc = #xs - 1, nr = #ys - 1, xs = xs, ys = ys }
end

-- a cell edge in CSS: whole pixels when the inner size of the box is known (g.iw / g.ih,
-- set by grid_box: the lines of the box are placed on the same pixels), else in %
local function edge(p, size)
  if size then return string.format("%dpx", math.floor(size * p / 100 + 0.5)) end
  return pct(p)
end
local function area_style(area, g)
  local cols, rows = g.nc, g.nr
  if not area or area == "" then return "left:0;top:0;width:100%;height:100%" end
  local box = area:match("^%((.*)%)$")
  if box then
    local v = {}
    for x in box:gmatch("[^,]+") do v[#v + 1] = len(x) end
    if #v ~= 4 then return nil end
    return "left:" .. v[1] .. ";top:" .. v[2] .. ";width:" .. v[3] .. ";height:" .. v[4]
  end
  local c0, c1, r0, r1
  local cs, rs = area:match("^([^,]+),([^,]+)$")
  if cs then
    c0, c1 = range(cs, cols); r0, r1 = range(rs, rows)
  else
    local a, b = range(area, cols * rows)
    if not a then return nil end
    if cols == 1 or rows == 1 then            -- 1-D grid: k counts along its only axis
      if cols == 1 then c0, c1, r0, r1 = 1, 1, a, b else c0, c1, r0, r1 = a, b, 1, 1 end
    else                                       -- row-major, bounding box of the cells a..b
      local ca, ra = (a - 1) % cols + 1, (a - 1) // cols + 1
      local cb, rb = (b - 1) % cols + 1, (b - 1) // cols + 1
      c0, c1, r0, r1 = math.min(ca, cb), math.max(ca, cb), ra, rb
    end
  end
  if not (c0 and c1 and r0 and r1) or c1 > cols or r1 > rows then return nil end
  local st
  if g.iw and g.ih then
    -- left/top and right/bottom edges on the pixel grid of the box, like its lines
    local x0, x1 = edge(g.xs[c0], g.iw), edge(g.xs[c1 + 1], g.iw)
    local y0, y1 = edge(g.ys[r0], g.ih), edge(g.ys[r1 + 1], g.ih)
    st = "left:" .. x0 .. ";top:" .. y0 .. ";width:" .. (px_number(x1) - px_number(x0)) .. "px;height:" .. (px_number(y1) - px_number(y0)) .. "px"
  else
    st = "left:" .. pct(g.xs[c0]) .. ";top:" .. pct(g.ys[r0]) ..
         ";width:" .. pct(g.xs[c1 + 1] - g.xs[c0]) .. ";height:" .. pct(g.ys[r1 + 1] - g.ys[r0])
  end
  return st, { c0 = c0, c1 = c1, r0 = r0, r1 = r1 }
end

local function parse_steps(steps)
  local a, b = steps:match("^(%d+)%s*%-%s*(%d+)$")
  if not a then a = steps:match("^(%d+)%s*%-$"); if a then b = "end" end end
  if not a then a = steps:match("^(%d+)$"); b = a end
  return a and tonumber(a) or nil, b
end
-- outer element: appears at step a; inner: disappears after step b ("end": stays)
local function step_attrs(a, b)
  local o_cls, o_at, i_cls, i_at = {}, {}, {}, {}
  if a and a > 0 then o_cls[#o_cls + 1] = "fragment"; o_at[#o_at + 1] = { "data-fragment-index", tostring(a) } end
  if b and b ~= "end" then
    i_cls = { "fragment", "fade-out" }; i_at = { { "data-fragment-index", tostring(tonumber(b) + 1) } }
  end
  return o_cls, o_at, i_cls, i_at
end

-- a palette name (CSS var --hl-NAME, YAML talk: highlight: colors) or any CSS colour
-- theme colour names (YAML talk: colors) usable wherever a colour is expected
local THEME = { text = "--talk-text", title = "--talk-title", accent = "--talk-accent",
                background = "--talk-bg", bar = "--talk-bar" }
local function color_value(c)
  if c:sub(1, 1) == "#" or c:find("(", 1, true) then return c end
  if THEME[c] then return "var(" .. THEME[c] .. ")" end
  return "var(--hl-" .. c .. ", " .. c .. ")"
end

local function hl_regions(spec, g, inline)
  local cols, rows = g.nc, g.nr
  local mk = inline and function(c, a) return pandoc.Span(c or {}, a) end
                    or function(c, a) return pandoc.Div(c or {}, a) end
  local out = {}
  -- sequences: "STEPS@diag c1 c2 …" (cell k,k gets colour k), "@cols …" (cells of row 1), "@rows …"
  local entries = {}
  for entry in spec:gmatch("[^;]+") do
    local st, seq, list = trim(entry):match("^([^@]*)@(%a+)%s+(.+)$")
    if seq == "diag" or seq == "cols" or seq == "rows" then
      local k = 0
      for c in list:gmatch("%S+") do
        k = k + 1
        local area = seq == "diag" and (k .. "," .. k) or seq == "cols" and (k .. ",1") or ("1," .. k)
        entries[#entries + 1] = st .. "@" .. area .. " " .. c
      end
    else entries[#entries + 1] = entry end
  end
  for _, entry in ipairs(entries) do
    entry = trim(entry)
    -- optional colour at the end: a palette name or any CSS colour
    local body, color = entry:match("^(.-)%s+([%a#][%w#%.%-]*)$")
    if not body then body, color = entry:match("^(.-)%s+(%a+%b())$") end
    if not body then body = entry end
    local steps, area = body:match("^([^@]*)@(.*)$")
    if not steps then steps, area = body, nil end
    steps = trim(steps)
    local a, b = parse_steps(steps)
    local st, cells = area_style(area and trim(area) or nil, g)
    if a and st then
      if color then st = st .. ";--hl-c:" .. color_value(color) end
      out[#out + 1] = { entry = entry, st = st, a = a, b = b, cells = cells, color = color }
    else
      io.stderr:write("talk: cannot read hl entry '" .. entry .. "'\n")
    end
  end
  -- touching cells of a pixel grid: the left / upper one is drawn 1 px wider under its
  -- neighbour when that neighbour is shown whenever it is (so the overlap is never seen);
  -- two cells then never leave an antialiasing seam between them at a fractional zoom,
  -- and no colour is ever painted outside a cell (fringes over the lines or the border)
  local function last(x) return x == "end" and math.huge or tonumber(x) end
  local function covers(S, R) return S.a <= R.a and last(S.b) >= last(R.b) end
  if g.iw and g.ih then
    local under = {}                           -- under[R] = { S, … }: R is drawn 1 px under S
    for _, R in ipairs(out) do
      local x_more, y_more = 0, 0
      under[R] = {}
      if R.cells then
        for _, S in ipairs(out) do
          if S ~= R and S.cells and covers(S, R) then
            local right = S.cells.c0 == R.cells.c1 + 1 and S.cells.r0 <= R.cells.r0 and S.cells.r1 >= R.cells.r1
            local below = S.cells.r0 == R.cells.r1 + 1 and S.cells.c0 <= R.cells.c0 and S.cells.c1 >= R.cells.c1
            if right then x_more = 1 end
            if below then y_more = 1 end
            if right or below then under[R][#under[R] + 1] = S end
          end
        end
      end
      if x_more + y_more > 0 then R.st = R.st .. ";--hl-dx:" .. x_more .. "px;--hl-dy:" .. y_more .. "px" end
    end
    -- the neighbour must be painted after the cell it hides: order the regions so (the
    -- relation has no cycle: a cell is never both right of and below another one)
    local sorted, done = {}, {}
    local function visit(R)
      if done[R] then return end
      done[R] = true
      for _, S in ipairs(under[R]) do visit(S) end
      table.insert(sorted, 1, R)             -- R before everything it lies under
    end
    for i = #out, 1, -1 do visit(out[i]) end
    out = sorted
  end
  for i, R in ipairs(out) do
    local o_cls, o_at, i_cls, i_at = step_attrs(R.a, R.b)
    local cls, at = { "hl-region" }, { { "style", R.st }, { "data-hl", R.entry } }
    for _, c in ipairs(o_cls) do cls[#cls + 1] = c end
    for _, x in ipairs(o_at) do at[#at + 1] = x end
    local fill_cls, fill_at = { "hl-fill" }, i_at
    for _, c in ipairs(i_cls) do fill_cls[#fill_cls + 1] = c end
    out[i] = mk({ mk({}, pandoc.Attr("", fill_cls, fill_at)) }, pandoc.Attr("", cls, at))
  end
  return out, cols, rows
end

local function hl_host(el, inline)
  local a = el.attributes
  local spec = a["hl"]
  if not spec then return nil end
  -- the grid: cols= / rows= (an image or span), or the grid of a grid box (grid_box keeps it
  -- as grid-cols / grid-rows)
  local gc, gr = a["grid-cols"] or a["cols"], a["grid-rows"] or a["rows"]
  if gc or gr then gc, gr = gc or "1", gr or "1" end
  local g = grid_of(gc, gr)
  g.iw, g.ih = px_number((a["grid-inner"] or ""):match("^(%S+)")), px_number((a["grid-inner"] or ""):match("%S+$"))
  a["grid-inner"] = nil
  local regions, cols, rows = hl_regions(spec, g, inline)
  local st = {}
  if a["hl-color"] then st[#st + 1] = "--hl-color:" .. color_value(a["hl-color"]) end
  if gc then st[#st + 1] = "--hl-cols:" .. cols .. ";--hl-rows:" .. rows; el.classes:insert("hl-gridded") end
  if a["hl-style"] == "outline" then el.classes:insert("hl-outline") end
  local shape = a["hl-shape"]
  if shape == "round" then st[#st + 1] = "--hl-radius:" .. css_size(a["hl-radius"] or "14")
  elseif shape == "ellipse" or shape == "oval" then st[#st + 1] = "--hl-radius:50%"
  elseif a["hl-radius"] then st[#st + 1] = "--hl-radius:" .. css_size(a["hl-radius"]) end
  if a["hl-pad"] then st[#st + 1] = "--hl-pad:" .. css_size(a["hl-pad"]) end
  if a["hl-opacity"] then st[#st + 1] = "--hl-opacity:" .. a["hl-opacity"] end
  -- cells of a grid side by side: one layer that holds the opacity, the cells painted opaque
  -- and slightly overlapping inside it, so no seam shows between two coloured cells at any zoom
  if gc and not shape and not a["hl-radius"] and not a["hl-pad"] and a["hl-style"] ~= "outline" then
    local mk = inline and pandoc.Span or pandoc.Div
    regions = { mk(regions, pandoc.Attr("", { "hl-layer" })) }
  end
  for _, k in ipairs({ "hl-shape", "hl-radius", "hl-pad", "hl-opacity" }) do a[k] = nil end
  if #st > 0 then a["style"] = (a["style"] and (a["style"] .. ";") or "") .. table.concat(st, ";") end
  a["hl"], a["hl-color"], a["hl-style"] = nil, nil, nil
  a["grid-cols"], a["grid-rows"], a["cols"], a["rows"] = nil, nil, nil, nil
  el.classes:insert("hl-host")
  return regions
end

local function highlight_div(d)
  local regions = hl_host(d, false)
  if not regions then return nil end
  d.classes:insert("hl-under")       -- text of the box stays above the highlight
  for _, r in ipairs(regions) do d.content:insert(r) end
  return d
end
local function highlight_span(s)
  if s.attributes["hl"] == nil then return nil end
  local regions = hl_host(s, true)
  s.classes:insert("hl-under")
  for _, r in ipairs(regions) do s.content:insert(r) end
  return s
end
-- an image cannot hold children: it is wrapped in a span that takes its place, position,
-- size, data-id and fragment classes (the image fills it)
local function highlight_image(img)
  if img.attributes["hl"] == nil then return nil end
  local ia, wa = img.attributes, {}
  local wcls, icls = {}, { "hl-img" }
  for _, c in ipairs(img.classes) do
    if c == "absolute" or c == "fragment" or c:match("^fade") or c:match("^grow") or c:match("^shrink")
        or c == "move" or c == "tilt-shadow" then wcls[#wcls + 1] = c else icls[#icls + 1] = c end
  end
  local st = {}
  local W, H = px_number(ia["width"]), px_number(ia["height"])
  for _, k in ipairs({ "left", "top", "right", "bottom", "width", "height" }) do
    if ia[k] then st[#st + 1] = k .. ":" .. css_size(ia[k]); ia[k] = nil end
  end
  -- a picture of known size: its grid cells on whole pixels too (hl_host, area_style)
  if W and H and (ia["cols"] or ia["rows"]) then wa[#wa + 1] = { "grid-inner", W .. " " .. H } end
  for _, k in ipairs({ "hl", "cols", "rows", "hl-color", "hl-style", "hl-shape", "hl-radius", "hl-pad", "hl-opacity", "data-id", "data-fragment-index", "fragment-index",
                       "rotate-x", "rotate-y", "rotate-z", "perspective", "face", "depth", "angle" }) do
    if ia[k] then wa[#wa + 1] = { k, ia[k] }; ia[k] = nil end
  end
  if ia["style"] then st[#st + 1] = ia["style"]; ia["style"] = nil end
  wa[#wa + 1] = { "style", table.concat(st, ";") }
  ia["style"] = "width:100%;height:100%"
  img.attr = pandoc.Attr(img.identifier, icls, ia)
  local w = pandoc.Span({ img }, pandoc.Attr("", wcls, wa))
  local regions = hl_host(w, true)
  w.classes:insert("hl-img-host")
  for _, r in ipairs(regions) do w.content:insert(r) end
  return w
end

-- \hl{steps}{colour}{…} / \hlo{…} in an equation: KaTeX draws the equation in the browser,
-- after reveal.js has numbered the fragments. The highlight fragments are therefore made
-- here, next to the equation (so they are numbered with the others), and talk.js moves
-- each one into the part of the equation it belongs to.
local function highlight_math(m)
  local t = m.text
  if not (t:find("\\hlo?[%s{%[]") or t:find("\\eqmark", 1, true)) then return nil end
  -- \hl[name]{…} / \hlo[name]{…}: the optional name (for annotations) is moved out of the TeX
  local items, pos, buf = {}, 1, {}
  while true do
    local s0, e0, o, name = t:find("\\hl(o?)%s*%[([%w_%-]+)%]", pos)
    local s1, e1, o1 = t:find("\\hl(o?)%s*{", pos)
    if not s0 and not s1 then break end
    if s0 and (not s1 or s0 < s1) then
      buf[#buf + 1] = t:sub(pos, s0 - 1) .. "\\hl" .. o
      items[#items + 1] = name; pos = e0 + 1
    else
      buf[#buf + 1] = t:sub(pos, e1 - 1); pos = e1
      items[#items + 1] = false
    end
  end
  buf[#buf + 1] = t:sub(pos)
  t = table.concat(buf)
  t = t:gsub("\\eqmark%s*{([%w_%-]+)}", "\\htmlData{hlmark=%1}")
  m.text = t
  local out = { m }
  local k = 0
  for steps, color in t:gmatch("\\hlo?%s*(%b{})%s*(%b{})") do
    k = k + 1
    steps, color = trim(steps:sub(2, -2)), trim(color:sub(2, -2))
    local a, b = parse_steps(steps)
    if a then
      local o_cls, o_at, i_cls, i_at = step_attrs(a, b)
      local cls = { "hl-region", "hl-math-slot" }
      for _, c in ipairs(o_cls) do cls[#cls + 1] = c end
      local at = { { "data-hl", steps .. " " .. color }, { "style", "left:0;top:0;width:100%;height:100%" } }
      for _, x in ipairs(o_at) do at[#at + 1] = x end
      if items[k] then at[#at + 1] = { "data-name", items[k] } end
      local fcls = { "hl-fill" }
      for _, c in ipairs(i_cls) do fcls[#fcls + 1] = c end
      out[#out + 1] = pandoc.Span({ pandoc.Span({}, pandoc.Attr("", fcls, i_at)) }, pandoc.Attr("", cls, at))
    end
  end
  return out
end

-- ::: {.annot to="x2 kron" pos=below steps=2- sub="…"}  label  :::
-- a label with arrows to named parts of equations (\hl[name], \hlo[name], \eqmark{name}{…})
-- or to elements with that id; placed and drawn by talk.js from where they really are.
local function annotation(d)
  if not has_class(d, "annot") then return nil end
  local a = d.attributes
  local st, sb = parse_steps(a["steps"] or "0-")
  local o_cls, o_at, i_cls, i_at = step_attrs(st, sb)
  local inner_at = {}
  for _, k in ipairs({ "to", "pos", "dist", "shift", "x", "y", "arrow", "box", "gap", "dir", "anchor" }) do
    if a[k] then inner_at[#inner_at + 1] = { "data-" .. k, a[k] } end
  end
  local style = {}
  if a["color"] then
    style[#style + 1] = "--annot-c:" .. color_value(a["color"])
  end
  if a["size"] then style[#style + 1] = "--annot-size:" .. css_size(a["size"]) end
  if a["sub-size"] then style[#style + 1] = "--annot-sub-size:" .. css_size(a["sub-size"]) end
  if #style > 0 then inner_at[#inner_at + 1] = { "style", table.concat(style, ";") } end
  local label = { pandoc.Div(d.content, pandoc.Attr("", { "annot-label" })) }
  if a["sub"] then label[#label + 1] = pandoc.Div({ pandoc.Plain(pandoc.read(a["sub"], "markdown").blocks[1].content) }, pandoc.Attr("", { "annot-sub" })) end
  local icls = { "annot" }
  for _, c in ipairs(i_cls) do icls[#icls + 1] = c end
  for _, x in ipairs(i_at) do inner_at[#inner_at + 1] = x end
  local inner = pandoc.Div({ pandoc.Div(label, pandoc.Attr("", { "annot-box" })) }, pandoc.Attr("", icls, inner_at))
  local ocls = { "annot-wrap" }
  for _, c in ipairs(o_cls) do ocls[#ocls + 1] = c end
  return pandoc.Div({ inner }, pandoc.Attr(d.identifier, ocls, o_at))
end

-- [label]{.edge from=a to=b steps=1- color= width= shift= along=}: an arrow drawn by talk.js from
-- the edge of the element #a to the edge of #b (graph edges between nodes), its label beside the
-- middle of the arrow (shift= px to its left, along= px further along it). A div works too.
local function edge(el)
  if not has_class(el, "edge") or not el.attributes["to"] then return nil end
  local a = el.attributes
  local st, sb = parse_steps(a["steps"] or "0-")
  local o_cls, o_at, i_cls, i_at = step_attrs(st, sb)
  local inner_at = {}
  for _, k in ipairs({ "from", "to", "shift", "along", "width", "head", "gap" }) do
    if a[k] then inner_at[#inner_at + 1] = { "data-" .. k, a[k] } end
  end
  local style = {}
  if a["color"] then style[#style + 1] = "--annot-c:" .. color_value(a["color"]) end
  if a["size"] then style[#style + 1] = "--annot-size:" .. css_size(a["size"]) end
  if #style > 0 then inner_at[#inner_at + 1] = { "style", table.concat(style, ";") } end
  local icls = { "edge" }
  for _, c in ipairs(i_cls) do icls[#icls + 1] = c end
  for _, x in ipairs(i_at) do inner_at[#inner_at + 1] = x end
  local mk = (el.t == "Span") and pandoc.Span or pandoc.Div
  local inner = mk({ mk(el.content, pandoc.Attr("", { "edge-label" })) }, pandoc.Attr("", icls, inner_at))
  local ocls = { "annot-wrap" }
  for _, c in ipairs(o_cls) do ocls[#ocls + 1] = c end
  return mk({ inner }, pandoc.Attr(el.identifier, ocls, o_at))
end

-- ---------------------------------------------------------------------------- 3D tilt
-- {rotate-x=… rotate-y=… rotate-z=… perspective=…}  : real CSS 3D rotation (any element)
-- {face=top|side depth=0.5 angle=45}                 : oblique "cube face" look, the same
--                                                       convention as the tensors drawn in PowerPoint
local function tilt(el)
  local a = el.attributes
  local has3d = a["rotate-x"] or a["rotate-y"] or a["rotate-z"] or a["perspective"]
  local face = a["face"]
  if not has3d and not face then return nil end
  local tr = {}
  if has3d then
    if a["perspective"] then tr[#tr + 1] = "perspective(" .. css_size(a["perspective"]) .. ")" end
    -- applied to the element in the order Y, then X, then Z (same as PowerPoint's 3-D rotation)
    if a["rotate-z"] then tr[#tr + 1] = "rotateZ(" .. a["rotate-z"] .. "deg)" end
    if a["rotate-x"] then tr[#tr + 1] = "rotateX(" .. a["rotate-x"] .. "deg)" end
    if a["rotate-y"] then tr[#tr + 1] = "rotateY(" .. a["rotate-y"] .. "deg)" end
  end
  if face then
    local d = tonumber(a["depth"] or "0.5") or 0.5
    local ang = math.rad(tonumber(a["angle"] or "45") or 45)
    local dc, ds = d * math.cos(ang), d * math.sin(ang)
    if face == "top" then
      tr[#tr + 1] = string.format("matrix(1,0,%.4f,%.4f,0,0)", -dc, ds)
    elseif face == "side" or face == "right" then
      tr[#tr + 1] = string.format("matrix(%.4f,%.4f,0,1,0,0)", dc, -ds)
    elseif face == "depth" then   -- image lying along the depth axis (columns go "into" the screen)
      tr[#tr + 1] = string.format("matrix(%.4f,%.4f,1,0,0,0)", dc, -ds)
    end
  end
  for _, k in ipairs({ "rotate-x", "rotate-y", "rotate-z", "perspective", "face", "depth", "angle" }) do a[k] = nil end
  local st = {}
  -- Quarto's .absolute left=/top=/… would be lost once we set a style → move them into it
  for _, k in ipairs({ "left", "top", "right", "bottom", "width", "height" }) do
    if a[k] and has_class(el, "absolute") then st[#st + 1] = k .. ":" .. css_size(a[k]); a[k] = nil end
  end
  if #st > 0 then st[#st + 1] = "position:absolute" end
  if a["style"] then st[#st + 1] = a["style"] end
  st[#st + 1] = "transform:" .. table.concat(tr, " ")
  a["style"] = table.concat(st, ";")
  el.classes:insert("tilt")
  return el
end

-- ---------------------------------------------------------------------------- slides
local function is_break(b)
  return (b.t == "Header" and b.level <= 2) or b.t == "HorizontalRule"
end

local function kind_of(h)
  if h.t ~= "Header" then return nil end
  if has_class(h, "section-header") then return "header" end
  if has_class(h, "section-summary") then return "summary" end
  if has_class(h, "side-panel") then return "panel" end
  return nil
end

local pair_counter = 0

-- ---------------------------------------------------------------------------- lists
-- bullets="■ – • ○ ►" on a div (or YAML talk: bullets:), "none" = no marker → --talk-bN variables (5 levels)
local function bullet_vars(spec)
  local st, n = {}, 0
  for tok in tostring(spec):gmatch("%S+") do
    n = n + 1
    if n > 5 then break end
    local ch = (tok == "none") and "" or tok
    local size = ({ ["■"] = "1.1", ["▪"] = "1.1", ["○"] = "0.9", ["►"] = "0.7" })[ch] or "1"
    st[#st + 1] = string.format('--talk-b%d:"%s";--talk-b%d-size:%s', n, ch:gsub('"', '\\"'), n, size)
  end
  return table.concat(st, ";")
end

-- incremental list where only the items of the first N levels are clicks (PowerPoint
-- "by paragraph, level N"): each such item's content goes into a fragment div; deeper
-- items appear together with their parent.
local function wrap_list(list, maxdepth, depth)
  local items = {}
  for _, item in ipairs(list.content) do
    local blocks = {}
    for _, b in ipairs(item) do
      if (b.t == "BulletList" or b.t == "OrderedList") and depth < maxdepth then
        blocks[#blocks + 1] = wrap_list(b, maxdepth, depth + 1)
      else blocks[#blocks + 1] = b end
    end
    items[#items + 1] = { pandoc.Div(blocks, pandoc.Attr("", { "fragment" })) }
  end
  list.content = items
  return list
end
local function wrap_lists(blocks, maxdepth)
  local out = {}
  for _, b in ipairs(blocks) do
    if b.t == "BulletList" or b.t == "OrderedList" then out[#out + 1] = wrap_list(b, maxdepth, 1)
    else out[#out + 1] = b end
  end
  return out
end

-- - [text]{mark=media/icon.svg mark-size=40}: that picture as the item's marker (the item's
-- blocks are wrapped in div.marked, the picture inline before the text as img.mark; talk.scss LISTS)
local function mark_items(list)
  local changed = false
  for i, item in ipairs(list.content) do
    local b = item[1]
    local sp = b and (b.t == "Plain" or b.t == "Para") and b.content[1]
    if sp and sp.t == "Span" and sp.attributes["mark"] then
      -- (a real <img>, not a CSS url(): a url() in a custom property resolves against the stylesheet)
      local img = pandoc.Image({}, sp.attributes["mark"], "", pandoc.Attr("", { "mark" }))
      local st = sp.attributes["mark-size"] and ("--mark-size:" .. css_size(sp.attributes["mark-size"])) or nil
      sp.attributes["mark"], sp.attributes["mark-size"] = nil, nil
      local blocks = {}
      for _, x in ipairs(item) do blocks[#blocks + 1] = x end
      blocks[1].content:insert(1, img)        -- inline, in the first line of the item
      list.content[i] = { pandoc.Div(blocks, pandoc.Attr("", { "marked" }, st and { { "style", st } } or {})) }
      changed = true
    end
  end
  if changed then return list end
end

local function list_div(d)
  local changed = false
  if d.attributes["bullets"] then
    local st = bullet_vars(d.attributes["bullets"])
    d.attributes["style"] = (d.attributes["style"] and (d.attributes["style"] .. ";") or "") .. st
    d.attributes["bullets"] = nil
    changed = true
  end
  if has_class(d, "incremental") and d.attributes["levels"] then
    local n = tonumber(d.attributes["levels"]) or 1
    d.attributes["levels"] = nil
    local keep = {}
    for _, c in ipairs(d.classes) do if c ~= "incremental" then keep[#keep + 1] = c end end
    d.classes = keep
    d.content = wrap_lists(d.content, n)
    changed = true
  end
  if changed then return d end
end

-- ---------------------------------------------------------------------------- audio icon
-- Any span with .audio-btn (the {{< audio >}} shortcode, or the converter's []{.audio-btn
-- data-audio=…}) gets the speaker icon; size: --talk-audio-size (YAML talk: audio: size).
-- An image with data-audio stays an image (your own picture as a button).
local AUDIO_ICON = dofile(quarto.utils.resolve_path("audio_icon.lua"))   -- shared with audio.lua
local function audio_icon(sp)
  if not has_class(sp, "audio-btn") or has_class(sp, "talk-audio") then return nil end
  sp.classes:insert("talk-audio")
  sp.content:insert(1, pandoc.RawInline("html", AUDIO_ICON))
  if not sp.attributes["role"] then sp.attributes["role"] = "button"; sp.attributes["tabindex"] = "0" end
  if not sp.attributes["title"] then sp.attributes["title"] = "Play / stop" end
  return sp
end

-- ---------------------------------------------------------------------------- short box attributes
-- Positions, sizes and colours as attributes instead of a long style= (any div or span):
--   left= top= right= bottom= width= height=   on .absolute divs (numbers = px; Quarto's own
--                                             attributes, kept even when a style= is present)
--   size=18          font size in points (× --talk-pt, so it follows the deck's font scale)
--   color= background=   any CSS colour, or a theme name: text title accent background bar
--   align=center|right   line-height=   border="1px solid accent"   radius=   padding=
local POS = { "left", "top", "right", "bottom", "width", "height" }
local function theme_color(v)
  if v:match("^%a[%w%-]*$") then return color_value(v) end   -- theme name, palette name (intro, teal…) or CSS name
  return v
end
-- ---------------------------------------------------------------------------- audio played at a click
-- play=N on a sound (data-audio / .audio-btn span): the icon is there from the start and the sound
-- plays at click N (adds the trigger []{.fragment data-play=ID fragment-index=N} after it).
local play_count = 0
local function audio_play(sp)
  local n = sp.attributes["play"]
  if not n then return nil end
  sp.attributes["play"] = nil
  if sp.identifier == "" then play_count = play_count + 1; sp.identifier = "talk-play-" .. play_count end
  return pandoc.Span({}, pandoc.Attr("", { "fragment" }, { { "data-play", sp.identifier }, { "data-fragment-index", n } }))
end

-- ---------------------------------------------------------------------------- static blocks
-- ::: {.static} … ::: shows its content in its final state, without clicks (fragments removed;
-- what would end hidden, .fade-out / .fade-in-then-out, is dropped). E.g. a slide built click by
-- click, included again later as a recap: {{< include _outline.qmd >}} inside ::: {.static}.
local function static_block(d)
  if not has_class(d, "static") then return nil end
  local function strip(el)
    if not has_class(el, "fragment") then return nil end
    if has_class(el, "fade-out") or has_class(el, "fade-in-then-out") then return {} end
    local keep = {}
    for _, c in ipairs(el.classes) do if c ~= "fragment" then keep[#keep + 1] = c end end
    el.classes = keep
    el.attributes["fragment-index"], el.attributes["data-fragment-index"] = nil, nil
    return el
  end
  return pandoc.Div(pandoc.Blocks(d.content):walk({ Div = strip, Span = strip, Image = strip }), pandoc.Attr("", {}))
end

-- ---------------------------------------------------------------------------- title position
-- ## Title {top=15 left=146 width=1008 size=40}: the slide title placed like a PowerPoint title box
-- (defaults: the title placeholder, talk.scss). Pandoc moves heading attributes to the <section>,
-- so they become CSS variables there, read by the h2 rule.
local function title_attrs(h)
  if h.level ~= 2 then return nil end
  local st = {}
  for _, k in ipairs({ "top", "left", "width" }) do
    if h.attributes[k] then st[#st + 1] = "--title-" .. k .. ":" .. css_size(h.attributes[k]); h.attributes[k] = nil end
  end
  if h.attributes["size"] then st[#st + 1] = "--title-size:calc(" .. h.attributes["size"] .. " * var(--talk-pt))"; h.attributes["size"] = nil end
  if #st == 0 then return nil end
  h.attributes["style"] = table.concat(st, ";") .. (h.attributes["style"] and (";" .. h.attributes["style"]) or "")
  return h
end

-- ---------------------------------------------------------------------------- shapes
-- shape=NAME on any box (div or span) draws that outline behind its content, sized to the box:
--   arrow-right|arrow-left|arrow-up|arrow-down (head= length, shaft= thickness, in % of the box),
--   shrink|grow (trapezoid narrowing / widening to the right, taper= narrow side in %),
--   parallelogram (slant= %), cube (depth= in px; the content goes in the front face).
-- background= fills it, border="W STYLE COLOUR" draws its outline (instead of a rectangle); with
-- .box or .filled the outline and fill default to that style.
local function shape_path(kind, a, W, H)
  local function pc(k, d) return tonumber(tostring(a[k] or d):match("[%d%.]+")) end
  local function pts(t) local o = {} for i = 1, #t, 2 do o[#o + 1] = string.format("%.2f,%.2f", t[i] * W / 100, t[i + 1] * H / 100) end
    return "M" .. table.concat(o, " L") .. " Z" end
  if kind:match("^arrow") then
    local h, s = pc("head", 30), pc("shaft", 50)
    local y1, y2, x = 50 - s / 2, 50 + s / 2, 100 - h
    local r = { 0, y1, x, y1, x, 0, 100, 50, x, 100, x, y2, 0, y2 }       -- pointing right
    local t = {}
    for i = 1, #r, 2 do
      local u, v = r[i], r[i + 1]
      if kind == "arrow-left" then u = 100 - u elseif kind == "arrow-down" then u, v = v, u
      elseif kind == "arrow-up" then u, v = v, 100 - u end
      t[#t + 1] = u; t[#t + 1] = v
    end
    return pts(t)
  elseif kind == "shrink" or kind == "grow" then
    local m = (100 - pc("taper", 50)) / 2
    return kind == "shrink" and pts({ 0, 0, 100, m, 100, 100 - m, 0, 100 }) or pts({ 0, m, 100, 0, 100, 100, 0, 100 - m })
  elseif kind == "parallelogram" then
    local k = pc("slant", 25)
    return pts({ k, 0, 100, 0, 100 - k, 100, 0, 100 })
  elseif kind == "cube" then
    local d = pc("depth", 20)
    local dx, dy = d * 100 / W, d * 100 / H                                   -- depth in px
    return pts({ 0, dy, 100 - dx, dy, 100 - dx, 100, 0, 100 }) ..
      string.format(" M0,%.2f L%.2f,0 L%.2f,0 L%.2f,%.2f M%.2f,%.2f L%.2f,0 L%.2f,%.2f L%.2f,%.2f",
        dy * H / 100, dx * W / 100, W, (100 - dx) * W / 100, dy * H / 100, (100 - dx) * W / 100, dy * H / 100, W, W, (100 - dy) * H / 100, (100 - dx) * W / 100, H)
  end
end

local function shape(el)
  local a = el.attributes
  local kind = a["shape"]
  if not kind then return nil end
  local W, H = px_number(a["width"]) or 100, px_number(a["height"]) or 100
  local d = shape_path(kind, a, W, H)
  if not d then io.stderr:write("talk: unknown shape=" .. kind .. "\n"); return nil end
  local filled = has_class(el, "filled")
  local fill = a["background"] and theme_color(a["background"])
    or (filled and "var(--talk-accent)") or (has_class(el, "box") and "var(--talk-bg)") or "none"
  local bw, bc = filled and "3.67" or "1", filled and "var(--talk-accent-dark)" or "#000"
  if a["border"] then
    for tok in a["border"]:gmatch("%S+") do
      if tok:match("^[%d%.]+p?x?$") then bw = tok:gsub("px", "")
      elseif tok ~= "solid" then bc = theme_color(tok) end
    end
  end
  if kind == "cube" then
    local dp = tostring(a["depth"] or 20):match("[%d%.]+")
    a["style"] = "padding-top:" .. dp .. "px;padding-right:" .. dp .. "px" .. (a["style"] and (";" .. a["style"]) or "")
    -- for dims(): the depth edge and the front face
    a["dim-geom"] = "0 " .. dp .. " " .. dp .. " 0"
    a["dim-inset-top"], a["dim-inset-right"] = dp, dp
  elseif kind == "parallelogram" then
    local k = tonumber(tostring(a["slant"] or 25):match("[%d%.]+")) * W / 100
    a["dim-geom"] = string.format("0 %s %.4g 0", H, k)
    a["dim-inset-right"] = string.format("%.4g", k)
  end
  for _, k in ipairs({ "shape", "head", "shaft", "taper", "slant", "depth", "background", "border" }) do a[k] = nil end
  el.classes:insert("shape")
  local svg = string.format('<svg class="geom" viewBox="0 0 %s %s" preserveAspectRatio="none" overflow="visible">' ..
    '<path d="%s" fill="%s" stroke="%s" stroke-width="%s" vector-effect="non-scaling-stroke"/></svg>', W, H, d, fill, bc, bw)
  if el.t == "Span" then el.content:insert(1, pandoc.RawInline("html", svg))
  else el.content:insert(1, pandoc.RawBlock("html", svg)) end
  return el
end

-- ---------------------------------------------------------------------------- stacks
-- stack="c1 c2 … cn" on a box: n slices of the box's size, the first one in front (the box
-- itself: its background becomes the first colour), the others shifted behind it, up to
-- depth= px to the right and lift= px up (default 0.85 × depth), like a stack of matrices.
-- stack-id=PREFIX gives the slices data-id PREFIX-1 … PREFIX-n (Morph from grid cells, cell-id=).
local function stack(el)
  local a = el.attributes
  if not a["stack"] then return nil end
  local colors = {}
  for c in tostring(a["stack"]):gmatch("%S+") do colors[#colors + 1] = c end
  local n = #colors
  local depth = tonumber(tostring(a["depth"] or "20"):match("[%d%.]+")) or 20
  local lift = tonumber(tostring(a["lift"] or ""):match("[%d%.]+")) or depth * 0.85
  local prefix = a["stack-id"]
  a["stack"], a["stack-id"], a["lift"] = nil, nil, nil
  a["depth"] = nil
  -- dims drawn by dims(): the depth arrow runs from the front slice's corner to the back one
  a["dim-geom"] = string.format("0 0 %.4g %.4g", depth, -lift)
  local mk = (el.t == "Span") and pandoc.Span or pandoc.Div
  -- the slices draw the frame (the box's own border is dropped, talk.scss: it would show at its
  -- final place while the slices morph in)
  local border = a["border"] and a["border"]:gsub("(%a+)", function(w) return THEME[w] and ("var(" .. THEME[w] .. ")") or nil end)
                 or (has_class(el, "matrix") or has_class(el, "box")) and "1px solid #000" or "none"
  a["border"] = nil
  local slices = {}
  for k = n, 1, -1 do                       -- back to front: the DOM order paints them so
    local f = (n > 1) and (k - 1) / (n - 1) or 0
    local attrs = { { "style", string.format("left:%.4gpx;top:%.4gpx;background:%s;border:%s", f * depth, -f * lift, color_value(colors[k]), border) } }
    if prefix then attrs[#attrs + 1] = { "data-id", prefix .. "-" .. k } end
    slices[#slices + 1] = mk({}, pandoc.Attr("", { "slice" }, attrs))
  end
  local content = {}
  for _, x in ipairs(slices) do content[#content + 1] = x end
  for _, x in ipairs(el.content) do content[#content + 1] = x end
  el.content = (el.t == "Span") and pandoc.Inlines(content) or pandoc.Blocks(content)
  el.classes:insert("stacked")
  return el
end

-- ---------------------------------------------------------------------------- dimension arrows
-- dim-left="f" dim-bottom="t" dim-top=… dim-right=… dim-depth="b" on any box (.matrix, .box, a
-- cube or parallelogram shape, a stack): an arrow along that side, 14 px outside the box, with
-- its label (maths: `r_t` is read as $r_t$; Markdown with $…$ or text otherwise) beyond it.
-- On a cube the left and bottom arrows follow the front face and the depth arrow the top-left
-- edge; on a parallelogram the depth arrow follows the slanted left side; on a stack it goes
-- from the front slice to the back one. (dim-geom = "x0 y0 x1 y1": the depth edge, set by
-- shape() / stack(), in px of the box.)
local function dim_label(v)
  if v:find("$", 1, true) then return pandoc.read(v, "markdown").blocks[1].content end
  return pandoc.Inlines({ pandoc.Math("InlineMath", v) })
end
local function dims(el)
  local a = el.attributes
  local any = false
  for _, side in ipairs({ "left", "right", "top", "bottom", "depth" }) do if a["dim-" .. side] then any = true end end
  if not any then a["dim-geom"] = nil; return nil end
  local mk = (el.t == "Span") and pandoc.Span or pandoc.Div
  local W, H = px_number(a["width"]) or 100, px_number(a["height"]) or 100
  local geom = {}
  for v in tostring(a["dim-geom"] or ""):gmatch("%S+") do geom[#geom + 1] = tonumber(v) end
  local st = {}
  -- insets of the left / bottom arrows: the front face of a cube, the bottom side of a parallelogram
  if a["dim-inset-top"] then st[#st + 1] = "--dim-inset-top:" .. css_size(a["dim-inset-top"]) end
  if a["dim-inset-right"] then st[#st + 1] = "--dim-inset-right:" .. css_size(a["dim-inset-right"]) end
  a["dim-geom"], a["dim-inset-top"], a["dim-inset-right"] = nil, nil, nil
  local gap = tonumber(a["dim-gap"] or "14") or 14; a["dim-gap"] = nil
  st[#st + 1] = "--dim-gap:" .. gap .. "px"
  if a["dim-size"] then st[#st + 1] = "--dim-size:calc(" .. a["dim-size"] .. " * var(--talk-pt))"; a["dim-size"] = nil end
  local added = {}
  for _, side in ipairs({ "left", "right", "top", "bottom", "depth" }) do
    local v = a["dim-" .. side]
    if v then
      a["dim-" .. side] = nil
      local attrs = {}
      if side == "depth" then
        local x0, y0, x1, y1 = geom[1] or 0, geom[2] or H, geom[3] or W, geom[4] or 0
        local dx, dy = x1 - x0, y1 - y0
        local L = math.sqrt(dx * dx + dy * dy)
        local ang = math.deg(math.atan(dy, dx))
        -- the arrow is moved `gap` px away from the edge, on its outer (upper-left) side
        local nx, ny = dy / L, -dx / L
        if nx + ny > 0 then nx, ny = -nx, -ny end
        attrs[#attrs + 1] = { "style", string.format("left:%.4gpx;top:%.4gpx;width:%.4gpx;transform:rotate(%.4gdeg);--dim-angle:%.4gdeg",
          x0 + gap * nx, y0 + gap * ny, L, ang, -ang) }
      end
      local label = dim_label(v)
      if el.t ~= "Span" then label = { pandoc.Plain(label) } end
      added[#added + 1] = mk({ mk({}, pandoc.Attr("", { "dim-arrow" })), mk(label, pandoc.Attr("", { "dim-label" })) },
        pandoc.Attr("", { "dim", "dim-" .. side }, attrs))
    end
  end
  local content = {}
  for _, x in ipairs(el.content) do content[#content + 1] = x end
  for _, x in ipairs(added) do content[#content + 1] = x end
  el.content = (el.t == "Span") and pandoc.Inlines(content) or pandoc.Blocks(content)
  if #st > 0 then a["style"] = table.concat(st, ";") .. (a["style"] and (";" .. a["style"]) or "") end
  return el
end

-- ---------------------------------------------------------------------------- rotated content
-- .rot-l / .rot-r on a box: its content is turned by a quarter turn (left: read bottom-up),
-- still centred in the box (the box and its border stay as they are): labels of column vectors
local function rot(el)
  if not (has_class(el, "rot-l") or has_class(el, "rot-r")) then return nil end
  local mk = (el.t == "Span") and pandoc.Span or pandoc.Div
  local inner = {}
  for _, x in ipairs(el.content) do inner[#inner + 1] = x end
  if el.t == "Span" then el.content = pandoc.Inlines({ pandoc.Span(inner, pandoc.Attr("", { "rot" })) })
  else el.content = pandoc.Blocks({ pandoc.Div(inner, pandoc.Attr("", { "rot" })) }) end
  return el
end

-- ---------------------------------------------------------------------------- cards
-- ::: {.card}  ### Title  body…  ::: {.card-foot} … :::  :::  — a titled box: the title in the
-- PowerPoint shape style (.filled), the body framed under it (text centred vertically), an
-- optional footer at the bottom. Works alone (.absolute, width= height=) or as a column
-- (::: {.column .card}: the cards of a row share the row's height).
local function card(d)
  if not has_class(d, "card") then return nil end
  local title, body, foot = nil, {}, nil
  for i, b in ipairs(d.content) do
    if i == 1 and b.t == "Header" then title = b.content
    elseif b.t == "Div" and has_class(b, "card-foot") then foot = b
    else body[#body + 1] = b end
  end
  local out = {}
  if title then out[#out + 1] = pandoc.Div({ pandoc.Plain(title) }, pandoc.Attr("", { "card-title" })) end
  out[#out + 1] = pandoc.Div(body, pandoc.Attr("", { "card-body" }))
  if foot then out[#out + 1] = foot end
  d.content = (d.t == "Span") and pandoc.Inlines(out) or pandoc.Blocks(out)
  return d
end

-- ---------------------------------------------------------------------------- mermaid diagrams
-- ```{mermaid}``` charts (Quarto has already turned them into <pre class="mermaid-js">): maths in
-- labels ($$…$$) rendered by KaTeX as HTML, not MathML, so it uses the slides' KaTeX fonts
-- (\mathscr…). Set in the chart's own init directive.
local function mermaid_maths(r)
  if r.format ~= "html" or not r.text:match('^<pre class="mermaid mermaid%-js">') then return nil end
  r.text = r.text:gsub('^(<pre class="mermaid mermaid%-js">)', '%1%%%%{init: {"forceLegacyMathML": true}}%%%%\n', 1)
  return r
end

local function line_spec(spec, a)
  local w, c = "1px", "currentColor"
  local src = (spec == "true") and (a["border"] or (a["style"] or ""):match("border:%s*([^;]+)") or "") or spec
  for tok in tostring(src):gmatch("%S+") do
    if tok:match("^[%d%.]+px$") or tok:match("^[%d%.]+$") then w = css_size(tok)
    elseif tok ~= "solid" and tok ~= "dashed" and tok ~= "dotted" then c = theme_color(tok) end
  end
  return w, c
end

local function box_attrs(el)
  local a, st = el.attributes, {}
  if has_class(el, "annot") or has_class(el, "edge") then return nil end   -- their own attributes (annotation, edge)
  -- .sep: a separator line. Its length is width= (horizontal) or height= (vertical), its
  -- thickness thickness= (1 px), its colour color= (black), dash="12 8" for a dashed one; any
  -- position, click or class as usual
  if has_class(el, "sep") then
    local th = css_size(a["thickness"] or "1"); a["thickness"] = nil
    local vertical = a["height"] and not a["width"]
    if vertical then a["width"] = th elseif a["width"] and not a["height"] then a["height"] = th end
    if a["color"] then a["background"] = a["color"]; a["color"] = nil end
    if a["dash"] then                                -- dash="12 8": dashes of 12 px, gaps of 8 px
      local d, g = tostring(a["dash"]):match("([%d%.]+)%s+([%d%.]+)")
      d, g = d or a["dash"], g or d or a["dash"]
      local c = theme_color(a["background"] or "black")
      st[#st + 1] = string.format("background:repeating-linear-gradient(to %s, %s 0 %spx, transparent %spx %spx)",
        vertical and "bottom" or "right", c, d, d, tonumber(d) + tonumber(g))
      a["background"], a["dash"] = nil, nil
    end
  end
  if has_class(el, "absolute") then
    for _, k in ipairs(POS) do
      if a[k] then st[#st + 1] = k .. ":" .. css_size(a[k]); a[k] = nil end
    end
  elseif el.t == "Span" or has_class(el, "card") or has_class(el, "sep") then   -- e.g. the shapes of a .flow row
    for _, k in ipairs({ "width", "height" }) do
      if a[k] then st[#st + 1] = k .. ":" .. css_size(a[k]); a[k] = nil end
    end
  elseif has_class(el, "column") and a["height"] then   -- (with a height, the width goes in the same style=:
    for _, k in ipairs({ "width", "height" }) do          --  Quarto would otherwise add a second one)
      if a[k] then st[#st + 1] = k .. ":" .. css_size(a[k]); a[k] = nil end
    end
  end
  for _, k in ipairs({ "dx", "dy" }) do           -- motion path of a .fragment.move: dx= dy= in px
    if a[k] then st[#st + 1] = "--" .. k .. ":" .. css_size(a[k]); a[k] = nil end
  end
  if a["gap"] and has_class(el, "flow") then st[#st + 1] = "--flow-gap:" .. css_size(a["gap"]); a["gap"] = nil end
  if a["gap"] and has_class(el, "columns") then st[#st + 1] = "--talk-col-gap:" .. css_size(a["gap"]); a["gap"] = nil end
  -- lines=true | "2px accent" on .columns: a vertical line in the middle of each gap
  if a["lines"] and has_class(el, "columns") then
    local w, c = line_spec(a["lines"] == "true" and "1px black" or a["lines"], a)
    st[#st + 1] = "--talk-col-line-w:" .. w .. ";--talk-col-line-c:" .. c; a["lines"] = nil
    el.classes:insert("col-lines")
  end
  -- audio-col="x1 x2 …" on a box holding a list: the speaker icons of each item ({{< audio >}} or
  -- .audio-btn spans) are aligned in columns, x px from the left edge of the box
  if a["audio-col"] then
    local n = 0
    for x in tostring(a["audio-col"]):gmatch("%S+") do n = n + 1; st[#st + 1] = "--audio-col" .. n .. ":" .. css_size(x) end
    a["audio-col"] = nil
    el.classes:insert("audio-cols")
  end
  if a["opacity"] then st[#st + 1] = "opacity:" .. a["opacity"]; a["opacity"] = nil end
  -- fade-delay=S on a .fade-after: it fades out S s after the slide arrives (default: the push duration)
  if a["fade-delay"] then st[#st + 1] = "--talk-fade-delay:" .. a["fade-delay"] .. "s"; a["fade-delay"] = nil end
  -- indent="80 120": left edge of the text of level-1 items / of deeper levels, in px (hanging markers)
  if a["indent"] then
    local v = {}
    for x in tostring(a["indent"]):gmatch("[%d%.]+") do v[#v + 1] = tonumber(x) end
    local prev = 0
    for n = 1, 5 do
      local m = v[n == 1 and 1 or math.min(2, #v)]
      if m then
        local mar = (n == 1) and m or (prev + m)
        st[#st + 1] = string.format("--talk-mar%d:%gpx;--talk-ind%d:%gpx", n, mar, n, -m)
        prev = mar
      end
    end
    a["indent"] = nil
  end
  -- spacing="10 5": space before the items of a list, in pt (PowerPoint "space before"):
  -- first value for level-1 items, second for deeper levels (one value: every level)
  if a["spacing"] then
    local v = {}
    for x in tostring(a["spacing"]):gmatch("[%d%.]+") do v[#v + 1] = x end
    for n = 1, 5 do
      local pt = v[n == 1 and 1 or math.min(2, #v)]
      if pt then st[#st + 1] = "--talk-spcb" .. n .. ":calc(" .. pt .. " * var(--talk-pt))" end
    end
    a["spacing"] = nil
  end
  if a["size"] then st[#st + 1] = "font-size:calc(" .. a["size"] .. " * var(--talk-pt))"; a["size"] = nil end
  if a["color"] then st[#st + 1] = "color:" .. theme_color(a["color"]); a["color"] = nil end
  if a["background"] then st[#st + 1] = "background:" .. theme_color(a["background"]); a["background"] = nil end
  if a["align"] then st[#st + 1] = "text-align:" .. a["align"]; a["align"] = nil end
  if a["border"] then
    -- theme names also inside a border: border="1px solid accent"
    local b = a["border"]:gsub("(%a+)", function(w) if THEME[w] then return "var(" .. THEME[w] .. ")" end end)
    st[#st + 1] = "border:" .. b; a["border"] = nil
  end
  if a["radius"] then st[#st + 1] = "border-radius:" .. css_size(a["radius"]); a["radius"] = nil end
  for _, k in ipairs({ "line-height", "padding" }) do
    if a[k] then st[#st + 1] = k .. ":" .. a[k]; a[k] = nil end
  end
  if #st == 0 then return nil end
  a["style"] = table.concat(st, ";") .. (a["style"] and (";" .. a["style"]) or "")
  return el
end

-- ---------------------------------------------------------------------------- grid boxes
-- ONE formalism for every box divided into cells (matrices, structure bars, tensors…):
--   ::: {.absolute left= top= width= height= cols="2 2 1 1" rows=1 lines=true hl="1@2; 2-@4 teal"}
--   - a                       ← optional: one list item per cell, row by row (the cell's text)
--   - [b]{.cell .fragment}    ← .cell on a span alone in an item: attributes of the whole cell
--   :::                          (click, background, data-id for a Morph, hl…)
--   cols / rows : a number of equal cells, or relative sizes ("2 2 1 1"); default 1
--   lines       : true (the box's border width and colour) or "2px accent": lines between cells
--   hl          : highlights of cells, addressed as in any hl= (k, k-l, c,r, *), at clicks
--   cells       : "c1 c2 …": background colour of each cell, row by row (palette names or CSS)
--   cell-id     : PREFIX: every cell gets data-id PREFIX-k (a Morph of each cell: e.g. the cells
--                 of a matrix fly into the slices of a stack= box with stack-id=PREFIX)

local function grid_box(d)
  local a = d.attributes
  if not (a["cols"] or a["rows"]) then return nil end
  -- a span box ([]{.absolute .matrix rows=6 lines=true}) gets span cells and lines
  local mk = (d.t == "Span") and pandoc.Span or pandoc.Div
  if d.t == "Span" and not a["lines"] and not a["cells"] and not a["cell-id"] then return nil end   -- hl= alone: hl_host reads cols/rows
  local cols, rows = a["cols"] or "1", a["rows"] or "1"
  -- when the box size is known, the cell boundaries are rounded to whole pixels of its inner
  -- area (size − 2 × border): cells, highlights and lines then share exactly the same edges
  local bw = tonumber(tostring(a["border"] or (a["style"] or ""):match("border:%s*([^;]+)")
             or (has_class(d, "matrix") and "1px" or "")):match("([%d%.]+)px") or "0") or 0
  local W, H = px_number(a["width"]), px_number(a["height"])
  local function snap(spec, size)
    if not size or #boundaries(spec) <= 2 then return spec end      -- a single cell: nothing to snap
    local inner, xs, out = size - 2 * bw, boundaries(spec), {}
    for k = 2, #xs do
      out[#out + 1] = tostring(math.floor(xs[k] * inner / 100 + 0.5) - math.floor(xs[k - 1] * inner / 100 + 0.5))
    end
    return table.concat(out, " ")
  end
  cols, rows = snap(cols, W), snap(rows, H)
  local g = grid_of(cols, rows)
  a["cols"], a["rows"] = nil, nil
  d.classes:insert("grid-box")
  local out = {}
  -- cells="c1 c2 …" (backgrounds, row by row) and cell-id=PREFIX (data-id PREFIX-k): cells
  -- that do not come from a list are created empty
  local cell_bg, cell_id, ncell = {}, a["cell-id"], 0
  for c in tostring(a["cells"] or ""):gmatch("%S+") do cell_bg[#cell_bg + 1] = c end
  a["cells"], a["cell-id"] = nil, nil
  local function cell(i, id, cls, attrs, content)
    local c = (i - 1) % g.nc + 1
    local r = (i - 1) // g.nc + 1
    if r > g.nr then return end
    local st = "left:" .. pct(g.xs[c]) .. ";top:" .. pct(g.ys[r]) ..
               ";width:" .. pct(g.xs[c + 1] - g.xs[c]) .. ";height:" .. pct(g.ys[r + 1] - g.ys[r])
    if cell_bg[i] then st = st .. ";background:" .. color_value(cell_bg[i]) end
    if cell_id then attrs[#attrs + 1] = { "data-id", cell_id .. "-" .. i } end
    local merged = false
    for _, kv in ipairs(attrs) do if kv[1] == "style" then kv[2] = st .. ";" .. kv[2]; merged = true end end
    if not merged then attrs[#attrs + 1] = { "style", st } end
    ncell = i
    out[#out + 1] = mk(content, pandoc.Attr(id, cls, attrs))
  end
  -- cells from the list (row by row)
  for _, b in ipairs(d.content) do
    if b.t == "BulletList" or b.t == "OrderedList" then
      for i, item in ipairs(b.content) do
        local id, cls, attrs, content = "", { "seg" }, {}, nil
        local one = #item == 1 and (item[1].t == "Plain" or item[1].t == "Para") and item[1].content or nil
        if one then
          local inl = {}
          for _, x in ipairs(one) do if x.t ~= "Space" and x.t ~= "SoftBreak" then inl[#inl + 1] = x end end
          local sp = (#inl == 1 and inl[1].t == "Span") and inl[1] or nil
          if sp and has_class(sp, "cell") then
            id = sp.identifier
            for _, k in ipairs(sp.classes) do if k ~= "cell" then cls[#cls + 1] = k end end
            for k, v in pairs(sp.attributes) do attrs[#attrs + 1] = { k, v } end
            content = { pandoc.Plain(sp.content) }
          end
        end
        cell(i, id, cls, attrs, content or item)
      end
    else
      out[#out + 1] = b
    end
  end
  if ncell == 0 and (#cell_bg > 0 or cell_id) then
    for i = 1, g.nc * g.nr do cell(i, "", { "seg" }, {}, {}) end
  end
  -- lines between cells (separate elements: they stay when a cell appears on a click, and they
  -- are drawn above the highlights; the outer border is the box's own border)
  if a["lines"] and a["lines"] ~= "false" then
    local w, c
    if a["lines"] == "true" and not a["border"] and not (a["style"] or ""):match("border:") and has_class(d, "matrix") then
      w, c = "1px", "#000"                     -- the .matrix frame (talk.scss)
    else
      w, c = line_spec(a["lines"], a)
    end
    -- with a known box size the boundaries are whole pixels (see above): the line starts there;
    -- otherwise it is centred on the boundary
    local function at(p, size)
      if size then return string.format("%dpx", math.floor((size - 2 * bw) * p / 100 + 0.5)) end
      return "calc(" .. pct(p) .. " - " .. w .. " / 2)"
    end
    for k = 2, g.nc do
      out[#out + 1] = mk({}, pandoc.Attr("", { "grid-line" }, { { "style",
        "left:" .. at(g.xs[k], W) .. ";top:0;bottom:0;width:" .. w .. ";background:" .. c } }))
    end
    for k = 2, g.nr do
      out[#out + 1] = mk({}, pandoc.Attr("", { "grid-line" }, { { "style",
        "top:" .. at(g.ys[k], H) .. ";left:0;right:0;height:" .. w .. ";background:" .. c } }))
    end
  end
  a["lines"] = nil
  -- the same grid serves the highlights (hl_host reads it)
  if a["hl"] then
    a["grid-cols"], a["grid-rows"] = cols, rows
    if W and H then a["grid-inner"] = (W - 2 * bw) .. " " .. (H - 2 * bw) end
    -- the border is painted again above the highlights (talk.scss .hl-gridded::after), so a
    -- fill scaled to a fraction of a pixel never shows over it
    if bw > 0 then a["style"] = "--hl-bw:" .. bw .. "px" .. (a["style"] and (";" .. a["style"]) or "") end
  end
  d.content = (d.t == "Span") and pandoc.Inlines(out) or pandoc.Blocks(out)
  return d
end

-- ---------------------------------------------------------------------------- slide numbers
-- .test-slide (first slide used to test the clicker / sound) and .additional (backup slides)
-- are left out of the count; talk.js labels them "test slide" and "additional-1, -2, …"
-- Appendix: an empty  ::: {.appendix} :::  anywhere in a slide (usually at the end of the
-- conclusion) makes EVERY following slide .additional, like LaTeX \appendix. A slide after it
-- can opt out with .counted. The render log says where the appendix starts (never silent).
local appendix = { on = false, after = nil, count = 0 }
local function slide_label(h)
  if h.t ~= "Header" then return "(slide break)" end
  local t = stringify(h.content)
  if t == "" then t = "#" .. h.identifier end
  return t
end
local function take_appendix_marker(body)
  local found, keep = false, {}
  for _, b in ipairs(body) do
    if b.t == "Div" and has_class(b, "appendix") then found = true
    else keep[#keep + 1] = b end
  end
  return keep, found
end
local function special_slide(h)
  if h.t ~= "Header" then return end
  if appendix.on and not has_class(h, "counted") and not has_class(h, "additional")
      and not has_class(h, "section-summary") then
    h.classes:insert("additional")
    appendix.count = appendix.count + 1
  end
  if (has_class(h, "test-slide") or has_class(h, "additional")) and not h.attributes["visibility"] then
    h.attributes["visibility"] = "uncounted"
  end
end

-- ---------------------------------------------------------------------------- table of contents
-- every section (header, or header + summary) → { id, title, summary }; a slide with
-- .toc-slide (or a ::: {#toc} div) gets the list. Classes for styling: talk-toc, toc-item,
-- toc-title, toc-summary (README).
local toc_entries = {}
local function deep(blocks) return pandoc.Blocks(blocks):walk({}) end
local function toc_record(h, title, summary)
  if has_class(h, "no-toc") then return end
  if h.identifier == "" then h.identifier = "talk-section-" .. (#toc_entries + 1) end
  local sum = {}
  for _, b in ipairs(summary or {}) do
    if not (b.t == "Div" and (has_class(b, "slide-refs") or has_class(b, "notes"))) then sum[#sum + 1] = b end
  end
  toc_entries[#toc_entries + 1] = { id = h.identifier, title = pandoc.Inlines(title):walk({}), summary = deep(sum) }
end
local function toc_blocks()
  local items = {}
  for k, e in ipairs(toc_entries) do
    local inner = { pandoc.Div({ pandoc.Plain({ pandoc.Link(e.title, "#/" .. e.id) }) }, pandoc.Attr("", { "toc-title" })) }
    if #e.summary > 0 then inner[#inner + 1] = pandoc.Div(e.summary, pandoc.Attr("", { "toc-summary" })) end
    items[#items + 1] = pandoc.Div(inner, pandoc.Attr("", { "toc-item" }, { { "data-toc-index", tostring(k) } }))
  end
  return pandoc.Div(items, pandoc.Attr("", { "talk-toc" }))
end
local function fill_toc(blocks)
  return pandoc.Blocks(blocks):walk({ Div = function(d)
    if d.identifier == "toc" or has_class(d, "talk-toc-placeholder") then
      local t = toc_blocks()
      if d.identifier == "toc" then t.identifier = "toc" end
      for _, c in ipairs(d.classes) do if c ~= "talk-toc-placeholder" then t.classes:insert(c) end end
      return t
    end
  end })
end

-- ---------------------------------------------------------------------------- sections
-- style: full (header → summary, Morph-like) | simple (the header alone, title only; the
-- summary becomes an ordinary slide that keeps its content but not its panel)
local function section_style(opts)
  local st = opts.style or global.style or "full"
  return st
end

local function plain_summary(s)
  -- the summary slide in "simple" style: heading hidden (kept for the menu), panel dropped
  local parts = split_body(s.body)
  local h = s.head
  h.classes:insert("talk-hidden-title")
  for _, c in ipairs({ "section-summary" }) do
    local keep = {}
    for _, x in ipairs(h.classes) do if x ~= c then keep[#keep + 1] = x end end
    h.classes = keep
  end
  for k, _ in pairs(VARS) do h.attributes[k] = nil end
  h.attributes["style"] = nil; h.attributes["duration"] = nil; h.attributes["easing"] = nil
  local body = {}
  for _, b in ipairs(parts.rest) do body[#body + 1] = b end
  for _, b in ipairs(parts.notes) do body[#body + 1] = b end
  return h, body
end

local function process(blocks)
  local slides, cur, pre = {}, nil, {}
  for _, b in ipairs(blocks) do
    if is_break(b) then cur = { head = b, body = {} }; slides[#slides + 1] = cur
    elseif cur then cur.body[#cur.body + 1] = b
    else pre[#pre + 1] = b end
  end
  local out = pre
  local i = 1
  local function plain_slide(h, body)
    out[#out + 1] = h
    local is_refs = false
    pandoc.Blocks(body):walk({ Div = function(d) if d.identifier == "refs" then is_refs = true end end })
    for _, b in ipairs(body) do out[#out + 1] = b end
    if cite.enabled and cite.slide_refs and not is_refs and h.t == "Header"
        and not has_class(h, "no-slide-refs") then
      local d = slide_refs_div(body)
      if d then out[#out + 1] = d end
    end
  end
  while i <= #slides do
    local s = slides[i]
    local h = s.head
    special_slide(h)
    local marker
    s.body, marker = take_appendix_marker(s.body)
    if not marker and slides[i + 1] and kind_of(h) == "header" and kind_of(slides[i + 1].head) == "summary" then
      slides[i + 1].body, marker = take_appendix_marker(slides[i + 1].body)
    end
    if marker and not appendix.after then appendix.after = slide_label(h) end
    if h.t == "Header" and has_class(h, "incremental") and h.attributes["levels"] then
      local n = tonumber(h.attributes["levels"]) or 1
      h.attributes["levels"] = nil
      local keep = {}
      for _, c in ipairs(h.classes) do if c ~= "incremental" then keep[#keep + 1] = c end end
      h.classes = keep
      s.body = wrap_lists(s.body, n)
    end
    local kind = kind_of(h)
    if kind then
      pair_counter = pair_counter + 1
      local opts = take_options(h)
      local style = (kind == "header") and section_style(opts) or "full"
      local a = section_info(h, s.body, kind)
      local nxt = slides[i + 1]
      local has_summary = kind == "header" and nxt and kind_of(nxt.head) == "summary"
      if kind == "header" then
        local summary_subs = a.subs
        if has_summary then
          local p = split_body(nxt.body)
          if p.panel then summary_subs = p.panel end
        end
        toc_record(h, a.title, summary_subs)
      end
      if style == "simple" and kind == "header" then
        -- title only: no subtitle, no reference line, no morph
        a.subs = {}; a.ref = nil
        h.classes:insert("talk-sec-simple")
        for _, x in ipairs(build_section(a, nil, opts, nil, nil)) do out[#out + 1] = x end
        if has_summary then
          local h2, body = plain_summary(nxt)
          special_slide(h2)
          local has_content = false
          for _, b in ipairs(body) do if not (b.t == "Div" and has_class(b, "notes")) then has_content = true end end
          if has_content then plain_slide(h2, body) end
          i = i + 1
        end
      elseif has_summary then
        special_slide(nxt.head)
        local o2 = take_options(nxt.head, opts)
        -- the header lays out the summary's text (its invisible copy) exactly as the summary does
        for _, k in ipairs({ "panel-width", "panel-top", "summary-title-size", "panel-subtitle-size", "panel-padding" }) do
          opts[k] = o2[k]
        end
        local b = section_info(nxt.head, nxt.body, "summary")
        b.paired = true
        for _, x in ipairs(build_section(a, b, opts, o2, "talk-sec-" .. pair_counter)) do out[#out + 1] = x end
        i = i + 1
      else
        local pid = (kind ~= "panel") and ("talk-sec-" .. pair_counter) or nil
        for _, x in ipairs(build_section(a, nil, opts, nil, pid)) do out[#out + 1] = x end
      end
    else
      local body = s.body
      if h.t == "Header" and has_class(h, "toc-slide") then
        local found = false
        pandoc.Blocks(body):walk({ Div = function(d) if d.identifier == "toc" then found = true end end })
        if not found then
          body = pandoc.Blocks(body) .. pandoc.Blocks({ pandoc.Div({}, pandoc.Attr("", { "talk-toc-placeholder" })) })
        end
      end
      plain_slide(h, body)
    end
    if marker then appendix.on = true end
    i = i + 1
  end
  if appendix.after then
    io.stderr:write(string.format("talk: appendix after the slide \"%s\": the %d following slides are numbered additional-1 … additional-%d\n",
      appendix.after, appendix.count, appendix.count))
  end
  return out
end

local function fill_refs(blocks, doc)
  if not cite.enabled then return blocks end
  local found = false
  local res = pandoc.Blocks(blocks):walk({ Div = function(d)
    if d.identifier ~= "refs" then return nil end
    found = true
    local keys, seen = {}, {}
    local all = cited_keys(blocks)
    for _, k in ipairs(cite.used) do if cite.labels[k] then all[#all + 1] = k end end   -- cited in section titles
    for _, k in ipairs(all) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
    local nc = doc.meta.nocite and stringify(doc.meta.nocite) or ""
    for _, r in ipairs(cite.refs) do
      local id = stringify(r.id)
      if not seen[id] and (nc:find("@%*") or nc:find("@" .. id, 1, true)) then keys[#keys + 1] = id end
    end
    table.sort(keys, function(x, y) return (cite.labels[x] or x):lower() < (cite.labels[y] or y):lower() end)
    local ents = {}
    for _, e in ipairs(entries_for(keys)) do ents[#ents + 1] = e end
    -- keep the anchors ref-<key> so that citations still link to their entry
    for j, k in ipairs(keys) do if ents[j] then ents[j].identifier = "ref-" .. k end end
    -- (entries that do not fit the slide continue on copies of it: talk.js module 7)
    return pandoc.Div(ents, pandoc.Attr("talk-refs", { "references", "talk-references" }))
  end })
  if found then doc.meta["suppress-bibliography"] = true end
  return res
end

-- ---------------------------------------------------------------------------- title slide
-- ## {.title-slide}: the title slide, filled from the YAML (title, author, institute, subtitle,
-- date, talk: title-slide: {note, logos, background}); its own body (notes…) is kept.
--   parts="title logos" shows only some parts (e.g. the closing slide); a heading text replaces
--   the title. Without any .title-slide, one is added at the start (after the test slides).
-- Quarto's own title slide is switched off (the title moves to pagetitle).
local function meta_inlines(v)
  if v == nil then return nil end
  if type(v) == "string" then return pandoc.Inlines({ pandoc.Str(v) }) end
  if v.t == "MetaInlines" or v.t == "Inlines" or (type(v) == "table" and v[1] and v[1].t) then
    return pandoc.Inlines(v)
  end
  if v.t == "MetaBlocks" then return pandoc.utils.blocks_to_inlines(v) end
  return pandoc.Inlines({ pandoc.Str(stringify(v)) })
end
local function plain_text(inl)
  local out = {}
  pandoc.Inlines(inl):walk({ RawInline = function() out[#out + 1] = " " end,
    Str = function(x) out[#out + 1] = x.text end, Space = function() out[#out + 1] = " " end,
    LineBreak = function() out[#out + 1] = " " end, SoftBreak = function() out[#out + 1] = " " end })
  return (table.concat(out):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function title_slides(doc, blocks, ts)
  local meta = doc.meta
  if ts == false or (ts ~= nil and type(ts) ~= "table" and stringify(ts) == "false") then return blocks end   -- Quarto's own
  ts = type(ts) == "table" and ts or {}
  local title = meta_inlines(meta.title)
  local by = {}
  local function add(x) if x and #x > 0 then by[#by + 1] = x end end
  local authors = meta.author
  if authors then
    if authors.t == "MetaList" or (type(authors) == "table" and authors[1] and not authors[1].t) then
      for _, a in ipairs(authors) do add(meta_inlines(type(a) == "table" and a.name or a)) end
    else add(meta_inlines(type(authors) == "table" and authors.name or authors)) end
  end
  add(meta_inlines(meta.institute)); add(meta_inlines(meta.subtitle))
  local byline = pandoc.Inlines({})
  for k, x in ipairs(by) do
    if k > 1 then byline:insert(pandoc.Str(",")); byline:insert(pandoc.Space()) end
    byline:extend(x)
  end
  local note, date = meta_inlines(ts.note), meta_inlines(ts.date or meta.date)
  local logos = {}
  for _, l in ipairs(ts.logos or {}) do
    logos[#logos + 1] = pandoc.Image({}, stringify(type(l) == "table" and (l.src or l) or l))
  end
  -- Quarto must not build its own title slide
  if title then
    if not meta.pagetitle then meta.pagetitle = pandoc.MetaString(plain_text(title)) end
    meta.title = nil
  end
  local function fill(h)
    local parts = {}
    for p in tostring(h.attributes["parts"] or "title byline note date logos"):gmatch("%S+") do parts[p] = true end
    h.attributes["parts"] = nil
    h.classes:insert("nobar")
    if not h.attributes["background-color"] then
      h.attributes["background-color"] = ts.background and stringify(ts.background) or "var(--talk-accent)"
    end
    local t = (#h.content > 0) and h.content or title
    h.content = pandoc.Inlines(t):walk({ LineBreak = function() return pandoc.Space() end })   -- hidden (CSS); names the slide (menu, logs)
    local box = {}
    local function div(cls, inl) if inl and #inl > 0 then box[#box + 1] = pandoc.Div({ pandoc.Plain(inl) }, pandoc.Attr("", { cls })) end end
    if parts.title then div("ts-title", t) end
    if parts.byline then div("ts-byline", byline) end
    if parts.note then div("ts-note", note) end
    if parts.date then div("ts-date", date) end
    local out = { pandoc.Div(box, pandoc.Attr("", { "ts-text" })) }
    if parts.logos and #logos > 0 then
      local imgs = {}
      for _, im in ipairs(logos) do imgs[#imgs + 1] = im:clone() end
      out[#out + 1] = pandoc.Div({ pandoc.Plain(imgs) }, pandoc.Attr("", { "ts-logos" }))
    end
    return out
  end
  local res, found = {}, false
  for _, b in ipairs(blocks) do
    res[#res + 1] = b
    if b.t == "Header" and has_class(b, "title-slide") then
      found = true
      for _, x in ipairs(fill(b)) do res[#res + 1] = x end
    end
  end
  if not found and title then
    -- automatic title slide: before the first slide that is not a test slide
    local h = pandoc.Header(2, {}, pandoc.Attr("talk-title", { "title-slide" }))
    local ins = #res + 1
    for k, b in ipairs(res) do
      if b.t == "Header" and b.level <= 2 and not has_class(b, "test-slide") then ins = k; break end
    end
    local add_blocks = { h }
    for _, x in ipairs(fill(h)) do add_blocks[#add_blocks + 1] = x end
    for k = #add_blocks, 1, -1 do table.insert(res, ins, add_blocks[k]) end
  end
  return res
end

-- ---------------------------------------------------------------------------- push transition
-- ## Title {push=up|down|left|right}: PowerPoint "Push": this slide pushes the previous one
-- out (both move together). reveal.js animates each slide with its OWN transition, so a slide
-- with transition="slide" after a slide without one slides in over an empty screen (the old
-- slide vanishes at once). The pair therefore gets data-transition="talk-push" and classes
-- talk-push-in-DIR (this slide) / talk-push-out-DIR (the previous one); talk.scss moves only
-- the two states of the push and makes every other change instant.
local function push_transitions(blocks)
  local heads = {}
  for _, b in ipairs(blocks) do
    if b.t == "Header" and b.level <= 2 then heads[#heads + 1] = b end
  end
  for k, h in ipairs(heads) do
    local dir = h.attributes["push"]
    if dir then
      h.attributes["push"] = nil
      if dir == "true" or dir == "" then dir = "left" end
      h.attributes["transition"] = "talk-push"
      h.classes:insert("talk-push-in-" .. dir)
      h.classes:insert("talk-push-in")
      local prev = heads[k - 1]
      if prev then
        prev.attributes["transition"] = "talk-push"
        prev.classes:insert("talk-push-out-" .. dir)
        prev.classes:insert("talk-push-out")
      end
    end
  end
  return blocks
end

-- ---------------------------------------------------------------------------- meta / dependencies
function Pandoc(doc)
  if not quarto.doc.is_format("revealjs") then return doc end
  local m = doc.meta.talk or {}
  local sec = m.section or {}
  local root = {}
  for k, var in pairs(VARS) do
    if sec[k] ~= nil then
      local v = stringify(sec[k])
      if LENGTH[k] then v = css_size(v) end
      root[#root + 1] = var .. ":" .. v
    end
  end
  for _, k in ipairs({ "color", "duration", "easing", "title-size", "summary-title-size", "style",
                       "panel-width", "subtitle-size" }) do
    if sec[k] then global[k] = stringify(sec[k]) end
  end
  -- panel sizes not given in the YAML follow the YAML panel-width (reference: 440 px)
  local pw = px_number(global["panel-width"])
  if pw and pw ~= 440 then
    for k, target in pairs(PANEL_SIZES) do
      if not sec[k] and not sec[target] then
        local v = string.format("%.4g", px_number(global[k]) * pw / 440)
        if k == target then global[k] = v end
        root[#root + 1] = VARS[target] .. ":" .. v .. "px"
      end
    end
  end
  if m.bullets then root[#root + 1] = bullet_vars(stringify(m.bullets)) end
  do
    local t, s = px_number(global["title-size"]), px_number(global["summary-title-size"])
    if t and s and t > 0 then root[#root + 1] = string.format("--sec-title-ratio:%.4f", s / t) end
  end

  -- theme colours
  local colors = m.colors or {}
  local css = {}
  local function col(k) return colors[k] and stringify(colors[k]) or nil end
  if col("background") then
    root[#root + 1] = "--talk-bg:" .. col("background")
    root[#root + 1] = "--r-background-color:" .. col("background")
    css[#css + 1] = ".reveal-viewport{background-color:" .. col("background") .. " !important}"
  end
  if col("text") then root[#root + 1] = "--talk-text:" .. col("text"); root[#root + 1] = "--r-main-color:" .. col("text") end
  if col("title") then root[#root + 1] = "--talk-title:" .. col("title"); root[#root + 1] = "--r-heading-color:" .. col("title") end
  if col("bar") then root[#root + 1] = "--talk-bar:" .. col("bar") end
  if col("accent") then
    root[#root + 1] = "--talk-accent:" .. col("accent")
    if not sec.color then root[#root + 1] = "--sec-color:" .. col("accent"); global.color = col("accent") end
  end

  local au = m.audio or {}
  local function b(v, d) if v == nil then return d end; local s = stringify(v); return s == "true" or s == "yes" end
  if au.size then root[#root + 1] = "--talk-audio-size:" .. css_size(stringify(au.size)) end
  if m["push-duration"] then root[#root + 1] = "--talk-push-duration:" .. stringify(m["push-duration"]) end
  local sn = m["slide-number"] or {}
  local function js(v, d) return '"' .. (v and stringify(v) or d):gsub('[\\"]', "\\%0") .. '"' end
  local cfg = string.format('{"audio":{"autoplay":%s,"delay":%s,"stopOnSlideChange":%s},"slideNumber":{"test":%s,"additional":%s}}',
    tostring(b(au.autoplay, false)), au.delay and stringify(au.delay) or "0",
    tostring(b(au["stop-on-slide-change"], true)),
    js(sn.test, "test slide"), js(sn.additional, "additional-{n}"))
  local head = "<script>window.TalkConfig = " .. cfg .. ";</script>"
  if #root > 0 then head = head .. "\n<style>html:root{" .. table.concat(root, ";") .. "}" .. table.concat(css, "") .. "</style>" end
  quarto.doc.include_text("in-header", head)

  local fonts = {}
  for _, w in ipairs({ "400", "600", "700" }) do
    for _, s in ipairs({ "normal", "italic" }) do
      fonts[#fonts + 1] = "fonts/libre-franklin-latin-" .. w .. "-" .. s .. ".woff2"
    end
  end
  quarto.doc.add_html_dependency({
    name = "talk", version = "1.1.0",
    scripts = { { path = "talk.js", afterBody = true } },
    stylesheets = { "fonts.css" },
    resources = fonts,
  })

  setup_citations(doc, m.citations or {})
  local blocks = pandoc.Blocks(title_slides(doc, doc.blocks, m["title-slide"]))
  blocks = fullcites(blocks)
  blocks = blocks:walk({ Div = static_block })
  blocks = blocks:walk({ Div = function(d) local r = grid_box(d) or list_div(d) or card(d) or d
                           r = rot(r) or r; r = stack(r) or r; r = shape(r) or r; r = dims(r) or r
                           return box_attrs(r) or r end,
                         Span = function(sp)
                           local trigger = audio_play(sp)
                           local r = grid_box(sp) or audio_icon(sp) or sp
                           r = rot(r) or r; r = stack(r) or r; r = shape(r) or r; r = dims(r) or r; r = box_attrs(r) or r
                           if trigger then return { r, trigger } end
                           return r
                         end,
                         RawBlock = mermaid_maths, Header = title_attrs, BulletList = mark_items,
                         Para = function(pa)        -- a paragraph holding only &nbsp;: an empty line
                           if #pa.content == 1 and pa.content[1].t == "Str" and pa.content[1].text == "\u{a0}" then
                             return pandoc.Div({}, pandoc.Attr("", { "empty-line" })) end end })
  blocks = pandoc.Blocks(process(blocks))
  blocks = fill_toc(blocks)
  blocks = pandoc.Blocks(push_transitions(blocks))
  blocks = fill_refs(blocks, doc)
  blocks = blocks:walk({ Image = highlight_image, Div = highlight_div, Span = highlight_span })
  blocks = blocks:walk({ Math = highlight_math })
  blocks = blocks:walk({ Div = function(d) return annotation(d) or edge(d) end, Span = edge })
  if m.highlight then
    local hv = {}
    if m.highlight.color then hv[#hv + 1] = "--talk-hl:" .. stringify(m.highlight.color) end
    if m.highlight.opacity then hv[#hv + 1] = "--talk-hl-opacity:" .. stringify(m.highlight.opacity) end
    for k, v in pairs(m.highlight.colors or {}) do         -- a value may be another name: shade6: dark
      local c = stringify(v)
      if c:match("^%a[%w%-]*$") then c = color_value(c) end
      hv[#hv + 1] = "--hl-" .. k .. ":" .. c
    end
    if #hv > 0 then quarto.doc.include_text("in-header", "<style>html:root{" .. table.concat(hv, ";") .. "}</style>") end
  end
  blocks = blocks:walk({ Image = tilt, Div = tilt, Span = tilt })
  if cite.enabled then blocks = resolve_cites(blocks) end
  doc.blocks = blocks
  return doc
end
