-- GoldGP_UIKit.lua

local Addon = GoldGP

-- ============================================================================
-- ЦВЕТА (единая палитра для всех модулей)
-- ============================================================================
local COLORS = {
  -- Фоны окон — полупрозрачные тёмные (alpha < 1.0)
  bg_main      = { r = 0.06, g = 0.06, b = 0.08, a = 0.88 },  -- главное окно, чуть прозрачное
  bg_panel     = { r = 0.10, g = 0.10, b = 0.13, a = 0.92 },  -- панели (тулбар, хедер, футер)
  bg_row       = { r = 0.08, g = 0.08, b = 0.10, a = 0.85 },  -- строка таблицы
  bg_row_hover = { r = 0.14, g = 0.13, b = 0.08, a = 0.95 },  -- строка под курсором (мягкий золотистый отблеск)
  bg_row_sel   = { r = 0.28, g = 0.22, b = 0.08, a = 0.95 },  -- выбранная строка

  -- Края — чёрные для всех окон
  border       = { r = 0.00, g = 0.00, b = 0.00, a = 1.0 },  -- чёрный край окна (2px)
  border_gold  = { r = 0.79, g = 0.64, b = 0.15, a = 1.0 },  -- золотая рамка для акцентов
  border_thin  = { r = 0.15, g = 0.15, b = 0.18, a = 1.0 },  -- тонкая внутренняя разделительная

  -- Текст
  text_main    = { r = 0.95, g = 0.95, b = 0.95, a = 1.0 },
  text_dim     = { r = 0.60, g = 0.60, b = 0.60, a = 1.0 },  -- 0.60: читаемость серого на тёмном
  text_gold    = { r = 1.00, g = 0.84, b = 0.00, a = 1.0 },
  text_success = { r = 0.30, g = 0.85, b = 0.30, a = 1.0 },
  text_error   = { r = 0.95, g = 0.30, b = 0.30, a = 1.0 },
}

-- ============================================================================
-- СТИЛЬ КНОПОК
-- ============================================================================
-- Два размера кнопок вместо разнобоя 24/22/20/18:
--   BTN_H    — обычные кнопки (тулбар, футер);
--   BTN_H_SM — маленькие (в заголовке, в строках таблиц).
local BTN_H    = 24
local BTN_H_SM = 20

-- Концепция: flat-дизайн с тонкой золотой рамкой.
-- При hover — рамка становится ярче + появляется лёгкий золотистый отблеск фона.
-- При нажатии — фон затемняется (эффект "вдавленности").
-- Текст при default — мягкий кремовый, при hover — золотой.

local BTN_BG           = { r = 0.14, g = 0.14, b = 0.18, a = 0.95 }  -- глубокий тёмный
local BTN_BG_HOVER     = { r = 0.30, g = 0.24, b = 0.10, a = 0.98 }  -- золотистый отблеск
local BTN_BG_DOWN      = { r = 0.08, g = 0.08, b = 0.10, a = 1.00 }  -- затемнённое
local BTN_BORDER       = { r = 0.40, g = 0.32, b = 0.15, a = 1.00 }  -- золотистая, тусклая
local BTN_BORDER_HOVER = { r = 0.95, g = 0.80, b = 0.20, a = 1.00 }  -- золотистая, яркая

-- Текст кнопок
local BTN_TEXT         = { r = 0.92, g = 0.90, b = 0.80, a = 1.0 }  -- кремовый
local BTN_TEXT_HOVER   = { r = 1.00, g = 0.84, b = 0.00, a = 1.0 }  -- золотой

-- Активная кнопка (Gold/GP, Только рейд) — выделена
local ACTIVE_BG        = { r = 0.55, g = 0.42, b = 0.08, a = 1.0 }
local ACTIVE_BORDER    = { r = 1.00, g = 0.84, b = 0.00, a = 1.0 }

-- Неактивная кнопка (Gold/GP, когда другая активна)
local INACTIVE_BG      = { r = 0.10, g = 0.10, b = 0.13, a = 0.90 }
local INACTIVE_BORDER  = { r = 0.18, g = 0.18, b = 0.20, a = 1.0 }

