-- GoldGP_Core.lua

local addonName, ns = ...
GoldGP = CreateFrame("Frame", addonName)
local Addon = GoldGP
ns.Addon = Addon

-- Публичный API
Addon.version = "2.8.6"
Addon.callbacks = {}

-- PrintError/Print определены ПЕРВЫМИ — до любых потенциально крашащих вызовов.
-- Если RegisterAddonMessagePrefix крашит, PrintError уже определена.
local function print_err(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP|r: " .. tostring(msg))
  end
end
local function print_ok(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r: " .. tostring(msg))
  end
end
Addon.PrintError = print_err
Addon.Print = print_ok

-- ============================================================================
-- КОНСТАНТЫ
-- ============================================================================
local EVENT_PREFIX = "GoldGP"          -- для SendAddonMessage
local SYNC_MSG_CHANGES_PENDING = "CHANGES_PENDING"
local SYNC_MSG_CHANGES_FLUSHED = "CHANGES_FLUSHED"
-- Посещаемость — через public note + GuildInfo, addon-broadcast не используется.

-- РЕГИСТРАЦИЯ ПРЕФИКСА — без этого CHAT_MSG_ADDON не срабатывает!
-- pcall: функция может быть недоступна (sirus.su) — не крашим весь Core.lua
pcall(function()
  RegisterAddonMessagePrefix(EVENT_PREFIX)
end)

-- Константа причины "приход на рт" — для счётчика посещаемости
Addon.ATTENDANCE_REASON = "Приход на рт"

-- ============================================================================
-- ГИЛЬД-ЛОК
-- ============================================================================
-- Аддон работает ТОЛЬКО у членов указанной гильдии.
-- Впиши сюда точное название своей гильдии (как оно отображается в игре).
-- Пустая строка "" = разрешена любая гильдия (но не "без гильдии").
-- Название также можно задать в игре без правки файла: /gg setguild [имя]
--   /gg setguild        — привязать к текущей гильдии игрока (без опечаток)
--   /gg setguild clear  — снять привязку (вернуться к константе выше)
Addon.REQUIRED_GUILD_NAME = ""

-- Дефолтные настройки
local DEFAULTS = {
  global = {
    log = {},                            -- лог событий
    max_log_size = 5000,                 -- максимум записей в логе
    debug = false,                       -- режим отладки
    attendance_data = {},                -- индивидуальный счётчик посещаемости (name -> count)
    attendance_total = 0,                -- общее кол-во РТ в гильдии (второе число в формате X / Y)
    required_guild = "",                 -- гильд-лок (override константы REQUIRED_GUILD_NAME)
    welcome_seen = false,                -- показано ли окно первого запуска (Правила/Таблица)
  },
  profile = {
    -- Глобальные настройки гильдии (читаются из GuildInfo)
    decay_p = 0,                         -- @DECAY_P
    extras_p = 100,                      -- @EXTRAS_P
    min_gold = 0,                        -- @MIN_GOLD
    base_gp = 1,                         -- @BASE_GP

    -- Настройки UI
    window_width = 500,
    window_height = 460,
    window_pos_x = nil,
    window_pos_y = nil,
    -- Ширина Журнала (настраивается в Options)
    history_width = 500,

    -- Настройки массовых начислений
    mass_ep_cooldown = 1.5,              -- минимальный интервал между массовками (сек)
    safe_mass_mode = true,               -- проверять state перед массовкой

    -- Настройки recurring
    recurring_period_mins = 15,

    -- Сортировка
    sort_order = "PR",                   -- NAME | GOLD | GP | PR

    -- Разделение массовки по пати (1-5 = 100%, 6-8 = 50%)
    party_split_enabled = true,          -- включить разделение по пати
    party_split_threshold = 5,           -- партии 1..N получают 100%
    party_split_percent = 50,            -- партии (N+1)..8 получают X% (0-100)

    -- Интервал OnUpdate для Storage
    update_interval = 0.1,               -- 0.05 (быстро) / 0.1 (норма) / 0.2 (слабые ПК)
  }
}

-- ============================================================================
-- ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ
-- ============================================================================
local db
local initialized = false
-- throttle для RAID_ROSTER_UPDATE (1 сек)
local raid_roster_throttle_time = 0

-- ============================================================================
-- ГИЛЬД-ЛОК — СОСТОЯНИЕ И API
-- ============================================================================
-- Addon.guild_lock_ok:
--   true  — игрок в разрешённой гильдии, аддон работает
--   false — заблокирован (нет гильдии / чужая гильдия)
--   nil   — ещё неизвестно (ждём данные гильдии от сервера)
-- Пока nil/false: UI не открывается, начисления/синхронизация/команды отключены.

-- Требуемая гильдия: db.global.required_guild (задаётся /gg setguild) имеет приоритет,
-- иначе используется константа Addon.REQUIRED_GUILD_NAME из начала файла.
function Addon:GetRequiredGuild()
  if self.db and self.db.global and self.db.global.required_guild and
     self.db.global.required_guild ~= "" then
    return self.db.global.required_guild
  end
  return self.REQUIRED_GUILD_NAME or ""
end

-- Проверка гильд-лока. Возвращает:
--   ok(true)                    — разрешено
--   false, "no_guild"           — игрок вообще без гильдии
--   false, "unknown"            — гильдия ещё не получена от сервера (ждём)
--   false, "<имя гильдии>"      — игрок в чужой гильдии
function Addon:CheckGuildLock()
  if not IsInGuild() then
    return false, "no_guild"
  end
  local guild_name = GetGuildInfo("player")
  if not guild_name then
    return false, "unknown"
  end
  local required = self:GetRequiredGuild()
  if required == "" then
    return true
  end
  -- Точное сравнение (кириллица в strlower не меняется в Lua 5.1)
  if guild_name == required then return true end
  -- ASCII-приведение регистра — на случай латинского названия
  if guild_name:lower() == required:lower() then return true end
  return false, guild_name
end

function Addon:IsEnabled()
  return self.guild_lock_ok ~= false
end

-- Пересчитать состояние гильд-лока. Вызывается из PEW / GUILD_ROSTER_UPDATE /
-- PLAYER_GUILD_UPDATE. Сообщает игроку только при РЕАЛЬНОЙ смене состояния.
function Addon:UpdateGuildLock(trigger)
  local ok, info = self:CheckGuildLock()
  local prev = self.guild_lock_ok
  self.guild_lock_ok = ok

  if not ok then
    -- "unknown" — сервер ещё не прислал данные, молчим (перепроверим на roster-событиях)
    if info == "no_guild" then
      if prev ~= false then
        Addon.PrintError("GoldGP заблокирован: вы не состоите в гильдии. Аддон не работает.")
        if self.Log then self.Log:Info("Guild lock ON (%s): no guild", tostring(trigger)) end
      end
    elseif info ~= "unknown" then
      if prev ~= false or prev == nil then
        -- prev == nil: первый подсчёт при уже известной чужой гильдии — тоже сообщаем
        Addon.PrintError(string.format(
          "GoldGP заблокирован: гильдия '%s' не является разрешённой. Аддон не работает.",
          tostring(info)))
        if self.Log then self.Log:Info("Guild lock ON (%s): guild='%s'", tostring(trigger), tostring(info)) end
      end
    end
    return
  end

  -- Разблокировка (или первый успешный вход)
  if prev == false then
    Addon.Print("GoldGP: гильд-лок снят — аддон активирован.")
    if self.Log then self.Log:Info("Guild lock OFF (%s)", tostring(trigger)) end
  end
  -- Если при входе аддон был заблокирован и полная инициализация не выполнялась —
  -- выполняем её сейчас (ровно тот же путь, что у PLAYER_ENTERING_WORLD).
  if not initialized then
    self:DoWorldInit("guild_lock_unlock")
  end
end

-- Полная инициализация после входа в мир. Та же функция вызывается при снятии
-- гильд-лока без перезахода (игрок вступил в гильдию прямо в игровой сессии).
function Addon:DoWorldInit(trigger)
  if initialized then return end
  if Addon.Log then
    Addon.Log:Info("DoWorldInit (%s): initializing...", tostring(trigger or "player_entering_world"))
  end
  -- CanEditOfficerNote надёжно работает после входа в мир (в ADDON_LOADED ещё нет гильдии).
  self.state.can_edit = CanEditOfficerNote() and true or false
  if Addon.Log then
    Addon.Log:Info("CanEditOfficerNote: %s (read-only mode: %s)",
      self.state.can_edit and "YES" or "NO",
      self.state.can_edit and "OFF" or "ON")
  end
  if Addon.Storage then
    Addon.Storage:Initialize()
  end
  GuildRoster()
  -- Загрузить статусы "в отпуске" из БД
  Addon:LoadOnLeaveStatus()
  Addon:LoadStandby()
  if Addon.UI then
    Addon.UI:Initialize()
  end
  initialized = true
  if Addon.Log then
    Addon.Log:Info("GoldGP v%s initialized for guild '%s'", self.version, self.guild_name or "unknown")
  end
  -- Принудительное обновление состава рейда при входе в мир.
  if UnitInRaid("player") then
    self:RAID_ROSTER_UPDATE()
  end
  -- Обновление standby-сессии (детект лидера рейда)
  self:UpdateStandbyRaidSession("player_entering_world")
  -- Перехват whisper для standby
  Addon:HookWhisperForStandby()
end

-- Состояние аддона
Addon.state = {
  guild_name = "",
  in_raid = false,
  raid_members = {},                     -- снимок состава рейда (name -> true)
  raid_subgroups = {},                   -- name -> subgroup (1..8) для party-split
  -- name -> АНГЛИЙСКИЙ токен класса (fileName из GetRaidRosterInfo, 6-е
  -- возвращаемое). Авторитетный источник класса для рейд-сообщников —
  -- используется Addon:GetClassToken, если class_data пуст/битый.
  raid_units = {},
  last_mass_award_time = 0,              -- для cooldown'а
  standby = {},                          -- name -> true (на замене) — runtime, НЕ persisted
  -- standby session state — привязана к текущему лидеру рейда (leader-scoped)
  standby_session = {
    id = nil,         -- "time:leaderName:seq" — уникален на рейд-сессию
    leader = nil,     -- текущий лидер рейда
    active = false,   -- true когда в рейде и есть лидер
    revision = 0,     -- монотонный счётчик для STB_SET/DEL/CLEAR
  },
  -- Отслеживание pending snapshot-запроса: pending_names + meta_received_at
  -- для атомарного snapshot. Live state.standby НЕ меняется до получения всех
  -- chunks — имена накапливаются в pending_names, затем атомарно заменяют live state.
  standby_snapshot = {
    request_id = nil,
    expected_chunks = 0,
    received_chunks = {},
    pending_names = {},       -- временный буфер для имён из chunks
    cooldown = 0,             -- GetTime() последнего запроса — cooldown 3 сек
    meta_received_at = 0,     -- GetTime() получения STB_META — для таймаута (watch ниже)
  },
  can_edit = false,                      -- CanEditOfficerNote() — read-only mode для не-офицеров
}

-- Данные гильдии
Addon.data = {
  gold_data = {},                        -- name -> gold (только mains)
  gp_data = {},                          -- name -> gp
  main_data = {},                        -- alt_name -> main_name
  alt_data = {},                         -- main_name -> {alt_names}
  ignored = {},                          -- name -> note (битые ноты)
  class_data = {},                       -- name -> class
  rank_data = {},                        -- name -> rank index (0..N)
  rank_name_data = {},                   -- name -> rank name (string)
  on_leave = {},                         -- name -> true (игрок в отпуске)
  cache_version = 0,                     -- инкрементируется при любой мутации данных
  attendance_data = {},                  -- name -> count (счётчик посещаемости РТ)
  attendance_total = 0,                  -- общее кол-во РТ (второе число X / Y)
  member_count = 0,                      -- кэшированное число игроков в gold_data
}

-- BumpCacheVersion — инвалидирует кэш standings в UI. Вызывать при любой мутации данных.
function Addon:BumpCacheVersion()
  self.data.cache_version = (self.data.cache_version or 0) + 1
end

-- ============================================================================
-- УТИЛИТЫ
-- ============================================================================

-- Зарегистрировать callback
function Addon:RegisterCallback(event, func)
  if not self.callbacks[event] then
    self.callbacks[event] = {}
  end
  tinsert(self.callbacks[event], func)
end

-- Вызвать callbacks
function Addon:Fire(event, ...)
  if self.callbacks[event] then
    for _, func in ipairs(self.callbacks[event]) do
      local ok, err = pcall(func, ...)
      if not ok and self.Log then
        self.Log:Error("Callback error in %s: %s", event, tostring(err))
      end
    end
  end
end

-- ============================================================================
-- ИНИЦИАЛИЗАЦИЯ БД
-- ============================================================================
local function InitDB()
  if GoldGPDB == nil then GoldGPDB = {} end
  if GoldGPDB.global == nil then GoldGPDB.global = {} end
  if GoldGPDB.profiles == nil then GoldGPDB.profiles = {} end

  -- ============================================================================
  -- ВЕРСИОНИРОВАНИЕ SavedVariables
  -- ============================================================================
  -- Текущая версия формата БД. При изменении структуры данных — поднять версию
  -- и добавить миграцию в MigrateDB().
  local CURRENT_DB_VERSION = 2

  -- Миграции: вызываются при устаревшей версии БД
  local function MigrateDB(old_version)
    if old_version < 1 then
      -- Миграция v0 -> v1:
      --   * Переименовать ep_data -> gold_data если есть
      --   * Создать history если нет
      if GoldGPDB.global.ep_data and not GoldGPDB.global.gold_data then
        GoldGPDB.global.gold_data = GoldGPDB.global.ep_data
        GoldGPDB.global.ep_data = nil
        if Addon.Log then Addon.Log:Info("DB migration v0->v1: renamed ep_data to gold_data") end
      end
      if not GoldGPDB.global.history then
        GoldGPDB.global.history = {}
      end
      -- Удаляем старые discord данные если есть
      GoldGPDB.global.discord_queue = nil
      GoldGPDB.global.discord_enabled = nil
      GoldGPDB.global.discord_webhook_url = nil
      GoldGPDB.global.discord_last_sent = nil
    end
    if old_version < 2 then
      -- Миграция v1 -> v2: вынести position истории из lm_window_pos (общего с LootMaster)
      -- в отдельный window_positions (LootMaster продолжает использовать lm_window_pos).
      if GoldGPDB.global.lm_window_pos and GoldGPDB.global.lm_window_pos.history then
        if not GoldGPDB.global.window_positions then
          GoldGPDB.global.window_positions = {}
        end
        if not GoldGPDB.global.window_positions.history then
          GoldGPDB.global.window_positions.history = GoldGPDB.global.lm_window_pos.history
        end
        GoldGPDB.global.lm_window_pos.history = nil
        if Addon.Log then
          Addon.Log:Info("DB migration v1->v2: moved history pos lm_window_pos -> window_positions")
        end
      end
    end
    GoldGPDB.global.db_version = CURRENT_DB_VERSION
    if Addon.Log then
      Addon.Log:Info("DB migrated from v%d to v%d", old_version, CURRENT_DB_VERSION)
    end
  end

  -- Проверяем версию и запускаем миграцию при необходимости
  local db_version = GoldGPDB.global.db_version or 0
  if db_version < CURRENT_DB_VERSION then
    MigrateDB(db_version)
  end

  -- Глобальные настройки
  for k, v in pairs(DEFAULTS.global) do
    if GoldGPDB.global[k] == nil then
      GoldGPDB.global[k] = v
    end
  end

  -- Профиль = имя гильдии (как в EPGP)
  local guild = GetGuildInfo("player") or "Default"
  if GoldGPDB.profiles[guild] == nil then
    GoldGPDB.profiles[guild] = {}
  end
  for k, v in pairs(DEFAULTS.profile) do
    if GoldGPDB.profiles[guild][k] == nil then
      GoldGPDB.profiles[guild][k] = v
    end
  end

  -- Миграция history_width: если было 600 (старый дефолт) — сброс на 500
  if GoldGPDB.profiles[guild].history_width == 600 then
    GoldGPDB.profiles[guild].history_width = 500
  end

  db = {
    global = GoldGPDB.global,
    profile = GoldGPDB.profiles[guild],
  }
  Addon.db = db
  Addon.guild_name = guild

  -- Синхронизируем attendance_data из SavedVariables в Addon.data
  if GoldGPDB.global.attendance_data then
    Addon.data.attendance_data = GoldGPDB.global.attendance_data
  else
    GoldGPDB.global.attendance_data = {}
    Addon.data.attendance_data = GoldGPDB.global.attendance_data
  end

  -- Синхронизируем attendance_total (общее кол-во РТ)
  if GoldGPDB.global.attendance_total == nil then
    GoldGPDB.global.attendance_total = 0
  end
  Addon.data.attendance_total = GoldGPDB.global.attendance_total
end

-- ============================================================================
-- ПОСЕЩАЕМОСТЬ — public API
-- ============================================================================
-- Автоматического ежемесячного сброса посещаемости НЕТ — офицеры сбрасывают
-- вручную через Options UI (att_reset_btn, с подтверждением). Значения
-- сохраняются между месяцами, relog и roster refresh.

-- Public API: общее кол-во РТ в гильдии (второе число в X / Y)
function Addon:GetAttendanceTotal()
  return (self.data and self.data.attendance_total) or
         (self.db and self.db.global and self.db.global.attendance_total) or 0
end

-- Public API: индивидуальный счётчик игрока.
-- Всегда резолвим в main — attendance хранится на public note мейна
function Addon:GetAttendanceCount(name)
  if not name then return 0 end
  local data = self.data and self.data.attendance_data
  if not data then return 0 end
  local main = (self.data.main_data and self.data.main_data[name]) or name
  return data[main] or 0
end

-- Обновить @ATT_TOTAL в GuildInfo.
-- Возвращает true при успехе, false при ошибке (нет прав / ошибка записи).
-- Вызывающие (MassGold/RetryAttendanceMass/RestoreMass) ОБЯЗАНЫ проверять
-- возвращаемое значение и НЕ считать локальный кэш закоммиченным при false.
function Addon:SetGuildInfoAttendance(new_total)
  -- Читаем текущий GuildInfo из Storage
  local current_info = Addon.Storage and Addon.Storage:GetGuildInfoText() or ""
  local new_info
  if current_info:find("@ATT_TOTAL:%d+") then
    new_info = current_info:gsub("@ATT_TOTAL:%d+", "@ATT_TOTAL:" .. tostring(new_total))
  elseif current_info:find("%-GGP%-") then
    -- Добавляем перед закрывающим -GGP-
    new_info = current_info:gsub("(%-GGP%-[^\n]*)", "@ATT_TOTAL:" .. tostring(new_total) .. "\n%1", 1)
    -- Если не сработало (однострочный), добавляем в конец
    if not new_info or new_info == current_info then
      new_info = current_info .. "\n@ATT_TOTAL:" .. tostring(new_total)
    end
  else
    new_info = current_info .. "\n@ATT_TOTAL:" .. tostring(new_total)
  end
  -- Проверяем права перед записью
  if not CanEditOfficerNote() then
    if Addon.Log then
      Addon.Log:Warn("SetGuildInfoAttendance: no officer note permission — @ATT_TOTAL NOT updated")
    end
    return false
  end
  -- Записываем (без очереди — GuildInfo синхронный API)
  SetGuildInfoText(new_info)
  -- Оптимистичное обновление локального кэша — вызывающий подтверждает ростером
  Addon.data.attendance_total = new_total
  if Addon.db and Addon.db.global then
    Addon.db.global.attendance_total = new_total
  end
  if Addon.Log then
    Addon.Log:Info("GuildInfo @ATT_TOTAL updated to %d", new_total)
  end
  return true
end

-- ============================================================================
-- ОБРАБОТКА СОБЫТИЙ
-- ============================================================================

-- GUILD_ROSTER_UPDATE — обновление ростера гильдии
function Addon:GUILD_ROSTER_UPDATE(localUpdate)
  if Addon.Log then
    Addon.Log:Debug("GUILD_ROSTER_UPDATE(local=%s)", tostring(localUpdate))
  end
  if not IsInGuild() then
    if Addon.Storage then
      Addon.Storage:Disable()
    end
    return
  end
  -- Гильд-лок: при чужой гильдии не парсим officer notes и не синхронизируем.
  -- UpdateGuildLock сам разблокирует и доинициализирует аддон, если игрок вступил
  -- в разрешённую гильдию прямо в игровой сессии.
  self:UpdateGuildLock("guild_roster_update")
  if not self:IsEnabled() then
    return
  end
  -- Обновляем can_edit при каждом ростер-апдейте (права могут измениться
  -- при смене звания офицером). UI использует это для read-only mode.
  self.state.can_edit = CanEditOfficerNote() and true or false
  -- Если при PLAYER_ENTERING_WORLD гильдия ещё не загрузилась — профиль создался
  -- под именем "Default". При первом GUILD_ROSTER_UPDATE реальное имя гильдии
  -- становится доступно — переинициализируем DB с правильным профилем.
  local guild_now = GetGuildInfo("player")
  if guild_now and Addon.guild_name == "Default" and guild_now ~= "Default" then
    if Addon.Log then
      Addon.Log:Info("Guild name resolved: %s — re-initializing DB profile", guild_now)
    end
    InitDB()
    if Addon.UI then
      Addon.UI:Initialize()
    end
  end
  if Addon.Storage then
    Addon.Storage:OnRosterUpdate(localUpdate)
  end
end

-- RAID_ROSTER_UPDATE — изменение состава рейда
function Addon:RAID_ROSTER_UPDATE()
  -- Throttle 1 сек — событие стреляет часто (переход зон, смена лидера).
  local now = GetTime()
  if now - raid_roster_throttle_time < 1.0 then return end
  raid_roster_throttle_time = now
  if Addon.Log then
    Addon.Log:Debug("RAID_ROSTER_UPDATE")
  end
  if UnitInRaid("player") then
    self.state.in_raid = true
    -- Снимок состава рейда + subgroup для каждого игрока
    wipe(self.state.raid_members)
    wipe(self.state.raid_subgroups)
    -- Заодно снимок токенов классов (см. GetClassToken)
    wipe(self.state.raid_units)
    for i = 1, GetNumRaidMembers() do
      -- GetRaidRosterInfo возвращает: name, rank, subgroup, level, class, fileName,
      -- zone, online, isDead, role, isML
      local name, _, subgroup, _, _, fileName = GetRaidRosterInfo(i)
      if name then
        -- Отрезаем сервер-суффикс
        name = strsplit("-", name)
        self.state.raid_members[name] = true
        self.state.raid_subgroups[name] = tonumber(subgroup) or 0
        -- fileName — АНГЛИЙСКИЙ токен класса (WARRIOR/PRIEST/...), надёжен на
        -- любом клиенте: UnitClass/GetRaidRosterInfo возвращают его напрямую,
        -- без конвертации локализованных имён
        if fileName and fileName ~= "" then
          self.state.raid_units[name] = fileName
        end
      end
    end
  else
    self.state.in_raid = false
    wipe(self.state.raid_members)
    wipe(self.state.raid_subgroups)
    wipe(self.state.raid_units)
    -- Выход из рейда завершает standby-сессию.
    self:EndStandbySession("left_raid")
    -- Остановить recurring если был
    if Addon.Award and Addon.Award:RunningRecurring() then
      Addon.Award:StopRecurring()
    end
  end
  -- Обновление standby-сессии (детект смены лидера / нового рейда)
  self:UpdateStandbyRaidSession("raid_roster_update")
  if Addon.UI then
    -- Инвалидируем кэш standings при изменении состава рейда
    if Addon.UI.InvalidateStandings then Addon.UI:InvalidateStandings() end
    Addon.UI:RefreshStandings()
  end
end

-- PLAYER_ENTERING_WORLD — инициализация после загрузки.
-- Сначала гильд-лок; при блокировке полная инициализация не выполняется.
function Addon:PLAYER_ENTERING_WORLD()
  self:UpdateGuildLock("player_entering_world")
  if not self:IsEnabled() then
    if Addon.Log then
      Addon.Log:Info("PLAYER_ENTERING_WORLD skipped: guild lock active")
    end
    return
  end
  -- InitDB уже вызван при ADDON_LOADED — не вызываем повторно.
  self:DoWorldInit("player_entering_world")
  -- Авто-очистка старых данных
  Addon:CleanupOldData()
end

-- ============================================================================
-- АВТО-ОЧИСТКА СТАРЫХ ДАННЫХ
-- ============================================================================
-- Вызывается при каждом входе в игру.
-- Очищает:
--   * Лог (Addon.db.global.log) — старше 7 дней (max 2000 записей)
--   * Журнал (Addon.db.global.history) — старше 90 дней (max 5000 записей)
--   * Удаляет пустые/nil поля которые могли накопиться
local pending_on_leave_cleanup = false

-- Отложенная чистка on_leave — вызывается из RosterReady callback
-- (первый реально распарсенный ростер после входа в мир).
function Addon:RunDeferredOnLeaveCleanup()
  if not pending_on_leave_cleanup then return end
  pending_on_leave_cleanup = false
  if not self.db or not self.db.global or not self.db.global.on_leave then return end
  local removed = 0
  local new_on_leave = {}
  for name, _ in pairs(self.db.global.on_leave) do
    if self.data.gold_data[name] or self.data.main_data[name] then
      new_on_leave[name] = true
    else
      removed = removed + 1
    end
  end
  self.db.global.on_leave = new_on_leave
  if removed > 0 and self.Log then
    self.Log:Info("Deferred on_leave cleanup: removed %d entries (left the guild)", removed)
  end
end

function Addon:CleanupOldData()
  if not self.db or not self.db.global then return end
  local g = self.db.global
  local now = time()
  local cleaned = 0

  -- 1. Очистка лога (старше 7 дней)
  if g.log and #g.log > 0 then
    local max_log_age = 7 * 24 * 3600  -- 7 дней
    local max_log_size = 2000
    local new_log = {}
    for _, entry in ipairs(g.log) do
      if entry.time and (now - entry.time) < max_log_age then
        tinsert(new_log, entry)
      else
        cleaned = cleaned + 1
      end
    end
    -- Если всё ещё слишком много — обрезаем
    while #new_log > max_log_size do
      tremove(new_log, 1)
      cleaned = cleaned + 1
    end
    g.log = new_log
  end

  -- 2. Очистка журнала (старше 90 дней)
  if g.history and #g.history > 0 then
    local max_history_age = 90 * 24 * 3600  -- 90 дней
    local max_history_size = 5000
    local new_history = {}
    for _, entry in ipairs(g.history) do
      if entry.time and (now - entry.time) < max_history_age then
        tinsert(new_history, entry)
      else
        cleaned = cleaned + 1
      end
    end
    -- Если всё ещё слишком много — обрезаем
    while #new_history > max_history_size do
      tremove(new_history, 1)
      cleaned = cleaned + 1
    end
    g.history = new_history
  end

  -- 3. Очистка старых backup decay (если есть в памяти)
  -- (last_decay_backup — локальная переменная в Award.lua, не в БД)

  -- 4. Удаляем устаревшие поля из прошлых версий
  g.discord_queue = nil
  g.discord_enabled = nil
  g.discord_webhook_url = nil
  g.discord_last_sent = nil
  g.ep_data = nil  -- старое поле из EPGP-совместимости
  -- nil-assignments — defensive cleanup старых полей в SavedVariables.
  g.auto_decay_last_run = nil
  g.auto_decay_enabled = nil
  g.auto_decay_percent = nil
  g.auto_decay_weekday = nil
  g.auto_decay_hour = nil
  g.last_reset_month = nil

  -- 5. Очистка on_leave от игроков, которых больше нет в гильдии.
  -- Чистим ТОЛЬКО когда ростер реально распарсен (Storage initialized):
  -- GuildRoster() асинхронный, при входе в мир gold_data ещё ПУСТОЙ.
  -- Если ростер ещё не пришёл — чистка будет выполнена отложенно (RosterReady →
  -- RunDeferredOnLeaveCleanup, см. ADDON_LOADED ниже).
  local roster_ready = Addon.Storage and Addon.Storage.IsInitialized and Addon.Storage:IsInitialized()
  if not roster_ready then
    pending_on_leave_cleanup = true
  elseif g.on_leave then
    local new_on_leave = {}
    for name, _ in pairs(g.on_leave) do
      -- Оставляем только если игрок всё ещё в кэше
      if self.data.gold_data[name] or self.data.main_data[name] then
        new_on_leave[name] = true
      else
        cleaned = cleaned + 1
      end
    end
    g.on_leave = new_on_leave
    pending_on_leave_cleanup = false
  end

  if cleaned > 0 and self.Log then
    self.Log:Info("Cleanup: removed %d old entries (log+history+stale data)", cleaned)
  end

  -- Выводим статистику памяти
  local log_size = g.log and #g.log or 0
  local history_size = g.history and #g.history or 0
  local on_leave_count = 0
  if g.on_leave then
    for _ in pairs(g.on_leave) do on_leave_count = on_leave_count + 1 end
  end
  if self.Log then
    self.Log:Debug("Data sizes: log=%d, history=%d, on_leave=%d", log_size, history_size, on_leave_count)
  end
end

-- Команда для ручной очистки
function Addon:ManualCleanup()
  self:CleanupOldData()
  Addon.Print("Очистка выполнена. Лог и журнал очищены от старых записей.")
  Addon.Print(string.format("Текущие размеры: лог=%d, журнал=%d",
    self.db.global.log and #self.db.global.log or 0,
    self.db.global.history and #self.db.global.history or 0))
end

-- PLAYER_GUILD_UPDATE — изменение гильдейского статуса
function Addon:PLAYER_GUILD_UPDATE()
  if Addon.Log then
    Addon.Log:Debug("PLAYER_GUILD_UPDATE")
  end
  if IsInGuild() then
    GuildRoster()
  end
  -- Пересчитать гильд-лок (вступил/вышел из гильдии на лету).
  -- Если гильдия ещё не пришла от сервера — перепроверим в GUILD_ROSTER_UPDATE.
  self:UpdateGuildLock("player_guild_update")
end

-- ============================================================================
-- СТАРТ АДДОНА
-- ============================================================================
Addon:RegisterEvent("ADDON_LOADED")
Addon:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local loaded = ...
    if loaded == "GoldGP" then
      self:UnregisterEvent("ADDON_LOADED")
      if Addon.Log then
        Addon.Log:Info("Addon loaded, initializing DB...")
      end

      -- InitDB вызывается ПРИ ADDON_LOADED (как в EPGP).
      -- SavedVariables (GoldGPDB) уже загружены при ADDON_LOADED.
      InitDB()

      -- Авто-миграция recurring next_award: GetTime() даёт мусор после релога
      -- (секунды с старта сессии), а time() — эпоха. Если значение < 10^9 — сбрасываем.
      if self.db and self.db.profile and self.db.profile.next_award then
        local na = self.db.profile.next_award
        if na < 1000000000 then
          if Addon.Log then
            Addon.Log:Info("Recurring migration: next_award=%d looks like GetTime, clearing", na)
          end
          self.db.profile.next_award = nil
          self.db.profile.next_award_reason = nil
          self.db.profile.next_award_amount = nil
        end
      end

      self:RegisterEvent("PLAYER_ENTERING_WORLD")
      self:RegisterEvent("GUILD_ROSTER_UPDATE")
      self:RegisterEvent("RAID_ROSTER_UPDATE")
      self:RegisterEvent("PLAYER_GUILD_UPDATE")
      self:RegisterEvent("CHAT_MSG_ADDON")

      -- Отложенная чистка on_leave после первого РЕАЛЬНОГО ростера:
      -- CleanupOldData при входе в мир не может чистить on_leave (gold_data пустой),
      -- поэтому помечает чистку как отложенную — выполняем её здесь.
      self:RegisterCallback("RosterReady", function()
        Addon:RunDeferredOnLeaveCleanup()
      end)

      -- Посещаемость: public note (|N) + GuildInfo (@ATT_TOTAL).
      -- Синхронизация через GUILD_ROSTER_UPDATE, не через addon messages.
    end
  else
    local handler = self[event]
    if handler then
      handler(self, ...)
    end
  end
end)

-- Обработчик CHAT_MSG_ADDON для синхронизации между офицерами
function Addon:CHAT_MSG_ADDON(prefix, message, distribution, sender)
  -- Фильтруем только свои сообщения
  if prefix ~= EVENT_PREFIX then return end
  -- Игнорируем свои же сообщения (они приходят обратно)
  if sender then
    local name = strsplit("-", sender) or sender
    if name == UnitName("player") then return end
  end

  -- Гильд-лок: не обрабатываем синхронизацию вне разрешённой гильдии
  if not self:IsEnabled() then return end

  if message == SYNC_MSG_CHANGES_PENDING then
    -- Другой офицер начал запись ноты — его Storage в FLUSHING.
    -- Наш Storage переходит в REMOTE_FLUSHING чтобы не вмешиваться.
    -- EnterRemoteFlushing (обёртка над SetState) обновляет timer/sender ДО
    -- SetState — это позволяет refresh'у таймера при повторных CHANGES_PENDING
    -- (SetState early-returns на same-state, но timer/sender обновятся через
    -- EnterRemoteFlushing).
    if Addon.Storage and Addon.Storage.EnterRemoteFlushing then
      local sender_name = sender and (strsplit("-", sender) or sender) or "unknown"
      Addon.Storage:EnterRemoteFlushing(sender_name)
    elseif Addon.Storage and Addon.Storage.SetState then
      -- Fallback для старых версий Storage (без EnterRemoteFlushing)
      Addon.Storage:SetState("REMOTE_FLUSHING")
    end
    if Addon.Log then
      Addon.Log:Debug("[Sync] Remote officer %s is flushing notes", tostring(sender))
    end
  elseif message == SYNC_MSG_CHANGES_FLUSHED then
    -- Другой офицер завершил запись — перечитываем ноты с сервера
    if Addon.Log then
      Addon.Log:Debug("[Sync] Remote officer %s flushed notes, requesting roster", tostring(sender))
    end
    -- Небольшая задержка чтобы сервер успел применить ноту
    Addon:ScheduleDelayedRosterRequest()
  elseif message:find("^STB_") then
    -- STB-протокол — STB_SET/DEL/CLEAR/REQ/META/CHUNK
    local sender_name = sender and (strsplit("-", sender) or sender) or ""
    -- Формат: STB_COMMAND^sessionId^revision^name (для META/CHUNK/REQ — ^requestId^revision^...)
    local parts = {}
    for part in string.gmatch(message, "([^%^]+)") do
      tinsert(parts, part)
    end
    local stb_cmd = parts[1]  -- "STB_SET", "STB_DEL", ...
    -- Срезаем префикс "STB_" -> "SET", "DEL", "CLEAR", "REQ", "META", "CHUNK"
    local cmd = stb_cmd:gsub("^STB_", "")
    if cmd == "SET" or cmd == "DEL" then
      -- STB_SET^sessionId^revision^name
      local sessionId = parts[2] or ""
      local revision = parts[3] or "0"
      local sname = parts[4] or ""
      self:HandleSTBDelta(sender_name, cmd, sessionId, revision, sname)
    elseif cmd == "CLEAR" then
      -- STB_CLEAR^sessionId^revision
      local sessionId = parts[2] or ""
      local revision = parts[3] or "0"
      self:HandleSTBDelta(sender_name, "CLEAR", sessionId, revision, "")
    elseif cmd == "REQ" then
      -- STB_REQ^sessionId^requestId^knownRevision
      local sessionId = parts[2] or ""
      local requestId = parts[3] or ""
      local knownRev = parts[4] or "0"
      self:HandleSTBReq(sender_name, sessionId, requestId, knownRev)
    elseif cmd == "META" then
      -- STB_META^sessionId^requestId^revision^chunkCount^memberCount
      local sessionId = parts[2] or ""
      local requestId = parts[3] or ""
      local revision = parts[4] or "0"
      local chunkCount = parts[5] or "0"
      local memberCount = parts[6] or "0"
      self:HandleSTBMeta(sender_name, sessionId, requestId, revision, chunkCount, memberCount)
    elseif cmd == "CHUNK" then
      -- STB_CHUNK^sessionId^requestId^revision^index^namesStr
      local sessionId = parts[2] or ""
      local requestId = parts[3] or ""
      local revision = parts[4] or "0"
      local index = parts[5] or "0"
      local namesStr = parts[6] or ""
      self:HandleSTBChunk(sender_name, sessionId, requestId, revision, index, namesStr)
    end
  end
end

-- Отложенный запрос ростера (debounce 1 сек + рандомизация для не-офицеров)
local roster_request_frame = nil
local roster_request_timer = 0
function Addon:ScheduleDelayedRosterRequest()
  if not roster_request_frame then
    roster_request_frame = CreateFrame("Frame")
    roster_request_frame:Hide()
    roster_request_frame:SetScript("OnUpdate", function(self, elapsed)
      roster_request_timer = roster_request_timer - elapsed
      if roster_request_timer <= 0 then
        self:Hide()
        if Addon.Storage and Addon.Storage.OnRosterUpdate then
          Addon.Storage:OnRosterUpdate(false)
        end
        GuildRoster()
      end
    end)
  end
  -- Офицеры запрашивают быстрее (0.5 сек), не-офицеры вразнобой (1.0-2.5 сек) —
  -- предотвращает спам-атаку на сервер при 40+ игроках с аддоном
  if CanEditOfficerNote() then
    roster_request_timer = 0.5
  else
    roster_request_timer = 1.0 + math.random(0, 150) / 100
  end
  roster_request_frame:Show()
end

-- ============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (для других модулей)
-- ============================================================================

-- Проверка, может ли игрок редактировать офицерские ноты
function Addon:CanEditOfficerNote()
  return CanEditOfficerNote()
end

-- ============================================================================
-- STANDBY RAID-LEADER SESSION
-- ============================================================================
-- Standby-список существует только для текущего рейда и текущего лидера рейда.
-- Без восстановления из SavedVariables: сессия стартует пустой при каждом входе
-- в рейд / назначении лидера и стирается при релоге/выходе/смене лидера.
-- ============================================================================

-- Локальный счётчик sequence для id сессий
local standby_session_seq = 0

-- Имя текущего лидера рейда: скан GetRaidRosterInfo по rank==2.
-- nil, если не в рейде или лидер не найден.
-- Fallback через IsRaidLeader(): если скан rank==2 не нашёл лидера
-- (квирки приваток / свежая смена лидера, когда ростер ещё не обновился),
-- а мы сами лидер — возвращаем себя. Иначе standby-сессия залипает без лидера.
function Addon:GetCurrentRaidLeaderName()
  local numRaid = GetNumRaidMembers()
  if numRaid == 0 then return nil end
  for i = 1, numRaid do
    local name, rank = GetRaidRosterInfo(i)
    if name and rank == 2 then
      return strsplit("-", name) or name
    end
  end
  -- Fallback: мы лидер, но rank==2 ещё не виден в ростере
  if IsRaidLeader and IsRaidLeader() then
    return UnitName("player")
  end
  return nil
end

-- Текущий игрок — лидер рейда?
function Addon:IsCurrentRaidLeader()
  local leader = self:GetCurrentRaidLeaderName()
  if not leader then return false end
  return leader == UnitName("player")
end

-- ============================================================================
-- ТАЙМАУТ SNAPSHOT-ПРИЁМА
-- ============================================================================
-- meta_received_at — метка получения STB_META. Если STB_CHUNK не долетели за
-- STANDBY_SNAPSHOT_TIMEOUT сек — сбрасываем snapshot-состояние и сообщаем
-- игроку (live-список замен НЕ трогаем — атомарность сохранена).
-- ============================================================================
local STANDBY_SNAPSHOT_TIMEOUT = 10   -- сек на приём всех STB_CHUNK после STB_META
local standby_snapshot_watch_frame = nil

local function StartStandbySnapshotWatch()
  if not standby_snapshot_watch_frame then
    standby_snapshot_watch_frame = CreateFrame("Frame")
    standby_snapshot_watch_frame:Hide()
    standby_snapshot_watch_frame.elapsed = 0
    standby_snapshot_watch_frame:SetScript("OnUpdate", function(self, elapsed)
      -- Проверяем раз в ~1 сек (ленивый скрытый фрейм, не каждый кадр)
      self.elapsed = (self.elapsed or 0) + elapsed
      if self.elapsed < 1.0 then return end
      self.elapsed = 0
      local snap = Addon.state.standby_snapshot
      if (snap.meta_received_at or 0) <= 0 then
        self:Hide()
        return
      end
      if (GetTime() - snap.meta_received_at) >= STANDBY_SNAPSHOT_TIMEOUT then
        -- Сброс snapshot-состояния (live standby не менялся — он заменяется
        -- только при полном приёме всех chunks)
        snap.request_id = nil
        snap.expected_chunks = 0
        snap.received_chunks = {}
        snap.pending_names = {}
        snap.meta_received_at = 0
        self:Hide()
        Addon.Print("Standby: snapshot не получен от лидера (таймаут). Повторите /gg standby sync")
        if Addon.Log then
          Addon.Log:Warn("[Standby] snapshot timeout after %ds — pending state reset", STANDBY_SNAPSHOT_TIMEOUT)
        end
      end
    end)
  end
  standby_snapshot_watch_frame.elapsed = 0
  standby_snapshot_watch_frame:Show()
end

local function StopStandbySnapshotWatch()
  if standby_snapshot_watch_frame then
    standby_snapshot_watch_frame:Hide()
  end
end

-- Начать новую standby-сессию для лидера рейда.
function Addon:BeginStandbySession(leaderName)
  standby_session_seq = standby_session_seq + 1
  self.state.standby_session.id = tostring(time()) .. ":" .. tostring(leaderName) .. ":" .. tostring(standby_session_seq)
  self.state.standby_session.leader = leaderName
  self.state.standby_session.active = true
  self.state.standby_session.revision = 0
  -- Стартуем с пустым списком (НИКОГДА не восстанавливать из SavedVariables)
  self.state.standby = {}
  if self.Log then
    self.Log:Info("[Standby] Session begin: id=%s leader=%s", self.state.standby_session.id, tostring(leaderName))
  end
end

-- Завершить текущую standby-сессию — сброс всего: отложенные отправки snapshot,
-- snapshot-состояние (pending_names + meta_received_at), список замен, сессия.
function Addon:EndStandbySession(reason)
  if self.Log then
    self.Log:Info("[Standby] Session end: reason=%s id=%s", tostring(reason), tostring(self.state.standby_session.id))
  end
  -- Отменить отложенные отправки snapshot-чанков
  self:CancelStandbySnapshotSend()
  -- Сброс pending snapshot-состояния
  self.state.standby_snapshot.request_id = nil
  self.state.standby_snapshot.expected_chunks = 0
  self.state.standby_snapshot.received_chunks = {}
  self.state.standby_snapshot.pending_names = {}
  self.state.standby_snapshot.meta_received_at = 0
  -- Остановить таймаут-watch (если ждали chunks)
  StopStandbySnapshotWatch()
  -- Очистить standby-список
  self.state.standby = {}
  -- Сброс состояния сессии
  self.state.standby_session.id = nil
  self.state.standby_session.leader = nil
  self.state.standby_session.active = false
  self.state.standby_session.revision = 0
  -- НЕ писать в SavedVariables — список эфемерный
  -- Обновление UI
  if self.UI and self.UI.RefreshStandings then
    self.UI:InvalidateStandings()
    self.UI:RefreshStandings()
    if self.UI.RefreshStandbyWindow then self.UI:RefreshStandbyWindow() end
  end
end

-- Единый обработчик изменений состава рейда.
-- Вызывается из RAID_ROSTER_UPDATE и PLAYER_ENTERING_WORLD.
function Addon:UpdateStandbyRaidSession(reason)
  local newLeader = self:GetCurrentRaidLeaderName()
  local oldLeader = self.state.standby_session.leader

  if not newLeader then
    -- Не в рейде или нет лидера — завершаем активную сессию
    if self.state.standby_session.active then
      self:EndStandbySession("left_raid_or_no_leader")
    end
    return
  end

  if not oldLeader or not self.state.standby_session.active then
    -- Новая сессия (была неактивна)
    self:BeginStandbySession(newLeader)
    Addon.Print(string.format("Standby: новый лидер рейда %s. Список замен пуст.", newLeader))
    return
  end

  if oldLeader ~= newLeader then
    -- Смена лидера — полный сброс, список не переносится
    self:EndStandbySession("leader_changed_" .. tostring(oldLeader) .. "_to_" .. tostring(newLeader))
    self:BeginStandbySession(newLeader)
    Addon.Print(string.format("Standby: смена лидера рейда (%s -> %s). Список замен очищен.", tostring(oldLeader), newLeader))
    return
  end

  -- Лидер тот же — сессия продолжается, ничего не делаем
end

-- ============================================================================
-- STANDBY (замена)
-- ============================================================================

-- Проверить, на замене ли игрок
function Addon:IsStandby(name)
  return self.state.standby[name] == true
end

-- SetStandby — мутации только у текущего лидера рейда (STB-протокол с
-- sessionId + revision). Плюс офицерский гейт (CanEditOfficerNote): «Замены» —
-- полностью офицерская функция, не-офицеры не управляют списком даже если
-- они лидеры рейда. Приём STB-дельт (синхронизация отображения) НЕ гейтится —
-- иначе у офицеров сломается отображение.
function Addon:SetStandby(name, on_standby)
  -- Офицерский гейт
  if not (self.state and self.state.can_edit) then
    self.PrintError("Управлять заменами могут только офицеры (право редактирования офицерских заметок)")
    return false
  end
  -- Гейт лидера рейда
  if not self:IsCurrentRaidLeader() then
    self.PrintError("Только текущий лидер рейда принимает игроков на замену")
    return false
  end
  -- Идемпотентность: состояние уже такое — пропускаем
  if self.state.standby[name] == on_standby then
    return false
  end
  -- Сессия должна быть активна
  if not self.state.standby_session.active then
    self.PrintError("Standby session не активна (нет рейда?)")
    return false
  end
  -- Применяем изменение
  if on_standby then
    self.state.standby[name] = true
    if self.Log then self.Log:Info("[Standby] %s - на замене (rev=%d)", name, self.state.standby_session.revision) end
  else
    self.state.standby[name] = nil
    if self.Log then self.Log:Info("[Standby] %s - снят с замены (rev=%d)", name, self.state.standby_session.revision) end
  end
  -- Инкремент revision
  self.state.standby_session.revision = self.state.standby_session.revision + 1
  -- Рассылка STB-дельты в RAID (не GUILD)
  local msg = string.format("STB_%s^%s^%d^%s",
    on_standby and "SET" or "DEL",
    self.state.standby_session.id,
    self.state.standby_session.revision,
    tostring(name))
  pcall(function()
    local channel = GetNumRaidMembers() > 0 and "RAID" or "GUILD"
    SendAddonMessage(EVENT_PREFIX, msg, channel)
  end)
  -- Обновление UI
  if self.UI and self.UI.RefreshStandings then
    self.UI:InvalidateStandings()
    self.UI:RefreshStandings()
    if self.UI.RefreshStandbyWindow then self.UI:RefreshStandbyWindow() end
  end
  return true
end

-- LoadStandby НЕ восстанавливает список из SavedVariables —
-- только разовая миграция: wipe старого persisted standby_list.
function Addon:LoadStandby()
  if self.db and self.db.global and self.db.global.standby_list then
    -- Разовая миграция: wipe старого persisted-списка
    wipe(self.db.global.standby_list)
    self.db.global.standby_list = nil
    if self.Log then
      self.Log:Info("[Standby] Old persistent standby_list wiped (migration)")
    end
  end
  -- Никакого восстановления standby — список стартует пустым
  self.state.standby = {}
end

-- ClearStandby — только текущий лидер рейда.
function Addon:ClearStandby()
  if not self:IsCurrentRaidLeader() then
    self.PrintError("Только текущий лидер рейда может очистить список замен")
    return false
  end
  if not self.state.standby_session.active then
    self.PrintError("Standby session не активна")
    return false
  end
  wipe(self.state.standby)
  self.state.standby_session.revision = self.state.standby_session.revision + 1
  -- Broadcast STB_CLEAR
  local msg = string.format("STB_CLEAR^%s^%d", self.state.standby_session.id, self.state.standby_session.revision)
  pcall(function()
    local channel = GetNumRaidMembers() > 0 and "RAID" or "GUILD"
    SendAddonMessage(EVENT_PREFIX, msg, channel)
  end)
  if self.Log then self.Log:Info("[Standby] Список очищен (rev=%d)", self.state.standby_session.revision) end
  if self.UI and self.UI.RefreshStandings then
    self.UI:InvalidateStandings()
    self.UI:RefreshStandings()
    if self.UI.RefreshStandbyWindow then self.UI:RefreshStandbyWindow() end
  end
  return true
end

-- Запросить snapshot у текущего лидера рейда.
-- Отправляет STB_REQ в RAID-канал. Cooldown 3 секунды.
function Addon:RequestStandbySnapshot(reason)
  local now = GetTime()
  if now - self.state.standby_snapshot.cooldown < 3.0 then
    if self.Log then self.Log:Debug("[Standby] Snapshot request on cooldown (%.1fs)", now - self.state.standby_snapshot.cooldown) end
    return false
  end
  self.state.standby_snapshot.cooldown = now
  -- Уникальный requestId
  local requestId = tostring(time()) .. ":" .. tostring(math.random(1, 99999))
  self.state.standby_snapshot.request_id = requestId
  self.state.standby_snapshot.expected_chunks = 0
  self.state.standby_snapshot.received_chunks = {}
  -- Мы и есть лидер — список уже локальный, запрос не нужен
  if self:IsCurrentRaidLeader() then
    if self.Log then self.Log:Debug("[Standby] We are leader — no snapshot needed") end
    return true
  end
  -- Отправка STB_REQ — пустой sessionId, если он ещё неизвестен
  local sessionId = self.state.standby_session.id or ""
  local knownRev = self.state.standby_session.revision or 0
  local msg = string.format("STB_REQ^%s^%s^%d", sessionId, requestId, knownRev)
  pcall(function()
    SendAddonMessage(EVENT_PREFIX, msg, "RAID")
  end)
  if self.Log then self.Log:Info("[Standby] Snapshot requested (req=%s, reason=%s)", requestId, tostring(reason)) end
  if self.Print then
    self.Print("Standby: запрос snapshot у лидера рейда...")
  end
  return true
end

-- Очередь отправки snapshot с троттлингом через OnUpdate:
-- предотвращает rate-limit / потерю чанков от плотного цикла SendAddonMessage.
-- Активна одна отправка за раз. Отменяется в EndStandbySession.
local standby_send_queue = {}        -- очередь сообщений {msg, target}
local standby_send_frame = nil       -- OnUpdate-фрейм, разгребающий очередь
local standby_send_interval = 0.3   -- интервал между сообщениями (сек)
local standby_send_timer = 0

local function standby_send_frame_init()
  if standby_send_frame then return end
  standby_send_frame = CreateFrame("Frame")
  standby_send_frame:Hide()
  standby_send_frame:SetScript("OnUpdate", function(self, elapsed)
    standby_send_timer = standby_send_timer + elapsed
    if standby_send_timer < standby_send_interval then return end
    standby_send_timer = 0
    -- Забираем одно сообщение из очереди
    local entry = tremove(standby_send_queue, 1)
    if not entry then
      self:Hide()
      return
    end
    pcall(function()
      SendAddonMessage(EVENT_PREFIX, entry.msg, "WHISPER", entry.target)
    end)
  end)
end

-- Отменить все отложенные отправки snapshot (вызывается из EndStandbySession).
function Addon:CancelStandbySnapshotSend()
  wipe(standby_send_queue)
  if standby_send_frame then standby_send_frame:Hide() end
  standby_send_timer = 0
end

-- Лидер шлёт snapshot-чанки в WHISPER запросившему.
-- Очередь с троттлингом OnUpdate: META уходит сразу, чанки — с интервалом 0.3с.
-- Активна одна отправка за раз — новый запрос отменяет старую очередь.
function Addon:SendStandbySnapshot(requesterName, requestId)
  if not self:IsCurrentRaidLeader() then return end
  if not self.state.standby_session.active then return end
  local sessionId = self.state.standby_session.id
  local revision = self.state.standby_session.revision
  -- Собираем имена со standby
  local names = {}
  for name, _ in pairs(self.state.standby) do
    tinsert(names, name)
  end
  local memberCount = #names
  -- Режем на чанки (макс ~200 байт на сообщение, ~12 символов на имя + запятая)
  local chunks = {}
  local currentChunk = {}
  local currentLen = 0
  for i, name in ipairs(names) do
    local nameLen = #name + 1  -- имя + запятая
    if currentLen + nameLen > 200 then
      tinsert(chunks, currentChunk)
      currentChunk = {}
      currentLen = 0
    end
    tinsert(currentChunk, name)
    currentLen = currentLen + nameLen
  end
  if #currentChunk > 0 then tinsert(chunks, currentChunk) end
  local chunkCount = #chunks
  -- Отменяем предыдущую отложенную отправку
  self:CancelStandbySnapshotSend()
  -- Инициализация отправляющего фрейма
  standby_send_frame_init()
  -- STB_META уходит сразу (первое сообщение, без задержки)
  local metaMsg = string.format("STB_META^%s^%s^%d^%d^%d", sessionId, requestId, revision, chunkCount, memberCount)
  pcall(function()
    SendAddonMessage(EVENT_PREFIX, metaMsg, "WHISPER", requesterName)
  end)
  -- Ставим STB_CHUNK в очередь с троттлинг-интервалом
  for i, chunk in ipairs(chunks) do
    local chunkStr = table.concat(chunk, ",")
    local chunkMsg = string.format("STB_CHUNK^%s^%s^%d^%d^%s", sessionId, requestId, revision, i, chunkStr)
    tinsert(standby_send_queue, { msg = chunkMsg, target = requesterName })
  end
  -- Запускаем разгребание очереди
  if #standby_send_queue > 0 then
    standby_send_timer = standby_send_interval  -- send first chunk on next OnUpdate tick
    standby_send_frame:Show()
  end
  if self.Log then self.Log:Info("[Standby] Snapshot queued to %s: %d chunks, %d members (throttled)", requesterName, chunkCount, memberCount) end
end

-- Применить STB-дельту (SET/DEL/CLEAR) — с проверкой sender + sessionId.
-- Revision должна быть СТРОГО НОВЕЕ локальной: задержавшиеся дельты с той же
-- или старой revision отвергаются.
function Addon:HandleSTBDelta(sender, command, sessionId, revision, name)
  -- sender должен быть текущим лидером рейда
  local leader = self:GetCurrentRaidLeaderName()
  if not leader or sender ~= leader then
    if self.Log and self.Log.Debug then
      self.Log:Debug("[Standby] Ignored %s from non-leader %s (leader=%s)", command, tostring(sender), tostring(leader))
    end
    return
  end
  -- sessionId должен совпадать с локальной сессией
  if not self.state.standby_session.active then
    -- Локальная сессия не активна — пробуем начать
    self:UpdateStandbyRaidSession("stb_delta_no_session")
    if not self.state.standby_session.active then return end
  end
  if self.state.standby_session.id ~= sessionId then
    if self.Log and self.Log.Debug then
      self.Log:Debug("[Standby] Ignored %s: sessionId mismatch (local=%s remote=%s)", command, self.state.standby_session.id, sessionId)
    end
    return
  end
  local revNum = tonumber(revision) or 0
  if revNum <= self.state.standby_session.revision then
    if self.Log and self.Log.Debug then
      self.Log:Debug("[Standby] Ignored %s: stale revision %d <= local %d", command, revNum, self.state.standby_session.revision)
    end
    return
  end
  -- Применяем дельту
  if command == "SET" then
    self.state.standby[name] = true
  elseif command == "DEL" then
    self.state.standby[name] = nil
  elseif command == "CLEAR" then
    wipe(self.state.standby)
  end
  -- Обновляем revision (гарантированно новее — безопасно присвоить)
  self.state.standby_session.revision = revNum
  -- Обновление UI
  if self.UI and self.UI.RefreshStandings then
    self.UI:InvalidateStandings()
    self.UI:RefreshStandings()
    if self.UI.RefreshStandbyWindow then self.UI:RefreshStandbyWindow() end
  end
end

-- Обработка STB_REQ — отвечает только лидер.
function Addon:HandleSTBReq(sender, sessionId, requestId, knownRevision)
  if not self:IsCurrentRaidLeader() then return end
  -- Ответ — snapshot с текущими sessionId/revision
  self:SendStandbySnapshot(sender, requestId)
end

-- Обработка STB_META — начало приёма snapshot.
-- НЕ очищает live state.standby: имена накапливаются в pending_names, live state
-- заменяется ТОЛЬКО после получения всех chunks в HandleSTBChunk.
-- При том же sessionId revision должна быть СТРОГО НОВЕЕ — задержавшийся
-- snapshot с той же/старой revision отвергается. При другом sessionId
-- (адаптация новой сессии) проверка revision пропускается — новая сессия
-- стартует с нуля, revision 0 лидера валидна.
function Addon:HandleSTBMeta(sender, sessionId, requestId, revision, chunkCount, memberCount)
  -- sender должен быть текущим лидером рейда
  local leader = self:GetCurrentRaidLeaderName()
  if not leader or sender ~= leader then return end
  local revNum = tonumber(revision) or 0
  local isSameSession = self.state.standby_session.id == sessionId and self.state.standby_session.active
  if isSameSession and revNum <= self.state.standby_session.revision then
    if self.Log and self.Log.Debug then
      self.Log:Debug("[Standby] Ignored STB_META: stale revision %d <= local %d (same session)", revNum, self.state.standby_session.revision)
    end
    return
  end
  -- Чужой sessionId — адаптируем сессию лидера, но НЕ чистим live standby
  if not isSameSession then
    self.state.standby_session.id = sessionId
    self.state.standby_session.leader = leader
    self.state.standby_session.active = true
    -- НЕ очищаем self.state.standby — live state остаётся до атомарной замены
  end
  -- Инициализация tracking'а snapshot
  self.state.standby_snapshot.request_id = requestId
  self.state.standby_snapshot.expected_chunks = tonumber(chunkCount) or 0
  self.state.standby_snapshot.received_chunks = {}
  -- Инициализируем pending_names (временный буфер)
  self.state.standby_snapshot.pending_names = {}
  self.state.standby_snapshot.meta_received_at = GetTime()
  -- Запускаем таймаут-watch (chunks должны долететь за 10 сек)
  -- ПУСТОЙ snapshot (chunkCount=0) — apply ниже сам сбрасывает состояние,
  -- там же останавливаем watch.
  if self.state.standby_snapshot.expected_chunks > 0 then
    StartStandbySnapshotWatch()
  end
  -- Пустой snapshot (chunkCount=0) — атомарно применяем пустой список,
  -- если revision допустима (проверка выше).
  if self.state.standby_snapshot.expected_chunks == 0 then
    -- Пустой список от лидера — атомарно заменяем live state
    wipe(self.state.standby)
    self.state.standby_session.revision = revNum
    self.state.standby_snapshot.request_id = nil
    self.state.standby_snapshot.expected_chunks = 0
    self.state.standby_snapshot.pending_names = {}
    self.state.standby_snapshot.meta_received_at = 0
    -- Чанков не ждали — watch не нужен
    StopStandbySnapshotWatch()
    if self.UI and self.UI.RefreshStandings then
      self.UI:InvalidateStandings()
      self.UI:RefreshStandings()
      if self.UI.RefreshStandbyWindow then self.UI:RefreshStandbyWindow() end
    end
    if self.Print then
      self.Print(string.format("Standby: snapshot получен от %s, 0 игроков (пустой список)", tostring(leader)))
    end
  end
end

-- Обработка STB_CHUNK — накопление и атомарное применение по готовности.
-- Имена накапливаются в pending_names. Live state.standby заменяется ТОЛЬКО
-- после получения ВСЕХ chunks. При потере chunks старый список сохраняется,
-- partial snapshot не применяется.
function Addon:HandleSTBChunk(sender, sessionId, requestId, revision, index, namesStr)
  -- sender должен быть текущим лидером рейда
  local leader = self:GetCurrentRaidLeaderName()
  if not leader or sender ~= leader then return end
  -- Должен совпадать с ожидающимся snapshot'ом
  if self.state.standby_snapshot.request_id ~= requestId then return end
  if self.state.standby_snapshot.expected_chunks == 0 then return end
  -- Кладём чанк в received_chunks для контроля полноты
  self.state.standby_snapshot.received_chunks[tonumber(index) or 0] = namesStr
  -- Накапливаем имена в pending_names (временный буфер, НЕ live state)
  for name in string.gmatch(namesStr, "([^,]+)") do
    self.state.standby_snapshot.pending_names[name] = true
  end
  -- Проверка: все ли чанки получены
  local receivedCount = 0
  for _ in pairs(self.state.standby_snapshot.received_chunks) do receivedCount = receivedCount + 1 end
  if receivedCount < self.state.standby_snapshot.expected_chunks then
    return  -- Ждём остальные чанки — live state не трогаем
  end
  -- Все чанки получены — АТОМАРНАЯ замена live state:
  -- строим новый standby из pending_names
  local newStandby = {}
  for name, _ in pairs(self.state.standby_snapshot.pending_names) do
    newStandby[name] = true
  end
  -- Атомарно заменяем live state
  wipe(self.state.standby)
  for name, _ in pairs(newStandby) do
    self.state.standby[name] = true
  end
  -- Обновляем revision сессии
  self.state.standby_session.revision = tonumber(revision) or self.state.standby_session.revision
  -- Сброс snapshot-состояния
  self.state.standby_snapshot.request_id = nil
  self.state.standby_snapshot.expected_chunks = 0
  self.state.standby_snapshot.received_chunks = {}
  self.state.standby_snapshot.pending_names = {}
  self.state.standby_snapshot.meta_received_at = 0
  -- Snapshot полностью применён — таймаут-watch больше не нужен
  StopStandbySnapshotWatch()
  -- Обновление UI
  if self.UI and self.UI.RefreshStandings then
    self.UI:InvalidateStandings()
    self.UI:RefreshStandings()
    if self.UI.RefreshStandbyWindow then self.UI:RefreshStandbyWindow() end
  end
  local count = 0
  for _ in pairs(self.state.standby) do count = count + 1 end
  if self.Print then
    self.Print(string.format("Standby: snapshot получен от %s, %d игроков", tostring(leader), count))
  end
end

-- Whisper-фильтр: обрабатывает "Замена" только текущий лидер рейда.
-- string.trim в Lua/WoW 3.3.5a НЕ существует — используем FrameXML-глобал
-- strtrim с gsub-fallback (trim_lower).
local standby_filter_installed = false
local standby_last_reply_time = 0

local function trim_lower(msg)
  local s = msg:lower()
  if strtrim then return strtrim(s) end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Addon:HookWhisperForStandby()
  if standby_filter_installed then return end
  standby_filter_installed = true

  local function standby_filter(self, event, msg, sender, ...)
    if event ~= "CHAT_MSG_WHISPER" then return end
    if not msg or not sender then return end

    -- Обрабатывает standby-шепоты только текущий лидер рейда
    -- + офицерский гейт — функция «Замены» полностью офицерская.
    if not Addon:IsCurrentRaidLeader()
       or not (Addon.state and Addon.state.can_edit) then
      -- Не лидер рейда (или не офицер) — если это standby-команда, подсказываем лидера
      local lower_msg = trim_lower(msg)
      if lower_msg == "standby" or lower_msg == "замена" or
         lower_msg == "standby+" or lower_msg == "замена+" or
         lower_msg == "sb" or lower_msg == "sb+" or
         lower_msg == "standby-" or lower_msg == "замена-" or
         lower_msg == "-standby" or lower_msg == "-замена" or
         lower_msg == "sb-" then
        -- Отвечаем именем текущего лидера
        local leader = Addon:GetCurrentRaidLeaderName()
        local now = GetTime()
        if (now - standby_last_reply_time) > 2.0 then
          local name = strsplit("-", sender)
          if leader then
            SendChatMessage("GoldGP: Напишите \"Замена\" текущему лидеру рейда: " .. leader, "WHISPER", nil, name)
          else
            SendChatMessage("GoldGP: Лидер рейда не найден. Standby недоступен.", "WHISPER", nil, name)
          end
          standby_last_reply_time = now
        end
        return false  -- Пропускаем шепот дальше в чат
      end
      return false
    end

    local lower_msg = trim_lower(msg)
    local name = strsplit("-", sender)
    local in_guild = Addon.data.gold_data[name] or Addon.data.main_data[name]
    if not in_guild then return end

    local now = GetTime()
    local can_reply = (now - standby_last_reply_time) > 2.0

    if lower_msg == "standby" or lower_msg == "замена" or
       lower_msg == "standby+" or lower_msg == "замена+" or
       lower_msg == "sb" or lower_msg == "sb+" then
      Addon:SetStandby(name, true)
      if can_reply then
        SendChatMessage("GoldGP: Вы на замене (standby). EP будет начисляться.", "WHISPER", nil, name)
        standby_last_reply_time = now
      end
      return false
    end

    if lower_msg == "standby-" or lower_msg == "замена-" or
       lower_msg == "-standby" or lower_msg == "-замена" or
       lower_msg == "sb-" then
      Addon:SetStandby(name, false)
      if can_reply then
        SendChatMessage("GoldGP: Сняты с замены.", "WHISPER", nil, name)
        standby_last_reply_time = now
      end
      return false
    end

    return false
  end

  ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", standby_filter)
  if self.Log then
    self.Log:Info("Whisper filter for standby installed (raid-leader-only)")
  end
end

-- Кандидат на начисление: в рейде или на замене (вне рейда — все)
function Addon:IsInAwardList(name)
  -- Игроки "в отпуске" никогда не получают EP/GP
  if self.data.on_leave[name] then
    return false
  end
  if self.state.in_raid then
    -- standby тоже получают EP (как extras)
    return self.state.raid_members[name] or self.state.standby[name]
  else
    return true  -- если не в рейде — все получают
  end
end

-- Является ли имя "дополнительным" (extras): standby — это extras
function Addon:IsInExtrasList(name)
  return self.state.standby[name] == true
end

-- Получить номер партии игрока в рейде (1..8) или nil если не в рейде
function Addon:GetSubgroup(name)
  return self.state.raid_subgroups[name]
end

-- Вычислить фактический amount для игрока с учётом party-split
-- Если party_split_enabled = true:
--   subgroup 1..threshold -> 100% (amount как есть)
--   subgroup (threshold+1)..8 -> party_split_percent % от amount
--   extras (не в рейде) -> amount передаётся как есть, не модифицируем
-- Возвращает: adjusted_amount, multiplier (для лога)
function Addon:GetPartyAdjustedAmount(name, amount)
  local p = self.db and self.db.profile or nil
  if not p or not p.party_split_enabled then
    return amount, 1.0
  end
  -- Если игрок не в рейде (например, extras) — full amount
  local sg = self.state.raid_subgroups[name]
  if not sg or sg == 0 then
    return amount, 1.0
  end
  local threshold = p.party_split_threshold or 5
  if sg <= threshold then
    return amount, 1.0
  else
    local pct = p.party_split_percent or 50
    local adjusted = math.floor(amount * pct / 100)
    return adjusted, pct / 100
  end
end

-- Получить Gold/GP/main для имени
function Addon:GetMemberData(name)
  local main = self.data.main_data[name]
  if main then
    name = main
  end
  if self.data.gold_data[name] ~= nil then
    local base_gp = (self.db and self.db.profile and self.db.profile.base_gp) or 0
    -- nil guard для gp_data (race condition при загрузке ростера)
    local gp = self.data.gp_data[name] or 0
    return self.data.gold_data[name], gp + base_gp, main
  end
  return nil, nil, nil
end

-- ============================================================================
-- МНОГОСЛОЙНЫЙ РЕЗОЛВ КЛАССА
-- ============================================================================
-- class_data пишется ТОЛЬКО из гильд-ростера (локализованное имя -> токен),
-- и любое отклонение сервера/клиента (nil, битая строка, локаль) оставляет
-- игрока без иконки. Поэтому — авторитетная цепочка источников:
--   1. class_data[name] (гильд-ростер, токен после нормализации в Storage);
--   2. class_data[main] (альт наследует класс мейна);
--   3. ЖИВОЙ UnitClass если игрок в рейде (state.raid_units — токен из
--      GetRaidRosterInfo, обновляется в RAID_ROSTER_UPDATE) или в группе.
-- Возвращает АНГЛИЙСКИЙ токен (WARRIOR/...) или nil.
function Addon:GetClassToken(name, main)
  if not name then return nil end
  local known = self.CLASS_TOKENS
  local is_token = function(v)
    return v ~= nil and (known == nil or known[v]) and true or false
  end
  -- 1-2. Кэш ростера (свой + мейна)
  local cd = self.data and self.data.class_data
  if cd then
    local c = cd[name]
    if is_token(c) then return c end
    if main and main ~= name then
      c = cd[main]
      if is_token(c) then return c end
    end
  end
  -- 3a. Рейд: токен снят в RAID_ROSTER_UPDATE (O(1) lookup)
  local ru = self.state and self.state.raid_units
  if ru and ru[name] then
    local c = ru[name]
    if is_token(c) then return c end
  end
  -- 3b. Группа: живой UnitClass (O(5), вызывается только при пустом кэше)
  if self.state and self.state.raid_members and self.state.raid_members[name] then
    -- в рейде, но raid_units ещё не готов — пробуем напрямую
    for i = 1, GetNumRaidMembers() do
      local rname = GetRaidRosterInfo(i)
      if rname then
        rname = strsplit("-", rname)
        if rname == name then
          local c = select(2, UnitClass("raid" .. i))
          if is_token(c) then return c end
          break
        end
      end
    end
  elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
    local pname = UnitName("player")
    if pname == name then
      local c = select(2, UnitClass("player"))
      if is_token(c) then return c end
    else
      for i = 1, GetNumPartyMembers() do
        if UnitName("party" .. i) == name then
          local c = select(2, UnitClass("party" .. i))
          if is_token(c) then return c end
          break
        end
      end
    end
  end
  return nil
end

-- Множество валидных токенов (для проверки в GetClassToken).
-- ИНИЦИАЛИЗИРУЕТСЯ В GoldGP_UIKit.lua (из CLASS_ICON_TCOORDS; UIKit грузится
-- сразу после Core — к моменту вызовов GetClassToken оно уже заполнено).
Addon.CLASS_TOKENS = nil

-- ============================================================================
-- ДИАГНОСТИКА КЛАССОВ (/gg classdiag)
-- ============================================================================
-- Причина «нет иконки класса» почти всегда — сервер вернул строку класса,
-- которой нет в мапе локализация→токен. Команда печатает в чат ВСЕ различающиеся
-- строки классов из гильд-ростера (RAW, как их отдал сервер) с результатом
-- маппинга и примерами по игрокам. Вывод копируется и присылается разработчику.
function Addon:GetClassDiagnostics()
  local function out(msg)
    if DEFAULT_CHAT_FRAME then
      DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r: " .. tostring(msg))
    end
  end

  local locale = "unknown"
  pcall(function() locale = GetLocale() end)
  local tokens_n = 0
  if self.CLASS_TOKENS then
    for _ in pairs(self.CLASS_TOKENS) do tokens_n = tokens_n + 1 end
  end
  out(string.format("=== classdiag: локаль=%s, токенов в whitelist=%d ===", locale, tokens_n))

  if not GetNumGuildMembers or GetNumGuildMembers() == 0 then
    out("Гильд-ростер пуст — откройте /gg (или /gg refresh), подождите 2-3 сек и повторите /gg classdiag")
    return
  end

  local normalize = self.DebugNormalizeClassToken  -- диагностический экспорт Storage
  local distinct = {}   -- [raw] = { count, token, sample }
  local order = {}
  local no_class = {}   -- игроки без строки класса (сервер не отдал class)
  local total = GetNumGuildMembers()
  for i = 1, total do
    local name, _, _, _, class = GetGuildRosterInfo(i)
    if name then
      name = strsplit("-", name)
      if class and class ~= "" then
        local d = distinct[class]
        if not d then
          d = { count = 0, token = nil, sample = name }
          distinct[class] = d
          tinsert(order, class)
        end
        d.count = d.count + 1
        if not d.token and normalize then
          d.token = normalize(class)
        end
      else
        -- Показываем явно: молчаливый пропуск даёт итог «не мапится=0»
        -- при игроке без иконки.
        if #no_class < 5 then no_class[#no_class + 1] = name end
      end
    end
  end

  table.sort(order, function(a, b) return distinct[a].count > distinct[b].count end)
  local unknown_n = 0
  for _, raw in ipairs(order) do
    local d = distinct[raw]
    if d.token then
      out(string.format("  «%s» ×%d → %s  (пример: %s)", raw, d.count, d.token, d.sample))
    else
      unknown_n = unknown_n + 1
      out(string.format("  «%s» ×%d → ??? НЕ МАПИТСЯ  (пример: %s)", raw, d.count, d.sample))
    end
  end

  out(string.format("Итог: уникальных строк класса=%d, не мапится=%d", #order, unknown_n))
  if #no_class > 0 then
    out(string.format("Без строки класса: %d (примеры: %s) — у них иконки нет по другой причине; попробуйте /gg refresh и повторите",
      #no_class, table.concat(no_class, ", ")))
  end
  if unknown_n > 0 then
    out("Скопируйте вывод выше и пришлите разработчику — по нему добавлю недостающие строки.")
  else
    out("Все строки ростера мапятся. Если у кого-то иконки всё равно нет — /gg refresh, подождите 3 сек и повторите classdiag.")
  end
end

-- Получить main для имени (если alt — вернёт main, иначе self)
function Addon:GetMain(name)
  return self.data.main_data[name] or name
end

-- ============================================================================
-- СТАТУС "В ОТПУСКЕ"
-- ============================================================================

-- Проверить, в отпуске ли игрок
function Addon:IsOnLeave(name)
  return self.data.on_leave[name] == true
end

-- Установить/снять статус "в отпуске".
-- Статус синхронизируется ВСЕМ офицерам через маркер [ОТП] в офицерской ноте.
-- Alt резолвится в main.
function Addon:SetOnLeave(name, on_leave)
  -- Проверка прав — не-офицер не должен менять отпуск (on_leave хранится локально).
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты — изменение статуса отпуска невозможно")
    if self.Log then
      self.Log:Warn("SetOnLeave: no permission for %s (CanEditOfficerNote=false)", tostring(name))
    end
    return false
  end
  -- alt → main (флаги и маркер держим ТОЛЬКО на main, у альта нота = имя main'а)
  local main = (self.data.main_data and self.data.main_data[name]) or name
  if on_leave then
    self.data.on_leave[main] = true
    if self.Log then
      self.Log:Info("[OnLeave] %s — установлен статус 'в отпуске'", main)
    end
  else
    self.data.on_leave[main] = nil
    if self.Log then
      self.Log:Info("[OnLeave] %s — снят статус 'в отпуске'", main)
    end
  end
  -- Сохранить в БД
  if self.db and self.db.global then
    if not self.db.global.on_leave then self.db.global.on_leave = {} end
    if on_leave then
      self.db.global.on_leave[main] = true
    else
      self.db.global.on_leave[main] = nil
    end
  end
  -- Синхронизация через офицерскую ноту (маркер [ОТП] в конце).
  -- Пишем ТОЛЬКО если нота реально изменилась — иначе лишний flush на сервер.
  if Addon.Storage and Addon.Storage.GetNote and Addon.Storage.SetNote then
    local raw = Addon.Storage:GetNote(main)
    if raw ~= nil then
      local base_note = raw:gsub("%s*%[%s*ОТП%s*%]%s*$", ""):gsub("%s+$", "")
      local new_note = on_leave and (base_note .. " [ОТП]") or base_note
      if new_note ~= raw then
        local set_result = Addon.Storage:SetNote(main, new_note)
        if set_result == nil and self.Log then
          self.Log:Warn("SetOnLeave: note write deferred (pending queue full) for %s", tostring(main))
        end
      end
    end
  end
  -- Обновить UI
  if self.UI and self.UI.RefreshStandings then
    self.UI:InvalidateStandings()
    self.UI:RefreshStandings()
  end
  return true
end

-- Загрузить статусы "в отпуске" из БД при инициализации
function Addon:LoadOnLeaveStatus()
  if self.db and self.db.global and self.db.global.on_leave then
    for name, _ in pairs(self.db.global.on_leave) do
      self.data.on_leave[name] = true
    end
    if self.Log then
      local count = 0
      for _ in pairs(self.data.on_leave) do count = count + 1 end
      self.Log:Info("[OnLeave] Loaded %d players on leave", count)
    end
  end
end

-- Получить ИМЯ звания игрока (например "Guild Master", "Officer", "Member")
function Addon:GetRankName(name)
  return self.data.rank_name_data[name]
end

-- ============================================================================
-- ЦВЕТА ЗВАНИЙ (для гильдии MadTeaParty — sirus.su)
-- ============================================================================
-- Иерархия снизу вверх:
--   Шестерка       (новичок)      — тёмно-серый
--   Босяк                         — серый
--   Бандит                        — тёмно-зелёный
--   Громила                       — зелёный
--   Авторитет                     — бирюзовый
--   Вор в законе                  — синий
--   Крестный отец  (офицер)       — фиолетовый
--   Дон            (GM)           — золотой
-- ============================================================================
local RANK_COLORS = {
  -- Точные совпадения (для MadTeaParty)
  ["Дон"]              = { r = 1.00, g = 0.84, b = 0.00 },  -- золотой (GM)
  ["Крестный отец"]    = { r = 0.70, g = 0.40, b = 0.95 },  -- фиолетовый (Officer)
  ["Вор в законе"]     = { r = 0.30, g = 0.50, b = 1.00 },  -- синий
  ["Авторитет"]        = { r = 0.20, g = 0.85, b = 0.85 },  -- бирюзовый
  ["Громила"]          = { r = 0.30, g = 0.85, b = 0.30 },  -- зелёный
  ["Бандит"]           = { r = 0.20, g = 0.60, b = 0.20 },  -- тёмно-зелёный
  ["Босяк"]            = { r = 0.55, g = 0.55, b = 0.55 },  -- серый
  ["Шестерка"]         = { r = 0.40, g = 0.40, b = 0.40 },  -- тёмно-серый (новичок)

  -- Стандартные Blizzard-звания (на случай если гильдия использует их)
  ["Guild Master"]     = { r = 1.00, g = 0.84, b = 0.00 },
  ["Officer"]          = { r = 0.70, g = 0.40, b = 0.95 },
  ["Member"]           = { r = 0.55, g = 0.55, b = 0.55 },
  ["Trial"]            = { r = 0.40, g = 0.40, b = 0.40 },
  ["Initiate"]         = { r = 0.40, g = 0.40, b = 0.40 },
}

-- Fallback по индексу звания (если имя не найдено в таблице)
local RANK_COLORS_BY_INDEX = {
  [0] = { r = 1.00, g = 0.84, b = 0.00 },  -- GM (золотой)
  [1] = { r = 0.70, g = 0.40, b = 0.95 },  -- Officer (фиолетовый)
  [2] = { r = 0.30, g = 0.50, b = 1.00 },  -- высокий ранг (синий)
  [3] = { r = 0.30, g = 0.85, b = 0.30 },  -- средний (зелёный)
  [4] = { r = 0.55, g = 0.55, b = 0.55 },  -- обычный (серый)
  [5] = { r = 0.40, g = 0.40, b = 0.40 },  -- новичок (тёмно-серый)
}

-- Получить цвет звания игрока
-- name: имя игрока
-- Возвращает: {r, g, b} — цвет звания
function Addon:GetRankColor(name)
  local rank_name = self.data.rank_name_data[name]
  if rank_name and RANK_COLORS[rank_name] then
    return RANK_COLORS[rank_name]
  end
  -- Fallback: по индексу звания
  local rank_idx = self.data.rank_data[name] or 99
  if RANK_COLORS_BY_INDEX[rank_idx] then
    return RANK_COLORS_BY_INDEX[rank_idx]
  end
  -- Самый низкий — серый
  return { r = 0.55, g = 0.55, b = 0.55 }
end

-- Количество участников для начисления
function Addon:GetNumMembersInAwardList()
  if self.state.in_raid then
    return GetNumRaidMembers()
  else
    -- Считаем mains из gold_data (пропуская альтов).
    local count = 0
    for name in pairs(self.data.gold_data) do
      if not self.data.main_data[name] then
        count = count + 1
      end
    end
    return count
  end
end

if Addon.Log then
  Addon.Log:Info("GoldGP_Core loaded")
end
