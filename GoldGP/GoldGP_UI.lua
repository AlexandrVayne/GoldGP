-- GoldGP_UI.lua

local Addon = GoldGP
local UI = {}
Addon.UI = UI

-- UIKit загружается раньше в .toc — fallbacks не нужны.
local UIKit = Addon.UIKit
local COLORS = UIKit.COLORS
local CLASS_COLORS = UIKit.CLASS_COLORS
local CLASS_ICON_TEXTURE = UIKit.CLASS_ICON_TEXTURE
local CLASS_ICON_TCOORDS = UIKit.CLASS_ICON_TCOORDS

-- ============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================================
local apply_backdrop = UIKit.apply_backdrop

local function make_movable(frame)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Сохранить позицию
    if Addon.db and Addon.db.profile then
      local scale = self:GetScale() or 1
      local x, y = self:GetCenter()
      local uiScale = UIParent:GetScale()
      Addon.db.profile.window_pos_x = x * scale * uiScale
      Addon.db.profile.window_pos_y = y * scale * uiScale
    end
  end)
end

local create_button = UIKit.create_button

-- ============================================================================
-- СОЗДАНИЕ ГЛАВНОГО ОКНА
-- ============================================================================
local main_frame
local rows = {}      -- список строк (для обновления)
-- Высота строки таблицы. Объявлена на уровне файла: используется и в
-- CreateMainWindow (OnVerticalScroll), и в CreateRow/GetVisibleRows.
local ROW_HEIGHT = 24
local sort_order = "PR"  -- текущая сортировка (персистится в profile.sort_order)
-- show_all_mode: false (по умолчанию) = показывать только рейд/группу;
-- true = показывать всех игроков гильдии (чекбокс "Показать всех" в футере).
local show_all_mode = false

function UI:Initialize()
  -- nil-check Addon.db — может быть nil, если /gg вызван до ADDON_LOADED
  if not Addon.db then
    Addon.PrintError("Аддон ещё загружается, подождите 2 сек и повторите /gg")
    return
  end
  if main_frame then
    -- Перечитать настройки позиции
    if Addon.db.profile.window_pos_x and Addon.db.profile.window_pos_y then
      main_frame:ClearAllPoints()
      main_frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
        Addon.db.profile.window_pos_x, Addon.db.profile.window_pos_y)
    end
    return
  end
  self:CreateMainWindow()
end

