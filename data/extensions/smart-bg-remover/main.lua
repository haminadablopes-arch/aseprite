--[[------------------------------------------------------------------------------
  main.lua - Smart Background Remover v0.7.0

  Current flow:
  - Only 2 layers: Original (hidden after processing) + "Original - removed" (reused)
  - Live canvas preview of ALL selected frames (batch processed in ~50ms
    slices via Timer; slider drag re-processes only the 1st frame)
  - All parameters in the preview: Detection, Tolerance, Soften edges,
    contiguous, islands, border sampling (thickness + sides) and perFrame
  - v0.6.1: simplified menu - a single "Remove Background (Ctrl+Shift+B)"
    item directly on the frames/cels popup (no submenu); "Repeat" removed
  - After confirming, applies to all selected frames with no report dialog
  - Ctrl+Shift+B opens the preview directly; single undo with Ctrl+Z
  - v0.7.0: fully translated to English (Portuguese labels/suffixes from
    older versions are still recognized for compatibility)

  API used:
  * plugin:newMenuGroup / newCommand
  * plugin.preferences
  * cel.image = newImage (ReplaceImage)
  * sprite:newLayer / deleteLayer / newCel / deleteCel
  * Dialog with onchange for instant preview
------------------------------------------------------------------------------]]

local bgcore = require("lib.bgcore")

--------------------------------------------------------------------------------
-- Constants and default options
--------------------------------------------------------------------------------

local PROCESSED_SUFFIX = " - removed"
local LEGACY_PROCESSED_SUFFIX = " - removido" -- pt-BR layers from older versions
local BACKUP_SUFFIX = " (backup)" -- for compatibility with old versions

local MODE_LABELS = {
  "Automatic",
  "Solid color",
  "Repeating pattern",
  "Gradient",
  "Color set",
  "Edge flood",
}
local MODE_BY_LABEL = {
  ["Automatic"] = "auto",
  ["Solid color"] = "flat",
  ["Repeating pattern"] = "tile",
  ["Gradient"] = "gradient",
  ["Color set"] = "set",
  ["Edge flood"] = "flood",
  -- legacy Portuguese labels (saved preferences from older versions)
  ["Automático"] = "auto",
  ["Cor sólida"] = "flat",
  ["Padrão repetitivo"] = "tile",
  ["Conjunto de cores"] = "set",
  ["Inundação pelas bordas"] = "flood",
}
local LABEL_BY_MODE = {}
for k, v in pairs(MODE_BY_LABEL) do LABEL_BY_MODE[v] = k end

local SCOPE_LABELS = { "Selected frames", "Current frame", "All frames" }
local SCOPE_BY_LABEL = {
  ["Selected frames"] = "selected",
  ["Current frame"] = "current",
  ["All frames"] = "all",
  -- legacy Portuguese labels
  ["Frames selecionados"] = "selected",
  ["Frame atual"] = "current",
  ["Todos os frames"] = "all",
}
local LABEL_BY_SCOPE = {}
for k, v in pairs(SCOPE_BY_LABEL) do LABEL_BY_SCOPE[v] = k end

