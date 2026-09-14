-- GoldGP_Dialog.lua

local Addon = GoldGP
local Dialog = {}
Addon.Dialog = Dialog

-- UIKit загружается раньше в .toc — fallbacks не нужны.
local UIKit = Addon.UIKit
local COLORS = UIKit.COLORS

local apply_backdrop = UIKit.apply_backdrop
local style_editbox = UIKit.style_editbox

-- Единая функция кнопки из UIKit
local make_button = UIKit.create_button

-- ============================================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ДЛЯ ДИАЛОГОВ
-- ============================================================================
-- Все диалоги всегда справа от /gg + авто-закрытие других

-- Список всех диалоговых фреймов (для авто-закрытия)
local all_dialog_frames = {}

-- Позиционирует фрейм справа от главного окна GoldGPFrame
local function position_dialog_right(f)
  f:ClearAllPoints()
  if GoldGPFrame and GoldGPFrame:IsShown() then
    f:SetPoint("LEFT", GoldGPFrame, "RIGHT", 10, 0)
  else
    -- Главное окно скрыто — центр экрана
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

-- Закрывает все диалоги кроме текущего
local function close_other_dialogs(except_frame)
  for _, dlg in ipairs(all_dialog_frames) do
    if dlg ~= except_frame and dlg:IsShown() then
      dlg:Hide()
    end
  end
  -- Также закрываем окно журнала если открыто
  if Addon.History and Addon.History.Hide then
    Addon.History:Hide()
  end
end

-- Регистрирует диалог в списке (вызывается после создания)
local function register_dialog(f)
  tinsert(all_dialog_frames, f)
end

-- ============================================================================
-- 1. ДИАЛОГ НАЧИСЛЕНИЯ ИГРОКУ
-- ============================================================================
local award_player_frame
local award_player_state = { name = nil, type = "gold" }

