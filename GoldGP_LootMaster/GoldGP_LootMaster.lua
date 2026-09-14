-- GoldGP_LootMaster.lua
-- Отложенный старт: глобаль GoldGPLootMaster создаётся ВСЕГДА (до boot) —
-- Client/ML/Options всегда привязываются; всё тело обёрнуто в boot(Addon)
-- (намеренно без ре-индентации); если ядро ещё не загружено — waiter (до 30с)
-- ждёт GoldGP и доинициализирует модуль через LM:_PostLoadInit(); при
-- таймауте — громкое сообщение в чат.
-- НЕЛЬЗЯ возвращать ранний выход при отсутствии ядра — модуль молча умирает.

_G.GoldGPLootMaster = _G.GoldGPLootMaster or {}

local boot = function(Addon)
local LM = _G.GoldGPLootMaster

-- ============================================================================
-- КОНСТАНТЫ
-- ============================================================================

local VERSION = "0.7.4"
local PREFIX_ML_TO_CLIENT = "GoldGPLM"     -- ML → клиенты
local PREFIX_CLIENT_TO_ML = "GoldGPLM_R"   -- клиенты → ML
local DEFAULT_TIMEOUT = 60                  -- сек

-- Байт версии протокола: все сообщения начинаются с V<n>^.
-- При несовпадении версии — молча отбрасываем (одно предупреждение на отправителя).
-- Протокол V2: lootKey — первое поле каждого loot-сообщения
-- (DO_YOU_WANT/WANT/GEAR/LOOTED/DISCARD); одного itemID недостаточно —
-- два одинаковых предмета должны быть независимыми экземплярами.
-- V1-клиенты отклоняются с однократным предупреждением (см. StripProtocolVersion).
local PROTOCOL_VERSION = 2
local PROTOCOL_PREFIX = "V" .. PROTOCOL_VERSION .. "^"

-- Предупреждение о несовпадении версии — одно на отправителя (анти-спам чата)
local warned_version_mismatch = {}

-- Response IDs
local RESPONSE = {
  WAIT       = 0,
  NEED       = 1,   -- Мейн спек
  OFFSPEC    = 2,   -- Офф спек
  PASS       = 3,   -- Откажусь
  TIMEOUT    = 4,
}

-- Тексты ответов для отображения
local RESPONSE_TEXT = {
  [0] = "|cFF808080ожидание...|r",
  [1] = "|cFF30AA30Мейн спек|r",
  [2] = "|cFFF0A000Офф спек|r",
  [3] = "|cFF808080Откажусь|r",
  [4] = "|cFFFF5050Время вышло|r",
}

-- Сортировка ответов (меньше = выше в таблице)
local RESPONSE_SORT = {
  [0] = 400,  -- WAIT
  [1] = 100,  -- NEED (Мейн спек) — самый высокий приоритет
  [2] = 200,  -- OFFSPEC
  [3] = 300,  -- PASS
  [4] = 350,  -- TIMEOUT
}

-- Типы выдачи лута
local LOOTTYPE = {
  UNKNOWN    = 1,
  GP         = 2,   -- Отдать + GP
  BANK       = 4,   -- В банк
  FREE       = 5,   -- Бесплатно (GP = 0)
}

-- ============================================================================
-- СОСТОЯНИЕ АДДОНА
-- ============================================================================

LM.state = {
  -- Кто мы: ML или кандидат
  isML = false,           -- true если мы Master Looter
  mlName = nil,           -- имя текущего ML

  -- sessionId — уникален для каждой ML-сессии. Генерируется в InitML и при
  -- смене ML. Все lootKey префиксируются sessionId, поэтому сообщения от
  -- старой сессии автоматически отбрасываются (lootKey не найдётся в lootTable).
  sessionId = nil,
  -- Последовательный счётчик для генерации lootKey, если slotID недоступен
  -- (например, ручное добавление через /gg loot add).
  lootSeq = 0,

  -- Текущий список лута (для ML)
  lootTable = {},         -- [lootKey] = { link, name, itemID, texture, rarity, ilevel, equipLoc, gpValue, slotID, quantity, candidates = {}, candidateOrder = {} }

  -- Список предметов для кандидата (для клиента)
  clientLootList = {},    -- [i] = { lootKey, itemID, link, texture, name, ilevel, gpValue, quality, equipLoc, timeout, mlName }

  -- Идемпотентность обеспечивается lootKey-матчингом в pendingAwards
  -- и TTL-очисткой (PurgeStalePendingAwards).

  -- Очередь ожидаемых выдач для CHAT_MSG_LOOT matching:
  -- pendingAwards[itemID][candidate] = { lootKey1, lootKey2, ... }
  -- При выдаче (GiveMasterLoot) lootKey добавляется в очередь; при приходе
  -- CHAT_MSG_LOOT первый lootKey извлекается — ровно один за одно событие.
  pendingAwards = {},

  -- Recovery-структура для pending GP записей при смене ML:
  -- recoveryQueue[i] = { lootKey, player, link, itemID, lootType, lootGP,
  --   gpPendingAmount, gpPendingReason, sourceSessionId }
  -- При EndLootSession записи с gpPending=true извлекаются сюда до очистки lootTable.
  -- FlushPendingGP итерирует recoveryQueue в дополнение к lootTable.
  recoveryQueue = {},
}

-- LM.mlFrame — ссылка на ML-окно, присваивается в GoldGP_LootMaster_ML.lua
-- (CreateMLWindow). Используется в EndLootSession/finish_test/TestReset, чтобы
-- скрыть открытое ML-окно при завершении сессии.
LM.mlFrame = nil

-- Тестовый режим. Запрещает реальные побочные эффекты:
--   GiveMasterLoot, IncGP, изменение officer notes, реальные RAID/PARTY broadcast.
-- Включается через /gg loot testfull (одноразово на один запуск) и сбрасывается
-- через /gg loot testreset.
LM.testMode = false
-- LM.testAwards — список GP awards, применённых в testMode: заполняется
-- OnChatMsgLoot testMode branch вместо реального Addon.Award:IncGP, чтобы
-- TestFull/TestDuplicates проверяли фактические суммы GP (400/200)
-- и порядок применения. Очищается при test setup и в finish_test.
LM.testAwards = {}

-- Timestamps постановки в очередь pendingAwards (TTL-очистка).
LM.pendingAwardsAt = {}

-- ============================================================================
-- ЦЕНТРАЛИЗОВАННЫЕ ПОИСКОВЫЕ ФУНКЦИИ
-- ============================================================================
-- Все UI/protocol операции должны искать loot по lootKey, а не по itemID.
-- itemID — тип предмета; lootKey — конкретный экземпляр в конкретной сессии.
-- ============================================================================

-- Найти loot в ML-side lootTable по lootKey. O(1) hash lookup.
function LM:FindLootByKey(lootKey)
  if not lootKey then return nil end
  return LM.state.lootTable[lootKey]
end

-- Найти loot в client-side clientLootList по lootKey. Linear scan.
function LM:FindClientLootByKey(lootKey)
  if not lootKey then return nil end
  for _, cl in ipairs(LM.state.clientLootList) do
    if cl.lootKey == lootKey then
      return cl
    end
  end
  return nil
end

-- ============================================================================
-- SESSION MANAGEMENT HELPERS
-- ============================================================================
-- lootKey = sessionId:itemID:slotID-or-seq. Все сообщения от ML содержат
-- sessionId в lootKey. При смене ML генерируется новый sessionId, поэтому
-- сообщения от старого ML автоматически отбрасываются (lootKey не найдётся
-- в lootTable, либо явно отклоняется IsCurrentSession проверкой в парсерах).
-- ============================================================================

-- Извлечь sessionId из lootKey (часть до первого ":").
function LM:GetLootSessionId(lootKey)
  if not lootKey then return nil end
  local _, _, sid = string.find(lootKey, "^([^:]+):")
  return sid
end

-- Проверить, что lootKey принадлежит текущей ML-сессии.
-- Если LM.state.sessionId nil (мы не ML и не знаем текущую сессию),
-- принимаем сообщение (это для клиентов, которые ещё не знают sessionId).
function LM:IsCurrentSession(lootKey)
  if not lootKey then return false end
  if not LM.state.sessionId then return true end  -- клиент не знает текущую сессию
  local sid = LM:GetLootSessionId(lootKey)
  return sid == LM.state.sessionId
end

-- Начать новую ML-сессию: сгенерировать sessionId, сбросить lootSeq,
-- установить mlName, закрыть старые клиентские popup.
-- Вызывается из InitML и при смене ML на player.
function LM:BeginLootSession(mlName)
  LM.state.sessionId = string.format("s_%d_%d", time(), math.floor(GetTime() * 1000))
  LM.state.lootSeq = 0
  LM.state.mlName = mlName or UnitName("player")
  -- Закрываем старые клиентские popup (если у нас остались от прошлого ML)
  if LM.ResetClientLootState then
    LM:ResetClientLootState("begin_session")
  end
  if Addon and Addon.Log then
    Addon.Log:Debug("[LootMaster] BeginLootSession: sessionId=%s mlName=%s",
      tostring(LM.state.sessionId), tostring(LM.state.mlName))
  end
end

-- Завершить текущую ML-сессию: извлечь pending-GP записи в recoveryQueue,
-- сбросить sessionId/mlName/isML/trackingEnabled, скрыть mlFrame,
-- закрыть клиентские popup.
-- Вызывается при смене ML away from player и при A->B transition (не player).
function LM:EndLootSession(reason)
  if Addon and Addon.Log and Addon.Log.Debug then
    Addon.Log:Debug("[LootMaster] EndLootSession: reason=%s sessionId=%s",
      tostring(reason), tostring(LM.state.sessionId))
  end
  -- Извлекаем pending-GP записи в recoveryQueue (чтобы не потерять retry state)
  if LM.state.lootTable then
    for lootKey, loot in pairs(LM.state.lootTable) do
      if loot.candidates then
        for name, cand in pairs(loot.candidates) do
          if cand.gpPending and not cand.gpProcessed then
            tinsert(LM.state.recoveryQueue, {
              lootKey = lootKey,
              player = name,
              link = loot.link,
              itemID = loot.itemID,
              lootType = cand.lootType or LM.LOOTTYPE.UNKNOWN,
              lootGP = cand.gpPendingAmount or cand.lootGP or 0,
              gpPendingAmount = cand.gpPendingAmount or 0,
              gpPendingReason = cand.gpPendingReason,
              sourceSessionId = LM.state.sessionId,
            })
            -- ВАЖНО: помечаем ОРИГИНАЛ как обработанный — долг живёт ТОЛЬКО в
            -- recoveryQueue. Иначе (повторный вход как ML, /reload — RestoreLootTable)
            -- FlushPendingGP спишет GP ИЗ lootTable И ИЗ recoveryQueue — двойное
            -- списание. Ровно ОДИН путь charge (lootTable-loop ИЛИ recoveryQueue).
            cand.gpProcessed = true
          end
        end
      end
    end
  end
  -- Сбрасываем сессионное состояние
  LM.state.sessionId = nil
  LM.state.mlName = nil
  LM.state.isML = false
  LM.trackingEnabled = nil
  -- Чистим pendingAwards (они относились к старой сессии)
  LM.state.pendingAwards = {}
  -- Закрываем клиентские popup (старые DO_YOU_WANT больше не валидны)
  if LM.ResetClientLootState then
    LM:ResetClientLootState("end_session_" .. tostring(reason))
  end
  -- Скрываем ML-окно если открыто
  if LM.mlFrame and LM.mlFrame:IsShown() then
    LM.mlFrame:Hide()
  end
  -- Восстанавливаем как минимум 1 ссылку на lootTable — он остаётся,
  -- но без сессионного контекста. Записи с mayDistribute=false будут очищены
  -- ScheduleLootCleanup по таймауту.
end

-- ============================================================================
-- НОРМАЛИЗАЦИЯ itemID И ИМЁН КАНДИДАТОВ
-- ============================================================================
-- itemID может быть number (от LM.GetItemIDFromLink), string (от протокола/
-- тестов) или вообще nil. Для Lua это разные ключи таблицы:
--   pendingAwards[40354] ~= pendingAwards["40354"]
-- ОБЯЗАТЕЛЬНО все ключи pendingAwards проходят через NormalizeItemID,
-- чтобы гарантировать один и тот же тип (string).
-- ============================================================================

-- Нормализовать itemID в строку вида "40354" (без суффиксов, без floating point).
-- Принимает number, string, или nil. Если невалидно — возвращает nil.
function LM:NormalizeItemID(itemID)
  if itemID == nil then return nil end
  local value = itemID
  -- Если передали item link, попробуем извлечь itemID через regex
  if type(value) == "string" then
    local parsed = LM.GetItemIDFromLink(value)
    if parsed then
      value = parsed
    end
  end
  local numeric = tonumber(value)
  if not numeric then return nil end
  return tostring(math.floor(numeric))
end

-- Нормализовать имя кандидата — убрать server suffix.
-- "Player-Realm" → "Player". Nil-safe.
function LM:NormalizePlayerName(name)
  if not name then return nil end
  -- strsplit возвращает first token до разделителя "-"
  return strsplit("-", name) or name
end

