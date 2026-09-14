-- GoldGP_LootMaster_Options.lua

local LM = _G.GoldGPLootMaster
if not LM then return end

local Addon = GoldGP

-- ============================================================================
-- UI-КЛЕЙ: виджеты берутся напрямую из UIKit через глобал GoldGP (резолв в
-- момент вызова — локальный Addon может быть не захвачен при отложенном
-- старте). create_section_header/create_checkbox — общие фабрики UIKit.
-- ============================================================================

-- ============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================================

-- Создать EditBox для ввода текста (label + editbox + кнопка OK)
-- Текст применяется только по нажатию OK или Enter, а не по потере фокуса.
local function create_text_field(parent, label_text, get_func, set_func, anchor_frame, y_offset)
  local COLORS = GoldGP.UIKit.COLORS
  local style_editbox = GoldGP.UIKit.style_editbox
  local apply_backdrop = GoldGP.UIKit.apply_backdrop
  local create_button = GoldGP.UIKit.create_button

  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(540, 32)
  if anchor_frame then
    container:SetPoint("TOPLEFT", anchor_frame, "BOTTOMLEFT", 0, y_offset or -10)
  else
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y_offset or -10)
  end

  container.label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  container.label:SetPoint("LEFT", container, "LEFT", 0, 0)
  container.label:SetWidth(160)
  container.label:SetJustifyH("LEFT")
  container.label:SetText(label_text)
  container.label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Уникальное глобальное имя для каждого EditBox, иначе
  -- InputBoxTemplate без имени оставляет чёрные полоски (артефакты текстур) при закрытии.
  -- Имя строим из label_text (транслитерация не нужна — Lua допускает любые символы в строке).
  local frame_name = "GoldGPLMOptEdit" .. tostring(container)
  local edit = CreateFrame("EditBox", frame_name, container, "InputBoxTemplate")
  edit:SetSize(180, 22)
  edit:SetPoint("LEFT", container.label, "RIGHT", 12, 0)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(20)
  edit:SetText(get_func() or "")
  style_editbox(edit)

  -- Статус-индикатор: "Сохранено" / "Не сохранено"
  local status = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", edit, "RIGHT", 8, 0)
  status:SetText("|cFF30AA30Сохранено|r")
  status:SetTextColor(1, 1, 1)

  -- Функция применения
  local function apply_text()
    local txt = edit:GetText() or ""
    set_func(txt)
    status:SetText("|cFF30AA30Сохранено: \"" .. txt .. "\"|r")
    -- Вернуть через 2 сек к короткому "Сохранено"
    local f = CreateFrame("Frame")
    local t = 0
    f:Show()
    f:SetScript("OnUpdate", function(self, elapsed)
      t = t + elapsed
      if t >= 2.0 then
        self:Hide()
        status:SetText("|cFF30AA30Сохранено|r")
      end
    end)
  end

  -- Кнопка OK
  local ok_btn = create_button(container, "OK", 50, 22, apply_text)
  ok_btn:SetPoint("LEFT", status, "RIGHT", 8, 0)
  ok_btn.text:SetTextColor(0.30, 0.85, 0.30)

  -- Enter = OK
  edit:SetScript("OnEnterPressed", function(self)
    apply_text()
    self:ClearFocus()
  end)
  -- При потере фокуса — НЕ применять (только по OK/Enter).
  -- Но если текст изменился — показать "Не сохранено"
  edit:SetScript("OnEditFocusLost", function(self)
    local current = get_func() or ""
    local txt = self:GetText() or ""
    if txt ~= current then
      status:SetText("|cFFFFD700Не сохранено|r")
    else
      status:SetText("|cFF30AA30Сохранено|r")
    end
  end)
  edit:SetScript("OnTextChanged", function(self, userChanged)
    if userChanged then
      local current = get_func() or ""
      local txt = self:GetText() or ""
      if txt ~= current then
        status:SetText("|cFFFFD700Не сохранено|r")
      else
        status:SetText("|cFF30AA30Сохранено|r")
      end
    end
  end)

  container.edit = edit
  container.ok_btn = ok_btn
  container.status = status
  return container
