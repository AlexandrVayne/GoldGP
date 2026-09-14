-- GoldGP_Options.lua

local Addon = GoldGP
local Options = {}
Addon.Options = Options

-- UI-виджеты берутся напрямую из Addon.UIKit (загружается раньше в .toc);
-- create_section_header/create_checkbox — общие фабрики UIKit.

-- ============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ДЛЯ СОЗДАНИЯ ВИДЖЕТОВ
-- ============================================================================

local function create_slider_float(parent, label_text, min_val, max_val, step, get_func, set_func, anchor_frame, y_offset)
  local COLORS = Addon.UIKit.COLORS
  local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
  slider:SetOrientation("HORIZONTAL")
  slider:SetMinMaxValues(min_val, max_val)
  slider:SetValueStep(step)
  slider:SetValue(get_func() or min_val)
  slider:SetWidth(220)
  if anchor_frame then
    slider:SetPoint("TOPLEFT", anchor_frame, "BOTTOMLEFT", 0, y_offset or -20)
  else
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y_offset or -20)
  end

  slider.label = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  slider.label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 4)
  slider.label:SetText(label_text)
  slider.label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  slider.valueText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  slider.valueText:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", 0, 4)
  slider.valueText:SetText(string.format("%.2f", get_func() or min_val))
  slider.valueText:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)

  slider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value * 100 + 0.5) / 100
    self.valueText:SetText(string.format("%.2f", value))
    set_func(value)
  end)

  if slider.LowText then
    slider.LowText:SetText(string.format("%.2f", min_val))
    slider.LowText:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end
  if slider.HighText then
    slider.HighText:SetText(string.format("%.2f", max_val))
    slider.HighText:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end
  if slider.Text then slider.Text:SetText("") end

  return slider
end

