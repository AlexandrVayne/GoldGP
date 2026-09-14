-- GoldGP_History.lua

local Addon = GoldGP
local History = {}
Addon.History = History

-- Локальный UI
local history_frame
local rows = {}
local filter_text = ""
local sort_desc = true     -- true = новые сверху

-- Debounce для поиска — чтобы при быстром вводе не вызывать Refresh на каждый символ
local search_debounce_at = 0  -- время GetTime() когда нужно обновить
local search_debounce_frame
search_debounce_frame = CreateFrame("Frame")
search_debounce_frame:Hide()
search_debounce_frame:SetScript("OnUpdate", function()
  if search_debounce_at > 0 and GetTime() >= search_debounce_at then
    search_debounce_at = 0
    search_debounce_frame:Hide()
    History:Refresh()
  end
end)

-- ============================================================================
-- ЦВЕТА (из UIKit + дополнительные для типов журнала)
-- ============================================================================
-- UIKit загружается раньше в .toc — fallbacks не нужны.
local UIKit = Addon.UIKit
local COLORS = UIKit.COLORS
-- Дополнительные цвета для типов записей (журналльные) — дополняем COLORS напрямую.
COLORS.text_blue   = { r = 0.40, g = 0.60, b = 1.00, a = 1.0 }
COLORS.text_purple = { r = 0.70, g = 0.40, b = 0.95, a = 1.0 }

local apply_backdrop = UIKit.apply_backdrop
local style_editbox = UIKit.style_editbox

-- Единая функция кнопки из UIKit
local make_button = UIKit.create_button

-- ============================================================================
-- ДОБАВЛЕНИЕ ЗАПИСЕЙ В ЖУРНАЛ
-- ============================================================================

-- Подписываемся на события начислений и записываем в журнал
Addon:RegisterCallback("GoldAward", function(name, reason, amount, mass, undo)
  if not Addon.db or not Addon.db.global then return end
  if not Addon.db.global.history then Addon.db.global.history = {} end

  local entry = {
    time = time(),
    type = mass and "MASS_GOLD" or "GOLD",
    target = name,
    reason = reason or "",
    amount = amount,
    officer = UnitName("player") or "?",
    undo = undo or false,
  }
  tinsert(Addon.db.global.history, entry)

  -- Ограничиваем размер журнала (5000 записей)
  while #Addon.db.global.history > 5000 do
    tremove(Addon.db.global.history, 1)
  end

  -- Обновляем UI если открыт
  History:InvalidateFilter()
  if history_frame and history_frame:IsShown() then
    History:Refresh()
  end
end)

Addon:RegisterCallback("GPAward", function(name, reason, amount, mass, undo)
  if not Addon.db or not Addon.db.global then return end
  if not Addon.db.global.history then Addon.db.global.history = {} end

  local entry = {
    time = time(),
    type = mass and "MASS_GP" or "GP",
    target = name,
    reason = reason or "",
    amount = amount,
    officer = UnitName("player") or "?",
    undo = undo or false,
  }
  tinsert(Addon.db.global.history, entry)

  while #Addon.db.global.history > 5000 do
    tremove(Addon.db.global.history, 1)
  end

  History:InvalidateFilter()
  if history_frame and history_frame:IsShown() then
    History:Refresh()
  end
end)

Addon:RegisterCallback("Decay", function(percent)
  if not Addon.db or not Addon.db.global then return end
  if not Addon.db.global.history then Addon.db.global.history = {} end

  local entry = {
    time = time(),
    type = "DECAY",
    target = "ALL",
    reason = string.format("Decay %d%%", percent),
    amount = 0,
    officer = UnitName("player") or "?",
    undo = false,
  }
  tinsert(Addon.db.global.history, entry)

  while #Addon.db.global.history > 5000 do
    tremove(Addon.db.global.history, 1)
  end

  History:InvalidateFilter()
  if history_frame and history_frame:IsShown() then
    History:Refresh()
  end
end)

