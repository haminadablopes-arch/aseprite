-- ai2pixel.lua — Extensão nativa do Aseprite: metodologia Grade-Nativa
-- Converte o sprite ATIVO (pseudo pixel art de IA, em alta resolução) em um
-- novo sprite de pixel art autêntico 1:1, com paleta recuperada (Indexed).
--
-- Instalação: Editar > Preferências > Extensões > Adicionar Extensão…
--             (selecione o arquivo .aseprite-extension / .zip)
-- Uso:        File > Scripts > ai2pixel — Grade-Nativa
--             (abra antes a sequência de frames: File > Open no frame_00.png
--              e aceite "carregar sequência", ou abra a arte única)
--
-- Pipeline (espelho fiel de pipeline/ai2pixel.py e studio/pipeline.js):
--   1 chroma-key+despill  2 grade (picos+RANSAC+regressão+refino fino)
--   3 reamostragem nativa (mediana no miolo)  4 paleta exata/k-means OKLab
--   5 snap + órfãos  6 sprite Indexed + exports opcionais

local pc = app.pixelColor

-- ---------------------------------------------------------------- utilidades
local function packRGBA(r, g, b, a) return ((a * 256 + b) * 256 + g) * 256 + r end
local function pR(c) return c % 256 end
local function pG(c) return math.floor(c / 256) % 256 end
local function pB(c) return math.floor(c / 65536) % 256 end
local function pA(c) return math.floor(c / 16777216) % 256 end

-- sRGB -> OKLab (Ottosson 2020)
local function s2l(c) c = c / 255 if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
local function l2s(c) if c <= 0 then return 0 end if c >= 1 then return 255 end
  local v = c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
  return math.floor(v * 255 + 0.5) end
local function oklab(r, g, b)
  local R, G, B = s2l(r), s2l(g), s2l(b)
  local l = 0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B
  local m = 0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B
  local s = 0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B
  l, m, s = l ^ (1 / 3), m ^ (1 / 3), s ^ (1 / 3)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
         1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
         0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end