-- ============================================================================
-- ВКЛАДКА 1: ОБЩИЕ НАСТРОЙКИ
-- ============================================================================
local function create_general_tab()
  local panel = CreateFrame("Frame")
  panel.name = "Общие"
  panel.parent = "GoldGP"
  local COLORS = Addon.UIKit.COLORS
  local create_button = Addon.UIKit.create_button
  local style_editbox = Addon.UIKit.style_editbox

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("|cFFFFD700GoldGP - Общие настройки|r")

  -- Party-split только для офицеров
  local can_edit = CanEditOfficerNote() and true or false
  local next_anchor = title
  local next_offset = -20

  if can_edit then
    -- Секция: Party-Split
    -- Порог фиксированный (всегда P1-5=100%), настраивается только процент P6-8 (stepper).
    local sec2 = Addon.UIKit.create_section_header(panel, "Party-Split", next_anchor, next_offset)

    local split_cb = Addon.UIKit.create_checkbox(panel, "Включить party-split (P1-5=100%, P6-8=X%)",
      function() return Addon.db and Addon.db.profile and Addon.db.profile.party_split_enabled end,
      function(v)
        Addon.db.profile.party_split_enabled = v and true or false
        Addon.Print("Party-split: " .. (v and "ON" or "OFF"))
      end,
      sec2)

    local split_threshold_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    split_threshold_label:SetPoint("TOPLEFT", split_cb, "BOTTOMLEFT", 0, -8)
    split_threshold_label:SetText("Порог: |cFF30AA30P1-5 = 100%|r (фиксированный)")
    split_threshold_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)
    -- Принудительно устанавливаем порог = 5
    if Addon.db and Addon.db.profile then
      Addon.db.profile.party_split_threshold = 5
    end

    -- Stepper для процента P6-8
    local pct_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    pct_label:SetPoint("TOPLEFT", split_threshold_label, "BOTTOMLEFT", 0, -10)
    pct_label:SetText("Процент для P6-8:")
    pct_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

    local pct_value = (Addon.db and Addon.db.profile and Addon.db.profile.party_split_percent) or 50
    local pct_edit = CreateFrame("EditBox", "GoldGPOptPctEdit", panel, "InputBoxTemplate")
    pct_edit:SetSize(50, 20)
    pct_edit:SetPoint("LEFT", pct_label, "RIGHT", 10, 0)
    pct_edit:SetAutoFocus(false)
    pct_edit:SetNumeric(true)
    pct_edit:SetMaxLetters(3)
    pct_edit:SetText(tostring(pct_value))
    style_editbox(pct_edit)

    local pct_minus_btn = create_button(panel, "-", 24, 20, function()
      local v = tonumber(pct_edit:GetText()) or 50
      v = math.max(0, v - 5)
      pct_edit:SetText(tostring(v))
    end)
    pct_minus_btn:SetPoint("LEFT", pct_edit, "RIGHT", 4, 0)

    local pct_plus_btn = create_button(panel, "+", 24, 20, function()
      local v = tonumber(pct_edit:GetText()) or 50
      v = math.min(100, v + 5)
      pct_edit:SetText(tostring(v))
    end)
    pct_plus_btn:SetPoint("LEFT", pct_minus_btn, "RIGHT", 2, 0)

    -- Двухстрочное объявление, чтобы замыкание видело upvalue
    local pct_ok_btn
    pct_ok_btn = create_button(panel, "OK", 40, 20, function()
      local v = tonumber(pct_edit:GetText()) or 50
      v = math.max(0, math.min(100, v))
      pct_edit:SetText(tostring(v))
      if Addon.db and Addon.db.profile then
        Addon.db.profile.party_split_percent = v
      end
      Addon.Print("Party-split: P6-8 = " .. v .. "%")
      pct_ok_btn.text:SetTextColor(0.3, 0.85, 0.3)
    end)
    pct_ok_btn:SetPoint("LEFT", pct_plus_btn, "RIGHT", 6, 0)

    next_anchor = pct_label
    next_offset = -24
  end

  -- Секция: Массовые начисления
  local sec3 = Addon.UIKit.create_section_header(panel, "Массовые начисления", next_anchor, next_offset)

  local safe_cb = Addon.UIKit.create_checkbox(panel, "Безопасный режим (проверять state перед массовкой)",
    function() return Addon.db and Addon.db.profile and Addon.db.profile.safe_mass_mode end,
    function(v) Addon.db.profile.safe_mass_mode = v and true or false end,
    sec3)

  local cd_slider = create_slider_float(panel, "Cooldown массовок (сек)", 0, 10, 0.5,
    function() return (Addon.db and Addon.db.profile and Addon.db.profile.mass_ep_cooldown) or 1.5 end,
    function(v) Addon.db.profile.mass_ep_cooldown = v end,
    safe_cb)

  -- Секция: Окна — ширина Журнала
  -- Stepper для ширины Журнала
  local sec6 = Addon.UIKit.create_section_header(panel, "Окна", cd_slider, -24)

  local hw_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  hw_label:SetPoint("TOPLEFT", sec6, "BOTTOMLEFT", 0, -8)
  hw_label:SetText("Ширина Журнала (px):")
  hw_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  local hw_value = (Addon.db and Addon.db.profile and Addon.db.profile.history_width) or 600
  local hw_edit = CreateFrame("EditBox", "GoldGPOptHwEdit", panel, "InputBoxTemplate")
  hw_edit:SetSize(60, 20)
  hw_edit:SetPoint("LEFT", hw_label, "RIGHT", 10, 0)
  hw_edit:SetAutoFocus(false)
  hw_edit:SetNumeric(true)
  hw_edit:SetMaxLetters(4)
  hw_edit:SetText(tostring(hw_value))
  style_editbox(hw_edit)

  local hw_minus_btn = create_button(panel, "-", 24, 20, function()
    local v = tonumber(hw_edit:GetText()) or 600
    v = math.max(500, v - 10)
    hw_edit:SetText(tostring(v))
  end)
  hw_minus_btn:SetPoint("LEFT", hw_edit, "RIGHT", 4, 0)

  local hw_plus_btn = create_button(panel, "+", 24, 20, function()
    local v = tonumber(hw_edit:GetText()) or 600
    v = math.min(1200, v + 10)
    hw_edit:SetText(tostring(v))
  end)
  hw_plus_btn:SetPoint("LEFT", hw_minus_btn, "RIGHT", 2, 0)

  -- Двухстрочное объявление, чтобы замыкание видело upvalue
  local hw_ok_btn
  hw_ok_btn = create_button(panel, "OK", 40, 20, function()
    local v = tonumber(hw_edit:GetText()) or 600
    v = math.max(500, math.min(1200, v))
    hw_edit:SetText(tostring(v))
    if Addon.db and Addon.db.profile then
      Addon.db.profile.history_width = v
    end
    -- Применить немедленно если журнал открыт
    if Addon.History and Addon.History.ApplyWidth then
      Addon.History:ApplyWidth(v)
    end
    Addon.Print("Ширина Журнала: " .. v .. "px")
    hw_ok_btn.text:SetTextColor(0.3, 0.85, 0.3)
  end)
  hw_ok_btn:SetPoint("LEFT", hw_plus_btn, "RIGHT", 6, 0)

  local hw_hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  hw_hint:SetPoint("TOPLEFT", hw_label, "BOTTOMLEFT", 0, -6)
  hw_hint:SetText("|cFF808080Применяется немедленно (журнал закроется и откроется снова). 500-1200px.|r")
  hw_hint:SetWidth(440)
  hw_hint:SetJustifyH("LEFT")

  -- Секция: Посещаемость — сброс счётчика
  local sec_att = Addon.UIKit.create_section_header(panel, "Посещаемость", hw_hint, -20)

  local att_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  att_label:SetPoint("TOPLEFT", sec_att, "BOTTOMLEFT", 0, -8)
  att_label:SetText("Счётчик посещений РТ:")
  att_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Текущее значение
  local att_count_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  att_count_label:SetPoint("LEFT", att_label, "RIGHT", 8, 0)
  local function update_att_display()
    -- Показываем общее кол-во РТ (total) + сколько игроков имеют ненулевой счётчик
    local total = Addon:GetAttendanceTotal() or 0
    local players_with_count = 0
    if Addon.data.attendance_data then
      for _, c in pairs(Addon.data.attendance_data) do
        if c and c > 0 then players_with_count = players_with_count + 1 end
      end
    end
    att_count_label:SetText(string.format("|cFF30AA30РТ в месяце: %d  |  игроков с посещением: %d|r", total, players_with_count))
  end
  update_att_display()

  -- Кнопка сброса
  local att_reset_btn = create_button(panel, "Сбросить посещаемость", 180, 24, function()
    -- Диалог подтверждения
    StaticPopupDialogs["GOLDGP_RESET_ATTENDANCE"] = {
      text = "|cFFFF5050ВНИМАНИЕ!|r\nОбнулить посещаемость у ВСЕХ игроков?\n\nИндивидуальный счётчик (X) и общее кол-во РТ (Y) будут сброшены в 0/0.\n\nЭто действие нельзя отменить.",
      button1 = "Да, обнулить",
      button2 = "Отмена",
      timeout = 0,
      whileDead = 1,
      hideOnEscape = 1,
      showAlert = 1,
      OnAccept = function()
        -- Сброс посещаемости: public notes (N)→(0) + @ATT_TOTAL:0 + локальный кэш.
        -- Автоматического ежемесячного сброса нет: обнулённая посещаемость
        -- держится до следующего ручного запуска.
        if Addon.data.attendance_data then
          wipe(Addon.data.attendance_data)
        end
        if Addon.db and Addon.db.global then
          Addon.db.global.attendance_total = 0
          if GoldGPDB and GoldGPDB.global and GoldGPDB.global.attendance_data then
            wipe(GoldGPDB.global.attendance_data)
          end
          if GoldGPDB and GoldGPDB.global then
            GoldGPDB.global.attendance_total = 0
          end
        end
        Addon.data.attendance_total = 0
        -- Сброс @ATT_TOTAL в GuildInfo
        Addon:SetGuildInfoAttendance(0)
        -- Сброс (N) → (0) в public notes ВСЕХ игроков (mains + alts)
        if Addon.Storage and Addon.Storage.SetPublicNote then
          for name in pairs(Addon.data.gold_data) do
            Addon.Storage:SetPublicNote(name, 0)
          end
        end
        Addon:BumpCacheVersion()
        if Addon.UI then Addon.UI:RefreshStandings() end
        update_att_display()
        Addon.Print("Посещаемость: счётчик обнулён (0 / 0) для всех игроков")
      end,
    }
    StaticPopup_Show("GOLDGP_RESET_ATTENDANCE")
  end)
  att_reset_btn:SetPoint("LEFT", att_count_label, "RIGHT", 12, 0)
  -- Кнопка сброса посещаемости только для офицеров: не-офицеры видят статистику
  -- (РТ в месяце / игроков с посещением), но НЕ могут сбросить.
  -- can_edit обновляется в GUILD_ROSTER_UPDATE (Core.lua). Скрываем через OnShow панели.
  panel:HookScript("OnShow", function()
    if Addon.state and Addon.state.can_edit then
      att_reset_btn:Show()
    else
      att_reset_btn:Hide()
    end
  end)
  -- Первичная установка при создании панели
  if not (Addon.state and Addon.state.can_edit) then
    att_reset_btn:Hide()
  end

  -- Подсказка
  local att_hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  att_hint:SetPoint("TOPLEFT", att_label, "BOTTOMLEFT", 0, -4)
  att_hint:SetText("|cFF808080Формат: X / Y где X - посещения игрока, Y - всего РТ в гильдии. Увеличивается при массовом EP с причиной 'Приход на рт'. v2.5.9: автоматический ежемесячный сброс удалён - только ручной сброс кнопкой выше (требует прав офицера).|r")
  att_hint:SetWidth(440)
  att_hint:SetJustifyH("LEFT")

  -- Обновлять при показе панели
  panel:HookScript("OnShow", function() update_att_display() end)

  return panel