-- Создаёт фрейм ОДИН раз при первом открытии, потом переиспользуется
local function create_award_player_frame()
  if award_player_frame then return award_player_frame end

  local f = CreateFrame("Frame", "GoldGPAwardPlayerDialog", UIParent)
  f:SetSize(340, 240)
  -- Позиция: справа от главного окна GoldGP, на одном уровне по вертикали
  -- SetPoint делается динамически в ShowAwardPlayer — чтобы следовать за главным окном
  apply_backdrop(f, COLORS.bg_main, COLORS.border, 2)
  -- ВАЖНО: FULLSCREEN_DIALOG — выше чем DIALOG у главного окна, чтобы не перекрываться
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetFrameLevel(10)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  f:Hide()

  -- При скрытии — очистить фокус EditBox
  f:SetScript("OnHide", function(self)
    if self.amount_box then self.amount_box:ClearFocus() end
    if self.reason_box then self.reason_box:ClearFocus() end
  end)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", f, "TOP", 0, -10)
  f.title:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Текущие значения
  f.cur_text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.cur_text:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
  f.cur_text:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Тип начисления
  f.type_label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.type_label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -75)
  f.type_label:SetText("Тип:")
  f.type_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- ASCII-глифы (>>, -) вместо Unicode: шрифт WoW 3.3.5a показывает
  -- Unicode-символы (OK, U+2212) как «?» или пустой квадрат
  local GOLD_ACTIVE_BG = UIKit.ACTIVE_BG
  local GOLD_ACTIVE_BORDER = UIKit.ACTIVE_BORDER
  local INACTIVE_BG = UIKit.INACTIVE_BG
  local INACTIVE_BORDER = UIKit.INACTIVE_BORDER

  local function update_type_buttons()
    -- is_active flag — активная кнопка не реагирует на hover/leave/down/up.
    f.gold_btn.is_active = (award_player_state.type == "gold")
    f.gp_btn.is_active   = (award_player_state.type == "gp")

    if award_player_state.type == "gold" then
      apply_backdrop(f.gold_btn, GOLD_ACTIVE_BG, GOLD_ACTIVE_BORDER, 3)
      f.gold_btn.text:SetTextColor(1.00, 0.84, 0.00)
      f.gold_btn.text:SetText(">> EP")
      apply_backdrop(f.gp_btn, INACTIVE_BG, INACTIVE_BORDER, 1)
      f.gp_btn.text:SetTextColor(0.45, 0.45, 0.45)
      f.gp_btn.text:SetText("GP")
    else
      apply_backdrop(f.gp_btn, GOLD_ACTIVE_BG, GOLD_ACTIVE_BORDER, 3)
      f.gp_btn.text:SetTextColor(1.00, 0.84, 0.00)
      f.gp_btn.text:SetText(">> GP")
      apply_backdrop(f.gold_btn, INACTIVE_BG, INACTIVE_BORDER, 1)
      f.gold_btn.text:SetTextColor(0.45, 0.45, 0.45)
      f.gold_btn.text:SetText("EP")
    end
  end

  f.gold_btn = make_button(f, "EP", 80, 24, function()
    award_player_state.type = "gold"
    update_type_buttons()
  end)
  f.gold_btn:SetPoint("LEFT", f.type_label, "RIGHT", 12, 0)

  f.gp_btn = make_button(f, "GP", 80, 24, function()
    award_player_state.type = "gp"
    update_type_buttons()
  end)
  f.gp_btn:SetPoint("LEFT", f.gold_btn, "RIGHT", 6, 0)

  -- Сохраняем функцию для вызова при открытии диалога
  f.update_type_buttons = update_type_buttons

  f.amount_label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.amount_label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -110)
  f.amount_label:SetText("Количество:")
  f.amount_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  f.amount_box = CreateFrame("EditBox", "GoldGPDialogPlayerAmt", f, "InputBoxTemplate")
  style_editbox(f.amount_box)
  f.amount_box:SetSize(100, 22)
  f.amount_box:SetPoint("LEFT", f.amount_label, "RIGHT", 12, 0)
  f.amount_box:SetAutoFocus(false)
  -- НЕ SetNumeric: он блокирует ввод минуса — нужны отрицательные числа
  f.amount_box:SetMaxLetters(7)  -- до -99999
  f.amount_box:SetText("100")
  -- Оставляем только цифры и один минус в начале
  f.amount_box:SetScript("OnTextChanged", function(self, isUserInput)
    if not isUserInput then return end  -- программное изменение — не трогаем
    local text = self:GetText()
    local cleaned = text:gsub("[^0-9-]", "")
    if cleaned:sub(1, 1) == "-" then
      local rest = cleaned:sub(2):gsub("-", "")
      cleaned = "-" .. rest
    else
      cleaned = cleaned:gsub("-", "")
    end
    if cleaned ~= text then
      self:SetText(cleaned)
      self:SetCursorPosition(#cleaned)
    end
  end)

  -- Кнопки "+" и "-" для быстрого изменения знака
  -- ИСПОЛЬЗУЕМ ASCII ДЕФИС (U+002D) вместо Unicode минуса (U+2212)
  -- Причина: стандартный шрифт WoW 3.3.5a (Friz Quadrata) не содержит U+2212,
  -- поэтому Unicode минус отображается как "?" или пустой квадрат.
  f.minus_btn = make_button(f, "-", 30, 22, function()
    local val = tonumber(f.amount_box:GetText()) or 0
    f.amount_box:SetText(tostring(-math.abs(val)))
  end)
  f.minus_btn:SetPoint("LEFT", f.amount_box, "RIGHT", 4, 0)

  f.plus_btn = make_button(f, "+", 30, 22, function()
    local val = tonumber(f.amount_box:GetText()) or 0
    f.amount_box:SetText(tostring(math.abs(val)))
  end)
  f.plus_btn:SetPoint("LEFT", f.minus_btn, "RIGHT", 4, 0)

  f.reason_label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.reason_label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -145)
  f.reason_label:SetText("Причина:")
  f.reason_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  f.reason_box = CreateFrame("EditBox", "GoldGPDialogPlayerReason", f, "InputBoxTemplate")
  style_editbox(f.reason_box)
  f.reason_box:SetSize(200, 22)
  f.reason_box:SetPoint("LEFT", f.reason_label, "RIGHT", 12, 0)
  f.reason_box:SetAutoFocus(false)
  f.reason_box:SetText("Босс убит")

  f.cancel_btn = make_button(f, "Отмена", 90, 26, function()
    f:Hide()
  end)
  f.cancel_btn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)

  f.award_btn = make_button(f, "Начислить", 110, 26, function()
    local amount = tonumber(f.amount_box:GetText()) or 0
    local reason = f.reason_box:GetText() or ""
    if amount == 0 or reason == "" then
      Addon.PrintError("Укажите количество и причину!")
      return
    end
    local target_name = award_player_state.name
    if not target_name then
      Addon.PrintError("Игрок не выбран!")
      f:Hide()
      return
    end
    if award_player_state.type == "gold" then
      Addon.Award:IncGold(target_name, reason, amount, false)
    else
      Addon.Award:IncGP(target_name, reason, amount, false)
    end
    f:Hide()
  end)
  f.award_btn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)

  -- Регистрируем ОДИН раз — чтобы Escape закрывал окно
  tinsert(UISpecialFrames, "GoldGPAwardPlayerDialog")

  award_player_frame = f
  register_dialog(f)
  return f