end

-- Создать слайдер (int)
local function create_slider(parent, label_text, min_val, max_val, step, get_func, set_func, anchor_frame, y_offset)
  local COLORS = GoldGP.UIKit.COLORS
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
  slider.valueText:SetText(tostring(get_func() or min_val))
  slider.valueText:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)

  slider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value + 0.5)
    self.valueText:SetText(tostring(value))
    set_func(value)
  end)

  if slider.LowText then
    slider.LowText:SetText(tostring(min_val))
    slider.LowText:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end
  if slider.HighText then
    slider.HighText:SetText(tostring(max_val))
    slider.HighText:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end
  if slider.Text then slider.Text:SetText("") end

  return slider
end

-- ============================================================================
-- РАБОТА С БД LootMaster
-- ============================================================================
-- LM.db инициализируется в GoldGP_LootMaster.lua (LoadLootMasterDB).
-- Здесь только безопасные геттеры/сеттеры.

local function get_db()
  if LM.db and LM.db.global then return LM.db.global end
  return nil
end

-- Состояние вкладки GP
local gp_override_list = {}    -- отсортированный массив: { itemID, gp, name }
local gp_list_dirty   = true
local gp_list_scroll_frame = nil
local gp_list_rows     = {}
local GP_ROW_HEIGHT    = 24
local GP_VISIBLE_ROWS  = 8

local function get_item_name(itemID)
  if not itemID then return nil end
  local name = GetItemInfo(itemID)
  return name
end

local function rebuild_gp_list()
  wipe(gp_override_list)
  local db = get_db()
  local overrides = db and db.gp_overrides
  if not overrides then return end
  for itemID, gp in pairs(overrides) do
    local name = get_item_name(itemID) or ("Item #" .. tostring(itemID))
    tinsert(gp_override_list, { itemID = itemID, gp = gp, name = name })
  end
  table.sort(gp_override_list, function(a, b)
    if a.gp ~= b.gp then return a.gp > b.gp end
    return a.itemID < b.itemID
  end)
  gp_list_dirty = false
end

local function save_gp_override(itemID, gp)
  local db = get_db()
  if not db then return false end
  if not db.gp_overrides then db.gp_overrides = {} end
  db.gp_overrides[itemID] = gp
  gp_list_dirty = true
  if _G.GoldGPLootMaster and _G.GoldGPLootMaster.ClearItemCache then
    _G.GoldGPLootMaster:ClearItemCache()
  end
  return true
end

local function delete_gp_override(itemID)
  local db = get_db()
  if not db or not db.gp_overrides then return end
  db.gp_overrides[itemID] = nil
  gp_list_dirty = true
  if _G.GoldGPLootMaster and _G.GoldGPLootMaster.ClearItemCache then
    _G.GoldGPLootMaster:ClearItemCache()
  end
end

local function refresh_gp_list()
  if not gp_list_scroll_frame then return end
  if gp_list_dirty then rebuild_gp_list() end
  local total  = #gp_override_list
  local offset = FauxScrollFrame_GetOffset(gp_list_scroll_frame)
  FauxScrollFrame_Update(gp_list_scroll_frame, total, GP_VISIBLE_ROWS, GP_ROW_HEIGHT)
  for i = 1, GP_VISIBLE_ROWS do
    local row = gp_list_rows[i]
    if not row then break end
    local idx  = i + offset
    local data = gp_override_list[idx]
    if data then
      row.name_text:SetText(data.name)
      row.id_text:SetText("ID: " .. tostring(data.itemID))
      row.gp_text:SetText(data.gp .. " GP")
      row.del_btn.item_id = data.itemID
      row.del_btn:Show()
      row:Show()
    else
      row:Hide()
    end
  end
end

local function get_setting(key, default)
  local g = get_db()
  if not g then return default end
  return g[key] or default
end

local function set_setting(key, value)
  local g = get_db()
  if not g then return end
  g[key] = value
end

