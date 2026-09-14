-- GoldGP_Welcome.lua
-- Окно первого запуска.
-- Показывается ОДИН раз (db.global.welcome_seen) при первом входе в игру:
--   * большая квадратная кнопка «ПРАВИЛА» — открывает окно с правилами гильдии
--     (сейчас текст-заглушка, заменить в RULES_TEXT ниже);
--   * большая квадратная кнопка «ТАБЛИЦА» — открывает стандартную таблицу Gold/GP
--     (весь обычный функционал аддона).
-- Повторный показ: /gg welcome, кнопка «Правила» в тайтлбаре таблицы,
-- /gg rules — сразу окно правил.
-- Окно уважает гильд-лок (Addon:IsEnabled) — при блокировке не показывается.

local Addon = GoldGP
local UIKit = Addon.UIKit
local COLORS = UIKit.COLORS

-- ============================================================================
-- ТЕКСТ ПРАВИЛ (ЗАГЛУШКА — ЗАМЕНИТЬ НА РЕАЛЬНЫЕ ПРАВИЛА ГИЛЬДИИ)
-- ============================================================================
local RULES_TEXT = [[
(Это текст-заглушка — замените его на реальные правила вашей гильдии.
 Текст редактируется в файле GoldGP_Welcome.lua, переменная RULES_TEXT.)

1. ОБЩИЕ ПОЛОЖЕНИЯ
Рейды собираются в календаре за 30 минут до старта. Опоздание без
предупреждения — минус резервное место на следующий рейд.

2. СИСТЕМА GOLD/GP
Все предметы из рейдовых сундуков и с боссов распределяются через
систему Gold/GP (аддон GoldGP). Приоритет = Gold / GP.
   • Gold (EP) — очки, начисляемые за посещение рейдов, выполнение
     заданий гильдии и активную помощь сокланам.
   • GP — стоимость предмета, списывается с игрока при получении лута.
Чем выше ваш приоритет и чем меньше GP — тем выше шанс получить предмет.

3. РАСПРЕДЕЛЕНИЕ ЛУТА
   3.1. Предмет объявляется мастером лутания в окне голосования.
   3.2. Нажмите «ХОЧУ», если предмет вам нужен на текущую спек-сборку.
   3.3. При равных приоритетах решение принимает рейд-лидер.
   3.4. Оффспек-предметы списываются 50% GP и идут в последнюю очередь.

4. ПОСЕЩАЕМОСТЬ И НАКАЗАНИЯ
   4.1. Отсутствие на рейде без предупреждения — штраф 50% Gold.
   4.2. Три пропуска подряд без предупреждения — исключение из резерва.
   4.3. Флаконы и зелья обязательны на прогресс-боссах (проверка /gg flask).

5. ДИСЦИПЛИНА
   5.1. Оскорбления в любом чате — исключение из гильдии.
   5.2. Спорные вопросы решаются с офицерами в привате.
   5.3. Возврат GP за ошибочное начисление — через офицера в течение рейда.

6. КОНТАКТЫ
Старшина гильдии: <имя>. Заместитель: <имя>.
Вопросы по аддону GoldGP: /gg help или /gg config.
]]

-- ============================================================================
-- ЛОКАЛЬНОЕ СОСТОЯНИЕ
-- ============================================================================
local welcome_frame          -- окно выбора (Правила / Таблица)
local rules_frame            -- окно правил
local delay_frame            -- one-shot задержка автопоказа после входа в мир

local function MarkSeen()
  if Addon.db and Addon.db.global then
    Addon.db.global.welcome_seen = true
  end
end