-- Подписка на RestoreDone — запись об отмене в журнал
Addon:RegisterCallback("RestoreDone", function()
  if not Addon.db or not Addon.db.global then return end
  if not Addon.db.global.history then Addon.db.global.history = {} end
  local entry = {
    time = time(),
    type = "UNDO",
    target = "ALL",
    reason = "Отмена последней операции",
    amount = 0,
    officer = UnitName("player") or "?",
    undo = true,
  }
  tinsert(Addon.db.global.history, entry)
  while #Addon.db.global.history > 5000 do
    tremove(Addon.db.global.history, 1)
  end
  History:InvalidateFilter()
  if history_frame and history_frame:IsShown() then
    History:Refresh()
  end
end)

-- ============================================================================
-- ФИЛЬТРАЦИЯ И СОРТИРОВКА
-- ============================================================================
local function matches_filter(entry)
  -- Фильтр по подстроке (имя/причина/офицер)
  if filter_text and filter_text ~= "" then
    local ft = filter_text:lower()
    if not (entry.target and entry.target:lower():find(ft, 1, true))
       and not (entry.reason and entry.reason:lower():find(ft, 1, true))
       and not (entry.officer and entry.officer:lower():find(ft, 1, true)) then
      return false
    end
  end

  return true
end

-- Кэшируем результат фильтрации.
-- Кэш инвалидируется при изменении filter_text или при добавлении новой записи.
local filtered_cache = nil
local filter_signature = ""

local function get_filtered_entries()
  -- Считаем подпись — если изменилась, кэш невалиден
  local history_count = 0
  if Addon.db and Addon.db.global and Addon.db.global.history then
    history_count = #Addon.db.global.history
  end
  local sig = string.format("%s|%d",
    filter_text or "", history_count)
  if filtered_cache and sig == filter_signature then
    return filtered_cache
  end
  filter_signature = sig

  local result = {}
  if not Addon.db or not Addon.db.global or not Addon.db.global.history then
    filtered_cache = result
    return result
  end
  for _, entry in ipairs(Addon.db.global.history) do
    if matches_filter(entry) then
      tinsert(result, entry)
    end
  end
  -- Сортировка по времени (новые сверху)
  table.sort(result, function(a, b)
    if sort_desc then
      return a.time > b.time
    else
      return a.time < b.time
    end
  end)
  filtered_cache = result
  return result
end

-- Публичный метод для инвалидации кэша фильтрации (вызывается при добавлении записи)
function History:InvalidateFilter()
  filtered_cache = nil
  filter_signature = ""
end

-- ============================================================================
-- ЦВЕТА ТИПОВ ЗАПИСЕЙ
-- ============================================================================
local function type_color(entry_type)
  if entry_type == "MASS_GOLD" then return COLORS.text_gold end
  if entry_type == "GOLD" then      return COLORS.text_gold end
  if entry_type == "MASS_GP" then   return COLORS.text_blue end
  if entry_type == "GP" then        return COLORS.text_blue end
  if entry_type == "DECAY" then     return COLORS.text_purple end
  return COLORS.text_main
end

local function type_label(entry_type)
  if entry_type == "MASS_GOLD" then return "Mass+Gold" end
  if entry_type == "GOLD" then      return "+Gold" end
  if entry_type == "MASS_GP" then   return "Mass+GP" end
  if entry_type == "GP" then        return "+GP" end
  if entry_type == "DECAY" then     return "Decay" end
  return entry_type
end

-- ============================================================================
-- СОЗДАНИЕ ОКНА ЖУРНАЛА
-- ============================================================================
local ROW_HEIGHT = 24
-- Число видимых строк вычисляется из реальной высоты скролл-зоны (аналогично
-- UI.lua): высота окна настраивается, хардкод ломает прокрутку. До создания
-- окна — консервативный fallback.
local function GetVisibleRows()
  if not history_frame or not history_frame.scroll then return 16 end
  local h = history_frame.scroll:GetHeight() or 0
  if h < ROW_HEIGHT then return 1 end
  return math.floor((h + 2) / ROW_HEIGHT)
end