-- ============================================================================
-- ВКЛАДКА 1: ОБЩИЕ
-- ============================================================================
local function create_general_tab()
  local COLORS = GoldGP.UIKit.COLORS
  local apply_backdrop = GoldGP.UIKit.apply_backdrop
  local create_button = GoldGP.UIKit.create_button

  local panel = CreateFrame("Frame")
  panel.name = "Общие"
  panel.parent = "GoldGP_LootMaster"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("|cFFFFD700GoldGP LootMaster - Общие|r")

  local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  desc:SetText("Настройки окна кандидата и поведения LootMaster.")
  desc:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Секция 1: Тексты кнопок
  local sec1 = GoldGP.UIKit.create_section_header(panel, "Тексты кнопок кандидата", desc, -16)

  local need_field = create_text_field(panel, "Кнопка 'Мейн спек':",
    function() return get_setting("btn_need_text", "Мейн спек") end,
    function(v)
      set_setting("btn_need_text", v)
      LM:ApplyButtonLabels()
    end,
    sec1)

  local offspec_field = create_text_field(panel, "Кнопка 'Офф спек':",
    function() return get_setting("btn_offspec_text", "Офф спек") end,
    function(v)
      set_setting("btn_offspec_text", v)
      LM:ApplyButtonLabels()
    end,
    need_field)

  local pass_field = create_text_field(panel, "Кнопка 'Откажусь':",
    function() return get_setting("btn_pass_text", "Откажусь") end,
    function(v)
      set_setting("btn_pass_text", v)
      LM:ApplyButtonLabels()
    end,
    offspec_field)

  -- Подсказка
  local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", pass_field, "BOTTOMLEFT", 0, -8)
  hint:SetText("|cFF808080Изменения применяются по кнопке OK или Enter. Окно кандидата обновится при следующем луте.|r")
  hint:SetWidth(440)
  hint:SetJustifyH("LEFT")

  -- OnShow — обновить значения в EditBox из БД (на случай если они изменились снаружи)
  panel:SetScript("OnShow", function()
    if need_field.edit then need_field.edit:SetText(get_setting("btn_need_text", "Мейн спек")) end
    if offspec_field.edit then offspec_field.edit:SetText(get_setting("btn_offspec_text", "Офф спек")) end
    if pass_field.edit then pass_field.edit:SetText(get_setting("btn_pass_text", "Откажусь")) end
    if need_field.status then need_field.status:SetText("|cFF30AA30Сохранено|r") end
    if offspec_field.status then offspec_field.status:SetText("|cFF30AA30Сохранено|r") end
    if pass_field.status then pass_field.status:SetText("|cFF30AA30Сохранено|r") end
  end)

  -- Кнопка "Сбросить к дефолту"
  local reset_btn = create_button(panel, "Сбросить к дефолту", 180, 24, function()
    set_setting("btn_need_text", "Мейн спек")
    set_setting("btn_offspec_text", "Офф спек")
    set_setting("btn_pass_text", "Откажусь")
    if need_field.edit then need_field.edit:SetText("Мейн спек") end
    if offspec_field.edit then offspec_field.edit:SetText("Офф спек") end
    if pass_field.edit then pass_field.edit:SetText("Откажусь") end
    if need_field.status then need_field.status:SetText("|cFF30AA30Сохранено|r") end
    if offspec_field.status then offspec_field.status:SetText("|cFF30AA30Сохранено|r") end
    if pass_field.status then pass_field.status:SetText("|cFF30AA30Сохранено|r") end
    LM:ApplyButtonLabels()
    if Addon and Addon.Print then
      Addon.Print("LootMaster: тексты кнопок сброшены к дефолту")
    end
  end)
  reset_btn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)

  -- Секция 2: Таймер
  local sec2 = GoldGP.UIKit.create_section_header(panel, "Таймер кандидата", reset_btn, -20)

  local timeout_slider = create_slider(panel, "Время на ответ (сек)", 15, 120, 5,
    function() return get_setting("loot_timeout", 60) end,
    function(v) set_setting("loot_timeout", v) end,
    sec2)

  -- Подсказка для таймера
  local timeout_hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  timeout_hint:SetPoint("TOPLEFT", timeout_slider, "BOTTOMLEFT", 0, -8)
  timeout_hint:SetText("|cFF808080Применяется к новым раздачам лута. Если кандидат не ответил за это время - авто-PASS.|r")
  timeout_hint:SetWidth(440)
  timeout_hint:SetJustifyH("LEFT")

  -- Секция 2b: ML окно для всех
  local sec2b = GoldGP.UIKit.create_section_header(panel, "Просмотр ML окна", timeout_hint, -16)

  local ml_view_cb = GoldGP.UIKit.create_checkbox(panel,
    "Показывать read-only окно ML другим кандидатам после их ответа",
    function() return get_setting("ml_view_all_enabled", false) end,
    function(v)
      set_setting("ml_view_all_enabled", v and true or false)
      if Addon and Addon.Print then
        Addon.Print("LootMaster: ML окно для всех — " .. (v and "ВКЛ" or "ВЫКЛ"))
      end
    end,
    sec2b)

  local ml_view_hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ml_view_hint:SetPoint("TOPLEFT", ml_view_cb, "BOTTOMLEFT", 0, -4)
  ml_view_hint:SetText("|cFF808080Если включено - после ответа кандидат увидит таблицу с ответами всех игроков (только просмотр, без влияния).|r")
  ml_view_hint:SetWidth(440)
  ml_view_hint:SetJustifyH("LEFT")

  -- Версия
  local ver = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ver:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
  ver:SetText("LootMaster v" .. (LM.VERSION or "?"))
  ver:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  return panel
