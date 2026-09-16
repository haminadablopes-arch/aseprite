--[[------------------------------------------------------------------------------
  main.lua - Removedor de Fundo Inteligente (Smart Background Remover)

  Registra os comandos no menu de contexto da timeline (frames selecionados) e
  no menu de contexto dos cels, mostra o diálogo de opções e aplica a remoção
  do fundo em todos os frames selecionados dentro de uma única transação
  (um único Ctrl+Z desfaz tudo).

  Detalhes da API usados aqui (conforme src/app/script/*):
    * plugin:newMenuGroup{ id, title, group } - cria um submenu num grupo existente
    * plugin:newCommand{ id, title, group, onclick, onenabled }
    * plugin.preferences                      - persistido em preferences.lua
    * cel.image = novoImage                   - cmd::ReplaceImage (desfazível)
------------------------------------------------------------------------------]]

local bgcore = require("lib.bgcore")

--------------------------------------------------------------------------------
-- Opções padrão
--------------------------------------------------------------------------------

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
-- Contexto de imagem para o núcleo
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
-- Alvos (frames x camadas)
--------------------------------------------------------------------------------

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
        if which == "all" then
          list[#list + 1] = l
        elseif which == "visible" then
          if l.isVisible then list[#list + 1] = l end
        end
      end
      if l.isGroup then walk(l.layers) end
    end
  end
  if which == "active" then
    local al = app.activeLayer
    if al and al.isImage then
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
  -- frames
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

  -- camadas
  local which = LAYERS_BY_LABEL[opts.layersLabel] or opts.layers or "active"
  local layers = imageLayers(sprite, which)

  -- cels (sem repetir imagens vinculadas/linkadas)
  local targets, seen = {}, {}
  for _, f in ipairs(frames) do
    for _, l in ipairs(layers) do
      if l.isEditable and not l.isTilemap then
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
  return targets, frames, layers
end

--------------------------------------------------------------------------------
-- Execução
--------------------------------------------------------------------------------

local function formatReport(reports, opts, elapsed)
  local lines = {}
  local totalRemoved, totalPixels, models = 0, 0, {}
  for _, r in ipairs(reports) do
    totalRemoved = totalRemoved + (r.removed or 0)
    totalPixels = totalPixels + (r.total or 0)
    models[r.modelType or "?"] = (models[r.modelType or "?"] or 0) + 1
  end
  lines[#lines + 1] = string.format("Frames processados: %d", #reports)
  local ml = {}
  for k, v in pairs(models) do ml[#ml + 1] = string.format("%s (%d)", k, v) end
  table.sort(ml)
  lines[#lines + 1] = "Modelos detectados: " .. table.concat(ml, ", ")
  if totalPixels > 0 then
    lines[#lines + 1] = string.format("Pixels apagados: %d (%.2f%% do total)",
                                      totalRemoved, totalRemoved / totalPixels * 100)
  end
  lines[#lines + 1] = string.format("Tempo: %.2f s", elapsed)
  lines[#lines + 1] = ""
  local maxLines = 24
  for i, r in ipairs(reports) do
    if i > maxLines then
      lines[#lines + 1] = string.format("... e mais %d frames", #reports - maxLines)
      break
    end
    lines[#lines + 1] = string.format("[%s] %s -> %.2f%% apagado",
                                      r.modelType or "?", r.label or "?", r.percent or 0)
    if r.reason then
      lines[#lines + 1] = "      " .. r.reason
    end
    if r.warnings and #r.warnings > 0 then
      for _, w in ipairs(r.warnings) do
        lines[#lines + 1] = "      AVISO: " .. w
      end
    end
  end
  return table.concat(lines, "\n")
end

local function showResult(title, text)
  -- Análise (somente leitura): relatório no diálogo, sem print no console.
  local dlg = Dialog { title = title }
  dlg:label { text = text }
  dlg:newrow()
  dlg:button { id = "ok", text = "Fechar", focus = true }
  dlg:show()
end

-- Garante, por camada de origem, um backup (camada original renomeada) e
-- uma camada de resultado onde só entram os frames efetivamente alterados.
local function resultLayerFor(sprite, source, cache)
  local rec = cache[source]
  if rec then return rec.result end
  local origName = source.name
  if not origName:find("%(backup%)$") then
    source.name = origName .. " (backup)"
  else
    origName = origName:gsub("%s*%(backup%)$", "")
  end
  local result = sprite:newLayer()
  result.name = origName
  result.isVisible = true
  -- backup permanece visível por baixo nos frames sem cel de resultado
  cache[source] = { result = result, origName = origName }
  return result
end

local function runRemoval(opts, analyzeOnly)
  local sprite = app.activeSprite
  if not sprite then
    app.alert "Abra um sprite primeiro."
    return
  end

  local algo = toAlgoOpts(opts)
  local targets, frames, layers = collectTargets(sprite, opts)
  if #targets == 0 then
    app.alert("Nenhum cel encontrado para o escopo escolhido.\n" ..
              "Dica: selecione os frames na timeline antes de usar o comando.")
    return
  end

  local reports = {}
  local t0 = os.clock()

  -- diálogo de progresso (não modal)
  local progress = nil
  local function setProgress(txt)
    if progress then
      progress:modify { id = "lbl", text = txt }
      if app.refresh then app.refresh() end
      progress:repaint()
    end
  end
  if #targets > 1 then
    progress = Dialog { title = "Removedor de Fundo Inteligente" }
    progress:label { id = "lbl", text = "Iniciando..." }
    progress:show { wait = false }
  end

  local sharedModel, sharedCtx = nil, nil
  local layerCache = {}
  local ok, err = pcall(function()
    local function job()
      for i, t in ipairs(targets) do
        setProgress(string.format("Frame %d/%d: %s", i, #targets, t.label))
        local img = t.cel.image
        local ctx = ctxFor(img, sprite)
        local model
        if (not opts.perFrame) and sharedModel then
          model = sharedModel
        else
          model = bgcore.analyze(img.bytes, ctx, algo)
        end
        if (not opts.perFrame) and not sharedModel then sharedModel = model end

        local rep = {
          label = t.label,
          modelType = model.type,
          description = model.description,
          confidence = model.confidence,
          frame = t.frame,
          layer = t.layer.name,
        }

        rep.warnings = rep.warnings or {}
        if t.layer.isBackground then
          rep.warnings[#rep.warnings + 1] =
            "esta é uma camada de fundo (Background): converta-a em camada normal " ..
            "para enxergar a transparência"
        end

        if model.type == "empty" or model.type == "transparent" then
          rep.reason = model.description
          rep.removed, rep.total, rep.percent = 0, ctx.w * ctx.h, 0
        elseif analyzeOnly then
          -- só análise: não mexe nos pixels, mas estima quantos seriam apagados
          local nb, r = bgcore.processWithModel(img.bytes, ctx, model, algo)
          rep.removed, rep.total, rep.percent = r.removed or 0, r.total or 0, r.percent or 0
          rep.warnings = r.warnings
          rep.elapsed = r.elapsed
        else
          local newBytes, r = bgcore.processWithModel(img.bytes, ctx, model, algo)
          -- backup da origem + cel de resultado só se o frame mudou de fato
          if newBytes and (r.removed or 0) > 0 then
            local newImg = Image(img.spec)
            local bytes = newBytes
            if newImg.rowStride ~= ctx.stride then
              bytes = bgcore.restride(newBytes, ctx, newImg.rowStride)
            end
            newImg.bytes = bytes
            local dest = resultLayerFor(sprite, t.layer, layerCache)
            local pos = t.cel.position
            if sprite.newCel then
              sprite:newCel(dest, t.frame, newImg, pos)
            elseif dest.addCel then
              dest:addCel(t.frame, newImg)
            else
              -- fallback: substitui no próprio cel (API incompleta)
              t.cel.image = newImg
            end
          end
          rep.removed, rep.total, rep.percent = r.removed or 0, r.total or 0, r.percent or 0
          rep.warnings = r.warnings
          rep.elapsed = r.elapsed
        end
        reports[#reports + 1] = rep
      end
    end

    if analyzeOnly then
      job()
    else
      app.transaction("Remover fundo inteligente", job)
    end
  end)

  if progress then progress:close() end

  if not ok then
    app.alert("Erro durante a execução:\n" .. tostring(err))
    return
  end

  local title = analyzeOnly and "Análise do fundo (nada foi alterado)"
                              or "Remoção de fundo concluída"
  showResult(title, formatReport(reports, opts, os.clock() - t0))

  saveOpts(opts)
end

--------------------------------------------------------------------------------
-- Diálogo de opções
--------------------------------------------------------------------------------

local function showDialog(opts, defaultAction)
  local dlg = Dialog { title = "Removedor de Fundo Inteligente" }
  local pressed = nil

  dlg:combobox {
    id = "modeLabel",
    label = "Detecção:",
    options = MODE_LABELS,
    option = opts.modeLabel,
  }
  dlg:slider { id = "tolerance", label = "Tolerância:", min = 0, max = 128,
               value = opts.tolerance }
  dlg:slider { id = "soft", label = "Suavizar bordas:", min = 0, max = 64,
               value = opts.soft }
  dlg:check { id = "contiguous", text = "Apagar somente áreas conectadas às bordas",
              selected = opts.contiguous }
  dlg:check { id = "removeIslands", text = "Apagar também ilhas internas do fundo",
              selected = opts.removeIslands }

  dlg:separator { text = "Amostragem da borda" }
  dlg:slider { id = "sample", label = "Espessura:", min = 1, max = 32,
               value = opts.sample }
  dlg:check { id = "sideTop", text = "Topo", selected = opts.sideTop }
  dlg:check { id = "sideBottom", text = "Base", selected = opts.sideBottom }
  dlg:check { id = "sideLeft", text = "Esquerda", selected = opts.sideLeft }
  dlg:check { id = "sideRight", text = "Direita", selected = opts.sideRight }

  dlg:separator { text = "Onde aplicar" }
  dlg:combobox { id = "scopeLabel", label = "Escopo:", options = SCOPE_LABELS,
                 option = opts.scopeLabel }
  dlg:combobox { id = "layersLabel", label = "Camadas:", options = LAYER_LABELS,
                 option = opts.layersLabel }
  dlg:check { id = "perFrame", text = "Detectar o fundo em cada frame (recomendado)",
              selected = opts.perFrame }

  dlg:separator()
  dlg:button {
    id = "remove",
    text = "Remover fundo",
    focus = (defaultAction ~= "analyze"),
    onclick = function() pressed = "remove"; dlg:close() end,
  }
  dlg:button {
    id = "analyze",
    text = "Somente analisar",
    onclick = function() pressed = "analyze"; dlg:close() end,
  }
  dlg:button { id = "cancel", text = "Cancelar",
               onclick = function() pressed = "cancel"; dlg:close() end }

  dlg:show()
  local data = dlg.data
  if pressed == nil then
    pressed = (data and data.remove) and "remove"
              or ((data and data.analyze) and "analyze" or "cancel")
  end
  if pressed == "cancel" then return nil end

  local out = {}
  for k, v in pairs(opts) do out[k] = v end
  for k, v in pairs(data) do
    if k ~= "reve()
  local opts = currentOpts()
  local res, action = showDialog(opts, "remove")
  if res then runRemoval(res, action == "analyze") end
end

local function cmdAnalyze()
  local opts = currentOpts()
  runRemoval(opts, true)
end

local function cmdRepeat()
  local saved = (plugin and plugin.preferences and plugin.preferences.last)
  if not saved then
    cmdRemove()
    return
  end
  local opts = currentOpts()
  runRemoval(opts, false)
end

--------------------------------------------------------------------------------
-- init / exit
--------------------------------------------------------------------------------

function init(plugin)
  -- submenu no menu de contexto dos FRAMES da timeline
  plugin:newMenuGroup {
    id = "smartbg_frame_menu",
    title = "Fundo Inteligente",
    group = "frame_popup_reverse",
  }
  plugin:newCommand {
    id = "SmartBgRemover",
    title = "Remover fundo...",
    group = "smartbg_frame_menu",
    onclick = cmdRemove,
    onenabled = hasSprite,
  }
  plugin:newCommand {
    id = "SmartBgRemoverAnalyze",
    title = "Analisar fundo (sem alterar)",
    group = "smartbg_frame_menu",
    onclick = cmdAnalyze,
    onenabled = hasSprite,
  }
  plugin:newCommand {
    id = "SmartBgRemoverRepeat",
    title = "Repetir última remoção",
    group = "smartbg_frame_menu",
    onclick = cmdRepeat,
    onenabled = function() return hasSprite() and plugin.preferences.last ~= nil end,
  }

  -- mesmo conjunto no menu de contexto dos CELS
  plugin:newMenuGroup {
    id = "smartbg_cel_menu",
    title = "Fundo Inteligente",
    group = "cel_popup_new",
  }
  plugin:newCommand {
    id = "SmartBgRemoverCel",
    title = "Remover fundo...",
    group = "smartbg_cel_menu",
    onclick = cmdRemove,
    onenabled = hasSprite,
  }
  plugin:newCommand {
    id = "SmartBgRemoverAnalyzeCel",
    title = "Analisar fundo (sem alterar)",
    group = "smartbg_cel_menu",
    onclick = cmdAnalyze,
    onenabled = hasSprite,
  }
end

function exit(plugin)
  -- nada a limpar: os comandos/menus são removidos automaticamente
end
oup = "smartbg_cel_menu",
    onclick = cmdRemove,
    onenabled = hasSprite,
  }
  plugin:newCommand {
    id = "SmartBgRemoverAnalyzeCel",
    title = "Analisar fundo (sem alterar)",
    group = "smartbg_cel_menu",
    onclick = cmdAnalyze,
    onenabled = hasSprite,
  }
end

function exit(plugin)
  -- nada a limpar: os comandos/menus são removidos automaticamente
end
