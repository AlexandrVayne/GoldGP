-- GoldGP_Log.lua

local Addon = GoldGP
local Log = {}
Addon.Log = Log

-- Уровни
local LEVELS = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }
local LEVEL_NAMES = { "ERROR", "WARN", "INFO", "DEBUG" }

-- Текущий уровень (если debug=true — DEBUG, иначе INFO)
local function CurrentLevel()
  if Addon.db and Addon.db.global and Addon.db.global.debug then
    return LEVELS.DEBUG
  end
  return LEVELS.INFO
end

-- ============================================================================
-- ФОРМАТИРОВАНИЕ
-- ============================================================================
local function format_msg(fmt, ...)
  if select("#", ...) == 0 then
    return tostring(fmt)
  end
  local ok, msg = pcall(string.format, fmt, ...)
  if ok then
    return msg
  else
    return tostring(fmt) .. " [FORMAT ERROR: " .. tostring(msg) .. "]"
  end
end

local function timestamp()
  return time()
end

local function color_for_level(level)
  if level == "ERROR" then return "|cFFFF5050" end
  if level == "WARN" then  return "|cFFFFAA00" end
  if level == "INFO" then  return "|cFFAAFFAA" end
  if level == "DEBUG" then return "|cFF888888" end
  return "|cFFFFFFFF"
end

-- ============================================================================
-- ЗАПИСЬ В ЛОГ
-- ============================================================================
-- Уровневый гейт ВАЖЕН: Debug пишется в БД ТОЛЬКО при debug=true. Без гейта
-- Debug из FrameOnUpdate/ParseNote (10+ вызовов/сек) даёт аллокацию таблицы +
-- tinsert/tremove при 5000 записей на каждый вызов — постоянный GC-press
-- и разрастание SavedVariables.
local function write_log(level_name, message)
  local level_num = LEVELS[level_name] or LEVELS.INFO
  -- Гейт: INFO — всегда; DEBUG — только в debug-режиме
  if level_num <= CurrentLevel() and Addon.db and Addon.db.global then
    local entry = {
      time = timestamp(),
      level = level_name,
      msg = message:sub(1, 500),  -- ограничиваем длину
    }
    tinsert(Addon.db.global.log, entry)

    -- Ограничение размера лога
    local max_size = Addon.db.global.max_log_size or 5000
    while #Addon.db.global.log > max_size do
      tremove(Addon.db.global.log, 1)
    end
  end

  -- Вывод в чат: ТОЛЬКО ERROR и WARN.
  -- INFO и DEBUG пишутся только в SavedVariables (видны через /gg log и /gg log export),
  -- но НЕ выводятся в чат — чтобы не засорять self-chat.
  if level_name == "ERROR" or level_name == "WARN" then
    local colored = color_for_level(level_name) .. "[" .. level_name .. "]|r " .. message
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r " .. colored)
  end
end

-- ============================================================================
-- ПУБЛИЧНЫЕ МЕТОДЫ
-- ============================================================================
function Log:Error(fmt, ...)
  write_log("ERROR", format_msg(fmt, ...))
end

function Log:Warn(fmt, ...)
  write_log("WARN", format_msg(fmt, ...))
end

function Log:Info(fmt, ...)
  write_log("INFO", format_msg(fmt, ...))
end

function Log:Debug(fmt, ...)
  write_log("DEBUG", format_msg(fmt, ...))
end

-- Логирование специфичных событий аддона
function Log:Award(kind, name, reason, amount, mass, officer)
  self:Info("[%s] %s -> %s | amount=%d | reason='%s' | mass=%s | officer=%s",
    kind:upper(), kind == "gold" and "Gold" or "GP",
    name, amount, reason, tostring(mass), tostring(officer))
end

function Log:StateChange(old_state, new_state, context)
  self:Debug("State: %s -> %s (%s)", old_state, new_state, context or "")
end

function Log:NoteChanged(name, old_note, new_note, source)
  self:Debug("Note changed: %s | '%s' -> '%s' | source=%s",
    name, tostring(old_note), tostring(new_note), tostring(source))
end

function Log:PendingQueued(name, note)
  self:Debug("Pending queued: %s -> '%s' (queue size will increase)", name, tostring(note))
end

function Log:PendingFlushed(name, note)
  self:Debug("Pending flushed: %s -> '%s' (sent to server)", name, tostring(note))
end

function Log:MassAwardStart(reason, amount, target_count)
  self:Info("Mass award START | reason='%s' | amount=%d | targets=%d", reason, amount, target_count)
end

function Log:MassAwardEnd(reason, amount, awarded_count, failed_count, failed_names)
  if failed_count > 0 then
    self:Warn("Mass award END | reason='%s' | amount=%d | OK=%d | FAILED=%d | failed: %s",
      reason, amount, awarded_count, failed_count, table.concat(failed_names, ", "))
  else
    self:Info("Mass award END | reason='%s' | amount=%d | OK=%d | FAILED=0",
      reason, amount, awarded_count)
  end
end

function Log:RecurringTick(reason, amount, period_mins)
  self:Info("Recurring tick | reason='%s' | amount=%d | period=%dm", reason, amount, period_mins)
end

function Log:RecurringSkipped(reason)
  self:Warn("Recurring SKIPPED | reason='%s' | guild storage not CURRENT", reason)
end

-- ============================================================================
-- ЧТЕНИЕ / ОЧИСТКА
-- ============================================================================
-- Получить последние N записей
function Log:GetLast(n)
  if not Addon.db or not Addon.db.global or not Addon.db.global.log then
    return {}
  end
  local result = {}
  local total = #Addon.db.global.log
  local start = math.max(1, total - n + 1)
  for i = start, total do
    tinsert(result, Addon.db.global.log[i])
  end
  return result
end

-- Очистить лог
function Log:Clear()
  if Addon.db and Addon.db.global then
    Addon.db.global.log = {}
    self:Info("Log cleared")
  end
end

Log:Info("GoldGP_Log loaded")
