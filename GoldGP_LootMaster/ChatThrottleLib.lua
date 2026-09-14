-- ============================================================================
-- ChatThrottleLib.lua  (streamlined version for GoldGP_LootMaster)
-- ============================================================================
-- Упрощённая адаптация ChatThrottleLib by Mikk (BSD-licensed, из AceComm-3.0).
-- Ограничивает исходящий трафик SendAddonMessage, чтобы не получить кик
-- от сервера за превышение rate-limit (~800 cps / 4KB burst в WotLK 3.3.5a).
--
-- API:
--   ChatThrottleLib:SendAddonMessage(prio, prefix, msg, distribution, target)
--     prio: "ALERT" | "NORMAL" | "BULK"
--
-- Если глобальный ChatThrottleLib уже существует (AceComm загружен другим аддоном),
-- этот файл не переопределяет его — используем существующий.
-- ============================================================================

local CTL_VERSION = 22

-- Если уже загружен более свежий/равный — выходим
if _G.ChatThrottleLib then
  if _G.ChatThrottleLib.version and _G.ChatThrottleLib.version >= CTL_VERSION then
    return
  end
end

local ChatThrottleLib = {}
_G.ChatThrottleLib = ChatThrottleLib
ChatThrottleLib.version = CTL_VERSION

-- ============================================================================
-- КОНСТАНТЫ
-- ============================================================================
ChatThrottleLib.MAX_CPS = 800       -- bytes per second sustained
ChatThrottleLib.BURST   = 4000      -- max burst buffer (bytes)
ChatThrottleLib.MSG_OVERHEAD = 40   -- per-message overhead

ChatThrottleLib.MIN_FPS = 20        -- reduce CPS to half if FPS drops below this

-- ============================================================================
-- ЛОКАЛЬНЫЕ ССЫЛКИ (для скорости)
-- ============================================================================
local GetTime = GetTime
local GetFramerate = GetFramerate
local t_insert = table.insert
local t_remove = table.remove
local math_min = math.min
local math_max = math.max
local strlen = string.len
local tostring = tostring

-- ============================================================================
-- ОЧЕРЕДИ ПО ПРИОРИТЕТАМ
-- ============================================================================
-- Pipe: простая FIFO-очередь (массив сообщений).
-- Prio: { queue = { msg1, msg2, ... }, avail = bytes, nTotalSent = 0 }

local Prio = {
  ALERT  = { queue = {}, avail = 0, nTotalSent = 0 },
  NORMAL = { queue = {}, avail = 0, nTotalSent = 0 },
  BULK   = { queue = {}, avail = 0, nTotalSent = 0 },
}
ChatThrottleLib.Prio = Prio

-- Пул сообщений (переиспользование таблиц — снижает GC pressure)
local MsgBin = setmetatable({}, { __mode = "k" })

local function NewMsg()
  local msg = next(MsgBin)
  if msg then
    MsgBin[msg] = nil
    return msg
  end
  return {}
end

local function DelMsg(msg)
  msg[1] = nil; msg[2] = nil; msg[3] = nil; msg[4] = nil
  msg.f = nil
  msg.nSize = nil
  msg.callbackFn = nil
  msg.callbackArg = nil
  MsgBin[msg] = true
end

-- ============================================================================
-- ОБНОВЛЕНИЕ ДОСТУПНОЙ ПОЛОСЫ
-- ============================================================================
ChatThrottleLib.avail = 0
ChatThrottleLib.LastAvailUpdate = 0
ChatThrottleLib.bQueueing = false
ChatThrottleLib.bChoking = false

function ChatThrottleLib:UpdateAvail()
  local now = GetTime()
  if self.LastAvailUpdate == 0 then self.LastAvailUpdate = now end
  local newavail = self.MAX_CPS * (now - self.LastAvailUpdate)
  local avail = self.avail

  -- Если FPS низкий — режем трафик вдвое
  local fps = GetFramerate and GetFramerate() or 60
  if fps < self.MIN_FPS then
    avail = math_min(self.MAX_CPS, avail + newavail * 0.5)
    self.bChoking = true
  else
    avail = math_min(self.BURST, avail + newavail)
    self.bChoking = false
  end

  avail = math_max(avail, -(self.MAX_CPS * 2))  -- не молчим дольше 2 сек
  self.avail = avail
  self.LastAvailUpdate = now
  return avail
end

-- ============================================================================
-- ОТПРАВКА ОДНОГО СООБЩЕНИЯ (с учётом bypass-флага)
-- ============================================================================
local bMyTraffic = false

local function RealSend(msg)
  bMyTraffic = true
  msg.f(msg[1], msg[2], msg[3], msg[4])
  bMyTraffic = false
end

-- ============================================================================
-- РАЗГРУЗКА ОЧЕРЕДИ
-- ============================================================================
local function Despool(PrioObj)
  local q = PrioObj.queue
  while q[1] and PrioObj.avail >= q[1].nSize do
    local msg = t_remove(q, 1)
    PrioObj.avail = PrioObj.avail - msg.nSize
    RealSend(msg)
    PrioObj.nTotalSent = PrioObj.nTotalSent + msg.nSize
    if msg.callbackFn then
      local ok, err = pcall(msg.callbackFn, msg.callbackArg)
      if not ok then
        -- тихо игнорируем ошибку callback'а — не ронять очередь
      end
    end
    DelMsg(msg)
  end
