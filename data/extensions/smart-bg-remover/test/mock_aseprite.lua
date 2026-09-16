--[[------------------------------------------------------------------------------
  mock_aseprite.lua - Ambiente falso do Aseprite para testar main.lua fora do
  Aseprite (usado pelo harness.py). Não faz parte da extensão instalada.

  Implementa o mínimo da API de script usada pela extensão:
    app, plugin, Dialog, Image, ColorMode, RangeType
------------------------------------------------------------------------------]]

RangeType = { EMPTY = 0, LAYERS = 1, FRAMES = 2, CELS = 3 }
ColorMode = { RGB = 1, GRAYSCALE = 2, GRAY = 2, INDEXED = 4, TILEMAP = 5 }

local _id = 0
local function newId()
  _id = _id + 1
  return _id
end

--------------------------------------------------------------------------------
-- Image
--------------------------------------------------------------------------------
local ImageMT = {}
ImageMT.__index = function(t, k)
  if k == "bytes" then
    return t._bytes
  elseif k == "rowStride" then
    return t.width * t._bpp
  elseif k == "bytesPerPixel" then
    return t._bpp
  elseif k == "spec" then
    return { width = t.width, height = t.height,
             colorMode = t._colorMode, bpp = t._bpp }
  end
  return rawget(t, k)