-- Цвета классов
local CLASS_COLORS = {
  ["DRUID"]      = { r = 1.00, g = 0.49, b = 0.04 },
  ["HUNTER"]     = { r = 0.67, g = 0.83, b = 0.45 },
  ["MAGE"]       = { r = 0.41, g = 0.80, b = 0.94 },
  ["PALADIN"]    = { r = 0.96, g = 0.55, b = 0.73 },
  ["PRIEST"]     = { r = 1.00, g = 1.00, b = 1.00 },
  ["ROGUE"]      = { r = 1.00, g = 0.96, b = 0.41 },
  ["SHAMAN"]     = { r = 0.00, g = 0.44, b = 0.87 },
  ["WARLOCK"]    = { r = 0.58, g = 0.51, b = 0.79 },
  ["WARRIOR"]    = { r = 0.78, g = 0.61, b = 0.43 },
  ["DEATHKNIGHT"] = { r = 0.77, g = 0.12, b = 0.23 },
}

local CLASS_ICON_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local CLASS_ICON_TCOORDS = CLASS_ICON_TCOORDS or {
  ["WARRIOR"]     = { 0,    0.25, 0,    0.25 },
  ["MAGE"]        = { 0.25, 0.5,  0,    0.25 },
  ["ROGUE"]       = { 0.5,  0.75, 0,    0.25 },
  ["DRUID"]       = { 0.75, 1.0,  0,    0.25 },
  ["HUNTER"]      = { 0,    0.25, 0.25, 0.5  },
  ["SHAMAN"]      = { 0.25, 0.5,  0.25, 0.5  },
  ["PRIEST"]      = { 0.5,  0.75, 0.25, 0.5  },
  ["WARLOCK"]     = { 0.75, 1.0,  0.25, 0.5  },
  ["PALADIN"]     = { 0,    0.25, 0.5,  0.75 },
  ["DEATHKNIGHT"] = { 0.25, 0.5,  0.5,  0.75 },
}

-- ============================================================================
-- ПРИМЕНИТЬ BACKDROP
-- ============================================================================
-- apply_backdrop вызывается на hover/leave каждой строки и каждой кнопки —
-- горячий путь. SetBackdrop внутри копирует переданную таблицу, поэтому
-- переиспользование одной общей spec безопасно (без аллокаций на вызов).
local BACKDROP_SPEC = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  tile = false, tileSize = 0, edgeSize = 1,
  insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

local function apply_backdrop(frame, bg, edge, edge_size)
  BACKDROP_SPEC.edgeSize = edge_size or 1
  frame:SetBackdrop(BACKDROP_SPEC)
  frame:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1.0)
  frame:SetBackdropBorderColor(edge.r, edge.g, edge.b, edge.a or 1.0)
end

-- ============================================================================
-- СОЗДАТЬ КНОПКУ (единая реализация для всех модулей)
-- ============================================================================
-- Стиль:
--   * Тёмный полупрозрачный фон с золотистой тусклой рамкой (2px)
--   * Hover: золотистый отблеск фона + яркая золотая рамка
--   * Down: затемнённый фон (эффект вдавленности)
--   * Текст: кремовый по умолчанию, золотой при hover
--   * Звук: igMainMenuOptionCheckBoxOn
local function create_button(parent, text, width, height, callback)
  local btn = CreateFrame("Button", nil, parent)
  btn:SetSize(width or 100, height or 26)

  apply_backdrop(btn, BTN_BG, BTN_BORDER, 2)

  btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  btn.text:SetPoint("CENTER", btn, "CENTER", 0, 1)
  btn.text:SetText(text)
  btn.text:SetTextColor(BTN_TEXT.r, BTN_TEXT.g, BTN_TEXT.b)

  -- is_active — активная кнопка (переключатель) не реагирует на hover/down.
  -- Устанавливается извне: btn.is_active = true. Сбрасывается: btn.is_active = false.
  btn.is_active = false

  btn:SetScript("OnEnter", function(self)
    if self.is_active then return end
    apply_backdrop(self, BTN_BG_HOVER, BTN_BORDER_HOVER, 2)
    self.text:SetTextColor(BTN_TEXT_HOVER.r, BTN_TEXT_HOVER.g, BTN_TEXT_HOVER.b)
  end)
  btn:SetScript("OnLeave", function(self)
    if self.is_active then return end
    apply_backdrop(self, BTN_BG, BTN_BORDER, 2)
    self.text:SetTextColor(BTN_TEXT.r, BTN_TEXT.g, BTN_TEXT.b)
  end)
  btn:SetScript("OnMouseDown", function(self)
    if self.is_active then return end
    apply_backdrop(self, BTN_BG_DOWN, BTN_BORDER_HOVER, 2)
  end)
  btn:SetScript("OnMouseUp", function(self)
    if self.is_active then return end
    apply_backdrop(self, BTN_BG_HOVER, BTN_BORDER_HOVER, 2)
  end)
  btn:SetScript("OnClick", function()
    if callback then callback() end
    PlaySound("igMainMenuOptionCheckBoxOn")
  end)

  return btn