local LAYER_LABELS = { "Active layer", "All layers", "Visible layers" }
local LAYERS_BY_LABEL = {
  ["Active layer"] = "active",
  ["All layers"] = "all",
  ["Visible layers"] = "visible",
  -- legacy Portuguese labels
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
  modeLabel = "Automatic",
  scopeLabel = "Selected frames",
  layersLabel = "Active layer",
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
-- Image context
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
-- Layer helpers
--------------------------------------------------------------------------------

local function isProcessedLayer(layer)
  if not layer or not layer.name then return false end
  return layer.name:sub(-#PROCESSED_SUFFIX) == PROCESSED_SUFFIX
      or layer.name:sub(-#LEGACY_PROCESSED_SUFFIX) == LEGACY_PROCESSED_SUFFIX
end

local function isBackupLayer(layer)
  if not layer or not layer.name then return false end
  return layer.name:find("%(backup%)$") ~= nil
end

local function findProcessedLayer(sprite, sourceLayer)
  if not sourceLayer then return nil end
  if isProcessedLayer(sourceLayer) then return sourceLayer end
  local expected = sourceLayer.name .. PROCESSED_SUFFIX
  local expectedLegacy = sourceLayer.name .. LEGACY_PROCESSED_SUFFIX
  local function walk(layers)
    for _, l in ipairs(layers) do
      if l.name == expected or l.name == expectedLegacy then return l end
      if l.isGroup then
        local f = walk(l.layers)
        if f then return f end
      end
    end
    return nil
  end
  return walk(sprite.layers)
end

-- Must be called inside a transaction
local function getOrCreateProcessedLayer(sprite, sourceLayer)
  if isProcessedLayer(sourceLayer) then return sourceLayer end
  local existing = findProcessedLayer(sprite, sourceLayer)
  if existing then return existing end
  local newLayer = sprite:newLayer()
  newLayer.name = sourceLayer.name .. PROCESSED_SUFFIX
  newLayer.isVisible = true
  -- tries to place right above the original
  local ok = pcall(function()
    newLayer.stackIndex = sourceLayer.stackIndex + 1
  end)
  if not ok then
    -- fallback: stays at the top
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
  local imageFrames = {} -- image id -> all cels using it (linked frames)
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
  -- sort by frame to get the first one
  table.sort(targets, function(a,b) return a.frame < b.frame end)
  return targets, frames, layers, imageFrames
end

--------------------------------------------------------------------------------
-- Final processing (no report dialog)
--------------------------------------------------------------------------------

local function runFinalRemoval(sprite, targets, opts, sharedModelForFirst, imageFrames)
  local algo = toAlgoOpts(opts)
  local sharedModel = nil
  if not opts.perFrame then
    sharedModel = sharedModelForFirst
  end

  local ok, err = pcall(function()
    app.transaction("Remove smart background", function()
      -- maps source -> processed
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
          -- nothing to do
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
            -- propagate to linked cels (same image, any layer) =>
            -- animation without holes
            local list = imageFrames and imageFrames[t.cel.image.id]
            if list then
              for _, e in ipairs(list) do
                if not (e.frame == t.frame and e.layer == t.layer) then
                  local dest2 = getOrCreateProcessedLayer(sprite, e.layer)
                  processedMap[e.layer] = dest2
                  local cel2 = dest2:cel(e.frame)
                  if cel2 then
                    cel2.image = newImg
                  else
                    sprite:newCel(dest2, e.frame, newImg, e.cel.position)
                  end
                end
              end
            end
          end
        end
      end

      -- hide originals, show processed ones
      for src, proc in pairs(processedMap) do
        src.isVisible = false
        proc.isVisible = true
      end
      -- also guarantees that layers which already had a processed layer but were not touched in this run (e.g. only 1 frame) still get the original hidden if the processed layer has a cel in the frame
      -- already handled above
    end)
  end)

  if not ok then
    app.alert("Error during execution:\n" .. tostring(err))
    return false
  end

  app.refresh()
  return true
end

--------------------------------------------------------------------------------
-- Live preview on canvas
--------------------------------------------------------------------------------

local function showPreviewDialog()
  local sprite = app.activeSprite
  if not sprite then
    app.alert("Open a sprite first.")
    return
  end

  local initialOpts = currentOpts()
  local targets, frames, layers, imageFrames = collectTargets(sprite, initialOpts)
  if #targets == 0 then
    app.alert("No cel found for the chosen scope.\nTip: select frames on the timeline before using the command.")
    return
  end

  -- first selected frame = first of the sorted list
  local firstTarget = targets[1]
  local sourceLayer = firstTarget.layer

  -- saves states for restoration on cancel
  local originalSourceVisible = sourceLayer.isVisible
  local processedLayer = findProcessedLayer(sprite, sourceLayer)
  local createdNewLayer = (processedLayer == nil)
  local originalProcessedVisible = nil
  if processedLayer then
    originalProcessedVisible = processedLayer.isVisible
  end

  -- pre-preview state of EVERY cel that gets touched (to restore everything on cancel).
  -- Memory strategy: only caches bytes when the pre-existing content differs
  -- from the original layer (re-run) and within a cap (PREVIEW_BYTES_BUDGET); beyond
  -- the cap, restores from the original (which is not modified during preview). Otherwise,
  -- N 2048x2048 frames in a re-run = ~GBs of RAM just to be able to cancel.
  local PREVIEW_BYTES_BUDGET = 256 * 1024 * 1024 -- 256MB
  local previewBytes = 0
  local previewCels = {}
  local function recordPreviewCel(frameNumber, srcCel)
    if previewCels[frameNumber] then return end
    local cel = processedLayer and processedLayer:cel(frameNumber)
    local st = { existed = (cel and cel.image ~= nil), srcCel = srcCel }
    if st.existed then
      if srcCel and srcCel.image then
        -- identical to the original? restoring from it is enough => zero caching
        if cel.image.bytes ~= srcCel.image.bytes then
          previewBytes = previewBytes + #cel.image.bytes
          if previewBytes <= PREVIEW_BYTES_BUDGET then
            st.bytes = cel.image.bytes
            st.spec = cel.image.spec
          end
        end
      else
        -- no source to restore from later: caching is mandatory
        st.bytes = cel.image.bytes
        st.spec = cel.image.spec
      end
    end
    previewCels[frameNumber] = st
  end

  -- writes the preview image into a frame of the processed layer (transaction only as fallback)
  local function writePreviewCel(frameNumber, srcCel, newImg)
    recordPreviewCel(frameNumber, srcCel)
    local ok = pcall(function()
      local cel = processedLayer:cel(frameNumber)
      if cel then
        cel.image = newImg
      else
        sprite:newCel(processedLayer, frameNumber, newImg, srcCel.position)
      end
    end)
    if not ok then
      pcall(function()
        app.transaction("Background Preview", function()
          local cel = processedLayer:cel(frameNumber)
          if cel then
            cel.image = newImg
          else
            sprite:newCel(processedLayer, frameNumber, newImg, srcCel.position)
          end
        end)
      end)
    end
  end

  -- applies to the target frame + propagates to linked cels (same image,
  -- any layer — same rule as runFinalRemoval)
  local function applyPreviewImage(t, newImg)
    writePreviewCel(t.frame, t.cel, newImg)
    local list = imageFrames and imageFrames[t.cel.image.id]
    if list then
      for _, e in ipairs(list) do
        if not (e.frame == t.frame and e.layer == t.layer) then
          writePreviewCel(e.frame, e.cel, newImg)
        end
      end
    end
  end

  -- prepares preview: creates layer if needed and guarantees the initial cel
  local function preparePreviewTx()
    app.transaction("Prepare Background Preview", function()
      if not processedLayer then
        processedLayer = getOrCreateProcessedLayer(sprite, sourceLayer)
      end
      -- records the pre-preview state of all targets (before creating placeholders)
      for _, t in ipairs(targets) do
        recordPreviewCel(t.frame, t.cel)
      end
      -- guarantees a cel in the first frame (copies original as placeholder)
      local existing = processedLayer:cel(firstTarget.frame)
      if not existing then
        local srcImg = firstTarget.cel.image
        local copyImg = Image(srcImg.spec)
        copyImg.bytes = srcImg.bytes
        sprite:newCel(processedLayer, firstTarget.frame, copyImg, firstTarget.cel.position)
      end
      sourceLayer.isVisible = false
      processedLayer.isVisible = true
      -- focuses on the preview frame
      if app.activeFrame and app.activeFrame.frameNumber ~= firstTarget.frame then
        app.activeFrame = sprite.frames[firstTarget.frame]
      end
    end)
  end

  preparePreviewTx()
  app.refresh()

  -- preview state
  local lastPreviewOpts = nil
  local dialogOpen = true
  local batchGen = 0      -- batch generation (changes on every updateAllPreviews)
  local batchTimer = nil  -- active batch Timer (if the API has one)

  local dlg = Dialog{ title = "Background Removal Preview (Ctrl+Shift+B)" }

  local function getDlgOpts()
    local data = dlg.data
    local o = {}
    for k, v in pairs(initialOpts) do o[k] = v end
    o.modeLabel = data.modeLabel or o.modeLabel
    o.tolerance = data.tolerance or o.tolerance
    o.soft = data.soft or o.soft
    -- booleans: explicit nil check (false is a valid value)
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

  -- computes model + processed bytes for one target.
  -- when perFrame is off, reuses the 1st frame's model (shared.m)
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

  -- instant preview: first frame only. While DRAGGING, throttles to
  -- ~10/s — on large frames each round costs hundreds of ms;
  -- the final value is always guaranteed by onrelease (updateAllPreviews)
  local lastQuickMs = 0
  local function updatePreview()
    local now = os.clock() * 1000
    if now - lastQuickMs < 100 then return end
    lastQuickMs = now

    local curOpts = getDlgOpts()
    lastPreviewOpts = curOpts
    local algo = toAlgoOpts(curOpts)

    local ok, img, ctx, model, newBytes, rep = pcall(computeTarget, firstTarget, curOpts, algo, {})
    if not ok then
      dlg:modify{ id = "status", text = "Preview error: " .. tostring(img) }
      return
    end

    if newBytes then
      applyPreviewImage(firstTarget, toPreviewImage(img, ctx, newBytes))
      local pct = rep and rep.percent or 0
      dlg:modify{ id = "status", text = string.format("Preview frame %d: %s - %.1f%% removed - %d/%d selected frames", firstTarget.frame, model.type, pct, #targets, #frames) }
    else
      dlg:modify{ id = "status", text = string.format("Preview: %s - nothing to remove", model.description or model.type) }
    end

    if app.refresh then app.refresh() end
    dlg:repaint()
  end

  -- full preview: processes ALL selected frames in ~50ms slices,
  -- giving control back to the UI between slices (Timer) to avoid freezing
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
          finish("Preview error: " .. tostring(img))
          return
        end
        if newBytes then
          applyPreviewImage(t, toPreviewImage(img, ctx, newBytes))
        else
          -- nothing detected: shows the original itself (avoids an empty frame in the animation)
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
          dlg:modify{ id = "status", text = string.format("Updating previews... %d/%d frames", i - 1, total) }
        end
        -- in Timer mode, gives control back to the UI every ~50ms;
        -- without a Timer (mock/tests), processes everything at once
        if batchTimer and (os.clock() - t0) > 0.05 then
          return
        end
      end
      finish(string.format("Previews: %d/%d frames - %s - %.1f%% on frame %d%s",
        total, total, firstType or "?", firstPct, firstTarget.frame,
        curOpts.perFrame and "" or " (shared model)"))
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

  -- widgets: sliders update the 1st frame while dragging (onchange) and the
  -- whole batch on release (onrelease); checkboxes/combobox trigger the full batch
  dlg:combobox{
    id = "modeLabel",
    label = "Detection:",
    options = MODE_LABELS,
    option = initialOpts.modeLabel,
    onchange = updateAllPreviews,
  }
  dlg:slider{
    id = "tolerance",
    label = "Tolerance:",
    min = 0, max = 128,
    value = initialOpts.tolerance,
    onchange = updatePreview,
    onrelease = updateAllPreviews,
  }
  dlg:slider{
    id = "soft",
    label = "Soften edges:",
    min = 0, max = 64,
    value = initialOpts.soft,
    onchange = updatePreview,
    onrelease = updateAllPreviews,
  }
  dlg:check{
    id = "contiguous",
    text = "Erase only areas connected to the borders",
    selected = initialOpts.contiguous,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "removeIslands",
    text = "Also erase internal islands",
    selected = initialOpts.removeIslands,
    onchange = updateAllPreviews,
  }
  dlg:separator{ text = "Border sampling" }
  dlg:slider{
    id = "sample",
    label = "Thickness:",
    min = 1, max = 32,
    value = initialOpts.sample,
    onchange = updatePreview,
    onrelease = updateAllPreviews,
  }
  dlg:check{
    id = "sideTop",
    text = "Top",
    selected = initialOpts.sideTop,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "sideBottom",
    text = "Bottom",
    selected = initialOpts.sideBottom,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "sideLeft",
    text = "Left",
    selected = initialOpts.sideLeft,
    onchange = updateAllPreviews,
  }
  dlg:check{
    id = "sideRight",
    text = "Right",
    selected = initialOpts.sideRight,
    onchange = updateAllPreviews,
  }
  -- perFrame: affects the preview (shared model vs per frame) and the final confirmation
  dlg:check{
    id = "perFrame",
    text = "Detect background in each frame on confirm",
    selected = initialOpts.perFrame,
    onchange = updateAllPreviews,
  }
  dlg:separator{ text = "Live preview on canvas" }
  dlg:label{ id = "status", text = "Processing preview of " .. #targets .. " frame(s)..." }
  dlg:separator()
  dlg:button{ id = "play", text = "▶ Play animation", onclick = function()
    pcall(function() app.command.PlayAnimation() end)
  end }
  dlg:button{ id = "confirm", text = "Apply to all", focus = true }
  dlg:button{ id = "cancel", text = "Cancel" }

  -- first preview: 1st frame + full batch (in slices, if Timer is available)
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
    -- shared model re-analyzed from the 1st frame with the final options
    -- (guarantees consistency even if a batch was still pending)
    local sharedModel = nil
    if not finalOpts.perFrame then
      local img = firstTarget.cel.image
      local ctx = ctxFor(img, sprite)
      pcall(function() sharedModel = bgcore.analyze(img.bytes, ctx, toAlgoOpts(finalOpts)) end)
    end
    -- aplica a todos
    runFinalRemoval(sprite, targets, finalOpts, sharedModel, imageFrames)
  else
    -- cancel: restores the pre-preview state of ALL touched cels
    app.transaction("Cancel background preview", function()
      -- restaura visibilidade original
      if sourceLayer then
        sourceLayer.isVisible = originalSourceVisible
      end
      if createdNewLayer then
        -- removes the layer created only for preview
        if processedLayer then
          -- checks whether it still exists
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
          -- restores each touched cel, in order:
          --   1. cached bytes           => exact restore
          --   2. cel on the original    => restores a copy of the original (fallback)
          --   3. existed without source => keeps the preview (doesn't destroy content)
          --   4. didn't exist           => removes the cel created only for the preview
          for frameNumber, st in pairs(previewCels) do
            local cel = processedLayer:cel(frameNumber)
            if st.bytes and st.spec then
              if cel then
                local restoreImg = Image(st.spec)
                restoreImg.bytes = st.bytes
                cel.image = restoreImg
              end
            elseif st.srcCel and st.srcCel.image then
              if cel then
                local srcImg = Image(st.srcCel.image.spec)
                srcImg.bytes = st.srcCel.image.bytes
                cel.image = srcImg
                pcall(function() cel.position = st.srcCel.position end)
              end
            elseif not st.existed then
              if cel then
                pcall(function()
                  sprite:deleteCel(processedLayer, frameNumber)
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
-- Legacy commands adapted to the new flow
--------------------------------------------------------------------------------

local function hasSprite()
  return app.activeSprite ~= nil
end

local function cmdPreview()
  showPreviewDialog()
end

-- (v0.6.1) the "Repeat last removal" command (cmdRepeat) was removed:
-- the preview opens with the options saved from the last run, so repeating
-- no longer warrants its own menu item.

--------------------------------------------------------------------------------
-- init / exit
--------------------------------------------------------------------------------

function init(plugin)
  -- v0.6.1: a single command, directly on the context menu (no submenu).
  -- Behavior is contextual: the command reads the timeline selection
  -- (frames or cels) and acts on it. IDs preserved to keep
  -- keys.aseprite-keys (Ctrl+Shift+B) and custom shortcuts working.

  -- context menu of timeline FRAMES
  plugin:newCommand{
    id = "SmartBgRemoverPreview",
    title = "Remove Background (Ctrl+Shift+B)",
    group = "frame_popup_reverse",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }

  -- context menu of CELS
  plugin:newCommand{
    id = "SmartBgRemoverCelPreview",
    title = "Remove Background (Ctrl+Shift+B)",
    group = "cel_popup_new",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }

  -- global command for the shortcut (appears under Edit > Keyboard Shortcuts)
  plugin:newCommand{
    id = "SmartBgRemoverGlobalPreview",
    title = "Remove Background (Ctrl+Shift+B)",
    group = "edit_new",
    onclick = cmdPreview,
    onenabled = hasSprite,
  }
end

function exit(plugin)
end