function UI:CreateMainWindow()
  -- nil-check (двойная защита)
  if not Addon.db or not Addon.db.profile then
    Addon.PrintError("Аддон ещё загружается, подождите 2 сек и повторите /gg")
    return
  end
  local profile = Addon.db.profile
  -- Минимальная ширина 560: в старых SavedVariables может лежать меньшее значение —
  -- сбрасываем к 560 и обновляем БД.
  local width = profile.window_width or 560
  if width < 560 then
    width = 560
    profile.window_width = 560
  end
  -- Расчёт ширины: icon(24) + name(120) + gold(65) + gp(55) + pr(55) + rank(85) + attend(60) = 464
  -- + left margin 12 + right scrollbar 30 + border 2 = 508. 560px = с запасом.
  local height = profile.window_height or 460

  -- Восстановить сохранённую сортировку из profile.sort_order.
  local saved_sort = profile.sort_order
  if saved_sort == "NAME" or saved_sort == "GOLD" or saved_sort == "GP"
     or saved_sort == "PR" or saved_sort == "RANK" or saved_sort == "ATTEND" then
    sort_order = saved_sort
  end

  -- Главный фрейм (чёрный край 2px, полупрозрачный фон)
  main_frame = CreateFrame("Frame", "GoldGPFrame", UIParent)
  main_frame:SetSize(width, height)
  main_frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  apply_backdrop(main_frame, COLORS.bg_main, COLORS.border, 2)
  make_movable(main_frame)
  main_frame:SetFrameStrata("DIALOG")
  main_frame:EnableMouse(true)
  main_frame:Hide()

  -- Шапка окна: единый фабричный метод UIKit (тайтлбар + иконка + масштаб + закрыть)
  local chrome = UIKit.create_window_chrome(main_frame, {
    title = "|cFFFFD700Mad|r|cFFAAAAAATeaParty|r |cFF808080Gold/GP|r",
    icon  = "Interface\\Icons\\INV_Misc_Coin_01",
    on_close = function() UI:Hide() end,
    on_scale_change = function(s)
      -- Персист масштаба в профиль (прежде делался в каждой кнопке отдельно)
      if Addon.db and Addon.db.profile then
        Addon.db.profile.window_scale = s
      end
    end,
  })

  -- Бейдж read-only mode (показывается когда can_edit = false)
  local ro_badge = chrome.title_bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ro_badge:SetPoint("LEFT", chrome.title_text, "RIGHT", 10, 0)
  ro_badge:SetText("|cFFFF5050[Read-only]|r")
  ro_badge:Hide()
  UI.ro_badge = ro_badge

  -- Сообщение "не в гильдии" (показывается когда нет гильдии)
  local no_guild_text = main_frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  no_guild_text:SetPoint("CENTER", main_frame, "CENTER", 0, 0)
  no_guild_text:SetText("|cFFFF5050Вы не состоите в гильдии|r\n\n|cFF808080GoldGP требует членство в гильдии для работы|r")
  no_guild_text:Hide()
  UI.no_guild_text = no_guild_text

  -- Восстановление масштаба
  if Addon.db and Addon.db.profile and Addon.db.profile.window_scale then
    main_frame:SetScale(Addon.db.profile.window_scale)
    chrome.scale_text:SetText(math.floor(Addon.db.profile.window_scale * 100 + 0.5) .. "%")
  end

  -- Кнопка «Правила» открывает СРАЗУ окно правил (Welcome:ShowRules), а не
  -- окно выбора — то остаётся только при первом запуске и через /gg welcome.
  local rules_btn = create_button(chrome.title_bar, "Правила", 64, UIKit.BTN_H_SM, function()
    if Addon.Welcome and Addon.Welcome.ShowRules then
      Addon.Welcome:ShowRules()
    end
  end)
  rules_btn:SetPoint("RIGHT", chrome.scale_minus, "LEFT", -8, 0)

  -- Состояние Storage видно в нижней плашке окна.

  -- ============================================================================
  -- ВЕРХНИЙ ТУЛБАР (1 ряд): слева кнопки (Масс EP, Рт таймер, Фласки, Замены)
  -- Высота 40px = отступ 8 + кнопка 24 + отступ 8
  -- ============================================================================
  local toolbar = CreateFrame("Frame", nil, main_frame)
  toolbar:SetPoint("TOPLEFT", chrome.title_bar, "BOTTOMLEFT", 0, -2)
  toolbar:SetPoint("TOPRIGHT", chrome.title_bar, "BOTTOMRIGHT", 0, -2)
  toolbar:SetHeight(40)
  apply_backdrop(toolbar, COLORS.bg_panel, COLORS.border, 1)

  -- Слева: Масс EP | Рт таймер
  -- "Масс EP" — зелёная тема (EP = очки усилия, успех) + иконка монеты.
  -- "Рт таймер" — иконка часов (INV_Misc_PocketWatch_01).
  local mass_gold_btn = create_button(toolbar, "Масс EP", 100, UIKit.BTN_H, function()
    if Addon.Dialog then
      Addon.Dialog:ShowMassAward()
    end
  end)
  mass_gold_btn:SetPoint("LEFT", toolbar, "LEFT", 10, 0)

  -- Иконка монеты на кнопке "Масс EP"
  mass_gold_btn.icon = mass_gold_btn:CreateTexture(nil, "ARTWORK")
  mass_gold_btn.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
  mass_gold_btn.icon:SetSize(16, 16)
  mass_gold_btn.icon:SetPoint("LEFT", mass_gold_btn, "LEFT", 6, 0)
  mass_gold_btn.text:ClearAllPoints()
  mass_gold_btn.text:SetPoint("CENTER", mass_gold_btn, "CENTER", 8, 1)

  -- Зелёная тема для "Масс EP" (EP = очки усилия, позитивное начисление)
  local MASS_BG = { r = 0.06, g = 0.20, b = 0.10, a = 1.0 }
  local MASS_BG_HOVER = { r = 0.10, g = 0.32, b = 0.14, a = 1.0 }
  local MASS_BG_DOWN = { r = 0.04, g = 0.14, b = 0.06, a = 1.0 }
  local MASS_BORDER = { r = 0.20, g = 0.65, b = 0.25, a = 1.0 }
  local MASS_BORDER_HOVER = { r = 0.40, g = 0.90, b = 0.40, a = 1.0 }
  apply_backdrop(mass_gold_btn, MASS_BG, MASS_BORDER, 2)
  mass_gold_btn.text:SetTextColor(0.75, 0.95, 0.75)
  mass_gold_btn:SetScript("OnEnter", function(self)
    apply_backdrop(self, MASS_BG_HOVER, MASS_BORDER_HOVER, 2)
    self.text:SetTextColor(1.00, 1.00, 1.00)
  end)
  mass_gold_btn:SetScript("OnLeave", function(self)
    apply_backdrop(self, MASS_BG, MASS_BORDER, 2)
    self.text:SetTextColor(0.75, 0.95, 0.75)
  end)
  mass_gold_btn:SetScript("OnMouseDown", function(self)
    apply_backdrop(self, MASS_BG_DOWN, MASS_BORDER_HOVER, 2)
  end)
  mass_gold_btn:SetScript("OnMouseUp", function(self)
    apply_backdrop(self, MASS_BG_HOVER, MASS_BORDER_HOVER, 2)
  end)
  UI.mass_gold_btn = mass_gold_btn  -- для ApplyReadOnlyMode

  local recurring_btn = create_button(toolbar, "Рт таймер", 95, UIKit.BTN_H, function()
    if Addon.Award:RunningRecurring() then
      Addon.Award:StopRecurring()
    else
      if Addon.Dialog then
        Addon.Dialog:ShowRecurringSetup()
      end
    end
  end)
  recurring_btn:SetPoint("LEFT", mass_gold_btn, "RIGHT", 6, 0)

  -- Иконка часов на кнопке "Рт таймер"
  recurring_btn.icon = recurring_btn:CreateTexture(nil, "ARTWORK")
  recurring_btn.icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
  recurring_btn.icon:SetSize(16, 16)
  recurring_btn.icon:SetPoint("LEFT", recurring_btn, "LEFT", 6, 0)
  -- Сдвигаем текст правее иконки
  recurring_btn.text:ClearAllPoints()
  recurring_btn.text:SetPoint("CENTER", recurring_btn, "CENTER", 8, 1)

  -- Кнопки "Только рейд" в тулбаре нет — переключение рейд/все в футере
  -- (чекбокс "Показать всех", см. ниже).

  -- Кнопка "Фласки" — проверка настоев в группе/рейде + начисление GP (модуль GoldGP_Flask).
  -- ВАЖНО: кнопка создаётся ВСЕГДА, видимость определяется ДИНАМИЧЕСКИ через
  -- UI:SyncFlaskButton() — НЕ возвращать одноразовый детект Addon.Flask при
  -- создании окна (иначе при поздней загрузке/ошибке модуля кнопка молча не появится):
  --   * модуль есть  -> кнопка видна (офицерам);
  --   * модуля нет   -> кнопка скрыта, при открытии таблицы — разовая подсказка.
  -- SyncFlaskButton вызывается из: CreateMainWindow (конец), UI:Show,
  -- ApplyReadOnlyMode и самого модуля GoldGP_Flask при загрузке.
  local flask_btn = create_button(toolbar, "Фласки", 85, UIKit.BTN_H, function()
      -- Диалог подтверждения
      StaticPopupDialogs["GOLDGP_FLASK_CONFIRM"] = {
        text = "|cFFFFD700Проверка настоев|r\n\nПроверить настои у группы/рейда и начислить GP игрокам без настоя?\n\n|cFF808080Отчёт будет отправлен в GUILD-чат.|r",
        button1 = "Начислить GP",
        button2 = "Отмена",
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        OnAccept = function()
          if Addon.Flask and Addon.Flask.RunCheck then
            Addon.Flask:RunCheck()
          else
            Addon.PrintError("Модуль Flask не загружен")
          end
        end,
      }
      StaticPopup_Show("GOLDGP_FLASK_CONFIRM")
    end)
  flask_btn:SetPoint("LEFT", recurring_btn, "RIGHT", 6, 0)

  -- Иконка настоя слева от текста
  flask_btn.icon = flask_btn:CreateTexture(nil, "ARTWORK")
  flask_btn.icon:SetTexture("Interface\\Icons\\INV_Potion_97")
  flask_btn.icon:SetSize(16, 16)
  flask_btn.icon:SetPoint("LEFT", flask_btn, "LEFT", 6, 0)
  -- Сдвигаем текст правее иконки
  flask_btn.text:ClearAllPoints()
  flask_btn.text:SetPoint("CENTER", flask_btn, "CENTER", 8, 1)

  -- Бирюзовая тема (отличается от золотых кнопок и красного "Срез")
  local FLASK_BG = { r = 0.06, g = 0.18, b = 0.18, a = 1.0 }
  local FLASK_BG_HOVER = { r = 0.10, g = 0.32, b = 0.32, a = 1.0 }
  local FLASK_BG_DOWN = { r = 0.04, g = 0.12, b = 0.12, a = 1.0 }
  local FLASK_BORDER = { r = 0.20, g = 0.60, b = 0.60, a = 1.0 }
  local FLASK_BORDER_HOVER = { r = 0.40, g = 0.90, b = 0.90, a = 1.0 }
  apply_backdrop(flask_btn, FLASK_BG, FLASK_BORDER, 2)
  flask_btn.text:SetTextColor(0.70, 0.95, 0.95)
  flask_btn:SetScript("OnEnter", function(self)
    apply_backdrop(self, FLASK_BG_HOVER, FLASK_BORDER_HOVER, 2)
    self.text:SetTextColor(1.00, 1.00, 1.00)
  end)
  flask_btn:SetScript("OnLeave", function(self)
    apply_backdrop(self, FLASK_BG, FLASK_BORDER, 2)
    self.text:SetTextColor(0.70, 0.95, 0.95)
  end)
  flask_btn:SetScript("OnMouseDown", function(self)
    apply_backdrop(self, FLASK_BG_DOWN, FLASK_BORDER_HOVER, 2)
  end)
  flask_btn:SetScript("OnMouseUp", function(self)
    apply_backdrop(self, FLASK_BG_HOVER, FLASK_BORDER_HOVER, 2)
  end)

  UI.flask_btn = flask_btn
  flask_btn:Hide()  -- видимость выставит SyncFlaskButton()

  -- Кнопка "Замены" - открыть окно standby списка.
  -- Окно целиком офицерское (гейт внутри ShowStandbyWindow) — кнопка
  -- дополнительно скрывается здесь при отсутствии прав (belt & suspenders,
  -- основное управление — ApplyReadOnlyMode).
  local standby_btn = create_button(toolbar, "Замены", 70, UIKit.BTN_H_SM, function()
    UI:ShowStandbyWindow()
  end)
  -- Якорь "Замен" переключается динамически в SyncFlaskButton: если кнопки
  -- фласков нет — "Замены" прижимается к "Рт таймер".
  standby_btn:SetPoint("LEFT", flask_btn, "RIGHT", 4, 0)
  UI.standby_btn = standby_btn

  -- Заголовок таблицы (header)
  local header = CreateFrame("Frame", nil, main_frame)
  header:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -2)
  header:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -2)
  header:SetHeight(24)
  apply_backdrop(header, COLORS.bg_panel, COLORS.border, 1)

  -- ============================================================================
  -- КОЛОНКИ ТАБЛИЦЫ
  -- ============================================================================
  -- Структура: Class icon (без заголовка) | Имя | Gold | GP | PR | Звание
  --
  -- ! ЕСЛИ ХОТИТЕ ИЗМЕНИТЬ ШИРИНУ КОЛОНКИ ИМЕНИ:
  --    меняйте только COL_WIDTH.name ниже (по умолчанию 130).
  --    Остальные колонки сдвинутся автоматически через COL_X.name + COL_WIDTH.name.
  --
  -- Колонка "Звание" имеет фиксированную ширину 110px — вмещает "Крестный отец"
  -- (самое длинное из стандартных званий), и прижимается к правому краю.
  -- ============================================================================

  -- Координаты X для каждой колонки
  local COL_X = {
    icon    = 12,                              -- иконка класса (без заголовка)
    name    = 40,                              -- имя игрока
    gold    = 40 + 120,                        -- Gold
    gp      = 40 + 120 + 65,                   -- GP
    pr      = 40 + 120 + 65 + 55,              -- PR
    rank    = 40 + 120 + 65 + 55 + 55,         -- Звание
    attend  = 40 + 120 + 65 + 55 + 55 + 85,    -- Посещаемость
  }
  -- Ширины колонок
  local COL_WIDTH = {
    icon = 24,
    name = 120,
    gold = 65,
    gp   = 55,
    pr   = 55,
    rank = 85,
    attend = 70,                               -- посещаемость
  }

  -- Заголовки колонок (кликабельные для сортировки)
  local function create_header_btn(text, x, width, sort_key)
    local btn = CreateFrame("Button", nil, header)
    btn:SetSize(width, 22)
    btn:SetPoint("LEFT", header, "LEFT", x, 0)
    apply_backdrop(btn, COLORS.bg_panel, COLORS.border, 1)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("LEFT", btn, "LEFT", 4, 0)  -- прижать влево для длинных названий
    btn.text:SetText(text)
    btn.text:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
    btn:SetScript("OnEnter", function(self)
      self.text:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)
    end)
    btn:SetScript("OnLeave", function(self)
      self.text:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
    end)
    btn:SetScript("OnClick", function()
      if sort_key then
        sort_order = sort_key
        -- Персистим сортировку в profile.sort_order
        if Addon.db and Addon.db.profile then
          Addon.db.profile.sort_order = sort_key
        end
        UI:RefreshStandings()
      end
    end)
    return btn
  end

  -- Заголовки: НЕ создаём заголовок для icon-колонки (она без подписи, только иконки классов в строках)
  create_header_btn("Имя",   COL_X.name, COL_WIDTH.name, "NAME")
  -- Заголовок "EP" (не "Gold") — правило терминологии: пользовательский текст всегда EP
  create_header_btn("EP",  COL_X.gold, COL_WIDTH.gold, "GOLD")
  create_header_btn("GP",    COL_X.gp,   COL_WIDTH.gp,   "GP")
  create_header_btn("PR",    COL_X.pr,   COL_WIDTH.pr,   "PR")
  -- Звание
  local rank_header = create_header_btn("Звание", COL_X.rank, COL_WIDTH.rank, "RANK")
  rank_header.text:SetPoint("RIGHT", rank_header, "RIGHT", -4, 0)
  -- Колонка "Посещ." (счётчик посещаемости РТ)
  create_header_btn("Посещ.", COL_X.attend, COL_WIDTH.attend, "ATTEND")

  -- ============================================================================
  -- НИЖНИЙ FOOTER (1 ряд): справа 3 кнопки — Журнал | Обновить | Срез
  -- Высота 40px = отступ 8 + кнопка 24 + отступ 8
  -- SetFrameLevel(20) у footer — гарантированно выше строк игроков,
  -- чтобы строки не вылазили на footer при скролле.
  -- ============================================================================
  local footer = CreateFrame("Frame", nil, main_frame)
  footer:SetPoint("BOTTOMLEFT", main_frame, "BOTTOMLEFT", 2, 2)
  footer:SetPoint("BOTTOMRIGHT", main_frame, "BOTTOMRIGHT", -2, 2)
  footer:SetHeight(40)
  footer:SetFrameLevel(20)  -- ВАЖНО: выше строк (которые имеют FrameLevel по умолчанию)
  apply_backdrop(footer, COLORS.bg_panel, COLORS.border, 1)

  -- Справа: Журнал | Обновить | Срез
  -- Кнопка "Срез" выделена КРАСНЫМ (опасная операция — чтобы случайно не кликнуть)
  local decay_btn = create_button(footer, "Срез", 60, UIKit.BTN_H, function()
    Addon.Award:DecayWithConfirm()
  end)
  decay_btn:SetPoint("RIGHT", footer, "RIGHT", -10, 0)
  -- Кастомный красный стиль для кнопки "Срез"
  local DECAY_BG = { r = 0.30, g = 0.08, b = 0.08, a = 1.0 }       -- тёмно-красный фон
  local DECAY_BG_HOVER = { r = 0.55, g = 0.12, b = 0.12, a = 1.0 }  -- ярко-красный при hover
  local DECAY_BG_DOWN = { r = 0.15, g = 0.04, b = 0.04, a = 1.0 }   -- очень тёмный при нажатии
  local DECAY_BORDER = { r = 0.80, g = 0.20, b = 0.20, a = 1.0 }    -- красная рамка
  local DECAY_BORDER_HOVER = { r = 1.00, g = 0.35, b = 0.35, a = 1.0 }  -- яркая красная при hover
  apply_backdrop(decay_btn, DECAY_BG, DECAY_BORDER, 2)
  decay_btn.text:SetTextColor(1.00, 0.60, 0.60)  -- светло-красный текст
  -- Переопределяем hover/down скрипты для красной темы
  decay_btn:SetScript("OnEnter", function(self)
    apply_backdrop(self, DECAY_BG_HOVER, DECAY_BORDER_HOVER, 2)
    self.text:SetTextColor(1.00, 0.85, 0.85)
  end)
  decay_btn:SetScript("OnLeave", function(self)
    apply_backdrop(self, DECAY_BG, DECAY_BORDER, 2)
    self.text:SetTextColor(1.00, 0.60, 0.60)
  end)
  decay_btn:SetScript("OnMouseDown", function(self)
    apply_backdrop(self, DECAY_BG_DOWN, DECAY_BORDER_HOVER, 2)
  end)
  decay_btn:SetScript("OnMouseUp", function(self)
    apply_backdrop(self, DECAY_BG_HOVER, DECAY_BORDER_HOVER, 2)
  end)
  UI.decay_btn = decay_btn  -- для ApplyReadOnlyMode

  -- Кнопка "Обновить": GuildRoster + отложенные UpdateStandbyRaidSession /
  -- RequestStandbySnapshot. Кулдаун 3 сек — защита от шторма кликов.
  -- Задержка после GuildRoster: ростер должен обновиться до определения лидера.
  local refresh_cooldown_time = 0
  local refresh_btn = create_button(footer, "Обновить", 75, UIKit.BTN_H, function()
    local now = GetTime()
    if now - refresh_cooldown_time < 3.0 then
      Addon.Print("Обновить: подождите 3 сек между кликами")
      return
    end
    refresh_cooldown_time = now
    GuildRoster()
    Addon.Print("Запрос гильдейского ростера...")
    -- Отложенные standby-обновление + запрос снапшота (ростер должен
    -- обновиться раньше, чем определяется лидер рейда).
    -- Переиспользуем ОДИН delay-фрейм вместо создания нового при каждом
    -- клике (иначе — утечка фреймов).
    if not UI.refresh_delay_frame then
      UI.refresh_delay_frame = CreateFrame("Frame")
      UI.refresh_delay_frame:Hide()
    end
    local refresh_delay_frame = UI.refresh_delay_frame
    local refresh_delay = 0.75
    refresh_delay_frame:SetScript("OnUpdate", function(self, elapsed)
      refresh_delay = refresh_delay - elapsed
      if refresh_delay <= 0 then
        self:Hide()
        Addon:UpdateStandbyRaidSession("manual_refresh")
        Addon:RequestStandbySnapshot("manual_refresh")
      end
    end)
    refresh_delay_frame:Show()
  end)
  refresh_btn:SetPoint("RIGHT", decay_btn, "LEFT", -6, 0)

  local history_btn = create_button(footer, "Журнал", 65, UIKit.BTN_H, function()
    if Addon.History then
      Addon.History:Toggle()
    end
  end)
  history_btn:SetPoint("RIGHT", refresh_btn, "LEFT", -6, 0)

  -- Чекбокс "Показать всех" — если включён, показывает всех игроков гильдии
  -- (даже в рейде/группе). Если выключен (по умолчанию) — только рейд/группа/standby.
  local show_all_cb = CreateFrame("CheckButton", nil, footer, "UICheckButtonTemplate")
  show_all_cb:SetSize(20, 20)
  show_all_cb:SetPoint("LEFT", footer, "LEFT", 10, 0)
  show_all_cb:SetChecked(show_all_mode)
  show_all_cb:SetScript("OnClick", function(self)
    show_all_mode = self:GetChecked() and true or false
    UI:InvalidateStandings()
    UI:RefreshStandings()
  end)

  local show_all_label = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  show_all_label:SetPoint("LEFT", show_all_cb, "RIGHT", 4, 0)
  show_all_label:SetText("Показать всех")
  show_all_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Информационная плашка правее чекбокса.
  local footer_info = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  footer_info:SetPoint("LEFT", show_all_label, "RIGHT", 16, 0)
  footer_info:SetText("")
  footer_info:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  UI.footer_info = footer_info

  -- ScrollFrame для списка игроков (до footer)
  local scroll = CreateFrame("ScrollFrame", "GoldGPListScroll", main_frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -22, -2)
  scroll:SetPoint("BOTTOM", footer, "TOP", 0, -2)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() UI:RefreshStandings() end)
  end)

  -- Пустое состояние: показывается в RefreshStandings, когда игрок в гильдии,
  -- но ростер ещё не давал данных (первый вход / гильд-лок).
  UI.empty_state = UIKit.create_empty_state(GoldGPListScroll,
    "Нет данных для отображения\n\nОткройте гильд-ростер (клавиша J) — таблица заполняется\nиз офицерских нот при первом обновлении ростера.\nЕсли ростер не открывается — активен гильд-лок.")

  -- Сохраняем ссылки
  UI.frame = main_frame
  UI.recurring_btn = recurring_btn
  UI.COL_X = COL_X
  UI.COL_WIDTH = COL_WIDTH

  -- Начальная синхронизация кнопки "Фласки" (модуль мог загрузиться как до,
  -- так и после создания окна — см. комментарий к созданию кнопки)
  UI:SyncFlaskButton()

  -- Слушаем события для обновления
  -- Батчинг рефрешей: другой офицер может сделать flush при открытом окне —
  -- без батча каждая изменённая нота давала бы полный рефреш (сортировка +
  -- перерисовка всех строк). Один батч-рефреш по дебаунсу 0.2с.
  local note_dirty_frame = CreateFrame("Frame")
  note_dirty_frame:Hide()
  note_dirty_frame:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed >= 0.2 then
      self.elapsed = 0
      self:Hide()
      UI:InvalidateStandings()
      UI:RefreshStandings()
    end
  end)
  local function ScheduleBatchedRefresh()
    note_dirty_frame:Show()
  end

  Addon:RegisterCallback("NoteChanged", ScheduleBatchedRefresh)
  Addon:RegisterCallback("NoteDeleted", ScheduleBatchedRefresh)
  Addon:RegisterCallback("StorageStateChanged", ScheduleBatchedRefresh)
  -- Первый реальный ростер — один гарантированный рефреш
  Addon:RegisterCallback("RosterReady", function()
    UI:InvalidateStandings()
    UI:RefreshStandings()
  end)

  Addon:RegisterCallback("MassGoldDone", function()

    -- Обновить футер (статистика recurring)
    UI:RefreshStandings()
  end)
  -- Реальный обработчик RestoreDone живёт в History.lua.
  -- При остановке recurring — обновить футер
  Addon:RegisterCallback("StopRecurring", function()
    UI:RefreshStandings()
  end)
