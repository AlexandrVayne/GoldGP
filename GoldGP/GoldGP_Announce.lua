-- GoldGP_Announce.lua

local Addon = GoldGP
local Announce = {}
Addon.Announce = Announce

-- ============================================================================
-- ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ
-- ============================================================================

-- Дебаунс для индивидуальных начислений.
-- КЛЮЧ = "имя:тип" ("gold"/"gp") — EP и GP одному игроку дебаунсятся НЕЗАВИСИМО;
-- имя игрока хранится в info.player (публикация читает его из записи, а не из ключа).
local individual_debounce = {}
local DEBOUNCE_SECONDS = 2.0  -- ждать 2 сек после последнего начисления игроку

-- Таймер для проверки дебаунса
local timer_frame = CreateFrame("Frame", "GoldGP_AnnounceTimer")
timer_frame:Hide()
local timer_active = false

-- ============================================================================
-- ОТСЛЕЖИВАНИЕ МАССОВОК
-- ============================================================================
-- Когда начинается Mass Gold/GP — мы получаем много событий GoldAward/GPAward
-- с mass=true. Мы хотим опубликовать ОДНО сообщение со сводкой.
-- Для этого в Award.lua мы вызываем Announce:OnMassStart() / OnMassEnd()

local mass_in_progress = false
local mass_reason = nil
local mass_amount = 0
local mass_count = 0
local mass_extras_count = 0
local mass_extras_amount = 0
local mass_reduced_count = 0
local mass_reduced_amount = 0

-- ============================================================================
-- НАСТРОЙКИ ПО УМОЛЧАНИЮ
-- ============================================================================
-- Добавляем настройки в профиль при инициализации
local function ensure_defaults()
  if not Addon.db or not Addon.db.profile then return end
  local p = Addon.db.profile
  if p.announce_enabled == nil then       p.announce_enabled = true end
  if p.announce_channel == nil then       p.announce_channel = "GUILD" end
  if p.announce_mass == nil then          p.announce_mass = true end
  if p.announce_individual == nil then    p.announce_individual = true end
  if p.announce_decay == nil then         p.announce_decay = true end
  if p.announce_recurring == nil then     p.announce_recurring = true end
  if p.announce_min_amount == nil then    p.announce_min_amount = 1 end
end

-- ============================================================================
-- ОТПРАВКА СООБЩЕНИЯ В ЧАТ
-- ============================================================================
local function send_chat(msg)
  if not Addon.db or not Addon.db.profile then return end
  ensure_defaults()
  if not Addon.db.profile.announce_enabled then return end
  local channel = Addon.db.profile.announce_channel or "GUILD"
  -- Проверка: не отправляем если канал не подходит (например RAID когда не в рейде)
  if channel == "RAID" and not UnitInRaid("player") then
    channel = "GUILD"
  elseif channel == "PARTY" and GetNumPartyMembers() == 0 then
    channel = "GUILD"
  end
  SendChatMessage(msg, channel)
end

-- ============================================================================
-- ОБРАБОТКА МАССОВОК
-- ============================================================================

-- Вызывается из Award.lua в начале MassGold
function Announce:OnMassStart(reason, amount)
  ensure_defaults()
  if not Addon.db.profile.announce_mass then return end
  mass_in_progress = true
  mass_reason = reason
  mass_amount = amount
  mass_count = 0
  mass_extras_count = 0
  mass_extras_amount = 0
  mass_reduced_count = 0
  mass_reduced_amount = 0
end

-- Вызывается из Award.lua для каждого игрока в массовке
-- is_extras = true если игрок в standby (получил extras_amount)
-- is_reduced = true если игрок в P6-8 (получил % от amount)
-- actual_amount = сколько реально получил
function Announce:OnMassAward(name, actual_amount, is_extras, is_reduced)
  if not mass_in_progress then return end
  if is_extras then
    mass_extras_count = mass_extras_count + 1
    mass_extras_amount = actual_amount
  elseif is_reduced then
    mass_reduced_count = mass_reduced_count + 1
    mass_reduced_amount = actual_amount
  else
    mass_count = mass_count + 1
  end
