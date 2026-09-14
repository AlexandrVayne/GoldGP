-- GoldGP_Flask.lua
-- ОТЛОЖЕННАЯ ИНИЦИАЛИЗАЦИЯ: тело модуля обёрнуто в boot(Addon); если глобаль
-- GoldGP ещё не создана (нарушенный порядок загрузки), waiter ждёт ядро до 30с
-- и доинициализирует модуль вместо молчаливого выхода.
-- Ставится ТОЛЬКО офицерам. Ядро GoldGP детектит модуль по Addon.Flask:
--   * кнопка «Фласки» в тулбаре /gg создаётся только при наличии модуля;
--   * вкладка «Настои» живёт в настройках ЭТОГО аддона (GoldGP_Flask_Options.lua);
--   * /gg flask остаётся диспетчером в ядре и работает только при наличии модуля.
-- Контракт модуля (ничего другого из ядра не используется):
--   Addon.Print / Addon.PrintError, Addon.Log,
--   Addon.Award:IncGP (с гвардом), Addon.Storage:IsCurrentState (с гвардом),
--   CanEditOfficerNote() (Blizzard API).
-- СВОЯ БД (GoldGPFlaskDB.global): flask_ids, flask_gp_amount, db_version, migrated.
-- ОДНОРАЗОВАЯ МИГРАЦИЯ из GoldGPDB (старые место хранения: global.flask_ids +
-- profiles[гильдия].flask_gp_amount) — см. InitFlaskDB().

-- Тело модуля (ниже, до «end of boot») исполняется ВНУТРИ boot(Addon) —
-- намеренно без ре-индентации, чтобы дифф остался читаемым.
local Flask = {}

local boot = function(Addon)
Addon.Flask = Flask

-- ============================================================================
-- БАЗОВЫЙ СПИСОК НАСТОЕВ
-- ============================================================================
local DEFAULT_FLASKS = {
  -- Classic
  17626, 17627, 17628, 17629,
  -- TBC
  28518, 28519, 28520, 28521, 28540, 33053, 42735,
  40567, 40568, 40572, 40573, 40575, 40576,
  41608, 41609, 41610, 41611, 46837, 46839,
  -- WotLK 3.3.5a
  53752, 53755, 53758, 54212, 53760, 62380, 67019,
  -- Sirus.su кастомные (270005-270010)
  270005, 270006, 270007, 270008, 270009, 270010,
}

local FlaskNames = nil
local FlaskNamesDirty = true

local MAX_RAID_GROUP = 5
local AWARD_DELAY = 0.3
local CHECK_COOLDOWN = 3
-- Канал ВСЕГДА "GUILD" — без выбора.
local FLASK_CHANNEL = "GUILD"

-- Кэш spell info {id = {name, icon}} — чтобы не вызывать GetSpellInfo
-- на каждый скролл списка в настройках (как делает FlaskGP).
local spellInfoCache = {}

-- ============================================================================
-- СВОЯ БД + ОДНОРАЗОВАЯ МИГРАЦИЯ
-- ============================================================================
-- Дефолты:
--   flask_gp_amount = 1, db_version = 1, migrated = false.
-- flask_ids хранится там же (nil = дефолтный список DEFAULT_FLASKS).

local function InitFlaskDB()
  if GoldGPFlaskDB == nil then GoldGPFlaskDB = {} end
  if GoldGPFlaskDB.global == nil then GoldGPFlaskDB.global = {} end

  Flask.db = { global = GoldGPFlaskDB.global }
  local g = Flask.db.global

  -- Дефолты
  if g.flask_gp_amount == nil then g.flask_gp_amount = 1 end
  if g.db_version == nil then g.db_version = 1 end

  -- ОДНОРАЗОВАЯ МИГРАЦИЯ из GoldGPDB:
  --   * GoldGPDB.global.flask_ids                 -> GoldGPFlaskDB.global.flask_ids
  --   * GoldGPDB.profiles[гильдия].flask_gp_amount -> GoldGPFlaskDB.global.flask_gp_amount
  -- Старые поля обнуляются, migrated = true. При отсутствии старых данных —
  -- просто migrated = true (повторный вход не копирует ничего).
  -- Профиль гильдии берём тот же, что выбрало ядро (Addon.guild_name ставится
  -- в InitDB ядра при его ADDON_LOADED — ядро грузится раньше, зависимость жёсткая).
  if g.migrated ~= true then
    local old_global = GoldGPDB and GoldGPDB.global or nil
    local guild = Addon.guild_name or "Default"
    local old_profile = (GoldGPDB and GoldGPDB.profiles and GoldGPDB.profiles[guild]) or nil
    local copied_ids = false
    local copied_gp = false

    if old_global and old_global.flask_ids then
      g.flask_ids = old_global.flask_ids
      old_global.flask_ids = nil
      copied_ids = true
    end
    if old_profile and old_profile.flask_gp_amount then
      g.flask_gp_amount = old_profile.flask_gp_amount
      old_profile.flask_gp_amount = nil
      copied_gp = true
    end

    g.migrated = true
    if Addon.Log then
      Addon.Log:Info("[Flask] migration from GoldGPDB: ids=%s, gp=%s",
        tostring(copied_ids), tostring(copied_gp))
    end
  end

  if Addon.Log then
    Addon.Log:Info("[Flask] DB ready (flask_gp_amount=%d)", g.flask_gp_amount or 1)
  end