end

-- Вкладка GP — фиксированные таблицы + пользовательские переопределения
local function create_gp_tab()
  local apply_backdrop = GoldGP.UIKit.apply_backdrop
  local create_button  = GoldGP.UIKit.create_button
  local style_editbox  = GoldGP.UIKit.style_editbox
  local COLORS         = GoldGP.UIKit.COLORS

  local panel = CreateFrame("Frame", "GoldGPLMOptionsGPPanel")
  panel.name   = "GP"
  panel.parent = "GoldGP_LootMaster"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("|cFFFFD700LootMaster - Настройки GP|r")

  local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  desc:SetWidth(560)
  desc:SetJustifyH("LEFT")
  desc:SetText(
    "Фиксированные GP по ilvl:\n" ..
    "|cFFFFD700245 ilvl:|r  2H = 400   1H = 200   Тринкет = 400   Оф-сет = 200   Тир-сет = 100\n" ..
    "|cFFFFD700258 ilvl:|r  2H = 600   1H = 400   Тринкет = 600   Оф-сет = 400   Тир-сет = 300\n" ..
    "|cFF808080Предметы других ilvl используют формулу EPGP. Ниже - ручные переопределения.|r"
  )

  local sep1 = panel:CreateTexture(nil, "ARTWORK")
  sep1:SetHeight(1)
  sep1:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
  sep1:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, 0)
  -- SetColorTexture не существует в WoW 3.3.5a (появился в Cataclysm 4.0+).
  -- Используем SetTexture + SetVertexColor — стандартный паттерн 3.3.5a.
  sep1:SetTexture("Interface\\Buttons\\WHITE8x8")
  sep1:SetVertexColor(0.3, 0.25, 0.1, 0.8)

  local add_label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  add_label:SetPoint("TOPLEFT", sep1, "BOTTOMLEFT", 0, -12)
  add_label:SetText("Добавить / изменить GP для предмета:")
  add_label:SetTextColor(0.95, 0.85, 0.5)

  local id_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  id_label:SetPoint("TOPLEFT", add_label, "BOTTOMLEFT", 0, -10)
  id_label:SetText("Item ID:")
  id_label:SetTextColor(0.7, 0.7, 0.7)

  local id_box = CreateFrame("EditBox", "GoldGPLMOptGpIdBox", panel, "InputBoxTemplate")
  style_editbox(id_box)
  id_box:SetSize(90, 22)
  id_box:SetPoint("LEFT", id_label, "RIGHT", 8, 0)
  id_box:SetAutoFocus(false)
  id_box:SetMaxLetters(7)
  id_box:SetNumeric(true)

  local gp_label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  gp_label:SetPoint("LEFT", id_box, "RIGHT", 16, 0)
  gp_label:SetText("GP:")
  gp_label:SetTextColor(0.7, 0.7, 0.7)

  local gp_box = CreateFrame("EditBox", "GoldGPLMOptGpValBox", panel, "InputBoxTemplate")
  style_editbox(gp_box)
  gp_box:SetSize(70, 22)
  gp_box:SetPoint("LEFT", gp_label, "RIGHT", 8, 0)
  gp_box:SetAutoFocus(false)
  gp_box:SetMaxLetters(5)
  gp_box:SetNumeric(true)

  local preview_text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  preview_text:SetPoint("TOPLEFT", id_label, "BOTTOMLEFT", 0, -6)
  preview_text:SetWidth(400)
  preview_text:SetJustifyH("LEFT")
  preview_text:SetTextColor(0.5, 0.8, 0.5)

  id_box:SetScript("OnTextChanged", function(self)
    local itemID = tonumber(self:GetText())
    if itemID and itemID > 0 then
      local name = get_item_name(itemID)
      if name then
        preview_text:SetText(name)
      else
        preview_text:SetText("|cFF808080Предмет не в кэше клиента|r")
      end
    else
      preview_text:SetText("")
    end
  end)

  local status_text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  status_text:SetPoint("LEFT", gp_box, "RIGHT", 10, 0)
  status_text:SetText("")

  -- closure scoping — двухстрочное объявление
  local ok_btn
  ok_btn = create_button(panel, "OK", 50, 22, function()
    local itemID = tonumber(id_box:GetText())
    local gp     = tonumber(gp_box:GetText())
    if not itemID or itemID <= 0 then
      status_text:SetText("|cFFFF5050Укажите Item ID|r")
      return
    end
    if not gp or gp <= 0 then
      status_text:SetText("|cFFFF5050Укажите GP > 0|r")
      return
    end
    save_gp_override(itemID, gp)
    status_text:SetText("|cFF30AA30Сохранено!|r")
    refresh_gp_list()
    local clear_timer = CreateFrame("Frame")
    local t = 1.5
    clear_timer:SetScript("OnUpdate", function(self, elapsed)
      t = t - elapsed
      if t <= 0 then
        self:Hide()
        status_text:SetText("")
      end
    end)
    clear_timer:Show()
  end)
  ok_btn:SetPoint("LEFT", gp_box, "RIGHT", 80, 0)

  local sep2 = panel:CreateTexture(nil, "ARTWORK")
  sep2:SetHeight(1)
  sep2:SetPoint("TOPLEFT", preview_text, "BOTTOMLEFT", 0, -12)
  sep2:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, 0)
  -- SetColorTexture не существует в WoW 3.3.5a — SetTexture + SetVertexColor.
  sep2:SetTexture("Interface\\Buttons\\WHITE8x8")
  sep2:SetVertexColor(0.3, 0.25, 0.1, 0.6)

  local list_label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  list_label:SetPoint("TOPLEFT", sep2, "BOTTOMLEFT", 0, -10)
  list_label:SetText("Активные переопределения:")
  list_label:SetTextColor(0.95, 0.85, 0.5)

  local col_name = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  col_name:SetPoint("TOPLEFT", list_label, "BOTTOMLEFT", 0, -6)
  col_name:SetText("Предмет")
  col_name:SetTextColor(0.6, 0.6, 0.6)

  local col_id = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  col_id:SetPoint("LEFT", col_name, "LEFT", 200, 0)
  col_id:SetText("Item ID")
  col_id:SetTextColor(0.6, 0.6, 0.6)

  local col_gp = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  col_gp:SetPoint("LEFT", col_name, "LEFT", 310, 0)
  col_gp:SetText("GP")
  col_gp:SetTextColor(0.6, 0.6, 0.6)

  local list_container = CreateFrame("Frame", nil, panel)
  list_container:SetSize(540, GP_VISIBLE_ROWS * GP_ROW_HEIGHT)
  list_container:SetPoint("TOPLEFT", col_name, "BOTTOMLEFT", 0, -4)
  apply_backdrop(list_container, { r=0.06, g=0.06, b=0.08, a=0.9 }, { r=0.2, g=0.2, b=0.2, a=1 }, 1)

  -- FauxScrollFrame с глобальным именем!
  gp_list_scroll_frame = CreateFrame("ScrollFrame", "GoldGPLMGPListScroll", list_container, "FauxScrollFrameTemplate")
  gp_list_scroll_frame:SetSize(540, GP_VISIBLE_ROWS * GP_ROW_HEIGHT)
  gp_list_scroll_frame:SetPoint("TOPLEFT", list_container, "TOPLEFT", 0, 0)
  gp_list_scroll_frame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, GP_ROW_HEIGHT, refresh_gp_list)
  end)

  for i = 1, GP_VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, list_container)
    row:SetSize(540, GP_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list_container, "TOPLEFT", 0, -((i-1) * GP_ROW_HEIGHT))

    local bg_color = (i % 2 == 0)
      and { r=0.08, g=0.08, b=0.10, a=0.85 }
      or  { r=0.06, g=0.06, b=0.08, a=0.85 }
    apply_backdrop(row, bg_color, { r=0, g=0, b=0, a=0 }, 0)
    row.base_bg = bg_color

    row:SetScript("OnEnter", function(self)
      apply_backdrop(self, { r=0.20, g=0.16, b=0.06, a=0.95 }, { r=0, g=0, b=0, a=0 }, 0)
    end)
    row:SetScript("OnLeave", function(self)
      apply_backdrop(self, self.base_bg, { r=0, g=0, b=0, a=0 }, 0)
    end)

    row.name_text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name_text:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.name_text:SetWidth(190)
    row.name_text:SetJustifyH("LEFT")
    row.name_text:SetTextColor(0.9, 0.9, 0.9)

    row.id_text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.id_text:SetPoint("LEFT", row, "LEFT", 200, 0)
    row.id_text:SetTextColor(0.6, 0.6, 0.6)

    row.gp_text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.gp_text:SetPoint("LEFT", row, "LEFT", 310, 0)
    row.gp_text:SetTextColor(1.0, 0.84, 0.0)

    -- closure scoping — двухстрочное объявление
    local del_btn
    del_btn = create_button(row, "X", 22, 18, function()
      if del_btn.item_id then
        delete_gp_override(del_btn.item_id)
        refresh_gp_list()
      end
    end)
    del_btn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    apply_backdrop(del_btn, { r=0.25, g=0.06, b=0.06, a=0.95 }, { r=0.6, g=0.1, b=0.1, a=1.0 }, 2)
    del_btn.text:SetTextColor(1.0, 0.3, 0.3)
    row.del_btn = del_btn

    row:Hide()
    gp_list_rows[i] = row
  end

  -- closure scoping — двухстрочное объявление
  local clear_all_btn
  clear_all_btn = create_button(panel, "Очистить всё", 120, 24, function()
    local db = get_db()
    if db then
      db.gp_overrides = {}
      gp_list_dirty = true
      refresh_gp_list()
      if _G.GoldGPLootMaster and _G.GoldGPLootMaster.ClearItemCache then
        _G.GoldGPLootMaster:ClearItemCache()
      end
    end
  end)
  clear_all_btn:SetPoint("BOTTOMRIGHT", list_container, "BOTTOMRIGHT", 0, -8)

  panel:SetScript("OnShow", function()
    gp_list_dirty = true
    refresh_gp_list()
  end)

  return panel
