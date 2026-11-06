--[[
  {{< audio media/intro.mp3 >}}                         click-to-play speaker icon
  {{< audio media/intro.mp3 autoplay=true delay=0.5 >}} plays when the slide / its fragment appears
  {{< audio src=media/x.mp3 label="Verse 1" id=v1 loop=true volume=0.6 fragment=2 >}}
  {{< audio media/x.mp3 left=300 top=500 size=48 >}}    absolutely positioned (px), icon size (px)

  Arguments: src (or first positional), autoplay, delay (s), loop, volume (0-1), id,
             label, class, style, fragment (true or an index), left, top, size.
]]

local stringify = pandoc.utils.stringify

local ICON = dofile(quarto.utils.resolve_path("audio_icon.lua"))   -- same icon as talk.lua


local function get(kwargs, k)
  local v = kwargs[k]
  if v == nil then return nil end
  v = stringify(v)
  if v == "" then return nil end
  return v
end

local function px(v) if v:match("^%-?[%d%.]+$") then return v .. "px" end return v end

return {
  ["audio"] = function(args, kwargs, meta)
    local src = get(kwargs, "src") or (args[1] and stringify(args[1]))
    if not src or src == "" then return pandoc.Null() end
    if not quarto.doc.is_format("html:js") then return pandoc.Str("") end

    local cls = { "audio-btn", "talk-audio" }
    local attrs = { { "data-audio", src }, { "role", "button" }, { "tabindex", "0" }, { "title", "Play / stop" } }
    local style = {}

    local auto = get(kwargs, "autoplay")
    if auto then attrs[#attrs + 1] = { "data-autoplay", (auto == "false" or auto == "no") and "false" or "true" } end
    local delay = get(kwargs, "delay"); if delay then attrs[#attrs + 1] = { "data-autoplay-delay", delay } end
    local loop = get(kwargs, "loop"); if loop and loop ~= "false" then attrs[#attrs + 1] = { "data-loop", "" } end
    local vol = get(kwargs, "volume"); if vol then attrs[#attrs + 1] = { "data-volume", vol } end
    local id = get(kwargs, "id") or ""
    local frag = get(kwargs, "fragment")
    if frag and frag ~= "false" then
      cls[#cls + 1] = "fragment"
      if frag ~= "true" then attrs[#attrs + 1] = { "data-fragment-index", frag } end
    end
    local c = get(kwargs, "class"); if c then cls[#cls + 1] = c end
    local left, top = get(kwargs, "left"), get(kwargs, "top")
    if left or top then
      style[#style + 1] = "position:absolute"
      if left then style[#style + 1] = "left:" .. px(left) end
      if top then style[#style + 1] = "top:" .. px(top) end
    end
    -- size = size of the icon (px, or any CSS length); default: --talk-audio-size
    local size = get(kwargs, "size"); if size then style[#style + 1] = "--talk-audio-size:" .. px(size) end
    local st = get(kwargs, "style"); if st then style[#style + 1] = st end
    if #style > 0 then attrs[#attrs + 1] = { "style", table.concat(style, ";") } end
    local label = get(kwargs, "label")
    local content = { pandoc.RawInline("html", ICON) }
    if label then content[2] = pandoc.Span({ pandoc.Str(label) }, pandoc.Attr("", { "talk-audio-label" })) end
    return pandoc.Span(content, pandoc.Attr(id, cls, attrs))
  end
}
