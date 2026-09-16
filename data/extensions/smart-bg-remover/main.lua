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
  local imageFrames = {} -- id da imagem -> todos os cels que a usam (frames vinculados)
  for _, f in ipairs(frames) do
    for _, l in ipairs(layers) do
      if l.isEditable and not l.isTilemap and not isProcessedLayer(l) and not isBackupLayer(l) then
        local cel = l:cel(f)
        if cel and cel.image then
          local id = cel.image.id
          imageFrames[id] = imageFrames[id] or {}
          imageFrames[id][#imageFrames[id] + 1] = { frame = f, layer = l, cel = cel }
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
  return targets, frames, layers, imageFrames
end

--------------------------------------------------------------------------------
-- Processamento final (sem diálogo de relatório)
--------------------------------------------------------------------------------

local function runFinalRemoval(sprite, targets, opts, sharedModelForFirst, imageFrames)
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
  local targets, frames, layers, imageFrames = collectTargets(sprite, initialOpts)
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
  if processedLayer then
    originalProcessedVisible = processedLayer.isVisible
  end

  -- estado pré-preview de CADA cel que for tocado (para restaurar tudo no cancel)
  local previewCels = {}
  local function recordPreviewCel(frameNumber)
    if previewCels[frameNumber] then return end
    local cel = processedLayer and processedLayer:cel(frameNumber)
    if cel and cel.image then
      previewCels[frameNumber] = { existed = true, bytes = cel.image.bytes,
                                   spec = cel.image.spec, position = cel.position }
    else
      previewCels[frameNumber] = { existed = false }
    end
  end

  -- escreve a imagem de preview num frame da layer processada (transação só como fallback)
  local function writePreviewCel(frameNumber, posSrc, newImg)
    recordPreviewCel(frameNumber)
    local ok = pcall(function()
      local cel = processedLayer:cel(frameNumber)
      if cel then
        cel.image = newImg
      else
        sprite:newCel(processedLayer, frameNumber, newImg, posSrc)
      end
    end)
    if not ok then
      pcall(function()
        app.transaction("Preview Fundo", function()
          local cel = processedLayer:cel(frameNumber)
          if cel then
            cel.image = newImg
          else
            sprite:newCel(processedLayer, frameNumber, newImg, posSrc)
          end
        end)
      end)
    end
  end

  -- aplica no frame do alvo + propaga para cels vinculados (mesma imagem)
  local function applyPreviewImage(t, newImg)
    writePreviewCel(t.frame, t.cel.position, newImg)
    local list = imageFrames and imageFrames[t.cel.image.id]
    if list then
      for _, e in ipairs(list) do
        if e.layer == t.layer and e.frame ~= t.frame then
          writePreviewCel(e.frame, e.cel.position, newImg)
        end
      end
    end
  end

  -- prepara preview: cria layer se necessário e garante cel inicial
  local function preparePreviewTx()
    app.transaction("Preparar Preview Fundo", function()
      if not processedLayer then
        processedLayer = getOrCreateProcessedLayer(sprite, sourceLayer)
      end
      -- registra o estado pré-preview de todos os alvos (antes de criar placeholders)
      for _, t in ipairs(targets) do
        recordPreviewCel(t.frame)
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

  -- estado do preview
  local lastPreviewOpts = nil
  local dialogOpen = true
  local batchGen = 0      -- geração do lote (muda a cada updateAllPreviews)
  local batchTimer = nil  -- Timer ativo do lote (se a API tiver Timer)

  local dlg = Dialog{ title = "Preview Remoção de Fundo (Ctrl+Shift+B)" }

  local function getDlgOpts()
    local data = dlg.data
    local o = {}
    for k, v in pairs(initialOpts) do o[k] = v end
    o.modeLabel = data.modeLabel or o.modeLabel
    o.tolerance = data.tolerance or o.tolerance
    o.soft = data.soft or o.soft
    -- booleanos: checagem explícita de nil (false é um valor válido)
    if data.contiguous ~= nil then o.contiguous = data.contiguous end
    if data.removeIslands ~= nil then o.removeIslands = data.removeIslands end
    o.sample = data.sample or o.sample
    if data.sideTop ~= nil then o.sideTop = data.sideTop end
    if data.sideBottom ~= nil then o.sideBottom = data.sideBottom end
    if data.sideLeft ~= nil then o.sideLeft = data.sideLeft end
    if data.sideRight ~= nil then o.sideRight = data.sideRight end
    if data.perFrame ~= nil then o.perFrame = data.perFrame end
    return o
  end

  -- calcula modelo + bytes processados de um alvo.
  -- quando perFrame está desligado, reutiliza o modelo do 1º frame (shared.m)
  local function computeTarget(t, curOpts, algo, shared)
    local img = t.cel.image
    local ctx = ctxFor(img, sprite)
    local model
    if not curOpts.perFrame then
      if not shared.m then shared.m = bgcore.analyze(img.bytes, ctx, algo) end
      model = shared.m
    else
      model = bgcore.analyze(img.bytes, ctx, algo)
    end
    local newBytes, rep = bgcore.processWithModel(img.bytes, ctx, model, algo)
    return img, ctx, model, newBytes, rep
  end

  local function toPreviewImage(img, ctx, newBytes)
    local newImg = Image(img.spec)
    local bytes = newBytes
    if newImg.rowStride ~= ctx.stride then
      bytes = bgcore.restride(newBytes, ctx, newImg.rowStride)
    end
    newImg.bytes = bytes
    return newImg
  end

  -- preview instantâneo: só o primeiro frame (barato, responde durante o arraste)
  local function updatePreview()
    local curOpts = getDlgOpts()
    lastPreviewOpts = curOpts
    local algo = toAlgoOpts(curOpts)

    local ok, img, ctx, model, newBytes, rep = pcall(computeTarget, firstTarget, curOpts, algo, {})
    if not ok then
      dlg:modify{ id = "status", text = "Erro no preview: " .. tostring(img) }
      return
    end

    if newBytes then
      applyPreviewImage(firstTarget, toPreviewImage(img, ctx, newBytes))
      local pct = rep and rep.percent or 0
      dlg:modify{ id = "status", text = string.format("Preview frame %d: %s - %.1f%% removido - %d/%d frames selecionados", firstTarget.frame, model.type, pct, #targets, #frames) }
    else
      dlg:modify{ id = "status", text = string.format("Preview: %s - nada a remover", model.description or model.type) }
    end

    if app.refresh then app.refresh() end
    dlg:repaint()
  end

  -- preview completo: processa TODOS os frames selecionados em parcelas (~50ms),
  -- devolvendo controle à UI entre uma parcela e outra (Timer) para não travar
  local function updateAllPreviews()
    batchGen = batchGen + 1
    local gen = batchGen
    local curOpts = getDlgOpts()
    lastPreviewOpts = curOpts
    local algo = toAlgoOpts(curOpts)
    local shared = {}
    local total = #targets
    local i = 1
    local t0 = os.clock()
    local firstType, firstPct = nil, 0

    local function stopBatchTimer()
      if batchTimer then
        local t = batchTimer
        batchTimer = nil
        pcall(function() t:stop() end)
      end
    end

    local function finish(msg)
      stopBatchTimer()
      dlg:modify{ id = "status", text = msg }
      if app.refresh then app.refresh() end
      dlg:repaint()
    end

    local function step()
      if gen ~= batchGen or not dialogOpen then return end
      while i <= total do
        local t = targets[i]
        local ok, img, ctx, model, newBytes, rep = pcall(computeTarget, t, curOpts, algo, shared)
        if not ok then
          finish("Erro no preview: " .. tostring(img))
          return
        end
        if newBytes then
          applyPreviewImage(t, toPreviewImage(img, ctx, newBytes))
        else
          -- nada detectado: mostra o próprio original (evita frame vazio na animação)
          local copyImg = Image(img.spec)
          copyImg.bytes = img.bytes
          applyPreviewImage(t, copyImg)
        end
        if i == 1 then
          firstType = model.type
          firstPct = (rep and rep.percent) or 0
        end
        i = i + 1
        if i <= total then
          dlg:modify{ id = "status", text = string.format("Atualizando previews... %d/%d frames", i - 1, total) }
        end
        -- em modo Timer, devolve o controle à UI a cada ~50ms;
        -- sem Timer (mock/testes), processa tudo de uma vez
        if batchTimer and (os.clock() - t0) > 0.05 then
          return
        end
      end
      finish(string.format("Previews: %d/%d frames - %s - %.1f%% no frame %d%s",
        total, total, firstType or "?", firstPct, firstTarget.frame,
        curOpts.perFrame and "" or " (modelo compartilhado)"))
    end

    stopBatchTimer()
    if Timer then
      local okT = pcall(function()
        local tmr
        tmr = Timer{ interval = 0.01, ontick = function()
          if gen ~= batchGen or not dialogOpen then
            pcall(function() tmr:stop() end)
            return
          end
          step()
        end }
        batchTimer = tmr
        tmr:start()
      end)
      if not okT then
        batchTimer = nil
        step()
      end
    else
      step()
    end
  end

  -- widgets: sliders atualizam o 1º frame durante o arraste (onchange) e o lote
  -- completo ao soltar (onrelease); checkboxes/combobox disparam o lote completo
  dlg:combobox{
    id = "modeLabel",
    label = "Detecção:",
    options = MODE_LABELS,
    option = initialOpts.modeLabel,
    onchange = updateAllPreviews,
  }
  dlg:slider{
    id = "tolerance",
    label = "Tolerância:",
    min = 0, max = 128,
    value = initialOpts.tolerance,
    onchange = updatePreview,
    onrelease = updateAllPreviews,
  }
  dlg:slider{
    id = "soft",
    label = "Suavizar bordas:",
    min = 0, max = 64,
    value = initialOpts.soft,
    onchange = updatePreview,
    onrelease = updateAllPreviews,
  }
  dlg:check{
    id = "contiguous",
    text = "Apagar somente áreas conectadas às bordas",
    selected = initialOpts.contiguous,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "removeIslands",
    text = "Apagar também ilhas internas",
    selected = initialOpts.removeIslands,
    onchange = updateAllPreviews,
  }
  dlg:separator{ text = "Amostragem da borda" }
  dlg:slider{
    id = "sample",
    label = "Espessura:",
    min = 1, max = 32,
    value = initialOpts.sample,
    onchange = updatePreview,
    onrelease = updateAllPreviews,
  }
  dlg:check{
    id = "sideTop",
    text = "Topo",
    selected = initialOpts.sideTop,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "sideBottom",
    text = "Base",
    selected = initialOpts.sideBottom,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "sideLeft",
    text = "Esquerda",
    selected = initialOpts.sideLeft,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "sideRight",
    text = "Direita",
    selected = initialOpts.sideRight,
    onchange = updateAllPreviews,
  }
  -- perFrame: afeta o preview (modelo compartilhado vs por frame) e a confirmação final
  dlg:check{
    id = "perFrame",
    text = "Detectar fundo em cada frame ao confirmar",
    selected = initialOpts.perFrame,
    onchange = updateAllPreviews,
  }
  dlg:separator{ text = "Preview ao vivo no canvas" }
  dlg:label{ id = "status", text = "Processando preview de " .. #targets .. " frame(s)..." }
  dlg:separator()
  dlg:button{ id = "play", text = "▶ Reproduzir animação", onclick = function()
    pcall(function() app.command.PlayAnimation() end)
  end }
  dlg:button{ id = "confirm", text = "Confirmar e aplicar a todos", focus = true }
  dlg:button{ id = "cancel", text = "Cancelar" }

  -- primeiro preview: 1º frame + lote completo (em parcelas, se houver Timer)
  updateAllPreviews()

  dlg:show()

  dialogOpen = false
  if batchTimer then
    local t = batchTimer
    batchTimer = nil
    pcall(function() t:stop() end)
  end

  local data = dlg.data
  if data.confirm then
    local finalOpts = lastPreviewOpts or getDlgOpts()
    saveOpts(finalOpts)
    -- modelo compartilhado re-analisado do 1º frame com as opções finais
    -- (garante consistência mesmo se um lote ainda estivesse pendente)
    local sharedModel = nil
    if not finalOpts.perFrame then
      local img = firstTarget.cel.image
      local ctx = ctxFor(img, sprite)
      pcall(function() sharedModel = bgcore.analyze(img.bytes, ctx, toAlgoOpts(finalOpts)) end)
    end
    -- aplica a todos
    runFinalRemoval(sprite, targets, finalOpts, sharedModel, imageFrames)
  else
    -- cancelar: restaura o estado pré-preview de TODOS os cels tocados
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
          -- restaura cada cel tocado: existed => bytes originais; senão remove
          for frameNumber, st in pairs(previewCels) do
            local cel = processedLayer:cel(frameNumber)
            if st.existed then
              if cel then
                local restoreImg = Image(st.spec)
                restoreImg.bytes = st.bytes
                cel.image = restoreImg
                if st.position then
                  pcall(function() cel.position = st.position end)
                end
              end
            else
              if cel then
                pcall(function()
                  sprite:deleteCel(processedLayer, sprite.frames[frameNumber])
                end)
              end
            end
          end
          if originalProcessedVisible ~= nil then
            processedLayer.isVisible = originalProcessedVisible
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
  local targets, frames, layers, imageFrames = collectTargets(sprite, opts)
  if #targets == 0 then
    app.alert("Nenhum cel encontrado.")
    return
  end
  -- aplica direto sem preview, sem diálogo, reutilizando layer
  runFinalRemoval(sprite, targets, opts, nil, imageFrames)
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