end

-- ============================================================================
-- ГЛАВНАЯ ПАНЕЛЬ + РЕГИСТРАЦИЯ В INTERFACE OPTIONS
-- ============================================================================
local optionsRegistered = false
-- локальный флаг блокировки повторной регистрации
local _lm_register_in_progress = false

-- Панель регистрируется ВСЕГДА (категория настроек не может исчезнуть:
-- молчаливый ранний return по CanEditOfficerNote = баг «исчезли настройки»),
-- а офицерские ограничения применяются К СОДЕРЖИМОМУ: у не-офицеров
-- служебные кнопки скрыты и показано пояснение. Состояние перепроверяется
-- при каждом открытии панели (права могут измениться в сессии).
local lm_test_buttons = nil       -- { testgp_btn, testfull_btn }
local lm_officer_notice = nil     -- FontString «только для офицеров»

local function ApplyLMOfficerState()
  local officer = CanEditOfficerNote() and true or false
  if lm_test_buttons then
    for _, btn in ipairs(lm_test_buttons) do
      if btn then
        if officer then btn:Show() else btn:Hide() end
      end
    end
  end
  if lm_officer_notice then
    if officer then lm_officer_notice:Hide() else lm_officer_notice:Show() end
  end
end

local function register_options()
  if optionsRegistered then return end
  if not LM then return end
  if not LM.db then return end  -- LM.db должен быть готов
  -- локальный флаг-блокировка
  if _lm_register_in_progress then return end
  -- Гейт CanEditOfficerNote здесь НЕ ставится — панель регистрируется всегда
  -- (см. комментарий выше), офицерство применяется к кнопкам на OnShow.
  _lm_register_in_progress = true

  -- Ре-резолв ядра НА МОМЕНТ регистрации (файловая локаль могла быть
  -- захвачена nil при отложенном старте модуля — waiter доинициализирует позже)
  local Addon = GoldGP

  local COLORS = GoldGP.UIKit.COLORS
  local create_button = GoldGP.UIKit.create_button

  -- Главная панель
  local mainPanel = CreateFrame("Frame")
  mainPanel.name = "GoldGP_LootMaster"

  local title = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("|cFFFFD700Gold|r|cFFAAAAAAGP|r LootMaster - настройки")

  local subtitle = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  subtitle:SetText("Распределение лута с начислением GP через GoldGP.")
  subtitle:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Кнопка "Тест GP"
  local testgp_btn = create_button(mainPanel, "Тест GP", 120, 24, function()
    if LM.TestGP then LM:TestGP() end
  end)
  testgp_btn:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -10)

  -- Кнопка "Полный тест"
  local testfull_btn = create_button(mainPanel, "Полный тест", 130, 24, function()
    if LM.TestFull then LM:TestFull() end
  end)
  testfull_btn:SetPoint("LEFT", testgp_btn, "RIGHT", 8, 0)

  -- Офицерский режим содержимого (кнопки/пояснение) — см. комментарий выше.
  -- Ссылки сохраняются, ApplyLMOfficerState() вызывается в OnShow панели.
  lm_test_buttons = { testgp_btn, testfull_btn }
  lm_officer_notice = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lm_officer_notice:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
  lm_officer_notice:SetWidth(480)
  lm_officer_notice:SetJustifyH("LEFT")
  lm_officer_notice:SetText("|cFFF0A000Настройки и тесты доступны только офицерам\n(звание с правом редактирования офицерских заметок).|r")
  lm_officer_notice:Hide()
  mainPanel:SetScript("OnShow", ApplyLMOfficerState)
  ApplyLMOfficerState()

  -- Информация о версии
  local ver = mainPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ver:SetPoint("BOTTOMRIGHT", mainPanel, "BOTTOMRIGHT", -10, 10)
  ver:SetText("LootMaster v" .. (LM.VERSION or "?") .. "  |  GoldGP v" .. (Addon and Addon.version or "?"))
  ver:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Регистрируем все панели
  -- Каждая панель в отдельном pcall — чтобы найти какая крашит
  local ok1, err1 = pcall(InterfaceOptions_AddCategory, mainPanel)
  if not ok1 then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050LM: mainPanel FAILED:|r " .. tostring(err1)) end

  local ok2, err2 = pcall(function()
    InterfaceOptions_AddCategory(create_general_tab())
  end)
  if not ok2 then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050LM: general_tab FAILED:|r " .. tostring(err2)) end

  local ok3, err3 = pcall(function()
    InterfaceOptions_AddCategory(create_gp_tab())
  end)
  if not ok3 then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5050LM: gp_tab FAILED:|r " .. tostring(err3)) end

  LM._optionsPanel = mainPanel
  -- ВСЕГДА сбрасываем флаг (даже при ошибке) — иначе deadlock
  _lm_register_in_progress = false
  -- Регистрируем как успешную ТОЛЬКО если все pcall успешны
  if ok1 and ok2 and ok3 then
    optionsRegistered = true
  end

  if Addon and Addon.Log then
    Addon.Log:Info("GoldGP_LootMaster_Options registered (2 subcategories: Общие + GP)")
  end
