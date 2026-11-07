-- lib/sections.lua — part of talk.lua: slides: section header / summary / side panel, title slide, test slide and appendix, table of contents, push transition, the split into slides (process).
-- Loaded by talk.lua into one shared environment: the top-level functions and tables of every
-- part are visible to the others (no `local` at the top level; locals inside functions as usual).

-- ---------------------------------------------------------------------------- options
VARS = {
  ["color"] = "--sec-color", ["text-color"] = "--sec-text", ["ref-color"] = "--sec-ref-color",
  ["panel-width"] = "--sec-panel-width", ["title-size"] = "--sec-title-size",
  ["summary-title-size"] = "--sec-summary-title-size", ["subtitle-size"] = "--sec-subtitle-size",
  ["ref-size"] = "--sec-ref-size", ["title-width"] = "--sec-title-width",
  ["title-weight"] = "--sec-title-weight", ["panel-padding"] = "--sec-panel-padding",
  ["panel-subtitle-size"] = "--sec-panel-subtitle-size",
  ["panel-top"] = "--sec-panel-top", ["border-width"] = "--sec-border-width",
  ["border-color"] = "--sec-border-color",
}
-- section options given in px: NUMBER ones are written as plain numbers (talk.scss computes from them
-- the panel sizes that follow panel-width, and the summary / header title ratio), LENGTH ones in px
NUMBER = { ["panel-width"] = true, ["title-size"] = true, ["summary-title-size"] = true,
                 ["subtitle-size"] = true, ["panel-subtitle-size"] = true }
LENGTH = { ["ref-size"] = true, ["title-width"] = true, ["panel-padding"] = true, ["panel-top"] = true,
                 ["border-width"] = true }
-- defaults that are not CSS (the CSS defaults live in talk.scss :root, SECTION SLIDES)
global = { duration = "1.2", easing = "ease-in-out" }

pair_counter = 0   -- section-like slides built so far (their ids: talk-sec-N, talk-panel-N)

-- ---------------------------------------------------------------------------- word splitting
PUNCT = {}
for _, c in utf8.codes("()[]{},.;:!?«»\"“”‘’/|") do PUNCT[c] = true end