end

-- ============================================================================
-- СТИЛЬ EDITBOX (тёмный фон + золотистая рамка)
-- ============================================================================
local function style_editbox(editbox)
  if not editbox then return end
  local EB_BG = { r = 0.05, g = 0.05, b = 0.07, a = 0.95 }
  local EB_BORDER = { r = 0.40, g = 0.32, b = 0.15, a = 1.0 }
  apply_backdrop(editbox, EB_BG, EB_BORDER, 1)
  editbox:SetScript("OnEditFocusGained", function(self)
    apply_backdrop(self, EB_BG, BTN_BORDER_HOVER, 2)
  end)
  editbox:SetScript("OnEditFocusLost", function(self)
    apply_backdrop(self, EB_BG, EB_BORDER, 1)
  end)
end

-- ============================================================================
-- ФАБРИКИ ДЛЯ ПАНЕЛЕЙ НАСТРОЕК (общие для GoldGP_Options и LM_Options)
-- ============================================================================

-- Заголовок секции: золотой текст, привязка к якорю или к родителю
local function create_section_header(parent, title, anchor_frame, y_offset)
  local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  if anchor_frame then
    header:SetPoint("TOPLEFT", anchor_frame, "BOTTOMLEFT", 0, y_offset or -16)
  else
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y_offset or -16)
  end
  header:SetText("|cFFFFD700" .. title .. "|r")
  return header
end

-- Чекбокс с подписью: get_func/set_func — доступ к настройке
local function create_checkbox(parent, label_text, get_func, set_func, anchor_frame, y_offset)
  local cb = CreateFrame("CheckButton", nil, parent, "OptionsCheckButtonTemplate")
  if anchor_frame then
    cb:SetPoint("TOPLEFT", anchor_frame, "BOTTOMLEFT", 0, y_offset or -10)
  else
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y_offset or -10)
  end
  cb:SetChecked(get_func())
  cb:SetScript("OnClick", function(self)
    set_func(self:GetChecked())
  end)
  cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 1)
  cb.label:SetText(label_text)
  cb.label:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)
  return cb
end

-- ============================================================================
-- КНОПКИ МАСШТАБА ОКНА ("-" / "+" + текст "NNN%")
-- ============================================================================
-- Единые кнопки изменения масштаба для всех окон (UI, History, ML, Client).
-- parent — фрейм-владелец (тайтлбар); target — фрейм, чей масштаб меняется.
-- opts: { min, max, step, on_change } — по умолчанию 0.5..2.0, шаг 0.1.
-- Возвращает minus_btn, plus_btn, scale_text; якоря расставляет вызывающий
-- код (или create_window_chrome).
local function create_scale_buttons(parent, target, opts)
  opts = opts or {}
  local min_s     = opts.min or 0.5
  local max_s     = opts.max or 2.0
  local step      = opts.step or 0.1
  local on_change = opts.on_change

  local function fmt(s)
    return math.floor(s * 100 + 0.5) .. "%"
  end

  local scale_text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  scale_text:SetWidth(40)
  scale_text:SetJustifyH("CENTER")
  scale_text:SetText(fmt(target:GetScale() or 1))
  scale_text:SetTextColor(0.7, 0.7, 0.7)

  local function set_scale(s)
    s = math.max(min_s, math.min(max_s, s))
    target:SetScale(s)
    scale_text:SetText(fmt(s))
    if on_change then on_change(s) end
  end

  local minus_btn = create_button(parent, "-", 24, 24, function()
    set_scale((target:GetScale() or 1) - step)
  end)

  local plus_btn = create_button(parent, "+", 24, 24, function()
    set_scale((target:GetScale() or 1) + step)
  end)

  return minus_btn, plus_btn, scale_text
end