end

-- SavedVariables (GoldGPFlaskDB) доступны уже при исполнении файла;
-- InitFlaskDB() вызывается в конце boot().

-- ============================================================================
-- СПИСОК НАСТОЕВ — API
-- ============================================================================
function Flask:GetFlaskIDs()
  if Flask.db and Flask.db.global and Flask.db.global.flask_ids then
    return Flask.db.global.flask_ids
  end
  return DEFAULT_FLASKS
end

-- Получить {name, icon} для spellID с кэшем (как FlaskGP).
-- GetSpellInfo возвращает: name, rank, icon, ...
-- Кэш обновляется только при add/remove/reset.
function Flask:GetSpellInfoCached(spellID)
  if not spellID then return nil end
  if spellInfoCache[spellID] then
    return spellInfoCache[spellID]
  end
  local name, _, icon = GetSpellInfo(spellID)
  local cached = { name = name or "(нет названия)", icon = icon }
  spellInfoCache[spellID] = cached
  return cached
end

-- Сбросить кэш (вызывается при add/remove/reset)
function Flask:ClearSpellInfoCache()
  spellInfoCache = {}
end

-- Возвращает таблицу для UI настроек
function Flask:GetFlaskList()
  local result = {}
  local ids = self:GetFlaskIDs()
  for i, id in ipairs(ids) do
    local name = GetSpellInfo(id) or "(нет названия)"
    tinsert(result, { idx = i, spellID = id, name = name })
  end
  return result
end

local function rebuildFlaskNames()
  FlaskNames = {}
  local ids = Flask:GetFlaskIDs()
  for _, spellID in ipairs(ids) do
    local spellName = GetSpellInfo(spellID)
    if spellName then
      FlaskNames[spellName] = true
    end
  end
  FlaskNamesDirty = false
end