end

function Dialog:ShowAwardPlayer(name, award_type)
  local f = create_award_player_frame()
  award_player_state.name = name
  -- Тип можно задать при открытии (gold/gp)
  award_player_state.type = award_type or "gold"

  f.title:SetText("|cFFFFD700Начисление:|r " .. name)

  local gold, gp, main = Addon:GetMemberData(name)
  if gold then
    f.cur_text:SetText(string.format("Сейчас: |cFFFFD700%d EP|r | %d GP | PR=%.2f",
      gold, gp or 0, (gp and gp > 0) and gold / gp or 0))
  else
    f.cur_text:SetText("|cFFFF5050Нет данных (невалидная оффнота?)|r")
  end

  -- Обновить визуальное выделение кнопок Gold/GP
  -- Инициализируем is_active флаги перед update_type_buttons
  if f.gold_btn then f.gold_btn.is_active = (award_player_state.type == "gold") end
  if f.gp_btn then f.gp_btn.is_active = (award_player_state.type == "gp") end
  if f.update_type_buttons then
    f.update_type_buttons()
  end

  f.amount_box:SetText("100")
  f.reason_box:SetText("Босс убит")
  f.amount_box:ClearFocus()
  f.reason_box:ClearFocus()

  -- Позиционируем справа от /gg + закрываем другие диалоги
  close_other_dialogs(f)
  position_dialog_right(f)

  f:Show()
  f:Raise()
end

-- ============================================================================
-- 2. ДИАЛОГ МАССОВОГО НАЧИСЛЕНИЯ
-- ============================================================================
local mass_award_frame