end

-- ============================================================================
-- СИНХРОНИЗАЦИЯ КНОПКИ "ФЛАСКИ"
-- ============================================================================
-- Показывает/скрывает кнопку в зависимости от (а) наличия модуля GoldGP_Flask
-- и (б) прав офицера; переключает якорь кнопки "Замены".
-- Вызывается из: CreateMainWindow, UI:Show, ApplyReadOnlyMode и самого
-- модуля GoldGP_Flask после загрузки (Addon.Flask = Flask -> notify).
function UI:SyncFlaskButton()
  local btn = UI.flask_btn
  if not btn then return end
  local module_ok = (Addon.Flask ~= nil)
  local officer = (Addon.state and Addon.state.can_edit) or false
  if module_ok and officer then
    btn:Show()
    -- "Замены" прижата к кнопке фласков
    if UI.standby_btn then
      UI.standby_btn:ClearAllPoints()
      UI.standby_btn:SetPoint("LEFT", btn, "RIGHT", 4, 0)
    end
  else
    btn:Hide()
    -- Модуля нет — "Замены" прижимается к "Рт таймер" (без дырки в тулбаре)
    if UI.standby_btn and UI.recurring_btn then
      UI.standby_btn:ClearAllPoints()
      UI.standby_btn:SetPoint("LEFT", UI.recurring_btn, "RIGHT", 6, 0)
    end
  end