local function create_history_frame()
  -- Если фрейм уже существует, но ширина в настройках изменилась —
  -- уничтожаем старый и создаём новый. Иначе колонки не перераспределятся.
  if history_frame then
    local current_width = history_frame:GetWidth()
    local cfg_width = 600
    if Addon.db and Addon.db.profile and Addon.db.profile.history_width then
      cfg_width = math.max(500, math.min(1200, Addon.db.profile.history_width))
    end
    if math.abs(current_width - cfg_width) > 1 then
      history_frame:Hide()
      history_frame = nil
      -- Очистить кэш строк — они привязаны к старому фрейму (родителю)
      wipe(rows)
    else
      return history_frame
    end
  end

  -- Фрейм АНОНИМНЫЙ намеренно: при пересоздании (смена ширины) CreateFrame
  -- с тем же именем вернул бы СТАРЫЙ фрейм; анонимный пересоздаётся корректно.
  local f = CreateFrame("Frame", nil, UIParent)
  -- Ширина из настроек (по умолчанию 600).
  -- Расчёт высоты: title 30 + filter 40 + header 24 + scroll(16×24=384) + bottom 24 = 514.
  local hist_width = 600
  if Addon.db and Addon.db.profile and Addon.db.profile.history_width then
    hist_width = math.max(500, math.min(1200, Addon.db.profile.history_width))
  end
  f:SetSize(hist_width, 514)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  apply_backdrop(f, COLORS.bg_main, COLORS.border, 2)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, xOfs, yOfs = self:GetPoint(1)
    if point and Addon.db and Addon.db.global then
      if not Addon.db.global.window_positions then Addon.db.global.window_positions = {} end
      Addon.db.global.window_positions.history = { point = point, relPoint = relPoint, x = xOfs, y = yOfs }
    end
  end)
  -- Восстановление позиции
  if Addon.db and Addon.db.global and Addon.db.global.window_positions and Addon.db.global.window_positions.history then
    local pos = Addon.db.global.window_positions.history
    f:ClearAllPoints()
    f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
  end
  f:Hide()

  -- Шапка окна: единый фабричный метод UIKit
  local chrome = UIKit.create_window_chrome(f, {
    title = "|cFFFFD700Mad|r|cFFAAAAAATeaParty|r |cFF808080Журнал|r",
    icon  = "Interface\\Icons\\INV_Misc_Book_09",
    on_close = function() f:Hide() end,
  })

  -- Высота 40px = отступ 8 + поле 24 + отступ 8.
  local filter_bar = CreateFrame("Frame", nil, f)
  filter_bar:SetPoint("TOPLEFT", chrome.title_bar, "BOTTOMLEFT", 0, -2)
  filter_bar:SetPoint("TOPRIGHT", chrome.title_bar, "BOTTOMRIGHT", 0, -2)
  filter_bar:SetHeight(40)
  apply_backdrop(filter_bar, COLORS.bg_panel, COLORS.border, 1)

  -- Поиск по подстроке — единственный фильтр журнала
  local search_label = filter_bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  search_label:SetPoint("LEFT", filter_bar, "LEFT", 10, 0)
  search_label:SetText("Поиск:")
  search_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  local search_box = CreateFrame("EditBox", "GoldGPHistSearch", filter_bar, "InputBoxTemplate")
  search_box:SetSize(180, 20)
  search_box:SetPoint("LEFT", search_label, "RIGHT", 8, 0)
  search_box:SetAutoFocus(false)
  style_editbox(search_box)
  -- Debounce 250мс: Refresh вызывается не на каждый символ, а после паузы ввода —
  -- иначе каждая буква пересортировывает до 5000 записей.
  search_box:SetScript("OnTextChanged", function(self)
    filter_text = self:GetText() or ""
    filter_text = filter_text:lower()
    search_debounce_at = GetTime() + 0.25
    search_debounce_frame:Show()
  end)
  search_box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  search_box:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    filter_text = ""
    self:ClearFocus()
    History:Refresh()
  end)

  -- Подсказка справа от поиска
  local search_hint = filter_bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  search_hint:SetPoint("LEFT", search_box, "RIGHT", 12, 0)
  search_hint:SetText("|cFF808080Поиск по имени / причине / офицеру|r")
  search_hint:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Заголовок таблицы
  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", filter_bar, "BOTTOMLEFT", 0, -2)
  header:SetPoint("TOPRIGHT", filter_bar, "BOTTOMRIGHT", 0, -2)
  header:SetHeight(24)
  apply_backdrop(header, COLORS.bg_panel, COLORS.border, 1)

  -- Колонки: Время | Тип | Игрок | Gold/GP | Причина | Офицер
  -- В колонке времени только дата DD.MM — полное время в tooltip строки.
  -- Фиксированные колонки: time(50) + type(75) + target(100) + amount(75) + officer(85) = 385px
  -- "Причина" = hist_width - 385 - 40 (отступы)
  local fixed_cols = 50 + 75 + 100 + 75 + 85  -- 385
  local reason_width = math.max(80, hist_width - fixed_cols - 40)  -- минимум 80, отступы 40
  local COL_X = { time = 12, type = 70, target = 150, amount = 255, reason = 335, officer = 335 + reason_width + 5 }
  local COL_WIDTH = { time = 50, type = 75, target = 100, amount = 75, reason = reason_width, officer = 85 }

  local function create_header_btn(text, x, width)
    local btn = CreateFrame("Button", nil, header)
    btn:SetSize(width, 22)
    btn:SetPoint("LEFT", header, "LEFT", x, 0)
    apply_backdrop(btn, COLORS.bg_panel, COLORS.border, 1)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("LEFT", btn, "LEFT", 4, 0)
    btn.text:SetText(text)
    btn.text:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
    return btn
  end

  create_header_btn("Время",   COL_X.time,     COL_WIDTH.time)
  create_header_btn("Тип",     COL_X.type,     COL_WIDTH.type)
  create_header_btn("Игрок",   COL_X.target,   COL_WIDTH.target)
  create_header_btn("Сумма",   COL_X.amount,   COL_WIDTH.amount)
  create_header_btn("Причина", COL_X.reason,   COL_WIDTH.reason)
  create_header_btn("Офицер",  COL_X.officer,  COL_WIDTH.officer)

  -- ScrollFrame ОБЯЗАН иметь глобальное имя "GoldGPHistoryScroll":
  -- FauxScrollFrame_OnVerticalScroll и FauxScrollFrame_Update в WoW 3.3.5a берут
  -- дочерний ScrollBar через _G[frame:GetName().."ScrollBar"]; если GetName() = nil,
  -- конкатенация nil.."ScrollBar" падает на каждом скролле (offset не обновляется).
  -- Поэтому при пересоздании фрейма scroll переиспользуется через _G[] + SetParent
  -- (CreateFrame с тем же именем вернул бы старый фрейм).
  local scroll = _G["GoldGPHistoryScroll"]
  if scroll then
    -- Переиспользуем существующий scroll при пересоздании history_frame (смена ширины)
    scroll:SetParent(f)
    scroll.offset = 0  -- сброс offset при пересоздании
  else
    scroll = CreateFrame("ScrollFrame", "GoldGPHistoryScroll", f, "FauxScrollFrameTemplate")
  end
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -22, -2)
  scroll:SetPoint("BOTTOM", f, "BOTTOM", 0, 24)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() History:Refresh() end)
  end)
  -- Скрываем стандартный ScrollBar и его кнопки — его текстура торчала выше фрейма ("поле над окном")
  local sb = _G["GoldGPHistoryScrollScrollBar"]
  if sb then
    sb:Hide()
    sb:SetAlpha(0)
  end
  local up_btn = _G["GoldGPHistoryScrollScrollBarScrollUpButton"]
  if up_btn then up_btn:Hide() end
  local down_btn = _G["GoldGPHistoryScrollScrollBarScrollDownButton"]
  if down_btn then down_btn:Hide() end
  local thumb = _G["GoldGPHistoryScrollScrollBarThumbTexture"]
  if thumb then thumb:Hide() end

  -- Пустое состояние журнала: создаётся один раз на scroll — scroll
  -- переиспользуется при пересоздании окна (смена ширины из настроек).
  if not scroll.empty_state then
    scroll.empty_state = UIKit.create_empty_state(scroll,
      "Журнал пуст\n\nНачисления Gold/GP и события появятся здесь\nпосле первой активности аддона.")
  end

  -- Сохраняем ссылки
  f.search_box = search_box
  f.scroll = scroll
  f.COL_X = COL_X
  f.COL_WIDTH = COL_WIDTH

  -- Статус-бар снизу
  local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 4)
  status:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  status:SetText("")
  f.status = status

  -- Кнопка "Отмена последнего" с диалогом подтверждения:
  -- показывает, что именно отменится, перед выполнением
  local undo_last_btn
  undo_last_btn = make_button(f, "<< Отмена последнего", 150, 20, function()
    if not Addon.Award or not Addon.Award.UndoLastAction then
      Addon.PrintError("Award.UndoLastAction не загружен")
      return
    end
    -- Строим описание того, что отменится
    local undo_desc = "Нет данных для отмены"
    local has_mass = Addon.Award.HasMassBackup and Addon.Award:HasMassBackup()
    local has_decay = Addon.Award.HasDecayBackup and Addon.Award:HasDecayBackup()
    if has_mass then
      undo_desc = "Отмена массовки"
    elseif has_decay then
      undo_desc = "Отмена среза"
    end
    -- Проверяем последнюю запись в истории
    if Addon.db and Addon.db.global and Addon.db.global.history then
      local hist = Addon.db.global.history
      local last = hist[#hist]
      if last then
        local currency = (last.type == "GOLD" or last.type == "MASS_GOLD") and "EP" or "GP"
        if last.type == "DECAY" then
          undo_desc = string.format("Отмена среза (%s)", last.reason or "?")
        elseif last.target and last.target ~= "ALL" then
          undo_desc = string.format("Отмена: %s %s%d %s -> %s",
            last.target, last.amount > 0 and "+" or "", last.amount, currency, last.target)
        elseif last.type == "MASS_GOLD" or last.type == "MASS_GP" then
          undo_desc = string.format("Отмена массовки: '%s' (%d %s)", last.reason or "?", last.amount or 0, currency)
        end
      end
    end
    -- Диалог подтверждения
    StaticPopupDialogs["GOLDGP_HISTORY_UNDO_CONFIRM"] = {
      text = "|cFFFFD700Отмена последнего действия|r\n\n" .. undo_desc .. "\n\n|cFF808080Подтвердите отмену|r",
      button1 = "OK",
      button2 = "Отмена",
      timeout = 0,
      whileDead = 1,
      hideOnEscape = 1,
      OnAccept = function()
        Addon.Award:UndoLastAction()
        History:InvalidateFilter()
        History:Refresh()
      end,
    }
    StaticPopup_Show("GOLDGP_HISTORY_UNDO_CONFIRM")
  end)
  undo_last_btn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 2)
  -- Красно-оранжевая тема (опасная операция)
  local UNDO_BG = { r = 0.25, g = 0.12, b = 0.05, a = 1.0 }
  local UNDO_BG_HOVER = { r = 0.45, g = 0.20, b = 0.08, a = 1.0 }
  local UNDO_BORDER = { r = 0.70, g = 0.35, b = 0.10, a = 1.0 }
  local UNDO_BORDER_HOVER = { r = 1.00, g = 0.55, b = 0.15, a = 1.0 }
  apply_backdrop(undo_last_btn, UNDO_BG, UNDO_BORDER, 2)
  undo_last_btn.text:SetTextColor(1.00, 0.75, 0.40)
  undo_last_btn:SetScript("OnEnter", function(self)
    apply_backdrop(self, UNDO_BG_HOVER, UNDO_BORDER_HOVER, 2)
    self.text:SetTextColor(1.00, 0.90, 0.60)
  end)
  undo_last_btn:SetScript("OnLeave", function(self)
    apply_backdrop(self, UNDO_BG, UNDO_BORDER, 2)
    self.text:SetTextColor(1.00, 0.75, 0.40)
  end)
  history_frame = f
  return f