end

-- Вызывается из Award.lua в конце MassGold
function Announce:OnMassEnd()
  if not mass_in_progress then return end
  ensure_defaults()
  if not Addon.db.profile.announce_mass then
    mass_in_progress = false
    return
  end

  local currency = "EP"
  local total_awarded = mass_count + mass_extras_count + mass_reduced_count

  -- Минимальная сумма
  if math.abs(mass_amount) < (Addon.db.profile.announce_min_amount or 0) and
     total_awarded == 0 then
    mass_in_progress = false
    return
  end

  -- Формируем сообщение
  local msg
  if mass_extras_count > 0 and mass_reduced_count > 0 then
    -- И массовка, и standby, и P6-8
    msg = string.format("%+d %s '%s' -> %d игрокам (P1-5), +%d -> %d (P6-8), +%d -> %d standby",
      mass_amount, currency, mass_reason,
      mass_count, mass_reduced_amount, mass_reduced_count,
      mass_extras_amount, mass_extras_count)
  elseif mass_extras_count > 0 then
    -- Массовка + standby
    msg = string.format("%+d %s '%s' -> %d игрокам + %d standby",
      mass_amount, currency, mass_reason, mass_count, mass_extras_count)
  elseif mass_reduced_count > 0 then
    -- Массовка с party-split
    msg = string.format("%+d %s '%s' -> %d игрокам (P1-5), +%d -> %d (P6-8)",
      mass_amount, currency, mass_reason,
      mass_count, mass_reduced_amount, mass_reduced_count)
  else
    -- Простая массовка
    msg = string.format("%+d %s '%s' -> %d игрокам",
      mass_amount, currency, mass_reason, mass_count)
  end

  send_chat(msg)
  Addon.Log:Info("[Announce] Mass: %s", msg)

  mass_in_progress = false
end

-- ============================================================================
-- ОБРАБОТКА ИНДИВИДУАЛЬНЫХ НАЧИСЛЕНИЙ (с дебаунсом)
-- ============================================================================

local function check_debounce_timer()
  if timer_active then return end
  timer_active = true
  timer_frame:SetScript("OnUpdate", function(_, elapsed)
    local now = GetTime()
    local has_pending = false
    for key, info in pairs(individual_debounce) do
      if now - info.last_time >= DEBOUNCE_SECONDS then
        -- Время публиковать
        if not info.published then
          local currency = info.type == "gold" and "EP" or "GP"
          -- last_amount — НАКОПЛЕННАЯ ДЕЛЬТА за окно дебаунса: код выше складывает
          -- суммы всех начислений этого типа игроку до наступления тишины 2 сек
          -- (быстрые +1, +1, +1 публикуются одной строкой «+3»).
          -- Имя берётся из info.player (ключ таблицы — "имя:тип").
          local msg = string.format("%s%d %s '%s' -> %s",
            info.last_amount > 0 and "+" or "",
            info.last_amount, currency, info.last_reason, info.player)
          send_chat(msg)
          Addon.Log:Info("[Announce] Individual: %s", msg)
          info.published = true
        end
        individual_debounce[key] = nil
      else
        has_pending = true
      end
    end
    if not has_pending then
      timer_active = false
      timer_frame:Hide()
    end
  end)
  timer_frame:Show()
end

-- Подписываемся на индивидуальные начисления (mass=false)
-- math.abs(amount) при проверке min_amount — отрицательные суммы (штрафы)
-- тоже публикуются
Addon:RegisterCallback("GoldAward", function(name, reason, amount, mass, undo)
  if mass or undo then return end  -- массовки обрабатываются отдельно
  ensure_defaults()
  if not Addon.db.profile.announce_individual then return end
  if math.abs(amount) < (Addon.db.profile.announce_min_amount or 0) then return end

  local now = GetTime()
  -- Ключ по имени+типу — EP и GP одному игроку дебаунсятся независимо
  local key = name .. ":gold"
  local info = individual_debounce[key]
  if not info then
    info = { player = name, type = "gold", last_amount = 0, last_reason = "", last_time = 0, published = false }
    individual_debounce[key] = info
  end
  -- Накапливаем дельту (если офицер быстро нажал +1, +1, +1 -> +3)
  info.last_amount = info.last_amount + amount
  if reason and reason ~= "" then info.last_reason = reason end
  info.last_time = now
  info.published = false
  check_debounce_timer()
end)