-- ============================================================================
-- ОКНО ПРАВИЛ
-- ============================================================================
local function EnsureRulesFrame()
  if rules_frame then return end

  local f = CreateFrame("Frame", "GoldGPRulesFrame", UIParent)
  f:SetFrameStrata("DIALOG")
  f:SetWidth(620)
  f:SetHeight(460)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()
  UIKit.apply_backdrop(f, COLORS.bg_main, COLORS.border, 2)
  tinsert(UISpecialFrames, "GoldGPRulesFrame")  -- Escape закрывает окно

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", f, "TOP", 0, -16)
  title:SetText("|cFFFFD700Правила гильдии|r")

  -- Кнопка закрытия (X)
  local close_btn = UIKit.create_button(f, "X", 28, 22, function()
    f:Hide()
  end)
  close_btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)

  -- Скролл с текстом правил
  local scroll = CreateFrame("ScrollFrame", "GoldGPRulesScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -46)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -40, 58)

  -- ОБЯЗАТЕЛЬНО: скролл-чайлд должен получить РЕАЛЬНУЮ высоту контента
  -- (body:GetStringHeight()) ДО SetScrollChild — иначе диапазон прокрутки = 0
  -- и текст невиден.
  -- Порядок критичен: контент -> высота чайлда -> SetScrollChild -> UpdateScrollChildRect.
  local child = CreateFrame("Frame", nil, scroll)
  child:SetWidth(556)

  local body = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  body:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -2)
  body:SetWidth(552)
  body:SetJustifyH("LEFT")
  body:SetSpacing(3)
  body:SetText(RULES_TEXT)

  child:SetHeight(body:GetStringHeight() + 8)
  scroll:SetScrollChild(child)
  scroll:UpdateScrollChildRect()

  -- Ссылки для FitRulesFrameToContent (правила могут заменить заглушку
  -- на длинный реальный текст — окно растянется под контент при показе)
  f.scroll = scroll
  f.body = body

  -- Нижняя кнопка «Открыть таблицу»
  local open_table_btn = UIKit.create_button(f, "Открыть таблицу", 180, 28, function()
    f:Hide()
    if Addon.UI and Addon.UI.Show then
      Addon.UI:Show()
    end
  end)
  open_table_btn:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)

  rules_frame = f
end

-- Высота окна правил подстраивается под контент (текст может вырасти
-- после замены заглушки на реальные правила) — но не выше 80% высоты экрана.
local function FitRulesFrameToContent()
  if not rules_frame or not rules_frame.body then return end
  local scroll = rules_frame.scroll
  local content_h = rules_frame.body:GetStringHeight() + 8
  local min_h = 460
  local screen_h = GetScreenHeight() or 768
  local max_h = math.floor(screen_h * 0.8)
  -- 46px (шапка) + контент + 58px (низ скролла) + 16px (запас под кнопку)
  local need_h = 46 + content_h + 58 + 16
  if need_h < min_h then need_h = min_h end
  if need_h > max_h then need_h = max_h end
  if math.abs((rules_frame:GetHeight() or 0) - need_h) > 2 then
    rules_frame:SetHeight(need_h)
  end
  if scroll then scroll:UpdateScrollChildRect() end
end

local function ShowRules()
  EnsureRulesFrame()
  FitRulesFrameToContent()
  rules_frame:Show()
  rules_frame:Raise()
end

-- ============================================================================
-- ОКНО ВЫБОРА (Правила / Таблица)
-- ============================================================================
local function MakeBigButton(parent, label, caption, x_offset, onclick)
  local btn = UIKit.create_button(parent, label, 180, 180, nil)
  btn:SetPoint("TOP", parent, "TOP", x_offset, -140)
  -- Крупный текст по центру + мелкая подпись снизу
  btn.text:ClearAllPoints()
  btn.text:SetPoint("CENTER", btn, "CENTER", 0, 22)
  if btn.text.SetFontObject then
    btn.text:SetFontObject("GameFontNormalLarge")
  end
  btn.text:SetText(label)
  local sub = btn:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  sub:SetPoint("BOTTOM", btn, "BOTTOM", 0, 14)
  sub:SetText(caption)
  if onclick then
    btn:SetScript("OnClick", onclick)
  end
  return btn
end

