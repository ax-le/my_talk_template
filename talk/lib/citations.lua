-- lib/citations.lua — part of talk.lua: citations: biblatex-like labels, per-slide reference lists, \fullcite, the references slide.
-- Loaded by talk.lua into one shared environment: the top-level functions and tables of every
-- part are visible to the others (no `local` at the top level; locals inside functions as usual).

-- ---------------------------------------------------------------------------- state
cite = { enabled = false, slide_refs = true, refs = nil, labels = {}, csl = nil, highlight = nil, used = {}, own = {} }

-- ---------------------------------------------------------------------------- citations
-- biblatex "alphabetic"-like labels: Foo00, MCB22, Mar+20 (+ a/b suffixes). A `shorthand`
-- field in the .bib file always wins (so labels match the ones of a LaTeX thesis).
function read_shorthands(paths)
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

function first_chars(s, n)
  local out = {}
  for _, c in utf8.codes(s) do
    out[#out + 1] = utf8.char(c)
    if #out >= n then break end
  end
  return table.concat(out)
end

function alpha_label(r)
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

function setup_citations(doc, opts)
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
entry_cache = {}
function entries_for(keys)
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

function cited_keys(blocks)
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
function render_cite(c)
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

function resolve_cites(blocks)
  return pandoc.Blocks(blocks):walk({ Cite = function(c)
    if not cite.enabled then return nil end
    return render_cite(c)
  end })
end

-- [@key]{.fullcite}  →  the full formatted entry (like biblatex \fullcite)
function fullcites(blocks)
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

-- ---------------------------------------------------------------------------- per-slide refs
slide_refs_div = function(blocks)
  local keys = cited_keys(blocks)
  if #keys == 0 then return nil end
  local e = entries_for(keys)
  if #e == 0 then return nil end
  return pandoc.Div(e, pandoc.Attr("", { "slide-refs" }))
end

-- ---------------------------------------------------------------------------- references slide
function fill_refs(blocks, doc)
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
