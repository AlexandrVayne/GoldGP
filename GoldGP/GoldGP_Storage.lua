-- GoldGP_Storage.lua

local Addon = GoldGP
local Storage = {}
Addon.Storage = Storage

-- ============================================================================
-- СОСТОЯНИЯ
-- ============================================================================
-- UNINITIALIZED -> STALE_WAITING_FOR_ROSTER_UPDATE -> STALE -> CURRENT
--                                              v
--                                          FLUSHING -> STALE_WAITING_FOR_ROSTER_UPDATE
--                                              v
--                                       REMOTE_FLUSHING -> STALE_WAITING / CURRENT
-- REMOTE_FLUSHING может перейти в CURRENT (после roster update
-- от ScheduleDelayedRosterRequest), в дополнение к STALE_WAITING и STALE.

local VALID_TRANSITIONS = {
  UNINITIALIZED                       = { CURRENT = true },
  STALE                               = {
    CURRENT = true, REMOTE_FLUSHING = true, FLUSHING = true,
    ["STALE_WAITING_FOR_ROSTER_UPDATE"] = true,
  },
  ["STALE_WAITING_FOR_ROSTER_UPDATE"] = {
    STALE = true, FLUSHING = true,
    ["STALE_WAITING_FOR_ROSTER_UPDATE"] = true,
  },
  CURRENT                             = {
    FLUSHING = true, REMOTE_FLUSHING = true, STALE = true,
    ["STALE_WAITING_FOR_ROSTER_UPDATE"] = true,
  },
  -- ВАЖНО: FLUSHING может перейти в любой state — иначе состояние залипает
  -- при ответе сервера sirus.su (который часто присылает GUILD_ROSTER_UPDATE
  -- с localUpdate=nil во время flush).
  FLUSHING                            = {
    ["STALE_WAITING_FOR_ROSTER_UPDATE"] = true,
    STALE = true, CURRENT = true, FLUSHING = true,
  },
  -- REMOTE_FLUSHING -> {STALE_WAITING, STALE, CURRENT}.
  -- CURRENT — чтобы разрешить быстрый recovery когда roster уже обновлён.
  REMOTE_FLUSHING                     = {
    ["STALE_WAITING_FOR_ROSTER_UPDATE"] = true,
    STALE = true, CURRENT = true,
  },
}

-- Состояние кэша
local state = "STALE_WAITING_FOR_ROSTER_UPDATE"
local initialized = false
local index = nil  -- текущий индекс обхода cache для Frame_OnUpdate
local flushing_since = 0  -- timestamp когда вошли в FLUSHING (для fail-safe)
local stale_waiting_since = 0  -- timestamp когда вошли в STALE_WAITING (для timeout)
-- REMOTE_FLUSHING recovery — когда другой офицер пишет officer
-- notes (CHANGES_PENDING), мы не начинааем свои записи до окончания remote flush.
-- remote_flushing_since — timestamp входа в REMOTE_FLUSHING (для timeout 5-10 сек).
-- remote_flushing_sender — имя офицера, который отправил CHANGES_PENDING.
local remote_flushing_since = 0
local remote_flushing_sender = nil

-- время последнего GuildRoster() запроса в STALE_WAITING (throttle 1.5с)
local stale_waiting_last_request = 0

-- Кэш: name -> { note=, seen=, public_note=, guild_index= }
local cache = {}

-- pending_note[name] — очередь значений. SetNote добавляет в конец, Frame_OnUpdate сбрасывает по одному.
local pending_note = {}

-- ============================================================================
-- ПУБЛИЧНЫЕ МЕТОДЫ
-- ============================================================================

-- Получить ноту игрока
function Storage:GetNote(name)
  local e = cache[name]
  return e and e.note
end