end

-- ============================================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================================
function LM:OpenOptions()
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
-- ПРИМЕНЕНИЕ ТЕКСТОВ КНОПОК К ОКНУ КАНДИДАТА
-- ============================================================================
-- Вызывается из настроек при изменении текста, а также из Client.lua при
-- показе lootFrame. Безопасна для вызова в любой момент (если фреймы ещё
-- не созданы — просто ничего не делает).
function LM:ApplyButtonLabels()
  -- Локальные lootFrames доступны через LM._lootFrames (сохраняется в Client.lua)
  local frames = self._lootFrames
  if not frames then return end
  local need_text    = get_setting("btn_need_text",    "Мейн спек")
  local offspec_text = get_setting("btn_offspec_text", "Офф спек")
  local pass_text    = get_setting("btn_pass_text",    "Откажусь")
  for _, lf in ipairs(frames) do
    if lf.btnNeed and lf.btnNeed.text then
      lf.btnNeed.text:SetText(need_text)
    end
    if lf.btnOffspec and lf.btnOffspec.text then
      lf.btnOffspec.text:SetText(offspec_text)
    end
    if lf.btnPass and lf.btnPass.text then
      lf.btnPass.text:SetText(pass_text)
    end
  end
end

-- ============================================================================
-- РЕГИСТРАЦИЯ ЧЕРЕЗ ADDON_LOADED
-- ============================================================================
-- В WoW 3.3.5a нет C_Timer — используем OnUpdate для задержки 0.5 сек после
-- ADDON_LOADED, чтобы LM.db гарантированно был инициализирован.

