-- lib/highlights.lua — part of talk.lua: highlights (hl=, \hl / \hlo in equations), annotations and edges (.annot), 3D tilt.
-- Loaded by talk.lua into one shared environment: the top-level functions and tables of every
-- part are visible to the others (no `local` at the top level; locals inside functions as usual).

-- ---------------------------------------------------------------------------- highlights
-- (the STEPS / AREA syntax: lib/common.lua, click steps)

-- grid geometry: g = { nc, nr, xs = {0, …, 100}, ys = {0, …, 100} } (cell boundaries in %)
function boundaries(spec)
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
function grid_of(cols, rows)
  local xs, ys = boundaries(cols), boundaries(rows)
  return { nc = #xs - 1, nr = #ys - 1, xs = xs, ys = ys }
end

-- a cell edge in CSS: whole pixels when the inner size of the box is known (g.iw / g.ih,
-- set by grid_box: the lines of the box are placed on the same pixels), else in %
function edge(p, size)
  if size then return string.format("%dpx", math.floor(size * p / 100 + 0.5)) end
  return pct(p)
end
function area_style(area, g)
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

function hl_regions(spec, g, inline)
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
    out[i] = stepped(mk, R.a, R.b, { "hl-region" }, { { "style", R.st }, { "data-hl", R.entry } }, { "hl-fill" }, {})
  end
  return out, cols, rows
end

function hl_host(el, inline)
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
  add_style(a, table.concat(st, ";"))
  a["hl"], a["hl-color"], a["hl-style"] = nil, nil, nil
  a["grid-cols"], a["grid-rows"], a["cols"], a["rows"] = nil, nil, nil, nil
  el.classes:insert("hl-host")
  return regions
end

function highlight_div(d)
  local regions = hl_host(d, false)
  if not regions then return nil end
  d.classes:insert("hl-under")       -- text of the box stays above the highlight
  for _, r in ipairs(regions) do d.content:insert(r) end
  return d
end
function highlight_span(s)
  if s.attributes["hl"] == nil then return nil end
  local regions = hl_host(s, true)
  s.classes:insert("hl-under")
  for _, r in ipairs(regions) do s.content:insert(r) end
  return s
end
-- an image cannot hold children: it is wrapped in a span that takes its place, position,
-- size, data-id and fragment classes (the image fills it)
function highlight_image(img)
  if img.attributes["hl"] == nil then return nil end
  local ia, wa = img.attributes, {}
  local wcls, icls = {}, { "hl-img" }
  for _, c in ipairs(img.classes) do
    if c == "absolute" or is_fragment_class(c) or c == "move" or c == "tilt-shadow" then wcls[#wcls + 1] = c
    else icls[#icls + 1] = c end
  end
  local W, H = px_number(ia["width"]), px_number(ia["height"])
  local st = take_pos(ia, {})
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
function highlight_math(m)
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
      local at = { { "data-hl", steps .. " " .. color }, { "style", "left:0;top:0;width:100%;height:100%" } }
      if items[k] then at[#at + 1] = { "data-name", items[k] } end
      out[#out + 1] = stepped(pandoc.Span, a, b, { "hl-region", "hl-math-slot" }, at, { "hl-fill" }, {})
    end
  end
  return out
end

-- ::: {.annot to="x2 kron" pos=below sub="…"}  label  :::
-- a label with arrows to named parts of equations (\hl[name], \hlo[name], \eqmark{name}{…}) or to
-- elements with that id. With from=: [label]{.annot from=a to=b} is an arrow from the edge of #a to
-- the edge of #b (graph edges), its label beside the middle of the arrow (shift= px to its left,
-- along= px further). Both are placed and drawn by talk.js from where the targets really are.
-- Clicks: the native fragment classes / fragment-index on it, moved to its wrapper (the label
-- element itself is laid out by talk.js). A div or a span.
ANNOT_DATA = { "from", "to", "pos", "dist", "shift", "along", "x", "y", "arrow", "width", "head",
                     "box", "gap", "dir", "anchor" }
function annotation(el)
  if not has_class(el, "annot") then return nil end
  local a, mk = el.attributes, ctor(el)
  local edge = a["from"] ~= nil
  local inner_at, ocls, o_at = {}, { "annot-wrap" }, {}
  for _, k in ipairs(ANNOT_DATA) do
    if a[k] then inner_at[#inner_at + 1] = { "data-" .. k, a[k] } end
  end
  local style = {}
  if a["color"] then style[#style + 1] = "--annot-c:" .. color_value(a["color"]) end
  if a["size"] then style[#style + 1] = "--annot-size:" .. css_size(a["size"]) end
  if a["sub-size"] then style[#style + 1] = "--annot-sub-size:" .. css_size(a["sub-size"]) end
  if #style > 0 then inner_at[#inner_at + 1] = { "style", table.concat(style, ";") } end
  for _, c in ipairs(el.classes) do if is_fragment_class(c) then ocls[#ocls + 1] = c end end
  for _, k in ipairs({ "fragment-index", "data-fragment-index" }) do
    if a[k] then o_at[#o_at + 1] = { k, a[k] } end
  end
  local inner
  if edge then
    inner = mk({ mk(el.content, pandoc.Attr("", { "annot-edge-label" })) }, pandoc.Attr("", { "annot", "annot-edge" }, inner_at))
  else
    local function block(x) return el.t == "Span" and x or { pandoc.Plain(x) } end
    local label = { mk(el.content, pandoc.Attr("", { "annot-label" })) }
    if a["sub"] then
      label[#label + 1] = mk(block(pandoc.read(a["sub"], "markdown").blocks[1].content), pandoc.Attr("", { "annot-sub" }))
    end
    inner = mk({ mk(label, pandoc.Attr("", { "annot-box" })) }, pandoc.Attr("", { "annot" }, inner_at))
  end
  return mk({ inner }, pandoc.Attr(el.identifier, ocls, o_at))
end

-- ---------------------------------------------------------------------------- 3D tilt
-- {rotate-x=… rotate-y=… rotate-z=… perspective=…}  : real CSS 3D rotation (any element)
-- {face=top|side depth=0.5 angle=45}                 : oblique "cube face" look, the same
--                                                       convention as the tensors drawn in PowerPoint
function tilt(el)
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
  -- Quarto's .absolute left=/top=/… would be lost once we set a style → move them into it
  local st = has_class(el, "absolute") and take_pos(a, {}) or {}
  if #st > 0 then st[#st + 1] = "position:absolute" end
  add_style(a, table.concat(st, ";"))
  add_style(a, "transform:" .. table.concat(tr, " "))
  el.classes:insert("tilt")
  return el
end
