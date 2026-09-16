--[[------------------------------------------------------------------------------
  main.lua - Removedor de Fundo Inteligente (Smart Background Remover) v0.5.0

  Novo fluxo (conforme solicitação):
  - Só 2 layers: Original (oculta após processar) + "Original - removido" (reutilizada)
  - Preview ao vivo no canvas do primeiro frame selecionado
  - Parâmetros essenciais no preview: Detecção + Tolerância + Suavizar bordas + checkbox perFrame
  - Após confirmar, aplica a todos os frames selecionados sem mostrar diálogo de relatório
  - Atalho Ctrl+Shift+B abre direto o preview
  - Undo único com Ctrl+Z

  API usada:
  * plugin:newMenuGroup / newCommand
  * plugin.preferences
  * cel.image = newImage (ReplaceImage)
  * sprite:newLayer / deleteLayer / newCel / deleteCel
  * Dialog com onchange para preview instantâneo
------------------------------------------------------------------------------]]

local bgcore = require("lib.bgcore")

--------------------------------------------------------------------------------
-- Constantes e opções padrão
--------------------------------------------------------------------------------

local PROCESSED_SUFFIX = " - removido"
local BACKUP_SUFFIX = " (backup)" -- para compatibilidade com versões antigas

local MODE_LABELS = {
  "Automático",
  "Cor sólida",
  "Padrão repetitivo",
  "Gradiente",
  "Conjunto de cores",
  "Inundação pelas bordas",
}
local MODE_BY_LABEL = {
  ["Automático"] = "auto",
  ["Cor sólida"] = "flat",
  ["Padrão repetitivo"] = "tile",
  ["Gradiente"] = "gradient",
  ["Conjunto de cores"] = "set",
  ["Inundação pelas bordas"] = "flood",
}
local LABEL_BY_MODE = {}
for k, v in pairs(MODE_BY_LABEL) do LABEL_BY_MODE[v] = k end

local SCOPE_LABELS = { "Frames selecionados", "Frame atual", "Todos os frames" }
local SCOPE_BY_LABEL = {
  ["Frames selecionados"] = "selected",
  ["Frame atual"] = "current",
  ["Todos os frames"] = "all",
}
local LABEL_BY_SCOPE = {}
for k, v in pairs(SCOPE_BY_LABEL) do LABEL_BY_SCOPE[v] = k end

local LAYER_LABELS = { "Camada ativa", "Todas as camadas", "Camadas visíveis" }
local LAYERS_BY_LABEL = {
  ["Camada ativa"] = "active",
  ["Todas as camadas"] = "all",
  ["Camadas visíveis"] = "visible",
}
local LABEL_BY_LAYERS = {}
for k, v in pairs(LAYERS_BY_LABEL) do LABEL_BY_LAYERS[v] = k end

local DEFAULTS = {
  mode = "auto",
  tolerance = 24,
  soft = 0,
  contiguous = true,
  removeIslands = false,
  sample = 6,
  sideTop = true,
  sideBottom = true,
  sideLeft = true,
  sideRight = true,
  scope = "selected",
  layers = "active",
  perFrame = true,
  modeLabel = "Automático",
  scopeLabel = "Frames selecionados",
  layersLabel = "Camada ativa",
}

local function currentOpts()
  local o = {}
  local saved = (plugin and plugin.preferences and plugin.preferences.last) or {}
  for k, v in pairs(DEFAULTS) do
    local sv = saved[k]
    if sv == nil then o[k] = v else o[k] = sv end
  end
  return o
end

local function toAlgoOpts(o)
  return {
    mode = MODE_BY_LABEL[o.modeLabel] or o.mode or "auto",
    tolerance = tonumber(o.tolerance) or 24,
    soft = tonumber(o.soft) or 0,
    contiguous = (o.contiguous == true),
    removeIslands = (o.removeIslands == true),
    sample = tonumber(o.sample) or 6,
    sides = {
      top = (o.sideTop == true),
      bottom = (o.sideBottom == true),
      left = (o.sideLeft == true),
      right = (o.sideRight == true),
    },
  }
end

local function saveOpts(o)
  if plugin and plugin.preferences then
    plugin.preferences.last = o
  end
end

--------------------------------------------------------------------------------
-- Contexto de imagem
--------------------------------------------------------------------------------

