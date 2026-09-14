-- GoldGP_Award.lua

local Addon = GoldGP
local Award = {}
Addon.Award = Award

-- backup-переменные (объявлены НАВЕРХУ — Lua local виден только после объявления)
local last_decay_backup = nil
local last_mass_backup   = nil
local last_reset_backup  = nil

-- Reentrancy guard для MassGold — запрещает параллельный запуск
-- (защита от двойного клика по кнопке "Начислить всем" или повторного /gg mass)
local mass_in_progress = false

-- In-memory backup последней частично неуспешной attendance mass operation.
-- Структура:
--   last_attendance_mass_recovery = {
--     id = ...,                      -- уникальный ID (time())
--     reason = ...,
--     amount = ...,
--     extras_amount = ...,
--     extras_reason = ...,
--     plannedMains = { [mainName] = true, ... },  -- mains которые должны получить attendance
--     epSucceededMains = { [mainName] = true, ... },  -- mains успешно получившие EP
--     epFailedMains = { [mainName] = true, ... },  -- mains для которых IncGold не удался
--     attendanceApplied = false,  -- флаг: была ли применена attendance фаза
--     attendanceTargets = { [mainName] = oldCount + 1, ... },  -- target counts (idempotent)
--     attendanceOldTotal = oldTotal,
--     epTargets = { [mainName] = { amount=, reason=, isExtras=, sourceName= }, ... },
--       -- исходные параметры выдачи для каждого main,
--       -- чтобы retry использовал их, а не пересчитывал через текущий состав рейда.
--   }
-- Не persisted в SavedVariables — после reload повтор recovery недоступен.
-- Это рискованнее чем persist, но безопаснее чем двойной EP (retry может быть вызван
-- только вручную через /gg attendance retry, что не даст повторного EP).
local last_attendance_mass_recovery = nil

-- статистика recurring
local recurring_stats = { total_ep = 0, count = 0 }

-- Задержки в Award реализованы через абсолютные метки time()/GetTime() в профильных полях.

-- ============================================================================
-- УТИЛИТЫ
-- ============================================================================

-- Helper — добавить маркер [ОТП] к note если игрок в отпуске.
-- Резолвит alt→main. Не добавляет маркер к note альта (alt note = "MainName").
local function AppendLeaveMarker(note, name)
  if not name then return note end
  local main = Addon.data.main_data[name] or name
  if Addon.data.on_leave and Addon.data.on_leave[main] then
    return note .. " [ОТП]"
  end
  return note
end

-- Кодировать ноту "Gold,GP"
-- gp = DISPLAYED (raw + base_gp). Subtract base_gp before writing to officer note.
-- Optional targetName — если указан и main в отпуске, добавляет [ОТП].
local function EncodeNote(gold, gp, targetName)
  local base = Addon.db.profile.base_gp or 0
  local note = string.format("%d,%d", math.max(gold, 0), math.max(gp - base, 0))
  if targetName then
    return AppendLeaveMarker(note, targetName)
  end
  return note
end

-- Кодировать ноту из RAW значений (без вычитания base_gp).
-- Используется в RestoreDecay/RestoreReset где backup уже хранит raw данные.
-- Принимает raw gold и raw gp (как хранится в Addon.data.gold_data / gp_data),
-- возвращает officer note строку "gold,gp" без двойного вычитания base_gp.
-- Optional targetName — если указан и main в отпуске, добавляет [ОТП].
local function EncodeRawNote(gold, gp, targetName)
  local note = string.format("%d,%d", math.max(gold or 0, 0), math.max(gp or 0, 0))
  if targetName then
    return AppendLeaveMarker(note, targetName)
  end
  return note
end

-- GetRawMemberData — возвращает raw gold и raw gp из Addon.data
-- БЕЗ добавления base_gp. Используется в backup/restore контекстах (CreateDecayBackup,
-- RestoreDecay, RestoreReset), где мы работаем с officer note напрямую, а не с
-- displayed values. GetMemberData() добавляет base_gp, что приводит к ошибкам
-- при сравнении raw и displayed значений.
-- Возвращает: rawGold, rawGP, target (где target = main если name это alt, иначе name).
-- Если name не найден в gold_data — возвращает nil, nil.
local function GetRawMemberData(name)
  if not name then return nil, nil end
  -- Resolve alt → main (alt's officer note is the main's name, not "Gold,GP")
  local main = Addon.data.main_data[name]
  local target = main or name
  local rawGold = Addon.data.gold_data[target]
  local rawGP = Addon.data.gp_data[target]
  if rawGold == nil or rawGP == nil then
    return nil, nil
  end
  return rawGold, rawGP, target
end

-- ============================================================================
-- ОСНОВНЫЕ ОПЕРАЦИИ
-- ============================================================================

-- Добавить Gold/GP игроку (внутренняя)
local function AddGoldGP(name, gold_delta, gp_delta)
  local total_gold = Addon.data.gold_data[name]
  local total_gp = Addon.data.gp_data[name]
  if total_gold == nil or total_gp == nil then
    return nil, "not a main: " .. tostring(name)
  end

  -- Корректируем deltas, чтобы не уйти в минус
  if total_gold + gold_delta < 0 then
    gold_delta = -total_gold
  end
  if total_gp + gp_delta < 0 then
    gp_delta = -total_gp
  end

  -- Вычисляем НОВЫЕ значения
  local new_gold = total_gold + gold_delta
  local new_gp = total_gp + gp_delta

  -- Записываем новую ноту через Storage (с очередью pending!)
  -- Передаём name в EncodeNote для сохранения [ОТП] маркера.
  local new_note = EncodeNote(new_gold, new_gp + (Addon.db.profile.base_gp or 0), name)
  local set_result = Addon.Storage:SetNote(name, new_note)

  -- Если SetNote вернул nil (очередь pending переполнена) — отказ.
  -- НЕ обновляем gold_data/gp_data, чтобы кэш не разошёлся с сервером.
  if set_result == nil then
    return nil, "pending_full"
  end

  -- НЕМЕДЛЕННО обновляем gold_data/gp_data сразу после расчёта, а не ждём
  -- callback NoteChanged после flush: иначе повторное начисление до flush
  -- читает устаревший кэш и шлёт серверу ту же ноту повторно — sirus.su может
  -- интерпретировать это как ошибку или применить как декремент.
  -- Если SetNote упадёт (pending уже занят тем же значением) —
  --   данные в кэше всё равно будут правильными (мы их уже прибавили).
  -- Если сервер отклонит ноту — при следующем GUILD_ROSTER_UPDATE
  --   ParseNote перезапишет gold_data реальным значением с сервера.
  Addon.data.gold_data[name] = new_gold
  Addon.data.gp_data[name] = new_gp
  Addon:BumpCacheVersion()

  Addon.Log:Debug("AddGoldGP: %s | gold %d + %d = %d | gp %d + %d = %d | note='%s'",
    name, total_gold, gold_delta, new_gold, total_gp, gp_delta, new_gp, new_note)

  return gold_delta, gp_delta, nil
end

-- ============================================================================
-- ИНДИВИДУАЛЬНЫЕ НАЧИСЛЕНИЯ
-- ============================================================================

-- Начислить Gold конкретному игроку
-- name: имя игрока (может быть alt — автоматически определит main)
-- reason: причина (строка)
-- amount: количество (целое число, может быть отрицательным для штрафа)
-- mass: true если это часть массовки (для лога)
-- undo: true если это undo операция
-- Возвращает: имя main'а (или nil при ошибке)
function Award:IncGold(name, reason, amount, mass, undo)
  -- Гильд-лок
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — начисления невозможны")
    return nil
  end
  if type(name) ~= "string" then
    Addon.Log:Error("IncGold: name must be string, got %s", type(name))
    return nil
  end

  -- Проверка прав на офицерские ноты: без прав сервер отклонит ноту и EP
  -- "исчезнет" при следующем GUILD_ROSTER_UPDATE.
  -- undo-операции тоже требуют прав (нужно записать новую ноту).
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты — начисление EP невозможно")
    Addon.Log:Warn("IncGold: no permission (CanEditOfficerNote=false)")
    return nil
  end

  -- Игроки "в отпуске" не получают EP/GP (даже индивидуально)
  if Addon:IsOnLeave(name) and not undo then
    Addon.PrintError(name .. " — в отпуске, начисление невозможно")
    Addon.Log:Warn("IncGold: %s is on leave, skipping", name)
    return nil
  end

  local gold, gp, main = Addon:GetMemberData(name)
  if gold == nil then
    Addon.Log:Warn("Ignoring Gold change for unknown member: %s", name)
    return nil
  end

  local target = main or name
  -- AddGoldGP returns (gold_delta, gp_delta) on success, (nil, err_string) on failure.
  local gold_delta, gp_delta, err = AddGoldGP(target, amount, 0)
  if err then
    Addon.PrintError(string.format("Не удалось начислить EP игроку %s — сервер занят записью. Подождите 2-3 сек.", name))
    return nil
  end
  if gold_delta then
    Addon:Fire("GoldAward", name, reason, gold_delta, mass, undo)
    Addon.Log:Award("gold", name, reason, gold_delta, mass, UnitName("player"))
  end
  return target
