-- GoldGP_Flask_Options.lua
-- Вкладка «Настои» отдельного аддона GoldGP_Flask: своя категория Interface
-- Options «GoldGP Фласки»; панель регистрируется ВСЕГДА, офицерство применяется
-- к содержимому. Тело исполняется внутри boot(Addon, Flask) без ре-индентации.
local boot = function(Addon, Flask)

-- ============================================================================
-- UI-КЛЕЙ: виджеты берутся напрямую из Addon.UIKit (внутри boot Addon —
-- реальный глобал GoldGP). create_section_header/create_checkbox — общие
-- фабрики UIKit.
-- ============================================================================

-- ============================================================================
-- ВКЛАДКА «НАСТОИ»
-- ============================================================================
local panel_data = {
  count_label = nil,
  rows = {},
  -- Офицерские контролы вкладки (скрываются у не-офицеров)
  officer_controls = {},
  officer_notice = nil,  -- пояснение на ГЛАВНОЙ панели
  tab_notice = nil,      -- пояснение на вкладке «Настои»
}

-- Панели регистрируются ВСЕГДА (молчаливый ранний return по CanEditOfficerNote
-- = баг «исчезли настройки»), а офицерство применяется к СОДЕРЖИМОМУ
-- (кнопки скрываются, показывается пояснение) с живой перепроверкой
-- при каждом открытии панели.
local function ApplyFlaskOfficerState()
  local officer = CanEditOfficerNote() and true or false
  for _, ctrl in ipairs(panel_data.officer_controls or {}) do
    if ctrl then
      if officer then ctrl:Show() else ctrl:Hide() end
    end
  end
  if panel_data.officer_notice then
    if officer then panel_data.officer_notice:Hide() else panel_data.officer_notice:Show() end
  end
  if panel_data.tab_notice then
    if officer then panel_data.tab_notice:Hide() else panel_data.tab_notice:Show() end
  end
end