end

-- ============================================================================
-- СОЗДАНИЕ СТРОКИ
-- ============================================================================
local function create_row(idx)
  local row = CreateFrame("Button", nil, history_frame)
  row:SetSize(history_frame:GetWidth() - 24, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", history_frame.scroll, "TOPLEFT", 0, -((idx - 1) * ROW_HEIGHT))
  apply_backdrop(row, COLORS.bg_row, COLORS.border, 1)
  -- Регистрируем и ЛКМ и ПКМ
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.time:SetPoint("LEFT", row, "LEFT", history_frame.COL_X.time, 0)
  row.time:SetSize(history_frame.COL_WIDTH.time, ROW_HEIGHT)
  row.time:SetJustifyH("LEFT")

  row.type = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.type:SetPoint("LEFT", row, "LEFT", history_frame.COL_X.type, 0)
  row.type:SetSize(history_frame.COL_WIDTH.type, ROW_HEIGHT)
  row.type:SetJustifyH("LEFT")

  row.target = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.target:SetPoint("LEFT", row, "LEFT", history_frame.COL_X.target, 0)
  row.target:SetSize(history_frame.COL_WIDTH.target, ROW_HEIGHT)
  row.target:SetJustifyH("LEFT")

  row.amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.amount:SetPoint("LEFT", row, "LEFT", history_frame.COL_X.amount, 0)
  row.amount:SetSize(history_frame.COL_WIDTH.amount, ROW_HEIGHT)
  row.amount:SetJustifyH("RIGHT")

  row.reason = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.reason:SetPoint("LEFT", row, "LEFT", history_frame.COL_X.reason, 0)
  row.reason:SetSize(history_frame.COL_WIDTH.reason, ROW_HEIGHT)
  row.reason:SetJustifyH("LEFT")

  row.officer = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.officer:SetPoint("LEFT", row, "LEFT", history_frame.COL_X.officer, 0)
  row.officer:SetSize(history_frame.COL_WIDTH.officer, ROW_HEIGHT)
  row.officer:SetJustifyH("LEFT")

  -- Текст-индикатор "[X]" справа — для ВСЕХ записей
  -- (любое действие можно отменить через ПКМ)
  row.undo_text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.undo_text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  row.undo_text:SetText("|cFFB04040[X]|r")
  row.undo_text:Hide()

  -- ПКМ по строке -> контекстное меню с отменой ЛЮБОЙ записи.
  -- Поддерживаются: GOLD, GP (индивидуальные), MASS_GOLD, MASS_GP (массовки), DECAY (срез).
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" and self.row_data and self.row_data.entry then
      local entry = self.row_data.entry
      -- Формируем описание записи для меню
      local currency = (entry.type == "GOLD" or entry.type == "MASS_GOLD") and "Gold" or "GP"
      local type_label_str = type_label(entry.type)
      local desc_text
      if entry.type == "DECAY" then
        desc_text = string.format("Срез %s\nПричина: %s", entry.reason or "", entry.reason or "")
      elseif entry.type == "MASS_GOLD" or entry.type == "MASS_GP" then
        desc_text = string.format("Массовка: %s%d %s\nПричина: %s",
          entry.amount > 0 and "+" or "",
          entry.amount, currency, entry.reason or "")
      else
        desc_text = string.format("%s%d %s -> %s\nПричина: %s",
          entry.amount > 0 and "+" or "",
          entry.amount, currency, entry.target or "?", entry.reason or "")
      end

      local menu_items = {
        {
          text = "|cFFFFD700Отменить начисление|r",
          isTitle = true,
          notCheckable = true,
        },
        {
          text = desc_text,
          notCheckable = true,
        },
        {
          text = "|cFFFF5050Отменить|r",
          notCheckable = true,
          func = function()
            if Addon.Award and Addon.Award.UndoEntry then
              local ok = Addon.Award:UndoEntry(entry)
              -- Анонс отмены в гильд-чат
              if ok and Addon.Announce and Addon.Announce.SendCustomMessage then
                local currency = (entry.type == "GOLD" or entry.type == "MASS_GOLD") and "EP" or "GP"
                local undo_msg
                if entry.type == "DECAY" then
                  undo_msg = "Отмена: срез (" .. (entry.reason or "") .. ")"
                elseif entry.type == "MASS_GOLD" or entry.type == "MASS_GP" then
                  undo_msg = string.format("Отмена массовки: '%s' (%s)", entry.reason or "?", currency)
                else
                  undo_msg = string.format("Отмена: %s%d %s '%s' -> %s",
                    entry.amount > 0 and "-" or "+",
                    math.abs(entry.amount or 0),
                    currency,
                    entry.reason or "",
                    entry.target or "?")
                end
                Addon.Announce:SendCustomMessage(undo_msg)
              end
              History:InvalidateFilter()
              History:Refresh()
            end
          end,
        },
      }
      -- Используем UIDropDownMenu
      if not History.menu_frame then
        History.menu_frame = CreateFrame("Frame", "GoldGPHistoryMenu", UIParent, "UIDropDownMenuTemplate")
      end
      EasyMenu(menu_items, History.menu_frame, "cursor", 0, 0, "MENU")
    end
  end)

  -- Hover effects для строки
  row:SetScript("OnEnter", function(self)
    apply_backdrop(self, COLORS.bg_row_hover, COLORS.border_gold, 1)
    if self.row_data and self.row_data.entry then
      self.undo_text:Show()
    end
    if self.row_data and self.row_data.tooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      local tt = self.row_data.tooltip
      if self.undo_text:IsShown() then
        tt = tt .. "\n|cFFB04040ПКМ -> Отменить|r"
      end
      GameTooltip:SetText(tt, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", function(self)
    apply_backdrop(self, COLORS.bg_row, COLORS.border, 1)
    self.undo_text:Hide()
    GameTooltip:Hide()
  end)

  return row
end

-- ============================================================================
-- ОБНОВЛЕНИЕ СТРОК
-- ============================================================================
function History:Refresh()
  if not history_frame or not history_frame:IsShown() then return end

  local entries = get_filtered_entries()
  local total = #entries

  local scroll = history_frame.scroll
  if not scroll then return end

  -- Пустое состояние: после фильтра не осталось записей
  if scroll.empty_state then
    if total == 0 then scroll.empty_state:Show() else scroll.empty_state:Hide() end
  end

  local visible_rows = GetVisibleRows()
  local scroll_offset = FauxScrollFrame_GetOffset(scroll)
  local max_visible = math.min(visible_rows, total - scroll_offset)

  for i = 1, visible_rows do
    local row = rows[i]
    if not row then
      row = create_row(i)
      rows[i] = row
    end

    local idx = i + scroll_offset
    if idx <= total and i <= max_visible then
      local entry = entries[idx]
      self:UpdateRow(row, entry)
      row:Show()
    else
      row:Hide()
    end
  end

  FauxScrollFrame_Update(scroll, total, visible_rows, ROW_HEIGHT)

  -- Статус-бар: количество записей
  local all_count = 0
  if Addon.db and Addon.db.global and Addon.db.global.history then
    all_count = #Addon.db.global.history
  end
  history_frame.status:SetText(string.format("Показано: %d из %d записей", total, all_count))
end

function History:UpdateRow(row, entry)
  row.row_data = { entry = entry }

  -- Время: только дата DD.MM; полное время (дата+время) — в tooltip при
  -- наведении (см. row.row_data.tooltip ниже).
  local date_part = date("%d.%m", entry.time)   -- "DD.MM" (07.06)
  row.time:SetText("|cFFFFD700" .. date_part .. "|r")
  row.time:SetTextColor(1, 1, 1)

  row.type:SetText(type_label(entry.type))
  local tc = type_color(entry.type)
  row.type:SetTextColor(tc.r, tc.g, tc.b)

  row.target:SetText(entry.target or "?")
  row.target:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Защита от nil amount — старые/повреждённые записи в SavedVariables
  local entry_amount = entry.amount or 0
  local amount_str = string.format("%+d", entry_amount)
  row.amount:SetText(amount_str)
  if entry_amount > 0 then
    row.amount:SetTextColor(COLORS.text_success.r, COLORS.text_success.g, COLORS.text_success.b)
  elseif entry_amount < 0 then
    row.amount:SetTextColor(COLORS.text_error.r, COLORS.text_error.g, COLORS.text_error.b)
  else
    row.amount:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
  end

  -- Причина (обрезаем, если слишком длинная)
  local reason = entry.reason or ""
  if #reason > 35 then
    reason = reason:sub(1, 33) .. "…"
  end
  row.reason:SetText(reason)
  row.reason:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  row.officer:SetText(entry.officer or "?")
  row.officer:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Tooltip с полной информацией
  -- Защита от nil в полях entry — старые/повреждённые записи могут иметь nil amount/reason.
  local tt_amount = entry.amount or 0
  local tt_type = type_label(entry.type) or tostring(entry.type or "?")
  local tt_target = entry.target or "?"
  local tt_reason = entry.reason or ""
  local tt_officer = entry.officer or "?"
  local tt_time_str = date("%Y-%m-%d %H:%M:%S", entry.time or 0)
  local tt = string.format("Время: %s\nТип: %s\nИгрок: %s\nСумма: %+d\nПричина: %s\nОфицер: %s",
    tt_time_str, tt_type, tt_target, tt_amount, tt_reason, tt_officer)
  if entry.undo then tt = tt .. "\n|cFFFFAA00(отмена операции)|r" end
  row.row_data.tooltip = tt
end

-- ============================================================================
-- ПОКАЗ/СКРЫТИЕ
-- ============================================================================
function History:Toggle()
  -- Всегда вызываем create_history_frame() — внутри проверяется,
  -- изменилась ли ширина в настройках (тогда фрейм пересоздаётся).
  create_history_frame()
  if history_frame:IsShown() then
    history_frame:Hide()
  else
    -- Позиционируем слева от /gg если оно открыто
    history_frame:ClearAllPoints()
    if GoldGPFrame and GoldGPFrame:IsShown() then
      history_frame:SetPoint("RIGHT", GoldGPFrame, "LEFT", -10, 0)
    else
      history_frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    history_frame:Show()
    history_frame:Raise()
    self:Refresh()
  end
end

function History:Show()
  -- Всегда вызываем create_history_frame() (см. комментарий в Toggle)
  create_history_frame()
  -- Позиционируем слева от /gg если оно открыто
  history_frame:ClearAllPoints()
  if GoldGPFrame and GoldGPFrame:IsShown() then
    history_frame:SetPoint("RIGHT", GoldGPFrame, "LEFT", -10, 0)
  else
    history_frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  history_frame:Show()
  history_frame:Raise()
  self:Refresh()
end

function History:Hide()
  if history_frame then history_frame:Hide() end
end

-- Немедленное применение ширины Журнала из настроек:
-- сбрасывает history_frame — при следующем Show()/Toggle() пересоздастся с новой шириной.
-- Если журнал сейчас открыт — сразу пересоздаёт и показывает.
function History:ApplyWidth(new_width)
  if not history_frame then return end  -- не открыт — ничего не делаем
  -- Уничтожаем старый фрейм, при следующем Toggle()/Show() пересоздастся с новой шириной
  history_frame:Hide()
  history_frame = nil
  wipe(rows)
  -- Сразу пересоздать и показать
  self:Show()
end

function History:Clear()
  if Addon.db and Addon.db.global then
    Addon.db.global.history = {}
    Addon.Log:Info("History cleared")
    self:InvalidateFilter()
    self:Refresh()
  end
end

if Addon.Log then Addon.Log:Info("GoldGP_History loaded") end