function tokens(s)
  local out, cur = {}, {}
  local function flush() if #cur > 0 then out[#out + 1] = table.concat(cur); cur = {} end end
  for _, c in utf8.codes(s) do
    if PUNCT[c] then flush(); out[#out + 1] = utf8.char(c)
    else cur[#cur + 1] = utf8.char(c) end
  end
  flush()
  return out
end

function keyof(tok)
  local k = tok:lower():gsub("[%s\"'<>&=]", "")
  if k == "" then k = "x" end
  return k
end

-- every word / punctuation mark → <span class="w" data-id="…">  (ids collected in `ids`)
function wordify(inlines, prefix, ids)
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

function wordify_blocks(blocks, prefix, ids)
  local i = 0
  return pandoc.Blocks(blocks):walk({
    Plain = function(b) i = i + 1; return pandoc.Plain(wordify(b.content, prefix .. "-" .. i, ids)) end,
    -- no <p>: reveal.js also pairs paragraphs by their text, which would move them twice
    Para = function(b) i = i + 1; return pandoc.Div({ pandoc.Plain(wordify(b.content, prefix .. "-" .. i, ids)) }, pandoc.Attr("", { "sec-p" })) end,
  })
end

-- keep data-id only where keep(id) is true (used for the invisible "ghost" copies)
function filter_ids(blocks, keep)
  local function f(el)
    local id = el.attributes["data-id"]
    if id and not keep(id) then el.attributes["data-id"] = nil; return el end
  end
  return pandoc.Blocks(blocks):walk({ Span = f, Div = f })
end

-- ---------------------------------------------------------------------------- section slides
function take_options(h, inherited)
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

-- section options → CSS variables (get(option) → its value or nil), for a slide or the YAML
function sec_vars(get)
  local parts = {}
  for _, k in ipairs(sorted_keys(VARS)) do
    local v = get(k)
    if v and NUMBER[k] then
      local n = px_number(v)
      if not n then io.stderr:write("talk: section option " .. k .. "=" .. v .. " must be a number of px\n") end
      v = n and string.format("%g", n)
    elseif v and LENGTH[k] then v = css_size(v) end
    if v then parts[#parts + 1] = VARS[k] .. ":" .. v end
  end
  return parts
end
function style_of(o) return table.concat(sec_vars(function(k) return o[k] end), ";") end

function split_body(body)
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
function text_blocks(layout, title_inlines, subs, ref, prefix, ids)
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
function section_info(h, body, kind)
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

function slide_attrs(info, opts, pid)
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
  add_style(h.attributes, style_of(opts))
end

function layout_of(kind) return kind == "header" and "header" or "summary" end

-- build one or two (header + summary) slides
function build_section(a, b, opts_a, opts_b, pid)
  local out = {}
  local prefix = pid or ("talk-panel-" .. pair_counter)   -- (pair_counter: one per section-like slide)
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
        remove_class(d, "fragment", "fade-out", "move", "audio-btn")
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

-- ---------------------------------------------------------------------------- slides
function is_break(b)
  return (b.t == "Header" and b.level <= 2) or b.t == "HorizontalRule"
end

function kind_of(h)
  if h.t ~= "Header" then return nil end
  if has_class(h, "section-header") then return "header" end
  if has_class(h, "section-summary") then return "summary" end
  if has_class(h, "side-panel") then return "panel" end
  return nil
end

-- ---------------------------------------------------------------------------- slide numbers
-- .test-slide (first slide used to test the clicker / sound) and .additional (backup slides)
-- are left out of the count; talk.js labels them "test slide" and "additional-1, -2, …"
-- Appendix: an empty  ::: {.appendix} :::  anywhere in a slide (usually at the end of the
-- conclusion) makes EVERY following slide .additional, like LaTeX \appendix. A slide after it
-- can opt out with .counted. The render log says where the appendix starts (never silent).
appendix = { on = false, after = nil, count = 0 }
function slide_label(h)
  if h.t ~= "Header" then return "(slide break)" end
  local t = stringify(h.content)
  if t == "" then t = "#" .. h.identifier end
  return t
end
function take_appendix_marker(body)
  local found, keep = false, {}
  for _, b in ipairs(body) do
    if b.t == "Div" and has_class(b, "appendix") then found = true
    else keep[#keep + 1] = b end
  end
  return keep, found
end
function special_slide(h)
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
toc_entries = {}
function deep(blocks) return pandoc.Blocks(blocks):walk({}) end
function toc_record(h, title, summary)
  if has_class(h, "no-toc") then return end
  if h.identifier == "" then h.identifier = "talk-section-" .. (#toc_entries + 1) end
  local sum = {}
  for _, b in ipairs(summary or {}) do
    if not (b.t == "Div" and (has_class(b, "slide-refs") or has_class(b, "notes"))) then sum[#sum + 1] = b end
  end
  toc_entries[#toc_entries + 1] = { id = h.identifier, title = pandoc.Inlines(title):walk({}), summary = deep(sum) }
end
function toc_blocks()
  local items = {}
  for k, e in ipairs(toc_entries) do
    local inner = { pandoc.Div({ pandoc.Plain({ pandoc.Link(e.title, "#/" .. e.id) }) }, pandoc.Attr("", { "toc-title" })) }
    if #e.summary > 0 then inner[#inner + 1] = pandoc.Div(e.summary, pandoc.Attr("", { "toc-summary" })) end
    items[#items + 1] = pandoc.Div(inner, pandoc.Attr("", { "toc-item" }, { { "data-toc-index", tostring(k) } }))
  end
  return pandoc.Div(items, pandoc.Attr("", { "talk-toc" }))
end
function fill_toc(blocks)
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
function section_style(opts)
  local st = opts.style or global.style or "full"
  return st
end

function plain_summary(s)
  -- the summary slide in "simple" style: heading hidden (kept for the menu), panel dropped
  local parts = split_body(s.body)
  local h = s.head
  h.classes:insert("talk-hidden-title")
  remove_class(h, "section-summary")
  for k, _ in pairs(VARS) do h.attributes[k] = nil end
  h.attributes["style"] = nil; h.attributes["duration"] = nil; h.attributes["easing"] = nil
  local body = {}
  for _, b in ipairs(parts.rest) do body[#body + 1] = b end
  for _, b in ipairs(parts.notes) do body[#body + 1] = b end
  return h, body
end

function process(blocks)
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
    local levels = h.t == "Header" and take_levels(h)
    if levels then s.body = wrap_lists(s.body, levels) end
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
      -- .toc-slide / .references-slide: the list goes at the end of the slide, unless the slide
      -- places it itself (::: {#toc} / ::: {#refs})
      local function ensure(cls, id, placeholder)
        if not (h.t == "Header" and has_class(h, cls)) then return end
        local found = false
        pandoc.Blocks(body):walk({ Div = function(d) if d.identifier == id then found = true end end })
        if not found then body = pandoc.Blocks(body) .. pandoc.Blocks({ placeholder }) end
      end
      ensure("toc-slide", "toc", pandoc.Div({}, pandoc.Attr("", { "talk-toc-placeholder" })))
      ensure("references-slide", "refs", pandoc.Div({}, pandoc.Attr("refs")))
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

-- ---------------------------------------------------------------------------- title slide
-- ## {.title-slide}: the title slide, filled from the YAML (title, author, institute, subtitle,
-- date, talk: title-slide: {note, logos, background}); its own body (notes…) is kept.
--   parts="title logos" shows only some parts (e.g. the closing slide); a heading text replaces
--   the title. Without any .title-slide, one is added at the start (after the test slides).
-- Quarto's own title slide is switched off (the title moves to pagetitle).
function meta_inlines(v)
  if v == nil then return nil end
  if type(v) == "string" then return pandoc.Inlines({ pandoc.Str(v) }) end
  if v.t == "MetaInlines" or v.t == "Inlines" or (type(v) == "table" and v[1] and v[1].t) then
    return pandoc.Inlines(v)
  end
  if v.t == "MetaBlocks" then return pandoc.utils.blocks_to_inlines(v) end
  return pandoc.Inlines({ pandoc.Str(stringify(v)) })
end
function plain_text(inl)
  local out = {}
  pandoc.Inlines(inl):walk({ RawInline = function() out[#out + 1] = " " end,
    Str = function(x) out[#out + 1] = x.text end, Space = function() out[#out + 1] = " " end,
    LineBreak = function() out[#out + 1] = " " end, SoftBreak = function() out[#out + 1] = " " end })
  return (table.concat(out):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function title_slides(doc, blocks, ts)
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
function push_transitions(blocks)
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