end

-- ============================================================================
-- ВКЛАДКИ: в Options ядра 2 категории — main + «Общие». Вкладка «Настои»
-- живёт в отдельном аддоне GoldGP_Flask (его GoldGP_Flask_Options.lua
-- регистрирует свою категорию в Interface Options).
-- ============================================================================

-- ============================================================================
-- ГЛАВНАЯ ПАНЕЛЬ + РЕГИСТРАЦИЯ В INTERFACE OPTIONS
-- ============================================================================

-- optionsRegistered объявлен ДО register_options (Lua local виден только после объявления)
-- _register_in_progress тоже local (иначе глобаль в _G — конфликт с другими аддонами)
local optionsRegistered = false
local _register_in_progress = false

local function register_options()
  if not Addon then return end
  if optionsRegistered then return end
  if _register_in_progress then return end
  _register_in_progress = true


  -- Главная панель
  local mainPanel = CreateFrame("Frame")
  mainPanel.name = "GoldGP"

  local COLORS = Addon.UIKit.COLORS
  local create_button = Addon.UIKit.create_button

  local title = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("|cFFFFD700Gold|r|cFFAAAAAAGP|r - настройки")

  local subtitle = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  subtitle:SetText("Выберите вкладку слева для настройки.")
  subtitle:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  local open_btn = create_button(mainPanel, "Открыть окно /gg", 150, 24, function()
    if InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
    if Addon.UI then
      Addon.UI:Initialize()
      if Addon.UI.frame then
        Addon.UI.frame:Show()
      end
    end
  end)
  open_btn:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -10)

  local ver = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ver:SetPoint("BOTTOMRIGHT", mainPanel, "BOTTOMRIGHT", -10, 10)
  ver:SetText("v" .. (Addon.version or "2.3.1"))
  ver:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Регистрируем все панели
  -- Каждая вкладка в отдельном pcall — чтобы найти, какая крашит
  local ok_main, err_main = pcall(InterfaceOptions_AddCategory, mainPanel)
  if not ok_main then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP: mainPanel FAILED:|r " .. tostring(err_main))
  end

  local ok_gen, err_gen = pcall(function()
    local tab = create_general_tab()
    InterfaceOptions_AddCategory(tab)
  end)
  if not ok_gen then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP: general_tab FAILED:|r " .. tostring(err_gen))
  end

  -- Отдельной вкладки «Команды» нет — полный список команд через /gg help.

  -- Сохраняем ссылку для Options:Open()
  Options._mainPanel = mainPanel
  -- Флаг в КОНЦЕ — только после успешной регистрации всех категорий
  optionsRegistered = true
  _register_in_progress = false

  if Addon.Log then
    Addon.Log:Info("GoldGP_Options registered in InterfaceOptions (2 categories)")
  end