-- ============================================================================
-- ЦЕНТРАЛИЗОВАННАЯ ОЧЕРЕДЬ pendingAwards
-- ============================================================================
-- Все обращения к LM.state.pendingAwards должны проходить через эти 3 функции:
--   QueuePendingAward  — добавить lootKey (с защитой от дубликата)
--   PeekPendingAward   — посмотреть первый lootKey без удаления
--   RemovePendingAward — удалить конкретный lootKey (после успешного matching)
-- Прямой доступ LM.state.pendingAwards[...] запрещён.
-- ============================================================================

-- Добавить lootKey в очередь pendingAwards[itemID][candidate].
-- Защита от повторного lootKey обязательна — двойной клик не должен добавлять
-- один предмет дважды. Возвращает true при успехе, false при невалидных args.
function LM:QueuePendingAward(itemID, candidate, lootKey)
  local itemKey = LM:NormalizeItemID(itemID)
  -- Нормализуем имя кандидата (без server suffix)
  local candKey = LM:NormalizePlayerName(candidate)
  if not itemKey or not candKey or not lootKey then
    return false
  end
  if not LM.state.pendingAwards[itemKey] then
    LM.state.pendingAwards[itemKey] = {}
  end
  if not LM.state.pendingAwards[itemKey][candKey] then
    LM.state.pendingAwards[itemKey][candKey] = {}
  end
  local queue = LM.state.pendingAwards[itemKey][candKey]
  -- Защита от дубликата: проверяем, нет ли уже такого lootKey в очереди
  for _, existingKey in ipairs(queue) do
    if existingKey == lootKey then
      -- Уже в очереди — не добавляем повторно (двойной клик защитился)
      return true
    end
  end
  tinsert(queue, lootKey)
  -- Timestamp для TTL-очистки
  if not LM.pendingAwardsAt[itemKey] then LM.pendingAwardsAt[itemKey] = {} end
  if not LM.pendingAwardsAt[itemKey][candKey] then LM.pendingAwardsAt[itemKey][candKey] = {} end
  LM.pendingAwardsAt[itemKey][candKey][lootKey] = time()
  return true
end

-- Посмотреть первый lootKey в очереди без удаления.
-- Возвращает: lootKey, queue_table, itemKey (или nil если очередь пуста/отсутствует).
function LM:PeekPendingAward(itemID, candidate)
  local itemKey = LM:NormalizeItemID(itemID)
  local candKey = LM:NormalizePlayerName(candidate)
  if not itemKey or not candKey then return nil end
  local byCandidate = LM.state.pendingAwards[itemKey]
  local queue = byCandidate and byCandidate[candKey]
  if not queue or #queue == 0 then
    return nil
  end
  return queue[1], queue, itemKey
end

-- Удалить конкретный lootKey из очереди (после успешного matching).
-- Возвращает true при удалении, false если lootKey не найден.
-- Чистит пустые очереди чтобы не засорять LM.state.pendingAwards.
function LM:RemovePendingAward(itemID, candidate, lootKey)
  local itemKey = LM:NormalizeItemID(itemID)
  local candKey = LM:NormalizePlayerName(candidate)
  if not itemKey or not candKey then return false end
  local byCandidate = LM.state.pendingAwards[itemKey]
  local queue = byCandidate and byCandidate[candKey]
  if not queue then return false end
  for i, queuedKey in ipairs(queue) do
    if queuedKey == lootKey then
      tremove(queue, i)
      -- Чистим и timestamp
      if LM.pendingAwardsAt[itemKey] and LM.pendingAwardsAt[itemKey][candKey] then
        LM.pendingAwardsAt[itemKey][candKey][lootKey] = nil
      end
      -- Чистим пустые очереди
      if #queue == 0 then
        byCandidate[candKey] = nil
      end
      if LM.pendingAwardsAt[itemKey] and not next(LM.pendingAwardsAt[itemKey][candKey] or {}) then
        LM.pendingAwardsAt[itemKey][candKey] = nil
      end
      if not next(byCandidate) then
        LM.state.pendingAwards[itemKey] = nil
      end
      return true
    end
  end
  return false
end

-- ============================================================================
-- ОЧИСТКА "ПРИЗРАКОВ" В ОЧЕРЕДИ pendingAwards
-- ============================================================================
-- "Призрак" = lootKey, чей loot уже удалён из lootTable (таймаут/отмена/конец
-- сессии), но lootKey продолжает висеть ПЕРВЫМ в очереди pendingAwards.
-- PeekPendingAward всегда возвращает ПЕРВЫЙ элемент — призрак навсегда блокирует
-- все последующие выдачи того же itemID+игроку (валидация не проходит, а ключ
-- не удаляется). Защита:
--   * ScheduleLootCleanup удаляет ключи выданных/просроченных лутов из очереди;
--   * OnChatMsgLoot при невалидной записи УДАЛЯЕТ призрака и продолжает поиск;
--   * TTL 10 минут — страховка от любых других утечек.
-- ============================================================================

-- Удалить все вхождения lootKey из очередей pendingAwards (по всему дереву).
-- Вызывается при удалении лута из lootTable (cleanup/отмена).
function LM:PurgePendingAwardByLootKey(lootKey)
  if not lootKey then return end
  for itemKey, byCandidate in pairs(LM.state.pendingAwards) do
    for candKey, queue in pairs(byCandidate) do
      for i = #queue, 1, -1 do
        if queue[i] == lootKey then
          tremove(queue, i)
          if LM.pendingAwardsAt[itemKey] and LM.pendingAwardsAt[itemKey][candKey] then
            LM.pendingAwardsAt[itemKey][candKey][lootKey] = nil
          end
        end
      end
      if #queue == 0 then
        byCandidate[candKey] = nil
        if LM.pendingAwardsAt[itemKey] then
          LM.pendingAwardsAt[itemKey][candKey] = nil
        end
      end
    end
    if not next(byCandidate) then
      LM.state.pendingAwards[itemKey] = nil
    end
  end
end

-- TTL: удалить записи старше PENDING_AWARD_TTL секунд (страховка).
local PENDING_AWARD_TTL = 600  -- 10 минут
function LM:PurgeStalePendingAwards()
  local now = time()
  for itemKey, byCandidate in pairs(LM.pendingAwardsAt) do
    for candKey, stamps in pairs(byCandidate) do
      for lootKey, ts in pairs(stamps) do
        if (now - (ts or 0)) > PENDING_AWARD_TTL then
          stamps[lootKey] = nil
          local queue = LM.state.pendingAwards[itemKey] and LM.state.pendingAwards[itemKey][candKey]
          if queue then
            for i = #queue, 1, -1 do
              if queue[i] == lootKey then tremove(queue, i) end
            end
          end
        end
      end
    end
    -- Чистим пустые ветки
    local byCand = LM.state.pendingAwards[itemKey]
    if byCand then
      for candKey, queue in pairs(byCand) do
        if #queue == 0 then byCand[candKey] = nil end
      end
      if not next(byCand) then LM.state.pendingAwards[itemKey] = nil end
    end
    for candKey, stamps in pairs(byCandidate) do
      if not next(stamps) then byCandidate[candKey] = nil end
    end
    if not next(byCandidate) then LM.pendingAwardsAt[itemKey] = nil end
  end
end

-- ============================================================================
-- TABLE POOL (переиспользование таблиц — снижает GC pressure)
-- ============================================================================
-- Вдохновлено EPGP_LootMaster/lootmaster.lua:84-92
local _tablePool = {}
local function popTable()
  return tremove(_tablePool, 1) or {}
end
local function pushTable(t)
  if type(t) ~= "table" then return end
  wipe(t)
  tinsert(_tablePool, t)
end
LM._popTable = popTable
LM._pushTable = pushTable

-- ============================================================================
-- ITEM INFO CACHE (убирает двойные вызовы GetItemInfo)
-- ============================================================================
-- GetItemInfo — тяжёлая синхронная функция. При первом запросе предмета,
-- которого нет в кэше клиента, она возвращает nil и асинхронно запрашивает
-- данные у сервера. Повторный вызов вернёт уже закэшированные данные.
-- Здесь мы храним результат на 5 минут чтобы не дёргать WoW-кэш понапрасну.
LM.itemInfoCache = {}
LM.itemInfoCacheVersion = 0  -- bump для принудительной очистки
local ITEM_CACHE_TTL = 300   -- 5 минут

-- Возвращает: name, link, rarity, level, equipLoc (как GetItemInfo, но первые 5 нужных полей)
function LM:GetCachedItemInfo(link)
  if not link or link == "" then return end
  local now = GetTime()
  local cached = LM.itemInfoCache[link]
  if cached and cached.cacheVer == LM.itemInfoCacheVersion and (now - cached.ts) < ITEM_CACHE_TTL then
    return cached.name, cached.link, cached.rarity, cached.level, cached.equipLoc
  end
  -- Запрос к GetItemInfo (один вызов вместо двух!)
  local name, _, rarity, level, _, _, _, _, equipLoc = GetItemInfo(link)
  if name then
    -- Кэшируем только если сервер вернул данные (name не nil)
    LM.itemInfoCache[link] = {
      name = name,
      link = link,
      rarity = rarity,
      level = level,
      equipLoc = equipLoc,
      ts = now,
      cacheVer = LM.itemInfoCacheVersion,
    }
  end
  return name, link, rarity, level, equipLoc
end

-- Принудительно очистить кэш предметов (например, после /reload)
function LM:ClearItemCache()
  wipe(LM.itemInfoCache)
  LM.itemInfoCacheVersion = LM.itemInfoCacheVersion + 1
end

-- ============================================================================
-- ФАЗА 1: ПРОТОКОЛ КОММУНИКАЦИИ
-- ============================================================================
--
-- Протокол V2: lootKey — первый field каждого сообщения.
-- lootKey = sessionId .. ":" .. itemID .. ":" .. slotID-or-seq
-- itemID — тип предмета (одинаковые предметы имеют одинаковый itemID);
-- lootKey — конкретный экземпляр (два одинаковых предмета = два lootKey).
--
-- Формат сообщений (разделитель ^):
--   DO_YOU_WANT:lootKey^itemID^gpValue^ilvl^quality^equipLoc^timeout^link^texture
--   WANT:lootKey^response^note
--   GEAR:lootKey^itemID1^gp1^ilvl1^itemID2^gp2^ilvl2
--   LOOTED:lootKey^player^link^lootType^lootGP
--   DISCARD:lootKey
--
-- Каналы: RAID (в рейде), PARTY (в группе), WHISPER (fallback)
-- ============================================================================

-- Определить канал для отправки
local function GetChannel(target)
  if not target or target == UnitName("player") then
    return nil  -- себе напрямую
  end
  if GetNumRaidMembers() > 0 then
    return "RAID"
  elseif GetNumPartyMembers() > 0 then
    return "PARTY"
  else
    return "WHISPER"
  end
end

-- Срезать префикс версии протокола с входящего сообщения.
-- Возвращает: payload без префикса, или nil при несовпадении версии.
local function StripProtocolVersion(message)
  if not message then return nil end
  -- Expected format: V<n>^<rest>
  local _, _, vStr, rest = string.find(message, "^V(%d+)%^(.*)$")
  if not vStr then
    -- No version prefix — old client. Reject (drop silently, warn once).
    return nil
  end
  local v = tonumber(vStr)
  if v ~= PROTOCOL_VERSION then
    return nil, v  -- version mismatch: return nil + remote version
  end
  return rest
end

-- Отправить сообщение ML → клиент
-- Чанкинг: SendAddonMessage в 3.3.5a молча теряет сообщения > 255 байт.
-- DO_YOU_WANT содержит lootKey+link+texture (~200-280 байт) и регулярно выходит за лимит
-- для длинных русских названий предметов. Крупные сообщения автоматически разбиваются.
function LM:SendToClient(command, payload, target)
  -- Префикс версии протокола во всех сообщениях
  local msg = command .. ":" .. PROTOCOL_PREFIX .. (payload or "")
  -- Разделить self-delivery (target==player) и broadcast (target=nil).
  if target == UnitName("player") then
    -- Себе напрямую — без SendAddonMessage
    LM:OnClientMessageReceived(PREFIX_ML_TO_CLIENT, msg, nil, UnitName("player"))
    return
  end
  -- Определяем канал: для broadcast (target=nil) или адресной WHISPER
  local channel
  if target == nil then
    if GetNumRaidMembers() > 0 then
      channel = "RAID"
    elseif GetNumPartyMembers() > 0 then
      channel = "PARTY"
    else
      LM:OnClientMessageReceived(PREFIX_ML_TO_CLIENT, msg, nil, UnitName("player"))
      return
    end
  else
    channel = GetChannel(target)
    if not channel then return end
  end
  -- Чанкинг + маршрутизация через ChatThrottleLib
  -- DO_YOU_WANT и LOOTED — ALERT (важные), остальные — NORMAL
  local prio = (command == "DO_YOU_WANT" or command == "LOOTED") and "ALERT" or "NORMAL"
  LM:TransmitChunked(PREFIX_ML_TO_CLIENT, msg, channel, target, prio)
end

-- Отправить сообщение клиент → ML
function LM:SendToML(command, payload)
  local target = LM.state.mlName
  if not target then return end
  -- Префикс версии протокола во всех сообщениях
  local msg = command .. ":" .. PROTOCOL_PREFIX .. (payload or "")
  if target == UnitName("player") then
    -- Себе напрямую
    LM:OnMLMessageReceived(PREFIX_CLIENT_TO_ML, msg, nil, UnitName("player"))
    return
  end
  local channel = GetChannel(target)
  if not channel then return end
  -- Чанкинг + маршрутизация через ChatThrottleLib
  -- WANT — ALERT (ответ кандидата, важен для ML), GEAR — NORMAL
  local prio = (command == "WANT") and "ALERT" or "NORMAL"
  LM:TransmitChunked(PREFIX_CLIENT_TO_ML, msg, channel, target, prio)
