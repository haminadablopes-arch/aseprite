--[[------------------------------------------------------------------------------
  bgcore.lua - Core of the "Smart Background Remover"

  This module is PURE: it uses no Aseprite API. It works only with byte
  strings (the same format as Aseprite's Image.bytes / Image:getPixel()),
  which allows testing and auditing it outside Aseprite (see test/ folder).

  Expected pixel format (little endian, same as Aseprite):
    bpp=4 (RGB)      : R, G, B, A
    bpp=2 (GRAY)     : V, A
    bpp=1 (INDEXED)  : palette index

  Pipeline:
    1) analyze()      -> discovers the background "model" by sampling borders
    2) computeFlags() -> classifies each frame pixel (background candidate / subject)
    3) connectivity() -> (optional) keeps only what is connected to the borders and
                         separates internal background "islands"
    4) applyMask()    -> returns the new frame bytes with the background erased

  Copyright (c) 2026 - MIT License
------------------------------------------------------------------------------]]

local M = { version = "0.4.0" }

local byte, sub, rep, gsub, gmatch, format =
      string.byte, string.sub, string.rep, string.gsub, string.gmatch, string.format
local concat, sort, insert = table.concat, table.sort, table.insert
local floor, ceil, max, min, sqrt, abs, huge =
      math.floor, math.ceil, math.max, math.min, math.sqrt, math.abs, math.huge
local clock = os.clock

--------------------------------------------------------------------------------
-- Default options
--------------------------------------------------------------------------------

local function defaultOpts(o)
  o = o or {}
  local sides = {}
  if o.sides then
    for k, v in pairs(o.sides) do sides[k] = v end
  else
    sides = { top = true, bottom = true, left = true, right = true }
  end
  return {
    mode           = o.mode or "auto",   -- auto | flat | set | tile | gradient | flood
    tolerance      = o.tolerance or 24,  -- RGBA euclidean distance (0..255)
    contiguous     = (o.contiguous == nil) and true or o.contiguous,
    removeIslands  = o.removeIslands or false,
    sample         = o.sample or 6,      -- thickness of the sampled border band
    sides          = sides,
    soft           = o.soft or 0,        -- edge softening radius (0 = off)
    maxColors      = o.maxColors or 12,
    maxRuns        = o.maxRuns or 400000,
    minShare       = o.minShare or 0.004,
    tileScore      = o.tileScore or 0.55,
  }
end
M.defaultOpts = defaultOpts

--------------------------------------------------------------------------------
-- Colors
--------------------------------------------------------------------------------

-- Extrai r,g,b,a de uma "chave" (pixel cru de bpp bytes).
local function unpackKey(key, bpp, pal)
  if bpp == 4 then
    return byte(key, 1, 4)
  elseif bpp == 2 then
    local v, a = byte(key, 1, 2)
    return v, v, v, a
  else
    local i = byte(key, 1) or 0
    local c = pal and pal[i]
    if c then return c[1], c[2], c[3], c[4] end
    return i, i, i, 255
  end
end
M.unpackKey = unpackKey

local function dist2(r1, g1, b1, a1, r2, g2, b2, a2)
  local dr, dg, db, da = r1 - r2, g1 - g2, b1 - b2, a1 - a2
  return dr * dr + dg * dg + db * db + da * da
end
M.dist2 = dist2

local function keyToHex(key, bpp, pal)
  local r, g, b, a = unpackKey(key, bpp, pal)
  if bpp == 1 then
    return format("#%d(idx=%d a=%d)", r, byte(key, 1) or 0, a)
  end
  return format("#%02X%02X%02X a=%d", r, g, b, a)
end
M.keyToHex = keyToHex

--------------------------------------------------------------------------------
-- Border sampling
--------------------------------------------------------------------------------