-- ============================================================================
-- ШАПКА ОКНА (тайтлбар: иконка + заголовок + масштаб + закрыть)
-- ============================================================================
-- Один фабричный метод для всех окон — шапки пиксель-в-пиксель одинаковы
-- (раньше каждое окно собирало шапку по-своему, с микроразличиями).
-- frame — окно; opts:
--   title           — текст заголовка (с разметкой |cff...);
--   icon            — путь к иконке 20x20 (опционально);
--   on_close        — колбэк закрытия (по умолчанию frame:Hide());
--   on_scale_change — колбэк после смены масштаба (опционально, для persist).
-- Возвращает таблицу частей — для доанкоривания своих элементов (кнопка
-- «Правила», бейдж read-only и т.п.):
--   { title_bar, title_icon, title_text, scale_minus, scale_plus, scale_text, close_btn }
local function create_window_chrome(frame, opts)
  opts = opts or {}

  local title_bar = CreateFrame("Frame", nil, frame)
  title_bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
  title_bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  title_bar:SetHeight(30)
  apply_backdrop(title_bar, COLORS.bg_panel, COLORS.border_gold, 1)

  local title_icon
  if opts.icon then
    title_icon = title_bar:CreateTexture(nil, "ARTWORK")
    title_icon:SetTexture(opts.icon)
    title_icon:SetSize(20, 20)
    title_icon:SetPoint("LEFT", title_bar, "LEFT", 8, 0)
  end

  local title_text = title_bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title_text:SetPoint("LEFT", title_icon or title_bar, "RIGHT", title_icon and 8 or 10, 0)
  title_text:SetText(opts.title or "")
  title_text:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  local scale_minus, scale_plus, scale_text = create_scale_buttons(title_bar, frame, {
    on_change = opts.on_scale_change,
  })
  scale_minus:SetPoint("RIGHT", title_bar, "RIGHT", -110, 0)
  scale_plus:SetPoint("RIGHT", title_bar, "RIGHT", -40, 0)
  scale_text:SetPoint("LEFT", scale_minus, "RIGHT", 5, 0)

  local close_btn = CreateFrame("Button", nil, title_bar, "UIPanelCloseButton")
  close_btn:SetPoint("RIGHT", title_bar, "RIGHT", 0, 0)
  close_btn:SetScript("OnClick", function()
    if opts.on_close then opts.on_close() else frame:Hide() end
  end)

  return {
    title_bar   = title_bar,
    title_icon  = title_icon,
    title_text  = title_text,
    scale_minus = scale_minus,
    scale_plus  = scale_plus,
    scale_text  = scale_text,
    close_btn   = close_btn,
  }
end

-- ============================================================================
-- ПУСТОЕ СОСТОЯНИЕ ОБЛАСТИ ДАННЫХ
-- ============================================================================
-- Заглушка «нет данных» для scroll-областей (ростер, журнал). Многострочный
-- текст задаётся через \n. Создаётся скрытой; вызывающий код показывает её,
-- когда список пуст, и прячет при наличии строк.
local function create_empty_state(parent, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("CENTER", parent, "CENTER", 0, 0)
  fs:SetJustifyH("CENTER")
  fs:SetJustifyV("MIDDLE")
  fs:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  fs:SetText(text or "")
  fs:Hide()
  return fs
end

-- ============================================================================
-- ЭКСПОРТ
-- ============================================================================
-- Множество валидных токенов классов — для Addon:GetClassToken (Core).
-- UIKit грузится сразу после Core, поэтому к моменту вызовов GetClassToken
-- это множество уже готово.
Addon.CLASS_TOKENS = {}
for token in pairs(CLASS_ICON_TCOORDS) do
  Addon.CLASS_TOKENS[token] = true
end

Addon.UIKit = {
  COLORS = COLORS,
  CLASS_COLORS = CLASS_COLORS,
  CLASS_ICON_TEXTURE = CLASS_ICON_TEXTURE,
  CLASS_ICON_TCOORDS = CLASS_ICON_TCOORDS,
  ACTIVE_BG = ACTIVE_BG,
  ACTIVE_BORDER = ACTIVE_BORDER,
  INACTIVE_BG = INACTIVE_BG,
  INACTIVE_BORDER = INACTIVE_BORDER,
  BTN_H = BTN_H,
  BTN_H_SM = BTN_H_SM,
  apply_backdrop = apply_backdrop,
  create_button = create_button,
  style_editbox = style_editbox,
  create_section_header = create_section_header,
  create_checkbox = create_checkbox,
  create_scale_buttons = create_scale_buttons,
  create_window_chrome = create_window_chrome,
  create_empty_state = create_empty_state,
}

if Addon.Log then
  Addon.Log:Info("GoldGP_UIKit loaded (v2.1.0)")
end