end

-- Разовая диагностика для кейса "аддон фласков включен, а кнопки нет".
-- Молчит, если аддон GoldGP_Flask просто не установлен (норма для не-офицеров).
local flask_hint_shown = false
local function MaybeShowFlaskHint()
  if flask_hint_shown then return end
  if Addon.Flask then return end  -- модуль есть — проблем нет
  flask_hint_shown = true
  -- IsAddOnLoaded/GetAddOnInfo доступны в 3.3.5a
  local ok_loaded, loaded = pcall(IsAddOnLoaded, "GoldGP_Flask")
  if ok_loaded and loaded then
    -- Аддон загружен, но Addon.Flask ещё не выставлен: либо модуль ждёт ядро
    -- (отложенный старт до 30с — восстановится сам), либо упал с ошибкой.
    Addon.PrintError("GoldGP_Flask загружен, но модуль ещё не инициализировался. Если сообщение не исчезнет через 30с или после /reload — смотрите ошибки интерфейса (если модуль просто ждал ядро — он доинициализируется сам).")
    return
  end
  local ok_info, name = pcall(GetAddOnInfo, "GoldGP_Flask")
  if ok_info and name then
    Addon.PrintError("Аддон GoldGP_Flask установлен, но отключён. Включите его в списке аддонов и выполните /reload — появится кнопка \"Фласки\".")
  end
  -- Аддона нет вообще — молчим (норма для не-офицеров)
end

-- ============================================================================
-- МЕТКИ СОСТОЯНИЯ Storage (для footer_info в RefreshStandings)
-- ============================================================================
local STATE_LABELS = {
  ["CURRENT"]                            = "Готов",
  ["FLUSHING"]                           = "Запись...",
  ["STALE"]                              = "Обновление...",
  ["STALE_WAITING_FOR_ROSTER_UPDATE"]    = "Ожидание...",
  ["REMOTE_FLUSHING"]                    = "Синхр....",
  ["UNINITIALIZED"]                      = "Не загружен",
}

-- ============================================================================
-- ПОКАЗ/СКРЫТИЕ ОКНА
-- ============================================================================
function UI:Toggle()
  -- nil-check Addon.db
  if not Addon.db then
    Addon.PrintError("Аддон ещё загружается, подождите 2 сек и повторите /gg")
    return
  end
  -- Гильд-лок
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — аддон работает только в разрешённой гильдии")
    return
  end
  if not main_frame then
    self:Initialize()
  end
  if not main_frame then return end  -- Initialize мог вернуть early
  if main_frame:IsShown() then
    self:Hide()
  else
    main_frame:Show()
    UI:SyncFlaskButton()
    MaybeShowFlaskHint()
    self:RefreshStandings()
  end
end

