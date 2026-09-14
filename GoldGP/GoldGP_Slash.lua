-- GoldGP_Slash.lua

local Addon = GoldGP

local function print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r: " .. tostring(msg))
end

-- Единая реализация вывода ошибок из Core (print_err в этом файле — её алиас)
local print_err = Addon.PrintError

-- Флаг для обхода проверок при следующем /gg mass
local force_next = false

-- ============================================================================
-- ПАРСЕР КОМАНД
-- ============================================================================
local function handle_slash(msg)
  msg = msg or ""
  local args = {}
  for w in string.gmatch(msg, "%S+") do
    tinsert(args, w)
  end
  local cmd = args[1] and args[1]:lower() or ""

  -- Гильд-лок: при блокировке разрешены только служебные команды.
  -- rules/classdiag доступны и вне гильд-лока: правила гильдии смотрятся
  -- без ограничений, classdiag — read-only диагностика (ничего не изменяет)
  if Addon.IsEnabled and not Addon:IsEnabled()
     and cmd ~= "setguild" and cmd ~= "welcome" and cmd ~= "rules" and cmd ~= "help"
     and cmd ~= "classdiag" then
    print_err("GoldGP заблокирован гильд-локом — аддон работает только в разрешённой гильдии")
    print_err("Привязать к текущей гильдии: /gg setguild (доступно только вам)")
    return
  end

  if cmd == "" or cmd == "show" then
    if not Addon.UI then
      print_err("UI модуль не загружен! Проверьте что все файлы аддона на месте.")
      return
    end
    Addon.UI:Toggle()
    return

  elseif cmd == "hide" then
    if Addon.UI then Addon.UI:Hide() end

  elseif cmd == "refresh" then
    GuildRoster()
    print("Запрос гильдейского ростера...")

  elseif cmd == "state" then
    print("Storage state: " .. Addon.Storage:GetState())
    print("In raid: " .. (Addon.state.in_raid and "YES" or "NO"))
    print("Guild: " .. (Addon.guild_name or "?"))
    print("Members in cache: " .. (function()
      local n = 0
      for _ in pairs(Addon.data.gold_data) do n = n + 1 end
      return n
    end)())

  elseif cmd == "stats" then
    local s = Addon.Storage:GetStats()
    print(string.format("State: %s", s.state))
    print(string.format("Cache size: %d", s.cache_size))
    print(string.format("Pending names: %d", s.pending_names))
    print(string.format("Pending total notes: %d", s.pending_total_notes))
    print(string.format("Initialized: %s", s.initialized and "YES" or "NO"))

  elseif cmd == "gold" then
    -- /gg gold <name> <amount> [reason...]
    local name = args[2]
    local amount = tonumber(args[3])
    local reason = args[4] or "Manual"
    if not name or not amount then
      print_err("Usage: /gg gold <name> <amount> [reason]")
      return
    end
    -- Объединить остальные аргументы в reason
    if args[5] then
      local reason_parts = {}
      for i = 4, #args do tinsert(reason_parts, args[i]) end
      reason = table.concat(reason_parts, " ")
    end
    local result = Addon.Award:IncGold(name, reason, amount, false)
    if result then
      print(string.format("OK +%d EP -> %s (main: %s) — %s", amount, name, result, reason))
    else
      print_err(string.format("Не удалось начислить EP игроку %s", name))
    end

  elseif cmd == "gp" then
    local name = args[2]
    local amount = tonumber(args[3])
    local reason = args[4] or "Manual"
    if not name or not amount then
      print_err("Usage: /gg gp <name> <amount> [reason]")
      return
    end
    if args[5] then
      local reason_parts = {}
      for i = 4, #args do tinsert(reason_parts, args[i]) end
      reason = table.concat(reason_parts, " ")
    end
    local result = Addon.Award:IncGP(name, reason, amount, false)
    if result then
      print(string.format("OK +%d GP -> %s (main: %s) — %s", amount, name, result, reason))
    else
      print_err(string.format("Не удалось начислить GP игроку %s", name))
    end

  elseif cmd == "mass" then
    local amount = tonumber(args[2])
    local reason = args[3]
    if not amount or not reason then
      print_err("Usage: /gg mass <amount> <reason>")
      return
    end
    if args[4] then
      local reason_parts = {}
      for i = 3, #args do tinsert(reason_parts, args[i]) end
      reason = table.concat(reason_parts, " ")
    end
    if force_next then
      -- pcall + гарантированное восстановление safe_mass_mode в finally
      Addon.db.profile.safe_mass_mode = false
      local ok, err = pcall(function()
        Addon.Award:MassGold(reason, amount)
      end)
      Addon.db.profile.safe_mass_mode = true  -- ВСЕГДА восстанавливаем
      force_next = false
      if not ok then
        print_err("MassGold упал с ошибкой: " .. tostring(err))
      end
    else
      Addon.Award:MassGold(reason, amount)
    end

  elseif cmd == "decay" then
    Addon.Award:DecayWithConfirm()

  elseif cmd == "restore" then
    -- Приоритет: массовка (самое свежее) -> decay -> reset.
    -- Можно указать аргумент: /gg restore mass | decay | reset
    local sub = args[2] and args[2]:lower() or ""
    if sub == "mass" then
      if Addon.Award.RestoreMass and Addon.Award:RestoreMass() then
        -- ok
      else
        print_err("Нет backup массовки для восстановления")
      end
    elseif sub == "decay" then
      if Addon.Award.RestoreDecay and Addon.Award:RestoreDecay() then
        -- ok
      else
        print_err("Нет backup среза для восстановления")
      end
    elseif sub == "reset" then
      if Addon.Award.RestoreReset and Addon.Award:RestoreReset() then
        -- ok
      else
        print_err("Нет backup сброса для восстановления")
      end
    else
      -- Авто-режим: массовка -> decay -> reset
      if Addon.Award.RestoreMass and Addon.Award:RestoreMass() then
        -- массовка восстановлена
      elseif Addon.Award.RestoreDecay and Addon.Award:RestoreDecay() then
        -- decay восстановлен
      elseif Addon.Award.RestoreReset and Addon.Award:RestoreReset() then
        -- reset восстановлен
      else
        print_err("Нечего восстанавливать (mass/decay/reset backup отсутствуют)")
      end
    end

  elseif cmd == "cleanup" then
    Addon:ManualCleanup()

  elseif cmd == "leave" then
    -- /gg leave <name>        - поставить на отпуск (добавить [ОТП])
    -- /gg leave remove <name> - снять с отпуска
    -- /gg leave status <name> - показать статус
    local sub = args[2] and args[2]:lower() or ""
    local target_name = args[3]
    if sub == "remove" then
      target_name = target_name or ""
      if target_name == "" then
        print_err("Usage: /gg leave remove <name>")
        return
      end
      if not CanEditOfficerNote() then
        print_err("Нет прав на офицерские ноты!")
        return
      end
      -- Резолвим alt → main
      local main = Addon.data.main_data[target_name] or target_name
      -- Проверяем что main есть в gold_data
      if not Addon.data.gold_data[main] then
        print_err(string.format("Игрок %s не найден в кэше", target_name))
        return
      end
      -- Снимаем отпуск — пишем note без [ОТП]
      local rawGold = Addon.data.gold_data[main] or 0
      local rawGP = Addon.data.gp_data[main] or 0
      -- on_leave снимаем ДО записи ноты — новая нота без [ОТП]
      if Addon.data.on_leave then Addon.data.on_leave[main] = nil end
      local new_note = string.format("%d,%d", rawGold, rawGP)
      local set_ok = Addon.Storage:SetNote(main, new_note)
      if set_ok ~= nil then
        print(string.format("OK Снят с отпуска: %s (note: %s)", main, new_note))
        GuildRoster()
      else
        -- Восстанавливаем on_leave т.к. note не записан
        if Addon.data.on_leave then Addon.data.on_leave[main] = true end
        print_err(string.format("Не удалось записать note для %s (pending full?)", main))
      end
    elseif sub == "status" then
      target_name = target_name or ""
      if target_name == "" then
        print_err("Usage: /gg leave status <name>")
        return
      end
      local main = Addon.data.main_data[target_name] or target_name
      local on_leave = Addon.data.on_leave and Addon.data.on_leave[main] == true
      local rawGold = Addon.data.gold_data[main]
      local rawGP = Addon.data.gp_data[main]
      print(string.format("Игрок: %s", main))
      if on_leave then
        print("  Статус: ОТПУСК")
      else
        print("  Статус: активен")
      end
      if rawGold and rawGP then
        print(string.format("  Officer note: %d,%d%s", rawGold, rawGP, on_leave and " [ОТП]" or ""))
      else
        print("  Officer note: (нет данных)")
      end
    elseif sub ~= "" and sub ~= "help" then
      -- /gg leave <name> — поставить на отпуск
      local leave_name = sub
      if not CanEditOfficerNote() then
        print_err("Нет прав на офицерские ноты!")
        return
      end
      local main = Addon.data.main_data[leave_name] or leave_name
      if not Addon.data.gold_data[main] then
        print_err(string.format("Игрок %s не найден в кэше", leave_name))
        return
      end
      -- Проверяем что уже не в отпуске
      if Addon.data.on_leave and Addon.data.on_leave[main] then
        print(string.format("%s уже в отпуске", main))
        return
      end
      -- Ставим на отпуск — пишем note с [ОТП]
      local rawGold = Addon.data.gold_data[main] or 0
      local rawGP = Addon.data.gp_data[main] or 0
      -- on_leave выставляем ДО записи ноты — новая нота с [ОТП]
      if not Addon.data.on_leave then Addon.data.on_leave = {} end
      Addon.data.on_leave[main] = true
      local new_note = string.format("%d,%d [ОТП]", rawGold, rawGP)
      local set_ok = Addon.Storage:SetNote(main, new_note)
      if set_ok ~= nil then
        print(string.format("OK Поставлен на отпуск: %s (note: %s)", main, new_note))
        GuildRoster()
      else
        -- Откатываем on_leave т.к. note не записан
        Addon.data.on_leave[main] = nil
        print_err(string.format("Не удалось записать note для %s (pending full?)", main))
      end
    else
      print("=== Leave команды ===")
      print("  /gg leave <name>        - поставить на отпуск ([ОТП])")
      print("  /gg leave remove <name> - снять с отпуска")
      print("  /gg leave status <name> - показать статус отпуска")
    end

  elseif cmd == "attendance" then
    -- /gg attendance retry — повтор частично неуспешной attendance mass.
    -- НЕ начисляет EP повторно успешным игрокам.
    local sub = args[2] and args[2]:lower() or ""
    if sub == "retry" then
      if Addon.Award and Addon.Award.RetryAttendanceMass then
        Addon.Award:RetryAttendanceMass()
      else
        print_err("RetryAttendanceMass не реализован (обновите аддон)")
      end
    elseif sub == "status" then
      -- Отчёт о состоянии recovery
      if Addon.Award and Addon.Award.HasAttendanceRecovery and Addon.Award:HasAttendanceRecovery() then
        print("! Attendance recovery: есть — выполните /gg attendance retry")
      else
        print("OK Attendance recovery: нет (все массовки завершены успешно)")
      end
    else
      print("=== Attendance команды ===")
      print("  /gg attendance retry  - повтор частично неуспешной attendance mass")
      print("  /gg attendance status - отчёт о наличии recovery")
    end

  elseif cmd == "standby" then
    -- Standby slash commands — мутации только у лидера рейда и только офицеров.
    -- Управляющие операции требуют право на офицерские ноты, поверх гейта
    -- лидера рейда. list/status/sync доступны всем — пассивный просмотр
    -- (в таблице у рейд-сообщников всё равно видны [Замена]-пометки).
    -- /gg standby <name>     - добавить на замену (офицер + лидер рейда)
    -- /gg standby remove <name>  - снять с замены (офицер + лидер рейда)
    -- /gg standby list       - список замен (любой)
    -- /gg standby status     - отчёт о standby session (любой)
    -- /gg standby sync       - запрос snapshot от лидера (любой)
    -- /gg standby clear      - очистить весь список (офицер + лидер рейда)
    local sub = args[2] and args[2]:lower() or ""
    -- Общий офицерский гейт для мутаций
    local is_mutation = (sub ~= "list" and sub ~= "status" and sub ~= "sync")
    if is_mutation and not (Addon.state and Addon.state.can_edit) then
      print_err("Управлять заменами могут только офицеры (право редактирования офицерских заметок)")
      return
    end
    if sub == "list" then
      local count = 0
      for name in pairs(Addon.state.standby) do
        print("  * " .. name)
        count = count + 1
      end
      if count == 0 then print("  Нет игроков на замене") end
    elseif sub == "status" then
      -- Отчёт о standby session
      local session = Addon.state.standby_session
      local standby_count = 0
      for _ in pairs(Addon.state.standby) do standby_count = standby_count + 1 end
      if session and session.active then
        print(string.format("Standby session: active, leader=%s, rev=%d, игроков=%d",
          tostring(session.leader), session.revision, standby_count))
      else
        print("Standby session: не активна (нет рейда или нет лидера)")
        print("  Игроков на замене: " .. standby_count)
      end
    elseif sub == "sync" then
      -- Запрос snapshot у лидера
      Addon:RequestStandbySnapshot("slash_sync")
    elseif sub == "remove" then
      local name = args[3]
      if not name then
        print_err("Usage: /gg standby remove <name>")
        return
      end
      -- Гейт лидера рейда
      if not Addon:IsCurrentRaidLeader() then
        print_err("Только текущий лидер рейда управляет списком замен")
        return
      end
      Addon:SetStandby(name, false)
    elseif sub == "clear" then
      -- Гейт лидера рейда
      if not Addon:IsCurrentRaidLeader() then
        print_err("Только текущий лидер рейда управляет списком замен")
        return
      end
      Addon:ClearStandby()
    elseif sub and sub ~= "" then
      -- /gg standby <name> — add
      -- Гейт лидера рейда
      if not Addon:IsCurrentRaidLeader() then
        print_err("Только текущий лидер рейда управляет списком замен")
        return
      end
      Addon:SetStandby(sub, true)
    else
      print("=== Standby команды ===")
      print("  /gg standby <name>      - добавить на замену (только офицер + лидер рейда)")
      print("  /gg standby remove <name> - снять с замены (только офицер + лидер рейда)")
      print("  /gg standby list        - список замен")
      print("  /gg standby status      - отчёт о standby session")
      print("  /gg standby sync        - запрос snapshot от лидера рейда")
      print("  /gg standby clear       - очистить список (только офицер + лидер рейда)")
    end

  elseif cmd == "reset" then
    Addon.Award:ResetWithConfirm()

  elseif cmd == "recurring" then
    local sub = args[2] and args[2]:lower() or ""
    if sub == "stop" then
      Addon.Award:StopRecurring()
      print("Recurring остановлен")
    elseif sub == "status" then
      if Addon.Award:RunningRecurring() then
        local vars = Addon.db.profile
        -- next_award хранится в epoch (time()), не GetTime()
        local remaining = vars.next_award - time()
        print(string.format("Recurring: %s +%d каждые %dm (осталось %.0fs)",
          vars.next_award_reason or "?",
          vars.next_award_amount or 0,
          vars.recurring_period_mins or 0,
          remaining))
      else
        print("Recurring не запущен")
      end
    else
      local amount = tonumber(args[2])
      local reason = args[3] or "Рт по таймеру"
      if not amount then
        print_err("Usage: /gg recurring <amount> <reason>  OR  /gg recurring stop")
        return
      end
      Addon.Award:StartRecurring(reason, amount)
      print(string.format("Рт по таймеру старт: +%d каждые %dm", amount, Addon.db.profile.recurring_period_mins))
    end

  elseif cmd == "log" then
    local sub = args[2] and args[2]:lower() or ""
    if sub == "clear" then
      Addon.Log:Clear()
    elseif sub == "export" then
      print("=== LOG EXPORT (последние 100 записей) ===")
      local entries = Addon.Log:GetLast(100)
      for _, e in ipairs(entries) do
        local ts = date("%H:%M:%S", e.time)
        print(string.format("[%s] [%s] %s", ts, e.level, e.msg))
      end
    elseif sub == "" or tonumber(sub) then
      local n = tonumber(sub) or 20
      print(string.format("=== Последние %d записей лога ===", n))
      local entries = Addon.Log:GetLast(n)
      for _, e in ipairs(entries) do
        local ts = date("%H:%M:%S", e.time)
        local color = ""
        if e.level == "ERROR" then color = "|cFFFF5050" end
        if e.level == "WARN" then color = "|cFFFFAA00" end
        if e.level == "INFO" then color = "|cFFAAFFAA" end
        if e.level == "DEBUG" then color = "|cFF888888" end
        print(string.format("%s[%s] [%s] %s|r", color, ts, e.level, e.msg))
      end
    end

  elseif cmd == "force" then
    force_next = true
    print("! Следующий /gg mass выполнен БЕЗ проверок (один раз)")

  elseif cmd == "config" then
    -- /gg config открывает окно настроек через Interface Options
    if Addon.Options and Addon.Options.Open then
      Addon.Options:Open()
    else
      local p = Addon.db.profile
      print("=== Конфигурация ===")
      print(string.format("  decay_p: %d%%", p.decay_p or 0))
      print(string.format("  extras_p: %d%%", p.extras_p or 0))
      print(string.format("  min_gold: %d", p.min_gold or 0))
      print(string.format("  base_gp: %d", p.base_gp or 0))
      print(string.format("  mass_ep_cooldown: %.1f sec", p.mass_ep_cooldown or 0))
      print(string.format("  safe_mass_mode: %s", p.safe_mass_mode and "ON" or "OFF"))
      print(string.format("  recurring_period_mins: %d", p.recurring_period_mins or 0))
      print(string.format("  party_split_enabled: %s", p.party_split_enabled and "ON" or "OFF"))
      print(string.format("  party_split_threshold: P1-%d = 100%%", p.party_split_threshold or 5))
      print(string.format("  party_split_percent: %d%% for P%d+", p.party_split_percent or 50, (p.party_split_threshold or 5) + 1))
      print(string.format("  update_interval: %.2f сек", p.update_interval or 0.1))
    end

  elseif cmd == "flask" then
    -- Проверка настоев (канал всегда GUILD).
    -- Модуль — отдельный аддон GoldGP_Flask (ставится только офицерам);
    -- диспетчер остаётся здесь и работает только при его наличии.
    if not Addon.Flask then
      print("Модуль GoldGP_Flask не установлен — /gg flask недоступен. Настройка настоев — в окне настроек аддона GoldGP Фласки.")
      return
    end
    local sub = args[2] and args[2]:lower() or ""
    if sub == "" or sub == "check" then
      Addon.Flask:RunCheck()
    elseif sub == "gp" then
      local n = tonumber(args[3])
      if not n then print_err("Usage: /gg flask gp <N>") return end
      Addon.Flask:SetGPAmount(n)
    elseif sub == "list" then
      Addon.Flask:ListFlasks()
    elseif sub == "add" then
      if not args[3] then print_err("Usage: /gg flask add <spellID>") return end
      Addon.Flask:AddFlask(args[3])
    elseif sub == "remove" or sub == "delete" then
      if not args[3] then print_err("Usage: /gg flask remove <spellID>") return end
      Addon.Flask:RemoveFlask(args[3])
    elseif sub == "reset" then
      Addon.Flask:ResetFlasks()
    elseif sub == "status" then
      print("=== Flask: настройки ===")
      print(string.format("  GP за отсутствие настоя: %d", Addon.Flask:GetGPAmount()))
      print("  Канал отчёта: GUILD (фиксированный)")
      local ids = Addon.Flask:GetFlaskIDs()
      print(string.format("  Настоев в списке: %d", #ids))
    else
      print("=== Flask: команды ===")
      print("  /gg flask                 - проверить настои (канал GUILD)")
      print("  /gg flask gp <N>          - сумма GP за отсутствие настоя")
      print("  /gg flask list            - список настоев")
      print("  /gg flask add <spellID>   - добавить настой")
      print("  /gg flask remove <spellID>- удалить настой")
      print("  /gg flask reset           - сбросить к дефолтному")
      print("  /gg flask status          - текущие настройки")
    end

  elseif cmd == "loot" then
    -- LootMaster управление
    local sub = args[2] and args[2]:lower() or ""
    local LM = _G.GoldGPLootMaster
    if not LM then
      print("! GoldGP_LootMaster не загружен")
      return
    end
    if sub == "test" then
      LM:TestComm()
    elseif sub == "testgp" then
      LM:TestGP()
    elseif sub == "testfull" then
      LM:TestFull()
    elseif sub == "testreset" then
      -- Полная очистка тестового состояния.
      if LM.TestReset then
        LM:TestReset()
      else
        print("! TestReset не реализован (обновите аддон)")
      end
    elseif sub == "teststatus" then
      -- Отчёт о состоянии LootMaster.
      if LM.TestStatus then
        LM:TestStatus()
      else
        print("! TestStatus не реализован (обновите аддон)")
      end
    elseif sub == "testduplicates" then
      -- Тест двух одинаковых предметов с разными lootKey.
      if LM.TestDuplicates then
        LM:TestDuplicates()
      else
        print("! TestDuplicates не реализован (обновите аддон)")
      end
    elseif sub == "testchunk" then
      -- Регрессионный тест чанкинга (сообщения > 190 байт с кириллицей).
      if LM.TestChunk then
        LM:TestChunk()
      else
        print("! TestChunk не реализован (обновите аддон)")
      end
    elseif sub == "config" or sub == "options" or sub == "opts" then
      -- Открыть окно настроек LootMaster
      if LM.OpenOptions then
        LM:OpenOptions()
      else
        print("! Настройки LootMaster не загружены (GoldGP_LootMaster_Options.lua)")
      end
    elseif sub == "add" then
      -- /gg loot add [link] — добавить предмет в LootMaster вручную.
      -- Если link не указан — берётся предмет под курсором.
      local link = args[3]
      if not link then
        -- Проверяем не перетаскивается ли предмет (cursor)
        local type, itemID, itemLink = GetCursorInfo()
        if type == "item" and itemLink then
          link = itemLink
        end
      end
      if not link or not link:find("item:") then
        print_err("Usage: /gg loot add [itemLink]  (или перетащите предмет на курсор)")
        print("  Пример: /gg loot add |cffffffff|Hitem:12345:0:0:0:0:0:0:0|h[Item]|h|r")
        return
      end
      -- ГРАБЛИ 3.3.5a: IsMasterLooter() не существует (появился в Cataclysm+).
      -- Разрешаем добавить предмет даже не будучи ML — AddLoot сам проверит состояние
      -- при раздаче через GiveMasterLoot.
      local itemName, _, itemRarity, _, _, _, _, _, _, itemTexture = GetItemInfo(link)
      if not itemName then
        print_err("Не удалось получить информацию о предмете (попробуйте снова)")
        return
      end
      -- Добавляем через AddLoot (slotID=0 для ручного добавления)
      if LM.AddLoot then
        LM:AddLoot(link, itemName, itemTexture, 1, itemRarity or 2, 0)
        print(string.format("OK Предмет добавлен в LootMaster: %s", link))
      else
        print_err("LM.AddLoot не доступен")
      end
    else
      print("=== LootMaster команды ===")
      print("  /gg loot config    - открыть окно настроек LootMaster")
      print("  /gg loot add [link] - добавить предмет вручную (или перетащите на курсор)")
      print("  /gg loot test        - тест коммуникации")
      print("  /gg loot testgp     - тест GP-калькулятора")
      print("  /gg loot testfull   - ПОЛНЫЙ тест без рейда (окна ML + кандидат)")
      print("  /gg loot testreset  - (v2.5.8) очистка тестового состояния")
      print("  /gg loot teststatus - (v2.5.8) отчёт о состоянии LootMaster")
      print("  /gg loot testduplicates - (v2.5.8) тест двух одинаковых предметов")
      print("  /gg loot testchunk   - (v0.7.2) тест чанкинга сообщений > 190 байт")
    end

  elseif cmd == "split" then
    -- /gg split on|off         — включить/выключить party-split
    -- /gg split threshold <N>  — установить порог (1..7)
    -- /gg split percent <N>    — установить процент для P+1..8 (0..100)
    local sub = args[2] and args[2]:lower() or ""
    local p = Addon.db.profile
    if sub == "on" then
      p.party_split_enabled = true
      print("OK Party-split ВКЛ: P1-" .. (p.party_split_threshold or 5) .. " = 100%, P" .. ((p.party_split_threshold or 5) + 1) .. "-8 = " .. (p.party_split_percent or 50) .. "%")
    elseif sub == "off" then
      p.party_split_enabled = false
      print("OK Party-split ВЫКЛ — все получают 100%")
    elseif sub == "threshold" then
      local n = tonumber(args[3])
      if not n or n < 1 or n > 7 then
        print_err("Usage: /gg split threshold <1..7>")
        return
      end
      p.party_split_threshold = n
      print(string.format("OK Threshold: P1-%d = 100%%, P%d-8 = %d%%", n, n + 1, p.party_split_percent or 50))
    elseif sub == "percent" then
      local n = tonumber(args[3])
      if not n or n < 0 or n > 100 then
        print_err("Usage: /gg split percent <0..100>")
        return
      end
      p.party_split_percent = n
      print(string.format("OK Percent: P1-%d = 100%%, P%d-8 = %d%%", p.party_split_threshold or 5, (p.party_split_threshold or 5) + 1, n))
    elseif sub == "status" or sub == "" then
      if p.party_split_enabled then
        print(string.format("Party-split: ВКЛ | P1-%d = 100%% | P%d-8 = %d%%",
          p.party_split_threshold or 5, (p.party_split_threshold or 5) + 1, p.party_split_percent or 50))
      else
        print("Party-split: ВЫКЛ (все получают 100%)")
      end
    else
      print_err("Usage: /gg split <on|off|threshold N|percent N|status>")
    end

  elseif cmd == "help" then
    print("=== Команды GoldGP ===")
    print("  /gg                        — открыть/закрыть окно")
    print("  /gg show | hide            — показать/скрыть")
    print("  /gg refresh                — обновить ростер")
    print("  /gg state                  — состояние Storage")
    print("  /gg stats                  — статистика кэша")
    print("  /gg gold <name> <amt> [r]  — Gold игроку")
    print("  /gg gp <name> <amt> [r]    — GP игроку")
    print("  /gg mass <amt> <reason>    — массовка EP (P1-5=100%, P6-8=50%)")
    print("  /gg decay                  — применить decay")
    print("  /gg reset                  — обнулить всё")
    print("  /gg restore                — отменить массовку/срез/сброс (авто)")
    print("  /gg restore mass|decay|reset — отменить конкретный backup")
    print("  /gg recurring <amt> <r>    — старт recurring (с party-split)")
    print("  /gg recurring stop         — стоп recurring")
    print("  /gg recurring status       — статус recurring")
    print("  /gg split on|off           — вкл/выкл party-split")
    print("  /gg split threshold <N>    — порог (P1-N=100%, по умолч. 5)")
    print("  /gg split percent <N>      — %% для P+1..8 (по умолч. 50)")
    print("  /gg split status           — текущие настройки party-split")
    print("  /gg log [N|clear|export]   — лог операций")
    print("  /gg history                — открыть журнал начислений")
    print("  /gg history clear          — очистить журнал")
    print("  /gg announce on|off        — вкл/выкл автопубликацию в чат гильдии")
    print("  /gg announce channel <X>   — канал: GUILD | OFFICER | RAID | PARTY")
    print("  /gg announce test          — тестовое сообщение")
    print("  /gg announce status        — текущие настройки автопубликации")
    print("  /gg force                  — обход проверок (1 раз)")
    print("  /gg cleanup                — очистить старые данные (лог/журнал)")
    print("  /gg config                 — открыть окно настроек")
    print("  /gg setguild [имя|clear]   — гильд-лок: без арг. = текущая гильдия")
    print("  /gg welcome                — окно первого запуска (Правила/Таблица)")
    print("  /gg rules                  — сразу открыть окно правил гильдии")
    print("  /gg classdiag              — диагностика иконок классов (для репорта)")
    print("  /gg help                   — эта справка")

  elseif cmd == "history" then
    local sub = args[2] and args[2]:lower() or ""
    if sub == "clear" then
      Addon.History:Clear()
      print("Журнал очищен")
    elseif sub == "export" then
      print("=== EXPORT (последние 50) ===")
      local entries = Addon.db.global.history or {}
      local start_idx = math.max(1, #entries - 49)
      for i = start_idx, #entries do
        local e = entries[i]
        local ts = date("%Y-%m-%d %H:%M:%S", e.time)
        print(string.format("[%s] %s %s -> %s | %d | %s | %s",
          ts, e.type, e.officer or "?", e.target or "?",
          e.amount, e.reason or "", ""))
      end
    else
      Addon.History:Toggle()
    end

  elseif cmd == "announce" then
    local sub = args[2] and args[2]:lower() or ""
    if sub == "on" then
      Addon.Announce:SetEnabled(true)
      print("OK Автопубликация ВКЛ")
    elseif sub == "off" then
      Addon.Announce:SetEnabled(false)
      print("OK Автопубликация ВЫКЛ")
    elseif sub == "channel" then
      local ch = args[3] and args[3]:upper() or ""
      if ch ~= "GUILD" and ch ~= "OFFICER" and ch ~= "RAID" and ch ~= "PARTY" then
        print_err("Usage: /gg announce channel <GUILD|OFFICER|RAID|PARTY>")
        return
      end
      Addon.Announce:SetChannel(ch)
      print(string.format("OK Канал автопубликации: %s", ch))
    elseif sub == "test" then
      Addon.Announce:Test()
      print("Тестовое сообщение отправлено")
    elseif sub == "status" or sub == "" then
      local c = Addon.Announce:GetConfig()
      print("=== Автопубликация ===")
      print(string.format("  Включена: %s", c.enabled and "|cFF30AA30YES|r" or "|cFFFF5050NO|r"))
      print(string.format("  Канал: %s", c.channel))
      print(string.format("  Массовки: %s | Индивидуальные: %s | Decay: %s | Recurring: %s",
        c.mass and "ON" or "OFF",
        c.individual and "ON" or "OFF",
        c.decay and "ON" or "OFF",
        c.recurring and "ON" or "OFF"))
      print(string.format("  Мин. сумма: %d", c.min_amount))
    else
      print_err("Usage: /gg announce <on|off|channel X|test|status>")
    end

  elseif cmd == "setguild" then
    -- /gg setguild — привязать аддон к гильдии (гильд-лок)
    local sub = args[2]
    if not Addon.db or not Addon.db.global then
      print_err("БД ещё не загружена, повторите через пару секунд")
      return
    end
    if sub and sub:lower() == "clear" then
      Addon.db.global.required_guild = ""
      print("Гильд-лок сброшен (используется константа REQUIRED_GUILD_NAME из GoldGP_Core.lua)")
      if Addon.REQUIRED_GUILD_NAME ~= "" then
        print("Текущая константа в файле: " .. Addon.REQUIRED_GUILD_NAME)
      end
      Addon:UpdateGuildLock("slash_setguild")
    elseif sub == nil then
      -- Без аргумента — привязать к текущей гильдии игрока (без опечаток)
      local gname = GetGuildInfo("player")
      if not gname then
        print_err("Вы не состоите в гильдии — привязывать не к чему")
        return
      end
      Addon.db.global.required_guild = gname
      print(string.format("Гильд-лок установлен: аддон работает только в гильдии '%s'", gname))
      Addon:UpdateGuildLock("slash_setguild")
    else
      -- Ручное имя (может содержать пробелы)
      local parts = {}
      for i = 2, #args do tinsert(parts, args[i]) end
      local gname = table.concat(parts, " ")
      Addon.db.global.required_guild = gname
      print(string.format("Гильд-лок установлен: аддон работает только в гильдии '%s'", gname))
      Addon:UpdateGuildLock("slash_setguild")
    end

  elseif cmd == "welcome" then
    -- Показать окно первого запуска (Правила / Таблица) повторно
    if Addon.Welcome then
      Addon.Welcome:Show(true)
    else
      print_err("Модуль Welcome не загружен — проверьте GoldGP.toc")
    end

  elseif cmd == "rules" then
    -- Сразу открыть окно правил (без окна выбора)
    if Addon.Welcome and Addon.Welcome.ShowRules then
      Addon.Welcome:ShowRules()
    else
      print_err("Модуль Welcome не загружен — проверьте GoldGP.toc")
    end

  elseif cmd == "classdiag" then
    -- Диагностика классов — печатает RAW строки классов из ростера
    -- с результатом маппинга (для поиска причины «у части игроков нет иконки»)
    if Addon.GetClassDiagnostics then
      Addon:GetClassDiagnostics()
    else
      print_err("classdiag недоступен — обновите аддон до v2.8.3+")
    end

  else
    print_err("Неизвестная команда: " .. tostring(cmd) .. "  (попробуйте /gg help)")
  end
end

-- ============================================================================
-- РЕГИСТРАЦИЯ СЛЭШ-КОМАНД
-- ============================================================================
SLASH_GOLDGP1 = "/gg"
SLASH_GOLDGP2 = "/goldgp"
SLASH_GOLDGP3 = "/goldg"
SlashCmdList["GOLDGP"] = function(msg)
  -- Безопасный вызов
  local ok, err = pcall(handle_slash, msg)
  if not ok then
    print_err("Команда вызвала ошибку: " .. tostring(err))
    if Addon.Log then
      Addon.Log:Error("Slash command error: %s | msg='%s'", tostring(err), tostring(msg))
    end
  end
end

if Addon.Log then
  Addon.Log:Info("GoldGP_Slash loaded — commands: /gg, /goldgp, /goldg, /lm")
else
  DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r: Slash loaded (Log not available)")
end

-- Команда /lm — алиас для /gg loot.
-- /lm add [link] — добавить предмет в LootMaster
-- /lm config — открыть настройки
-- /lm help — справка
SLASH_GOLDGPLM1 = "/lm"
SlashCmdList["GOLDGPLM"] = function(msg)
  -- Перенаправляем на /gg loot
  local ok, err = pcall(handle_slash, "loot " .. (msg or ""))
  if not ok then
    print_err("/lm ошибка: " .. tostring(err))
  end
end