local function EnsureWelcomeFrame()
  if welcome_frame then return end

  local f = CreateFrame("Frame", "GoldGPWelcomeFrame", UIParent)
  f:SetFrameStrata("DIALOG")
  f:SetWidth(540)
  f:SetHeight(380)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()
  UIKit.apply_backdrop(f, COLORS.bg_main, COLORS.border, 2)
  tinsert(UISpecialFrames, "GoldGPWelcomeFrame")  -- Escape закрывает окно

  -- OnHide welcome-фрейма = MarkSeen: закрытие ЛЮБЫМ способом (в т.ч. Escape)
  -- считается «увиденным» — автопоказ не повторится.
  -- OnHide срабатывает и при переходе ПРАВИЛА → ShowRules — это ок (идемпотентно).
  f:SetScript("OnHide", MarkSeen)

  -- Заголовок в стиле аддона: |cFFFFD700Gold|r|cFFAAAAAAGP|r
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", f, "TOP", 0, -18)
  title:SetText("|cFFFFD700Gold|r|cFFAAAAAAGP|r — добро пожаловать!")

  local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
  f.subtitle = subtitle  -- текст зависит от того, первое это открытие или повторное

  -- Две большие квадратные кнопки
  local rules_btn = MakeBigButton(f, "ПРАВИЛА", "Правила гильдии", -110, function()
    MarkSeen()
    f:Hide()
    ShowRules()
    PlaySound("igMainMenuOptionCheckBoxOn")
  end)

  local table_btn = MakeBigButton(f, "ТАБЛИЦА", "Таблица Gold / GP", 110, function()
    MarkSeen()
    f:Hide()
    if Addon.UI and Addon.UI.Show then
      Addon.UI:Show()
    end
    PlaySound("igMainMenuOptionCheckBoxOn")
  end)

  -- Подсказка внизу
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
  hint:SetText("Автопоказ — один раз.  Повтор: /gg welcome или кнопка «Правила» в таблице")

  welcome_frame = f
end

-- ============================================================================
-- ПУБЛИЧНЫЙ API
-- ============================================================================
local Welcome = {}

-- ShowRules() — прямой API окна правил (кнопка «Правила» в таблице, /gg rules):
-- открывает СРАЗУ правила. Гейта гильд-лока НЕТ осознанно — правила полезно
-- читать и вне разрешённой гильдии (новобранец до гильд-привязки, проверка
-- перед вступлением). /gg rules включён в whitelist гильд-лока в Slash.lua.
function Welcome:ShowRules()
  ShowRules()
end

-- force=true игнорирует welcome_seen (команда /gg welcome, кнопка «Правила» в тайтлбаре)
function Welcome:Show(force)
  -- Гильд-лок: вне разрешённой гильдии окно не показываем
  if Addon.IsEnabled and not Addon:IsEnabled() then
    Addon.PrintError("GoldGP заблокирован гильд-локом — аддон работает только в разрешённой гильдии")
    return
  end
  if not Addon.db then
    -- БД ещё не готова (ADDON_LOADED не отработал) — молча выходим,
    -- автопоказ повторится на следующем PLAYER_ENTERING_WORLD
    return
  end
  if not force and Addon.db.global.welcome_seen then
    return
  end
  EnsureWelcomeFrame()
  -- При повторном открытии (кнопка «Правила» в таблице / /gg welcome)
  -- подзаголовок «запустили впервые» вводил бы в заблуждение
  if welcome_frame.subtitle then
    welcome_frame.subtitle:SetText(Addon.db.global.welcome_seen
      and "Выберите раздел:"
      or "Похоже, вы запустили аддон впервые.\nВыберите раздел:")
  end
  welcome_frame:Show()
  welcome_frame:Raise()
end

Addon.Welcome = Welcome

-- ============================================================================
-- АВТОПОКАЗ ПРИ ПЕРВОМ ЗАПУСКЕ
-- ============================================================================
local trigger = CreateFrame("Frame")
trigger:RegisterEvent("PLAYER_ENTERING_WORLD")
trigger:SetScript("OnEvent", function()
  if not Addon.db or not Addon.db.global then return end
  if Addon.db.global.welcome_seen then return end
  -- Задаём задержку 2 сек: даём прогрузиться UI и чату после входа в мир.
  -- Один переиспользуемый hidden-frame — без утечек фреймов.
  if not delay_frame then
    delay_frame = CreateFrame("Frame")
    delay_frame:Hide()
    delay_frame.elapsed = 0
    delay_frame:SetScript("OnUpdate", function(df, elapsed)
      df.elapsed = (df.elapsed or 0) + elapsed
      if df.elapsed >= 2.0 then
        df.elapsed = 0
        df:Hide()
        Welcome:Show()
      end
    end)
  end
  delay_frame.elapsed = 0
  delay_frame:Show()
end)

if Addon.Log then
  Addon.Log:Info("GoldGP_Welcome loaded (v2.7.1)")
end