function UI:Show()
  -- nil-check Addon.db
  if not Addon.db then
    Addon.PrintError("Аддон ещё загружается, подождите 2 сек и повторите /gg")
    return
  end
  -- Гильд-лок
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — аддон работает только в разрешённой гильдии")
    return
  end
  if not main_frame then self:Initialize() end
  if not main_frame then return end
  main_frame:Show()
  UI:SyncFlaskButton()
  MaybeShowFlaskHint()
  self:RefreshStandings()
end

function UI:Hide()
  if main_frame then main_frame:Hide() end
  -- При закрытии /gg закрываем диалоги начисления и Журнал
  if Addon.Dialog then
    -- Закрываем все диалоги Dialog.lua
    if GoldGPAwardPlayerDialog then GoldGPAwardPlayerDialog:Hide() end
    if GoldGPMassAwardDialog then GoldGPMassAwardDialog:Hide() end
    if GoldGPRecurringDialog then GoldGPRecurringDialog:Hide() end
  end
  if Addon.History then
    Addon.History:Hide()
  end
end

-- ============================================================================
-- КОНТЕКСТНОЕ МЕНЮ ПКМ
-- ============================================================================
-- context_menu_frame создаётся ЛЕНИВО (внутри функции), а не при загрузке
-- файла: UIDropDownMenuTemplate может быть ещё недоступен — иначе упадёт
-- загрузка всего GoldGP_UI.lua.
local context_menu_frame = nil

function UI:ShowContextMenu(name)
  if not name then return end

  -- Ленивое создание фрейма меню
  if not context_menu_frame then
    context_menu_frame = CreateFrame("Frame", "GoldGPContextMenu", UIParent, "UIDropDownMenuTemplate")
  end

  local is_on_leave = Addon:IsOnLeave(name)
  local leave_label = is_on_leave and "Снять отпуск" or "Отпуск"
  -- Read-only mode — не-офицерам скрываем пункты начисления и отпуска.
  -- can_edit обновляется в GUILD_ROSTER_UPDATE / PLAYER_ENTERING_WORLD.
  local can_edit = Addon.state.can_edit

  local menu_items = {
    {
      text = "|cFFFFD700" .. name .. "|r",
      isTitle = true,
      notCheckable = true,
    },
  }

  -- Пункты начисления только для офицеров
  if can_edit then
    tinsert(menu_items, {
      text = "Дать EP",
      notCheckable = true,
      func = function()
        if Addon.Dialog then
          Addon.Dialog:ShowAwardPlayer(name, "gold")
        end
      end,
    })
    tinsert(menu_items, {
      text = "Дать GP",
      notCheckable = true,
      func = function()
        if Addon.Dialog then
          Addon.Dialog:ShowAwardPlayer(name, "gp")
        end
      end,
    })
  end

  tinsert(menu_items, {
    text = "Пригласить в группу",
    notCheckable = true,
    func = function()
      InviteUnit(name)
      Addon.Print("Приглашение отправлено: " .. name)
    end,
  })

  -- Пункт "Отпуск" только для офицеров
  if can_edit then
    tinsert(menu_items, {
      text = "|cFF8888FF" .. leave_label .. "|r",
      notCheckable = true,
      func = function()
        Addon:SetOnLeave(name, not is_on_leave)
        if not is_on_leave then
          Addon.Print(name .. " — в отпуске (не получает EP/GP/decay)")
        else
          Addon.Print(name .. " — вернулся из отпуска")
        end
      end,
    })
  end

  -- Пункт "Отмена" — закрывает контекстное меню без действия
  tinsert(menu_items, {
    text = "|cFFB04040Отмена|r",
    notCheckable = true,
    func = function()
      CloseDropDownMenus()
    end,
  })

  EasyMenu(menu_items, context_menu_frame, "cursor", 0, 0, "MENU")
end

-- ============================================================================
-- ОБНОВЛЕНИЕ STANDINGS (сортировка + перерисовка строк)
-- ============================================================================
-- Кэш результата сортировки: инвалидируется при изменении sort_order,
-- in_raid, show_all_mode, cache_version или member_count.
-- До 5x ускорение прокрутки на гильдиях 200+ человек.
local standings_cache = nil
local standings_cache_signature = ""

local function get_standings_sorted()
  -- Считаем "подпись" — если изменилась, кэш невалиден
  local raid_sig = Addon.state.in_raid and "raid" .. GetNumRaidMembers() or "noraid"
  -- cache_version в подписи: инвалидирует кэш при любой мутации данных
  -- (IncGold, IncGP, Decay, Reset, ParseNote вызывают BumpCacheVersion)
  local cache_ver = Addon.data.cache_version or 0
  -- show_all_mode: true = показывать всех
  local se_sig = show_all_mode and "showall" or "raidonly"
  local sig = string.format("%s|%s|%s|%d|%d",
    sort_order or "", raid_sig, se_sig,
    cache_ver,
    -- Кэшированный member_count вместо O(N) прохода: обновляется в
    -- Storage:FrameOnUpdate после синхронизации ростера.
    (Addon.data.member_count or 0))
  if standings_cache and sig == standings_cache_signature then
    return standings_cache
  end
  standings_cache_signature = sig

  local standings = {}
  for name in pairs(Addon.data.gold_data) do
    -- Alt'ы видны ТОЛЬКО если они в рейде/группе/standby.
    -- show_all_mode НЕ распространяется на alt'ов — "Показать всех" = все main'ы.
    if Addon.data.main_data[name] then
      -- Это alt — показываем только если в рейде/группе/standby
      if Addon.state.raid_members[name]
         or Addon:IsStandby(name)
         or UI:IsInPartyMember(name) then
        tinsert(standings, name)
      end
    -- Фильтр по show_all_mode:
    -- show_all_mode = false (по умолчанию) → показывать только рейд/группу/standby.
    -- show_all_mode = true → показывать всех.
    -- Если не в рейде и не в группе — фильтр игнорируется (показываем всех).
    -- IsUnitInParty не существует в 3.3.5a: рейд покрывает raid_members,
    -- для 5-man группы проверяем через UI:IsInPartyMember(name).
    elseif not show_all_mode and (Addon.state.in_raid or GetNumPartyMembers() > 0)
      and not Addon.state.raid_members[name]
      and not Addon:IsStandby(name)
      and not UI:IsInPartyMember(name)
    then
      -- пропускаем тех, кто не в рейде/группе и не на замене
    else
      tinsert(standings, name)
    end
  end

  -- Сортировка
  if sort_order == "NAME" then
    table.sort(standings, function(a, b) return a < b end)
  elseif sort_order == "GOLD" then
    table.sort(standings, function(a, b)
      local ga = Addon.data.gold_data[a] or 0
      local gb = Addon.data.gold_data[b] or 0
      return ga > gb
    end)
  elseif sort_order == "GP" then
    table.sort(standings, function(a, b)
      local ga = Addon.data.gp_data[a] or 0
      local gb = Addon.data.gp_data[b] or 0
      return ga > gb
    end)
  elseif sort_order == "PR" then
    table.sort(standings, function(a, b)
      local ga, pa = Addon:GetMemberData(a)
      local gb, pb = Addon:GetMemberData(b)
      if not ga or not gb then return false end
      local pra = pa > 0 and ga / pa or 0
      local prb = pb > 0 and gb / pb or 0
      return pra > prb
    end)
  -- Сортировки "CLASS" нет (ни один заголовок её не выставляет). Если
  -- понадобится — вернуть вместе с заголовком колонки.
  elseif sort_order == "RANK" then
    table.sort(standings, function(a, b)
      local ra = Addon.data.rank_data[a] or 99
      local rb = Addon.data.rank_data[b] or 99
      if ra == rb then return a < b end
      return ra < rb
    end)
  end

  -- Приоритет: сначала те, кто в рейде
  -- Внутри "в рейде" — по subgroup, внутри "не в рейде" — по PR (сохраняем выбранную сортировку).
  -- Tiebreaker'ы обязательны: table.sort в Lua 5.1 нестабилен.
  if Addon.state.in_raid then
    table.sort(standings, function(a, b)
      local a_in = Addon.state.raid_members[a] and 1 or 0
      local b_in = Addon.state.raid_members[b] and 1 or 0
      if a_in ~= b_in then return a_in > b_in end
      if a_in == 1 then
        -- Оба в рейде — сортируем по subgroup (P1, P2, ..., P8)
        local sa = Addon.state.raid_subgroups[a] or 99
        local sb = Addon.state.raid_subgroups[b] or 99
        if sa ~= sb then return sa < sb end
        -- Одинаковый subgroup — по PR как tiebreaker
        local ga, pa = Addon:GetMemberData(a)
        local gb, pb = Addon:GetMemberData(b)
        local pra = (pa and pa > 0 and ga) and ga / pa or 0
        local prb = (pb and pb > 0 and gb) and gb / pb or 0
        if pra ~= prb then return pra > prb end
        return a < b
      else
        -- Оба НЕ в рейде — сохраняем выбранную сортировку (PR по умолчанию)
        -- Используем PR как tiebreaker для стабильного порядка
        local ga, pa = Addon:GetMemberData(a)
        local gb, pb = Addon:GetMemberData(b)
        local pra = (pa and pa > 0 and ga) and ga / pa or 0
        local prb = (pb and pb > 0 and gb) and gb / pb or 0
        if pra ~= prb then return pra > prb end
        return a < b
      end
    end)
  end

  standings_cache = standings
  return standings
