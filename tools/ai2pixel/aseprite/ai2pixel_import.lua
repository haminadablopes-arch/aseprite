-- ai2pixel_import.lua — monta um sprite animado no Aseprite a partir dos
-- frames nativos exportados pelo pipeline Grade-Nativa + paleta .gpl
--
-- Uso (CLI oficial):
--   aseprite -b --script ai2pixel_import.lua \
--     --script-param dir=out/frames_native \
--     --script-param count=16 \
--     --script-param gpl=out/palette.gpl \
--     --script-param out=personagem.aseprite
--
-- Como as cores dos frames já são membros EXATOS da paleta, converter para
-- Indexed depois (Sprite > Color Mode > Indexed) não perde nada.

local dir   = app.params.dir   or '.'
local count = tonumber(app.params.count or '1')
local gpl   = app.params.gpl   or ''
local outp  = app.params.out   or 'ai2pixel_sprite.aseprite'

-- 1) lê a paleta .gpl (linhas "R G B nome")
local palColors = {}
if gpl ~= '' then
  local f = io.open(gpl, 'r')
  if f then
    for line in f:lines() do
      local r, g, b = line:match('^%s*(%d+)%s+(%d+)%s+(%d+)')
      if r then palColors[#palColors + 1] = { tonumber(r), tonumber(g), tonumber(b) } end
    end
    f:close()
  end
end

-- 2) descobre o tamanho no primeiro frame
local first = app.open(dir .. '/frame_00.png')
local w, h = first.width, first.height
first:close()

-- 3) sprite animado com um cel por frame
local spr = Sprite(w, h, ColorMode.RGB)
for i = 2, count do spr:newFrame(i) end
for i = 1, count do
  local name = string.format('%s/frame_%02d.png', dir, i - 1)
  local src = app.open(name)
  local img = src.cels[1].image
  spr.cels[i].image:putImage(img, Point(0, 0))
  src:close()
end

-- 4) aplica a paleta recuperada
if #palColors > 0 then
  local pal = Palette(#palColors)
  for i, c in ipairs(palColors) do
    pal:setColor(i - 1, Color{ r = c[1], g = c[2], b = c[3] })
  end
  spr:setPalette(pal, false)
end

spr:saveAs(outp)
print('ai2pixel: ' .. count .. ' frames ' .. w .. 'x' .. h ..
      ' -> ' .. outp .. ' (' .. #palColors .. ' cores na paleta)')