local function oklabToRgb(L, a, b)
  local l_ = L + 0.3963377774 * a + 0.2158037573 * b
  local m_ = L - 0.1055613458 * a - 0.0638541728 * b
  local s_ = L - 0.0894841775 * a - 1.2914855480 * b
  local l, m, s = l_ ^ 3, m_ ^ 3, s_ ^ 3
  return l2s(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
         l2s(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
         l2s(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
end

-- ------------------------------------------------- leitura do sprite ativo
local function readFrame(spr, frame, pal)
  -- NOTE: nesta build do Aseprite o Frame NÃO expõe .cels. Caminhamos as
  -- camadas de baixo para cima (em grupos, Layer.cels já traz os descendentes)
  -- e pegamos o primeiro cel DO FRAME com imagem. A lista layer.cels é
  -- esparsa (só cels existentes, em ordem de frame) → casar por frameNumber.
  local fn = frame.frameNumber
  local cel
  for _, layer in ipairs(spr.layers) do
    for _, c in ipairs(layer.cels) do
      if c.frameNumber == fn then
        if c.image then cel = c end
        break -- no máximo 1 cel por (camada, frame)
      end
    end
    if cel then break end
  end
  if not cel then return nil end
  local img = cel.image
  local w, h = img.width, img.height
  local mode = spr.colorMode
  local px = {}
  for y = 0, h - 1 do
    local row = y * w
    for x = 0, w - 1 do
      local c = img:getPixel(x, y)
      local r, g, b, a
      if mode == ColorMode.RGB then
        r, g, b, a = pc.rgbaR(c), pc.rgbaG(c), pc.rgbaB(c), pc.rgbaA(c)
      elseif mode == ColorMode.INDEXED then
        if c == spr.transparentColor then r, g, b, a = 0, 0, 0, 0
        else local col = pal:getColor(c) r, g, b, a = col.red, col.green, col.blue, col.alpha end
      else
        local v = pc.grayaV(c); a = pc.grayaA(c); r, g, b = v, v, v
      end
      px[row + x + 1] = packRGBA(r, g, b, a)
    end
  end
  return { px = px, w = w, h = h }
end

-- ------------------------------------------------------- 1. chroma-key
local function detectChroma(fr)
  local w, h, px = fr.w, fr.h, fr.px
  local t = math.max(1, math.floor(0.02 * math.min(w, h)))
  local cnt, total = {}, 0
  local function add(i)
    local c = px[i] if pA(c) <= 200 then return end
    local k = math.floor(pR(c) / 16) * 256 + math.floor(pG(c) / 16) * 16 + math.floor(pB(c) / 16)
    cnt[k] = (cnt[k] or 0) + 1; total = total + 1
  end
  for y = 0, t - 1 do for x = 0, w - 1 do add(y * w + x + 1) end end
  for y = h - t, h - 1 do for x = 0, w - 1 do add(y * w + x + 1) end end
  for y = 0, h - 1 do add(y * w + 1); add(y * w + w) end
  if total == 0 then return nil end
  local bk, bv = 0, 0
  for k, v in pairs(cnt) do if v > bv then bv, bk = v, k end end
  local cov = bv / total
  local r = math.floor(bk / 256) * 16 + 8
  local g = math.floor(bk / 16) % 16 * 16 + 8
  local b = bk % 16 * 16 + 8
  if cov > 0.30 and (math.max(r, g, b) - math.min(r, g, b)) > 60 then
    return { key = { r, g, b }, cov = cov }
  end
  return nil
end

local function chromaKey(fr, key, tol)
  local lo, hi = tol * 0.45, tol * 1.05
  local kr, kg, kb = key[1], key[2], key[3]
  local green, blue, red = kg > kr and kg > kb, kb > kr and kb > kg, kr > kg and kr > kb
  local px = fr.px
  for i = 1, #px do
    local c = px[i]
    local dr, dg, db = pR(c) - kr, pG(c) - kg, pB(c) - kb
    local dist = math.sqrt(dr * dr + dg * dg + db * db)
    local a = (dist - lo) / math.max(1e-6, hi - lo)
    a = math.min(1, math.max(0, a))
    local r, g, b = pR(c), pG(c), pB(c)
    if green then g = math.min(g, math.max(r, b))
    elseif blue then b = math.min(b, math.max(r, g))
    elseif red then r = math.min(r, math.max(g, b)) end
    px[i] = packRGBA(r, g, b, math.floor(a * 255 + 0.5))
  end
end

-- ------------------------------------------------------- 2. grade
local function edgeSignal(fr)
  local w, h, px = fr.w, fr.h, fr.px
  local dx, dy = {}, {}
  for x = 1, w - 1 do dx[x] = 0 end
  for y = 1, h - 1 do dy[y] = 0 end
  for y = 0, h - 1 do
    local row = y * w
    for x = 0, w - 2 do
      local c0, c1 = px[row + x + 1], px[row + x + 2]
      local a0, a1 = pA(c0) / 255, pA(c1) / 255
      local s = 0
      for ch = 0, 2 do
        local f = ch == 0 and pR or (ch == 1 and pG or pB)
        local v0 = f(c0) * a0 + 255 * (1 - a0)
        local v1 = f(c1) * a1 + 255 * (1 - a1)
        s = s + math.abs(v1 - v0)
      end
      dx[x + 1] = dx[x + 1] + s / h
    end
  end
  for x = 0, w - 1 do
    for y = 0, h - 2 do
      local c0, c1 = px[y * w + x + 1], px[(y + 1) * w + x + 1]
      local a0, a1 = pA(c0) / 255, pA(c1) / 255
      local s = 0
      for ch = 0, 2 do
        local f = ch == 0 and pR or (ch == 1 and pG or pB)
        local v0 = f(c0) * a0 + 255 * (1 - a0)
        local v1 = f(c1) * a1 + 255 * (1 - a1)
        s = s + math.abs(v1 - v0)
      end
      dy[y + 1] = dy[y + 1] + s / w
    end
  end
  return dx, dy
end

local function contentMask(sig, n, pitch)
  local w = math.max(3, math.floor(pitch + 0.5))
  local cum = { [0] = 0 }
  for i = 1, n do cum[i] = cum[i - 1] + (sig[i] or 0) end
  local vals = {}
  for i = 1, n do if sig[i] > 0 then vals[#vals + 1] = sig[i] end end
  table.sort(vals)
  local med = #vals > 0 and vals[math.floor(#vals / 2) + 1] or 0
  local thr = math.max(1e-6, 0.25 * med)
  local mask = {}
  for i = 1, n do
    local a = math.max(1, i - math.floor(w / 2))
    local b = math.min(n, i + w - math.floor(w / 2) - 1)
    local sm = (cum[b] - cum[a - 1]) / math.max(1, b - a + 1)
    mask[i] = sm > thr
  end
  return mask
end

local function boundaryPeaks(sig, n)
  local cm = contentMask(sig, n, 7)
  local vals, sum, cnt = {}, 0, 0
  for i = 1, n do if cm[i] then sum = sum + sig[i]; cnt = cnt + 1; vals[#vals + 1] = sig[i] end end
  if cnt < 16 then return {} end
  table.sort(vals)
  local thr = math.max((sum / cnt) * 2.0, vals[math.floor(cnt * 0.90) + 1])
  local peaks, i = {}, 1
  while i <= n do
    if sig[i] > thr and cm[i] then
      local j = i
      while j + 1 <= n and sig[j + 1] > thr and (j + 1 - i) <= 4 do j = j + 1 end
      local bi = i
      for k = i, j do if sig[k] > sig[bi] then bi = k end end
      peaks[#peaks + 1] = bi
      i = j + 1
    else i = i + 1 end
  end
  return peaks
end

local function circPhase(bounds, p)
  local r = {}
  for i, b in ipairs(bounds) do r[i] = ((b % p) + p) % p end
  table.sort(r)
  local gi, gv = 1, -1
  for i = 1, #r do
    local nx = i < #r and r[i + 1] or r[1] + p
    if nx - r[i] > gv then gv = nx - r[i]; gi = i end
  end
  local cut = (r[gi] + gv / 2) % p
  local nxt = r[gi % #r + 1]
  return ((((nxt + p - cut) % p) + cut) % p)
end

local function fitPitch(bounds, p0)
  local o, p = bounds[1], p0
  for _ = 1, 5 do
    local k, dbs, dks = {}, {}, {}
    for i, b in ipairs(bounds) do k[i] = math.floor((b - o) / p + 0.5) end
    for i = 2, #bounds do
      if k[i] > k[i - 1] then dbs[#dbs + 1] = bounds[i] - bounds[i - 1]; dks[#dks + 1] = k[i] - k[i - 1] end
    end
    if #dbs < 3 then return nil end
    local ratios = {}
    for i = 1, #dbs do ratios[i] = dbs[i] / dks[i] end
    table.sort(ratios)
    local pn = ratios[math.floor(#ratios / 2) + 1]
    local res = {}
    for i, b in ipairs(bounds) do res[i] = b - k[i] * pn end
    table.sort(res)
    local on = res[math.floor(#res / 2) + 1]
    if math.abs(pn - p) < 1e-4 and math.abs(on - o) < 1e-4 then p, o = pn, on break end
    p, o = pn, on
  end
  for _ = 1, 2 do
    local k, K, B = {}, {}, {}
    for i, b in ipairs(bounds) do k[i] = math.floor((b - o) / p + 0.5) end
    local tol = math.max(1.5, 0.08 * p)
    for i, b in ipairs(bounds) do
      if math.abs(b - (o + k[i] * p)) <= tol then K[#K + 1] = k[i]; B[#B + 1] = b end
    end
    if #K >= 6 then
      local sk, sb, skk, skb = 0, 0, 0, 0
      for i = 1, #K do sk = sk + K[i]; sb = sb + B[i]; skk = skk + K[i] * K[i]; skb = skb + K[i] * B[i] end
      local den = #K * skk - sk * sk
      if math.abs(den) > 1e-9 then
        p = (#K * skb - sk * sb) / den
        o = (sb - p * sk) / #K
      end
    end
  end
  if p < 1.8 then return nil end
  return p, o
end

local function refinePitchFine(bounds, p0)
  local best = { 0, p0, 0 }
  local p = math.max(2, p0 - 0.8)
  while p <= p0 + 0.8 do
    local o = circPhase(bounds, p)
    local inl = 0
    for _, b in ipairs(bounds) do
      local r = ((b - o + p / 2) % p + p) % p - p / 2
      if math.abs(r) <= 1.0 then inl = inl + 1 end
    end
    local cov = inl / #bounds
    if cov > best[1 - 1 + 1] and cov > best[1] then best = { cov, p, o } end
    p = p + 0.02
  end
  return best[2], best[3]
end

local function ransacPitch(bounds, lo, hi, tol)
  lo, hi, tol = lo or 3, hi or 64, tol or 1.2
  local nb = #bounds
  if nb < 8 or nb > 44 then return nil end
  local best = { 0, 0, 0 }
  for i = 1, nb do
    for j = i + 1, nb do
      local d = bounds[j] - bounds[i]
      for m = 1, 8 do
        local p = d / m
        if p >= lo and p <= hi then
          local tolp = math.max(0.6, math.min(tol, 0.15 * p))
          local o = circPhase(bounds, p)
          local inl = 0
          for _, b in ipairs(bounds) do
            local r = ((b - o + p / 2) % p + p) % p - p / 2
            if math.abs(r) <= tolp then inl = inl + 1 end
          end
          if inl > best[1] or (inl == best[1] and inl > 0 and p > best[2]) then
            best = { inl, p, o }
          end
        end
      end
    end
  end
  if best[1] < 6 then return nil end
  local inl, p, o = best[1], best[2], best[3]
  local tolp = math.max(0.6, math.min(tol, 0.15 * p))
  local inb = {}
  for _, b in ipairs(bounds) do
    local r = ((b - o + p / 2) % p + p) % p - p / 2
    if math.abs(r) <= tolp then inb[#inb + 1] = b end
  end
  if #inb >= 6 then
    local fit = fitPitch(inb, p)
    if fit then p, o = fit[1], fit[2] end
  end
  local p2, o2 = refinePitchFine(#inb >= 6 and inb or bounds, p)
  return p2, o2, inl / nb
end

local function detectPitch(sig, n)
  local r = ransacPitch(boundaryPeaks(sig, n))
  if not r then return 1, 0, 0 end
  return r[1], r[2], r[3]
end

local function detectGrid(fr)
  local w, h = fr.w, fr.h
  local dx, dy = edgeSignal(fr)
  local px, ox, fx = detectPitch(dx, w - 1)
  local py, oy, fy = detectPitch(dy, h - 1)
  if math.max(fx, fy) >= 0.5 then
    local ref = fx >= fy and px or py
    local lo2, hi2 = ref * 0.94, ref * 1.06
    if fx < fy or math.abs(px - py) > 0.06 * math.max(px, py) then
      local r = ransacPitch(boundaryPeaks(dx, w - 1), lo2, hi2)
      if r and r[3] >= 0.4 then px, ox, fx = r[1], r[2], r[3] end
    end
    if fy < fx or math.abs(px - py) > 0.06 * math.max(px, py) then
      local r = ransacPitch(boundaryPeaks(dy, h - 1), lo2, hi2)
      if r and r[3] >= 0.4 then py, oy, fy = r[1], r[2], r[3] end
    end
  end
  local conf = math.min(fx, fy)
  if conf < 0.5 or px < 1.8 or py < 1.8 then
    return { px = 1, py = 1, ox = 0, oy = 0, conf = 0, native = true }
  end
  return { px = px, py = py, ox = ((ox % px) + px) % px, oy = ((oy % py) + py) % py,
           conf = conf, native = false }
end

-- ------------------------------------------- 3. reamostragem nativa (miolo)
local function resampleNative(fr, g)
  local w, h, px = fr.w, fr.h, fr.px
  local ox, oy = g.ox + 0.5, g.oy + 0.5
  local nw = math.max(1, math.floor((w - ox) / g.px))
  local nh = math.max(1, math.floor((h - oy) / g.py))
  local out = {}
  for j = 0, nh - 1 do
    local y0 = math.floor(oy + j * g.py + 0.5)
    local y1 = math.floor(oy + (j + 1) * g.py + 0.5)
    y0 = math.max(0, math.min(h, y0)); y1 = math.max(y0 + 1, math.min(h, y1))
    if y0 < h then
      for i = 0, nw - 1 do
        local x0 = math.floor(ox + i * g.px + 0.5)
        local x1 = math.floor(ox + (i + 1) * g.px + 0.5)
        x0 = math.max(0, math.min(w, x0)); x1 = math.max(x0 + 1, math.min(w, x1))
        if x0 < w then
          local na, tot = 0, 0
          for y = y0, y1 - 1 do
            local row = y * w
            for x = x0, x1 - 1 do
              tot = tot + 1
              if pA(px[row + x + 1]) > 127 then na = na + 1 end
            end
          end
          local idx = j * nw + i + 1
          if na / tot >= 0.45 then
            local m = math.floor(0.22 * (y1 - y0))
            local my0, my1 = y0 + m, math.max(y0 + m + 1, y1 - m)
            m = math.floor(0.22 * (x1 - x0))
            local mx0, mx1 = x0 + m, math.max(x0 + m + 1, x1 - m)
            local rs, gs, bs = {}, {}, {}
            for y = my0, my1 - 1 do
              local row = y * w
              for x = mx0, mx1 - 1 do
                local c = px[row + x + 1]
                if pA(c) > 127 then
                  rs[#rs + 1] = pR(c); gs[#gs + 1] = pG(c); bs[#bs + 1] = pB(c)
                end
              end
            end
            if #rs < 4 then
              rs, gs, bs = {}, {}, {}
              for y = y0, y1 - 1 do
                local row = y * w
                for x = x0, x1 - 1 do
                  local c = px[row + x + 1]
                  if pA(c) > 127 then
                    rs[#rs + 1] = pR(c); gs[#gs + 1] = pG(c); bs[#bs + 1] = pB(c)
                  end
                end
              end
            end
            if #rs > 0 then
              table.sort(rs); table.sort(gs); table.sort(bs)
              out[idx] = packRGBA(rs[math.floor(#rs / 2) + 1], gs[math.floor(#gs / 2) + 1],
                                  bs[math.floor(#bs / 2) + 1], 255)
            end
          end
        end
      end
    end
  end
  return { px = out, w = nw, h = nh }
end

-- --------------------------------------- 4. paleta exata / k-means OKLab
local function exactPalette(natives, maxColors, radius)
  radius = radius or 10
  local cnt = {}
  for _, nat in ipairs(natives) do
    for i = 1, nat.w * nat.h do
      local c = nat.px[i]
      if c and pA(c) > 0 then
        local k = pR(c) * 65536 + pG(c) * 256 + pB(c)
        cnt[k] = (cnt[k] or 0) + 1
      end
    end
  end
  local entries = {}
  for k, v in pairs(cnt) do if v >= 3 then entries[#entries + 1] = { k, v } end end
  table.sort(entries, function(a, b) return a[2] > b[2] end)
  local centers, members = {}, {}
  for _, e in ipairs(entries) do
    local k = e[1]
    local c = { math.floor(k / 65536), math.floor(k / 256) % 256, k % 256 }
    local hit = -1
    for i, ct in ipairs(centers) do
      local dr, dg, db = ct[1] - c[1], ct[2] - c[2], ct[3] - c[3]
      if math.sqrt(dr * dr + dg * dg + db * db) <= radius then hit = i break end
    end
    if hit >= 0 then
      members[hit][#members[hit] + 1] = c
      local s = { 0, 0, 0 }
      for _, mm in ipairs(members[hit]) do s[1] = s[1] + mm[1]; s[2] = s[2] + mm[2]; s[3] = s[3] + mm[3] end
      centers[hit] = { s[1] / #members[hit], s[2] / #members[hit], s[3] / #members[hit] }
    else
      centers[#centers + 1] = { c[1], c[2], c[3] }
      members[#members + 1] = { c }
    end
  end
  if #centers > 0 and #centers <= maxColors then
    local pal = {}
    for i, ct in ipairs(centers) do
      pal[i] = { math.floor(math.min(255, math.max(0, ct[1])) + 0.5),
                 math.floor(math.min(255, math.max(0, ct[2])) + 0.5),
                 math.floor(math.min(255, math.max(0, ct[3])) + 0.5) }
    end
    return pal
  end
  return nil
end

local function kmeansOklab(natives, k)
  local pts = {}
  for _, nat in ipairs(natives) do
    for i = 1, nat.w * nat.h do
      local c = nat.px[i]
      if c and pA(c) > 0 then pts[#pts + 1] = { oklab(pR(c), pG(c), pB(c)) } end
    end
  end
  local step = math.max(1, math.floor(#pts / 40000))
  local sample = {}
  for i = 1, #pts, step do sample[#sample + 1] = pts[i] end
  math.randomseed(7)
  local cen = { { sample[1][1], sample[1][2], sample[1][3] } }
  while #cen < k do
    local p = sample[math.random(#sample)]
    cen[#cen + 1] = { p[1], p[2], p[3] }
  end
  for _ = 1, 18 do
    local sums = {}
    for i = 1, #cen do sums[i] = { 0, 0, 0, 0 } end
    for _, p in ipairs(sample) do
      local bi, bd = 1, 1e9
      for i = 1, #cen do
        local d = (p[1] - cen[i][1]) ^ 2 + (p[2] - cen[i][2]) ^ 2 + (p[3] - cen[i][3]) ^ 2
        if d < bd then bd, bi = d, i end
      end
      local s = sums[bi]
      s[1] = s[1] + p[1]; s[2] = s[2] + p[2]; s[3] = s[3] + p[3]; s[4] = s[4] + 1
    end
    local move = 0
    for i = 1, #cen do
      if sums[i][4] > 0 then
        local nc = { sums[i][1] / sums[i][4], sums[i][2] / sums[i][4], sums[i][3] / sums[i][4] }
        move = math.max(move, math.sqrt((nc[1] - cen[i][1]) ^ 2 + (nc[2] - cen[i][2]) ^ 2 + (nc[3] - cen[i][3]) ^ 2))
        cen[i] = nc
      end
    end
    if move < 1e-5 then break end
  end
  local pal = {}
  for i, c in ipairs(cen) do pal[i] = { oklabToRgb(c[1], c[2], c[3]) } end
  return pal
end

local function snapToPalette(nat, palette, labs)
  local out = {}
  for i = 1, nat.w * nat.h do
    local c = nat.px[i]
    if c and pA(c) > 0 then
      local L, a, b = oklab(pR(c), pG(c), pB(c))
      local bi, bd = 1, 1e9
      for j = 1, #labs do
        local d = (L - labs[j][1]) ^ 2 + (a - labs[j][2]) ^ 2 + (b - labs[j][3]) ^ 2
        if d < bd then bd, bi = d, j end
      end
      out[i] = packRGBA(palette[bi][1], palette[bi][2], palette[bi][3], 255)
    end
  end
  return { px = out, w = nat.w, h = nat.h }
end

-- ------------------------------------------------------- 5. órfãos
local function removeOrphans(nat, passes)
  local w, h = nat.w, nat.h
  local data = nat.px
  local changed = 0
  for _ = 1, passes do
    local out, nch = {}, 0
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = y * w + x + 1
        local c = data[i]
        if c and pA(c) > 0 then
          local r, g, b = pR(c), pG(c), pB(c)
          local same = false
          for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 0 and ny >= 0 and nx < w and ny < h then
              local q = data[ny * w + nx + 1]
              if q and pA(q) > 0 and pR(q) == r and pG(q) == g and pB(q) == b then same = true break end
            end
          end
          if not same then
            local cnt = {}
            for dy = -1, 1 do
              for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                  local nx, ny = x + dx, y + dy
                  if nx >= 0 and ny >= 0 and nx < w and ny < h then
                    local q = data[ny * w + nx + 1]
                    if q and pA(q) > 0 then
                      local k = pR(q) * 65536 + pG(q) * 256 + pB(q)
                      cnt[k] = (cnt[k] or 0) + 1
                    end
                  end
                end
              end
            end
            local bk, bv = 0, 0
            for k, v in pairs(cnt) do if v > bv then bv, bk = v, k end end
            if bv >= 4 then
              out[i] = packRGBA(math.floor(bk / 65536), math.floor(bk / 256) % 256, bk % 256, 255)
              nch = nch + 1
            else out[i] = c end
          else out[i] = c end
        end
      end
    end
    data = out; changed = changed + nch
    if nch == 0 then break end
  end
  return { px = data, w = w, h = h, changed = changed }
end

-- ------------------------------------------------------- UI + orquestração
local dlg = Dialog("ai2pixel — Grade-Nativa")
dlg:label{ text = "Converte o sprite ATIVO (IA) em pixel art 1:1" }
dlg:label{ text = "Frames do sprite viram a animação de saída." }
dlg:number{ id = "colors", label = "Máx. de cores:", value = 32, decimals = 0 }
dlg:check{ id = "chroma", text = "Chroma-key automático (fundo sólido)", selected = true }
dlg:number{ id = "tol", label = "Tolerância chroma:", value = 90, decimals = 0 }
dlg:number{ id = "cleanup", label = "Limpeza de órfãos (passadas):", value = 1, decimals = 0 }
dlg:number{ id = "fps", label = "FPS da animação:", value = 12, decimals = 0 }
dlg:check{ id = "save", text = "Salvar .aseprite + .gpl ao concluir", selected = true }
dlg:file{ id = "out", title = "Prefixo de saída (se salvar):", filename = "ai2pixel_out.aseprite", saveFile = true }
dlg:separator{}
dlg:button{ id = "ok", text = "Converter", onclick = function(ev)
  local spr = app.activeSprite
  if not spr then app.alert("ai2pixel: abra antes um sprite (a arte de IA).") return end
  -- no Aseprite os valores dos widgets vêm em ev.data (não em ev)
  local d = ev.data or ev
  local maxColors = math.floor((d.colors or 32) + 0.5)
  local tol = d.tol or 90
  local cleanup = math.floor((d.cleanup or 1) + 0.5)
  local fps = math.max(1, d.fps or 12)

  -- leitura + chroma
  -- Paleta é por-frame na API: sprite.palettes[f] (1-based) — Sprite não tem
  -- campo .palette. Só sprites Indexed têm lista de paletas (RGB/Gray: vazia).
  local indexed = (spr.colorMode == ColorMode.INDEXED)
  local frames = {}
  for f = 1, #spr.frames do
    local pal
    if indexed then pal = spr.palettes[f] end
    local fr = readFrame(spr, spr.frames[f], pal)
    if fr then frames[#frames + 1] = fr end
  end
  if #frames == 0 then app.alert("ai2pixel: nenhum cel encontrado.") return end
  local keyInfo = nil
  if d.chroma then
    local d = detectChroma(frames[1])
    if d then
      keyInfo = d
      for _, fr in ipairs(frames) do chromaKey(fr, d.key, tol) end
    end
  end

  -- grade no frame 0
  local g = detectGrid(frames[1])
  if g.native then
    app.alert("ai2pixel: nenhuma grade de pseudo-pixels detectada\n(confiança baixa). A imagem pode já estar nativa.")
    return
  end

  -- reamostragem
  local natives = {}
  for _, fr in ipairs(frames) do natives[#natives + 1] = resampleNative(fr, g) end

  -- paleta global
  local palette = exactPalette(natives, maxColors)
  local exact = palette ~= nil
  if not palette then palette = kmeansOklab(natives, maxColors) end
  local labs = {}
  for i, c in ipairs(palette) do labs[i] = { oklab(c[1], c[2], c[3]) } end

  -- snap + órfãos
  local finals, orph = {}, {}
  for _, nat in ipairs(natives) do
    local sn = snapToPalette(nat, palette, labs)
    if cleanup > 0 then sn = removeOrphans(sn, cleanup) end
    orph[#orph + 1] = sn.changed or 0
    finals[#finals + 1] = sn
  end

  -- sprite de saída (Indexed, 1:1)
  local nw, nh = finals[1].w, finals[1].h
  local out = Sprite(nw, nh, ColorMode.INDEXED)
  local pal = Palette(#palette)
  for i, c in ipairs(palette) do pal:setColor(i - 1, Color{ r = c[1], g = c[2], b = c[3] }) end
  out:setPalette(pal, false)
  for f = 2, #finals do out:newEmptyFrame(f) end
  local layer = out.layers[1]
  local idxOf = {}
  for i, c in ipairs(palette) do idxOf[c[1] * 65536 + c[2] * 256 + c[3]] = i - 1 end
  local function fill(img, fin)
    for y = 0, nh - 1 do
      for x = 0, nw - 1 do
        local c = fin.px[y * nw + x + 1]
        if c and pA(c) > 0 then
          -- putPixel(x, y, índice de paleta) — esta build expõe putPixel/drawPixel,
          -- não setPixel
          img:putPixel(x, y, idxOf[pR(c) * 65536 + pG(c) * 256 + pB(c)] or 0)
        end
      end
    end
  end
  fill(layer.cels[1].image, finals[1])   -- frame 1 já tem cel padrão
  for f = 2, #finals do
    local img = Image(nw, nh, ColorMode.INDEXED)
    fill(img, finals[f])
    out:newCel(layer, f, img, Point(0, 0))
  end
  for f = 1, #finals do out.frames[f].duration = math.floor(1000 / fps) end

  local msg = string.format(
    "ai2pixel concluído!\ngrade: %.3f × %.3f px (conf. %.2f)\nnativo: %d × %d\npaleta: %d cores (%s)\nórfãos: %s",
    g.px, g.py, g.conf, nw, nh, #palette,
    exact and "EXATA — identidade preservada" or "k-means OKLab",
    table.concat(orph, ", "))
  if d.save and d.out and d.out ~= "" then
    local base = d.out:gsub("%.aseprite$", ""):gsub("%.gpl$", "")
    out:saveAs(base .. ".aseprite")
    pal:saveAs(base .. ".gpl")
    msg = msg .. "\nsalvo: " .. base .. ".aseprite / .gpl"
  end
  app.alert(msg)
end }
dlg:button{ text = "Cancelar", onclick = function() dlg:close() end }
dlg:show{ wait = false }