local function create_mass_award_frame()
  if mass_award_frame then return mass_award_frame end

  local f = CreateFrame("Frame", "GoldGPMassAwardDialog", UIParent)
  f:SetSize(420, 370)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  apply_backdrop(f, COLORS.bg_main, COLORS.border, 2)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:Hide()

  f:SetScript("OnHide", function(self)
    if self.amount_box then self.amount_box:ClearFocus() end
    if self.reason_box then self.reason_box:ClearFocus() end
  end)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", f, "TOP", 0, -10)
  f.title:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Информация о целях
  f.info_text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.info_text:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
  f.info_text:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- Party-split плашка
  f.split_text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.split_text:SetPoint("TOP", f.info_text, "BOTTOM", 0, -6)
  f.split_text:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  f.amount_label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.amount_label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -85)
  f.amount_label:SetText("Количество:")
  f.amount_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  f.amount_box = CreateFrame("EditBox", "GoldGPDialogMassAmt", f, "InputBoxTemplate")
  style_editbox(f.amount_box)
  f.amount_box:SetSize(100, 22)
  f.amount_box:SetPoint("LEFT", f.amount_label, "RIGHT", 12, 0)
  f.amount_box:SetAutoFocus(false)
  -- НЕ SetNumeric — нужна поддержка минуса (отрицательные суммы)
  f.amount_box:SetMaxLetters(7)
  f.amount_box:SetText("100")
  f.amount_box:SetScript("OnTextChanged", function(self, isUserInput)
    if not isUserInput then return end
    local text = self:GetText()
    local cleaned = text:gsub("[^0-9-]", "")
    if cleaned:sub(1, 1) == "-" then
      local rest = cleaned:sub(2):gsub("-", "")
      cleaned = "-" .. rest
    else
      cleaned = cleaned:gsub("-", "")
    end
    if cleaned ~= text then
      self:SetText(cleaned)
      self:SetCursorPosition(#cleaned)
    end
  end)

  f.minus_btn = make_button(f, "-", 30, 22, function()
    local val = tonumber(f.amount_box:GetText()) or 0
    f.amount_box:SetText(tostring(-math.abs(val)))
  end)
  f.minus_btn:SetPoint("LEFT", f.amount_box, "RIGHT", 4, 0)

  f.plus_btn = make_button(f, "+", 30, 22, function()
    local val = tonumber(f.amount_box:GetText()) or 0
    f.amount_box:SetText(tostring(math.abs(val)))
  end)
  f.plus_btn:SetPoint("LEFT", f.minus_btn, "RIGHT", 4, 0)

  f.reason_label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.reason_label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -120)
  f.reason_label:SetText("Причина:")
  f.reason_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  f.reason_box = CreateFrame("EditBox", "GoldGPDialogMassReason", f, "InputBoxTemplate")
  style_editbox(f.reason_box)
  f.reason_box:SetSize(220, 22)
  f.reason_box:SetPoint("LEFT", f.reason_label, "RIGHT", 12, 0)
  f.reason_box:SetAutoFocus(false)
  f.reason_box:SetText("Босс убит")

  -- Quick reasons — ШАБЛОНЫ с предустановленными суммами
  -- Формат: { label = "Приход на рт", reason = "Приход на рт", amount = 600 }
  f.quick_label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.quick_label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -155)
  f.quick_label:SetText("Шаблоны (клик - заполнить):")
  f.quick_label:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- 3 шаблона: 2 в первом ряду, 1 во втором (для лучшего визуала)
  local templates = {
    { label = "Приход на рт (600)",   reason = "Приход на рт",  amount = 600 },
    { label = "Конец Рт (10000)",     reason = "Конец Рт",      amount = 10000 },
    { label = "Фк Босс (10000)",      reason = "Фк Босс",       amount = 10000 },
  }
  for i, t in ipairs(templates) do
    local btn = make_button(f, t.label, 140, 24, function()
      f.reason_box:SetText(t.reason)
      f.amount_box:SetText(tostring(t.amount))
    end)
    if i == 1 then
      btn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -175)
    elseif i == 2 then
      btn:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + 150, -175)
    else
      btn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -205)
    end
  end

  f.cancel_btn = make_button(f, "Отмена", 90, 26, function() f:Hide() end)
  f.cancel_btn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)

  f.award_btn = make_button(f, "Начислить всем", 130, 26, function()
    local amount = tonumber(f.amount_box:GetText()) or 0
    local reason = f.reason_box:GetText() or ""
    if amount == 0 or reason == "" then
      Addon.PrintError("Укажите количество и причину!")
      return
    end
    -- Массовка работает только для Gold (GP начисляется индивидуально
    -- через диалог AwardPlayer).
    Addon.Award:MassGold(reason, amount)
    f:Hide()
  end)
  f.award_btn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)

  tinsert(UISpecialFrames, "GoldGPMassAwardDialog")
  mass_award_frame = f
  register_dialog(f)
  return f
end