end

-- ============================================================================
-- ЧАНКИНГ АДДОН-СООБЩЕНИЙ (лимит SendAddonMessage — 255 байт)
-- ============================================================================
-- Сообщения ≤ CHUNK_MAX_DATA байт уходят как есть (обратная совместимость).
-- Крупные — разбиваются на CH-части:
--   CHUNK:V2^<transferId>^<index>^<total>^<partData>
-- Получатель собирает части и обрабатывает собранное сообщение как обычное.
-- Несобранные буферы живут 15 сек и чистятся лениво.
-- ============================================================================
local CHUNK_MAX_DATA = 190          -- байты данных на часть (лимит 255 минус overhead)
local CHUNK_EXPIRY = 15             -- сек до выброса несобранного буфера
local chunk_seq = 0
LM._chunk_buffers = {}

local function ChunkSendRaw(prefix, msg, channel, target, prio)
  local CTL = _G.ChatThrottleLib
  if CTL then
    if channel == "WHISPER" and target then
      CTL:SendAddonMessage(prio, prefix, msg, "WHISPER", target)
    else
      CTL:SendAddonMessage(prio, prefix, msg, channel)
    end
  else
    if channel == "WHISPER" and target then
      SendAddonMessage(prefix, msg, "WHISPER", target)
    else
      SendAddonMessage(prefix, msg, channel)
    end
  end
end

