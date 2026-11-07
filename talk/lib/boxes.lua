-- lib/boxes.lua — part of talk.lua: boxes: lists, sounds, short attributes, shapes, stacks, dimension arrows, rotated content, cards, grid boxes.
-- Loaded by talk.lua into one shared environment: the top-level functions and tables of every
-- part are visible to the others (no `local` at the top level; locals inside functions as usual).

-- ---------------------------------------------------------------------------- lists
-- bullets="■ – • ○ ►" on a div (or YAML talk: bullets:), "none" = no marker → --talk-bN variables (5 levels)
function bullet_vars(spec)
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
function wrap_list(list, maxdepth, depth)
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
function wrap_lists(blocks, maxdepth)
  local out = {}
  for _, b in ipairs(blocks) do
    if b.t == "BulletList" or b.t == "OrderedList" then out[#out + 1] = wrap_list(b, maxdepth, 1)
    else out[#out + 1] = b end
  end
  return out
end

-- - [text]{mark=media/icon.svg mark-size=40}: that picture as the item's marker (the item's
-- blocks are wrapped in div.marked, the picture inline before the text as img.mark; talk.scss LISTS)
function mark_items(list)
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

function list_div(d)
  local changed = false
  if d.attributes["bullets"] then
    add_style(d.attributes, bullet_vars(d.attributes["bullets"]))
    d.attributes["bullets"] = nil
    changed = true
  end
  local n = take_levels(d)
  if n then
    d.content = wrap_lists(d.content, n)
    changed = true
  end
  if changed then return d end
end

-- ---------------------------------------------------------------------------- audio
-- [label]{audio=media/x.mp3}: a speaker icon (then its label, if any) that plays / stops the sound
-- when clicked; ![](pic.png){audio=…}: the picture is the button. On either:
--   play=0   plays when it is shown (the slide opens, or its own fragment appears)
--   play=N   plays at click N (on a .fragment without fragment-index: it also appears at click N)
--   delay=S  the sound starts S s after that;   loop=true;   volume=0.6
--   stop=N   every sound stops at click N (also on an empty span: []{stop=N})
-- Icon size: --talk-audio-size (2em of the font: size= pt; YAML talk: audio: size).
-- Output: data-audio, data-autoplay, data-autoplay-delay, data-loop, data-volume (read by talk.js)
-- and trigger fragments <span class="fragment" data-play=ID> / data-stop-audio after the element.
AUDIO_ICON = [[<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 9v6h4l5 4V5L7 9H3z" fill="currentColor"/>]] ..
  [[<path class="wave" d="M15.5 8.5a5 5 0 0 1 0 7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>]] ..
  [[<path class="wave" d="M18 6a8.5 8.5 0 0 1 0 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>]]
play_count = 0
function trigger(attr, value, n)
  return pandoc.Span({}, pandoc.Attr("", { "fragment", "talk-trigger" }, { { attr, value }, { "data-fragment-index", n } }))
end
-- returns the element (or nil when it is not a sound) and the trigger fragments to put after it
function audio(el)
  local a, after = el.attributes, {}
  local src, n = a["audio"], a["play"]
  if not src and not a["stop"] then return nil, after end
  if src then
    a["audio"], a["play"] = nil, nil
    a["data-audio"] = src
    if a["loop"] then if a["loop"] ~= "false" then a["data-loop"] = "" end; a["loop"] = nil end
    if a["volume"] then a["data-volume"] = a["volume"]; a["volume"] = nil end
    if a["delay"] then a["data-autoplay-delay"] = a["delay"]; a["delay"] = nil end
    if el.t == "Span" then
      el.classes:insert("audio-btn"); el.classes:insert("talk-audio")
      el.content:insert(1, pandoc.RawInline("html", AUDIO_ICON))
      a["role"], a["tabindex"], a["title"] = a["role"] or "button", a["tabindex"] or "0", a["title"] or "Play / stop"
    end
    if n == "0" then a["data-autoplay"] = "true"
    elseif n and has_class(el, "fragment") and not (a["fragment-index"] or a["data-fragment-index"]) then
      a["fragment-index"], a["data-autoplay"] = n, "true"
    elseif n then
      if el.identifier == "" then play_count = play_count + 1; el.identifier = "talk-play-" .. play_count end
      after[#after + 1] = trigger("data-play", el.identifier, n)
    end
  end
  if a["stop"] then after[#after + 1] = trigger("data-stop-audio", "true", a["stop"]); a["stop"] = nil end
  if not src and el.t == "Span" and #el.content == 0 then return nil, after end   -- []{stop=N}: the trigger alone
  return el, after
end

-- ---------------------------------------------------------------------------- short box attributes
-- Positions, sizes and colours as attributes instead of a long style= (any div or span):
--   left= top= right= bottom= width= height=   on .absolute divs (numbers = px; Quarto's own
--                                             attributes, kept even when a style= is present)
--   size=18          font size in points (× --talk-pt, so it follows the deck's font scale)
--   color= background=   any CSS colour, or a theme name: text title accent background bar
--   align=center|right   line-height=   border="1px solid accent"   radius=   padding=
-- ---------------------------------------------------------------------------- static blocks
-- ::: {.static} … ::: shows its content in its final state, without clicks (fragments removed;
-- what would end hidden, .fade-out / .fade-in-then-out, is dropped). E.g. a slide built click by
-- click, included again later as a recap: {{< include _outline.qmd >}} inside ::: {.static}.
function static_block(d)
  if not has_class(d, "static") then return nil end
  local function strip(el)
    if not has_class(el, "fragment") then return nil end
    if has_class(el, "fade-out") or has_class(el, "fade-in-then-out") then return {} end
    remove_class(el, "fragment")
    el.attributes["fragment-index"], el.attributes["data-fragment-index"] = nil, nil
    return el
  end
  return pandoc.Div(pandoc.Blocks(d.content):walk({ Div = strip, Span = strip, Image = strip }), pandoc.Attr("", {}))
end

-- ---------------------------------------------------------------------------- title position
-- ## Title {top=15 left=146 width=1008 size=40}: the slide title placed like a PowerPoint title box
-- (defaults: the title placeholder, talk.scss). Pandoc moves heading attributes to the <section>,
-- so they become CSS variables there, read by the h2 rule.
function title_attrs(h)
  if h.level ~= 2 then return nil end
  local st = {}
  for _, k in ipairs({ "top", "left", "width" }) do
    if h.attributes[k] then st[#st + 1] = "--title-" .. k .. ":" .. css_size(h.attributes[k]); h.attributes[k] = nil end
  end
  if h.attributes["size"] then st[#st + 1] = "--title-size:calc(" .. h.attributes["size"] .. " * var(--talk-pt))"; h.attributes["size"] = nil end
  if #st == 0 then return nil end
  add_style(h.attributes, table.concat(st, ";"))
  return h
end

-- ---------------------------------------------------------------------------- shapes
-- shape=NAME on any box (div or span) draws that outline behind its content, sized to the box:
--   arrow-right|arrow-left|arrow-up|arrow-down (head= length, shaft= thickness, in % of the box),
--   shrink|grow (trapezoid narrowing / widening to the right, taper= narrow side in %),
--   parallelogram (slant= %), cube (depth= in px; the content goes in the front face).
-- background= fills it, border="W STYLE COLOUR" draws its outline (instead of a rectangle); with
-- .box or .filled the outline and fill default to that style.
function shape_path(kind, a, W, H)
  local function pc(k, d) return num_in(a[k], d) end
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

function shape(el)
  local a = el.attributes
  local kind = a["shape"]
  if not kind then return nil end
  local W, H = px_number(a["width"]) or 100, px_number(a["height"]) or 100
  local d = shape_path(kind, a, W, H)
  if not d then io.stderr:write("talk: unknown shape=" .. kind .. "\n"); return nil end
  local filled = has_class(el, "filled")
  local fill = a["background"] and color_value(a["background"])
    or (filled and "var(--talk-filled-bg)") or (has_class(el, "box") and "var(--talk-bg)") or "none"
  local bw, bc = filled and "var(--talk-filled-bw)" or "1", filled and "var(--talk-filled-bc)" or "#000"   -- (talk.scss .filled)
  if a["border"] then
    for tok in a["border"]:gmatch("%S+") do
      if tok:match("^[%d%.]+p?x?$") then bw = tok:gsub("px", "")
      elseif tok ~= "solid" then bc = color_value(tok) end
    end
  end
  if kind == "cube" then
    local dp = num_in(a["depth"], 20)
    add_style(a, "padding-top:" .. dp .. "px;padding-right:" .. dp .. "px")
    -- for dims(): the depth edge and the front face
    a["dim-geom"] = "0 " .. dp .. " " .. dp .. " 0"
    a["dim-inset-top"], a["dim-inset-right"] = dp, dp
  elseif kind == "parallelogram" then
    local k = num_in(a["slant"], 25) * W / 100
    a["dim-geom"] = string.format("0 %s %.4g 0", H, k)
    a["dim-inset-right"] = string.format("%.4g", k)
  end
  for _, k in ipairs({ "shape", "head", "shaft", "taper", "slant", "depth", "background", "border" }) do a[k] = nil end
  el.classes:insert("shape")
  local svg = string.format('<svg class="geom" viewBox="0 0 %s %s" preserveAspectRatio="none" overflow="visible">' ..
    '<path d="%s" fill="%s" stroke="%s" stroke-width="%s" vector-effect="non-scaling-stroke"/></svg>', W, H, d, fill, bc, bw)
  el.content:insert(1, (el.t == "Span") and pandoc.RawInline("html", svg) or pandoc.RawBlock("html", svg))
  return el
end

-- ---------------------------------------------------------------------------- stacks
-- stack="c1 c2 … cn" on a box: n slices of the box's size, the first one in front (the box
-- itself: its background becomes the first colour), the others shifted behind it, up to
-- depth= px to the right and lift= px up (default 0.85 × depth), like a stack of matrices.
-- morph-id=PREFIX gives the slices data-id PREFIX-1 … PREFIX-n (a Morph from the cells of a grid box
-- with the same morph-id).
function stack(el)
  local a = el.attributes
  if not a["stack"] then return nil end
  local colors = {}
  for c in tostring(a["stack"]):gmatch("%S+") do colors[#colors + 1] = c end
  local n = #colors
  local depth = num_in(a["depth"], 20) or 20
  local lift = num_in(a["lift"], "") or depth * 0.85
  local prefix = a["morph-id"]          -- (removed by box_attrs: dims() reads it too)
  a["stack"], a["lift"] = nil, nil
  a["depth"] = nil
  -- dims drawn by dims(): the depth arrow runs from the front slice's corner to the back one
  a["dim-geom"] = string.format("0 0 %.4g %.4g", depth, -lift)
  local mk = ctor(el)
  -- the slices draw the frame (the box's own border is dropped, talk.scss: it would show at its
  -- final place while the slices morph in)
  local border = a["border"] and colors_in(a["border"])
                 or has_class(el, "box") and "1px solid #000" or "none"
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
  set_content(el, content)
  el.classes:insert("stacked")
  return el
end

-- ---------------------------------------------------------------------------- dimension arrows
-- dim-left="f" dim-bottom="t" dim-top=… dim-right=… dim-depth="b" on any box (.box, a
-- cube or parallelogram shape, a stack): an arrow along that side, 14 px outside the box, with
-- its label (maths: `r_t` is read as $r_t$; Markdown with $…$ or text otherwise) beyond it.
-- On a cube the left and bottom arrows follow the front face and the depth arrow the top-left
-- edge; on a parallelogram the depth arrow follows the slanted left side; on a stack it goes
-- from the front slice to the back one. (dim-geom = "x0 y0 x1 y1": the depth edge, set by
-- shape() / stack(), in px of the box.)
function dim_label(v)
  if v:find("$", 1, true) then return pandoc.read(v, "markdown").blocks[1].content end
  return pandoc.Inlines({ pandoc.Math("InlineMath", v) })
end
function dims(el)
  local a = el.attributes
  local any = false
  for _, side in ipairs({ "left", "right", "top", "bottom", "depth" }) do if a["dim-" .. side] then any = true end end
  if not any then a["dim-geom"] = nil; return nil end
  local mk = ctor(el)
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
      -- morph-id=P: the straight arrows get data-id P-left… (the depth one carries its own rotation,
      -- which reveal would replace while morphing)
      if side ~= "depth" and a["morph-id"] then attrs[#attrs + 1] = { "data-id", a["morph-id"] .. "-" .. side } end
      local label = dim_label(v)
      if el.t ~= "Span" then label = { pandoc.Plain(label) } end
      added[#added + 1] = mk({ mk({}, pandoc.Attr("", { "dim-arrow" })), mk(label, pandoc.Attr("", { "dim-label" })) },
        pandoc.Attr("", { "dim", "dim-" .. side }, attrs))
    end
  end
  local content = {}
  for _, x in ipairs(el.content) do content[#content + 1] = x end
  for _, x in ipairs(added) do content[#content + 1] = x end
  set_content(el, content)
  add_style(a, table.concat(st, ";"))
  return el
end

-- ---------------------------------------------------------------------------- rotated content
-- .rot-l / .rot-r on a box: its content is turned by a quarter turn (left: read bottom-up),
-- still centred in the box (the box and its border stay as they are): labels of column vectors
function rot(el)
  if not (has_class(el, "rot-l") or has_class(el, "rot-r")) then return nil end
  local inner = {}
  for _, x in ipairs(el.content) do inner[#inner + 1] = x end
  set_content(el, { ctor(el)(inner, pandoc.Attr("", { "rot" })) })
  return el
end

-- ---------------------------------------------------------------------------- cards
-- ::: {.card}  ### Title  body…  ::: {.card-foot} … :::  :::  — a titled box: the title in the
-- PowerPoint shape style (.filled), the body framed under it (text centred vertically), an
-- optional footer at the bottom. Works alone (.absolute, width= height=) or as a column
-- (::: {.column .card}: the cards of a row share the row's height).
function card(d)
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
  set_content(d, out)
  return d
end

-- ---------------------------------------------------------------------------- mermaid diagrams
-- ```{mermaid}``` charts (Quarto has already turned them into <pre class="mermaid-js">): maths in
-- labels ($$…$$) rendered by KaTeX as HTML, not MathML, so it uses the slides' KaTeX fonts
-- (\mathscr…). Set in the chart's own init directive.
function mermaid_maths(r)
  if r.format ~= "html" or not r.text:match('^<pre class="mermaid mermaid%-js">') then return nil end
  r.text = r.text:gsub('^(<pre class="mermaid mermaid%-js">)', '%1%%%%{init: {"forceLegacyMathML": true}}%%%%\n', 1)
  return r
end

function line_spec(spec, a)
  local w, c = "1px", "currentColor"
  local src = (spec == "true") and (a["border"] or (a["style"] or ""):match("border:%s*([^;]+)") or "") or spec
  for tok in tostring(src):gmatch("%S+") do
    if tok:match("^[%d%.]+px$") or tok:match("^[%d%.]+$") then w = css_size(tok)
    elseif tok ~= "solid" and tok ~= "dashed" and tok ~= "dotted" then c = color_value(tok) end
  end
  return w, c
end

function box_attrs(el)
  local a, st = el.attributes, {}
  if has_class(el, "annot") then return nil end   -- its own attributes (annotation)
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
      local c = color_value(a["background"] or "black")
      st[#st + 1] = string.format("background:repeating-linear-gradient(to %s, %s 0 %spx, transparent %spx %spx)",
        vertical and "bottom" or "right", c, d, d, tonumber(d) + tonumber(g))
      a["background"], a["dash"] = nil, nil
    end
  end
  if has_class(el, "absolute") then
    take_pos(a, st)
  elseif el.t == "Span" or has_class(el, "card") or has_class(el, "sep")   -- e.g. the shapes of a .flow row
      or (has_class(el, "column") and a["height"]) then  -- (a column with a height: its width goes in the same
    take_pos(a, st, { "width", "height" })             --  style=, Quarto would otherwise add a second one)
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
  a["morph-id"] = nil   -- (used by grid_box, stack and dims, which run before)
  -- valign=top|center|bottom|spread: vertical alignment of the content (talk.scss VERTICAL ALIGNMENT)
  if a["valign"] then
    local v = a["valign"]; a["valign"] = nil
    if v == "top" or v == "center" or v == "bottom" or v == "spread" then el.classes:insert("talk-va-" .. v)
    else io.stderr:write("talk: valign=" .. v .. " (top, center, bottom or spread)\n") end
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
  if a["color"] then st[#st + 1] = "color:" .. color_value(a["color"]); a["color"] = nil end
  if a["background"] then st[#st + 1] = "background:" .. color_value(a["background"]); a["background"] = nil end
  if a["align"] then st[#st + 1] = "text-align:" .. a["align"]; a["align"] = nil end
  if a["border"] then
    -- theme names also inside a border: border="1px solid accent"
    st[#st + 1] = "border:" .. colors_in(a["border"]); a["border"] = nil
  end
  if a["radius"] then st[#st + 1] = "border-radius:" .. css_size(a["radius"]); a["radius"] = nil end
  for _, k in ipairs({ "line-height", "padding" }) do
    if a[k] then st[#st + 1] = k .. ":" .. a[k]; a[k] = nil end
  end
  if #st == 0 then return nil end
  add_style(a, table.concat(st, ";"))
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
--   morph-id    : PREFIX: every cell gets data-id PREFIX-k (a Morph of each cell: e.g. the cells
--                 of a matrix fly into the slices of a stack= box with the same morph-id)

function grid_box(d)
  local a = d.attributes
  if not (a["cols"] or a["rows"]) then return nil end
  -- a span box ([]{.absolute .box rows=6 lines=true}) gets span cells and lines
  local mk = ctor(d)
  if d.t == "Span" and not a["lines"] and not a["cells"] and not a["morph-id"] then return nil end   -- hl= alone: hl_host reads cols/rows
  local cols, rows = a["cols"] or "1", a["rows"] or "1"
  -- when the box size is known, the cell boundaries are rounded to whole pixels of its inner
  -- area (size − 2 × border): cells, highlights and lines then share exactly the same edges
  local bw = tonumber(tostring(a["border"] or (a["style"] or ""):match("border:%s*([^;]+)")
             or (has_class(d, "box") and "1px" or "")):match("([%d%.]+)px") or "0") or 0   -- (.box: talk.scss)
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
  -- cells="c1 c2 …" (backgrounds, row by row) and morph-id=PREFIX (data-id PREFIX-k): cells
  -- that do not come from a list are created empty
  local cell_bg, cell_id, ncell = {}, a["morph-id"], 0
  for c in tostring(a["cells"] or ""):gmatch("%S+") do cell_bg[#cell_bg + 1] = c end
  a["cells"] = nil
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
    if a["lines"] == "true" and not a["border"] and not (a["style"] or ""):match("border:") and has_class(d, "box") then
      w, c = "1px", "#000"                     -- the .box frame (talk.scss)
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
    if bw > 0 then add_style(a, "--hl-bw:" .. bw .. "px") end
  end
  set_content(d, out)
  return d
end