-- Returns, for each row y (0-based), the [x1,x2] ranges (0-based, inclusive)
-- that belong to the sampled border.
local function borderRanges(w, h, sample, sides)
  local ranges = {}
  for y = 0, h - 1 do
    local list
    local topBand    = sides.top    and (y < sample)
    local bottomBand = sides.bottom and (y >= h - sample)
    if topBand or bottomBand then
      list = { { 0, w - 1 } }
    else
      list = {}
      if sides.left  then list[#list + 1] = { 0, min(sample - 1, w - 1) } end
      if sides.right then
        local x1 = max(0, w - sample)
        if #list > 0 and list[#list][2] >= x1 then
          list[#list][2] = w - 1
        else
          list[#list + 1] = { x1, w - 1 }
        end
      end
    end
    ranges[y] = list
  end
  return ranges
end

-- Counts border colors. Returns a histogram (key->count) and the total.
local function histogram(bytes, ctx, ranges, bpp, width, stride)
  local hist, total = {}, 0
  for y = 0, ctx.h - 1 do
    local list = ranges[y]
    if list and #list > 0 then
      local row = sub(bytes, y * stride + 1, y * stride + width * bpp)
      for i = 1, #list do
        local x1, x2 = list[i][1], list[i][2]
        if x2 >= x1 then
          local seg = sub(row, x1 * bpp + 1, (x2 + 1) * bpp)
          for key in gmatch(seg, rep(".", bpp)) do
            local c = hist[key]
            if c then hist[key] = c + 1 else hist[key] = 1 end
            total = total + 1
          end
        end
      end
    end
  end
  return hist, total
end

--------------------------------------------------------------------------------
-- Gradient fit (least squares, normalized u,v coords in [0,1])
--------------------------------------------------------------------------------

local function solve3(m, rhs)
  -- m: matriz 3x3 (tabela de linhas), rhs: vetor 3
  local a = {
    { m[1][1], m[1][2], m[1][3], rhs[1] },
    { m[2][1], m[2][2], m[2][3], rhs[2] },
    { m[3][1], m[3][2], m[3][3], rhs[3] },
  }
  for col = 1, 3 do
    -- pivot
    local piv, pivr = abs(a[col][col]), col
    for r = col + 1, 3 do
      if abs(a[r][col]) > piv then piv, pivr = abs(a[r][col]), r end
    end
    if piv < 1e-12 then return nil end
    a[col], a[pivr] = a[pivr], a[col]
    local p = a[col]
    for r = 1, 3 do
      if r ~= col then
        local f = a[r][col] / p[col]
        if f ~= 0 then
          for c = col, 4 do a[r][c] = a[r][c] - f * p[c] end
        end
      end
    end
  end
  return { a[1][4] / a[1][1], a[2][4] / a[2][2], a[3][4] / a[3][3] }
end

--------------------------------------------------------------------------------
-- Tile pattern detection (checker, stripes, periodic weaves)
--------------------------------------------------------------------------------

local TILE_SIZES = { { 1, 1 }, { 2, 1 }, { 1, 2 }, { 2, 2 }, { 4, 4 }, { 8, 8 }, { 16, 16 } }

-- For each phase (x%P, y%Q) finds the modal color on the border.
-- Returns (score, map) where score is the fraction of border pixels that match
-- exactly the color predicted by the tile.
local function evalTile(bytes, ctx, ranges, P, Q, bpp, width, stride)
  local acc, total = {}, 0
  local function phase(x, y) return ((y % Q) * P + (x % P)) end

  for y = 0, ctx.h - 1 do
    local list = ranges[y]
    if list and #list > 0 then
      local row = sub(bytes, y * stride + 1, y * stride + width * bpp)
      for i = 1, #list do
        for x = list[i][1], list[i][2] do
          local key = sub(row, x * bpp + 1, x * bpp + bpp)
          local ph = phase(x, y)
          local bucket = acc[ph]
          if not bucket then bucket = {}; acc[ph] = bucket end
          bucket[key] = (bucket[key] or 0) + 1
          total = total + 1
        end
      end
    end
  end
  if total == 0 then return 0, nil end

  local map, hit, missing = {}, 0, false
  for ph = 0, P * Q - 1 do
    local bucket = acc[ph]
    if not bucket then missing = true; break end
    local bestKey, bestCount = nil, -1
    for k, c in pairs(bucket) do
      if c > bestCount then bestKey, bestCount = k, c end
    end
    if not bestKey or bestCount < 2 then missing = true; break end
    map[ph] = bestKey
    hit = hit + bestCount
  end
  if missing then return 0, nil end
  return hit / total, map
end

--------------------------------------------------------------------------------
-- analyze(): discovers the background model
--------------------------------------------------------------------------------

function M.analyze(bytes, ctx, opts)
  opts = defaultOpts(opts)
  local w, h, bpp, stride, pal = ctx.w, ctx.h, ctx.bpp, ctx.stride, ctx.palette
  local t0 = clock()

  local sample = max(1, min(floor(opts.sample or 6), floor(min(w, h) / 2)))
  local ranges = borderRanges(w, h, sample, opts.sides)
  local hist, total = histogram(bytes, ctx, ranges, bpp, w, stride)

  local model = {
    type = "unknown",
    colors = {},
    sample = sample,
    borderPixels = total,
    confidence = 0,
    description = "",
    elapsed = 0,
  }

  if total == 0 then
    model.type = "empty"
    model.description = "No border pixels available for sampling."
    model.elapsed = clock() - t0
    return model
  end

  -- color list sorted by frequency
  local list = {}
  for k, c in pairs(hist) do list[#list + 1] = { key = k, count = c } end
  sort(list, function(a, b) return a.count > b.count end)

  -- transparency stats on the border
  local alphaZero = 0
  for i = 1, #list do
    local _, _, _, a = unpackKey(list[i].key, bpp, pal)
    if a == 0 then alphaZero = alphaZero + list[i].count end
  end
  model.borderAlphaZero = alphaZero / total

  local topColors = {}
  local acc = 0
  for i = 1, min(#list, opts.maxColors) do
    local c = list[i]
    local share = c.count / total
    if share < opts.minShare and i > 1 then break end
    local r, g, b, a = unpackKey(c.key, bpp, pal)
    topColors[#topColors + 1] = {
      key = c.key, count = c.count, share = share,
      r = r, g = g, b = b, a = a,
      hex = keyToHex(c.key, bpp, pal),
    }
    acc = acc + share
  end
  model.colors = topColors
  model.topShare = (topColors[1] and topColors[1].share) or 0
  model.distinctColors = #list

  if model.borderAlphaZero and model.borderAlphaZero > 0.9 then
    model.type = "transparent"
    model.confidence = model.borderAlphaZero
    model.description = format("Border is already transparent (%.1f%% of pixels). Nothing to remove.",
                               model.borderAlphaZero * 100)
    model.elapsed = clock() - t0
    return model
  end

  local mode = opts.mode
  local tol = opts.tolerance

  -- 1) Flat background ---------------------------------------------------------
  if mode == "auto" or mode == "flat" then
    if model.topShare >= 0.80 then
      model.type = "flat"
      model.confidence = model.topShare
      model.description = format("Flat background detected: color %s (%.1f%% of the border).",
                                 topColors[1].hex, model.topShare * 100)
      model.elapsed = clock() - t0
      return model
    end
    if mode == "flat" then
      model.type = "flat"
      model.confidence = model.topShare
      model.description = format("Forced 'solid color' mode: %s (%.1f%% of the border).",
                                 topColors[1].hex, model.topShare * 100)
      model.elapsed = clock() - t0
      return model
    end
  end

  -- 2) Tile pattern (checker / stripes / weave) --------------------------------
  if mode == "auto" or mode == "tile" then
    local best = nil
    for _, ts in ipairs(TILE_SIZES) do
      local P, Q = ts[1], ts[2]
      if P <= w and Q <= h then
        local score, map = evalTile(bytes, ctx, ranges, P, Q, bpp, w, stride)
        if score >= opts.tileScore and (not best or score > best.score + 0.02
                                        or (P * Q < best.P * best.Q and score >= best.score)) then
          if not best or (P * Q < best.P * best.Q and score >= best.score - 0.05)
             or (score > best.score + 0.05) then
            best = { P = P, Q = Q, score = score, map = map }
          end
        end
      end
    end
    if best then
      model.type = "tile"
      model.tileP, model.tileQ = best.P, best.Q
      model.tileMap = best.map
      model.confidence = best.score
      local ncolors = {}
      do
        local seen = {}
        for ph = 0, best.P * best.Q - 1 do
          local k = best.map[ph]
          if k and not seen[k] then
            seen[k] = true
            ncolors[#ncolors + 1] = keyToHex(k, bpp, pal)
          end
        end
      end
      model.tileColors = ncolors
      if best.P == 1 and best.Q == 1 then
        model.description = format("Single-color background (1x1 tile, %.0f%% match): %s.",
                                   best.score * 100, ncolors[1] or "?")
      else
        model.description = format(
          "Repeating pattern detected: %dx%d tile (%.0f%% border match), %d color(s): %s.",
          best.P, best.Q, best.score * 100, #ncolors, concat(ncolors, ", "))
      end
      model.elapsed = clock() - t0
      return model
    end
    if mode == "tile" then
      model.type = "tile"
      model.tileP, model.tileQ = 1, 1
      model.tileMap = { [0] = topColors[1].key }
      model.confidence = model.topShare
      model.description = format("No reliable periodic tile; using dominant color %s.",
                                 topColors[1].hex)
      model.elapsed = clock() - t0
      return model
    end
  end

  -- 3) Gradiente -----------------------------------------------------------------
  if mode == "auto" or mode == "gradient" then
    local n, Su, Sv, Suu, Suv, Svv = 0, 0, 0, 0, 0, 0
    local Sr, Sg, Sb, Sa = 0, 0, 0, 0
    local Sur, Sug, Sub, Sua = 0, 0, 0, 0
    local Svr, Svg, Svb, Sva = 0, 0, 0, 0
    local iw, ih = 1 / max(1, w - 1), 1 / max(1, h - 1)
    for y = 0, h - 1 do
      local list = ranges[y]
      if list and #list > 0 then
        local row = sub(bytes, y * stride + 1, y * stride + w * bpp)
        local v = y * ih
        for i = 1, #list do
          for x = list[i][1], list[i][2] do
            local key = sub(row, x * bpp + 1, x * bpp + bpp)
            local r, g, b, a = unpackKey(key, bpp, pal)
            if a > 0 then
              local u = x * iw
              n = n + 1
              Su = Su + u; Sv = Sv + v
              Suu = Suu + u * u; Suv = Suv + u * v; Svv = Svv + v * v
              Sr = Sr + r; Sg = Sg + g; Sb = Sb + b; Sa = Sa + a
              Sur = Sur + u * r; Sug = Sug + u * g; Sub = Sub + u * b; Sua = Sua + u * a
              Svr = Svr + v * r; Svg = Svg + v * g; Svb = Svb + v * b; Sva = Sva + v * a
            end
          end
        end
      end
    end
    if n > 32 then
      local A = { { n, Su, Sv }, { Su, Suu, Suv }, { Sv, Suv, Svv } }
      local cr = solve3(A, { Sr, Sur, Svr })
      local cg = solve3(A, { Sg, Sug, Svg })
      local cb = solve3(A, { Sb, Sub, Svb })
      local ca = solve3(A, { Sa, Sua, Sva })
      if cr and cg and cb and ca then
        -- residual error
        local se, cnt = 0, 0
        for y = 0, h - 1 do
          local list = ranges[y]
          if list and #list > 0 then
            local row = sub(bytes, y * stride + 1, y * stride + w * bpp)
            local v = y * ih
            for i = 1, #list do
              for x = list[i][1], list[i][2] do
                local key = sub(row, x * bpp + 1, x * bpp + bpp)
                local r, g, b, a = unpackKey(key, bpp, pal)
                if a > 0 then
                  local u = x * iw
                  local pr = cr[1] + cr[2] * u + cr[3] * v
                  local pg = cg[1] + cg[2] * u + cg[3] * v
                  local pb = cb[1] + cb[2] * u + cb[3] * v
                  local pa = ca[1] + ca[2] * u + ca[3] * v
                  se = se + dist2(r, g, b, a, pr, pg, pb, pa)
                  cnt = cnt + 1
                end
              end
            end
          end
        end
        local rms = sqrt(se / max(1, cnt)) / 2  -- average per channel (approx. RGBA/2)
        local span = (abs(cr[2]) + abs(cr[3]) + abs(cg[2]) + abs(cg[3])
                      + abs(cb[2]) + abs(cb[3])) / 6
        model.gradientRms = rms
        model.gradientSpan = span
        if mode == "gradient" or (rms <= max(3, tol * 0.75) and span >= 2) then
          model.type = "gradient"
          model.grad = { r = cr, g = cg, b = cb, a = ca }
          model.confidence = max(0, 1 - rms / max(1, tol))
          model.description = format(
            "Gradient detected: average variation %.0f per channel, residual error %.1f, %d color(s) on the border.",
            span, rms, #topColors)
          model.elapsed = clock() - t0
          return model
        end
      end
    end
  end

  -- 4) Fallback: color set + flood -----------------------------------------------
  model.type = "set"
  model.confidence = acc
  if mode == "flood" then
    model.description = format(
      "Forced flood mode: %d border color(s) (%s), covering %.0f%% of the border.",
      #topColors, concat((function()
        local t = {}
        for i = 1, min(4, #topColors) do t[i] = topColors[i].hex end
        return t
      end)(), ", "), acc * 100)
  else
    model.description = format(
      "Complex background/no clear pattern: %d main color(s) (%s), covering %.0f%% of the border. " ..
      "Color-set matching will be used.",
      #topColors, concat((function()
        local t = {}
        for i = 1, min(4, #topColors) do t[i] = topColors[i].hex end
        return t
      end)(), ", "), acc * 100)
  end
  model.elapsed = clock() - t0
  return model
end

--------------------------------------------------------------------------------
-- LUTs lazily computadas
--------------------------------------------------------------------------------

-- Creates a table whose values are computed on demand (memoization).
local function lazyTable(fn)
  return setmetatable({}, {
    __index = function(t, k)
      local v = fn(k)
      t[k] = v
      return v
    end
  })
end

--------------------------------------------------------------------------------
-- computeFlags(): classifies each pixel
--   '1' = background candidate
--   'S' = soft edge pixel (not erased, but may get reduced alpha)
--   '0' = sujeito (mantido)
--------------------------------------------------------------------------------

function M.computeFlags(bytes, ctx, model, opts)
  opts = defaultOpts(opts)
  local w, h, bpp, stride, pal = ctx.w, ctx.h, ctx.bpp, ctx.stride, ctx.palette
  local tol = opts.tolerance
  local tol2 = tol * tol
  local soft = opts.soft or 0
  local softTol = max(soft, 0)
  local softTol2 = (softTol * softTol)
  local useSoft = softTol > tol

  local pattern1 = "(" .. rep(".", bpp) .. ")"
  local flags = {}

  -- distance LUT (for edge softening), shared
  local distLut = nil
  local function makeDistFn(colorList)
    return function(key)
      local r, g, b, a = unpackKey(key, bpp, pal)
      if a == 0 then return 0 end
      local best = huge
      for i = 1, #colorList do
        local c = colorList[i]
        local d = dist2(r, g, b, a, c.r, c.g, c.b, c.a)
        if d < best then best = d end
      end
      return best
    end
  end

  --------------------------------------------------------------------------------
  -- Case A: fixed colors (flat / set) - a single LUT for the whole frame
  --------------------------------------------------------------------------------
  local function buildSetLUT(colorList, extraDist)
    local lut
    lut = lazyTable(function(key)
      local r, g, b, a = unpackKey(key, bpp, pal)
      if a == 0 then return "1" end
      local best = huge
      for i = 1, #colorList do
        local c = colorList[i]
        local d = dist2(r, g, b, a, c.r, c.g, c.b, c.a)
        if d < best then best = d end
      end
      if extraDist then extraDist[key] = best end
      if best <= tol2 then return "1" end
      if useSoft and best <= softTol2 then return "S" end
      return "0"
    end)
    return lut
  end

  local mode = model.type
  local extraDist = useSoft and lazyTable(makeDistFn(model.colors)) or nil

  local t0 = clock()

  if mode == "tile" and model.tileP and model.tileQ then
    --------------------------------------------------------------------------------
    -- Tile: each row uses P LUTs (one per x phase)
    --------------------------------------------------------------------------------
    local P, Q = model.tileP, model.tileQ
    if P == 1 and Q == 1 then
      local c0 = model.tileMap and model.tileMap[0]
      local colors = model.colors
      if c0 then
        local r, g, b, a = unpackKey(c0, bpp, pal)
        colors = { { r = r, g = g, b = b, a = a } }
      end
      local lut = buildSetLUT(colors, extraDist)
      for y = 0, h - 1 do
        local row = sub(bytes, y * stride + 1, y * stride + w * bpp)
        flags[y + 1] = gsub(row, pattern1, lut)
      end
    else
      local lutsByPhase = {}
      local function phaseLUT(ph)
        local l = lutsByPhase[ph]
        if not l then
          local k = model.tileMap and model.tileMap[ph]
          local colors = model.colors
          if k then
            local r, g, b, a = unpackKey(k, bpp, pal)
            colors = { { r = r, g = g, b = b, a = a } }
          end
          l = buildSetLUT(colors, extraDist)
          lutsByPhase[ph] = l
        end
        return l
      end

      -- generates the pattern and the group function for P pixels at a time
      local groupPattern = rep(pattern1, P)
      local names, rets = {}, {}
      for i = 1, P do names[i] = "k" .. i end
      for i = 1, P do rets[i] = "L" .. i .. "[k" .. i .. "]" end
      local localDecls = {}
      for i = 1, P do localDecls[i] = "L" .. i end
      local src = "local " .. concat(localDecls, ",") .. " = ...\n" ..
                  "return function(" .. concat(names, ",") .. ")\n" ..
                  "  return " .. concat(rets, " .. ") .. "\nend"
      local factory = assert(load(src))
      local tailPattern = pattern1

      for y = 0, h - 1 do
        local row = sub(bytes, y * stride + 1, y * stride + w * bpp)
        local py = (y % Q) * P
        local ls = {}
        for i = 1, P do ls[i] = phaseLUT(py + (i - 1)) end
        local unp = table.unpack or unpack
        local fn = factory(unp(ls, 1, P))
        local usable = floor(w / P) * P
        local out
        if usable > 0 then
          out = gsub(sub(row, 1, usable * bpp), groupPattern, fn)
        else
          out = ""
        end
        if usable < w then
          out = out .. gsub(sub(row, usable * bpp + 1), tailPattern, ls[1])
        end
        flags[y + 1] = out
      end
    end

  elseif mode == "gradient" and model.grad then
    --------------------------------------------------------------------------------
    -- Gradient: the prediction depends on (x,y), computed per pixel
    --------------------------------------------------------------------------------
    local gr, gg, gb, ga = model.grad.r, model.grad.g, model.grad.b, model.grad.a
    local iw, ih = 1 / max(1, w - 1), 1 / max(1, h - 1)
    for y = 0, h - 1 do
      local row = sub(bytes, y * stride + 1, y * stride + w * bpp)
      local v = y * ih
      local br, bg2, bb, ba = gr[1] + gr[3] * v, gg[1] + gg[3] * v,
                              gb[1] + gb[3] * v, ga[1] + ga[3] * v
      local ar, ag, ab, aa = gr[2], gg[2], gb[2], ga[2]   -- u is already normalized
      local x = 0
      flags[y + 1] = gsub(row, pattern1, function(key)
        local r, g, b, a = unpackKey(key, bpp, pal)
        local u = x * iw
        x = x + 1
        if a == 0 then return "1" end
        local d = dist2(r, g, b, a, br + ar * u, bg2 + ag * u, bb + ab * u, ba + aa * u)
        if d <= tol2 then return "1" end
        if useSoft and d <= softTol2 then return "S" end
        return "0"
      end)
    end

  else
    --------------------------------------------------------------------------------
    -- Flat / set / unknown: single LUT
    --------------------------------------------------------------------------------
    local colors = model.colors
    if #colors == 0 then
      for y = 0, h - 1 do flags[y + 1] = rep("0", w) end
      return flags, { elapsed = clock() - t0 }
    end
    local lut = buildSetLUT(colors, extraDist)
    for y = 0, h - 1 do
      local row = sub(bytes, y * stride + 1, y * stride + w * bpp)
      flags[y + 1] = gsub(row, pattern1, lut)
    end
  end

  return flags, { elapsed = clock() - t0, distLut = extraDist }
end

--------------------------------------------------------------------------------
-- connectivity(): connected components of the candidates (4-connectivity)
--   Devolve, por linha, a lista de spans {x1,x2,remove} (0-based, inclusivo)
--   or nil if the number of spans exceeds the limit (caller falls back to global mode).
--------------------------------------------------------------------------------

function M.connectivity(flags, w, h, opts)
  opts = defaultOpts(opts)
  local t0 = clock()
  local rowRuns, nRuns = {}, 0
  local runX1, runX2, runRow = {}, {}, {}
  local rowStart = {}

  for y = 1, h do
    rowStart[y] = nRuns + 1
    local list = flags[y]
    if list then
      for s, e in gmatch(list, "()1+()") do
        nRuns = nRuns + 1
        runX1[nRuns] = s - 1      -- 0-based
        runX2[nRuns] = e - 2      -- 0-based inclusivo
        runRow[nRuns] = y
      end
    end
    rowRuns[y] = nRuns
  end

  if nRuns == 0 then
    return { spansByRow = {}, nRuns = 0, elapsed = clock() - t0 }
  end

  if nRuns > opts.maxRuns then
    return nil, nRuns
  end

  -- union-find
  local parent, touch = {}, {}
  for i = 1, nRuns do
    parent[i] = i
    local y = runRow[i]
    touch[i] = (runX1[i] == 0) or (runX2[i] == w - 1) or (y == 1) or (y == h)
  end
  local function find(i)
    local r = i
    while parent[r] ~= r do r = parent[r] end
    while parent[i] ~= r do
      local p = parent[i]
      parent[i] = r
      i = p
    end
    return r
  end
  local function union(a, b)
    local ra, rb = find(a), find(b)
    if ra ~= rb then
      parent[rb] = ra
      touch[ra] = touch[ra] or touch[rb]
    end
  end

  -- links spans of adjacent rows that overlap
  for y = 2, h do
    local a1, a2 = rowStart[y - 1], rowRuns[y - 1]
    local b1, b2 = rowStart[y], rowRuns[y]
    local i, j = a1, b1
    while i <= a2 and j <= b2 do
      if runX2[i] < runX1[j] then
        i = i + 1
      elseif runX2[j] < runX1[i] then
        j = j + 1
      else
        union(i, j)
        if runX2[i] < runX2[j] then i = i + 1 else j = j + 1 end
      end
    end
  end

  -- decides what to remove
  local contiguous = opts.contiguous
  local removeIslands = opts.removeIslands
  local spansByRow = {}
  for y = 1, h do
    spansByRow[y] = {}
  end
  local removed = 0
  for i = 1, nRuns do
    local id = find(i)
    local doRemove
    if not contiguous then
      doRemove = true
    else
      doRemove = touch[id] or removeIslands
    end
    if doRemove then
      local y = runRow[i]
      local t = spansByRow[y]
      t[#t + 1] = { runX1[i], runX2[i] }
      removed = removed + (runX2[i] - runX1[i] + 1)
    end
  end

  return {
    spansByRow = spansByRow,
    nRuns = nRuns,
    removed = removed,
    elapsed = clock() - t0,
  }, nRuns
end

--------------------------------------------------------------------------------
-- applyMask(): escreve o resultado
--------------------------------------------------------------------------------

function M.applyMask(bytes, ctx, spansByRow, opts, flags, distLut)
  opts = defaultOpts(opts)
  local w, h, bpp, stride, pal = ctx.w, ctx.h, ctx.bpp, ctx.stride, ctx.palette
  local transp = ctx.transparentKey or rep("\0", bpp)
  local soft = opts.soft or 0
  local tol = opts.tolerance
  local softTol = max(soft, tol)
  local useSoft = soft > tol

  local out = {}
  local removed = 0
  local softened = 0

  -- For softening we need to know, per row, which spans were removed
  local function isRemovedNear(y, x)
    local t = spansByRow[y]
    if not t then return false end
    for i = 1, #t do
      local s = t[i]
      if x >= s[1] - 1 and x <= s[2] + 1 then return true end
    end
    return false
  end

  for y = 1, h do
    local base = (y - 1) * stride
    local row = sub(bytes, base + 1, base + w * bpp)
    local pad = ""
    if stride > w * bpp then pad = sub(bytes, base + w * bpp + 1, base + stride) end
    local spans = spansByRow[y]
    local pieces, last = nil, 0

    if spans and #spans > 0 then
      pieces = {}
      for i = 1, #spans do
        local x1, x2 = spans[i][1], spans[i][2]
        local a, b = x1 * bpp, (x2 + 1) * bpp
        if a > last then pieces[#pieces + 1] = sub(row, last + 1, a) end
        pieces[#pieces + 1] = rep(transp, x2 - x1 + 1)
        last = b
        removed = removed + (x2 - x1 + 1)
      end
      if last < #row then pieces[#pieces + 1] = sub(row, last + 1) end
      row = concat(pieces)
    end

    -- edge softening (alpha proportional to the model distance)
    if useSoft and flags and distLut and flags[y] then
      local patches, np = nil, 0
      for s, e in gmatch(flags[y], "()S+()") do
        for x = s - 1, e - 2 do
          if isRemovedNear(y, x) then
            local key = sub(row, x * bpp + 1, x * bpp + bpp)
            local d = distLut[key]
            if d then
              d = sqrt(d)
              if d > tol and d < softTol then
                local f = (d - tol) / (softTol - tol)
                local r, g, b, a = unpackKey(key, bpp, pal)
                local na = floor(a * f + 0.5)
                if na < a then
                  local nb
                  if bpp == 4 then
                    nb = string.char(r, g, b, na)
                  elseif bpp == 2 then
                    nb = string.char(r, na)
                  else
                    nb = key  -- indexed: doesn't touch per-pixel alpha
                  end
                  if nb ~= key then
                    if not patches then patches = {} end
                    np = np + 1
                    patches[np] = { x, nb }
                  end
                end
              end
            end
          end
        end
      end
      if np > 0 then
        local pieces2, last2 = {}, 0
        for i = 1, np do
          local x, nb = patches[i][1], patches[i][2]
          local a = x * bpp
          if a > last2 then pieces2[#pieces2 + 1] = sub(row, last2 + 1, a) end
          pieces2[#pieces2 + 1] = nb
          last2 = a + bpp
        end
        if last2 < #row then pieces2[#pieces2 + 1] = sub(row, last2 + 1) end
        row = concat(pieces2)
        softened = softened + np
      end
    end

    out[y] = row .. pad
  end

  return concat(out), { removed = removed, softened = softened }
end

--------------------------------------------------------------------------------
-- process(): pipeline completo de um frame
--------------------------------------------------------------------------------

-- Reorganiza os bytes de um stride para outro (usado quando a nova imagem
-- criada pelo script tem um rowStride diferente do original).
function M.restride(bytes, ctx, outStride)
  local w, h, bpp, stride = ctx.w, ctx.h, ctx.bpp, ctx.stride
  if stride == outStride then return bytes end
  local used = w * bpp
  local out = {}
  for y = 0, h - 1 do
    local row = sub(bytes, y * stride + 1, y * stride + used)
    if outStride > used then
      out[y + 1] = row .. rep("\0", outStride - used)
    else
      out[y + 1] = row
    end
  end
  return concat(out)
end

function M.processWithModel(bytes, ctx, model, opts)
  opts = defaultOpts(opts)
  local t0 = clock()
  local report = { ok = true, warnings = {} }

  report.model = model
  report.modelType = model.type
  report.description = model.description
  report.confidence = model.confidence

  if model.type == "empty" then
    report.ok = false
    report.reason = "Empty frame."
    report.removed = 0
    report.total = ctx.w * ctx.h
    report.percent = 0
    report.elapsed = clock() - t0
    return bytes, report
  end

  if model.type == "transparent" then
    report.ok = false
    report.reason = "Background already transparent."
    report.removed = 0
    report.total = ctx.w * ctx.h
    report.percent = 0
    report.elapsed = clock() - t0
    return bytes, report
  end

  local flags, finfo = M.computeFlags(bytes, ctx, model, opts)
  report.flagsElapsed = finfo.elapsed

  local needsConnectivity = (opts.contiguous or opts.removeIslands)
  local spansByRow = nil
  if needsConnectivity then
    local conn, nRuns = M.connectivity(flags, ctx.w, ctx.h, opts)
    if conn then
      spansByRow = conn.spansByRow
      report.nRuns = conn.nRuns
      report.connectivityElapsed = conn.elapsed
    else
      -- too many spans: falls back to global mode (all candidates are background)
      report.warnings[#report.warnings + 1] = format(
        "Too many background segments (%d > %d): connectivity disabled on this frame, " ..
        "using global matching from the detected pattern.", nRuns or 0, opts.maxRuns)
      spansByRow = nil
    end
  end

  if not needsConnectivity or (needsConnectivity and not spansByRow) then
    -- modo global: cada pixel candidato vira um span de 1 pixel
    spansByRow = {}
    local removed = 0
    for y = 1, ctx.h do
      local list = {}
      for s, e in gmatch(flags[y] or "", "()1+()") do
        list[#list + 1] = { s - 1, e - 2 }
        removed = removed + (e - s)
      end
      spansByRow[y] = list
    end
    report.removed = removed
  end

  local newBytes, stats = M.applyMask(bytes, ctx, spansByRow, opts, flags, finfo.distLut)
  report.removed = stats.removed
  report.softened = stats.softened
  report.total = ctx.w * ctx.h
  report.percent = (report.total > 0) and (report.removed / report.total * 100) or 0
  report.elapsed = clock() - t0
  return newBytes, report
end

--------------------------------------------------------------------------------
-- process(): pipeline completo de um frame (analisa + aplica)
--------------------------------------------------------------------------------

function M.process(bytes, ctx, opts)
  opts = defaultOpts(opts)
  local model = M.analyze(bytes, ctx, opts)
  return M.processWithModel(bytes, ctx, model, opts)
end

return M