local function refresh_flask_list()
  if not panel_data.scroll then return end
  local scroll = panel_data.scroll
  local rows = panel_data.rows or {}
  local row_height = panel_data.row_height or 24

  local ids = {}
  if Flask and Flask.GetFlaskIDs then
    ids = Flask:GetFlaskIDs()
  end

  local total = #ids
  local offset = FauxScrollFrame_GetOffset(scroll)

  for i = 1, #rows do
    local row = rows[i]
    local idx = i + offset
    if idx <= total then
      local spellID = ids[idx]
      -- Используем кэш (как FlaskGP) — GetSpellInfo только при первом обращении
      local info = Flask:GetSpellInfoCached(spellID)
      local spellName = info and info.name or "(нет названия)"
      local spellIcon = info and info.icon
      row.idx_label:SetText(string.format("%3d.", idx))
      row.id_label:SetText(tostring(spellID))
      row.name_label:SetText(spellName)
      if spellIcon and spellIcon ~= "" then
        row.icon:SetTexture(spellIcon)
      else
        row.icon:SetTexture("Interface\\Icons\\INV_Potion_97")  -- дефолтная
      end
      row.spellID = spellID
      row:Show()
    else
      row:Hide()
    end
  end

  FauxScrollFrame_Update(scroll, total, #rows, row_height)

  if panel_data.count_label then
    panel_data.count_label:SetText(string.format("Всего настоев: |cFF30AA30%d|r", total))
  end
end

local function create_flask_tab()
  local COLORS = Addon.UIKit.COLORS
  local apply_backdrop = Addon.UIKit.apply_backdrop
  local create_button = Addon.UIKit.create_button
  local style_editbox = Addon.UIKit.style_editbox

  local panel = CreateFrame("Frame")
  panel.name = "Настои"
  panel.parent = "GoldGP_Flask"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("|cFFFFD700Gold|r|cFFAAAAAAGP|r Фласки - Настои")

  local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  desc:SetText("Список spellID настоев для проверки. Канал отчёта всегда GUILD.")
  desc:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  panel_data.count_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  panel_data.count_label:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
  panel_data.count_label:SetText("Всего настоев: ...")
  panel_data.count_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- ScrollFrame со списком
  local row_height = 24
  local visible_rows = 10
  local list_width = 540
  local list_height = visible_rows * row_height + 8

  local container = CreateFrame("Frame", nil, panel)
  container:SetSize(list_width, list_height)
  container:SetPoint("TOPLEFT", panel_data.count_label, "BOTTOMLEFT", 0, -8)
  apply_backdrop(container, COLORS.bg_panel, COLORS.border, 1)

  local scroll = CreateFrame("ScrollFrame", "GoldGPFlaskOptionsScroll", container, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 4, -4)
  scroll:SetPoint("TOPRIGHT", container, "TOPRIGHT", -22, -4)
  scroll:SetPoint("BOTTOM", container, "BOTTOM", 0, 4)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, row_height, refresh_flask_list)
  end)

  local hdr = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hdr:SetPoint("TOPLEFT", container, "TOPLEFT", 8, -4)
  hdr:SetText("|cFF808080  #   Иконка  SpellID    Название|r")

  local rows = {}
  for i = 1, visible_rows do
    local row = CreateFrame("Frame", nil, container)
    row:SetSize(list_width - 24, row_height)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -((i - 1) * row_height) - 18)
    apply_backdrop(row, COLORS.bg_row, COLORS.border, 1)

    -- Иконка настоя (как в FlaskGP) — через GetSpellInfo(spellID), 3-е значение
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.icon:SetTexture("Interface\\Icons\\INV_Potion_97")

    row.idx_label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.idx_label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.idx_label:SetWidth(32)
    row.idx_label:SetJustifyH("LEFT")
    row.idx_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

    row.id_label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.id_label:SetPoint("LEFT", row.idx_label, "RIGHT", 6, 0)
    row.id_label:SetWidth(70)
    row.id_label:SetJustifyH("LEFT")
    row.id_label:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)

    row.name_label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name_label:SetPoint("LEFT", row.id_label, "RIGHT", 6, 0)
    row.name_label:SetWidth(280)
    row.name_label:SetJustifyH("LEFT")
    row.name_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

    -- Кнопка удаления
    row.del_btn = create_button(row, "X", 24, 20, function()
      if row.spellID then
        Flask:RemoveFlask(row.spellID)
        refresh_flask_list()
      end
    end)
    row.del_btn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    tinsert(panel_data.officer_controls, row.del_btn)

    rows[i] = row
  end

  panel_data.rows = rows
  panel_data.scroll = scroll
  panel_data.row_height = row_height

  -- Добавление нового настоя
  local add_section = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  add_section:SetPoint("TOPLEFT", container, "BOTTOMLEFT", 0, -16)
  add_section:SetText("|cFFFFD700Добавить настой|r")

  local add_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  add_label:SetPoint("TOPLEFT", add_section, "BOTTOMLEFT", 0, -8)
  add_label:SetText("Spell ID:")
  add_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Уникальное глобальное имя для EditBox,
  -- иначе InputBoxTemplate без имени оставляет чёрные полоски (артефакты).
  local add_edit = CreateFrame("EditBox", "GoldGPFlaskOptAddEdit", panel, "InputBoxTemplate")
  add_edit:SetSize(100, 20)
  add_edit:SetPoint("LEFT", add_label, "RIGHT", 8, 0)
  add_edit:SetAutoFocus(false)
  add_edit:SetNumeric(true)
  style_editbox(add_edit)
  add_edit:SetText("")

  -- Preview иконки настоя справа от поля ввода (как в FlaskGP)
  local preview_icon = panel:CreateTexture(nil, "ARTWORK")
  preview_icon:SetSize(22, 22)
  preview_icon:SetPoint("LEFT", add_edit, "RIGHT", 8, 0)
  preview_icon:SetTexture("Interface\\Icons\\INV_Potion_97")
  add_edit:SetScript("OnTextChanged", function(self)
    local txt = self:GetText()
    local spellID = tonumber(txt)
    if spellID and spellID > 0 then
      local info = Flask:GetSpellInfoCached(spellID)
      if info and info.icon and info.icon ~= "" then
        preview_icon:SetTexture(info.icon)
      else
        preview_icon:SetTexture("Interface\\Icons\\INV_Potion_97")
      end
    else
      preview_icon:SetTexture("Interface\\Icons\\INV_Potion_97")
    end
  end)

  local add_btn = create_button(panel, "Добавить", 90, 22, function()
    local txt = add_edit:GetText()
    local spellID = tonumber(txt)
    if not spellID or spellID <= 0 then
      Addon.PrintError("Введите корректный spellID (число)")
      return
    end
    local ok = Flask:AddFlask(spellID)
    if ok then
      add_edit:SetText("")
      refresh_flask_list()
    end
  end)
  add_btn:SetPoint("LEFT", preview_icon, "RIGHT", 8, 0)
  tinsert(panel_data.officer_controls, add_btn)

  local check_btn = create_button(panel, "Проверить настои", 130, 22, function()
    Flask:RunCheck()
  end)
  check_btn:SetPoint("LEFT", add_btn, "RIGHT", 12, 0)
  tinsert(panel_data.officer_controls, check_btn)

  local reset_btn = create_button(panel, "Сбросить список", 120, 22, function()
    Flask:ResetFlasks()
    refresh_flask_list()
  end)
  reset_btn:SetPoint("LEFT", check_btn, "RIGHT", 12, 0)
  tinsert(panel_data.officer_controls, reset_btn)

  -- Настройки GP
  local gp_section = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  gp_section:SetPoint("TOPLEFT", add_label, "BOTTOMLEFT", 0, -30)
  gp_section:SetText("|cFFFFD700Настройки проверки|r")

  local gp_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  gp_label:SetPoint("TOPLEFT", gp_section, "BOTTOMLEFT", 0, -8)
  gp_label:SetText("GP за отсутствие настоя:")
  gp_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  local gp_edit = CreateFrame("EditBox", "GoldGPFlaskOptGpEdit", panel, "InputBoxTemplate")
  gp_edit:SetSize(80, 20)
  gp_edit:SetPoint("LEFT", gp_label, "RIGHT", 8, 0)
  gp_edit:SetAutoFocus(false)
  gp_edit:SetNumeric(true)
  style_editbox(gp_edit)
  gp_edit:SetText(tostring(Flask:GetGPAmount()))
  gp_edit:SetScript("OnEnterPressed", function(self)
    local n = tonumber(self:GetText()) or 1
    Flask:SetGPAmount(n)
    self:SetText(tostring(Flask:GetGPAmount()))
    self:ClearFocus()
  end)
  gp_edit:SetScript("OnEditFocusLost", function(self)
    local n = tonumber(self:GetText()) or 1
    Flask:SetGPAmount(n)
    self:SetText(tostring(Flask:GetGPAmount()))
  end)
  tinsert(panel_data.officer_controls, gp_edit)

  -- Канал — всегда GUILD (не настраивается)
  local ch_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  ch_label:SetPoint("LEFT", gp_edit, "RIGHT", 30, 0)
  ch_label:SetText("Канал: |cFF30AA30GUILD|r (фиксированный)")
  ch_label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Пояснение для не-офицеров + живое применение прав при каждом показе
  local notice = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  notice:SetPoint("TOPLEFT", panel_data.count_label, "BOTTOMLEFT", 0, -10)
  notice:SetWidth(520)
  notice:SetJustifyH("LEFT")
  notice:SetText("|cFFF0A000Настройка настоев доступна только офицерам\n(звание с правом редактирования офицерских заметок).|r")
  notice:Hide()
  panel_data.tab_notice = notice

  panel:SetScript("OnShow", function()
    ApplyFlaskOfficerState()
    refresh_flask_list()
  end)
  ApplyFlaskOfficerState()
  return panel