end

-- ============================================================================
-- OnUpdate — главный цикл
-- ============================================================================
ChatThrottleLib.OnUpdateDelay = 0

function ChatThrottleLib.OnUpdate(_, delay)
  local self = ChatThrottleLib

  self.OnUpdateDelay = self.OnUpdateDelay + delay
  if self.OnUpdateDelay < 0.08 then return end  -- 12.5 раз/сек
  self.OnUpdateDelay = 0

  self:UpdateAvail()
  if self.avail < 0 then return end  -- кто-то перебирает — ждём

  -- Считаем приоритеты с очередями
  local n = 0
  for _, p in pairs(self.Prio) do
    if p.queue[1] or p.avail < 0 then n = n + 1 end
  end

  if n < 1 then
    -- Все очереди пусты — собираем остатки avail, выключаем frame
    for _, p in pairs(self.Prio) do
      self.avail = self.avail + p.avail
      p.avail = 0
    end
    self.bQueueing = false
    if self.Frame then self.Frame:Hide() end
    return
  end

  -- Делим доступную полосу поровну между активными приоритетами
  local share = self.avail / n
  self.avail = 0

  for _, p in pairs(self.Prio) do
    if p.queue[1] or p.avail < 0 then
      p.avail = p.avail + share
      if p.queue[1] and p.avail >= p.queue[1].nSize then
        Despool(p)
      end
    end
  end
end

-- ============================================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================================

function ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target)
  if not prio or not prefix or not text or not chattype or not self.Prio[prio] then
    error('Usage: ChatThrottleLib:SendAddonMessage("{ALERT|NORMAL|BULK}", prefix, text, chattype[, target])', 2)
  end

  local nSize = strlen(prefix) + 1 + strlen(text) + self.MSG_OVERHEAD
  if nSize > 255 then
    -- Blizzard limit — отрезаем (не должно случаться в LootMaster)
    return
  end

  -- Если очереди пусты и есть полоса — отправляем сразу
  if not self.bQueueing and nSize < self:UpdateAvail() then
    self.avail = self.avail - nSize
    bMyTraffic = true
    _G.SendAddonMessage(prefix, text, chattype, target)
    bMyTraffic = false
    self.Prio[prio].nTotalSent = self.Prio[prio].nTotalSent + nSize
    return
  end

  -- Иначе — в очередь
  local msg = NewMsg()
  msg.f = _G.SendAddonMessage
  msg[1] = prefix
  msg[2] = text
  msg[3] = chattype
  msg[4] = target  -- может быть nil
  msg.nSize = nSize
  t_insert(self.Prio[prio].queue, msg)

  self.bQueueing = true
  if self.Frame then self.Frame:Show() end
end

-- SendChatMessage — обёртка для совместимости (если аддону нужно в обычный чат)
function ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination)
  if not prio or not text or not self.Prio[prio] then
    error('Usage: ChatThrottleLib:SendChatMessage("{ALERT|NORMAL|BULK}", prefix, text[, chattype[, language[, destination]]])', 2)
  end
  local nSize = strlen(text) + self.MSG_OVERHEAD
  if nSize > 255 then return end

  if not self.bQueueing and nSize < self:UpdateAvail() then
    self.avail = self.avail - nSize
    bMyTraffic = true
    _G.SendChatMessage(text, chattype or "SAY", language, destination)
    bMyTraffic = false
    self.Prio[prio].nTotalSent = self.Prio[prio].nTotalSent + nSize
    return
  end

  local msg = NewMsg()
  msg.f = _G.SendChatMessage
  msg[1] = text
  msg[2] = chattype or "SAY"
  msg[3] = language
  msg[4] = destination
  msg.nSize = nSize
  t_insert(self.Prio[prio].queue, msg)

  self.bQueueing = true
  if self.Frame then self.Frame:Show() end
end

-- ============================================================================
-- ИНИЦИАЛИЗАЦИЯ
-- ============================================================================
function ChatThrottleLib:Init()
  if self.Frame then return end
  self.Frame = CreateFrame("Frame")
  self.Frame:Hide()
  self.Frame:SetScript("OnUpdate", self.OnUpdate)
  self.LastAvailUpdate = GetTime()
end

ChatThrottleLib:Init()

-- ============================================================================
-- Статистика (для отладки через /run ChatThrottleLib:Stats())
-- ============================================================================
function ChatThrottleLib:Stats()
  local total_queued = 0
  for _, p in pairs(self.Prio) do
    total_queued = total_queued + #p.queue
  end
  return {
    avail = math.floor(self.avail),
    queued = total_queued,
    queueing = self.bQueueing,
    choking = self.bChoking,
    alert_sent = self.Prio.ALERT.nTotalSent,
    normal_sent = self.Prio.NORMAL.nTotalSent,
    bulk_sent = self.Prio.BULK.nTotalSent,
  }
end
