-- lib/common.lua — part of talk.lua: helpers shared by every part of the filter (classes, sizes, style=, click steps, colours).
-- Loaded by talk.lua into one shared environment: the top-level functions and tables of every
-- part are visible to the others (no `local` at the top level; locals inside functions as usual).

stringify = pandoc.utils.stringify

function has_class(el, c)
  for _, k in ipairs(el.classes or {}) do if k == c then return true end end
  return false
end
function css_size(v)
  if tostring(v):match("^%-?[%d%.]+$") then return v .. "px" end
  return v
end
function px_number(v)
  local n = tostring(v or ""):match("^%s*([%d%.]+)%s*p?x?%s*$")
  return n and tonumber(n) or nil
end
-- the first number found in v (or in the default d): "30%" → 30, "20px" → 20
function num_in(v, d)
  return tonumber(tostring(v or d):match("[%d%.]+"))
end
function remove_class(el, ...)
  local drop, keep = {}, {}
  for _, c in ipairs({ ... }) do drop[c] = true end
  for _, c in ipairs(el.classes) do if not drop[c] then keep[#keep + 1] = c end end
  el.classes = keep
end
-- reveal.js fragment classes (the click and its effect)
function is_fragment_class(c)
  return c == "fragment" or c:match("^fade") ~= nil or c:match("^semi%-fade") ~= nil or c == "grow"
      or c == "shrink" or c == "strike" or c:match("^highlight%-") ~= nil or c == "current-visible"
end
-- the constructor of el's kind (a span box makes span children, a div box div children)
function ctor(el) return (el.t == "Span") and pandoc.Span or pandoc.Div end
function set_content(el, list)
  el.content = (el.t == "Span") and pandoc.Inlines(list) or pandoc.Blocks(list)
end
-- ONE style= per element, each CSS property in it once. add_style(a, "k:v;k2:v2") merges the
-- declarations into a["style"]: a property already there is replaced (the later pipeline stage wins,
-- i.e. the more specific attribute over a raw style=), and the replacement is reported on stderr,
-- because two writers of one property usually mean a bug. Authors write attributes, never style=.
function css_decls(st)          -- "a:b;c:url(x;y)" → { "a:b", "c:url(x;y)" } (no split inside parentheses)
  local out, cur, depth = {}, {}, 0
  for ch in tostring(st or ""):gmatch(".") do
    if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = depth - 1 end
    if ch == ";" and depth == 0 then out[#out + 1] = table.concat(cur); cur = {}
    else cur[#cur + 1] = ch end
  end
  out[#out + 1] = table.concat(cur)
  return out
end
function add_style(a, st)
  if st == nil or st == "" then return end
  local order, val = {}, {}
  local function put(decl, new)
    local k, v = decl:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
    if not k then return end
    if val[k] == nil then order[#order + 1] = k
    elseif new and val[k] ~= v then
      io.stderr:write("talk: CSS property " .. k .. " set twice (" .. val[k] .. ", then " .. v .. "): the second one is kept\n")
    end
    val[k] = v
  end
  for _, d in ipairs(css_decls(a["style"])) do put(d, false) end
  for _, d in ipairs(css_decls(st)) do put(d, true) end
  local out = {}
  for _, k in ipairs(order) do out[#out + 1] = k .. ":" .. val[k] end
  a["style"] = table.concat(out, ";")
end
-- the position / size attributes (numbers = px) moved into a list of CSS declarations
POS = { "left", "top", "right", "bottom", "width", "height" }
function take_pos(a, out, keys)
  for _, k in ipairs(keys or POS) do
    if a[k] then out[#out + 1] = k .. ":" .. css_size(a[k]); a[k] = nil end
  end
  return out
end
-- keys of a table in a fixed order (pairs() order changes between runs: the HTML would too)
function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end
-- .incremental levels=N on a div or a heading: returns N (and removes both), or nil
function take_levels(el)
  if not (has_class(el, "incremental") and el.attributes["levels"]) then return nil end
  local n = tonumber(el.attributes["levels"]) or 1
  el.attributes["levels"] = nil
  remove_class(el, "incremental")
  return n
end

-- ---------------------------------------------------------------------------- click steps, colours
-- hl="STEPS[@AREA]; …" on a div, span or image highlights the object itself (or a part of it)
-- during the given fragment steps. The highlight lives inside the object: it follows its
-- position, size and morphs, and borders stay on top.
--   STEPS : n (only at step n) | n-m | n- (from n to the end of the slide) ; 0 = before any click
--   AREA  : none (whole object) | k, k-l (cell numbers of the grid cols= / rows=, row-major)
--           | c,r with c and r = n, n-m or * (column, row) | (x,y,w,h) in % of the object, or px
function trim(x) return (x:gsub("^%s+", ""):gsub("%s+$", "")) end
function len(v)
  v = trim(v)
  if v:match("px$") or v:match("%%$") then return v end
  return v .. "%"
end
function range(v, n)
  v = trim(v)
  if v == "*" then return 1, n end
  local a, b = v:match("^(%d+)%s*%-%s*(%d+)$")
  if a then return tonumber(a), tonumber(b) end
  local k = tonumber(v); return k, k
end
function pct(x) return string.format("%.6g%%", x) end

function parse_steps(steps)
  local a, b = steps:match("^(%d+)%s*%-%s*(%d+)$")
  if not a then a = steps:match("^(%d+)%s*%-$"); if a then b = "end" end end
  if not a then a = steps:match("^(%d+)$"); b = a end
  return a and tonumber(a) or nil, b
end
-- outer element: appears at step a; inner: disappears after step b ("end": stays)
function step_attrs(a, b)
  local o_cls, o_at, i_cls, i_at = {}, {}, {}, {}
  if a and a > 0 then o_cls[#o_cls + 1] = "fragment"; o_at[#o_at + 1] = { "data-fragment-index", tostring(a) } end
  if b and b ~= "end" then
    i_cls = { "fragment", "fade-out" }; i_at = { { "data-fragment-index", tostring(tonumber(b) + 1) } }
  end
  return o_cls, o_at, i_cls, i_at
end
-- mk({ mk(content, inner) }, outer): an element shown during the clicks a..b (b = "end": to the end
-- of the slide). The step classes / attributes are appended to the given ones.
function stepped(mk, a, b, outer_cls, outer_at, inner_cls, inner_at, content)
  local o_cls, o_at, i_cls, i_at = step_attrs(a, b)
  for _, c in ipairs(o_cls) do outer_cls[#outer_cls + 1] = c end
  for _, x in ipairs(o_at) do outer_at[#outer_at + 1] = x end
  for _, c in ipairs(i_cls) do inner_cls[#inner_cls + 1] = c end
  for _, x in ipairs(i_at) do inner_at[#inner_at + 1] = x end
  return mk({ mk(content or {}, pandoc.Attr("", inner_cls, inner_at)) }, pandoc.Attr("", outer_cls, outer_at))
end

-- one colour: a name → var(--hl-NAME, NAME), so that the theme names (text title accent background
-- bar), the palette (red teal…), the deck's names (YAML talk: highlight: colors) and the CSS names all
-- work (talk.scss defines --hl-NAME for the theme and the palette); anything else ("#…", rgb(…),
-- var(…), a gradient) unchanged
function color_value(c)
  if not c:match("^%a[%w%-]*$") then return c end
  return "var(--hl-" .. c .. ", " .. c .. ")"
end
-- every colour name inside a CSS value: "2px solid accent", "1px dashed teal", "accent"
CSS_WORDS = { solid = true, dashed = true, dotted = true, double = true, groove = true, ridge = true,
  inset = true, outset = true, none = true, hidden = true, transparent = true, currentColor = true,
  currentcolor = true, inherit = true, initial = true, unset = true }
function colors_in(v)
  local out = {}
  for tok in tostring(v):gmatch("%S+") do
    out[#out + 1] = CSS_WORDS[tok] and tok or color_value(tok)
  end
  return table.concat(out, " ")
end