end

-- Начислить GP конкретному игроку
function Award:IncGP(name, reason, amount, mass, undo)
  -- Гильд-лок
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — начисления невозможны")
    return nil
  end
  if type(name) ~= "string" then
    return nil
  end
  if not reason then reason = "Manual" end

  -- Проверка прав на офицерские ноты (как в IncGold).
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты — начисление GP невозможно")
    Addon.Log:Warn("IncGP: no permission (CanEditOfficerNote=false)")
    return nil
  end

  -- Игроки "в отпуске" не получают EP/GP (даже индивидуально)
  if Addon:IsOnLeave(name) and not undo then
    Addon.PrintError(name .. " — в отпуске, начисление невозможно")
    Addon.Log:Warn("IncGP: %s is on leave, skipping", name)
    return nil
  end

  local gold, gp, main = Addon:GetMemberData(name)
  if gold == nil then
    Addon.Log:Warn("Ignoring GP change for unknown member: %s", name)
    return nil
  end

  local target = main or name
  -- AddGoldGP returns (gold_delta, gp_delta) on success, (nil, err_string) on failure.
  -- For IncGP we pass gold_delta=0, so gold_delta is 0 (truthy in Lua!). Must check err, not gold_delta.
  local gold_delta, gp_delta, err = AddGoldGP(target, 0, amount)
  if err then
    Addon.PrintError(string.format("Не удалось начислить GP игроку %s — сервер занят записью. Подождите 2-3 сек.", name))
    return nil
  end
  if gp_delta then
    Addon:Fire("GPAward", name, reason, gp_delta, mass, undo)
    Addon.Log:Award("gp", name, reason, gp_delta, mass, UnitName("player"))
  end
  return target
end

-- ============================================================================
-- МАССОВЫЕ НАЧИСЛЕНИЯ — С ПРОВЕРКАМИ!
-- ============================================================================

-- ============================================================================
-- ОТМЕНА ЗАПИСИ ЖУРНАЛА (undo)
-- ============================================================================
-- Отменяет конкретную запись из журнала
-- entry = { type, target, reason, amount, officer, time }
-- Инвертирует сумму: если было +50 -> становится -50, и наоборот.
-- Поддерживает отмену МАССОВОК — находит все записи с тем же reason+time
-- (±60 сек) и инвертирует каждую. DECAY с target="ALL" отменяет через RestoreDecay.
function Award:UndoEntry(entry)
  if not entry then
    Addon.PrintError("UndoEntry: запись не указана")
    return false
  end
  local target = entry.target

  -- DECAY с target="ALL" — используем backup (если есть)
  if entry.type == "DECAY" and (not target or target == "ALL") then
    if last_decay_backup then
      return Award:RestoreDecay()
    end
    Addon.PrintError("UndoEntry: нет backup для отмены среза (срез был до перелога)")
    return false
  end

  -- МАССОВКА (MASS_GOLD / MASS_GP) — отменяем всю группировку
  if entry.type == "MASS_GOLD" or entry.type == "MASS_GP" then
    return Award:UndoMassGroup(entry)
  end

  -- Индивидуальная запись (GOLD / GP)
  if not target or target == "ALL" then
    Addon.PrintError("UndoEntry: нельзя отменить записью без target")
    return false
  end
  -- Проверяем, что игрок существует
  local gold, gp, main = Addon:GetMemberData(target)
  if gold == nil then
    Addon.PrintError("UndoEntry: игрок " .. tostring(target) .. " не найден")
    return false
  end
  -- Инвертируем сумму
  -- Защита от nil amount в старых/повреждённых записях
  local entry_amount = entry.amount or 0
  local inverted_amount = -entry_amount
  local undo_reason = "Отмена: " .. (entry.reason or "?")
  -- Определяем тип
  if entry.type == "GOLD" then
    local result = Award:IncGold(target, undo_reason, inverted_amount, false, true)
    if result then
      Addon.Print(string.format("OK Отмена: %s %d EP -> %s", entry_amount > 0 and "-" or "+",
        math.abs(entry_amount), target))
      Addon.Log:Info("[UNDO] %s | %s | %d -> %d (%s)",
        target, entry.type, entry_amount, inverted_amount, entry.reason or "?")
      return true
    end
  elseif entry.type == "GP" then
    local result = Award:IncGP(target, undo_reason, inverted_amount, false, true)
    if result then
      Addon.Print(string.format("OK Отмена: %s %d GP -> %s", entry_amount > 0 and "-" or "+",
        math.abs(entry_amount), target))
      Addon.Log:Info("[UNDO] %s | %s | %d -> %d (%s)",
        target, entry.type, entry_amount, inverted_amount, entry.reason or "?")
      return true
    end
  else
    Addon.PrintError("UndoEntry: тип '" .. tostring(entry.type) .. "' не поддерживается для отмены")
    return false
  end
  return false
end