end

-- Публичный метод для инвалидации кэша (вызывается при NoteChanged/RAID_ROSTER_UPDATE)
function UI:InvalidateStandings()
  standings_cache = nil
  standings_cache_signature = ""
end

-- Проверка — находится ли игрок в 5-man группе (не рейде).
-- WoW 3.3.5a не имеет API IsUnitInParty(name) — проверяем вручную через party1..partyN.
function UI:IsInPartyMember(name)
  if not name then return false end
  if UnitName("player") == name then return true end
  local n = GetNumPartyMembers()
  for i = 1, n do
    local unit = "party" .. i
    local pname = UnitName(unit)
    if pname == name then return true end
  end
  return false
end

-- ============================================================================
-- ПЕРЕРИСОВКА СТРОК
-- ============================================================================
-- ВАЖНО: VISIBLE_ROWS НЕ хардкодить — число видимых строк вычисляется из
-- реальной высоты скролл-области (+2px допуска на стык); высота окна из
-- профиля может быть любой.
local function GetVisibleRows()
  if not GoldGPListScroll then return 15 end
  local h = GoldGPListScroll:GetHeight() or 0
  if h < ROW_HEIGHT then return 1 end
  return math.floor((h + 2) / ROW_HEIGHT)
end

-- Read-only mode для не-офицеров.
-- Скрывает кнопки начисления (Масс EP, Рт таймер, Срез, Замены) если нет прав.
-- can_edit обновляется в GUILD_ROSTER_UPDATE (Core.lua). ApplyReadOnlyMode
-- вызывается из RefreshStandings при изменении can_edit.
local last_can_edit = nil
function UI:ApplyReadOnlyMode()
  local can_edit = Addon.state.can_edit
  if can_edit == last_can_edit then return end  -- нет изменений - выходим
  last_can_edit = can_edit

  -- Кнопки требующие прав на офицерские ноты
  -- flask_btn исключён из общего цикла — его видимость = модуль + офицер
  --         (см. SyncFlaskButton), а не только офицер.
  local officer_buttons = { UI.mass_gold_btn, UI.recurring_btn, UI.decay_btn, UI.standby_btn }
  for _, btn in ipairs(officer_buttons) do
    if btn then
      if can_edit then
        btn:Show()
        btn:Enable()
      else
        btn:Hide()
      end
    end
  end
  UI:SyncFlaskButton()

  -- Бейдж read-only в заголовке
  if UI.ro_badge then
    if can_edit then
      UI.ro_badge:Hide()
    else
      UI.ro_badge:Show()
    end
  end

  if Addon.Log then
    Addon.Log:Debug("ApplyReadOnlyMode: can_edit=%s, officer buttons %s",
      tostring(can_edit), can_edit and "shown" or "hidden")
  end
end

function UI:RefreshStandings()
  if not main_frame or not main_frame:IsShown() then return end

  -- Обновляем read-only mode (скрываем кнопки для не-офицеров)
  UI:ApplyReadOnlyMode()

  -- Если игрок не в гильдии — показываем сообщение вместо списка
  local in_guild = IsInGuild and IsInGuild() or false
  if not in_guild then
    if UI.no_guild_text then UI.no_guild_text:Show() end
    -- Скрываем scroll frame и строки
    if GoldGPListScroll then GoldGPListScroll:Hide() end
    for i = 1, #rows do
      if rows[i] then rows[i]:Hide() end
    end
    return
  else
    if UI.no_guild_text then UI.no_guild_text:Hide() end
    if GoldGPListScroll then GoldGPListScroll:Show() end
  end

  local standings = get_standings_sorted()
  local total = #standings

  -- Пустое состояние: в гильдии, но данных ещё нет
  if UI.empty_state then
    if total == 0 then UI.empty_state:Show() else UI.empty_state:Hide() end
  end

  -- Обновляем информационную плашку в footer
  -- Если включён recurring — показываем статистику вместо состава рейда.
  if UI.footer_info then
    local in_raid = Addon.state.in_raid
    local raid_count = in_raid and GetNumRaidMembers() or 0
    -- Состояние Storage с цветом
    local state = Addon.Storage:GetState()
    local state_color
    if state == "CURRENT" then
      state_color = "|cFF30AA30"  -- зелёный
    elseif state == "UNINITIALIZED" then
      state_color = "|cFFFF5050"  -- красный
    else
      state_color = "|cFFFFAA00"  -- оранжевый (FLUSHING/STALE/REMOTE_FLUSHING)
    end
    local state_label = STATE_LABELS[state] or state
    local state_str = state_color .. state_label .. "|r"
    if Addon.Award and Addon.Award.RunningRecurring and Addon.Award:RunningRecurring() then
      local total_ep, count = Addon.Award:GetRecurringStats()
      local reason = Addon.db.profile.next_award_reason or "Рт по таймеру"
      UI.footer_info:SetText(string.format("%s | |cFFFFD700%s:|r |cFF30AA30%d EP|r / |cFFFFAA00%d|r",
        state_str, reason, total_ep, count))
    elseif in_raid and raid_count > 0 then
      UI.footer_info:SetText(string.format("%s | В рейде: |cFF30AA30%d|r | Всего: %d | |cFFFFD700РТ:|r |cFF30AA30%d|r",
        state_str, raid_count, total, Addon:GetAttendanceTotal() or 0))
    else
      UI.footer_info:SetText(string.format("%s | Всего: %d | |cFFFFD700РТ:|r |cFF30AA30%d|r",
        state_str, total, Addon:GetAttendanceTotal() or 0))
    end
  end

  local visible_rows = GetVisibleRows()
  local scroll_offset = FauxScrollFrame_GetOffset(GoldGPListScroll)
  local max_visible = math.min(visible_rows, total - scroll_offset)

  -- Создаём или переиспользуем строки
  for i = 1, visible_rows do
    local row = rows[i]
    if not row then
      row = self:CreateRow(i)
      rows[i] = row
    end

    local idx = i + scroll_offset
    if idx <= total and i <= max_visible then
      local name = standings[idx]
      self:UpdateRow(row, name, idx)
      row:Show()
    else
      row:Hide()
    end
  end

  FauxScrollFrame_Update(GoldGPListScroll, total, visible_rows, ROW_HEIGHT)
end