-- Установить ноту игроку (с очередью pending)
function Storage:SetNote(name, note)
  local e = cache[name]
  if not e then
    Addon.Log:Warn("SetNote for unknown player: %s", tostring(name))
    return nil
  end

  -- Защита от переполнения очереди pending (макс. 3)
  if pending_note[name] and #pending_note[name] >= 3 then
    Addon.Log:Warn("SetNote rejected for %s — pending queue full (%d). Wait for flush.",
      tostring(name), #pending_note[name])
    return nil
  end

  if not pending_note[name] then
    -- Очереди нет — создаём
    pending_note[name] = { note }
    Storage:SetState("FLUSHING")
    Addon.Log:PendingQueued(name, note)
  else
    -- Очередь уже есть — ДОБАВЛЯЕМ В КОНЕЦ (а не отбрасываем!)
    tinsert(pending_note[name], note)
    Addon.Log:PendingQueued(name, note)
    -- Предупреждаем о нескольких pending (это нормально, но для аудита)
    if #pending_note[name] > 1 then
      Addon.Log:Debug("Multiple pending notes for %s (queue size: %d) — handled correctly",
        name, #pending_note[name])
    end
    -- Состояние уже FLUSHING — не нужно менять
  end

  return e.note
end

local current_guild_info = ""

-- Получить текущий GuildInfo текст (alias для Core.lua)
function Storage:GetGuildInfoText()
  return current_guild_info or ""
end

-- Состояние CURRENT?
function Storage:IsCurrentState()
  return state == "CURRENT"
end

-- Ростер реально распарсен (данные gold_data/gp_data заполнены).
-- Используется Core:CleanupOldData чтобы НЕ чистить on_leave по пустому ростеру
-- (GuildRoster() асинхронный — данные приходят ПОЗЖЕ вызова).
function Storage:IsInitialized()
  return initialized and true or false
end

-- Получить текущее состояние (для отладки)
function Storage:GetState()
  return state
end

-- ============================================================================
-- УПРАВЛЕНИЕ СОСТОЯНИЕМ
-- ============================================================================
function Storage:SetState(new_state)
  if state == new_state then return end
  if not VALID_TRANSITIONS[state] or not VALID_TRANSITIONS[state][new_state] then
    Addon.Log:Debug("Ignoring state change %s -> %s", state, new_state)
    return
  end
  Addon.Log:StateChange(state, new_state, "Storage")
  state = new_state
  if new_state == "FLUSHING" then
    flushing_since = GetTime()
    SendAddonMessage("GoldGP", "CHANGES_PENDING", "GUILD")
  else
    flushing_since = 0
  end
  -- Отдельный таймер для STALE_WAITING (flushing_since сбрасывается выше)
  if new_state == "STALE_WAITING_FOR_ROSTER_UPDATE" then
    stale_waiting_since = GetTime()
  else
    stale_waiting_since = 0
  end
  -- REMOTE_FLUSHING таймер
  if new_state == "REMOTE_FLUSHING" then
    -- remote_flushing_since / sender устанавливаются в EnterRemoteFlushing ДО SetState,
    -- потому что SetState early-returns при same-state. Здесь только обновляем если
    -- transition произошёл из другого state.
    if remote_flushing_since == 0 then
      remote_flushing_since = GetTime()
    end
  else
    remote_flushing_since = 0
    remote_flushing_sender = nil
  end
  -- Если вошли в CURRENT и есть pending_note записи, сразу переходим в FLUSHING
  -- (не ждём следующего SetNote) — иначе pending notes могут висеть вечно, если
  -- state достиг CURRENT через не-SetNote path (например, через CHANGES_FLUSHED recovery).
  if new_state == "CURRENT" and next(pending_note) ~= nil then
    Addon.Log:Debug("CURRENT with pending notes -> FLUSHING")
    -- Рекурсивный вызов — уже после remote_flushing cleanup выше
    Storage:SetState("FLUSHING")
    return
  end
  Addon:Fire("StorageStateChanged", new_state)
end

-- EnterRemoteFlushing — обёртка над SetState для REMOTE_FLUSHING.
-- Устанавливает timer/sender ДО вызова SetState, чтобы timer refresh-ился даже если
-- state уже REMOTE_FLUSHING (SetState early-returns на same-state).
-- spec: "новый CHANGES_PENDING должен обновлять таймер".
function Storage:EnterRemoteFlushing(sender)
  remote_flushing_since = GetTime()
  remote_flushing_sender = sender
  -- Если state уже REMOTE_FLUSHING, SetState early-return'нет — но timer/sender
  -- уже обновлены выше. Если state другой, SetState выполнит transition.
  Storage:SetState("REMOTE_FLUSHING")
end

-- ============================================================================
-- ОБРАБОТКА GUILD_ROSTER_UPDATE
-- ============================================================================
function Storage:OnRosterUpdate(localUpdate)
  Addon.Log:Debug("Storage:OnRosterUpdate(local=%s) | current state=%s", tostring(localUpdate), state)
  if localUpdate then
    -- Локальный запрос (вызвали GuildRoster() сами) — переходим в FLUSHING
    Storage:SetState("FLUSHING")
  else
    -- Сервер прислал обновление ростера (localUpdate=nil).
    -- Если мы в FLUSHING — НЕ переводим в STALE (иначе состояние залипает!).
    -- FrameOnUpdate сам прочтёт обновлённые ноты и вернёт state в CURRENT.
    -- Если мы в CURRENT — переходим в STALE для перечитывания.
    -- Если мы в REMOTE_FLUSHING — переходим в STALE_WAITING
    -- (ждём окончания remote flush через roster update).
    if state == "CURRENT" then
      Storage:SetState("STALE")
      index = nil
    elseif state == "FLUSHING" then
      -- Мы в процессе flush — сервер прислал обновление, но мы ещё не закончили.
      -- НЕ меняем state — FrameOnUpdate продолжит обработку.
      Addon.Log:Debug("Roster update during FLUSHING — keeping state, will process in FrameOnUpdate")
    elseif state == "REMOTE_FLUSHING" then
      -- Roster update от remote flush — переходим в STALE
      -- для перечитывания notes. Альтернативно можно перейти в CURRENT напрямую,
      -- но STALE безопаснее (FrameOnUpdate перечитает notes и подтвердит CURRENT).
      Storage:SetState("STALE")
      index = nil
    elseif state ~= "UNINITIALIZED" then
      Storage:SetState("STALE")
      index = nil
    end
  end
end

-- ============================================================================
-- ПАРСИНГ GUILD INFO (для @DECAY_P, @MIN_GOLD, etc.)
-- ============================================================================
local function ParseGuildInfo(info_text)
  -- Ищем блок -GGP- ... -GGP- (или -EPGP- для совместимости)
  -- Формат:
  -- -GGP-
  -- @DECAY_P:20
  -- @EXTRAS_P:100
  -- @MIN_GOLD:5000
  -- @BASE_GP:1
  -- -GGP-

  local in_block = false
  local new_config = {}
  local patterns = {
    decay_p      = "@DECAY_P:(%d+)",
    extras_p     = "@EXTRAS_P:(%d+)",
    min_gold     = "@MIN_GOLD:(%d+)",
    base_gp      = "@BASE_GP:(%d+)",
    att_total    = "@ATT_TOTAL:(%d+)",
  }

  for line in string.gmatch(info_text, "[^\n]+") do
    if line:find("-GGP-") or line:find("-EPGP-") then
      in_block = not in_block
    end
    if in_block or line:find("@DECAY_P") or line:find("@EXTRAS_P")
                or line:find("@MIN_GOLD") or line:find("@BASE_GP")
                or line:find("@ATT_TOTAL") then
      for var, pat in pairs(patterns) do
        local v = line:match(pat)
        if v then
          new_config[var] = tonumber(v)
        end
      end
    end
  end

  if Addon.db and Addon.db.profile then
    local p = Addon.db.profile
    for var, v in pairs(new_config) do
      if p[var] ~= v then
        p[var] = v
        Addon.Log:Info("Config: %s = %d", var, v)
      end
    end
  end
  -- @ATT_TOTAL из GuildInfo → attendance_total
  if new_config.att_total then
    Addon.data.attendance_total = new_config.att_total
    if Addon.db and Addon.db.global then
      Addon.db.global.attendance_total = new_config.att_total
    end
  end
end

-- ПАРСИНГ ОБЩЕЙ НОТЫ (public note) для посещаемости
-- Формат: "спек (N)" — N = кол-во посещённых РТ
-- alt'ы пропускаются — attendance берётся от main's public note
local function ParsePublicNote(name, public_note)
  -- skip alts — attendance хранится на main's public note
  if Addon.data.main_data[name] then
    return
  end
  if not public_note or public_note == "" then
    Addon.data.attendance_data[name] = 0
    return
  end
  local text, count = public_note:match("^(.*)%((%d+)%)%s*$")
  if count then
    Addon.data.attendance_data[name] = tonumber(count)
  else
    Addon.data.attendance_data[name] = 0
  end
end

-- Установить public note с посещаемостью
-- Формат: "spec_text (N)" — N = count
local pending_public_note = {}
-- Returns true on success, false on failure (unknown player / pending queue full).
-- Callers (MassGold/RetryAttendanceMass/RestoreMass) MUST check return value and NOT
-- treat local attendance_data as committed when false.
function Storage:SetPublicNote(name, count)
  local e = cache[name]
  if not e then
    Addon.Log:Warn("SetPublicNote: %s not in cache", tostring(name))
    return false
  end
  -- Текущий текст спека из public note (без (N))
  local current_pub = e.public_note or ""
  -- парсим (N) в конце
  local spec_text = current_pub:match("^(.*)%((%d+)%)%s*$")
  if not spec_text then
    -- Нет (N) — весь текст это spec_text
    spec_text = current_pub
  end
  if spec_text then spec_text = spec_text:gsub("%s+$", "") end
  -- Новый формат: "spec_text (count)"
  local new_note = (spec_text or "") .. " (" .. tostring(count) .. ")"
  -- Проверка длины (лимит 31 символ)
  if #new_note > 31 then
    local suffix = " (" .. tostring(count) .. ")"
    local max_spec = 31 - #suffix
    spec_text = spec_text:sub(1, max_spec)
    new_note = spec_text .. suffix
  end
  pending_public_note[name] = new_note
  e.public_note = new_note
  Addon.data.attendance_data[name] = count
  return true
end

-- ============================================================================
-- ЛОКАЛИЗОВАННОЕ ИМЯ КЛАССА -> АНГЛИЙСКИЙ ТОКЕН
-- ============================================================================
-- GetGuildRosterInfo возвращает локализованное имя класса (зависит от клиента).
-- UI-таблицы (CLASS_COLORS, CLASS_ICON_TCOORDS) индексируются английским токеном.
-- ruRU (sirus.su) + enUS. Если имя не найдено — используем как есть (fallback).
local LOCALIZED_CLASS_TO_TOKEN = {
  -- ruRU
  ["Воин"]          = "WARRIOR",
  ["Паладин"]       = "PALADIN",
  ["Охотник"]       = "HUNTER",
  ["Разбойник"]     = "ROGUE",
  ["Жрец"]          = "PRIEST",
  -- ruRU-ростер возвращает ИМЕННО "Прист"
  -- (известный кварк русского клиента: GetClassInfo даёт "Жрец", а
  -- GetGuildRosterInfo — "Прист"). Без этого алиаса у всех прист не было иконки.
  ["Прист"]         = "PRIEST",
  ["Рыцарь смерти"] = "DEATHKNIGHT",
  ["Шаман"]         = "SHAMAN",
  ["Маг"]           = "MAGE",
  ["Чернокнижник"]  = "WARLOCK",
  ["Друид"]         = "DRUID",
  -- ЖЕНСКИЕ формы имён классов ruRU.
  -- WoW возвращает строку класса С УЧЁТОМ ПОЛА персонажа: GetGuildRosterInfo /
  -- UnitClass для женского шамана дают «Шаманка», женского ханта — «Охотница»
  -- и т.д. (подтверждено /gg classdiag: «Шаманка» без явной записи НЕ МАПИТСЯ).
  -- GetClassInfo() возвращает только базовую (мужскую) форму, поэтому рантайм-
  -- достройка ниже эти строки добавить НЕ может — только явная таблица.
  -- «Маг» и «Рыцарь смерти» в ruRU одинаковы для обоих полов — записи не нужны.
  ["Воительница"]   = "WARRIOR",
  ["Паладинка"]     = "PALADIN",
  ["Охотница"]      = "HUNTER",
  ["Разбойница"]    = "ROGUE",
  ["Жрица"]         = "PRIEST",
  ["Шаманка"]       = "SHAMAN",
  ["Чернокнижница"] = "WARLOCK",
  ["Друидка"]       = "DRUID",
  -- enUS
  ["Warrior"]       = "WARRIOR",
  ["Paladin"]       = "PALADIN",
  ["Hunter"]        = "HUNTER",
  ["Rogue"]         = "ROGUE",
  ["Priest"]        = "PRIEST",
  ["Death Knight"]  = "DEATHKNIGHT",
  ["Shaman"]        = "SHAMAN",
  ["Mage"]          = "MAGE",
  ["Warlock"]       = "WARLOCK",
  ["Druid"]         = "DRUID",
}

-- ДОСТРОЙКА мапы по данным САМОГО КЛИЕНТА.
-- GetClassInfo(i) возвращает локализованное имя + английский токен для каждого
-- класса — это покрывает любые локали/кастом-клиенты (Sirus), где строки
-- ростера совпадают со строками GetClassInfo, но не с hardcoded-таблицей выше.
-- Вручную заданные алиасы не перезаписываются (target уже совпадает либо алиас
-- уникален для ростера). Pcall — на экзотических клиентах GetClassInfo может
-- отсутствовать/падать; тогда остаётся hardcoded-мапа.
do
  pcall(function()
    for i = 1, 20 do
      local class_name, class_file = GetClassInfo(i)
      -- НЕ break на первом nil (в Lua 5.1 нет continue — через if).
      -- На экзотических клиентах часть индексов может вернуть nil: первый же
      -- nil оборвал бы ВСЮ достройку; стандартный клиент: i>10 → nil → skip.
      if class_name and class_file and LOCALIZED_CLASS_TO_TOKEN[class_name] == nil then
        LOCALIZED_CLASS_TO_TOKEN[class_name] = class_file
      end
    end
    -- Самосбор формы класса СВОЕГО персонажа. Если игрок — женщина,
    -- UnitClass("player") вернёт ЖЕНСКУЮ форму («Шаманка» вместо «Шаман»);
    -- мужчина даст базовую — она уже в мапе, no-op. Подстраховка для
    -- кастом-клиентов с нестандартными строками (ruRU покрыт таблицей выше).
    local loc_name, loc_token = UnitClass("player")
    if loc_name and loc_token and LOCALIZED_CLASS_TO_TOKEN[loc_name] == nil then
      LOCALIZED_CLASS_TO_TOKEN[loc_name] = loc_token
    end
  end)
end

-- Валидные токены + нормализация (иконки классов).
-- NormalizeClassToken возвращает ТОЛЬКО валидный токен (из множества
-- CLASS_TOKENS, заполняется в UIKit); при невалидном значении СОХРАНЯЕТСЯ
-- предыдущее валидное; неизвестные строки логируются ОДИН раз (диагностика).
-- Невалидный вход возможен: сервер вернул class=nil/пустую строку, либо это
-- вариант локального имени, которого нет в таблице (кастом-клиент).
local CLASS_TOKENS = Addon.CLASS_TOKENS  -- может быть nil на момент загрузки файла — ок

local known_class_warned = {}  -- строка -> true (warn once per unique string)

local function IsKnownToken(v)
  if not v then return false end
  if CLASS_TOKENS then return CLASS_TOKENS[v] and true or false end
  -- Fallback на момент загрузки (CLASS_TOKENS ещё нет): минимальный whitelist
  return ({ WARRIOR=true, PALADIN=true, HUNTER=true, ROGUE=true, PRIEST=true,
    DEATHKNIGHT=true, SHAMAN=true, MAGE=true, WARLOCK=true, DRUID=true })[v] and true or false
end

local function NormalizeClassToken(raw)
  if not raw or raw == "" then return nil end
  if type(raw) ~= "string" then return nil end
  local token = LOCALIZED_CLASS_TO_TOKEN[raw]
  if IsKnownToken(token) then return token end
  -- Уже токен (enUS-клиент / данные из UnitClass)
  if IsKnownToken(raw) then return raw end
  -- ASCII-регистронезависимый fallback (enUS-варианты "priest", "PRIEST")
  local upper = raw:gsub("%s+$", ""):upper()
  if IsKnownToken(upper) then return upper end
  -- Кириллица: strupper в 3.3.5 не работает — пробуем вариант с обрезкой пробелов
  local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed ~= raw then
    token = LOCALIZED_CLASS_TO_TOKEN[trimmed]
    if IsKnownToken(token) then return token end
  end
  -- Неизвестная строка — логируем ОДИН раз (диагностика кастом-клиентов)
  if not known_class_warned[raw] then
    known_class_warned[raw] = true
    if Addon.Log then
      Addon.Log:Warn("Storage: неизвестная строка класса '%s' (игроку не будет иконки). Сообщите разработчику.", raw)
    end
    -- Дублируем в чат ОДИН раз — лог скрыт от пользователя, а эта
    -- строка — ключ к диагностике (её показывает /gg classdiag)
    if Addon.PrintError then
      Addon.PrintError(string.format(
        "Неизвестная строка класса \"%s\" — иконка класса не будет показана. Выполните /gg classdiag и пришлите вывод разработчику.",
        raw))
    end
  end
  return nil
end

-- Диагностический экспорт (используется Addon:GetClassDiagnostics в Core
-- для /gg classdiag). Не для боевого кода — только нормализация сырой строки.
Addon.DebugNormalizeClassToken = NormalizeClassToken

-- ============================================================================
-- ПАРСИНГ ОФИЦЕРСКОЙ НОТЫ
-- ============================================================================
-- Формат ноты: "Gold,GP" — например "1000,500"
-- Для альтов: нота содержит имя main'а — например "Player001"
-- Поддержка маркера отпуска "[ОТП]" в конце note:
--   "1000,500 [ОТП]" → Gold=1000, GP=500, on_leave=true
--   "1000,500"       → Gold=1000, GP=500, on_leave=false
--   "Player001"      → alt (on_leave наследуется от main)
-- Маркер "[ОТП]" используется ТОЛЬКО в конце note, слово "отпуск" внутри строки НЕ считается.
local function ParseNote(name, note)
  Addon.Log:NoteChanged(name, Addon.data.gold_data[name] and "had_data" or "new", note, "ParseNote")

  -- Грабли: при наличии pending не перезаписываем данные старой нотой с сервера
  -- (сервер присылает устаревшее значение, пока flush не завершён).
  if pending_note[name] and #pending_note[name] > 0 then
    Addon.Log:Debug("ParseNote: %s has pending_note, ignoring server note '%s'", name, tostring(note))
    return
  end

  Addon.data.gold_data[name] = nil
  Addon.data.gp_data[name] = nil
  Addon.data.main_data[name] = nil

  -- Извлекаем маркер отпуска [ОТП] из конца note.
  -- Regex: optional whitespace + [ + optional whitespace + ОТП + optional whitespace + ] + optional trailing whitespace
  -- Если маркер найден — удаляем его из note, выставляем on_leave=true.
  -- Если маркер НЕ найден — on_leave=nil (снимаем отпуск, если был).
  local isOnLeave = false
  local rawNote = note or ""
  if rawNote:match("%s%[%s*ОТП%s*%]%s*$") then
    isOnLeave = true
    rawNote = rawNote:gsub("%s%[%s*ОТП%s*%]%s*$", "")
  end
  rawNote = rawNote:gsub("%s+$", "")

  -- Выставляем on_leave для main. Для alt on_leave наследуется от main
  -- через IsMemberOnLeave helper (resolves alt→main). Здесь выставляем только для
  -- main (т.к. alt не имеет числовой note — его note = "MainName").
  -- Маркер в ноте — ОБЩИЙ источник истины для всех офицеров,
  -- db.global.on_leave — локальный кэш. Правила синхронизации:
  --   * маркер [ОТП] найден      → data = true  и db = true;
  --   * маркера НЕТ в ноте       → НЕ стираем отпуск, если он есть в db
  --     (отпуск ставится офицером через UI; старая нота без маркера — не повод
  --     стирать статус на каждом логине/ростер-апдейте).
  --     Снять отпуск можно через UI (SetOnLeave(false)) — она чистит и db, и ноту.
  if isOnLeave then
    Addon.data.on_leave[name] = true
    if Addon.db and Addon.db.global then
      if not Addon.db.global.on_leave then Addon.db.global.on_leave = {} end
      Addon.db.global.on_leave[name] = true
    end
  else
    local db_has = Addon.db and Addon.db.global and Addon.db.global.on_leave
                   and Addon.db.global.on_leave[name] and true or false
    if db_has then
      Addon.data.on_leave[name] = true
    else
      Addon.data.on_leave[name] = nil
    end
  end

  if not rawNote or rawNote == "" then
    Addon.data.gold_data[name] = 0
    Addon.data.gp_data[name] = 0
    Addon:BumpCacheVersion()
    return
  end

  -- Пробуем парсить "Gold,GP"
  local gold_str, gp_str = string.match(rawNote, "^(%d+),(%d+)$")
  if gold_str then
    Addon.data.gold_data[name] = tonumber(gold_str)
    Addon.data.gp_data[name] = tonumber(gp_str)
    Addon:BumpCacheVersion()
    return
  end

  -- Если не парсится — это либо alt (нота = имя main'а), либо битая нота
  if Addon.data.gold_data[rawNote] ~= nil then
    -- Это alt — нота указывает на main
    Addon.data.main_data[name] = rawNote
    -- Копируем EP/GP от main в alt чтобы alt был виден в gold_data
    -- и отображался в списке /gg с значениями мейна
    Addon.data.gold_data[name] = Addon.data.gold_data[rawNote] or 0
    Addon.data.gp_data[name] = Addon.data.gp_data[rawNote] or 0
    -- Класс альта НЕ копируется от мейна!
    -- Альт — отдельный персонаж со СВОИМ классом (копирование давало альту
    -- чужую иконку/цвет класса мейна).
    -- Класс альта приходит из ростера (проход выше по коду), а если он там
    -- не распознан — GetClassToken в UI резолвит авторитетные источники.
    Addon.data.rank_data[name] = Addon.data.rank_data[rawNote]
    Addon.data.rank_name_data[name] = Addon.data.rank_name_data[rawNote]
    -- Alt's on_leave inherits from main (через helper), но локальный флаг
    -- на alt не выставляем — IsMemberOnLeave(name) resolves alt→main.
    -- Снимаем alt's локальный on_leave, если был выставлен раньше.
    Addon.data.on_leave[name] = nil
    if not Addon.data.alt_data[rawNote] then
      Addon.data.alt_data[rawNote] = {}
    end
    local already = false
    for _, existing in ipairs(Addon.data.alt_data[rawNote]) do
      if existing == name then already = true break end
    end
    if not already then
      tinsert(Addon.data.alt_data[rawNote], name)
    end
    Addon:BumpCacheVersion()
  else
    -- Битая нота
    Addon.data.ignored[name] = rawNote
    Addon.Log:Warn("Invalid officer note for %s: '%s' (ignored)", name, rawNote)
  end
end

-- Удаление игрока из кэша
local function DeleteMember(name)
  Addon.data.gold_data[name] = nil
  Addon.data.gp_data[name] = nil
  Addon.data.main_data[name] = nil
  Addon.data.class_data[name] = nil
  Addon.data.rank_data[name] = nil
  Addon.data.rank_name_data[name] = nil
  Addon.data.ignored[name] = nil
  -- Чистим on_leave при удалении игрока из кэша
  Addon.data.on_leave[name] = nil
  -- Удалить из alt_data основного
  for main, alts in pairs(Addon.data.alt_data) do
    for i, alt in ipairs(alts) do
      if alt == name then
        tremove(alts, i)
        break
      end
    end
  end
end

-- ============================================================================
-- ИНИЦИАЛИЗАЦИЯ
-- ============================================================================
function Storage:Initialize()
  -- Создать фрейм для OnUpdate
  if not self.frame then
    self.frame = CreateFrame("Frame", "GoldGP_StorageFrame")
    self.frame:Show()
    self.frame:SetScript("OnUpdate", function(_, elapsed)
      Storage:FrameOnUpdate(elapsed)
    end)
  end
  GuildRoster()
  Addon.Log:Info("Storage initialized")
end

function Storage:Disable()
  -- Очистить данные
  wipe(Addon.data.gold_data)
  wipe(Addon.data.gp_data)
  wipe(Addon.data.main_data)
  wipe(Addon.data.alt_data)
  wipe(Addon.data.class_data)
  wipe(Addon.data.rank_data)
  wipe(Addon.data.rank_name_data)
  wipe(Addon.data.ignored)
  wipe(cache)
  wipe(pending_note)
  state = "STALE_WAITING_FOR_ROSTER_UPDATE"
  initialized = false
end

-- ============================================================================
-- ГЛАВНЫЙ ЦИКЛ — FrameOnUpdate
-- ============================================================================
-- ВАЖНО: обрабатывает pending_note по ОЧЕРЕДИ (а не одно значение на имя)!
-- Интервал настраивается через profile.update_interval:
--   0.05 = 20 раз/сек (быстро, но больше CPU)
--   0.10 = 10 раз/сек (по умолчанию, баланс)
--   0.20 = 5 раз/сек (для слабых ПК)
local update_timer = 0
-- Счётчик неудачных flush-попыток (сохраняется между кадрами)
local flush_fail_count = 0

local function get_update_interval()
  if Addon.db and Addon.db.profile and Addon.db.profile.update_interval then
    return Addon.db.profile.update_interval
  end
  return 0.1  -- по умолчанию 10 раз/сек
end

function Storage:FrameOnUpdate(elapsed)
  update_timer = update_timer + elapsed
  local interval = get_update_interval()
  if update_timer < interval then return end
  update_timer = 0

  if state == "CURRENT" then
    -- Flush pending_public_note даже в CURRENT state
    if next(pending_public_note) then
      for name, note in pairs(pending_public_note) do
        local e = cache[name]
        if e and e.guild_index then
          GuildRosterSetPublicNote(e.guild_index, note)
          e.public_note = note
          pending_public_note[name] = nil
        end
      end
      -- Запросить обновление ростера чтобы получить актуальные public notes
      GuildRoster()
    end
    return
  end

  if state == "STALE_WAITING_FOR_ROSTER_UPDATE" then
    -- GuildRoster() НЕ чаще 1 раза в 1.5 сек (защита от спама на сервер, если
    -- сервер задерживает ответ): максимум ~0.7 запроса/сек при полном молчании
    -- сервера, а через 3 сек — recovery в CURRENT.
    local now_t = GetTime()
    if now_t - stale_waiting_last_request >= 1.5 then
      stale_waiting_last_request = now_t
      GuildRoster()
    end
    -- Если сервер не прислал GUILD_ROSTER_UPDATE за 3 сек — идём в CURRENT,
    -- pending-ноты (если появятся) сами переведут состояние в FLUSHING.
    if stale_waiting_since > 0 and (now_t - stale_waiting_since) > 3.0 then
      Addon.Log:Debug("STALE_WAITING for %.1fs - recovering to CURRENT", now_t - stale_waiting_since)
      Storage:SetState("CURRENT")
    end
    return
  end

  -- REMOTE_FLUSHING recovery.
  -- При timeout 5-10 сек (используем 7 сек как middle ground):
  --   1. WARN в лог.
  --   2. GuildRoster() запрос.
  --   3. Переход в STALE_WAITING_FOR_ROSTER_UPDATE.
  --   4. После roster update (OnRosterUpdate) — STALE -> CURRENT через FrameOnUpdate.
  -- Если remote_flushing_sender ущёл из игры, этот timeout сработает — Storage не блокируется навсегда.
  -- Pending notes НЕ теряются (pending_note нетронут).
  if state == "REMOTE_FLUSHING" and remote_flushing_since > 0 then
    local stuck_time = GetTime() - remote_flushing_since
    if stuck_time > 7.0 then
      Addon.Log:Warn("REMOTE_FLUSHING stuck for %.1fs (sender=%s) — requesting roster",
        stuck_time, tostring(remote_flushing_sender))
      remote_flushing_sender = nil
      GuildRoster()
      Storage:SetState("STALE_WAITING_FOR_ROSTER_UPDATE")
      return
    end
    -- Ещё не timeout — ждём CHANGES_FLUSHED или roster update
    return
  end

  -- Восстановление из FLUSHING:
  --   1. pending ПУСТ > 1.0 сек -> CURRENT (сервер получил ноту)
  --   2. pending НЕ пуст > 2.0 сек -> сбрасываем stuck_timer и продолжаем flush
  --      (до 5 записей за кадр). После 5 неудачных попыток — CURRENT с предупреждением.
  if state == "FLUSHING" and flushing_since > 0 then
    local stuck_time = GetTime() - flushing_since
    local has_pending = false
    local pending_count = 0
    for _ in pairs(pending_note) do
      has_pending = true
      pending_count = pending_count + 1
    end
    if not has_pending and stuck_time > 1.0 then
      -- Pending пуст, но сервер не прислал GUILD_ROSTER_UPDATE за 1 сек
      -- Нота уже отправлена на сервер через GuildRosterSetOfficerNote — безопасно вернуться в CURRENT
      Addon.Log:Debug("FLUSHING with no pending for %.1fs — recovering to CURRENT", stuck_time)
      Storage:SetState("CURRENT")
      return
    end
    if has_pending and stuck_time > 2.0 then
      -- Не делаем force-CURRENT сразу — даём циклу flush-а шанс.
      flush_fail_count = flush_fail_count + 1
      Addon.Log:Warn("FLUSHING stuck for %.1fs with %d pending — attempt %d to flush",
        stuck_time, pending_count, flush_fail_count)
      if flush_fail_count >= 5 then
        -- 5 попыток (≈0.5 сек) не помогли — действительно CURRENT с предупреждением
        Addon.Log:Warn("Force-recovering to CURRENT after 5 failed flush attempts. " ..
          "Pending notes may not be synced with server!")
        Addon.PrintError("Внимание: не удалось записать " .. pending_count ..
          " нот на сервер. Возможна рассинхронизация. Выполните /gg refresh.")
        Storage:SetState("CURRENT")
        flush_fail_count = 0
        return
      end
      -- Сбрасываем stuck-timer и ПРОДОЛЖАЕМ выполнение — цикл flush-а отработает ниже
      flushing_since = GetTime()
      -- НЕ return! Падаем в основной цикл ниже.
    end
  end

  -- Иногда GetNumGuildMembers возвращает 0 — ждём
  local total = GetNumGuildMembers(true)
  if total == 0 then return end

  if not index or index >= total then
    index = 1
  end

  -- Читаем гильдейский info при первом проходе
  if index == 1 then
    local new_info = GetGuildInfoText() or ""
    if new_info ~= current_guild_info then
      current_guild_info = new_info
      ParseGuildInfo(new_info)
    end
  end

  -- Обрабатываем до 100 членов за раз (5 при stuck-flush — не фризим UI)
  local batch_size = (flush_fail_count > 0) and 5 or 100
  local last_index = math.min(index + batch_size, total)

  for i = index, last_index do
    -- Сигнатура 3.3.5a:
    --   name(1), rank(2), rankIndex(3), level(4), class(5), zone(6),
    --   publicNote(7), officerNote(8), online(9), status(10)
    -- class — именно 5-е значение (11-й позиции не существует).
    local name, rank, rank_index, _, class, _, publicNote, note, _, _ = GetGuildRosterInfo(i)
    if name then
      -- Защита от приваток, где порядок rank/rankIndex перевёрнут:
      -- канон 3.3.5a — pos2 = ИМЯ звания (string), pos3 = ИНДЕКС (number).
      if type(rank) == "number" then
        rank, rank_index = rank_index, rank
      end
      -- Убираем сервер-суффикс
      name = strsplit("-", name)
      local entry = cache[name]
      local pending = pending_note[name]
      local pending_pub = pending_public_note[name]

      if not entry then
        entry = {}
        cache[name] = entry
      end

      entry.seen = true
      -- UI (CLASS_COLORS / CLASS_ICON_TCOORDS) индексируется АНГЛИЙСКИМ
      -- токеном класса ("WARRIOR"), а GetGuildRosterInfo возвращает ЛОКАЛИЗОВАННОЕ
      -- имя ("Воин" на ruRU). Конвертация — ниже, через NormalizeClassToken
      -- (нормализация + сохранение валидного значения).
      entry.guild_index = i  -- для GuildRosterSetPublicNote

      -- Парсинг public note для посещаемости
      if not pending_pub then
        entry.public_note = publicNote
        if initialized then
          ParsePublicNote(name, publicNote)
        end
      end

      -- Сохраняем класс (английский токен для UI) / rank для быстрого доступа
      -- Нормализация + сохранение предыдущего валидного значения.
      local class_token = NormalizeClassToken(class)
      if class_token then
        Addon.data.class_data[name] = class_token
      elseif not IsKnownToken(Addon.data.class_data[name]) then
        -- Валидного значения нет ни в ростере, ни в кэше — чистим (GetClassToken
        -- попробует авторитетные источники: мейн / рейд / группа)
        Addon.data.class_data[name] = nil
      end
      Addon.data.rank_data[name] = rank_index
      Addon.data.rank_name_data[name] = rank

      -- Если нота изменилась — парсим.
      -- Грабли: при наличии pending не перезаписываем entry.note значением с сервера
      -- (сервер может прислать старую ноту, пока flush не завершён).
      if entry.note ~= note then
        local old_note = entry.note
        if pending and #pending > 0 then
          -- У нас есть pending — не трогаем entry.note и gold_data
          Addon.Log:Debug("Server sent note '%s' for %s but we have pending — ignoring", tostring(note), name)
        else
          entry.note = note
          if initialized then
            ParseNote(name, note)
            Addon:Fire("NoteChanged", name, note)
          end
        end
        -- Если есть pending и он не совпадает с сервером — это InconsistentNote
        if pending and pending[1] ~= note then
          Addon.Log:Warn("InconsistentNote: %s | server='%s' | pending[1]='%s'",
            name, tostring(note), tostring(pending[1]))
        end
      end

      -- Сбросить ОДНО значение из очереди pending
      if pending and #pending > 0 then
        local next_note = pending[1]
        GuildRosterSetOfficerNote(i, next_note)
        Addon.Log:PendingFlushed(name, next_note)
        -- Обновляем локальный кэш сразу (оптимистично)
        entry.note = next_note
        -- Удаляем первый элемент из очереди
        tremove(pending, 1)
        -- Если очередь пуста — удаляем ключ
        if #pending == 0 then
          pending_note[name] = nil
        end
        flush_fail_count = 0
      end

      -- flush pending_public_note (посещаемость)
      if pending_pub then
        GuildRosterSetPublicNote(i, pending_pub)
        entry.public_note = pending_pub
        pending_public_note[name] = nil
      end
    end
  end

  index = last_index
  if index >= total then
    -- Закончили обход
    -- Удаляем "невидимые" записи
    for name, entry in pairs(cache) do
      if entry.seen then
        entry.seen = false
      else
        cache[name] = nil
        DeleteMember(name)
        Addon:Fire("NoteDeleted", name)
      end
    end

    -- Самолечение классов из ЖИВЫХ источников — ТОЛЬКО СОБСТВЕННЫЙ класс
    -- игрока, БЕЗ наследования от мейна (наследование давало альту чужую иконку).
    -- Источники: state.raid_units[name] (токен из GetRaidRosterInfo — авторитетный,
    -- английский) + живой UnitClass для группы. O(N) один раз за полный проход.
    do
      local raid_units = Addon.state and Addon.state.raid_units or nil
      local in_party = GetNumPartyMembers and GetNumPartyMembers() > 0
      for name in pairs(cache) do
        if not IsKnownToken(Addon.data.class_data[name]) then
          local healed = raid_units and raid_units[name] or nil
          if not IsKnownToken(healed) and in_party then
            -- Группа: живой UnitClass (O(1..5))
            if UnitName("player") == name then
              healed = select(2, UnitClass("player"))
            else
              for j = 1, GetNumPartyMembers() do
                if UnitName("party" .. j) == name then
                  healed = select(2, UnitClass("party" .. j))
                  break
                end
              end
            end
          end
          if IsKnownToken(healed) then
            Addon.data.class_data[name] = healed
          end
        end
      end
    end

    if not initialized then
      -- ДВУХПРОХОДНЫЙ ПАРСИНГ:
      -- 1-й проход: парсим только mains (notes в формате "Gold,GP")
      -- 2-й проход: парсим alts (notes, указывающие на main)
      -- Это нужно, потому что при сортировке по имени alt может идти
      -- раньше main — и main ещё не будет в gold_data.
      local pending_alts = {}
      for name, entry in pairs(cache) do
        local note = entry.note
        if note and note ~= "" then
          local gold_str, gp_str = string.match(note, "^(%d+),(%d+)$")
          if gold_str then
            -- Это main
            ParseNote(name, note)
          else
            -- Откладываем — это может быть alt
            tinsert(pending_alts, { name = name, note = note })
          end
        else
          -- Пустая нота — это main с 0,0
          ParseNote(name, note)
        end
      end
      -- 2-й проход: теперь все mains загружены, парсим alts
      for _, alt_entry in ipairs(pending_alts) do
        ParseNote(alt_entry.name, alt_entry.note)
      end
      initialized = true
      -- Ростер впервые реально распарсен. Сообщаем Core, чтобы он мог
      -- выполнить отложенную чистку on_leave (CleanupOldData при входе в мир
      -- ещё НЕ имеет данных ростера — GuildRoster() асинхронный).
      Addon:Fire("RosterReady")
      local mains_count = 0
      local alts_count = 0
      for _ in pairs(Addon.data.gold_data) do mains_count = mains_count + 1 end
      for _ in pairs(Addon.data.main_data) do alts_count = alts_count + 1 end
      -- Кэшируем число mains для UI (чтобы не делать O(N) проход при каждом скролле)
      Addon.data.member_count = mains_count
      Addon.Log:Info("Storage initialized: %d mains, %d alts, %d ignored",
        mains_count, alts_count, (function()
          local n = 0
          for _ in pairs(Addon.data.ignored) do n = n + 1 end
          return n
        end)())
    end

    -- Меняем состояние
    if state == "STALE" then
      Storage:SetState("CURRENT")
    elseif state == "FLUSHING" then
      -- Проверяем, что ВСЕ очереди pending пусты
      local has_pending = false
      for _ in pairs(pending_note) do
        has_pending = true
        break
      end
      if not has_pending then
        -- После flush сразу в CURRENT (а не в STALE_WAITING) — sirus.su часто
        -- не присылает GUILD_ROSTER_UPDATE после flush, состояние залипает.
        Storage:SetState("CURRENT")
        SendAddonMessage("GoldGP", "CHANGES_FLUSHED", "GUILD")
        Addon.Log:Debug("Flush complete, returning to CURRENT (no STALE_WAITING)")
      end
    end
  end
end

-- ============================================================================
-- СТАТИСТИКА (для отладки)
-- ============================================================================
function Storage:GetStats()
  local pending_count = 0
  local pending_total = 0
  for _, queue in pairs(pending_note) do
    pending_count = pending_count + 1
    pending_total = pending_total + #queue
  end
  local cache_count = 0
  for _ in pairs(cache) do cache_count = cache_count + 1 end

  return {
    state = state,
    cache_size = cache_count,
    pending_names = pending_count,
    pending_total_notes = pending_total,
    initialized = initialized,
  }
end

if Addon.Log then Addon.Log:Info("GoldGP_Storage loaded (with FIXED pending_note queue)") end