end

-- ============================================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================================
function Options:Open()
  if not optionsRegistered then
    register_options()
  end
  if self._mainPanel then
    InterfaceOptionsFrame_OpenToCategory(self._mainPanel)
    -- В WoW 3.3.5a иногда нужно дважды для корректного переключения
    InterfaceOptionsFrame_OpenToCategory(self._mainPanel)
  end
end

-- ============================================================================
-- РЕГИСТРАЦИЯ НАСТРОЕК ПРИ СТАРТЕ
-- ============================================================================

local function OnAddonLoaded()
  if optionsRegistered then return end
  if not Addon or not Addon.db then return end
  -- Специально без pcall: если регистрация падает, ошибку нужно видеть.
  DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700Gold|r|cFFAAAAAAGP|r: registering options...")
  register_options()
  if optionsRegistered then
    DEFAULT_CHAT_FRAME:AddMessage("|cFF30AA30GoldGP: options registered OK|r")
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP: options registration FAILED|r")
  end
end

-- OnUpdate-fallback проверяет готовность каждые 0.2 сек: ADDON_LOADED не
-- используем (может не сработать, если событие уже прошло). InitDB вызывается
-- при ADDON_LOADED в Core.lua, Addon.db готов почти сразу.
local optionsTimer = CreateFrame("Frame")
optionsTimer:Show()
local options_timer_elapsed = 0
optionsTimer:SetScript("OnUpdate", function(self, elapsed)
  if optionsRegistered then
    self:Hide()
    return
  end
  options_timer_elapsed = options_timer_elapsed + elapsed
  if options_timer_elapsed >= 0.2 then
    options_timer_elapsed = 0
    if Addon and Addon.db then
      OnAddonLoaded()
    end
  end
end)

if Addon and Addon.Log then
  Addon.Log:Info("GoldGP_Options module loaded (waiting for ADDON_LOADED)")
end
