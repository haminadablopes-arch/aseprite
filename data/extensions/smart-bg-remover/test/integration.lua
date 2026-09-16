--[[------------------------------------------------------------------------------
  integration.lua - Teste de integração do main.lua com o ambiente falso
  (mock_aseprite.lua). Não faz parte da extensão instalada.

  Lê frames em .bin (cabeçalho: 2 inteiros de 4 bytes little endian = largura,
  altura; depois RGBA), monta um sprite falso, dispara o comando do menu de
  contexto e grava os frames resultantes.
------------------------------------------------------------------------------]]

local M = {}

local function readBin(path)
  local f = assert(io.open(path, "rb"))
  local hdr = f:read(8)
  local b1, b2, b3, b4 = hdr:byte(1, 4)
  local w = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  local b5, b6, b7, b8 = hdr:byte(5, 8)
  local h = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
  local data = f:read("*a")
  f:close()
  return w, h, data
end

local function writeBin(path, w, h, data)
  local function le32(n)
    return string.char(n % 256, (n // 256) % 256, (n // 65536) % 256,
                       (n // 16777216) % 256)
  end
  local f = assert(io.open(path, "wb"))
  f:write(le32(w), le32(h), data)
  f:close()
end

function M.run(cfg)
  -- caminho para require("lib.bgcore")
  package.path = cfg.extPath .. "/?.lua;" .. package.path

  local mock = dofile(cfg.extPath .. "/test/mock_aseprite.lua")

  -- preferências (é o que o diálogo usaria como valores iniciais)
  if cfg.opts then plugin.preferences.last = cfg.opts end
  MOCK_NEXT_BUTTON = cfg.button or "remove"

  dofile(cfg.extPath .. "/main.lua")
  init(plugin)

  -- monta o sprite com os frames de entrada
  local w, h, first = readBin(cfg.inputs[1])
  local sprite = mock.makeSprite(w, h, { colorMode = ColorMode.RGB })
  local layer = sprite:addLayer("Camada 1")
  local shared = nil
  for i, path in ipairs(cfg.inputs) do
    local fw, fh, data = readBin(path)
    assert(fw == w and fh == h, "todos os frames devem ter o mesmo tamanho")
    local f = sprite:addFrame()
    local img
    if cfg.linked and i > 1 then
      img = shared           -- cel vinculado: mesma imagem (não deve ser reprocessada)
    else
      img = mock.makeImage(w, h, data)
      if cfg.linked and i == 1 then shared = img end
    end
    layer:addCel(f.frameNumber, img)
  end

  app.activeSprite = sprite
  app.activeLayer = layer
  app.activeFrame = sprite.frames[1]

  local selFrames = {}
  for _, n in ipairs(cfg.selectedFrames or {}) do
    selFrames[#selFrames + 1] = sprite.frames[n]
  end
  if #selFrames == 0 then
    for _, f in ipairs(sprite.frames) do selFrames[#selFrames + 1] = f end
  end
  app.range = { type = RangeType.FRAMES, frames = selFrames, cels = {} }

  -- dispara o comando exatamente como o menu faria
  local cmdId = cfg.command or "SmartBgRemover"
  local cmd = MOCK_COMMANDS[cmdId]
  if not cmd then
    error("comando não registrado: " .. tostring(cmdId))
  end
  local ok, err = pcall(function() cmd.onclick() end)
  if not ok then
    return { ok = false, error = tostring(err), log = MOCK_LOG }
  end

  -- grava os frames resultantes (camada de resultado, se existir; senão a original)
  local resultLayer = layer
  for _, l in ipairs(sprite.layers) do
    if l ~= layer and l.isImage then
      resultLayer = l
    end
  end
  local out = {}
  for i, f in ipairs(sprite.frames) do
    local cel = resultLayer:cel(f.frameNumber) or layer:cel(f.frameNumber)
    local path = cfg.outputs[i]
    writeBin(path, cel.image.width, cel.image.height, cel.image.bytes)
    out[i] = path
  end

  return {
    ok = true,
    commands = (function()
      local t = {}
      for _, c in ipairs(MOCK_COMMANDS) do t[#t + 1] = c.id .. " -> " .. (c.group or "") end
      return t
    end)(),
    groups = (function()
      local t = {}
      for id, g in pairs(MOCK_GROUPS) do t[#t + 1] = id .. " -> " .. tostring(g.group) end
      return t
    end)(),
    imagesReplaced = MOCK_LOG.imagesReplaced or 0,
    transactions = MOCK_LOG.transactions,
    alerts = MOCK_LOG.alerts,
    printed = MOCK_LOG.printed,
  }
end

return M