function Flask:AddFlask(spellID)
  spellID = tonumber(spellID)
  if not spellID then return false, "invalid_id" end
  if not (Flask.db and Flask.db.global) then return false, "db_not_ready" end
  if not Flask.db.global.flask_ids then
    Flask.db.global.flask_ids = {}
    for _, id in ipairs(DEFAULT_FLASKS) do
      tinsert(Flask.db.global.flask_ids, id)
    end
  end
  for _, id in ipairs(Flask.db.global.flask_ids) do
    if id == spellID then return false, "already_exists" end
  end
  tinsert(Flask.db.global.flask_ids, spellID)
  FlaskNamesDirty = true
  self:ClearSpellInfoCache()
  local info = self:GetSpellInfoCached(spellID)
  Addon.Print(string.format("Фласка добавлена: %d (%s). Всего: %d",
    spellID, info.name, #Flask.db.global.flask_ids))
  return true
end

function Flask:RemoveFlask(spellID)
  spellID = tonumber(spellID)
  if not spellID then return false, "invalid_id" end
  if not (Flask.db and Flask.db.global and Flask.db.global.flask_ids) then return false, "not_found" end
  for i, id in ipairs(Flask.db.global.flask_ids) do
    if id == spellID then
      tremove(Flask.db.global.flask_ids, i)
      FlaskNamesDirty = true
      self:ClearSpellInfoCache()
      local info = self:GetSpellInfoCached(spellID)
      Addon.Print(string.format("Фласка удалена: %d (%s). Осталось: %d",
        spellID, info.name, #Flask.db.global.flask_ids))
      return true
    end
  end
  return false, "not_found"
end

function Flask:ResetFlasks()
  if Flask.db and Flask.db.global then
    Flask.db.global.flask_ids = nil
  end
  FlaskNamesDirty = true
  self:ClearSpellInfoCache()
  Addon.Print("Список настоев сброшен к дефолтному (" .. #DEFAULT_FLASKS .. " шт.)")
end

function Flask:ListFlasks()
  local list = self:GetFlaskList()
  Addon.Print(string.format("=== Настои (%d) ===", #list))
  for _, f in ipairs(list) do
    Addon.Print(string.format("  %3d. %d - %s", f.idx, f.spellID, f.name))
  end
end

function Flask:SetGPAmount(amount)
  amount = math.floor(tonumber(amount) or 1)
  amount = math.max(1, math.min(99999, amount))
  if not (Flask.db and Flask.db.global) then return end
  Flask.db.global.flask_gp_amount = amount
  Addon.Print(string.format("GP за отсутствие настоя: %d", amount))
end

function Flask:GetGPAmount()
  if Flask.db and Flask.db.global then
    return Flask.db.global.flask_gp_amount or 1
  end
  return 1
end

-- ============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================================
local function sendToChannel(msg)
  if not IsInGuild() then
    Addon.Print(msg)
    return
  end
  pcall(SendChatMessage, msg, FLASK_CHANNEL)
end

local function buildUnitList()
  local units = {}
  if GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local unitid = "raid"..i
      local name, _, subgroup = GetRaidRosterInfo(i)
      if name and subgroup and subgroup <= MAX_RAID_GROUP then
        if UnitIsConnected(unitid) and not UnitIsDeadOrGhost(unitid) then
          tinsert(units, { unitid = unitid, name = name })
        end
      end
    end
  elseif GetNumPartyMembers() > 0 then
    local pname = UnitName("player")
    if pname then tinsert(units, { unitid = "player", name = pname }) end
    for i = 1, GetNumPartyMembers() do
      local unitid = "party"..i
      local name = UnitName(unitid)
      if name and UnitIsConnected(unitid) and not UnitIsDeadOrGhost(unitid) then
        tinsert(units, { unitid = unitid, name = name })
      end
    end
  else
    local pname = UnitName("player")
    if pname then tinsert(units, { unitid = "player", name = pname }) end
  end
  return units
end

local function checkUnitFlask(unitid)
  if FlaskNamesDirty or not FlaskNames then
    rebuildFlaskNames()
  end
  for i = 1, 40 do
    local buffName = UnitBuff(unitid, i)
    if not buffName then break end
    if FlaskNames[buffName] then
      return "flask", buffName
    end
  end
  return "none"
end

-- ============================================================================
-- ОТЛОЖЕННОЕ НАЧИСЛЕНИЕ GP
-- ============================================================================
local awardState = {
  queue = {}, awarded = {}, notFound = {},
  reason = "", amount = 1,
  isActive = false, frame = nil, timer = 0,
}

local lastCheckTime = 0

local function finalizeAwardReport()
  awardState.isActive = false
  if awardState.frame then awardState.frame:Hide() end

  if #awardState.awarded > 0 then
    local list = table.concat(awardState.awarded, ", ")
    sendToChannel(string.format("GP +%d выдано: %s (причина: %s)",
      awardState.amount, list, awardState.reason))
    Addon.Print(string.format("Фласки: GP начислен %d игрокам", #awardState.awarded))
  end

  if #awardState.notFound > 0 then
    Addon.PrintError("Фласки: не удалось начислить GP:")
    for _, name in ipairs(awardState.notFound) do
      Addon.PrintError("  " .. name)
    end
  end

  awardState.queue = {}
  awardState.awarded = {}
  awardState.notFound = {}
end

local function processNextAward()
  if #awardState.queue == 0 then
    finalizeAwardReport()
    return
  end
  local name = table.remove(awardState.queue, 1)
  local result = nil
  if Addon.Award and Addon.Award.IncGP then
    result = Addon.Award:IncGP(name, awardState.reason, awardState.amount, true)
  end
  if result then
    tinsert(awardState.awarded, name)
  else
    tinsert(awardState.notFound, name)
  end
end

local function startAwardQueue(names, reason, amount)
  awardState.queue = {}
  for _, name in ipairs(names) do
    tinsert(awardState.queue, name)
  end
  awardState.awarded = {}
  awardState.notFound = {}
  awardState.reason = reason
  awardState.amount = amount
  awardState.isActive = true
  awardState.timer = 0

  if not awardState.frame then
    awardState.frame = CreateFrame("Frame")
    awardState.frame:Hide()
    awardState.frame:SetScript("OnUpdate", function(self, elapsed)
      if not awardState.isActive then
        self:Hide()
        return
      end
      awardState.timer = awardState.timer - elapsed
      if awardState.timer <= 0 then
        awardState.timer = AWARD_DELAY
        processNextAward()
      end
    end)
  end
  awardState.frame:Show()
end

-- ============================================================================
-- ГЛАВНАЯ ФУНКЦИЯ: Проверка настоев + начисление GP
-- ============================================================================
function Flask:RunCheck()
  if awardState.isActive then
    Addon.Print("Фласки: начисление GP ещё выполняется, подождите...")
    return
  end

  local now = GetTime()
  if now - lastCheckTime < CHECK_COOLDOWN then
    local wait = math.ceil(CHECK_COOLDOWN - (now - lastCheckTime))
    Addon.Print(string.format("Фласки: проверка на кулдауне, подождите %d сек", wait))
    return
  end
  lastCheckTime = now

  -- Канал всегда GUILD
  if not IsInGuild() then
    Addon.PrintError("Фласки: вы не в гильдии - отчёт и начисление невозможны")
    return
  end

  -- Проверка прав в начале: non-officer видит отчёт только себе (без бродкаста в GUILD).
  local isOfficer = CanEditOfficerNote()

  if isOfficer then
    sendToChannel("Проверка настоев...")
  end

  local units = buildUnitList()
  if #units == 0 then
    Addon.Print("Фласки: нет игроков для проверки")
    return
  end

  local missingFlask = {}
  for _, u in ipairs(units) do
    if checkUnitFlask(u.unitid) == "none" then
      tinsert(missingFlask, u.name)
    end
  end

  if #missingFlask > 0 then
    local msg = "Без настоев: " .. table.concat(missingFlask, ", ")
    if isOfficer then
      sendToChannel(msg)
    else
      Addon.Print("Фласки: " .. msg)
    end
  end

  if #missingFlask == 0 then
    local okmsg = string.format("Все %d игроков с настоем!", #units)
    if isOfficer then
      sendToChannel(okmsg)
    else
      Addon.Print("Фласки: " .. okmsg)
    end
    return
  end

  if not isOfficer then
    Addon.PrintError("Фласки: нет прав на офицерские ноты - GP не начислен (только отчёт)")
    return
  end
  if Addon.Storage and not Addon.Storage:IsCurrentState() then
    local st = Addon.Storage:GetState()
    Addon.PrintError(string.format("Фласки: Storage в состоянии %s - подождите 2 сек", st))
    return
  end

  local gpAmount = self:GetGPAmount()
  local reason = "Нет настоя"
  Addon.Print(string.format("Фласки: начисление %d GP %d игрокам (по %.1f сек на каждого)...",
    gpAmount, #missingFlask, AWARD_DELAY))
  startAwardQueue(missingFlask, reason, gpAmount)
end

  -- Уведомить UI о готовности модуля: UI:SyncFlaskButton() можно вызвать
  -- в ЛЮБОЙ момент (видимость кнопки «Фласки» — динамическая).
  if Addon.UI and Addon.UI.SyncFlaskButton then
    pcall(function() Addon.UI:SyncFlaskButton() end)
  end

  if Addon.Log then
    Addon.Log:Info("GoldGP_Flask booted (v0.1.2, channel=GUILD, default flasks: %d)", #DEFAULT_FLASKS)
  end

  -- БД инициализируется ПОСЛЕДНЕЙ в boot — к этому моменту все функции
  -- модуля определены, SavedVariables уже загружены Blizzard.
  InitFlaskDB()
end  -- end of boot(Addon)

-- ============================================================================
-- ЗАПУСК — сразу, либо отложенно (waiter до 30с)
-- ============================================================================
if GoldGP then
  boot(GoldGP)
else
  -- Ядро ещё не загружено (нарушенный порядок). ЖДЁМ, не отключаемся.
  local waiter = CreateFrame("Frame")
  local waited = 0
  waiter:RegisterEvent("ADDON_LOADED")
  waiter:RegisterEvent("PLAYER_LOGIN")
  -- Любое событие -> проверка ядра на следующем OnUpdate (OnUpdate не тикает
  -- на экране загрузки, зато события доходит — ставим флаг принудительной проверки).
  waiter:SetScript("OnEvent", function() waited = 999 end)
  waiter:SetScript("OnUpdate", function(self, elapsed)
    waited = waited + elapsed
    if GoldGP then
      self:UnregisterAllEvents()
      self:Hide()
      boot(GoldGP)
      if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r: модуль «Фласки» инициализирован отложенно (ядро загрузилось позже модуля).")
      end
    elseif waited > 30 then
      self:UnregisterAllEvents()
      self:Hide()
      if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP Фласки: ядро GoldGP не загрузилось за 30с — модуль отключён. Проверьте, что папка GoldGP установлена и включена, затем выполните /reload.|r")
      end
    end
  end)
end