Addon:RegisterCallback("GPAward", function(name, reason, amount, mass, undo)
  if mass or undo then return end
  ensure_defaults()
  if not Addon.db.profile.announce_individual then return end
  if math.abs(amount) < (Addon.db.profile.announce_min_amount or 0) then return end

  local now = GetTime()
  -- Ключ по имени+типу — GP не затирает pendящий EP
  local key = name .. ":gp"
  local info = individual_debounce[key]
  if not info then
    info = { player = name, type = "gp", last_amount = 0, last_reason = "", last_time = 0, published = false }
    individual_debounce[key] = info
  end
  info.last_amount = info.last_amount + amount
  if reason and reason ~= "" then info.last_reason = reason end
  info.last_time = now
  info.published = false
  check_debounce_timer()
end)

-- ============================================================================
-- DECAY
-- ============================================================================
Addon:RegisterCallback("Decay", function(percent)
  ensure_defaults()
  if not Addon.db.profile.announce_decay then return end
  local msg = string.format("Срез %d%% применён ко всем игрокам", percent)
  send_chat(msg)
  Addon.Log:Info("[Announce] Decay: %s", msg)
end)

-- ============================================================================
-- RECURRING (периодические начисления)
-- ============================================================================
Addon:RegisterCallback("StartRecurring", function(reason, amount, mins)
  ensure_defaults()
  if not Addon.db.profile.announce_recurring then return end
  -- reason не включаем: "Рт по таймеру" уже в начале строки
  local msg = string.format("Рт по таймеру старт: +%d EP каждые %d мин",
    amount, mins)
  send_chat(msg)
  Addon.Log:Info("[Announce] Recurring start: %s", msg)
end)

Addon:RegisterCallback("StopRecurring", function()
  ensure_defaults()
  if not Addon.db.profile.announce_recurring then return end
  local msg = "Рт по таймеру остановлен"
  send_chat(msg)
  Addon.Log:Info("[Announce] Recurring stop: %s", msg)
end)

-- ============================================================================
-- ПУБЛИЧНЫЕ МЕТОДЫ
-- ============================================================================

function Announce:SetEnabled(enabled)
  ensure_defaults()
  Addon.db.profile.announce_enabled = enabled and true or false
  Addon.Log:Info("Announce enabled: %s", tostring(Addon.db.profile.announce_enabled))
end

function Announce:SetChannel(channel)
  ensure_defaults()
  Addon.db.profile.announce_channel = channel
  Addon.Log:Info("Announce channel: %s", channel)
end

function Announce:GetConfig()
  ensure_defaults()
  return {
    enabled = Addon.db.profile.announce_enabled,
    channel = Addon.db.profile.announce_channel,
    mass = Addon.db.profile.announce_mass,
    individual = Addon.db.profile.announce_individual,
    decay = Addon.db.profile.announce_decay,
    recurring = Addon.db.profile.announce_recurring,
    min_amount = Addon.db.profile.announce_min_amount,
  }
end

function Announce:Test()
  send_chat("Тестовое сообщение автопубликации")
end

-- Отправить произвольное сообщение в чат (канал из настроек)
function Announce:SendCustomMessage(msg)
  ensure_defaults()
  if not Addon.db.profile.announce_enabled then return end
  send_chat(msg)
  Addon.Log:Info("[Announce] Custom: %s", msg)
end

if Addon.Log then Addon.Log:Info("GoldGP_Announce loaded") end
