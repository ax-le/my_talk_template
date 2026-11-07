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


-- The filter is split into lib/*.lua, loaded here into ONE environment (E) shared by all the parts,
-- so a part calls any function of another one directly. Order of the parts: no matter (the names
-- are looked up when the functions run).
local G = _ENV                                 -- the filter's own environment
local E = setmetatable({}, { __index = G })
for _, part in ipairs({ "common", "citations", "sections", "highlights", "boxes" }) do
  assert(loadfile(quarto.utils.resolve_path("lib/" .. part .. ".lua"), "t", E))()
end
local _ENV = E

-- ---------------------------------------------------------------------------- meta / dependencies
function Pandoc(doc)
  if not quarto.doc.is_format("revealjs") then return doc end
  local m = doc.meta.talk or {}
  local sec = m.section or {}
  local root = sec_vars(function(k) return sec[k] ~= nil and stringify(sec[k]) or nil end)
  for _, k in ipairs({ "duration", "easing", "style" }) do
    if sec[k] then global[k] = stringify(sec[k]) end
  end
  if m.bullets then root[#root + 1] = bullet_vars(stringify(m.bullets)) end

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
  if col("accent") then root[#root + 1] = "--talk-accent:" .. col("accent") end   -- (--sec-color follows it, talk.scss)

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
    name = "talk", version = "1.1.0",   -- (= version in _extension.yml)
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
                           local snd, after = audio(sp)
                           if not snd and #after > 0 then return after end
                           local r = snd or grid_box(sp) or sp
                           r = rot(r) or r; r = stack(r) or r; r = shape(r) or r; r = dims(r) or r; r = box_attrs(r) or r
                           if #after > 0 then table.insert(after, 1, r); return after end
                           return r
                         end,
                         Image = function(img)
                           local snd, after = audio(img)
                           if #after > 0 then table.insert(after, 1, snd or img); return after end
                           return snd
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
  blocks = blocks:walk({ Div = annotation, Span = annotation })
  if m.highlight then
    local hv = {}
    if m.highlight.color then hv[#hv + 1] = "--talk-hl:" .. stringify(m.highlight.color) end
    if m.highlight.opacity then hv[#hv + 1] = "--talk-hl-opacity:" .. stringify(m.highlight.opacity) end
    local hc = m.highlight.colors or {}
    for _, k in ipairs(sorted_keys(hc)) do         -- a value may be another name: shade6: dark
      local c = stringify(hc[k])
      c = color_value(c)
      hv[#hv + 1] = "--hl-" .. k .. ":" .. c
    end
    if #hv > 0 then quarto.doc.include_text("in-header", "<style>html:root{" .. table.concat(hv, ";") .. "}</style>") end
  end
  blocks = blocks:walk({ Image = tilt, Div = tilt, Span = tilt })
  if cite.enabled then blocks = resolve_cites(blocks) end
  doc.blocks = blocks
  return doc
end
G.Pandoc = Pandoc   -- the filter function, seen by Pandoc / Quarto