-- Отмена массовки по одной записи из журнала.
-- Находит все записи MASS_GOLD/MASS_GP с тем же reason и временем (±60 сек) и инвертирует каждую.
function Award:UndoMassGroup(sample_entry)
  if not sample_entry or not Addon.db or not Addon.db.global or not Addon.db.global.history then
    Addon.PrintError("UndoMassGroup: нет данных истории")
    return false
  end
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты!")
    return false
  end
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов! Подождите несколько секунд и повторите.")
    return false
  end

  local reason = sample_entry.reason or ""
  local entry_time = sample_entry.time or 0
  local entry_type = sample_entry.type  -- MASS_GOLD или MASS_GP
  local GAP = 60  -- ±60 сек от времени записи

  -- Собираем все записи этой массовки (тот же type + reason + время в окне ±60 сек)
  local group = {}
  for _, e in ipairs(Addon.db.global.history) do
    if e.type == entry_type
      and (e.reason or "") == reason
      and math.abs((e.time or 0) - entry_time) <= GAP
      and e.target and e.target ~= "ALL"
    then
      tinsert(group, e)
    end
  end

  if #group == 0 then
    Addon.PrintError("UndoMassGroup: не найдено записей для отмены")
    return false
  end

  -- Если это последняя массовка и есть backup — используем RestoreMass (быстрее и точнее)
  if entry_type == "MASS_GOLD" and last_mass_backup
    and last_mass_backup.reason == reason
    and math.abs((last_mass_backup.time or 0) - entry_time) <= GAP
  then
    Addon.Print("Использую backup последней массовки для точной отмены...")
    return Award:RestoreMass()
  end

  -- Иначе инвертируем каждую запись по одной
  local undo_reason = "Отмена массовки: " .. reason
  local count = 0
  local failed = {}
  for _, e in ipairs(group) do
    local inverted = -e.amount
    local ok
    if entry_type == "MASS_GOLD" then
      ok = Award:IncGold(e.target, undo_reason, inverted, true, true)
    else
      ok = Award:IncGP(e.target, undo_reason, inverted, true, true)
    end
    if ok then
      count = count + 1
    else
      tinsert(failed, e.target)
    end
  end

  local currency = entry_type == "MASS_GOLD" and "EP" or "GP"
  Addon.Print(string.format("OK Отмена массовки '%s': %d игроков получило -%s, %d неудач",
    reason, count, currency, #failed))
  if #failed > 0 then
    Addon.PrintError("Не удалось отменить: " .. table.concat(failed, ", "))
  end
  -- Анонс в чат гильдии
  if Addon.Announce and Addon.Announce.SendCustomMessage then
    Addon.Announce:SendCustomMessage(string.format("Отмена массовки: '%s' — %d игроков", reason, count))
  end
  Addon.Log:Info("[UNDO MASS] %s | %s | %d entries, %d failed", reason, entry_type, count, #failed)
  return true
end

-- Отмена последнего действия (для кнопки в футере Журнала).
-- Ищет последнюю запись в истории и отменяет её (включая массовки и decay).
function Award:UndoLastAction()
  if not Addon.db or not Addon.db.global or not Addon.db.global.history then
    Addon.PrintError("UndoLastAction: история пуста")
    return false
  end
  local history = Addon.db.global.history
  if #history == 0 then
    Addon.PrintError("UndoLastAction: история пуста")
    return false
  end

  -- Берём последнюю запись
  local last = history[#history]
  if not last then
    Addon.PrintError("UndoLastAction: последняя запись повреждена")
    return false
  end

  -- Пропускаем записи-отмены (undo=true) — их самих отменять не нужно
  if last.undo then
    Addon.PrintError("UndoLastAction: последняя запись уже является отменой — нельзя отменить отмену")
    return false
  end

  -- Для DECAY — используем backup если есть
  if last.type == "DECAY" then
    if last_decay_backup then
      Addon.Print("Отмена последнего действия: срез")
      return Award:RestoreDecay()
    end
    Addon.PrintError("UndoLastAction: нет backup для отмены среза (срез был до перелога)")
    return false
  end

  -- Для массовок — находим всю группировку и отменяем
  if last.type == "MASS_GOLD" or last.type == "MASS_GP" then
    Addon.Print("Отмена последнего действия: массовка '" .. (last.reason or "?") .. "'")
    return Award:UndoMassGroup(last)
  end

  -- Для индивидуальных начислений (GOLD/GP)
  Addon.Print("Отмена последнего действия: " .. (last.type or "?") .. " " .. (last.amount or 0) .. " -> " .. (last.target or "?"))
  return Award:UndoEntry(last)
end

-- Массовое начисление Gold
-- reason: причина
-- amount: количество
-- Возвращает: таблицу с результатами {awarded, failed, extras}
function Award:MassGold(reason, amount)
  -- Гильд-лок
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — массовки невозможны")
    return { awarded = {}, failed = {}, error = "guild_lock" }
  end
  -- Force update raid_members — throttle мог пропустить RAID_ROSTER_UPDATE
  if UnitInRaid("player") and not next(Addon.state.raid_members) then
    Addon:RAID_ROSTER_UPDATE()
  end

  -- ПРОВЕРКА 1: cooldown между массовками
  local now = GetTime()
  local cooldown = Addon.db.profile.mass_ep_cooldown or 1.5
  if now - Addon.state.last_mass_award_time < cooldown then
    local wait = cooldown - (now - Addon.state.last_mass_award_time)
    Addon.Log:Warn("Mass Gold rejected: cooldown %.1fs remaining. Wait or use /gg force", wait)
    Addon.PrintError(string.format("Слишком быстро! Подождите %.1f сек или /gg force", wait))
    return { awarded = {}, failed = {}, error = "cooldown" }
  end

  -- ПРОВЕРКА 1.5: reentrancy guard — массовка уже выполняется
  if mass_in_progress then
    Addon.PrintError("Массовка уже выполняется, подождите...")
    return { awarded = {}, failed = {}, error = "in_progress" }
  end
  mass_in_progress = true

  -- ПРОВЕРКА 2: состояние Storage
  if Addon.db.profile.safe_mass_mode and not Addon.Storage:IsCurrentState() then
    mass_in_progress = false
    local st = Addon.Storage:GetState()
    Addon.Log:Warn("Mass Gold rejected: storage state=%s (not CURRENT). Use /gg force to override", st)
    Addon.PrintError(string.format("Storage в состоянии %s — подождите 2 сек или /gg force", st))
    return { awarded = {}, failed = {}, error = "not_current" }
  end

  -- ПРОВЕРКА 3: права
  if not CanEditOfficerNote() then
    mass_in_progress = false
    Addon.PrintError("Нет прав на офицерские ноты!")
    return { awarded = {}, failed = {}, error = "no_permission" }
  end

  Addon.state.last_mass_award_time = now
  Addon.Log:MassAwardStart(reason, amount, Addon:GetNumMembersInAwardList())

  -- Посещаемость через public note + GuildInfo.
  -- Attendance phase ОТЛОЖЕНА до полного успеха EP phase: иначе при partial EP
  -- failure @ATT_TOTAL уже увеличен, часть public notes не обновилась, проценты
  -- attendance рассинхронизированы.
  -- Собираем plannedAttendanceMains/successfulAttendanceMains/failedAttendanceMains
  -- в основном цикле. После цикла: если failed пуст и #successful == #planned →
  -- apply attendance. Иначе: сохраняем last_attendance_mass_recovery для ручного
  -- retry через /gg attendance retry.
  local is_attendance = reason and reason:lower():find(Addon.ATTENDANCE_REASON:lower(), 1, true)
  local plannedAttendanceMains = {}     -- set: { [mainName] = true, ... }
  local successfulAttendanceMains = {}   -- set: { [mainName] = true, ... }
  local failedAttendanceMains = {}       -- set: { [mainName] = true, ... }
  local attendanceTargets = {}           -- { [mainName] = oldCount + 1, ... }
  local attendanceOldTotal = 0
  -- epTargets[main] = { amount=, reason=, isExtras=, sourceName= }
  -- Сохраняем ИСХОДНЫЕ параметры выдачи для каждого main. Retry использует их,
  -- а не пересчитывает через текущий состав рейда / IsInExtrasList.
  local epTargets = {}

  if is_attendance then
    attendanceOldTotal = Addon.data.attendance_total or 0
    -- attendanceTargets[main] будет заполняться в цикле при первом добавлении main в planned
  end

  -- Helper для отметки planned main (alt→main resolution, dedup).
  -- НЕ инкрементирует attendance сразу — только добавляет в planned set.
  local function mark_planned_attendance(name)
    if not is_attendance then return end
    local main = Addon:GetMain(name) or Addon.data.main_data[name] or name
    -- Alt резолвится в main; main добавляется только один раз
    if not plannedAttendanceMains[main] then
      plannedAttendanceMains[main] = true
      -- Target count = oldCount + 1 (idempotent — повтор retry записывает тот же target)
      local oldCount = Addon.data.attendance_data[main] or 0
      attendanceTargets[main] = oldCount + 1
    end
  end

  -- Helper для отметки successful/failed EP main.
  -- Сохраняем epTargets с исходными amount/reason/isExtras/sourceName.
  -- Параметры epInfo: { amount=, reason=, isExtras=, sourceName= } — nil если не attendance
  local function mark_ep_result(name, success, epInfo)
    if not is_attendance then return end
    local main = Addon:GetMain(name) or Addon.data.main_data[name] or name
    if success then
      successfulAttendanceMains[main] = true
      failedAttendanceMains[main] = nil  -- если был failed раньше, снимаем
    else
      failedAttendanceMains[main] = true
      -- Сохраняем исходные параметры для retry (не пересчитывать в retry)
      if epInfo then
        epTargets[main] = {
          amount = epInfo.amount,
          reason = epInfo.reason,
          isExtras = epInfo.isExtras,
          sourceName = epInfo.sourceName or name,
        }
      end
    end
  end

  -- Уведомляем Announce о начале массовки
  if Addon.Announce then
    Addon.Announce:OnMassStart(reason, amount)
  end

  -- Backup для возможности отмены (по аналогии с Decay)
  -- attendance_marked — флаг для отката счётчика посещаемости в RestoreMass.
  -- Расширяем backup для attendance undo:
  --   attendance_old_total — total до массовки (для отката @ATT_TOTAL)
  --   attendance_old_counts — { [main] = oldCount } (для отката public notes mains)
  --   attendance_targets — { [main] = newCount } (target counts — idempotent для retry)
  local att_marked = false
  if reason and reason:lower():find(Addon.ATTENDANCE_REASON:lower(), 1, true) then
    att_marked = true
  end
  last_mass_backup = {
    time    = time(),
    reason  = reason,
    amount  = amount,
    players = {},   -- имя -> значение Gold ДО начисления
    attendance_marked = att_marked,
    attendance_old_total = att_marked and (Addon.data.attendance_total or 0) or nil,
    attendance_old_counts = {},  -- заполняется ниже если att_marked
    attendance_targets = {},     -- заполняется в цикле (только если attendance applied)
  }
  for name in pairs(Addon.data.gold_data) do
    local gold = Addon.data.gold_data[name]
    if gold then
      last_mass_backup.players[name] = gold
    end
    -- Сохраняем oldCount для mains (alt's count is main's count)
    if att_marked and not Addon.data.main_data[name] then
      last_mass_backup.attendance_old_counts[name] = Addon.data.attendance_data[name] or 0
    end
  end
  if Addon.Log then
    local n = 0
    for _ in pairs(last_mass_backup.players) do n = n + 1 end
    Addon.Log:Info("MassGold backup created: %d players", n)
  end

  local awarded = {}
  local extras_awarded = {}
  local failed = {}
  local extras_amount = math.floor((Addon.db.profile.extras_p or 100) * 0.01 * amount)
  local extras_reason = reason .. " - Standby"

  -- Статистика по party-split
  local stats_full = 0      -- получили 100%
  local stats_reduced = 0   -- получили X% (6-8 пати)
  local stats_extras = 0    -- standby

  -- Идём по standings: используем gold_data (кэш всех игроков гильдии)
  -- + фильтр альтов через main_data — соответствует логике UI:GetStandingsSorted().
  -- Основной цикл в pcall — гарантируем сброс mass_in_progress при panic.
  local ok, panic_err = pcall(function()
  for name in pairs(Addon.data.gold_data) do
    -- Alt получает EP если main НЕ в рейде (alt как представитель main)
    if Addon.data.main_data[name] then
      local main_name = Addon.data.main_data[name]
      if Addon.state.raid_members[main_name] then
        -- main в рейде — пропускаем alt (main получит EP)
      elseif Addon:IsInAwardList(name) then
        -- main НЕ в рейде — начисляем alt (IncGold резолвит alt→main)
        local gold, gp, main = Addon:GetMemberData(name)
        local main_resolved = main or name
        if gold == nil then
          tinsert(failed, { name = name, reason = "no_data" })
          Addon.Log:Warn("Mass Gold: alt %s in award list but no data", name)
        elseif not awarded[main_resolved] and not extras_awarded[main_resolved] then
          if Addon:IsInExtrasList(name) then
            local result = Award:IncGold(name, extras_reason, extras_amount, true)
            if result then
              extras_awarded[result] = true
              stats_extras = stats_extras + 1
              -- Откладываем attendance до полного успеха EP
              mark_planned_attendance(name)
              mark_ep_result(name, true)
              if Addon.Announce then
                Addon.Announce:OnMassAward(name, extras_amount, true, false)
              end
            else
              tinsert(failed, { name = name, reason = "inc_failed" })
              mark_planned_attendance(name)
              -- Передаём исходные параметры для retry
              mark_ep_result(name, false, {
                amount = extras_amount, reason = extras_reason,
                isExtras = true, sourceName = name,
              })
            end
          else
            local actual_amount, multiplier = Addon:GetPartyAdjustedAmount(name, amount)
            local sg = Addon:GetSubgroup(name)
            local reason_with_party = reason
            local is_reduced = false
            if multiplier < 1.0 and sg then
              reason_with_party = string.format("%s (P%d, %d%%)", reason, sg, math.floor(multiplier * 100))
              is_reduced = true
            end
            local result = Award:IncGold(name, reason_with_party, actual_amount, true)
            if result then
              awarded[result] = true
              if is_reduced then
                stats_reduced = stats_reduced + 1
              else
                stats_full = stats_full + 1
              end
              -- Откладываем attendance до полного успеха EP
              mark_planned_attendance(name)
              mark_ep_result(name, true)
              if Addon.Announce then
                Addon.Announce:OnMassAward(name, actual_amount, false, is_reduced)
              end
            else
              tinsert(failed, { name = name, reason = "inc_failed" })
              mark_planned_attendance(name)
              -- Передаём исходные параметры для retry
              mark_ep_result(name, false, {
                amount = actual_amount, reason = reason_with_party,
                isExtras = false, sourceName = name,
              })
            end
          end
        end
      end
    elseif Addon:IsInAwardList(name) then
      local gold, gp, main = Addon:GetMemberData(name)
      local main_resolved = main or name
      if gold == nil then
        tinsert(failed, { name = name, reason = "no_data" })
        Addon.Log:Warn("Mass Gold: %s in award list but no data (alt of unknown main?)", name)
      elseif not awarded[main_resolved] and not extras_awarded[main_resolved] then
        if Addon:IsInExtrasList(name) then
          local result = Award:IncGold(name, extras_reason, extras_amount, true)
          if result then
            extras_awarded[result] = true
            stats_extras = stats_extras + 1
            -- Откладываем attendance
            mark_planned_attendance(name)
            mark_ep_result(name, true)
            if Addon.Announce then
              Addon.Announce:OnMassAward(name, extras_amount, true, false)
            end
          else
            tinsert(failed, { name = name, reason = "inc_failed" })
            mark_planned_attendance(name)
            -- Передаём исходные параметры для retry
            mark_ep_result(name, false, {
              amount = extras_amount, reason = extras_reason,
              isExtras = true, sourceName = name,
            })
          end
        else
          local actual_amount, multiplier = Addon:GetPartyAdjustedAmount(name, amount)
          local sg = Addon:GetSubgroup(name)
          local reason_with_party = reason
          local is_reduced = false
          if multiplier < 1.0 and sg then
            reason_with_party = string.format("%s (P%d, %d%%)", reason, sg, math.floor(multiplier * 100))
            is_reduced = true
          end
          local result = Award:IncGold(name, reason_with_party, actual_amount, true)
          if result then
            awarded[result] = true
            if is_reduced then
              stats_reduced = stats_reduced + 1
            else
              stats_full = stats_full + 1
            end
            -- Откладываем attendance
            mark_planned_attendance(name)
            mark_ep_result(name, true)
            if Addon.Announce then
              Addon.Announce:OnMassAward(name, actual_amount, false, is_reduced)
            end
          else
            tinsert(failed, { name = name, reason = "inc_failed" })
            mark_planned_attendance(name)
            -- Передаём исходные параметры для retry
            mark_ep_result(name, false, {
              amount = actual_amount, reason = reason_with_party,
              isExtras = false, sourceName = name,
            })
          end
        end
      end
      -- Если main уже получил — корректно пропускаем (это не ошибка)
    end
  end
  end)  -- конец pcall вокруг основного цикла

  -- finally: сброс флага reentrancy в любом случае (success или panic)
  mass_in_progress = false

  if not ok then
    -- panic в основном цикле — закрываем Announce-сессию и возвращаем ошибку
    if Addon.Announce then Addon.Announce:OnMassEnd() end
    if Addon.Log then
      Addon.Log:Error("MassGold panic: %s", tostring(panic_err))
    end
    Addon.PrintError("Массовка упала с ошибкой: " .. tostring(panic_err))
    Addon:Fire("MassGoldDone")
    return {
      awarded = awarded,
      extras = extras_awarded,
      failed = failed,
      error = "panic",
      stats = { full = stats_full, reduced = stats_reduced, extras = stats_extras },
    }
  end

  -- Уведомляем Announce о завершении массовки
  if Addon.Announce then
    Addon.Announce:OnMassEnd()
  end

  -- Логируем результат
  local awarded_count = 0
  for _ in pairs(awarded) do awarded_count = awarded_count + 1 end
  local failed_names = {}
  for _, f in ipairs(failed) do tinsert(failed_names, f.name) end
  Addon.Log:MassAwardEnd(reason, amount, awarded_count, #failed, failed_names)

  -- Apply attendance phase ПОСЛЕ полного успеха EP phase.
  -- Правило: attendance засчитывается только если массовое начисление EP завершилось
  -- успешно для всех запланированных получателей attendance.
  -- Если #failed == 0 AND #successfulAttendanceMains == #plannedAttendanceMains → apply.
  -- Иначе: сохраняем last_attendance_mass_recovery для ручного retry.
  local attendanceApplied = false
  local plannedCount = 0
  local successCount = 0
  local failedCount = 0
  for _ in pairs(plannedAttendanceMains) do plannedCount = plannedCount + 1 end
  for _ in pairs(successfulAttendanceMains) do successCount = successCount + 1 end
  for _ in pairs(failedAttendanceMains) do failedCount = failedCount + 1 end

  if is_attendance then
    if #failed == 0 and failedCount == 0 and successCount == plannedCount and plannedCount > 0 then
      -- Полный успех EP — применяем attendance phase.
      -- 1. @ATT_TOTAL++ в GuildInfo
      -- 2. SetPublicNote для каждого planned main с target count (idempotent)
      -- 3. Обновляем локальный attendance_data cache
      -- 4. Запрос GuildRoster() для подтверждения
      -- Проверяем return values. Если SetGuildInfoAttendance
      --   или SetPublicNote вернул false — НЕ считаем attendance завершённой,
      --   сохраняем recovery для retry.
      local newTotal = attendanceOldTotal + 1
      local gi_ok = Addon:SetGuildInfoAttendance(newTotal)
      if not gi_ok then
        -- SetGuildInfoAttendance failed — сохраняем recovery, не меняем attendance
        last_attendance_mass_recovery = {
          id = time(),
          reason = reason, amount = amount,
          extras_amount = extras_amount, extras_reason = extras_reason,
          plannedMains = plannedAttendanceMains,
          epSucceededMains = successfulAttendanceMains,
          epFailedMains = failedAttendanceMains,
          attendanceApplied = false,
          attendanceTargets = attendanceTargets,
          attendanceOldTotal = attendanceOldTotal,
          epTargets = epTargets,
        }
        Addon.PrintError("Attendance не засчитан: SetGuildInfoAttendance failed (нет прав или Storage). " ..
          "Используйте /gg attendance retry после восстановления Storage.")
        if Addon.Log then
          Addon.Log:Warn("MassGold: SetGuildInfoAttendance failed — recovery сохранён")
        end
      else
        local allNotesOk = true
        for main, targetCount in pairs(attendanceTargets) do
          local pn_ok = true
          if Addon.Storage and Addon.Storage.SetPublicNote then
            pn_ok = Addon.Storage:SetPublicNote(main, targetCount)
          end
          if pn_ok then
            if Addon.data.attendance_data then
              Addon.data.attendance_data[main] = targetCount
            end
            if Addon.db and Addon.db.global and Addon.db.global.attendance_data then
              Addon.db.global.attendance_data[main] = targetCount
            end
            -- Заполняем attendance_targets в backup для RestoreMass
            last_mass_backup.attendance_targets[main] = targetCount
          else
            allNotesOk = false
          end
        end
        if not allNotesOk then
          -- Не все public notes записаны — сохраняем recovery
          last_attendance_mass_recovery = {
            id = time(),
            reason = reason, amount = amount,
            extras_amount = extras_amount, extras_reason = extras_reason,
            plannedMains = plannedAttendanceMains,
            epSucceededMains = successfulAttendanceMains,
            epFailedMains = failedAttendanceMains,
            attendanceApplied = false,
            attendanceTargets = attendanceTargets,
            attendanceOldTotal = attendanceOldTotal,
            epTargets = epTargets,
          }
          Addon.PrintError("Attendance не засчитан: не все public notes записаны. " ..
            "Используйте /gg attendance retry после восстановления Storage.")
          if Addon.Log then
            Addon.Log:Warn("MassGold: some SetPublicNote failed — recovery сохранён")
          end
        else
          -- Обновляем локальный total cache
          Addon.data.attendance_total = newTotal
          if Addon.db and Addon.db.global then
            Addon.db.global.attendance_total = newTotal
          end
          -- Запрос roster для подтверждения server-side
          GuildRoster()
          attendanceApplied = true
          if Addon.Log then
            Addon.Log:Info("Attendance applied: %d mains, @ATT_TOTAL=%d (reason='%s')",
              plannedCount, newTotal, tostring(reason))
          end
          Addon.Print(string.format("Attendance засчитан: %d участников, @ATT_TOTAL = %d",
            plannedCount, newTotal))
          -- Очищаем recovery (если был от прошлой попытки)
          last_attendance_mass_recovery = nil
        end
      end
    else
      -- Partial или full EP failure — НЕ применяем attendance.
      -- Сохраняем recovery для ручного retry через /gg attendance retry.
      last_attendance_mass_recovery = {
        id = time(),
        reason = reason,
        amount = amount,
        extras_amount = extras_amount,
        extras_reason = extras_reason,
        plannedMains = plannedAttendanceMains,
        epSucceededMains = successfulAttendanceMains,
        epFailedMains = failedAttendanceMains,
        attendanceApplied = false,
        attendanceTargets = attendanceTargets,
        attendanceOldTotal = attendanceOldTotal,
        -- epTargets — исходные параметры для retry
        epTargets = epTargets,
      }
      Addon.PrintError(string.format(
        "Attendance не засчитан: EP записан не всем участникам. EP успешно: %d, неуспешно: %d. " ..
        "Используйте /gg attendance retry после восстановления Storage.",
        successCount, failedCount))
      if Addon.Log then
        Addon.Log:Warn("Attendance NOT applied: EP success=%d, failed=%d, planned=%d",
          successCount, failedCount, plannedCount)
      end
    end
  end

  -- Логируем party-split статистику
  if Addon.db.profile.party_split_enabled and stats_reduced > 0 then
    local pct = Addon.db.profile.party_split_percent or 50
    local threshold = Addon.db.profile.party_split_threshold or 5
    Addon.Log:Info("Party split: %d full (%d%%), %d reduced (%d%%, P%d+), %d extras",
      stats_full, 100, stats_reduced, pct, threshold + 1, stats_extras)
  end

  -- Сообщаем в чат
  if #failed > 0 then
    Addon.PrintError(string.format("! Массовка: %d OK, %d FAILED: %s",
      awarded_count, #failed, table.concat(failed_names, ", ")))
    Addon.PrintError("Повторите через 5 сек или начислите вручную: /gg gold <name> <amount> <reason>")
  else
    -- Если включён party-split — показываем расширенную статистику
    if Addon.db.profile.party_split_enabled and stats_reduced > 0 then
      local pct = Addon.db.profile.party_split_percent or 50
      local reduced_amount = math.floor(amount * pct / 100)
      Addon.Print(string.format("OK Массовка '%s': +%d EP -> %d игрокам (P1-5), +%d EP -> %d игрокам (P6-8), +%d -> %d standby",
        reason, amount, stats_full, reduced_amount, stats_reduced, extras_amount, stats_extras))
    else
      Addon.Print(string.format("OK Массовка +%d EP '%s' — %d игроков", amount, reason, awarded_count))
    end
  end

  -- Уведомляем UI о завершении массовки (чтобы показать кнопку "Отменить")
  Addon:Fire("MassGoldDone")

  -- Defensive: флаг уже сброшен в finally после pcall, но дублируем
  -- перед финальным return для надёжности.
  mass_in_progress = false

  return {
    awarded = awarded,
    extras = extras_awarded,
    failed = failed,
    stats = {
      full = stats_full,
      reduced = stats_reduced,
      extras = stats_extras,
    }
  }
end

-- ============================================================================
-- DECAY (срез EP/GP на %)
-- ============================================================================

-- Backup перед срезом
-- Сохраняет snapshot всех Gold/GP до среза для возможности восстановления

local function CreateDecayBackup()
  last_decay_backup = {
    time = time(),
    data = {},
  }
  -- Храним RAW значения из Addon.data, а не данные GetMemberData
  -- (который добавляет base_gp к gp). Restore должен получить исходную officer note
  -- без двойного вычитания base_gp.
  -- Добавляем в backup ТОЛЬКО mains. У alts officer note содержит
  -- имя main'а (не "Gold,GP"), поэтому decay/reset не должен записывать числовую note
  -- альту — это уничтожит связь alt → main. Skip entries where Addon.data.main_data[name] ~= nil.
  for name in pairs(Addon.data.gold_data) do
    if not Addon.data.main_data[name] then
      -- Это main (не alt) — добавляем в backup
      local raw_gold, raw_gp = GetRawMemberData(name)
      if raw_gold ~= nil and raw_gp ~= nil then
        -- Сохраняем onLeave для restore marker'а
        last_decay_backup.data[name] = {
          gold = raw_gold, gp = raw_gp,
          onLeave = Addon.data.on_leave and Addon.data.on_leave[name] == true or false,
        }
      end
    end
  end
  if Addon.Log then
    local count = 0
    for _ in pairs(last_decay_backup.data) do count = count + 1 end
    Addon.Log:Info("Decay backup created (raw values, mains only): %d players", count)
  end
end

-- Восстановление после среза
-- RestoreDecay использует GetRawMemberData (не GetMemberData),
--   чтобы deltas считались в raw пространстве. GetMemberData добавляет base_gp к gp,
--   что приводило к ошибке восстановления на величину base_gp.
--   Callback'и передают undo=true (5-й arg) — чтобы announcement не публиковал
--   restore как обычное начисление, и history правильно помечала операцию отмены.
function Award:RestoreDecay()
  if not last_decay_backup then
    Addon.PrintError("Нет backup для восстановления (срез не выполнялся)")
    return false
  end
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты!")
    return false
  end
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов!")
    return false
  end

  local reason = "Восстановление после среза"
  local count = 0
  local failed = {}
  -- Итерируем только mains (backup уже содержит только mains,
  -- но дублируем проверку для safety).
  for name, values in pairs(last_decay_backup.data) do
    if not Addon.data.main_data[name] then
      -- Восстанавливаем on_leave flag из backup ПЕРЕД AddGoldGP,
      -- чтобы EncodeNote внутри AddGoldGP корректно добавил [ОТП] маркер.
      if values.onLeave then
        if not Addon.data.on_leave then Addon.data.on_leave = {} end
        Addon.data.on_leave[name] = true
      else
        if Addon.data.on_leave then Addon.data.on_leave[name] = nil end
      end
      -- GetRawMemberData вместо GetMemberData — БЕЗ base_gp
      local currentRawGold, currentRawGP = GetRawMemberData(name)
      if currentRawGold ~= nil and currentRawGP ~= nil then
        -- Deltas в raw пространстве
        local gold_delta = values.gold - currentRawGold
        local gp_delta = values.gp - currentRawGP
        if gold_delta ~= 0 or gp_delta ~= 0 then
          local actual_g, actual_p, err = AddGoldGP(name, gold_delta, gp_delta)
          if err then
            tinsert(failed, name)
          else
            -- Передаём undo=true как 5-й arg (mass=false 4-й arg)
            -- чтобы announcement/history помечали операцию как undo.
            if actual_g and actual_g ~= 0 then
              Addon:Fire("GoldAward", name, reason, actual_g, true, true)
            end
            if actual_p and actual_p ~= 0 then
              Addon:Fire("GPAward", name, reason, actual_p, true, true)
            end
            count = count + 1
          end
        else
          -- Delta = 0 — уже восстановлен (partial restore scenario), не дублируем callback
          -- Но всё равно перезаписываем note для восстановления [ОТП] маркера
          -- если on_leave изменился. AddGoldGP с delta=0 не вызывается, поэтому пишем note напрямую.
          if Addon.Storage and Addon.Storage.SetNote then
            local restore_note = EncodeRawNote(values.gold, values.gp, name)
            Addon.Storage:SetNote(name, restore_note)
          end
          count = count + 1
        end
      else
        tinsert(failed, name)
      end
    end
  end

  if #failed > 0 then
    Addon.PrintError(string.format(
      "Восстановлено %d игроков, НО %d пропущено (pending full): %s. Повторите /gg restoredecay через 2 сек.",
      count, #failed, table.concat(failed, ", ")))
    Addon.Log:Warn("RestoreDecay: %d failed (pending full): %s", #failed, table.concat(failed, ", "))
    -- НЕ очищаем last_decay_backup — позволяем повторить
    return false
  end

  Addon.Print(string.format("OK Восстановлено %d игроков до состояния от %s",
    count, date("%H:%M:%S", last_decay_backup.time)))
  last_decay_backup = nil
  Addon:Fire("RestoreDone")
  return true
end

-- Восстановление после массовки (Undo Mass Gold)
-- Откат attendance_total если массовка была attendance-marked.
-- RestoreMass attendance undo через attendance_old_counts/attendance_old_total
--   (не current - 1, а конкретные old values из backup). Серверные public notes восстанавливаются.
function Award:RestoreMass()
  if not last_mass_backup then
    Addon.PrintError("Нет backup для отмены (массовка не выполнялась или уже отменена)")
    return false
  end
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты!")
    return false
  end
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов! Подождите несколько секунд и повторите.")
    return false
  end

  local reason = "Отмена массовки: " .. (last_mass_backup.reason or "?")
  local count  = 0
  local failed = {}

  -- Сначала восстанавливаем EP (через deltas как в RestoreDecay/Reset).
  -- Только после полного успеха EP — восстанавливаем attendance public notes и @ATT_TOTAL.
  for name, gold_before in pairs(last_mass_backup.players) do
    -- Пропускаем альтов — их Gold привязан к main, восстановление main'а достаточно.
    if not Addon.data.main_data[name] then
      local gold_now = Addon.data.gold_data[name]
      if gold_now ~= nil then
        local delta = gold_before - gold_now
        if delta ~= 0 then
          local ok = Award:IncGold(name, reason, delta, true, true)
          if ok then
            count = count + 1
          else
            tinsert(failed, name)
          end
        end
      end
    end
  end

  -- Attendance undo — только при полном успехе EP restore.
  -- Используем attendance_old_counts (не current - 1) — восстанавливаем конкретные
  -- server-side public notes. Это идемпотентно: повтор даёт тот же old count.
  -- Проверяем return values от SetPublicNote и SetGuildInfoAttendance.
  --   Если false — не очищаем backup, не считаем attendance undo завершённой.
  if #failed == 0 and last_mass_backup.attendance_marked then
    local attUndoFailed = false
    -- Восстанавливаем public notes для всех mains из attendance_old_counts
    if last_mass_backup.attendance_old_counts and Addon.Storage and Addon.Storage.SetPublicNote then
      for main, oldCount in pairs(last_mass_backup.attendance_old_counts) do
        -- Проверяем что main был в planned attendance (т.к. backup мог быть создан
        -- для всех mains, но attendance phase могла не примениться)
        if last_mass_backup.attendance_targets and last_mass_backup.attendance_targets[main] then
          -- Attendance была применена — восстанавливаем old count
          local pn_ok = Addon.Storage:SetPublicNote(main, oldCount)
          if pn_ok then
            if Addon.data.attendance_data then
              Addon.data.attendance_data[main] = oldCount
            end
            if Addon.db and Addon.db.global and Addon.db.global.attendance_data then
              Addon.db.global.attendance_data[main] = oldCount
            end
          else
            attUndoFailed = true
            if Addon.Log then
              Addon.Log:Warn("RestoreMass: SetPublicNote failed for %s — backup сохранён", tostring(main))
            end
          end
        end
      end
    end
    -- Восстанавливаем @ATT_TOTAL
    if last_mass_backup.attendance_old_total then
      local gi_ok = Addon:SetGuildInfoAttendance(last_mass_backup.attendance_old_total)
      if gi_ok then
        if Addon.db and Addon.db.global then
          Addon.db.global.attendance_total = last_mass_backup.attendance_old_total
          Addon.data.attendance_total = last_mass_backup.attendance_old_total
        end
        if Addon.Log then
          Addon.Log:Info("Attendance total restored: %d (undo mass)", last_mass_backup.attendance_old_total)
        end
      else
        attUndoFailed = true
        if Addon.Log then
          Addon.Log:Warn("RestoreMass: SetGuildInfoAttendance failed — backup сохранён")
        end
      end
    end
    -- Запрос roster для подтверждения server-side
    GuildRoster()
    if attUndoFailed then
      Addon.PrintError("Attendance undo: не все public notes/GuildInfo записаны. " ..
        "Повторите /gg undo через 2 сек. Backup сохранён.")
      -- НЕ очищаем last_mass_backup — позволяем повторить
      return false
    end
  end

  if #failed > 0 then
    Addon.PrintError(string.format(
      "Восстановлено %d игроков, НО %d пропущено (pending full): %s. Повторите /gg undo через 2 сек.",
      count, #failed, table.concat(failed, ", ")))
    Addon.Log:Warn("RestoreMass: %d failed (pending full): %s", #failed, table.concat(failed, ", "))
    -- НЕ очищаем last_mass_backup — позволяем повторить
    -- НЕ вызываем RestoreDone — восстановление не завершено
    return false
  end

  Addon.Print(string.format("OK Массовка отменена: восстановлено %d игроков (было %s, %d EP)",
    count,
    date("%H:%M:%S", last_mass_backup.time),
    last_mass_backup.amount))

  -- Очищаем recovery если MassGold backup был связан с attendance
  last_attendance_mass_recovery = nil

  last_mass_backup = nil
  Addon.Log:Info("RestoreMass completed: %d restored, %d failed", count, #failed)
  Addon:Fire("RestoreDone")
  return true
end

-- RetryAttendanceMass — ручная команда офицера для повтора
-- частично неуспешной attendance mass operation.
-- НЕ начисляет EP повторно успешным игрокам.
-- Обрабатывает ТОЛЬКО epFailedMains. После успешной записи всех EP — применяет
-- attendance phase один раз для всех planned mains (используя attendanceTargets для
-- idempotent target counts).
-- Retry использует ИСХОДНЫЕ amount/reason/isExtras/sourceName
--   из recovery.epTargets[main] — НЕ пересчитывает через текущий состав рейда /
--   IsInExtrasList. Это важно для alt, standby и party split.
-- При обходе epFailedMains НЕ удаляем элементы из той же таблицы внутри pairs().
--   Сначала собираем имена в массив, затем обрабатываем массив, затем удаляем успешно обработанные.
-- После успешного retry заполняем last_mass_backup.attendance_targets —
--   иначе RestoreMass не увидит изменённые attendance targets.
-- SetGuildInfoAttendance и SetPublicNote возвращают true/false — проверяем.
function Award:RetryAttendanceMass()
  if not last_attendance_mass_recovery then
    Addon.PrintError("Нет recovery для повтора (массовка не была частично неуспешной или уже завершена)")
    return false
  end
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты!")
    return false
  end
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов! Подождите несколько секунд и повторите.")
    return false
  end

  local recovery = last_attendance_mass_recovery
  -- Используем epTargets если есть, иначе fallback к общим reason/amount
  local epTargets = recovery.epTargets or {}

  -- Собираем epFailedMains в массив (safe iteration — не удаляем из pairs())
  local failedMainsSnapshot = {}
  for main, _ in pairs(recovery.epFailedMains) do
    tinsert(failedMainsSnapshot, main)
  end

  if #failedMainsSnapshot == 0 then
    -- Все EP уже успешно записаны — нужно только применить attendance phase
    if not recovery.attendanceApplied then
      -- Проверяем return values от SetGuildInfoAttendance и SetPublicNote
      local newTotal = (recovery.attendanceOldTotal or 0) + 1
      local gi_ok = Addon:SetGuildInfoAttendance(newTotal)
      if not gi_ok then
        Addon.PrintError("Attendance retry: SetGuildInfoAttendance failed — recovery сохранён")
        return false
      end
      local allNotesOk = true
      for main, targetCount in pairs(recovery.attendanceTargets) do
        local pn_ok = true
        if Addon.Storage and Addon.Storage.SetPublicNote then
          pn_ok = Addon.Storage:SetPublicNote(main, targetCount)
        end
        if pn_ok then
          if Addon.data.attendance_data then
            Addon.data.attendance_data[main] = targetCount
          end
          if Addon.db and Addon.db.global and Addon.db.global.attendance_data then
            Addon.db.global.attendance_data[main] = targetCount
          end
          -- Заполняем attendance_targets в last_mass_backup для RestoreMass
          if last_mass_backup then
            last_mass_backup.attendance_targets[main] = targetCount
          end
        else
          allNotesOk = false
        end
      end
      if not allNotesOk then
        Addon.PrintError("Attendance retry: не все public notes записаны — recovery сохранён")
        return false
      end
      Addon.data.attendance_total = newTotal
      if Addon.db and Addon.db.global then
        Addon.db.global.attendance_total = newTotal
      end
      GuildRoster()
      Addon.Print(string.format("Attendance записан без повторного начисления EP. @ATT_TOTAL = %d", newTotal))
      last_attendance_mass_recovery = nil
      return true
    end
    -- attendance уже применена — просто очищаем recovery
    last_attendance_mass_recovery = nil
    Addon.Print("Attendance retry: EP уже успешен и attendance уже применена — recovery очищена")
    return true
  end

  -- Retry EP для epFailedMains используя ИСХОДНЫЕ параметры из epTargets.
  -- Итерируем по snapshot массиву, а не pairs(recovery.epFailedMains) — безопасное удаление.
  local epFailed = {}
  local epSucceeded = {}
  local succeededMains = {}  -- массив успешно обработанных для удаления после цикла
  for _, main in ipairs(failedMainsSnapshot) do
    -- Проверяем что main действительно в planned (defense-in-depth)
    if recovery.plannedMains[main] then
      -- Берём исходные параметры из epTargets[main], если есть;
      -- иначе fallback к общим reason/amount
      local epInfo = epTargets[main]
      local result
      if epInfo then
        -- Используем ИСХОДНЫЕ amount/reason/isExtras
        result = Award:IncGold(epInfo.sourceName or main, epInfo.reason, epInfo.amount, true)
      else
        -- Fallback (если epTargets не было сохранён — старые recovery)
        local isExtras = Addon:IsInExtrasList(main)
        if isExtras then
          result = Award:IncGold(main, recovery.extras_reason or (recovery.reason .. " - Standby"),
            recovery.extras_amount or 0, true)
        else
          local actual_amount = Addon:GetPartyAdjustedAmount(main, recovery.amount or 0)
          result = Award:IncGold(main, recovery.reason or "Приход на рт", actual_amount, true)
        end
      end
      if result then
        epSucceeded[main] = true
        tinsert(succeededMains, main)
      else
        epFailed[main] = true
      end
    end
  end

  -- Удаляем успешно обработанные mains из recovery.epFailedMains
  -- (после итерации, не во время pairs())
  for _, main in ipairs(succeededMains) do
    recovery.epFailedMains[main] = nil
  end
  -- Добавляем к epSucceededMains
  for main, _ in pairs(epSucceeded) do
    recovery.epSucceededMains[main] = true
  end

  local failedCount = 0
  for _ in pairs(epFailed) do failedCount = failedCount + 1 end
  local successCount = 0
  for _ in pairs(epSucceeded) do successCount = successCount + 1 end

  if failedCount > 0 then
    Addon.PrintError(string.format(
      "Attendance retry: EP успешно повторно для %d mains, НО %d всё ещё failed. " ..
      "Повторите /gg attendance retry через 2 сек.",
      successCount, failedCount))
    -- НЕ очищаем recovery — позволяем повторить
    return false
  end

  -- Все EP теперь успешны — применяем attendance phase
  -- Проверяем return values от SetGuildInfoAttendance и SetPublicNote
  local newTotal = (recovery.attendanceOldTotal or 0) + 1
  local gi_ok = Addon:SetGuildInfoAttendance(newTotal)
  if not gi_ok then
    Addon.PrintError("Attendance retry: SetGuildInfoAttendance failed — recovery сохранён, EP не повторяется")
    return false
  end
  local allNotesOk = true
  for main, targetCount in pairs(recovery.attendanceTargets) do
    local pn_ok = true
    if Addon.Storage and Addon.Storage.SetPublicNote then
      pn_ok = Addon.Storage:SetPublicNote(main, targetCount)
    end
    if pn_ok then
      if Addon.data.attendance_data then
        Addon.data.attendance_data[main] = targetCount
      end
      if Addon.db and Addon.db.global and Addon.db.global.attendance_data then
        Addon.db.global.attendance_data[main] = targetCount
      end
      -- Заполняем attendance_targets в last_mass_backup для RestoreMass
      if last_mass_backup then
        last_mass_backup.attendance_targets[main] = targetCount
      end
    else
      allNotesOk = false
    end
  end
  if not allNotesOk then
    Addon.PrintError("Attendance retry: не все public notes записаны — recovery сохранён, EP не повторяется")
    return false
  end
  Addon.data.attendance_total = newTotal
  if Addon.db and Addon.db.global then
    Addon.db.global.attendance_total = newTotal
  end
  GuildRoster()
  Addon.Print(string.format("Attendance записан без повторного начисления EP. @ATT_TOTAL = %d", newTotal))

  -- Очищаем recovery
  last_attendance_mass_recovery = nil
  Addon.Log:Info("Attendance retry completed: %d EP retry, attendance applied", successCount)
  return true
end

-- Геттер для UI (есть ли recovery для повтора)
function Award:HasAttendanceRecovery() return last_attendance_mass_recovery ~= nil end

-- Геттеры для UI (кнопка "Отменить" показывается только если есть backup)
function Award:HasMassBackup()  return last_mass_backup ~= nil end
function Award:HasDecayBackup() return last_decay_backup ~= nil end

-- Decay с подтверждением
function Award:DecayWithConfirm()
  local decay_p = Addon.db.profile.decay_p or 0
  if decay_p == 0 then
    Addon.Print("Decay = 0% (настроено в GuildInfo через @DECAY_P)")
    return
  end
  -- Диалог подтверждения
  StaticPopupDialogs["GOLDGP_DECAY_CONFIRM"] = {
    text = "|cFFFFD700ВНИМАНИЕ!|r\nПрименить срез %d%% ко всем игрокам?\n\n|cFFFF5050Это действие уменьшит EP/GP всех игроков (кроме тех, кто в отпуске).|r\n\nПеред срезом будет создан backup для возможности отмены.",
    button1 = "Да, сделать срез",
    button2 = "Отмена",
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    OnAccept = function()
      Award:Decay()
    end,
  }
  StaticPopup_Show("GOLDGP_DECAY_CONFIRM", decay_p)
end

function Award:Decay()
  -- Гильд-лок
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — срез невозможен")
    return false
  end
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты!")
    return false
  end
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов!")
    return false
  end
  local decay_p = Addon.db.profile.decay_p or 0
  if decay_p == 0 then
    Addon.Print("Decay = 0% (настроено в GuildInfo через @DECAY_P)")
    return false
  end

  -- Создаём backup перед срезом
  CreateDecayBackup()

  local decay = decay_p * 0.01
  local reason = string.format("Decay %d%%", decay_p)
  Addon.Log:Info("Starting decay %d%%", decay_p)

  local count = 0
  local failed = {}
  -- Decay только mains. Alts имеют officer note = "MainName",
  -- поэтому decay не должен записывать числовую note альту (уничтожит связь alt→main).
  -- Расчёт GP через rawGP (не displayed GP = raw + base_gp), т.к. base_gp не хранится
  -- в officer note — decay должен вычисляться от raw значения.
  for name in pairs(Addon.data.gold_data) do
    if Addon:IsOnLeave(name) then
      Addon.Log:Debug("Decay: skip %s (on leave)", name)
    elseif Addon.data.main_data[name] then
      -- Skip alts — не записываем числовую note альту
      Addon.Log:Debug("Decay: skip %s (alt of %s)", name, tostring(Addon.data.main_data[name]))
    else
      -- GetRawMemberData вместо GetMemberData — БЕЗ base_gp
      local rawGold, rawGP = GetRawMemberData(name)
      if rawGold and rawGP then
        local decay_gold = math.ceil(rawGold * decay)
        local decay_gp = math.ceil(rawGP * decay)
        local actual_g, actual_p, err = AddGoldGP(name, -decay_gold, -decay_gp)
        if err then
          tinsert(failed, name)
        else
          if actual_g and actual_g ~= 0 then
            Addon:Fire("GoldAward", name, reason, actual_g, true)
          end
          if actual_p and actual_p ~= 0 then
            Addon:Fire("GPAward", name, reason, actual_p, true)
          end
        count = count + 1
      end
    end
    end
  end

  Addon:Fire("Decay", decay_p)
  Addon:BumpCacheVersion()
  if #failed > 0 then
    Addon.PrintError(string.format("Decay %d%% применён к %d игрокам, НО %d пропущено (pending full): %s",
      decay_p, count, #failed, table.concat(failed, ", ")))
  else
    Addon.Print(string.format("OK Decay %d%% применён к %d игрокам", decay_p, count))
  end
  return true
end

-- ============================================================================
-- RESET
-- ============================================================================
-- Reset с backup + журнал + обновление кэша (как у Decay)

function Award:ResetWithConfirm()
  StaticPopupDialogs["GOLDGP_RESET_CONFIRM"] = {
    text = "|cFFFF5050ВНИМАНИЕ!|r\nОбнулить ВСЕ EP/GP у всех игроков гильдии?\n\n|cFFFF5050Это действие установит 0 EP и 0 GP для всех.|r\n\nПеред сбросом будет создан backup для возможности отмены.",
    button1 = "Да, обнулить всё",
    button2 = "Отмена",
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    OnAccept = function()
      Award:Reset()
    end,
  }
  StaticPopup_Show("GOLDGP_RESET_CONFIRM")
end

function Award:RestoreReset()
  if not last_reset_backup then
    Addon.PrintError("Нет backup для восстановления (сброс не выполнялся)")
    return false
  end
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав на офицерские ноты!")
    return false
  end
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов!")
    return false
  end

  local reason = "Восстановление после сброса"
  local count = 0
  local failed = {}
  -- Проверяем возврат SetNote. Если pending queue полна — не мутируем кэш.
  -- Используем EncodeRawNote (backup хранит raw gp, не displayed).
  -- Только mains (backup уже содержит только mains, но дублируем проверку).
  -- Передаём undo=true как 5-й arg — history помечает операцию как undo.
  -- Считаем RAW deltas (values.gold - currentRawGold) вместо абсолютных values.gold:
  --   это корректно при partial restore (уже восстановленные
  --   mains дают delta 0 — не создаём второй history entry, не переписываем note).
  -- Передаём mass=true, undo=true (5-й и 6-й args).
  for name, values in pairs(last_reset_backup.data) do
    if not Addon.data.main_data[name] then
      -- Восстанавливаем on_leave flag из backup ПЕРЕД записью note,
      -- чтобы EncodeRawNote добавил [ОТП] маркер.
      if values.onLeave then
        if not Addon.data.on_leave then Addon.data.on_leave = {} end
        Addon.data.on_leave[name] = true
      else
        if Addon.data.on_leave then Addon.data.on_leave[name] = nil end
      end
      -- GetRawMemberData для расчёта delta
      local currentRawGold, currentRawGP = GetRawMemberData(name)
      if currentRawGold ~= nil and currentRawGP ~= nil then
        local goldDelta = values.gold - currentRawGold
        local gpDelta = values.gp - currentRawGP
        -- Если оба delta = 0 — уже восстановлен, не создаём history entry
        if goldDelta ~= 0 or gpDelta ~= 0 then
          -- Записываем target raw values в officer note
          -- Передаём name для сохранения [ОТП] маркера
          local new_note = EncodeRawNote(values.gold, values.gp, name)
          local set_ok = Addon.Storage:SetNote(name, new_note)
          if set_ok ~= nil then
            Addon.data.gold_data[name] = values.gold
            Addon.data.gp_data[name] = values.gp
            -- Передаём delta (не absolute), mass=true, undo=true
            if goldDelta ~= 0 then
              Addon:Fire("GoldAward", name, reason, goldDelta, true, true)
            end
            if gpDelta ~= 0 then
              Addon:Fire("GPAward", name, reason, gpDelta, true, true)
            end
            count = count + 1
          else
            tinsert(failed, name)
          end
        else
          -- Delta = 0 — уже восстановлен, не считаем failed,
          -- не создаём второй history entry, не переписываем note повторно.
          count = count + 1
        end
      else
        tinsert(failed, name)
      end
    end
  end

  if #failed > 0 then
    Addon.PrintError(string.format("Восстановлено %d игроков, НО %d пропущено (pending full): %s. Повторите /gg restorereset через 2 сек.",
      count, #failed, table.concat(failed, ", ")))
    Addon.Log:Warn("RestoreReset: %d failed (pending full): %s", #failed, table.concat(failed, ", "))
    -- НЕ очищаем last_reset_backup — позволяем повторить
    return false
  end

  Addon.Print(string.format("OK Восстановлено %d игроков до состояния от %s",
    count, date("%H:%M:%S", last_reset_backup.time)))
  last_reset_backup = nil
  Addon:Fire("RestoreDone")
  return true
end

function Award:Reset()
  if not CanEditOfficerNote() then
    Addon.PrintError("Нет прав!")
    return false
  end
  -- Проверка IsCurrentState (как в Decay/RestoreReset).
  if not Addon.Storage:IsCurrentState() then
    Addon.PrintError("Storage не готов! Подождите несколько секунд и повторите.")
    return false
  end

  -- Создаём backup перед сбросом
  -- Храним RAW значения из Addon.data (не GetMemberData,
  -- который добавляет base_gp к gp). Restore должен вернуть исходную officer note.
  -- Только mains — alts имеют officer note = "MainName",
  -- нельзя записывать числовую note альту (уничтожит связь alt→main).
  last_reset_backup = {
    time = time(),
    data = {},
  }
  for name in pairs(Addon.data.gold_data) do
    if not Addon.data.main_data[name] then
      local raw_gold, raw_gp = GetRawMemberData(name)
      if raw_gold ~= nil and raw_gp ~= nil then
        -- Сохраняем onLeave для restore marker'а
        last_reset_backup.data[name] = {
          gold = raw_gold, gp = raw_gp,
          onLeave = Addon.data.on_leave and Addon.data.on_leave[name] == true or false,
        }
      end
    end
  end
  if Addon.Log then
    local count = 0
    for _ in pairs(last_reset_backup.data) do count = count + 1 end
    Addon.Log:Info("Reset backup created (raw values, mains only): %d players", count)
  end

  -- zero_note генерируем per-name (внутри цикла) для сохранения [ОТП].
  -- Проверяем return SetNote — если nil (pending full), НЕ обновляем кэш.
  -- Только mains — alts имеют officer note = "MainName",
  -- нельзя записывать "0,0" альту (уничтожит связь alt→main).
  local reset_ok = 0
  local reset_failed = 0
  for name in pairs(Addon.data.gold_data) do
    if not Addon.data.main_data[name] then
      -- Генерируем zero_note per-name для сохранения [ОТП] маркера
      local zero_note = EncodeNote(0, 0, name)
      local ok = Addon.Storage:SetNote(name, zero_note)
      if ok ~= nil then
        -- Немедленно обновляем кэш (только если SetNote успешно)
        Addon.data.gold_data[name] = 0
        Addon.data.gp_data[name] = 0
        -- Записываем в журнал
        Addon:Fire("GoldAward", name, "Reset", 0, true)
        reset_ok = reset_ok + 1
      else
        reset_failed = reset_failed + 1
      end
    end
  end
  if reset_failed > 0 then
    Addon.PrintError(string.format("Reset: %d игроков не записано (pending full), %d OK. Повторите через 2-3 сек.",
      reset_failed, reset_ok))
  end
  -- Инвалидируем кэш standings
  Addon:BumpCacheVersion()
  Addon.Print("OK Reset: все EP/GP обнулены. /gg restore для отмены")
  return true
end

-- ============================================================================
-- RECURRING (периодические начисления)
-- ============================================================================
local recurring_frame = CreateFrame("Frame", "GoldGP_RecurringFrame")
recurring_frame:Hide()

local recurring_timeout = 0
local function RecurringTicker(self, elapsed)
  if not Addon.db then return end
  local vars = Addon.db.profile
  if not vars.next_award then return end

  -- time() (epoch), а не GetTime() (сессионное): time() переживает релог,
  -- GetTime() обнуляется при каждом входе в игру.
  local now = time()
  if now >= vars.next_award then
    -- Snapshot next_award перед MassGold — если callback MassGoldDone вызовет
    -- StopRecurring (vars.next_award = nil), строка ниже упадёт на arithmetic on nil.
    local na_reason = vars.next_award_reason
    local na_amount = vars.next_award_amount
    local na_period = vars.recurring_period_mins
    -- ПРОВЕРКА: storage должен быть CURRENT
    if Addon.Storage:IsCurrentState() then
      Addon.Log:RecurringTick(na_reason, na_amount, na_period)
      Award:MassGold(na_reason, na_amount)
      -- Обновляем статистику recurring для футера
      recurring_stats.total_ep = recurring_stats.total_ep + (na_amount or 0)
      recurring_stats.count = recurring_stats.count + 1
      -- Проверяем что recurring не остановлен callback'ом MassGoldDone.
      if vars.next_award and na_period then
        vars.next_award = vars.next_award + na_period * 60
      end
    else
      -- Абсолютное next_award = now + 5, не инкремент — иначе retry-лог
      -- спамится каждый кадр.
      Addon.Log:RecurringSkipped(na_reason)
      vars.next_award = now + 5  -- retry через 5 сек (абсолютное время)
    end
  end

  recurring_timeout = recurring_timeout + elapsed
  if recurring_timeout > 0.5 then
    recurring_timeout = 0
  end
end
recurring_frame:SetScript("OnUpdate", RecurringTicker)

function Award:StartRecurring(reason, amount)
  local vars = Addon.db.profile
  if vars.next_award then
    return false, "already running"
  end
  vars.next_award_reason = reason
  vars.next_award_amount = amount
  -- time() вместо GetTime() — переживает релог
  vars.next_award = time() + vars.recurring_period_mins * 60
  -- Сброс статистики recurring
  recurring_stats.total_ep = 0
  recurring_stats.count = 0
  recurring_frame:Show()
  Addon:Fire("StartRecurring", reason, amount, vars.recurring_period_mins)
  Addon.Log:Info("Recurring started: reason='%s' amount=%d period=%dm",
    reason, amount, vars.recurring_period_mins)
  return true
end

function Award:StopRecurring()
  local vars = Addon.db.profile
  vars.next_award_reason = nil
  vars.next_award_amount = nil
  vars.next_award = nil
  -- Сброс статистики recurring
  recurring_stats.total_ep = 0
  recurring_stats.count = 0
  recurring_frame:Hide()
  Addon:Fire("StopRecurring")
  Addon.Log:Info("Recurring stopped")
  return true
end

-- Геттер статистики recurring для футера /gg
function Award:GetRecurringStats()
  return recurring_stats.total_ep, recurring_stats.count
end

function Award:RunningRecurring()
  return Addon.db.profile.next_award ~= nil
end

-- Диалоги подтверждения для отмены массовки/среза
StaticPopupDialogs["GOLDGP_UNDO_MASS_CONFIRM"] = {
  text = "|cFFFFD700Отмена массовки|r\n\nВернуть EP всем участникам последней массовки?\n|cFFFF5050Это действие нельзя отменить повторно.|r",
  button1 = "Да, отменить",
  button2 = "Нет",
  timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnAccept = function() Addon.Award:RestoreMass() end,
}
StaticPopupDialogs["GOLDGP_UNDO_DECAY_CONFIRM"] = {
  text = "|cFFFFD700Отмена среза|r\n\nВернуть EP/GP всем игрокам до последнего среза?\n|cFFFF5050Это действие нельзя отменить повторно.|r",
  button1 = "Да, отменить",
  button2 = "Нет",
  timeout = 0, whileDead = 1, hideOnEscape = 1,
  OnAccept = function() Addon.Award:RestoreDecay() end,
}

if Addon.Log then Addon.Log:Info("GoldGP_Award loaded (v2.4.0)") end