local function schedule_register(delay)
  local frame = CreateFrame("Frame")
  local elapsed_total = 0
  frame:Show()
  frame:SetScript("OnUpdate", function(self, elapsed)
    elapsed_total = elapsed_total + elapsed
    if elapsed_total >= delay then
      self:Hide()
      if not optionsRegistered and LM and LM.db then
        pcall(register_options)
      end
    end
  end)
end

local optionsLoadFrame = CreateFrame("Frame")
optionsLoadFrame:RegisterEvent("ADDON_LOADED")
optionsLoadFrame:SetScript("OnEvent", function(self, event, addonName)
  if event == "ADDON_LOADED" and addonName == "GoldGP_LootMaster" then
    self:UnregisterEvent("ADDON_LOADED")
    -- Задержка 0.5 сек чтобы LM.db гарантированно был инициализирован
    schedule_register(0.5)
  end
end)

-- ПРОСТОЙ И НАДЁЖНЫЙ паттерн — OnUpdate проверяет каждые 0.2 сек.
local lmOptionsTimer = CreateFrame("Frame")
lmOptionsTimer:Show()
local lm_timer_elapsed = 0
lmOptionsTimer:SetScript("OnUpdate", function(self, elapsed)
  if optionsRegistered then
    self:Hide()
    return
  end
  lm_timer_elapsed = lm_timer_elapsed + elapsed
  if lm_timer_elapsed >= 0.2 then
    lm_timer_elapsed = 0
    if LM and LM.db then
      register_options()
    end
  end
end)

if Addon and Addon.Log then
  Addon.Log:Info("GoldGP_LootMaster_Options module loaded (waiting for ADDON_LOADED)")
end