function Dialog:ShowMassAward()
  local f = create_mass_award_frame()

  local title_text = "Массовое начисление EP"
  f.title:SetText("|cFFFFD700" .. title_text .. "|r")

  -- ВАЖНО: вне рейда IsInAwardList возвращает true для ВСЕЙ гильдии — офицер
  -- может случайно раздать EP всем; получатели всегда показаны явно.
  local target_count = Addon:GetNumMembersInAwardList()
  if Addon.state.in_raid then
    f.info_text:SetText(string.format("Получатели: рейд + замены (%d) | В рейде: %d",
      target_count, GetNumRaidMembers()))
  else
    f.info_text:SetText(string.format("|cFFFF5050Получатели: ВСЕ члены гильдии (%d)|r  |  Не в рейде",
      target_count))
  end

  if Addon.db.profile.party_split_enabled then
    local threshold = Addon.db.profile.party_split_threshold or 5
    local pct = Addon.db.profile.party_split_percent or 50
    local full_count, reduced_count = 0, 0
    for n in pairs(Addon.state.raid_members) do
      local sg = Addon.state.raid_subgroups[n]
      if sg and sg > 0 then
        if sg <= threshold then full_count = full_count + 1
        else reduced_count = reduced_count + 1 end
      end
    end
    f.split_text:SetText(string.format(
      "|cFF30AA30P1-%d: 100%% (%d иг.)|r  |  |cFFF0A000P%d-8: %d%% (%d иг.)|r",
      threshold, full_count, threshold + 1, pct, reduced_count
    ))
    f.split_text:Show()
  else
    f.split_text:Hide()
  end

  f.amount_box:SetText("100")
  f.reason_box:SetText("Босс убит")
  f.amount_box:ClearFocus()
  f.reason_box:ClearFocus()

  -- Позиционируем справа от /gg + закрываем другие диалоги
  close_other_dialogs(f)
  position_dialog_right(f)

  f:Show()
  f:Raise()
end

-- ============================================================================
-- 3. ДИАЛОГ НАСТРОЙКИ RECURRING
-- ============================================================================
local recurring_frame

local function create_recurring_frame()
  if recurring_frame then return recurring_frame end

  -- Упрощённый диалог — фиксированные 600 Gold каждые 10 минут.
  -- Только кнопки "Старт" и "Отмена". Никаких полей ввода.
  local f = CreateFrame("Frame", "GoldGPRecurringDialog", UIParent)
  f:SetSize(300, 160)
  apply_backdrop(f, COLORS.bg_main, COLORS.border, 2)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetFrameLevel(10)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:Hide()

  -- Заголовок
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", f, "TOP", 0, -16)
  f.title:SetText("|cFFFFD700Рт по таймеру|r")
  f.title:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Информация о параметрах (фиксированных)
  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.info:SetPoint("TOP", f.title, "BOTTOM", 0, -16)
  f.info:SetText("|cFFFFD700+600 EP|r каждые |cFFFFD70010 минут|r")
  f.info:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

  -- Причина (фиксированная)
  f.reason = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.reason:SetPoint("TOP", f.info, "BOTTOM", 0, -8)
  f.reason:SetText("Причина: 'Рт по таймеру'")
  f.reason:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  f.cancel_btn = make_button(f, "Отмена", 120, 28, function() f:Hide() end)
  f.cancel_btn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 16)

  f.start_btn = make_button(f, "Старт", 120, 28, function()
    -- Фиксированные параметры: 600 Gold, 10 мин, "Рт по таймеру"
    Addon.db.profile.recurring_period_mins = 10
    Addon.Award:StartRecurring("Рт по таймеру", 600)
    Addon.Print("Рт по таймеру старт: +600 EP каждые 10 мин")
    f:Hide()
  end)
  f.start_btn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 16)

  tinsert(UISpecialFrames, "GoldGPRecurringDialog")
  recurring_frame = f
  register_dialog(f)
  return f
end

function Dialog:ShowRecurringSetup()
  local f = create_recurring_frame()

  -- Позиционируем справа от /gg + закрываем другие диалоги
  close_other_dialogs(f)
  position_dialog_right(f)

  f:Show()
  f:Raise()
end

if Addon.Log then Addon.Log:Info("GoldGP_Dialog loaded") end