end

-- ============================================================================
-- РЕГИСТРАЦИЯ В INTERFACE OPTIONS
-- ============================================================================
-- Паттерн GoldGP_LootMaster_Options.lua: главный фрейм + OnUpdate-polling
-- до готовности БД модуля (C_Timer в 3.3.5a не существует).
local optionsRegistered = false
local _register_in_progress = false

local function register_options()
  if optionsRegistered then return end
  if not Flask then return end
  if not Flask.db then return end  -- БД модуля готова после boot() (InitFlaskDB)
  if _register_in_progress then return end
  -- Гейт CanEditOfficerNote здесь НЕ ставится — панели регистрируются ВСЕГДА
  -- (см. комментарий в ApplyFlaskOfficerState), права применяются к содержимому.
  _register_in_progress = true

  local COLORS = Addon.UIKit.COLORS

  -- Главная панель
  local mainPanel = CreateFrame("Frame")
  mainPanel.name = "GoldGP_Flask"

  local title = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("|cFFFFD700Gold|r|cFFAAAAAAGP|r Фласки - настройки")

  local subtitle = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  subtitle:SetText("Проверка настоев в группе/рейде и GP-штраф за их отсутствие.")
  subtitle:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  local create_button = Addon.UIKit.create_button
  local check_btn = create_button(mainPanel, "Проверить настои", 140, 24, function()
    Flask:RunCheck()
  end)
  check_btn:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -10)

  local list_btn = create_button(mainPanel, "Список настоев", 140, 24, function()
    Flask:ListFlasks()
  end)
  list_btn:SetPoint("LEFT", check_btn, "RIGHT", 8, 0)

  -- Офицерский режим содержимого главной панели
  panel_data.officer_controls = { check_btn }
  local notice = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  notice:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
  notice:SetWidth(480)
  notice:SetJustifyH("LEFT")
  notice:SetText("|cFFF0A000Проверка и начисление GP доступны только офицерам\n(звание с правом редактирования офицерских заметок).|r")
  notice:Hide()
  panel_data.officer_notice = notice
  mainPanel:SetScript("OnShow", ApplyFlaskOfficerState)
  ApplyFlaskOfficerState()

  local ver = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ver:SetPoint("BOTTOMRIGHT", mainPanel, "BOTTOMRIGHT", -10, 10)
  ver:SetText("GoldGP Фласки v0.1.2  |  GoldGP v" .. (Addon.version or "?"))
  ver:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Регистрируем панели (каждая в pcall — чтобы найти какая крашит)
  local ok1, err1 = pcall(InterfaceOptions_AddCategory, mainPanel)
  if not ok1 then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP_Flask: mainPanel FAILED:|r " .. tostring(err1))
  end

  local ok2, err2 = pcall(function()
    InterfaceOptions_AddCategory(create_flask_tab())
  end)
  if not ok2 then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050GoldGP_Flask: flask_tab FAILED:|r " .. tostring(err2))
  end

  Flask._optionsPanel = mainPanel
  _register_in_progress = false
  if ok1 and ok2 then
    optionsRegistered = true
  end

  if Addon.Log then
    Addon.Log:Info("GoldGP_Flask_Options registered (main + Настои)")
  end