local function ctxFor(img, sprite)
  local ctx = {
    w = img.width,
    h = img.height,
    stride = img.rowStride,
    bpp = img.bytesPerPixel,
  }
  local cm = sprite.colorMode
  if cm == ColorMode.INDEXED then
    local pal = sprite.palettes[1]
    local t = {}
    for i = 0, 255 do
      local ok, c = pcall(function() return pal:getColor(i) end)
      if not ok or not c then break end
      t[i] = { c.red, c.green, c.blue, c.alpha }
    end
    ctx.palette = t
    local ti = 0
    pcall(function() ti = sprite.transparentColor end)
    ctx.transparentKey = string.char(ti)
  elseif cm == ColorMode.GRAY or cm == ColorMode.GRAYSCALE then
    ctx.transparentKey = string.char(0, 0)
  else
    ctx.transparentKey = string.char(0, 0, 0, 0)
  end
  return ctx
end

--------------------------------------------------------------------------------
-- Helpers de layers
--------------------------------------------------------------------------------

local function isProcessedLayer(layer)
  if not layer or not layer.name then return false end
  return layer.name:sub(-#PROCESSED_SUFFIX) == PROCESSED_SUFFIX
end

local function isBackupLayer(layer)
  if not layer or not layer.name then return false end
  return layer.name:find("%(backup%)$") ~= nil
end

local function findProcessedLayer(sprite, sourceLayer)
  if not sourceLayer then return nil end
  if isProcessedLayer(sourceLayer) then return sourceLayer end
  local expected = sourceLayer.name .. PROCESSED_SUFFIX
  local function walk(layers)
    for _, l in ipairs(layers) do
      if l.name == expected then return l end
      if l.isGroup then
        local f = walk(l.layers)
        if f then return f end
      end
    end
    return nil
  end
  return walk(sprite.layers)
end

-- Deve ser chamada dentro de uma transaction
local function getOrCreateProcessedLayer(sprite, sourceLayer)
  if isProcessedLayer(sourceLayer) then return sourceLayer end
  local existing = findProcessedLayer(sprite, sourceLayer)
  if existing then return existing end
  local newLayer = sprite:newLayer()
  newLayer.name = sourceLayer.name .. PROCESSED_SUFFIX
  newLayer.isVisible = true
  -- tenta colocar logo acima da original
  local ok = pcall(function()
    newLayer.stackIndex = sourceLayer.stackIndex + 1
  end)
  if not ok then
    -- fallback: mantém no topo mesmo
  end
  return newLayer
end

local function sortedUnique(t)
  local seen, out = {}, {}
  for _, v in ipairs(t) do
    if not seen[v] then seen[v] = true; out[#out + 1] = v end
  end
  table.sort(out)
  return out
end

local function imageLayers(sprite, which)
  local list = {}
  local function walk(layers)
    for _, l in ipairs(layers) do
      if l.isImage then
        if not isProcessedLayer(l) and not isBackupLayer(l) then
          if which == "all" then
            list[#list + 1] = l
          elseif which == "visible" then
            if l.isVisible then list[#list + 1] = l end
          end
        end
      end
      if l.isGroup then walk(l.layers) end
    end
  end
  if which == "active" then
    local al = app.activeLayer
    if al and al.isImage and not isProcessedLayer(al) and not isBackupLayer(al) then
      list[1] = al
      return list
    end
    walk(sprite.layers)
    for _, l in ipairs(list) do
      if l.isEditable then return { l } end
    end
    return { list[1] }
  end
  walk(sprite.layers)
  if #list == 0 then walk(sprite.layers) end
  return list
end

local function collectTargets(sprite, opts)
  local frames = {}
  local scope = SCOPE_BY_LABEL[opts.scopeLabel] or opts.scope or "selected"
  if scope == "all" then
    for i = 1, #sprite.frames do frames[#frames + 1] = i end
  elseif scope == "current" then
    if app.activeFrame then frames[1] = app.activeFrame.frameNumber end
  else
    local rt = app.range.type
    if rt == RangeType.FRAMES then
      for _, f in ipairs(app.range.frames) do frames[#frames + 1] = f.frameNumber end
    elseif rt == RangeType.CELS then
      for _, c in ipairs(app.range.cels) do frames[#frames + 1] = c.frame.frameNumber end
    end
    if #frames == 0 and app.activeFrame then
      frames[1] = app.activeFrame.frameNumber
    end
  end
  frames = sortedUnique(frames)

  local which = LAYERS_BY_LABEL[opts.layersLabel] or opts.layers or "active"
  local layers = imageLayers(sprite, which)

  local targets, seen = {}, {}
  for _, f in ipairs(frames) do
    for _, l in ipairs(layers) do
      if l.isEditable and not l.isTilemap and not isProcessedLayer(l) and not isBackupLayer(l) then
        local cel = l:cel(f)
        if cel and cel.image then
          local id = cel.image.id
          if not seen[id] then
            seen[id] = true
            targets[#targets + 1] = {
              frame = f,
              layer = l,
              cel = cel,
              label = string.format("frame %d / %s", f, l.name),
            }
          end
        end
      end
    end
  end
  -- ordena por frame para pegar o primeiro
  table.sort(targets, function(a,b) return a.frame < b.frame end)
  return targets, frames, layers
end

--------------------------------------------------------------------------------
-- Processamento final (sem diálogo de relatório)
--------------------------------------------------------------------------------

local function runFinalRemoval(sprite, targets, opts, sharedModelForFirst)
  local algo = toAlgoOpts(opts)
  local sharedModel = nil
  if not opts.perFrame then
    sharedModel = sharedModelForFirst
  end

  local ok, err = pcall(function()
    app.transaction("Remover fundo inteligente", function()
      -- mapeia source -> processed
      local processedMap = {}
      for _, t in ipairs(targets) do
        local img = t.cel.image
        local ctx = ctxFor(img, sprite)
        local model
        if sharedModel and not opts.perFrame then
          model = sharedModel
        else
          model = bgcore.analyze(img.bytes, ctx, algo)
          if not opts.perFrame and not sharedModel then
            sharedModel = model
          end
        end

        if model.type == "empty" or model.type == "transparent" then
          -- nada a fazer
        else
          local newBytes, r = bgcore.processWithModel(img.bytes, ctx, model, algo)
          if newBytes and (r.removed or 0) > 0 then
            local newImg = Image(img.spec)
            local bytes = newBytes
            if newImg.rowStride ~= ctx.stride then
              bytes = bgcore.restride(newBytes, ctx, newImg.rowStride)
            end
            newImg.bytes = bytes
            local dest = getOrCreateProcessedLayer(sprite, t.layer)
            processedMap[t.layer] = dest
            local existingCel = dest:cel(t.frame)
            if existingCel then
              existingCel.image = newImg
            else
              sprite:newCel(dest, t.frame, newImg, t.cel.position)
            end
          end
        end
      end

      -- ocultar originais, mostrar processadas
      for src, proc in pairs(processedMap) do
        src.isVisible = false
        proc.isVisible = true
      end
      -- também garante que para layers que já tinham processada mas não foram tocadas neste run (ex: só 1 frame), ainda oculta original se processada tem cel no frame
      -- já tratado acima
    end)
  end)

  if not ok then
    app.alert("Erro durante a execução:\n" .. tostring(err))
    return false
  end

  app.refresh()
  return true
end

--------------------------------------------------------------------------------
-- Preview ao vivo no canvas
--------------------------------------------------------------------------------

local function showPreviewDialog()
  local sprite = app.activeSprite
  if not sprite then
    app.alert("Abra um sprite primeiro.")
    return
  end

  local initialOpts = currentOpts()
  local targets, frames, layers = collectTargets(sprite, initialOpts)
  if #targets == 0 then
    app.alert("Nenhum cel encontrado para o escopo escolhido.\nDica: selecione os frames na timeline antes de usar o comando.")
    return
  end

  -- primeiro frame selecionado = primeiro da lista ordenada
  local firstTarget = targets[1]
  local sourceLayer = firstTarget.layer

  -- salva estados para restauração em caso de cancel
  local originalSourceVisible = sourceLayer.isVisible
  local processedLayer = findProcessedLayer(sprite, sourceLayer)
  local createdNewLayer = (processedLayer == nil)
  local originalProcessedVisible = nil
  local originalProcessedCelBytes = nil
  local originalProcessedCelSpec = nil
  local originalProcessedCelPosition = nil
  local hadOriginalCel = false

  if processedLayer then
    originalProcessedVisible = processedLayer.isVisible
    local cel = processedLayer:cel(firstTarget.frame)
    if cel and cel.image then
      hadOriginalCel = true
      originalProcessedCelBytes = cel.image.bytes
      originalProcessedCelSpec = cel.image.spec
      originalProcessedCelPosition = cel.position
    end
  end

  -- prepara preview: cria layer se necessário e garante cel inicial
  local function preparePreviewTx()
    app.transaction("Preparar Preview Fundo", function()
      if not processedLayer then
        processedLayer = getOrCreateProcessedLayer(sprite, sourceLayer)
      end
      -- garante que tem cel no primeiro frame (copia original como placeholder)
      local existing = processedLayer:cel(firstTarget.frame)
      if not existing then
        local srcImg = firstTarget.cel.image
        local copyImg = Image(srcImg.spec)
        copyImg.bytes = srcImg.bytes
        sprite:newCel(processedLayer, firstTarget.frame, copyImg, firstTarget.cel.position)
      end
      sourceLayer.isVisible = false
      processedLayer.isVisible = true
      -- foca no frame do preview
      if app.activeFrame and app.activeFrame.frameNumber ~= firstTarget.frame then
        app.activeFrame = sprite.frames[firstTarget.frame]
      end
    end)
  end

  preparePreviewTx()
  app.refresh()

  -- estado compartilhado para finalização
  local sharedModelForConfirm = nil
  local lastPreviewOpts = nil

  local dlg = Dialog{ title = "Preview Remoção de Fundo (Ctrl+Shift+B)" }

  local function getDlgOpts()
    local data = dlg.data
    local o = {}
    for k, v in pairs(initialOpts) do o[k] = v end
    o.modeLabel = data.modeLabel or o.modeLabel
    o.tolerance = data.tolerance or o.tolerance
    o.soft = data.soft or o.soft
    o.perFrame = data.perFrame
    -- mantém os demais (contiguous, sample, sides) dos defaults salvos
    return o
  end

  local function updatePreview()
    local curOpts = getDlgOpts()
    lastPreviewOpts = curOpts
    local algo = toAlgoOpts(curOpts)

    local img = firstTarget.cel.image
    local ctx = ctxFor(img, sprite)

    local ok, model, newBytes, rep = pcall(function()
      local m = bgcore.analyze(img.bytes, ctx, algo)
      local nb, r = bgcore.processWithModel(img.bytes, ctx, m, algo)
      return m, nb, r
    end)

    if not ok then
      dlg:modify{ id = "status", text = "Erro no preview: " .. tostring(model) }
      return
    end

    sharedModelForConfirm = model

    if newBytes then
      local newImg = Image(img.spec)
      local bytes = newBytes
      if newImg.rowStride ~= ctx.stride then
        bytes = bgcore.restride(newBytes, ctx, newImg.rowStride)
      end
      newImg.bytes = bytes

      -- atualiza cel da layer processada diretamente (sem nova transaction para ser instantâneo)
      -- mas dentro de pcall para não quebrar se API exigir transaction
      local ok2, err2 = pcall(function()
        local cel = processedLayer:cel(firstTarget.frame)
        if cel then
          cel.image = newImg
        else
          sprite:newCel(processedLayer, firstTarget.frame, newImg, firstTarget.cel.position)
        end
      end)
      if not ok2 then
        -- fallback: tenta dentro de transaction rápida
        pcall(function()
          app.transaction("Preview Fundo", function()
            local cel = processedLayer:cel(firstTarget.frame)
            if cel then
              cel.image = newImg
            else
              sprite:newCel(processedLayer, firstTarget.frame, newImg, firstTarget.cel.position)
            end
          end)
        end)
      end

      local pct = rep and rep.percent or 0
      dlg:modify{ id = "status", text = string.format("Preview frame %d: %s - %.1f%% removido - %d/%d frames selecionados", firstTarget.frame, model.type, pct, #targets, #frames) }
    else
      dlg:modify{ id = "status", text = string.format("Preview: %s - nada a remover", model.description or model.type) }
    end

    if app.refresh then app.refresh() end
    dlg:repaint()
  end

  -- widgets com onchange para preview instantâneo no canvas
  dlg:combobox{
    id = "modeLabel",
    label = "Detecção:",
    options = MODE_LABELS,
    option = initialOpts.modeLabel,
    onchange = updatePreview,
  }
  dlg:slider{
    id = "tolerance",
    label = "Tolerância:",
    min = 0, max = 128,
    value = initialOpts.tolerance,
    onchange = updatePreview,
  }
  dlg:slider{
    id = "soft",
    label = "Suavizar bordas:",
    min = 0, max = 64,
    value = initialOpts.soft,
    onchange = updatePreview,
  }
  dlg:check{
    id = "perFrame",
    text = "Detectar fundo em cada frame ao confirmar",
    selected = initialOpts.perFrame,
  }
  dlg:separator{ text = "Preview ao vivo no canvas" }
  dlg:label{ id = "status", text = "Processando preview do frame " .. firstTarget.frame .. "..." }
  dlg:separator()
  dlg:button{ id = "confirm", text = "Confirmar e aplicar a todos", focus = true }
  dlg:button{ id = "cancel", text = "Cancelar" }

  -- primeiro preview
  updatePreview()

  dlg:show()

  local data = dlg.data
  if data.confirm then
    local finalOpts = lastPreviewOpts or getDlgOpts()
    saveOpts(finalOpts)
    -- aplica a todos
    runFinalRemoval(sprite, targets, finalOpts, sharedModelForConfirm)
  else
    -- cancelar: restaura estado original
    app.transaction("Cancelar preview fundo", function()
      -- restaura visibilidade original
      if sourceLayer then
        sourceLayer.isVisible = originalSourceVisible
      end
      if createdNewLayer then
        -- remove a layer que foi criada só para preview
        if processedLayer then
          -- verifica se ainda existe
          local stillExists = false
          local function walk(layers)
            for _, l in ipairs(layers) do
              if l == processedLayer then stillExists = true; return end
              if l.isGroup then walk(l.layers) end
            end
          end
          walk(sprite.layers)
          if stillExists then
            sprite:deleteLayer(processedLayer)
          end
        end
      else
        if processedLayer then
          if originalProcessedVisible ~= nil then
            processedLayer.isVisible = originalProcessedVisible
          end
          local cel = processedLayer:cel(firstTarget.frame)
          if hadOriginalCel and originalProcessedCelBytes and originalProcessedCelSpec then
            if cel then
              local restoreImg = Image(originalProcessedCelSpec)
              restoreImg.bytes = originalProcessedCelBytes
              cel.image = restoreImg
              if originalProcessedCelPosition then
                -- posição já está, mas tenta restaurar
                pcall(function() cel.position = originalProcessedCelPosition end)
              end
            end
          else
            -- não tinha cel antes, remove o que foi criado para preview
            if cel then
              sprite:deleteCel(processedLayer, sprite.frames[firstTarget.frame])
            end
          end
        end
      end
    end)
    app.refresh()
  end
end

--------------------------------------------------------------------------------
-- Comandos antigos adaptados para novo fluxo
--------------------------------------------------------------------------------

local function hasSprite()
  return app.activeSprite ~= nil
end

local function cmdPreview()
  showPreviewDialog()
end

local function cmdRepeat()
  local sprite = app.activeSprite
  if not sprite then
    app.alert("Abra um sprite primeiro.")
    return
  end
  local saved = (plugin and plugin.preferences and plugin.preferences.last)
  if not saved then
    showPreviewDialog()
    return
  end
  local opts = currentOpts()
  local targets = (function()
    local t = collectTargets(sprite, opts)
    return t
  end)()
  if #targets == 0 then
    app.alert("Nenhum cel encontrado.")
    return
  end
  -- aplica direto sem preview, sem diálogo, reutilizando layer
  runFinalRemoval(sprite, targets, opts, nil)
  saveOpts(opts)
end

--------------------------------------------------------------------------------
-- init / exit
--------------------------------------------------------------------------------

function init(plugin)
  -- submenu no menu de contexto dos FRAMES da timeline
  plugin:newMenuGroup{
    id = "smartbg_frame_menu",
    title = "Fundo Inteligente",
    group = "frame_popup_reverse",
  }
  plugin:newCommand{
    id = "SmartBgRemoverPreview",
    title = "Preview Remoção de Fundo (Ctrl+Shift+B)",
    group = "smartbg_frame_menu",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }
  plugin:newCommand{
    id = "SmartBgRemover",
    title = "Remover fundo (preview)...",
    group = "smartbg_frame_menu",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }
  plugin:newCommand{
    id = "SmartBgRemoverRepeat",
    title = "Repetir última remoção",
    group = "smartbg_frame_menu",
    onclick = cmdRepeat,
    onenabled = function() return hasSprite() and plugin.preferences.last ~= nil end,
  }

  -- mesmo conjunto no menu de contexto dos CELS
  plugin:newMenuGroup{
    id = "smartbg_cel_menu",
    title = "Fundo Inteligente",
    group = "cel_popup_new",
  }
  plugin:newCommand{
    id = "SmartBgRemoverCelPreview",
    title = "Preview Remoção de Fundo (Ctrl+Shift+B)",
    group = "smartbg_cel_menu",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }
  plugin:newCommand{
    id = "SmartBgRemoverCel",
    title = "Remover fundo (preview)...",
    group = "smartbg_cel_menu",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }
  plugin:newCommand{
    id = "SmartBgRemoverRepeatCel",
    title = "Repetir última remoção",
    group = "smartbg_cel_menu",
    onclick = cmdRepeat,
    onenabled = function() return hasSprite() and plugin.preferences.last ~= nil end,
  }

  -- comando global para atalho (aparece em Edit > Keyboard Shortcuts)
  plugin:newCommand{
    id = "SmartBgRemoverGlobalPreview",
    title = "Fundo Inteligente: Preview Remoção",
    group = "edit_new",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }
end

function exit(plugin)
end