-- Создать строку (один раз, потом переиспользуем)
function UI:CreateRow(idx)
  local row = CreateFrame("Button", nil, main_frame)
  row:SetSize(main_frame:GetWidth() - 24, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", GoldGPListScroll, "TOPLEFT", 0, -((idx - 1) * ROW_HEIGHT))
  apply_backdrop(row, COLORS.bg_row, COLORS.border, 1)

  -- Иконка класса
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetTexture(CLASS_ICON_TEXTURE)
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", row, "LEFT", 3, 0)

  -- Маркер присутствия в рейде — галочка СПРАВА от имени.
  -- Используем текстуру чекбокса Interface\Buttons\UI-CheckBox-Check (галочка).
  row.raid_dot = row:CreateTexture(nil, "OVERLAY")
  row.raid_dot:SetSize(14, 14)
  row.raid_dot:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  row.raid_dot:SetVertexColor(0.2, 0.9, 0.3, 1)  -- зелёная галочка
  row.raid_dot:Hide()  -- позиция выставляется в UpdateRow после имени

  -- Имя
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetSize(UI.COL_WIDTH.name, ROW_HEIGHT)
  row.name:SetJustifyH("LEFT")

  -- Gold
  row.gold = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.gold:SetPoint("LEFT", row, "LEFT", UI.COL_X.gold, 0)
  row.gold:SetSize(UI.COL_WIDTH.gold, ROW_HEIGHT)
  row.gold:SetJustifyH("RIGHT")

  -- GP
  row.gp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.gp:SetPoint("LEFT", row, "LEFT", UI.COL_X.gp, 0)
  row.gp:SetSize(UI.COL_WIDTH.gp, ROW_HEIGHT)
  row.gp:SetJustifyH("RIGHT")

  -- PR
  row.pr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.pr:SetPoint("LEFT", row, "LEFT", UI.COL_X.pr, 0)
  row.pr:SetSize(UI.COL_WIDTH.pr, ROW_HEIGHT)
  row.pr:SetJustifyH("RIGHT")

  -- Звание — фиксированная ширина, прижим вправо
  row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.rank:SetPoint("LEFT", row, "LEFT", UI.COL_X.rank, 0)
  row.rank:SetSize(UI.COL_WIDTH.rank, ROW_HEIGHT)
  row.rank:SetJustifyH("RIGHT")

  -- Колонка "Посещ." — текстовый счётчик
  row.attend = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.attend:SetPoint("LEFT", row, "LEFT", UI.COL_X.attend, 0)
  row.attend:SetSize(UI.COL_WIDTH.attend, ROW_HEIGHT)
  row.attend:SetJustifyH("CENTER")

  -- Hover effects
  -- Цвет фона строки при hover зависит от того, в рейде ли игрок.
  -- Игрок в рейде имеет слегка зеленоватый фон (raid-tint), остальные — обычный hover.
  local RAID_TINT = { r = 0.05, g = 0.14, b = 0.05, a = 0.75 }
  row:SetScript("OnEnter", function(self)
    local rname = self.row_data and self.row_data.name
    local is_raid = rname and Addon.state.raid_members and Addon.state.raid_members[rname]
    if is_raid then
      apply_backdrop(self, { r = 0.15, g = 0.22, b = 0.10, a = 0.95 }, COLORS.border_gold, 1)
    else
      apply_backdrop(self, COLORS.bg_row_hover, COLORS.border_gold, 1)
    end
    if self.row_data and self.row_data.tooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(self.row_data.tooltip, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", function(self)
    local rname = self.row_data and self.row_data.name
    local is_raid = rname and Addon.state.raid_members and Addon.state.raid_members[rname]
    if is_raid then
      apply_backdrop(self, RAID_TINT, COLORS.border, 1)
    else
      apply_backdrop(self, COLORS.bg_row, COLORS.border, 1)
    end
    GameTooltip:Hide()
  end)

  -- Click -> открыть диалог начисления (ЛКМ) или контекстное меню (ПКМ)
  row:SetScript("OnClick", function(self, button)
    if button == "LeftButton" and self.row_data and self.row_data.name then
      if Addon.Dialog then
        Addon.Dialog:ShowAwardPlayer(self.row_data.name)
      end
    elseif button == "RightButton" and self.row_data and self.row_data.name then
      local name = self.row_data.name
      UI:ShowContextMenu(name)
    end
  end)

  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  return row
end

-- Обновить данные в строке
function UI:UpdateRow(row, name, idx)
  row.row_data = { name = name }

  local gold, gp, main = Addon:GetMemberData(name)
  -- Addon:GetClassToken — многослойный резолв:
  --   class_data[name] -> class_data[main] -> живой UnitClass (если игрок в рейде/группе).
  local class = Addon.GetClassToken and Addon:GetClassToken(name, main) or Addon.data.class_data[name]
  local rank_idx = Addon.data.rank_data[name]

  -- Иконка класса
  if class and CLASS_ICON_TCOORDS[class] then
    row.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[class]))
    row.icon:Show()
  else
    row.icon:Hide()
  end

  -- Имя с цветом класса
  local display_name = name
  if main then
    -- Alt в рейде без main — пометка "твин"
    if Addon.state.raid_members[name] and not Addon.state.raid_members[main] then
      display_name = name .. " |cFF808080[" .. main .. " - твин]|r"
    else
      display_name = name .. " |cFF808080(" .. main .. ")|r"
    end
  end
  -- Игрок "в отпуске" — добавить пометку
  if Addon.data.on_leave[name] then
    display_name = display_name .. " |cFF8888FF[отпуск]|r"
  end
  -- Игрок на замене — добавить пометку
  if Addon:IsStandby(name) then
    display_name = display_name .. " |cFF30AA30[Замена]|r"
  end
  local ccolor = class and CLASS_COLORS[class] or COLORS.text_main
  row.name:SetText(display_name)
  row.name:SetTextColor(ccolor.r, ccolor.g, ccolor.b)

  -- Игрок в рейде — зелёная галочка + зеленоватый фон строки.
  -- Цвет класса имени СОХРАНЯЕТСЯ.
  local RAID_TINT = { r = 0.05, g = 0.14, b = 0.05, a = 0.75 }
  local is_in_raid = Addon.state.raid_members[name]
  if is_in_raid then
    if row.raid_dot then
      -- Галочка справа от имени
      row.raid_dot:ClearAllPoints()
      row.raid_dot:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
      row.raid_dot:Show()
    end
    apply_backdrop(row, RAID_TINT, COLORS.border, 1)
  else
    if row.raid_dot then row.raid_dot:Hide() end
    apply_backdrop(row, COLORS.bg_row, COLORS.border, 1)
  end

  -- Игрок "в отпуске" — приглушить цвет имени
  if Addon.data.on_leave[name] then
    -- Смешать цвет класса с серым (50/50) для приглушённого вида
    local dim_r = (ccolor.r + 0.4) / 2
    local dim_g = (ccolor.g + 0.4) / 2
    local dim_b = (ccolor.b + 0.4) / 2
    row.name:SetTextColor(dim_r, dim_g, dim_b)
  end

  -- Gold
  if gold then
    row.gold:SetText(tostring(gold))
    row.gold:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)
  else
    row.gold:SetText("-")
    row.gold:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end

  -- GP
  if gp then
    row.gp:SetText(tostring(gp))
    row.gp:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)
  else
    row.gp:SetText("-")
    row.gp:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end

  -- PR
  if gold and gp and gp > 0 then
    local pr = gold / gp
    row.pr:SetText(string.format("%.2f", pr))
    -- Цвет PR: высокий — зелёный, низкий — красный
    local min_gold = Addon.db.profile.min_gold or 0
    if gold >= min_gold then
      row.pr:SetTextColor(COLORS.text_success.r, COLORS.text_success.g, COLORS.text_success.b)
    else
      row.pr:SetTextColor(COLORS.text_error.r, COLORS.text_error.g, COLORS.text_error.b)
    end
  else
    row.pr:SetText("-")
    row.pr:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end

  -- Звание: показываем ПОЛНОЕ имя звания с цветом по иерархии
  -- (Дон=золотой, Крестный отец=фиолетовый, ..., Шестерка=тёмно-серый)
  local rank_name = Addon:GetRankName(name) or Addon.data.rank_name_data[name]
  if rank_name and rank_name ~= "" then
    row.rank:SetText(rank_name)
    -- Получаем цвет из Addon:GetRankColor (учитывает имя звания + fallback по индексу)
    local rc = Addon:GetRankColor(name)
    row.rank:SetTextColor(rc.r, rc.g, rc.b)
  else
    row.rank:SetText("-")
    row.rank:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end

  -- Посещаемость: только individual count (total показывается в footer_info)
  local att_count = Addon:GetAttendanceCount(name) or 0
  row.attend:SetText(tostring(att_count))
  -- Цвет: 0 — серый, 100% — золотой, <50% — красноватый, иначе белый
  local att_total = Addon:GetAttendanceTotal() or 0
  if att_count == 0 then
    row.attend:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  elseif att_total > 0 and att_count >= att_total then
    row.attend:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)
  elseif att_total > 0 and (att_count / att_total) < 0.5 then
    row.attend:SetTextColor(0.8, 0.3, 0.3)
  else
    row.attend:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)
  end

  -- Tooltip с доп. информацией
  local sg = Addon.state.raid_subgroups[name]
  local tt = name

  -- Если это main — показать его альтов
  local alts = Addon.data.alt_data[name]
  if alts and #alts > 0 then
    tt = tt .. "\n|cFF808080Альты:|r " .. table.concat(alts, ", ")
  end

  -- Если это alt — показать main
  if main then
    tt = tt .. "\n|cFF808080Main:|r " .. main
  end

  -- Статус "в отпуске"
  if Addon.data.on_leave and Addon.data.on_leave[name] then
    tt = tt .. "\n|cFF8888FFВ отпуске|r"
  end
  -- Статус standby
  if Addon:IsStandby(name) then
    tt = tt .. "\n|cFF30AA30На замене (standby)|r"
  end

  -- В рейде?
  if Addon.state.raid_members[name] then
    tt = tt .. "\n|cFF30AA30В рейде|r"
    if sg and sg > 0 then
      tt = tt .. " (Party " .. sg .. ")"
      -- Подсказка о party-split
      local p = Addon.db.profile
      if p and p.party_split_enabled then
        local threshold = p.party_split_threshold or 5
        local pct = p.party_split_percent or 50
        if sg <= threshold then
          tt = tt .. " |cFF30AA30— 100% Gold|r"
        else
          tt = tt .. " |cFFF0A000— " .. pct .. "% Gold|r"
        end
      end
    end
  end
  if Addon.data.ignored[name] then tt = tt .. "\n|cFFFF5050IGNORED: " .. tostring(Addon.data.ignored[name]) .. "|r" end
  row.row_data.tooltip = tt