end

-- Публичный API: открыть настройки (на будущее — /gg flask открывает вкладку ядра,
-- у модуля кнопок в ядре нет; вызов через /run GoldGP.Flask.OpenOptions(Flask))
function Flask:OpenOptions()
  if not optionsRegistered then
    register_options()
  end
  if self._optionsPanel then
    InterfaceOptionsFrame_OpenToCategory(self._optionsPanel)
    -- В WoW 3.3.5a иногда нужно дважды для корректного переключения
    InterfaceOptionsFrame_OpenToCategory(self._optionsPanel)
  end
end

-- ============================================================================
-- ОТЛОЖЕННАЯ РЕГИСТРАЦИЯ (OnUpdate polling 0.2 сек — паттерн ядра и LootMaster)
-- ============================================================================
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
    if Flask and Flask.db then
      register_options()
    end
  end
end)

  if Addon.Log then
    Addon.Log:Info("GoldGP_Flask_Options booted (waiting for DB)")
  end
end  -- end of boot(Addon, Flask)

-- ============================================================================
-- ЗАПУСК — сразу, либо отложенно (waiter до 30с)
-- ============================================================================
local function launch_options()
  if GoldGP and GoldGP.Flask then
    boot(GoldGP, GoldGP.Flask)
    return true
  end
  return false
end

if not launch_options() then
  -- Ядро или модуль ещё не готовы — ЖДЁМ (диагностику уже вывел GoldGP_Flask.lua)
  local waiter = CreateFrame("Frame")
  local waited = 0
  waiter:RegisterEvent("ADDON_LOADED")
  waiter:RegisterEvent("PLAYER_LOGIN")
  waiter:SetScript("OnEvent", function() waited = 999 end)
  waiter:SetScript("OnUpdate", function(self, elapsed)
    waited = waited + elapsed
    if launch_options() then
      self:UnregisterAllEvents()
      self:Hide()
    elseif waited > 30 then
      self:UnregisterAllEvents()
      self:Hide()
      -- Молча: причину уже назвал GoldGP_Flask.lua (ядро не загрузилось)
    end
  end)
end