end
ImageMT.__newindex = function(t, k, v)
  if k == "bytes" then
    local need = t.width * t._bpp * t.height
    assert(#v == need, string.format("bytes: esperado %d, recebido %d", need, #v))
    t._bytes = v
  else
    rawset(t, k, v)
  end
end

function Image(specOrImage)
  local w, h, bpp, cm, bytes
  if specOrImage and specOrImage.width then
    w, h = specOrImage.width, specOrImage.height
    bpp = specOrImage.bpp or 4
    cm = specOrImage.colorMode or ColorMode.RGB
  else
    w, h, bpp, cm = specOrImage.width, specOrImage.height, 4, ColorMode.RGB
  end
  if specOrImage and specOrImage._bytes then
    bytes = specOrImage._bytes
  else
    bytes = string.rep("\0", w * bpp * h)
  end
  local img = setmetatable({
    id = newId(), width = w, height = h, _bpp = bpp, _colorMode = cm,
    _bytes = bytes,
  }, ImageMT)
  return img
end

function makeImage(w, h, bytes, bpp, cm)
  return Image { width = w, height = h, bpp = bpp or 4,
                 colorMode = cm or ColorMode.RGB, _bytes = bytes }
end

--------------------------------------------------------------------------------
-- Cel / Layer / Sprite
--------------------------------------------------------------------------------
local function makeCel(layer, frame, image)
  local cel = { id = newId(), layer = layer, frameNumber = frame, _image = image }
  function cel:image_get() return self._image end
  local mt = {
    __index = function(t, k)
      if k == "image" then return t._image end
      if k == "frame" then return { frameNumber = t.frameNumber } end
      return nil
    end,
    __newindex = function(t, k, v)
      if k == "image" then
        t._image = v
        if MOCK_LOG then
          MOCK_LOG.imagesReplaced = (MOCK_LOG.imagesReplaced or 0) + 1
        end
      else
        rawset(t, k, v)
      end
    end,
  }
  return setmetatable(cel, mt)
end

local function makeLayer(name, opts)
  opts = opts or {}
  local layer = {
    id = newId(),
    name = name,
    isImage = (opts.isImage ~= false),
    isGroup = (opts.isGroup == true),
    isVisible = (opts.isVisible ~= false),
    isEditable = (opts.isEditable ~= false),
    isTilemap = (opts.isTilemap == true),
    layers = {},
    _cels = {},
  }
  function layer:cel(frame)
    return self._cels[frame]
  end
  function layer:addCel(frame, image)
    local cel = makeCel(self, frame, image)
    self._cels[frame] = cel
    return cel
  end
  return layer
end

local function makeSprite(w, h, opts)
  opts = opts or {}
  local sprite = {
    id = newId(),
    width = w,
    height = h,
    colorMode = opts.colorMode or ColorMode.RGB,
    frames = {},
    layers = {},
    palettes = opts.palettes or { {} },
    transparentColor = opts.transparentColor or 0,
    filename = opts.filename or "mock.aseprite",
  }
  function sprite:addLayer(name, o)
    local l = makeLayer(name, o)
    self.layers[#self.layers + 1] = l
    return l
  end
  function sprite:newLayer()
    return self:addLayer("Layer")
  end
  function sprite:newCel(layer, frame, image, pos)
    local fn = type(frame) == "table" and frame.frameNumber or frame
    return layer:addCel(fn, image)
  end
  function sprite:addFrame()
    local f = { frameNumber = #self.frames + 1 }
    self.frames[#self.frames + 1] = f
    return f
  end
  return sprite
end

--------------------------------------------------------------------------------
-- app
--------------------------------------------------------------------------------
MOCK_LOG = { alerts = {}, transactions = {}, printed = {} }

app = {
  activeSprite = nil,
  activeLayer = nil,
  activeFrame = nil,
  range = { type = RangeType.EMPTY, frames = {}, cels = {} },
  isUIAvailable = true,

  transaction = function(label, fn)
    if type(label) == "function" then fn = label; label = "tx" end
    MOCK_LOG.transactions[#MOCK_LOG.transactions + 1] = label
    return fn()
  end,
  refresh = function() end,
  alert = function(msg)
    MOCK_LOG.alerts[#MOCK_LOG.alerts + 1] = tostring(msg)
    print("[alert] " .. tostring(msg))
  end,
  pixelColor = {},
}

function print(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  local line = table.concat(t, "\t")
  MOCK_LOG.printed[#MOCK_LOG.printed + 1] = line
  io.stderr:write(line .. "\n")
end

--------------------------------------------------------------------------------
-- Dialog (falso: guarda os widgets e devolve os valores padrão)
--------------------------------------------------------------------------------
local DialogMT = {}
DialogMT.__index = DialogMT

local function newDialog(title)
  local d = {
    title = (type(title) == "table" and (title.title or "")) or tostring(title or ""),
    widgets = {},
    data = {},
    _closed = false,
  }
  setmetatable(d, DialogMT)
  return d
end

local function addWidget(self, kind, args)
  args = args or {}
  local w = { kind = kind }
  for k, v in pairs(args) do w[k] = v end
  self.widgets[#self.widgets + 1] = w
  if w.id then
    if kind == "check" then
      self.data[w.id] = (w.selected == true)
    elseif kind == "slider" then
      self.data[w.id] = w.value
    elseif kind == "combobox" then
      self.data[w.id] = w.option
    elseif kind == "button" then
      self.data[w.id] = false
    else
      self.data[w.id] = w.text
    end
  end
  return w
end

function DialogMT:label(a) return addWidget(self, "label", a) end
function DialogMT:button(a) return addWidget(self, "button", a) end
function DialogMT:check(a) return addWidget(self, "check", a) end
function DialogMT:radio(a) return addWidget(self, "radio", a) end
function DialogMT:slider(a) return addWidget(self, "slider", a) end
function DialogMT:combobox(a) return addWidget(self, "combobox", a) end
function DialogMT:entry(a) return addWidget(self, "entry", a) end
function DialogMT:number(a) return addWidget(self, "number", a) end
function DialogMT:separator(a) return addWidget(self, "separator", a) end
function DialogMT:newrow() end
function DialogMT:modify(a)
  if a and a.id then
    for _, w in ipairs(self.widgets) do
      if w.id == a.id then
        for k, v in pairs(a) do if k ~= "id" then w[k] = v end end
      end
    end
    if a.text ~= nil then self.data[a.id] = a.text end
  end
end
function DialogMT:repaint() end
function DialogMT:close() self._closed = true end
function DialogMT:show(a)
  -- simula o clique no botão pedido por MOCK_NEXT_BUTTON (padrão: "remove")
  local btn = MOCK_NEXT_BUTTON or "remove"
  local found = false
  for _, w in ipairs(self.widgets) do
    if w.kind == "button" and w.id == btn then
      self.data[w.id] = true
      found = true
      if w.onclick then w.onclick() end
      break
    end
  end
  if not found then
    -- se não achou, marca o primeiro botão que não seja cancelar
    for _, w in ipairs(self.widgets) do
      if w.kind == "button" and w.id ~= "cancel" then
        self.data[w.id] = true
        if w.onclick then w.onclick() end
        break
      end
    end
  end
  return self
end

Dialog = function(title) return newDialog(title) end

--------------------------------------------------------------------------------
-- plugin
--------------------------------------------------------------------------------
MOCK_COMMANDS = {}
MOCK_GROUPS = {}

plugin = {
  name = "smart-bg-remover",
  path = "",
  preferences = {},

  newCommand = function(self, args)
    assert(args and args.id, "newCommand sem id")
    MOCK_COMMANDS[args.id] = args
    MOCK_COMMANDS[#MOCK_COMMANDS + 1] = args
    return args
  end,
  deleteCommand = function(self, id) MOCK_COMMANDS[id] = nil end,
  newMenuGroup = function(self, args)
    assert(args and args.id, "newMenuGroup sem id")
    MOCK_GROUPS[args.id] = args
    return args
  end,
  newMenuSeparator = function(self, args) return args end,
}

return {
  makeSprite = makeSprite,
  makeLayer = makeLayer,
  makeImage = makeImage,
  Image = Image,
}