end

-- ============================================================================
-- ОКНО STANDBY СПИСКА
-- Показывает игроков на замене. Кнопка "Убрать" снимает со standby.
-- ============================================================================
local standby_frame = nil
local standby_rows = {}

function UI:ShowStandbyWindow()
  -- Окно "Замены" — полностью ОФИЦЕРСКАЯ функция: не-офицеры не должны
  -- видеть кнопку и вообще иметь доступ к функции.
  -- Кнопка в тулбаре скрывается через ApplyReadOnlyMode, здесь — защита от
  -- обходных путей (slash-команды, /run, макросы).
  if not (Addon.state and Addon.state.can_edit) then
    Addon.PrintError("Список замен доступен только офицерам (право редактирования офицерских заметок)")
    return
  end
  if standby_frame and standby_frame:IsShown() then
    standby_frame:Hide()
    return
  end
  if not standby_frame then
    standby_frame = CreateFrame("Frame", "GoldGPStandbyFrame", UIParent)
    standby_frame:SetSize(280, 320)
    standby_frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    apply_backdrop(standby_frame, COLORS.bg_main, COLORS.border_gold, 2)
    standby_frame:SetFrameStrata("DIALOG")
    standby_frame:EnableMouse(true)
    standby_frame:SetMovable(true)
    standby_frame:SetScript("OnMouseDown", function(self) self:StartMoving() end)
    standby_frame:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
    standby_frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "GoldGPStandbyFrame")

    local title = standby_frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", standby_frame, "TOP", 0, -10)
    title:SetText("|cFFFFD700Замены (Standby)|r")
    title:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

    local hint = standby_frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
    hint:SetText("|cFF808080Шепните офицеру 'standby' чтобы попасть в список|r")
    hint:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

    local close_btn = create_button(standby_frame, "Закрыть", 80, UIKit.BTN_H_SM, function()
      standby_frame:Hide()
    end)
    close_btn:SetPoint("BOTTOM", standby_frame, "BOTTOM", 0, 10)

    -- Кнопка "Очистить" только для офицеров
    local clear_btn = create_button(standby_frame, "Очистить", 80, UIKit.BTN_H_SM, function()
      StaticPopupDialogs["GOLDGP_CLEAR_STANDBY"] = {
        text = "Очистить весь список замен?",
        button1 = "Да",
        button2 = "Нет",
        timeout = 0,
        hideOnEscape = 1,
        OnAccept = function()
          Addon:ClearStandby()
          UI:RefreshStandbyWindow()
        end,
      }
      StaticPopup_Show("GOLDGP_CLEAR_STANDBY")
    end)
    clear_btn:SetPoint("BOTTOMRIGHT", standby_frame, "BOTTOMRIGHT", -10, 10)
    -- Скрыть для не-офицеров
    if not Addon:CanEditOfficerNote() then
      clear_btn:Hide()
    end
    standby_frame.clear_btn = clear_btn

    -- Строки будут создаваться динамически в RefreshStandbyWindow
    standby_frame.title = title
    standby_frame.hint = hint
  end

  -- СНАЧАЛА Show(), потом RefreshStandbyWindow()
  standby_frame:Show()
  UI:RefreshStandbyWindow()
end

function UI:RefreshStandbyWindow()
  -- НЕ проверять IsShown — только существование фрейма
  if not standby_frame then return end

  -- Очистить старые строки
  for i = 1, #standby_rows do
    if standby_rows[i] then
      standby_rows[i]:Hide()
    end
  end

  -- Собрать список standby
  local names = {}
  for name, _ in pairs(Addon.state.standby or {}) do
    tinsert(names, name)
  end
  table.sort(names)

  -- Заголовок-счётчик
  if standby_frame.title then
    standby_frame.title:SetText(string.format("|cFFFFD700Замены (Standby): %d|r", #names))
  end

  -- Создать/обновить строки
  local y_offset = -50
  for i, name in ipairs(names) do
    if i > 12 then break end  -- максимум 12 строк
    local row = standby_rows[i]
    if not row then
      row = CreateFrame("Frame", nil, standby_frame)
      row:SetSize(260, 22)
      apply_backdrop(row, COLORS.bg_row, COLORS.border, 1)
      standby_rows[i] = row
    end
    row:SetPoint("TOP", standby_frame, "TOP", 0, y_offset)
    y_offset = y_offset - 24

    if not row.name_text then
      row.name_text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.name_text:SetPoint("LEFT", row, "LEFT", 8, 0)
    end
    row.name_text:SetText(name)
    row.name_text:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

    if not row.remove_btn then
      row.remove_btn = create_button(row, "X", 22, UIKit.BTN_H_SM, function()
        Addon:SetStandby(name, false)
        Addon.Print(name .. " снят с замены")
        UI:RefreshStandbyWindow()
      end)
      row.remove_btn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end
    row.remove_btn.name = name  -- обновить замыкание
    row.remove_btn:SetScript("OnClick", function()
      Addon:SetStandby(row.remove_btn.name, false)
      Addon.Print(row.remove_btn.name .. " снят с замены")
      UI:RefreshStandbyWindow()
    end)
    -- Скрыть X для не-офицеров
    if Addon:CanEditOfficerNote() then
      row.remove_btn:Show()
    else
      row.remove_btn:Hide()
    end

    row:Show()
  end

  -- Скрыть лишние строки
  for i = #names + 1, #standby_rows do
    if standby_rows[i] then standby_rows[i]:Hide() end
  end

  -- Подогнать высоту окна
  local height = math.max(160, 60 + #names * 24 + 40)
  standby_frame:SetHeight(height)
end

if Addon.Log then Addon.Log:Info("GoldGP_UI loaded") end