-- Построение чанк-строк — локальная функция BuildChunkMessages
-- (LM:TestChunk прогоняет build→reassemble без сети).
-- Формат ОДНОЙ части — РОВНО 4 поля после префикса версии (см. выше):
--   CHUNK:V2^<transferId>^<index>^<total>^<partData>
local function BuildChunkMessages(msg)
  chunk_seq = (chunk_seq + 1) % 100000
  local transferId = tostring(time()) .. "-" .. chunk_seq
  local total = math.ceil(#msg / CHUNK_MAX_DATA)
  local messages = {}
  for i = 1, total do
    local part = msg:sub((i - 1) * CHUNK_MAX_DATA + 1, i * CHUNK_MAX_DATA)
    messages[i] = string.format("CHUNK:%s^%d^%d^%s", transferId, i, total, part)
  end
  return messages
end

-- Разбить и отправить (или отправить как есть, если помещается).
function LM:TransmitChunked(prefix, msg, channel, target, prio)
  if #msg <= CHUNK_MAX_DATA then
    ChunkSendRaw(prefix, msg, channel, target, prio)
    return
  end
  local messages = BuildChunkMessages(msg)
  local total = #messages
  if Addon and Addon.Log and Addon.Log.Debug then
    Addon.Log:Debug("[LootMaster] Chunked send: %d bytes -> %d parts (prefix=%s)", #msg, total, tostring(prefix))
  end
  for i = 1, total do
    -- Каждая часть гарантированно < 255 байт
    ChunkSendRaw(prefix, messages[i], channel, target, prio)
  end
end

-- Попытка обработать входящее сообщение как CH-часть.
-- Возвращает true если сообщение было частью (обработано/отложено).
-- При сборке полного сообщения — рекурсивно вызывает соответствующий handler.
function LM:HandleChunkMessage(prefix, message, distribution, sender)
  if not message or not message:find("^CHUNK:") then return false end
  -- CHUNK:V2^<transferId>^<index>^<total>^<part>
  local _, _, rawPayload = string.find(message, "^CHUNK:(.*)$")
  if not rawPayload then return true end
  -- Пропускаем протокольный префикс V2^
  local verStr, rest = rawPayload:match("^V(%d+)%^(.*)$")
  if not verStr then return true end
  if tonumber(verStr) ~= PROTOCOL_VERSION then return true end
  local transferId, indexStr, totalStr, part = rest:match("^([^%^]+)%^([^%^]+)%^([^%^]+)%^(.*)$")
  if not transferId then return true end
  local index = tonumber(indexStr) or 0
  local total = tonumber(totalStr) or 0
  if index < 1 or total < 1 or index > total then return true end
  -- Ленивая чистка просроченных буферов
  local now = GetTime()
  for key, buf in pairs(LM._chunk_buffers) do
    if (now - buf.at) > CHUNK_EXPIRY then LM._chunk_buffers[key] = nil end
  end
  local key = tostring(sender) .. ":" .. transferId
  local buf = LM._chunk_buffers[key]
  if not buf then
    buf = { total = total, parts = {}, at = now }
    LM._chunk_buffers[key] = buf
  end
  buf.at = now
  buf.parts[index] = part
  -- Проверяем полноту
  local received = 0
  for i = 1, buf.total do
    if not buf.parts[i] then return true end
    received = received + 1
  end
  if received < buf.total then return true end
  -- Собрали — склеиваем и обрабатываем как обычное сообщение
  LM._chunk_buffers[key] = nil
  local reassembled = table.concat(buf.parts, "", 1, buf.total)
  if prefix == PREFIX_CLIENT_TO_ML then
    LM:OnMLMessageReceived(prefix, reassembled, distribution, sender)
  else
    LM:OnClientMessageReceived(prefix, reassembled, distribution, sender)
  end
  return true
end

-- Регрессионный тест чанкинга (/gg loot testchunk).
-- Строит сообщение > CHUNK_MAX_DATA байт с кириллицей (ruRU-сервер), прогоняет
-- его через BuildChunkMessages → HandleChunkMessage (без сети, sender = сам
-- игрок) и сверяет собранное сообщение с исходным ПОБАЙТОВО. Ловушка временно
-- подменяет LM.OnClientMessageReceived; оригинал восстанавливается даже при
-- ошибке (pcall). Сообщает OK/FAIL в чат по образцу других LM-тестов.
function LM:TestChunk()
  Addon.Print("=== LootMaster Chunk Test ===")
  local msg = "DO_YOU_WANT:" .. PROTOCOL_PREFIX .. string.rep("ПроверкаЧанкинга", 25)
  local chunks = BuildChunkMessages(msg)
  Addon.Print(string.format("  msg: %d байт -> %d чанков", #msg, #chunks))

  local received_msg = nil
  local received_count = 0
  local orig_handler = LM.OnClientMessageReceived
  LM.OnClientMessageReceived = function(self, prefix, message, distribution, sender)
    received_count = received_count + 1
    received_msg = message
  end

  local ok, err = pcall(function()
    for _, chunk in ipairs(chunks) do
      LM:HandleChunkMessage(PREFIX_ML_TO_CLIENT, chunk, "WHISPER", UnitName("player"))
    end
  end)

  -- Восстанавливаем оригинал в ЛЮБОМ случае (даже через pcall-ошибку)
  LM.OnClientMessageReceived = orig_handler

  if not ok then
    Addon.PrintError("  FAIL: ошибка при сборке чанков: " .. tostring(err))
    return
  end
  if received_count ~= 1 then
    Addon.PrintError(string.format("  FAIL: ловушка получила %d сообщений (ожидалось ровно 1)", received_count))
    return
  end
  if received_msg ~= msg then
    Addon.PrintError(string.format("  FAIL: сообщение искажено (получено %d байт, отправлено %d байт)",
      #tostring(received_msg), #msg))
    if received_msg then
      Addon.Print("  head(40): " .. received_msg:sub(1, 40))
    end
    return
  end
  Addon.Print(string.format("  OK: сообщение собрано byte-in-byte (%d байт, %d чанков)", #msg, #chunks))
end

-- ============================================================================
-- ОБРАБОТКА ВХОДЯЩИХ СООБЩЕНИЙ
-- ============================================================================

-- Разбор payload по разделителю ^
local function ParsePayload(payload)
  if not payload then return {} end
  local parts = LM._popTable()  -- table pool
  for part in string.gmatch(payload, "([^%^]+)") do
    tinsert(parts, part)
  end
  return parts
end

-- Вернуть таблицу parts в пул (вызывать после использования)
function LM:ReleaseParts(t)
  LM._pushTable(t)
end

-- ML получает сообщение от клиента (WANT, GEAR)
function LM:OnMLMessageReceived(prefix, message, distribution, sender)
  if prefix ~= PREFIX_CLIENT_TO_ML then return end
  -- ВАЖНО: сборка чанков на ВХОДЕ handler'а (до парсинга команды) —
  -- сообщения > 255 байт приходят частями
  if LM:HandleChunkMessage(prefix, message, distribution, sender) then return end
  if not LM.state.isML then return end

  -- Разбор: COMMAND:payload
  local _, _, command, rawPayload = string.find(message, "^([%a_]-):(.*)$")
  if not command then return end

  -- Срезать префикс версии протокола с payload
  local payload, remoteVer = StripProtocolVersion(rawPayload)
  if payload == nil then
    -- Несовпадение версии (или старый клиент без префикса) — предупреждение один раз на отправителя.
    if sender and not warned_version_mismatch[sender] then
      warned_version_mismatch[sender] = true
      if Addon and Addon.Log then
        if remoteVer then
          Addon.Log:Warn("[LootMaster] %s использует протокол v%s (у нас v%d). Сообщения игнорируются. Обновите аддон.",
            tostring(sender), tostring(remoteVer), PROTOCOL_VERSION)
        else
          Addon.Log:Warn("[LootMaster] %s использует старый протокол без версии. Сообщения игнорируются.",
            tostring(sender))
        end
      end
    end
    return
  end

  -- Верификация отправителя: WANT/GEAR должны приходить от зарегистрированного
  -- кандидата — это проверяется в HandleWANT/HandleGEAR через
  -- loot.candidates[sender], поэтому дополнительной проверки здесь нет.

  if command == "WANT" then
    -- WANT:lootKey^response^note
    local parts = ParsePayload(payload)
    local lootKey = parts[1]
    local response = tonumber(parts[2]) or 0
    local note = parts[3] or ""
    -- Проверка на текущую сессию: старые WANT от прошлой
    -- ML-сессии игнорируются (lootKey не найдётся в lootTable).
    if lootKey and not LM:IsCurrentSession(lootKey) then
      if Addon and Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] WANT ignored: stale session lootKey=%s", tostring(lootKey))
      end
      LM:ReleaseParts(parts)
      return
    end
    -- Anti-replay: один кандидат может слать WANT многократно (меняет мнение),
    -- поэтому WANT НЕ дедуплицируется. Дедупликация происходит через lootKey lookup
    -- — если loot не найден (старая сессия), сообщение просто игнорируется.
    LM:HandleWANT(lootKey, sender, response, note)
    LM:ReleaseParts(parts)
  elseif command == "GEAR" then
    -- GEAR:lootKey^itemID1^gp1^ilvl1^itemID2^gp2^ilvl2
    local parts = ParsePayload(payload)
    local lootKey = parts[1]
    -- Проверка на текущую сессию
    if lootKey and not LM:IsCurrentSession(lootKey) then
      if Addon and Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] GEAR ignored: stale session lootKey=%s", tostring(lootKey))
      end
      LM:ReleaseParts(parts)
      return
    end
    local gear = {
      item1 = tonumber(parts[2]) or 0,
      gp1 = tonumber(parts[3]) or 0,
      ilvl1 = tonumber(parts[4]) or 0,
    }
    LM:HandleGEAR(lootKey, sender, gear)
    LM:ReleaseParts(parts)
  end
end

-- Клиент получает сообщение от ML (DO_YOU_WANT, LOOTED, DISCARD)
function LM:OnClientMessageReceived(prefix, message, distribution, sender)
  if prefix ~= PREFIX_ML_TO_CLIENT then return end
  -- ВАЖНО: сборка чанков на ВХОДЕ handler'а (до парсинга команды) —
  -- сообщения > 255 байт приходят частями
  if LM:HandleChunkMessage(prefix, message, distribution, sender) then return end

  -- Разбор: COMMAND:payload
  local _, _, command, rawPayload = string.find(message, "^([%a_]-):(.*)$")
  if not command then return end

  -- Срезать префикс версии протокола
  local payload, remoteVer = StripProtocolVersion(rawPayload)
  if payload == nil then
    if sender and not warned_version_mismatch[sender] then
      warned_version_mismatch[sender] = true
      if Addon and Addon.Log then
        if remoteVer then
          Addon.Log:Warn("[LootMaster] ML %s использует протокол v%s (у нас v%d). Обновите аддон.",
            tostring(sender), tostring(remoteVer), PROTOCOL_VERSION)
        else
          Addon.Log:Warn("[LootMaster] ML %s использует старый протокол без версии.",
            tostring(sender))
        end
      end
    end
    return
  end

  -- Верификация отправителя против текущего ML.
  -- Self-delivery пропускается (sender == UnitName("player") — ML это мы).
  -- Остальные DO_YOU_WANT/LOOTED/DISCARD/ML_VIEW от не-ML отклоняются —
  -- защита от подмены: не-ML участник рейда не может инжектить фейковые
  -- попапы лута или принудительно закрывать окна кандидатов.
  local myName = UnitName("player")
  if sender ~= myName then
    if LM.state.mlName and sender ~= LM.state.mlName then
      -- Подделка или устаревший ML — молча отклоняем (только debug-лог).
      if Addon and Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] Ignored %s from non-ML sender %s (ML=%s)",
          tostring(command), tostring(sender), tostring(LM.state.mlName))
      end
      return
    end
  end

  if command == "DO_YOU_WANT" then
    -- DO_YOU_WANT:lootKey^itemID^gpValue^ilvl^quality^equipLoc^timeout^link^texture
    local parts = ParsePayload(payload)
    local loot = {
      lootKey  = parts[1],
      itemID   = parts[2],
      gpValue  = tonumber(parts[3]) or 0,
      ilevel   = tonumber(parts[4]) or 0,
      quality  = tonumber(parts[5]) or 0,
      equipLoc = parts[6] or "",
      timeout  = tonumber(parts[7]) or DEFAULT_TIMEOUT,
      link     = parts[8] or "",
      texture  = parts[9] or "",
      mlName   = sender,
    }
    LM:HandleDoYouWant(loot)
    LM:ReleaseParts(parts)

  elseif command == "LOOTED" then
    -- LOOTED:lootKey^player^link^lootType^lootGP
    local parts = ParsePayload(payload)
    local lootKey  = parts[1]
    local player   = parts[2]
    local link     = parts[3]
    local lootType = tonumber(parts[4]) or 0
    local lootGP   = tonumber(parts[5]) or 0
    -- Проверка на текущую сессию. Старый LOOTED от прошлой
    -- ML-сессии не должен закрывать новые popup.
    if lootKey and not LM:IsCurrentSession(lootKey) then
      if Addon and Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] LOOTED ignored: stale session lootKey=%s", tostring(lootKey))
      end
      LM:ReleaseParts(parts)
      return
    end
    LM:HandleLooted(lootKey, player, link, lootType, lootGP)
    LM:ReleaseParts(parts)

  elseif command == "DISCARD" then
    -- DISCARD:lootKey
    local lootKey = payload
    -- Проверка на текущую сессию
    if lootKey and not LM:IsCurrentSession(lootKey) then
      if Addon and Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] DISCARD ignored: stale session lootKey=%s", tostring(lootKey))
      end
      return
    end
    LM:HandleDiscard(lootKey)

  elseif command == "ML_VIEW" then
    -- ML_VIEW:itemID^itemName^texture^gpValue^ilevel^rarity^candidates
    local parts = ParsePayload(payload)
    local itemID   = parts[1]
    local itemName = parts[2]
    local texture  = parts[3]
    local gpValue  = tonumber(parts[4]) or 0
    local ilevel   = tonumber(parts[5]) or 0
    local rarity   = tonumber(parts[6]) or 0
    local candidatesStr = parts[7] or ""
    LM:HandleMLView(itemID, itemName, texture, gpValue, ilevel, rarity, candidatesStr, sender)
    LM:ReleaseParts(parts)
  end
end

-- ============================================================================
-- Обработчики реализованы в _Client.lua и _ML.lua (грузятся после этого файла)
-- ============================================================================

-- ============================================================================
-- РЕГИСТРАЦИЯ СОБЫТИЙ
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
-- Сброс предупреждений о несовпадении версии при входе/выходе из рейда —
-- обновившиеся игроки получат предупреждение снова, а не замолчат навсегда.
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
  -- Гильд-лок GoldGP: вне разрешённой гильдии LootMaster тоже не работает
  -- (голосования/попапы/синхронизация с ML отключены; Award-гейты в GoldGP режут GP).
  if Addon and Addon.IsEnabled and not Addon:IsEnabled() then return end
  if event == "CHAT_MSG_ADDON" then
    -- WoW 3.3.5a: prefix, message, channel, sender
    local prefix, message, channel, sender = ...
    if sender then
      -- Убираем сервер-суффикс
      sender = strsplit("-", sender) or sender
    end
    -- Маршрутизация
    if prefix == PREFIX_ML_TO_CLIENT then
      LM:OnClientMessageReceived(prefix, message, channel, sender)
    elseif prefix == PREFIX_CLIENT_TO_ML then
      LM:OnMLMessageReceived(prefix, message, channel, sender)
    end
  elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
    wipe(warned_version_mismatch)
  end
end)

-- ============================================================================
-- ФАЗА 2: GP-КАЛЬКУЛЯТОР
-- ============================================================================
--
-- Формула EPGP (из EPGP_LootMaster/Libs/epgp/epgp.lua:232-265):
--   gp_base = 0.483 * 2 ^ (ilvl / 26 + (rarity - 4))
--   gp_high = floor(gp_base * slot_multiplier)
--
-- ============================================================================
-- ФИКСИРОВАННЫЕ GP ПО ILVL (вместо формулы EPGP для ilvl 245 и 258)
-- Категории:
--   "2H"      — двуручное оружие (INVTYPE_2HWEAPON)
--   "1H"      — одноручное оружие/щит/дальнобойное/офф-хенд
--   "TRINKET" — тринкет (INVTYPE_TRINKET)
--   "OFFSET"  — оф-сет: пояс/кольцо/шея/ступни/наручи/плащ/реликвии/холдабл
--   "TIER"    — сет: голова/плечи/грудь/ноги/мантия
-- Для ilvl НЕ из этой таблицы — используется формула EPGP (fallback).
-- ============================================================================
local FIXED_GP_TABLE = {
  [245] = { ["2H"] = 400, ["1H"] = 200, ["TRINKET"] = 400, ["OFFSET"] = 200, ["TIER"] = 100 },
  [258] = { ["2H"] = 600, ["1H"] = 400, ["TRINKET"] = 600, ["OFFSET"] = 400, ["TIER"] = 300 },
}

-- Маппинг equipLoc -> категория для FIXED_GP_TABLE
local SLOT_TO_GP_CATEGORY = {
  ["INVTYPE_2HWEAPON"]       = "2H",
  ["INVTYPE_WEAPON"]         = "1H",
  ["INVTYPE_WEAPONMAINHAND"] = "1H",
  ["INVTYPE_WEAPONOFFHAND"]  = "1H",
  ["INVTYPE_SHIELD"]         = "1H",
  ["INVTYPE_RANGED"]         = "1H",
  ["INVTYPE_RANGEDRIGHT"]    = "1H",
  ["INVTYPE_THROWN"]         = "1H",
  ["INVTYPE_TRINKET"]        = "TRINKET",
  ["INVTYPE_NECK"]           = "OFFSET",
  ["INVTYPE_CLOAK"]          = "OFFSET",
  ["INVTYPE_WAIST"]          = "OFFSET",
  ["INVTYPE_WRIST"]          = "OFFSET",
  ["INVTYPE_HAND"]           = "OFFSET",
  ["INVTYPE_FINGER"]         = "OFFSET",
  ["INVTYPE_FEET"]           = "OFFSET",
  ["INVTYPE_RELIC"]          = "OFFSET",
  ["INVTYPE_HOLDABLE"]       = "OFFSET",
  ["INVTYPE_HEAD"]           = "TIER",
  ["INVTYPE_SHOULDER"]       = "TIER",
  ["INVTYPE_CHEST"]          = "TIER",
  ["INVTYPE_LEGS"]           = "TIER",
  ["INVTYPE_ROBE"]           = "TIER",
}

-- Найти ближайший ilvl-брекет (<=) в FIXED_GP_TABLE.
-- Возвращает GP для категории или nil если нет подходящего брекета.
local function GetFixedGP(ilvl, category)
  if not ilvl or not category then return nil end
  local best_ilvl = nil
  for bracket_ilvl in pairs(FIXED_GP_TABLE) do
    if bracket_ilvl <= ilvl then
      if not best_ilvl or bracket_ilvl > best_ilvl then
        best_ilvl = bracket_ilvl
      end
    end
  end
  if not best_ilvl then return nil end
  return FIXED_GP_TABLE[best_ilvl][category]
end

-- Множители слотов (из EPGP)
local EQUIPSLOT_MULTIPLIER_1 = {
  ["INVTYPE_HEAD"]           = 1.0,
  ["INVTYPE_NECK"]           = 0.5,
  ["INVTYPE_SHOULDER"]       = 0.75,
  ["INVTYPE_CHEST"]          = 1.0,
  ["INVTYPE_WAIST"]          = 0.75,
  ["INVTYPE_LEGS"]           = 1.0,
  ["INVTYPE_FEET"]           = 0.75,
  ["INVTYPE_WRIST"]          = 0.75,
  ["INVTYPE_HAND"]           = 0.75,
  ["INVTYPE_FINGER"]         = 0.5,
  ["INVTYPE_TRINKET"]        = 1.0,
  ["INVTYPE_CLOAK"]          = 0.5,
  ["INVTYPE_WEAPON"]         = 1.5,
  ["INVTYPE_SHIELD"]         = 1.5,
  ["INVTYPE_2HWEAPON"]       = 2.0,
  ["INVTYPE_WEAPONMAINHAND"] = 1.5,
  ["INVTYPE_WEAPONOFFHAND"]  = 0.5,
  ["INVTYPE_HOLDABLE"]       = 0.5,
  ["INVTYPE_RANGED"]         = 1.5,
  ["INVTYPE_RANGEDRIGHT"]    = 1.5,
  ["INVTYPE_THROWN"]         = 0.5,
  ["INVTYPE_RELIC"]          = 0.5,
  ["INVTYPE_ROBE"]           = 1.0,  -- Robe = Chest
}

-- Вторичные множители (для оффхенда / второго кольца)
local EQUIPSLOT_MULTIPLIER_2 = {
  ["INVTYPE_WEAPON"]         = 0.5,   -- оффхенд 1H
  ["INVTYPE_2HWEAPON"]       = 1.0,   -- 2H в оффхенде
  ["INVTYPE_WEAPONOFFHAND"]  = 0.5,
  ["INVTYPE_HOLDABLE"]       = 0.5,
  ["INVTYPE_FINGER"]         = 0.5,   -- второе кольцо
  ["INVTYPE_TRINKET"]        = 1.0,   -- второй тринкет
}

-- Хардкод tier-токенов и спецпредметов (rarity, level, equipLoc)
-- из EPGP_LootMaster/Libs/epgp/epgp.lua:44-207
local CUSTOM_ITEM_DATA = {
  -- T7 (WotLK, ilvl 213)
  [40610] = { 4, 213, "INVTYPE_CHEST" },  -- Chestguard of the Lost Vanquisher
  [40611] = { 4, 213, "INVTYPE_CHEST" },  -- Chestguard of the Lost Conqueror
  [40612] = { 4, 213, "INVTYPE_CHEST" },  -- Chestguard of the Lost Protector
  [40613] = { 4, 213, "INVTYPE_HEAD" },   -- Crown of the Lost Vanquisher
  [40614] = { 4, 213, "INVTYPE_HEAD" },   -- Crown of the Lost Conqueror
  [40615] = { 4, 213, "INVTYPE_HEAD" },   -- Crown of the Lost Protector
  [40616] = { 4, 213, "INVTYPE_HAND" },  -- Gauntlets of the Lost Vanquisher
  [40617] = { 4, 213, "INVTYPE_HAND" },  -- Gauntlets of the Lost Conqueror
  [40618] = { 4, 213, "INVTYPE_HAND" },  -- Gauntlets of the Lost Protector
  [40619] = { 4, 213, "INVTYPE_LEGS" },   -- Legplates of the Lost Vanquisher
  [40620] = { 4, 213, "INVTYPE_LEGS" },   -- Legplates of the Lost Conqueror
  [40621] = { 4, 213, "INVTYPE_LEGS" },   -- Legplates of the Lost Protector
  [40622] = { 4, 213, "INVTYPE_SHOULDER" }, -- Spaulders of the Lost Vanquisher
  [40623] = { 4, 213, "INVTYPE_SHOULDER" }, -- Spaulders of the Lost Conqueror
  [40624] = { 4, 213, "INVTYPE_SHOULDER" }, -- Spaulders of the Lost Protector

  -- T7.5 (Heroic, ilvl 226)
  [40625] = { 4, 226, "INVTYPE_CHEST" },
  [40626] = { 4, 226, "INVTYPE_CHEST" },
  [40627] = { 4, 226, "INVTYPE_CHEST" },
  [40628] = { 4, 226, "INVTYPE_HEAD" },
  [40629] = { 4, 226, "INVTYPE_HEAD" },
  [40630] = { 4, 226, "INVTYPE_HEAD" },
  [40631] = { 4, 226, "INVTYPE_HAND" },
  [40632] = { 4, 226, "INVTYPE_HAND" },
  [40633] = { 4, 226, "INVTYPE_HAND" },
  [40634] = { 4, 226, "INVTYPE_LEGS" },
  [40635] = { 4, 226, "INVTYPE_LEGS" },
  [40636] = { 4, 226, "INVTYPE_LEGS" },
  [40637] = { 4, 226, "INVTYPE_SHOULDER" },
  [40638] = { 4, 226, "INVTYPE_SHOULDER" },
  [40639] = { 4, 226, "INVTYPE_SHOULDER" },

  -- T8 (Ulduar, ilvl 219)
  [45635] = { 4, 219, "INVTYPE_CHEST" },
  [45636] = { 4, 219, "INVTYPE_CHEST" },
  [45637] = { 4, 219, "INVTYPE_CHEST" },
  [45638] = { 4, 219, "INVTYPE_HEAD" },
  [45639] = { 4, 219, "INVTYPE_HEAD" },
  [45640] = { 4, 219, "INVTYPE_HEAD" },
  [45641] = { 4, 219, "INVTYPE_HAND" },
  [45642] = { 4, 219, "INVTYPE_HAND" },
  [45643] = { 4, 219, "INVTYPE_HAND" },
  [45644] = { 4, 219, "INVTYPE_LEGS" },
  [45645] = { 4, 219, "INVTYPE_LEGS" },
  [45646] = { 4, 219, "INVTYPE_LEGS" },
  [45647] = { 4, 219, "INVTYPE_SHOULDER" },
  [45648] = { 4, 219, "INVTYPE_SHOULDER" },
  [45649] = { 4, 219, "INVTYPE_SHOULDER" },

  -- T8.5 (Heroic, ilvl 226)
  [45650] = { 4, 226, "INVTYPE_CHEST" },
  [45651] = { 4, 226, "INVTYPE_CHEST" },
  [45652] = { 4, 226, "INVTYPE_CHEST" },
  [45653] = { 4, 226, "INVTYPE_HEAD" },
  [45654] = { 4, 226, "INVTYPE_HEAD" },
  [45655] = { 4, 226, "INVTYPE_HEAD" },
  [45656] = { 4, 226, "INVTYPE_HAND" },
  [45657] = { 4, 226, "INVTYPE_HAND" },
  [45658] = { 4, 226, "INVTYPE_HAND" },
  [45659] = { 4, 226, "INVTYPE_LEGS" },
  [45660] = { 4, 226, "INVTYPE_LEGS" },
  [45661] = { 4, 226, "INVTYPE_LEGS" },
  [45662] = { 4, 226, "INVTYPE_SHOULDER" },
  [45663] = { 4, 226, "INVTYPE_SHOULDER" },
  [45664] = { 4, 226, "INVTYPE_SHOULDER" },

  -- T9 (Trial of the Crusader, ilvl 232)
  -- Vanquisher (Rogue, DK, Mage, Druid)
  [47545] = { 4, 232, "INVTYPE_CHEST" },
  [47546] = { 4, 232, "INVTYPE_HEAD" },
  [47547] = { 4, 232, "INVTYPE_HAND" },
  [47548] = { 4, 232, "INVTYPE_LEGS" },
  [47549] = { 4, 232, "INVTYPE_SHOULDER" },
  -- Conqueror (Paladin, Priest, Warlock)
  [47550] = { 4, 232, "INVTYPE_CHEST" },
  [47551] = { 4, 232, "INVTYPE_HEAD" },
  [47552] = { 4, 232, "INVTYPE_HAND" },
  [47553] = { 4, 232, "INVTYPE_LEGS" },
  [47554] = { 4, 232, "INVTYPE_SHOULDER" },
  -- Protector (Hunter, Shaman, Warrior)
  [47555] = { 4, 232, "INVTYPE_CHEST" },
  [47556] = { 4, 232, "INVTYPE_HEAD" },
  [47557] = { 4, 232, "INVTYPE_HAND" },
  [47558] = { 4, 232, "INVTYPE_LEGS" },
  [47559] = { 4, 232, "INVTYPE_SHOULDER" },

  -- T9.5 (Heroic, ilvl 245)
  [47560] = { 4, 245, "INVTYPE_CHEST" },
  [47561] = { 4, 245, "INVTYPE_HEAD" },
  [47562] = { 4, 245, "INVTYPE_HAND" },
  [47563] = { 4, 245, "INVTYPE_LEGS" },
  [47564] = { 4, 245, "INVTYPE_SHOULDER" },
  [47565] = { 4, 245, "INVTYPE_CHEST" },
  [47566] = { 4, 245, "INVTYPE_HEAD" },
  [47567] = { 4, 245, "INVTYPE_HAND" },
  [47568] = { 4, 245, "INVTYPE_LEGS" },
  [47569] = { 4, 245, "INVTYPE_SHOULDER" },
  [47570] = { 4, 245, "INVTYPE_CHEST" },
  [47571] = { 4, 245, "INVTYPE_HEAD" },
  [47572] = { 4, 245, "INVTYPE_HAND" },
  [47573] = { 4, 245, "INVTYPE_LEGS" },
  [47574] = { 4, 245, "INVTYPE_SHOULDER" },
}

-- Extract itemID from itemLink. Public (LM.GetItemIDFromLink) for reuse in Client.lua and ML.lua.
LM.GetItemIDFromLink = function(link)
  if not link then return nil end
  local _, _, itemID = string.find(link, "item:(%d+)")
  return tonumber(itemID)
end

-- Keep local alias for this file
local GetItemIDFromLink = LM.GetItemIDFromLink

-- Рассчитать GP для предмета.
-- Приоритет:
--   1. gp_overrides[itemID] из настроек пользователя (наивысший)
--   2. FIXED_GP_TABLE по ilvl + категория слота
--   3. Формула EPGP (fallback для ilvl вне таблицы или неизвестных слотов)
-- Возвращает: gp_high, gp_low, ilevel, rarity, equipLoc
-- gp_low = 50% от gp_high (для оффспека), nil если не применимо
function LM:CalcGP(itemLink)
  if not itemLink then return nil end

  local itemID = GetItemIDFromLink(itemLink)
  local rarity, level, equipLoc

  -- Данные о предмете: сначала хардкод тир-токенов, потом GetItemInfo
  if itemID and CUSTOM_ITEM_DATA[itemID] then
    local data = CUSTOM_ITEM_DATA[itemID]
    rarity   = data[1]
    level    = data[2]
    equipLoc = data[3]
  else
    local _, _, rar, lvl, eqLoc = LM:GetCachedItemInfo(itemLink)
    rarity   = rar
    level    = lvl
    equipLoc = eqLoc
  end

  if not rarity or not level then return nil, nil, nil, nil, nil end
  if rarity < 2 then return nil, nil, level, rarity, equipLoc end

  -- ШАГ 1: Пользовательское переопределение (наивысший приоритет)
  if itemID then
    local overrides = LM.db and LM.db.global and LM.db.global.gp_overrides
    if overrides and overrides[itemID] then
      local gp = overrides[itemID]
      local gp_low = math.floor(gp * 0.5)
      return gp, gp_low, level, rarity, equipLoc
    end
  end

  -- ШАГ 2: Фиксированная таблица по ilvl + категория слота
  local category = SLOT_TO_GP_CATEGORY[equipLoc]
  if category then
    local fixed_gp = GetFixedGP(level, category)
    if fixed_gp then
      local gp_low = math.floor(fixed_gp * 0.5)
      return fixed_gp, gp_low, level, rarity, equipLoc
    end
  end

  -- ШАГ 3: Fallback — формула EPGP
  local mult1 = EQUIPSLOT_MULTIPLIER_1[equipLoc]
  if not mult1 then return nil, nil, level, rarity, equipLoc end

  local gp_base = 0.483 * (2 ^ (level / 26 + (rarity - 4)))
  local gp_high = math.floor(gp_base * mult1)
  local gp_low  = nil
  local mult2   = EQUIPSLOT_MULTIPLIER_2[equipLoc]
  if mult2 then
    gp_low = math.floor(gp_base * mult2)
  end

  return gp_high, gp_low, level, rarity, equipLoc
end

-- Удобная обёртка — возвращает только основную GP цену (число или nil)
function LM:GetGPValue(itemLink)
  local gp = LM:CalcGP(itemLink)
  return gp  -- gp_high или nil
end

-- ============================================================================
-- ТЕСТОВЫЕ / ОТЛАДОЧНЫЕ ФУНКЦИИ
-- ============================================================================

-- Тест GP-калькулятора (для отладки через /run GoldGPLootMaster:TestGP())
function LM:TestGP()
  local testItems = {
    "|cffa335ee|Hitem:40354:0:0:0:0:0:0:0:80|h[Grim Toll]|h|r",           -- Trinket, ilvl 213
    "|cffa335ee|Hitem:40465:0:0:0:0:0:0:0:80|h[Deathshead Stompers]|h|r", -- Feet, ilvl 226
    "|cffa335ee|Hitem:40343:0:0:0:0:0:0:0:80|h[Armageddon]|h|r",          -- 2H Weapon, ilvl 213
    "|cffa335ee|Hitem:40610:0:0:0:0:0:0:0:80|h[Chestguard of the Lost Vanquisher]|h|r", -- T7 token
  }
  Addon.Print("=== GP Calculator Test ===")
  -- Показать переопределения если есть
  local ov = LM.db and LM.db.global and LM.db.global.gp_overrides
  if ov then
    local count = 0
    for _ in pairs(ov) do count = count + 1 end
    Addon.Print(string.format("  User overrides: %d items", count))
  end
  for _, link in ipairs(testItems) do
    local gp, gp2, ilvl, rarity, equipLoc = LM:CalcGP(link)
    -- Через кэш
    local name = LM:GetCachedItemInfo(link)
    if name then
      Addon.Print(string.format("  %s: GP=%s (low=%s) ilvl=%d rarity=%d slot=%s",
        name, tostring(gp), tostring(gp2), ilvl or 0, rarity or 0, tostring(equipLoc)))
    else
      Addon.Print(string.format("  [item not cached] link=%s GP=%s", tostring(link), tostring(gp)))
    end
  end
end

-- Тест коммуникации (для отладки через /run GoldGPLootMaster:TestComm())
function LM:TestComm()
  Addon.Print("=== LootMaster Comm Test ===")
  -- Тест: отправить себе DO_YOU_WANT
  local testPayload = "12345^150^213^4^INVTYPE_HEAD^60^[testlink]^testtexture"
  LM:SendToClient("DO_YOU_WANT", testPayload, UnitName("player"))
  Addon.Print("  DO_YOU_WANT sent to self (should appear in debug log)")

  -- Тест: отправить себе WANT
  local wantPayload = "12345^1^testnote"
  LM.state.mlName = UnitName("player")
  LM.state.isML = true
  LM:SendToML("WANT", wantPayload)
  Addon.Print("  WANT sent to self (should appear in debug log)")

  -- Тест: отправить себе GEAR
  local gearPayload = "12345^[item1]^50^200^^0^0"
  LM:SendToML("GEAR", gearPayload)
  Addon.Print("  GEAR sent to self (should appear in debug log)")
end

-- ============================================================================
-- БЕЗОПАСНЫЙ ТЕСТ БЕЗ РЕЙДА
-- ============================================================================
-- Команды:
--   /gg loot testfull       — полный сценарий (ML добавляет, кандидат видит
--                             окно, авто-нажатие Мейн спек, проверка что
--                             повторный DO_YOU_WANT НЕ создаёт второе окно).
--   /gg loot testreset      — полная очистка тестового состояния (окна, списки,
--                             флаги) и выключение testMode.
--   /gg loot teststatus     — отчёт о текущем состоянии (testMode, кол-во
--                             активных lootTable/clientLootList записей,
--                             sessionId, lootSeq).
--   /gg loot testduplicates — два одинаковых itemID с разными lootKey должны
--                             дать два НЕзависимых окна кандидата; DISCARD
--                             первого НЕ закрывает второе.
--
-- testMode (LM.testMode = true) запрещает:
--   - GiveMasterLoot (выдача реального лута);
--   - Addon.Award:IncGP (изменение GP/officer notes);
--   - реальные RAID/PARTY broadcast (self-delivery остаётся);
--   - PersistLootTable (не засоряем SavedVariables тестовыми записями).
--
-- Состояние сохраняется перед тестом и восстанавливается при testreset
-- (даже если тест упал с ошибкой — pcall/finally).
-- ============================================================================

-- Снимок состояния для восстановления после теста.
local testSnapshot = nil

-- Активные тестовые OnUpdate timers, чтобы finish_test мог их остановить.
local activeTestTimers = {}

local function capture_test_snapshot()
  return {
    isML = LM.state.isML,
    mlName = LM.state.mlName,
    sessionId = LM.state.sessionId,
    lootSeq = LM.state.lootSeq,
    lootTable = LM.state.lootTable,
    clientLootList = LM.state.clientLootList,
    pendingAwards = LM.state.pendingAwards,
    recoveryQueue = LM.state.recoveryQueue,
    trackingEnabled = LM.trackingEnabled,
  }
end

local function restore_test_snapshot(snap)
  if not snap then return end
  LM.state.isML = snap.isML
  LM.state.mlName = snap.mlName
  LM.state.sessionId = snap.sessionId
  LM.state.lootSeq = snap.lootSeq
  LM.state.lootTable = snap.lootTable or {}
  LM.state.clientLootList = snap.clientLootList or {}
  LM.state.pendingAwards = snap.pendingAwards or {}
  LM.state.recoveryQueue = snap.recoveryQueue or {}
  LM.trackingEnabled = snap.trackingEnabled
end

-- finish_test — единая функция завершения теста.
-- ВСЕГДА (даже при ошибке в delayed callback):
--   - останавливает тестовые OnUpdate timers;
--   - скрывает тестовые popup и ML-окно;
--   - восстанавливает snapshot;
--   - устанавливает LM.testMode = false;
--   - удаляет тестовые loot-записи (через snapshot restore);
--   - восстанавливает pendingAwards, recoveryQueue, session state.
-- Все delayed callbacks (OnUpdate в TestFull, TestDuplicates) ДОЛЖНЫ вызывать
-- эту функцию как при успехе, так и при ошибке.
local function finish_test(success, errorText)
  -- Останавливаем все активные тестовые timers
  for _, t in ipairs(activeTestTimers) do
    if t and t.Hide then t:Hide() end
  end
  wipe(activeTestTimers)
  -- Скрываем ML-окно если открыто
  if LM.mlFrame and LM.mlFrame:IsShown() then
    LM.mlFrame:Hide()
  end
  -- Полная очистка клиентского UI
  if LM.ResetClientLootState then
    LM:ResetClientLootState("finish_test")
  end
  -- Восстанавливаем snapshot (если был)
  if testSnapshot then
    restore_test_snapshot(testSnapshot)
    testSnapshot = nil
  end
  -- Сбрасываем флаги тест-режима
  LM.testMode = false
  LM._flush_in_progress = nil  -- defensive
  -- Очищаем LM.testAwards
  LM.testAwards = {}
  -- Скрываем gpPendingFrame (если был активирован тестом)
  if LM.mlTimeoutFrame then LM.mlTimeoutFrame:Hide() end
  -- Отчёт
  if success then
    Addon.Print("=== Тест завершён: OK ===")
  else
    Addon.PrintError("[Test] FAIL: " .. tostring(errorText or "unknown"))
    Addon.Print("[Test] Состояние восстановлено через finish_test")
  end
end

-- TestFull — полный mock-цикл с авто-восстановлением.
-- 12 шагов:
--   1. Snapshot состояния.
--   2. Включить testMode.
--   3. Создать виртуальный lootKey.
--   4. Трижды обработать DO_YOU_WANT и проверить одно окно.
--   5. Отправить WANT и проверить ответ ML.
--   6. Выполнить mock GiveLootToCandidate() без реального GiveMasterLoot().
--   7. Установить mock lootGiven, lootType, lootGP и pending queue.
--   8. Передать fake CHAT_MSG_LOOT.
--   9. Проверить правильный lootKey, закрытие popup и удаление записи.
--  10. Проверить gpProcessed и отсутствие изменения Gold/GP.
--  11. Передать повторный fake CHAT_MSG_LOOT и проверить no-op.
--  12. Автоматически восстановить состояние через finish_test.
function LM:TestFull()
  Addon.Print("=== LootMaster Full Test v2.5.9 (mock award + LOOTED) ===")

  -- 1. Snapshot состояния ДО теста
  testSnapshot = capture_test_snapshot()

  -- Обёртка для guaranteeed восстановления через finish_test
  local ok, err = pcall(function()
    -- 2. Включаем testMode и сбрасываем тестовое состояние
    LM.testMode = true
    LM.state.lootTable = {}
    LM.state.recoveryQueue = {}
    LM.state.pendingAwards = {}
    if LM.ResetClientLootState then
      LM:ResetClientLootState("testfull_start")
    end
    -- Инициализируем testAwards для проверок GP сумм
    LM.testAwards = {}
    -- Генерируем тестовый sessionId чтобы lootKey был уникальным
    LM.state.sessionId = "test_" .. tostring(time()) .. "_" .. tostring(GetTime())
    LM.state.lootSeq = 0

    -- Мы ML
    LM.state.isML = true
    LM.state.mlName = UnitName("player")
    LM.trackingEnabled = true

    -- 3. Создаём виртуальный lootKey
    -- 40354 = Grim Toll (ilvl 213, trinket, epic)
    local testLink = "|cffa335ee|Hitem:40354:0:0:0:0:0:0:0:80|h[Grim Toll]|h|r"
    local testName = "Grim Toll"
    local testTexture = "Interface\\Icons\\INV_Jewelry_Talisman_07"
    local testRarity = 4
    local testSlotID = 1

    Addon.Print("[1/12] Snapshot taken + testMode ON + virtual loot created")

    local gpValue = LM:GetGPValue(testLink) or 150
    local _, _, itemID = string.find(testLink, "item:(%d+)")
    local lootKey = LM.state.sessionId .. ":" .. tostring(itemID or "40354") .. ":" .. tostring(testSlotID)

    local loot = {
      key = lootKey,
      link = testLink,
      name = testName,
      itemID = itemID or "40354",
      texture = testTexture,
      rarity = testRarity,
      ilevel = 213,
      equipLoc = "INVTYPE_TRINKET",
      gpValue = gpValue,
      quantity = 1,
      slotID = testSlotID,
      mayDistribute = false,  -- testMode: никогда не выдаем реальный лут
      candidates = {},
      candidateOrder = {},
      announcedAt = time(),
      timeout = 60,
    }
    LM.state.lootTable[lootKey] = loot

    -- Добавляем себя как единственного кандидата
    local myName = UnitName("player")
    local _, myClass = UnitClass("player")
    local gold, gp = Addon:GetMemberData(myName)
    loot.candidates[myName] = {
      response = LM.RESPONSE.WAIT,
      note = "",
      class = myClass or "WARRIOR",
      candidateID = 1,
      gold = gold or 0,
      gp = gp or 0,
      pr = (gp and gp > 0) and (gold / gp) or 0,
      currentitem = "",
      currentilvl = 0,
      currentgp = 0,
      lootType = nil,
      lootGP = 0,
    }
    tinsert(loot.candidateOrder, myName)

    -- Показываем окно ML
    LM:ShowMLWindow(loot)

    -- 4. Трижды отправляем DO_YOU_WANT и проверяем одно окно
    Addon.Print("[4/12] 3× DO_YOU_WANT sent to self → ожидаем ровно 1 popup (dedup)")
    local payload = string.format("%s^%s^%d^%d^%d^%s^%d^%s^%s",
      loot.key, loot.itemID, loot.gpValue, loot.ilevel, loot.rarity,
      loot.equipLoc, 60, loot.link, loot.texture)
    LM:SendToClient("DO_YOU_WANT", payload, myName)
    LM:SendToClient("DO_YOU_WANT", payload, myName)
    LM:SendToClient("DO_YOU_WANT", payload, myName)
    local vis1 = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis1 = vis1 + 1 end
    end
    if vis1 == 1 then
      Addon.Print("  OK: ровно 1 окно (vis=" .. vis1 .. ")")
    else
      error(string.format("Dedup сломан: vis=%d, ожидалось 1", vis1))
    end

    -- 5. Отправляем WANT и проверяем ответ ML (через 2 сек)
    Addon.Print("[5/12] Авто-WANT 'Мейн спек' через 2 сек...")
    local autoTimer = CreateFrame("Frame")
    tinsert(activeTestTimers, autoTimer)
    autoTimer.testLootKey = lootKey
    autoTimer.testGoldBefore = gold or 0
    autoTimer.testGPBefore = gp or 0
    autoTimer.testLink = testLink
    autoTimer.testItemID = itemID or "40354"
    autoTimer.testLoot = loot
    local waitTime = 2
    autoTimer:SetScript("OnUpdate", function(self, elapsed)
      waitTime = waitTime - elapsed
      if waitTime <= 0 then
        self:Hide()
        -- Delayed body обёрнут в pcall — finish_test вызывается в обоих случаях
        local ok2, err2 = pcall(function()
          -- 5. Отправить WANT
          local cl = LM:FindClientLootByKey(self.testLootKey)
          if cl then
            LM:SendItemWanted(cl, LM.RESPONSE.NEED)
            Addon.Print("  [5/12] OK: WANT sent (lootKey found)")
          else
            error("clientLootList не содержит lootKey=" .. tostring(self.testLootKey))
          end

          -- Проверка закрытия popup
          local stillVisible = 0
          for _, lf in ipairs(LM._lootFrames or {}) do
            if lf:IsShown() then stillVisible = stillVisible + 1 end
          end
          if stillVisible == 0 then
            Addon.Print("  [5/12] OK: popup closed after WANT")
          else
            Addon.PrintError(string.format("  [5/12] FAIL: %d popups still visible", stillVisible))
          end

          -- Проверка ML-table response
          local ml_loot = LM:FindLootByKey(self.testLootKey)
          if ml_loot and ml_loot.candidates[myName] and
             ml_loot.candidates[myName].response == LM.RESPONSE.NEED then
            Addon.Print("  [5/12] OK: ML sees 'Мейн спек' response")
          else
            error("ML не видит ответ в таблице")
          end

          -- 6. Mock GiveLootToCandidate() — testMode guard устанавливает те же поля
          -- что и реальный путь (lootGiven/giveTime/lootType/lootGP), но не вызывает GiveMasterLoot.
          Addon.Print("[6/12] Mock GiveLootToCandidate (testMode — no GiveMasterLoot)")
          LM:GiveLootToCandidate(self.testLoot, myName, LM.LOOTTYPE.GP, self.testLoot.gpValue or 150)

          -- 7. Проверяем что mock установил lootGiven/lootType/lootGP и pendingAwards queue
          local cand = ml_loot.candidates[myName]
          if cand.lootGiven ~= true then
            error("mock GiveLoot не установил lootGiven=true")
          end
          if cand.lootType ~= LM.LOOTTYPE.GP then
            error("mock GiveLoot не установил lootType=GP")
          end
          if not cand.giveTime then
            error("mock GiveLoot не установил giveTime")
          end
          -- Проверяем очередь через PeekPendingAward (централизованный API).
          -- Используем string itemID здесь, чтобы проверить совместимость типов с number itemID
          -- в GiveLootToCandidate (loot.itemID в тесте это string из itemLink parsing).
          local peekKey = LM:PeekPendingAward(self.testItemID, myName)
          if peekKey ~= self.testLootKey then
            error("pendingAwards queue не содержит lootKey после mock GiveLoot (peek=" ..
              tostring(peekKey) .. ", expected=" .. tostring(self.testLootKey) .. ")")
          end
          Addon.Print("  [7/12] OK: lootGiven/lootType/lootGP/pendingAwards установлены")

          -- 8. Передать fake CHAT_MSG_LOOT
          Addon.Print("[8/12] Fake CHAT_MSG_LOOT (OnChatMsgLoot directly)")
          local fakeMsg = myName .. " получает лут: " .. self.testLink
          LM:OnChatMsgLoot(fakeMsg)

          -- 9. Проверяем закрытие popup и удаление записи из pendingAwards
          local vis2 = 0
          for _, lf in ipairs(LM._lootFrames or {}) do
            if lf:IsShown() then vis2 = vis2 + 1 end
          end
          if vis2 == 0 then
            Addon.Print("  [9/12] OK: popup closed after LOOTED")
          else
            Addon.PrintError(string.format("  [9/12] FAIL: %d popups still visible", vis2))
          end
          -- Проверяем что очередь пуста через PeekPendingAward
          local peekKey2 = LM:PeekPendingAward(self.testItemID, myName)
          if peekKey2 then
            Addon.PrintError(string.format("  [9/12] FAIL: pendingAwards queue still has lootKey=%s, expected empty",
              tostring(peekKey2)))
          else
            Addon.Print("  [9/12] OK: pendingAwards queue drained")
          end

          -- 10. Проверяем gpProcessed и отсутствие изменения Gold/GP
          if cand.gpProcessed ~= true then
            Addon.PrintError("  [10/12] FAIL: gpProcessed not set after LOOTED")
          else
            Addon.Print("  [10/12] OK: gpProcessed=true (testMode guard)")
          end
          local goldAfter, gpAfter = Addon:GetMemberData(myName)
          if (goldAfter or 0) == (self.testGoldBefore or 0) and (gpAfter or 0) == (self.testGPBefore or 0) then
            Addon.Print("  [10/12] OK: Gold/GP не изменились")
          else
            Addon.PrintError(string.format("  [10/12] FAIL: Gold %d->%d, GP %d->%d",
              self.testGoldBefore or 0, goldAfter or 0, self.testGPBefore or 0, gpAfter or 0))
          end

          -- 11. Повторный fake CHAT_MSG_LOOT — должен быть no-op
          Addon.Print("[11/12] Повторный fake CHAT_MSG_LOOT (должен быть no-op)")
          local ok3, err3 = pcall(function()
            LM:OnChatMsgLoot(fakeMsg)
          end)
          if ok3 then
            Addon.Print("  [11/12] OK: повторный CHAT_MSG_LOOT не вызвал ошибку")
          else
            error("Повторный CHAT_MSG_LOOT вызвал ошибку: " .. tostring(err3))
          end
          -- GP не должен был измениться
          local goldAfter2, gpAfter2 = Addon:GetMemberData(myName)
          if (goldAfter2 or 0) ~= (self.testGoldBefore or 0) or (gpAfter2 or 0) ~= (self.testGPBefore or 0) then
            error("GP изменился после повторного CHAT_MSG_LOOT — двойное начисление!")
          end

          -- 12. Авто-восстановление через finish_test
          Addon.Print("[12/12] Авто-восстановление состояния через finish_test")
        end)
        if ok2 then
          finish_test(true, nil)
        else
          finish_test(false, err2)
        end
      end
    end)
    autoTimer:Show()
  end)

  if not ok then
    -- pcall внутри синхронной части упал — восстанавливаем через finish_test
    finish_test(false, err)
    return
  end

  Addon.Print("=== Тест запущен. Финиш через 2 сек (finish_test auto) ===")
end

-- TestReset — аварийная ручная очистка.
-- Использует finish_test для гарантированной очистки.
function LM:TestReset()
  Addon.Print("=== LootMaster TestReset (manual cleanup) ===")
  -- finish_test делает всё нужное: останавливает timers, скрывает popup,
  -- восстанавливает snapshot, сбрасывает testMode.
  if testSnapshot then
    finish_test(true, "manual reset")
    Addon.Print("  Snapshot восстановлен через finish_test")
  else
    -- Нет активного теста — просто очищаем активное состояние
    LM.testMode = false
    LM.state.lootTable = {}
    LM.state.pendingAwards = {}
    LM.state.recoveryQueue = {}
    if LM.ResetClientLootState then
      LM:ResetClientLootState("testreset_no_snapshot")
    end
    if LM.mlFrame and LM.mlFrame:IsShown() then LM.mlFrame:Hide() end
    Addon.Print("  Активное состояние очищено (snapshot не было)")
  end

  -- Проверяем, что не осталось активных окон
  local visibleCount = 0
  for _, lf in ipairs(LM._lootFrames or {}) do
    if lf:IsShown() then visibleCount = visibleCount + 1 end
  end
  if visibleCount == 0 then
    Addon.Print("  OK: активных loot frames нет")
  else
    Addon.PrintError(string.format("  FAIL: осталось %d активных loot frames", visibleCount))
  end

  Addon.Print("=== TestReset завершён ===")
end

-- TestStatus — отчёт о текущем состоянии LootMaster.
function LM:TestStatus()
  Addon.Print("=== LootMaster TestStatus ===")
  Addon.Print(string.format("  testMode: %s", tostring(LM.testMode)))
  Addon.Print(string.format("  isML: %s", tostring(LM.state.isML)))
  Addon.Print(string.format("  mlName: %s", tostring(LM.state.mlName)))
  Addon.Print(string.format("  sessionId: %s", tostring(LM.state.sessionId)))
  Addon.Print(string.format("  lootSeq: %d", LM.state.lootSeq or 0))

  local lootCount = 0
  for _ in pairs(LM.state.lootTable or {}) do lootCount = lootCount + 1 end
  Addon.Print(string.format("  lootTable entries: %d", lootCount))

  Addon.Print(string.format("  clientLootList entries: %d", #(LM.state.clientLootList or {})))

  local visibleFrames = 0
  for _, lf in ipairs(LM._lootFrames or {}) do
    if lf:IsShown() then visibleFrames = visibleFrames + 1 end
  end
  Addon.Print(string.format("  visible lootFrames: %d", visibleFrames))

  Addon.Print("  Protocol version: V" .. tostring(LM.PROTOCOL_VERSION) .. "^")
  Addon.Print("  Addon version: " .. tostring(LM.VERSION))
  Addon.Print("=== TestStatus завершён ===")
end

-- TestDuplicates — два одинаковых itemID с разными lootKey
-- должны дать два независимых окна кандидата. DISCARD первого НЕ закрывает второе.
-- LOOTED второго закрывает только второе. Смена ML очищает оба старых окна.
function LM:TestDuplicates()
  Addon.Print("=== LootMaster TestDuplicates (Part 2) ===")

  -- Snapshot состояния ДО теста
  testSnapshot = capture_test_snapshot()

  local ok, err = pcall(function()
    -- Включаем testMode и сбрасываем состояние
    LM.testMode = true
    LM.state.lootTable = {}
    if LM.ResetClientLootState then
      LM:ResetClientLootState("testdup_start")
    end
    -- Инициализируем testAwards для T9 GP сумм проверок
    LM.testAwards = {}
    LM.state.sessionId = "testdup_" .. tostring(time()) .. "_" .. tostring(GetTime())
    LM.state.lootSeq = 0
    LM.state.isML = true
    LM.state.mlName = UnitName("player")
    LM.trackingEnabled = true

    local testLink = "|cffa335ee|Hitem:40354:0:0:0:0:0:0:0:80|h[Grim Toll]|h|r"
    local _, _, itemID = string.find(testLink, "item:(%d+)")
    itemID = itemID or "40354"
    local myName = UnitName("player")

    -- Тест 1: три DO_YOU_WANT с одним lootKey — должно быть одно окно
    Addon.Print("[T1] 3× DO_YOU_WANT с одним lootKey → ожидаем 1 окно")
    local lootKey1 = LM.state.sessionId .. ":" .. itemID .. ":1"
    local loot1 = {
      key = lootKey1, link = testLink, name = "Grim Toll",
      itemID = itemID, texture = "Interface\\Icons\\INV_Jewelry_Talisman_07",
      rarity = 4, ilevel = 213, equipLoc = "INVTYPE_TRINKET",
      gpValue = 150, quantity = 1, slotID = 1,
      mayDistribute = false, candidates = {}, candidateOrder = {},
      announcedAt = time(), timeout = 60,
    }
    loot1.candidates[myName] = {
      response = LM.RESPONSE.WAIT, note = "", class = "WARRIOR",
      candidateID = 1, gold = 0, gp = 0, pr = 0,
      currentitem = 0, currentilvl = 0, currentgp = 0,
      lootType = nil, lootGP = 0,
    }
    tinsert(loot1.candidateOrder, myName)
    LM.state.lootTable[lootKey1] = loot1

    local payload1 = string.format("%s^%s^%d^%d^%d^%s^%d^%s^%s",
      loot1.key, loot1.itemID, loot1.gpValue, loot1.ilevel, loot1.rarity,
      loot1.equipLoc, 60, loot1.link, loot1.texture)
    -- Три вызова SendToClient с одним lootKey
    LM:SendToClient("DO_YOU_WANT", payload1, myName)
    LM:SendToClient("DO_YOU_WANT", payload1, myName)
    LM:SendToClient("DO_YOU_WANT", payload1, myName)

    local vis1 = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis1 = vis1 + 1 end
    end
    if vis1 == 1 then
      Addon.Print(string.format("  OK: 1 окно (vis=%d)", vis1))
    else
      Addon.PrintError(string.format("  FAIL: ожидалось 1, vis=%d", vis1))
    end

    -- Тест 2: два разных lootKey с одним itemID — должно быть два независимых окна
    Addon.Print("[T2] 2× DO_YOU_WANT с разными lootKey (один itemID) → ожидаем 2 окна")
    local lootKey2 = LM.state.sessionId .. ":" .. itemID .. ":2"
    local loot2 = {
      key = lootKey2, link = testLink, name = "Grim Toll",
      itemID = itemID, texture = "Interface\\Icons\\INV_Jewelry_Talisman_07",
      rarity = 4, ilevel = 213, equipLoc = "INVTYPE_TRINKET",
      gpValue = 150, quantity = 1, slotID = 2,
      mayDistribute = false, candidates = {}, candidateOrder = {},
      announcedAt = time(), timeout = 60,
    }
    loot2.candidates[myName] = {
      response = LM.RESPONSE.WAIT, note = "", class = "WARRIOR",
      candidateID = 1, gold = 0, gp = 0, pr = 0,
      currentitem = 0, currentilvl = 0, currentgp = 0,
      lootType = nil, lootGP = 0,
    }
    tinsert(loot2.candidateOrder, myName)
    LM.state.lootTable[lootKey2] = loot2

    local payload2 = string.format("%s^%s^%d^%d^%d^%s^%d^%s^%s",
      loot2.key, loot2.itemID, loot2.gpValue, loot2.ilevel, loot2.rarity,
      loot2.equipLoc, 60, loot2.link, loot2.texture)
    LM:SendToClient("DO_YOU_WANT", payload2, myName)

    local vis2 = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis2 = vis2 + 1 end
    end
    if vis2 == 2 then
      Addon.Print(string.format("  OK: 2 независимых окна (vis=%d)", vis2))
    else
      Addon.PrintError(string.format("  FAIL: ожидалось 2, vis=%d", vis2))
    end

    -- Тест 3: DISCARD первого НЕ закрывает второе
    Addon.Print("[T3] DISCARD первого lootKey → второе окно должно остаться")
    LM:SendToClient("DISCARD", lootKey1, myName)
    local vis3 = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis3 = vis3 + 1 end
    end
    if vis3 == 1 then
      Addon.Print(string.format("  OK: осталось 1 окно (vis=%d)", vis3))
    else
      Addon.PrintError(string.format("  FAIL: ожидалось 1, vis=%d", vis3))
    end

    -- Тест 4: LOOTED второго закрывает только второе
    Addon.Print("[T4] LOOTED второго lootKey → последнее окно должно закрыться")
    LM:SendToClient("LOOTED", lootKey2 .. "^" .. myName .. "^" .. testLink .. "^" .. LM.LOOTTYPE.GP .. "^150", myName)
    local vis4 = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis4 = vis4 + 1 end
    end
    if vis4 == 0 then
      Addon.Print(string.format("  OK: все окна закрыты (vis=%d)", vis4))
    else
      Addon.PrintError(string.format("  FAIL: ожидалось 0, vis=%d", vis4))
    end

    -- Тест 5: повторный LOOTED безопасен
    Addon.Print("[T5] Повторный LOOTED — должен быть безопасным (no-op)")
    local ok5 = pcall(function()
      LM:SendToClient("LOOTED", lootKey2 .. "^" .. myName .. "^" .. testLink .. "^" .. LM.LOOTTYPE.GP .. "^150", myName)
    end)
    if ok5 then
      Addon.Print("  OK: повторный LOOTED не вызвал ошибку")
    else
      Addon.PrintError("  FAIL: повторный LOOTED вызвал ошибку")
    end

    -- Тест 6: смена ML очищает старые окна (имитация через ResetClientLootState)
    Addon.Print("[T6] Смена ML → ResetClientLootState должен очистить окна")
    -- Сначала переоткроем оба loot чтобы проверить очистку
    LM.state.lootTable[lootKey1] = loot1
    LM.state.lootTable[lootKey2] = loot2
    LM:SendToClient("DO_YOU_WANT", payload1, myName)
    LM:SendToClient("DO_YOU_WANT", payload2, myName)
    local vis6pre = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis6pre = vis6pre + 1 end
    end
    if LM.ResetClientLootState then
      LM:ResetClientLootState("ml_change_test")
    end
    local vis6post = 0
    for _, lf in ipairs(LM._lootFrames or {}) do
      if lf:IsShown() then vis6post = vis6post + 1 end
    end
    if vis6post == 0 then
      Addon.Print(string.format("  OK: было %d окон, стало %d после ML change", vis6pre, vis6post))
    else
      Addon.PrintError(string.format("  FAIL: было %d, осталось %d после ML change", vis6pre, vis6post))
    end

    -- Тест 7: новый sessionId не блокируется старыми записями.
    -- Старый lootKey в lootTable после смены sessionId — это УТЕЧКА, а не
    -- ожидаемое поведение: EndLootSession должен извлечь pending-GP записи
    -- (если есть) и оставить lootTable пустым либо только с записями без
    -- активных candidates (остальное чистит ScheduleLootCleanup).
    Addon.Print("[T7] Новый sessionId — старый lootKey не должен найтись")
    LM.state.sessionId = "testdup_newsession_" .. tostring(time())
    local stillThere = LM:FindLootByKey(lootKey1)
    if not stillThere then
      Addon.Print("  OK: старый lootKey1 не найден (новая сессия чиста)")
    else
      Addon.PrintError("  FAIL: старый lootKey1 найден после смены sessionId — утечка сессии")
      Addon.PrintError("  (EndLootSession должен был извлечь pending-GP и пометить остальные как mayDistribute=false)")
    end

    -- Тест 8 — совместимость типов itemID в pendingAwards:
    -- LM.GetItemIDFromLink() возвращает number, payload протокола string,
    -- а pendingAwards[40354] ~= pendingAwards["40354"]. NormalizeItemID
    -- гарантирует один и тот же строковый ключ.
    Addon.Print("[T8] NormalizeItemID: number ↔ string совместимость")
    -- Очищаем pendingAwards
    LM.state.pendingAwards = {}
    -- Queue с number itemID
    local q1 = LM:QueuePendingAward(tonumber(itemID), myName, "test_number_key")
    -- Peek с string itemID
    local peek_str = LM:PeekPendingAward(tostring(itemID), myName)
    if q1 and peek_str == "test_number_key" then
      Addon.Print("  OK: Queue(number) → Peek(string) → found")
    else
      Addon.PrintError(string.format("  FAIL: Queue(number)=q1=%s peek_str=%s (типы несовместимы)",
        tostring(q1), tostring(peek_str)))
    end
    -- Обратный тест: Queue с string → Peek с number
    LM.state.pendingAwards = {}
    local q2 = LM:QueuePendingAward(tostring(itemID), myName, "test_string_key")
    local peek_num = LM:PeekPendingAward(tonumber(itemID), myName)
    if q2 and peek_num == "test_string_key" then
      Addon.Print("  OK: Queue(string) → Peek(number) → found")
    else
      Addon.PrintError(string.format("  FAIL: Queue(string)=q2=%s peek_num=%s (типы несовместимы)",
        tostring(q2), tostring(peek_num)))
    end
    -- Тест duplicate protection
    LM.state.pendingAwards = {}
    LM:QueuePendingAward(itemID, myName, "dup_test_key")
    LM:QueuePendingAward(itemID, myName, "dup_test_key")  -- повтор
    local peek_dup = LM:PeekPendingAward(itemID, myName)
    if peek_dup == "dup_test_key" then
      Addon.Print("  OK: duplicate lootKey не добавляется повторно")
    else
      Addon.PrintError("  FAIL: duplicate lootKey добавлен повторно (защита сломана)")
    end

    -- Тест 9 — два одинаковых предмета с разными типами itemID и разным GP,
    -- обрабатываются в порядке выдачи. Проверяем ФАКТИЧЕСКИЕ суммы GP через
    -- LM.testAwards (не только gpProcessed). FAIL вызывает error() — тест не
    -- может завершиться finish_test(true) при неуспешной проверке.
    Addon.Print("[T9] Два одинаковых предмета, разный тип itemID, разный GP — порядок + суммы")
    LM.state.pendingAwards = {}
    LM.state.lootTable = {}
    -- Очищаем testAwards перед T9
    LM.testAwards = {}
    if LM.ResetClientLootState then
      LM:ResetClientLootState("testdup_t9")
    end
    LM.state.sessionId = "testdup_t9_" .. tostring(time())
    local lootKeyA = LM.state.sessionId .. ":" .. itemID .. ":A"
    local lootKeyB = LM.state.sessionId .. ":" .. itemID .. ":B"
    -- lootA: itemID как number, GP=400 (Main spec)
    local lootA = {
      key = lootKeyA, link = testLink, name = "Grim Toll A",
      itemID = tonumber(itemID),  -- number
      texture = "Interface\\Icons\\INV_Jewelry_Talisman_07",
      rarity = 4, ilevel = 213, equipLoc = "INVTYPE_TRINKET",
      gpValue = 400, quantity = 1, slotID = 10,
      mayDistribute = false, candidates = {}, candidateOrder = {},
      announcedAt = time(), timeout = 60,
    }
    lootA.candidates[myName] = {
      response = LM.RESPONSE.WAIT, note = "", class = "WARRIOR",
      candidateID = 1, gold = 0, gp = 0, pr = 0,
      currentitem = 0, currentilvl = 0, currentgp = 0,
      lootType = nil, lootGP = 0,
    }
    tinsert(lootA.candidateOrder, myName)
    LM.state.lootTable[lootKeyA] = lootA
    -- lootB: itemID как string, GP=200 (Off spec)
    local lootB = {
      key = lootKeyB, link = testLink, name = "Grim Toll B",
      itemID = tostring(itemID),  -- string
      texture = "Interface\\Icons\\INV_Jewelry_Talisman_07",
      rarity = 4, ilevel = 213, equipLoc = "INVTYPE_TRINKET",
      gpValue = 200, quantity = 1, slotID = 11,
      mayDistribute = false, candidates = {}, candidateOrder = {},
      announcedAt = time(), timeout = 60,
    }
    lootB.candidates[myName] = {
      response = LM.RESPONSE.WAIT, note = "", class = "WARRIOR",
      candidateID = 1, gold = 0, gp = 0, pr = 0,
      currentitem = 0, currentilvl = 0, currentgp = 0,
      lootType = nil, lootGP = 0,
    }
    tinsert(lootB.candidateOrder, myName)
    LM.state.lootTable[lootKeyB] = lootB
    -- Помещаем в очередь: сначала lootA (number itemID, GP=400), потом lootB (string itemID, GP=200)
    LM:GiveLootToCandidate(lootA, myName, LM.LOOTTYPE.GP, 400)
    LM:GiveLootToCandidate(lootB, myName, LM.LOOTTYPE.GP, 200)
    -- Проверяем порядок через PeekPendingAward
    local peekA = LM:PeekPendingAward(itemID, myName)
    if peekA ~= lootKeyA then
      error(string.format("T9: первый в очереди %s, ожидается %s (порядок выдачи нарушен)",
        tostring(peekA), tostring(lootKeyA)))
    end
    Addon.Print("  OK: первый в очереди lootKeyA (порядок выдачи сохранён)")
    -- Симулируем первый CHAT_MSG_LOOT
    local fakeMsgA = myName .. " получает лут: " .. testLink
    LM:OnChatMsgLoot(fakeMsgA)
    -- Проверяем что lootA обработан и testAwards содержит запись с GP=400
    if lootA.candidates[myName].gpProcessed ~= true then
      error("T9: lootA.gpProcessed не true после первого CHAT_MSG_LOOT")
    end
    if lootA.candidates[myName].lootGiven ~= nil then
      error("T9: lootA.lootGiven не nil после первого CHAT_MSG_LOOT")
    end
    if lootB.candidates[myName].gpProcessed == true then
      error("T9: lootB.gpProcessed true после первого CHAT_MSG_LOOT (должен быть false)")
    end
    if not LM.testAwards or #LM.testAwards ~= 1 then
      error(string.format("T9: testAwards должен иметь 1 запись, имеет %d",
        LM.testAwards and #LM.testAwards or -1))
    end
    if LM.testAwards[1].lootKey ~= lootKeyA then
      error(string.format("T9: testAwards[1].lootKey=%s, ожидается %s",
        tostring(LM.testAwards[1].lootKey), tostring(lootKeyA)))
    end
    if LM.testAwards[1].gp ~= 400 then
      error(string.format("T9: testAwards[1].gp=%d, ожидается 400",
        LM.testAwards[1].gp))
    end
    Addon.Print("  OK: после 1-го CHAT_MSG_LOOT — lootA обработан, testAwards[1].gp=400")
    -- После первого CHAT_MSG_LOOT в очереди должен остаться lootKeyB
    local peekB = LM:PeekPendingAward(itemID, myName)
    if peekB ~= lootKeyB then
      error(string.format("T9: после 1-го CHAT_MSG_LOOT peek=%s, ожидается %s",
        tostring(peekB), tostring(lootKeyB)))
    end
    Addon.Print("  OK: после 1-го CHAT_MSG_LOOT в очереди lootKeyB")
    -- Симулируем второй CHAT_MSG_LOOT
    LM:OnChatMsgLoot(fakeMsgA)
    -- После второго CHAT_MSG_LOOT очередь должна быть пуста
    local peekEmpty = LM:PeekPendingAward(itemID, myName)
    if peekEmpty then
      error(string.format("T9: после 2-го CHAT_MSG_LOOT peek=%s, ожидается nil", tostring(peekEmpty)))
    end
    -- lootB должен быть обработан
    if lootB.candidates[myName].gpProcessed ~= true then
      error("T9: lootB.gpProcessed не true после 2-го CHAT_MSG_LOOT")
    end
    if not LM.testAwards or #LM.testAwards ~= 2 then
      error(string.format("T9: testAwards должен иметь 2 записи, имеет %d",
        LM.testAwards and #LM.testAwards or -1))
    end
    if LM.testAwards[2].lootKey ~= lootKeyB then
      error(string.format("T9: testAwards[2].lootKey=%s, ожидается %s",
        tostring(LM.testAwards[2].lootKey), tostring(lootKeyB)))
    end
    if LM.testAwards[2].gp ~= 200 then
      error(string.format("T9: testAwards[2].gp=%d, ожидается 200", LM.testAwards[2].gp))
    end
    Addon.Print("  OK: после 2-го CHAT_MSG_LOOT — lootB обработан, testAwards[2].gp=200")
    -- Третий CHAT_MSG_LOOT — должен быть no-op (всё уже обработано)
    local testAwardsCountBefore = #LM.testAwards
    local ok_repeat = pcall(function()
      LM:OnChatMsgLoot(fakeMsgA)
    end)
    if not ok_repeat then
      error("T9: повторный CHAT_MSG_LOOT вызвал Lua error")
    end
    if #LM.testAwards ~= testAwardsCountBefore then
      error(string.format("T9: после 3-го CHAT_MSG_LOOT testAwards count=%d, ожидается %d (двойное начисление!)",
        #LM.testAwards, testAwardsCountBefore))
    end
    Addon.Print("  OK: повторный CHAT_MSG_LOOT — no-op (testAwards count не изменился)")

    Addon.Print("=== TestDuplicates completed. finish_test will auto-restore ===")
  end)

  if not ok then
    -- finish_test гарантирует восстановление даже при ошибке в pcall
    finish_test(false, "[TestDuplicates] " .. tostring(err))
    return
  end
  -- Успешное завершение — finish_test с success=true
  finish_test(true, "TestDuplicates completed")
end

-- ============================================================================
-- ИНИЦИАЛИЗАЦИЯ
-- ============================================================================

-- SavedVariables для настроек LootMaster (тексты кнопок, таймер, ...)
-- Хранятся в GoldGPLMDB (см. .toc, SavedVariables: GoldGPLMDB)
-- Структура: GoldGPLMDB = { global = { btn_need_text=..., btn_offspec_text=..., btn_pass_text=..., loot_timeout=60, db_version=1 } }

local LM_DB_DEFAULTS = {
  db_version       = 1,
  btn_need_text    = "Мейн спек",
  btn_offspec_text = "Офф спек",
  btn_pass_text    = "Откажусь",
  loot_timeout     = 60,  -- сек, 15..120
  -- Показывать ли read-only окно ML другим кандидатам после их ответа
  ml_view_all_enabled = false,
  -- Пользовательские переопределения GP по itemID
  gp_overrides     = {},  -- { [itemID] = gp, ... }
}

local function InitLMDB()
  if GoldGPLMDB == nil then GoldGPLMDB = {} end
  if GoldGPLMDB.global == nil then GoldGPLMDB.global = {} end
  -- Применяем дефолты для отсутствующих полей
  for k, v in pairs(LM_DB_DEFAULTS) do
    if GoldGPLMDB.global[k] == nil then
      GoldGPLMDB.global[k] = v
    end
  end
  LM.db = { global = GoldGPLMDB.global }
end

-- ============================================================================
-- ПОСТ-ЗАГРУЗОЧНАЯ ИНИЦИАЛИЗАЦИЯ (БД + префиксы + клиент + ML)
-- ============================================================================
-- Вызывается из ADDON_LOADED (нормальный путь) ИЛИ напрямую из waiter
-- (отложенный путь — когда ADDON_LOADED этого аддона уже прошёл, а ядро
-- появилось только сейчас). postload_done защищает от двойного запуска.
local postload_done = false
local function PostLoadInit()
  if postload_done then return end
  postload_done = true
  -- Инициализация БД ДО остальных модулей
  InitLMDB()
  -- Регистрация префиксов аддон-сообщений.
  -- В WoW 3.3.5a CHAT_MSG_ADDON молча отбрасывает сообщения с
  -- незарегистрированными префиксами. Регистрируем GoldGPLM (ML → клиенты)
  -- и GoldGPLM_R (клиенты → ML) один раз при загрузке аддона.
  -- ОБЯЗАТЕЛЬНО в pcall — защищает от краша (префикс уже зарегистрирован
  -- другим аддоном или лимит превышен).
  pcall(function()
    RegisterAddonMessagePrefix(PREFIX_ML_TO_CLIENT)   -- "GoldGPLM"
    RegisterAddonMessagePrefix(PREFIX_CLIENT_TO_ML)   -- "GoldGPLM_R"
  end)
  if Addon and Addon.Log then
    Addon.Log:Info("GoldGP_LootMaster v%s loaded (Phases 1-5)", VERSION)
  end
  -- Инициализация клиентского UI
  if LM.InitClient then LM:InitClient() end
  -- Инициализация ML
  if LM.InitML then LM:InitML() end
  -- Применить тексты кнопок к уже созданным lootFrames (если есть)
  if LM.ApplyButtonLabels then LM:ApplyButtonLabels() end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addonName)
  if event == "ADDON_LOADED" and addonName == "GoldGP_LootMaster" then
    self:UnregisterEvent("ADDON_LOADED")
    PostLoadInit()
  end
end)

-- Экспорт для отложенного старта (waiter внизу файла вызывает напрямую)
LM._PostLoadInit = PostLoadInit

-- Экспорт для отладки
LM.VERSION = VERSION
LM.PROTOCOL_VERSION = PROTOCOL_VERSION
LM.RESPONSE = RESPONSE
LM.RESPONSE_TEXT = RESPONSE_TEXT
LM.RESPONSE_SORT = RESPONSE_SORT
LM.LOOTTYPE = LOOTTYPE
LM.CUSTOM_ITEM_DATA = CUSTOM_ITEM_DATA

end  -- end of boot(Addon)

-- ============================================================================
-- ЗАПУСК — сразу, либо отложенно (waiter до 30с)
-- ============================================================================
if GoldGP then
  -- Нормальный путь: ядро загружено (Dependencies: GoldGP в .toc) — boot прямо
  -- сейчас, PostLoadInit придёт позже с ADDON_LOADED этого аддона.
  boot(GoldGP)
else
  -- Нарушенный порядок загрузки (кастом-клиент/старая установка). ЖДЁМ ядро.
  local waiter = CreateFrame("Frame")
  local waited = 0
  waiter:RegisterEvent("ADDON_LOADED")
  waiter:RegisterEvent("PLAYER_LOGIN")
  waiter:SetScript("OnEvent", function() waited = 999 end)
  waiter:SetScript("OnUpdate", function(self, elapsed)
    waited = waited + elapsed
    if GoldGP then
      self:UnregisterAllEvents()
      self:Hide()
      boot(GoldGP)
      -- ADDON_LOADED этого аддона уже прошёл — пост-инициализацию зовём напрямую.
      if _G.GoldGPLootMaster._PostLoadInit then
        _G.GoldGPLootMaster:_PostLoadInit()
      end
      if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r LootMaster: отложенный старт (ядро загрузилось позже модуля).")
      end
    elseif waited > 30 then
      self:UnregisterAllEvents()
      self:Hide()
      if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP LootMaster: ядро GoldGP не загрузилось за 30с — модуль отключён. Проверьте установку папки GoldGP и выполните /reload.|r")
      end
    end
  end)
end
