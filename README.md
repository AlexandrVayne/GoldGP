# GoldGP — современная замена EPGP для sirus.su (WoW 3.3.5a)

**Версия:** 2.8.6 + LootMaster v0.7.4 + Flask v0.1.2
**Interface:** 30300 (Wrath of the Lich King 3.3.5a)
**Сервер:** sirus.su
**Гильдия:** MadTeaParty

> Полная история изменений: [`CHANGELOG.md`](CHANGELOG.md)
> Контекст проекта для будущих правок (в т.ч. для ИИ-ассистентов): [`docs/PROJECT_MEMORY.md`](docs/PROJECT_MEMORY.md)
> План релиза и статус фаз: [`docs/RELEASE_PLAN.md`](docs/RELEASE_PLAN.md)

---

## Что это

GoldGP — это переработанный аддон EPGP с тёмным современным UI, исправленным критическим багом pending_note, системой посещаемости через public note + GuildInfo, проверкой настоев, окном настроек и LootMaster для распределения лута.

## Главные отличия от EPGP 5.5.15

| Характеристика | EPGP 5.5.15 | GoldGP 2.5.6 |
|----------------|-------------|---------------|
| Всего строк Lua | 42 840 | 13 460 |
| Библиотеки | 17 446 (14 Ace3 либ) | 290 (только CTL) |
| Зависимости | Ace3 (полный стек) | Нет (чистый Blizzard API) |
| Память при загрузке | ~2-3 MB | ~200-300 KB |
| Время загрузки | ~50-80мс | ~5-10мс |
| Очередь pending_note | 1 значение (баг!) | Список до 3 значений |
| Посещаемость | Локально (SavedVariables) | Сервер (public note + GuildInfo) |
| Standby sync | Нет | STANDBY_SET/DEL broadcast |
| LootMaster anti-spoofing | Нет | sender == mlName проверка |
| LootMaster crash recovery | Нет | PersistLootTable в SavedVariables |
| Protocol versioning | Нет | V1^ префикс |
| Party-split | Нет | P1-5=100%, P6-8=X% |
| Flask check | Нет | С GP штрафом |
| Рандомизация GuildRoster | Нет | 0.5-2.5 сек (для 40+ игроков) |

## Архитектура

### Хранение данных
- **EP/GP:** Officer Notes (сервер) — формат `"Gold,GP"` (например `"1000,500"`)
- **Посещаемость X:** Public Notes — формат `"спек (N)"` (например `"ретрик (5)"`)
- **Посещаемость Y:** Guild Info — `@ATT_TOTAL:N`
- **Standby:** `db.global.standby_list` (SavedVariables) + STANDBY_SET/DEL broadcast
- **Лог/История:** `db.global.log` / `db.global.history` (SavedVariables, макс 5000)

### Синхронизация
- **EP/GP/Посещаемость:** через `GUILD_ROSTER_UPDATE` (естественная, как EP/GP)
- **Сигналы:** `SendAddonMessage("GoldGP", ...)` в канал GUILD
  - `CHANGES_PENDING` — офицер начал запись
  - `CHANGES_FLUSHED` — офицер закончил, обновите кэш
  - `STANDBY_SET|name` / `STANDBY_DEL|name` — sync замен
- **LootMaster:** `SendAddonMessage("GoldGPLM"/"GoldGPLM_R", ...)` в RAID/PARTY/WHISPER
  - Все сообщения с префиксом `V1^` (version byte)
  - Anti-spoofing: проверка `sender == LM.state.mlName`
  - `ChatThrottleLib` для очереди сообщений

### Оптимизация
- **Storage State Machine:** CURRENT → STALE → FLUSHING → CURRENT
- **Batch processing:** 100 членов гильдии за кадр (не фризит UI)
- **standings_cache с сигнатурой:** O(1) проверка нужно ли пересчитывать
- **Table pool:** popTable/pushTable в LootMaster (меньше GC pressure)
- **Рандомизация GuildRoster():** офицеры 0.5с, не-офицеры 1.0-2.5с (рандом)
- **RegisterAddonMessagePrefix в pcall:** защита от краша при загрузке
- **PrintError в начале файла:** доступен даже при краше Core.lua

## Установка

**Вариант 1 — архив:**
1. Распакуйте архив в папку `<WoW>\Interface\AddOns\` (должны получиться папки `GoldGP`, `GoldGP_LootMaster`, `GoldGP_Flask`)
2. Перезапустите клиент WoW
3. Введите `/gg` для открытия окна

**Вариант 2 — прямо из git (обновление одной командой):**
```bash
git clone https://github.com/<ВАШ_НИК>/GoldGP.git "<WoW>\Interface\AddOns"
```
> Клонируйте в ПУСТУЮ папку AddOns. Обновление после рейда: `git pull` внутри этой папки.

**Пакет для офицеров:** аддон `GoldGP_Flask` ставится ОТДЕЛЬНО и требует ядро `GoldGP`
(жёсткая зависимость). При его наличии:
- в тулбаре окна /gg появляется кнопка «Фласки»;
- в ESC → Интерфейс → Аддоны появляется своя категория «GoldGP Фласки» с вкладкой «Настои»;
- диспетчер `/gg flask` начинает работать.

**Миграция настроек (одноразовая):** при первом запуске GoldGP_Flask сам переносит из
старого места (`GoldGPDB.global.flask_ids` + `GoldGPDB.profiles[гильдия].flask_gp_amount`)
в свою БД `GoldGPFlaskDB` и обнуляет старые поля. Повторные входы миграцию не повторяют
(флаг `migrated`).

## Настройка GuildInfo

```
-GGP-
@DECAY_P:20
@EXTRAS_P:100
@MIN_GOLD:5000
@BASE_GP:1
@ATT_TOTAL:0
-GGP-
```

## Слэш-команды

| Команда | Описание |
|---------|----------|
| `/gg` | Открыть/закрыть главное окно |
| `/gg setguild [имя\|clear]` | **v2.6.0** гильд-лок: без арг. = текущая гильдия, clear = снять |
| `/gg welcome` | **v2.6.0** окно первого запуска (ПРАВИЛА / ТАБЛИЦА) |
| `/gg rules` | **v2.7.1** сразу открыть окно правил гильдии (v2.8.0: работает и вне гильд-лока) |
| `/gg classdiag` | **v2.8.2** диагностика иконок классов: печатает RAW строки классов из ростера с результатом маппинга (вывод — отправить разработчику); v2.8.3: показывает и игроков без строки класса |
| `/gg flask` | **v2.8.0** проверка настоев — только при установленном GoldGP_Flask |
| `/gg mass <amount> <reason>` | Массовое начисление EP |
| `/gg gold <name> <amount> [reason]` | Начислить EP игроку |
| `/gg gp <name> <amount> [reason]` | Начислить GP игроку |
| `/gg decay` | Применить срез |
| `/gg reset` | Сбросить все EP/GP |
| `/gg recurring <amount> <reason>` | Рт по таймеру |
| `/gg recurring stop` | Стоп таймер |
| `/gg standby <name>` | Добавить на замену (v2.8.1: только офицер + лидер рейда) |
| `/gg standby list` | Список замен |
| `/gg standby clear` | Очистить список замен (v2.8.1: только офицер + лидер рейда) |
| `/gg history` | Открыть журнал |
| `/gg state` | Состояние Storage |
| `/gg help` | Помощь |

## Гильд-лок (v2.6.0)

Аддон работает ТОЛЬКО у членов заданной гильдии:
- Константа `Addon.REQUIRED_GUILD_NAME` в начале `GoldGP_Core.lua` (пусто = любая гильдия, но не «без гильдии»);
- Или `/gg setguild` (запись в `db.global.required_guild` — приоритет над константой);
- Пока лок активен: UI не открывается, начисления/синхронизация/команды отключены;
- Вступил в гильдию прямо в сессии — `GUILD_ROSTER_UPDATE`/`PLAYER_GUILD_UPDATE` автоматически снимает лок и доинициализирует аддон (`DoWorldInit`), перезаход не нужен.

## Офицерские функции (v2.8.1)

Ключ «офицер» = право редактирования офицерских заметок (`CanEditOfficerNote`,
галка в звании на панели управления гильдией):
- **«Замены» (standby) — полностью офицерская функция:** кнопка в тулбаре,
  окно списка, `/gg standby`-мутации, шепот-самозапись. Не-офицеры кнопку НЕ
  видят, окно открыть не могут, шепот «замена» у них не обрабатывается;
- **Настройки LootMaster и Фласков видны ВСЕМ, содержимое — офицерам**
  (категория больше не может «исчезнуть»; у не-офицеров кнопки скрыты с пояснением);
- **Кнопка «Фласки»** в тулбаре = наличие модуля GoldGP_Flask + офицер;
  если модуль включён, а кнопки нет — при открытии таблицы будет разовая
  подсказка с причиной (отключён аддон / ошибка Lua в модуле).

## Окно первого запуска (v2.6.0, GoldGP_Welcome.lua)

- Показывается ОДИН раз (`db.global.welcome_seen`) через 2 сек после первого входа в мир;
- Две большие квадратные кнопки: «ПРАВИЛА» (окно правил — текст-заглушка в `RULES_TEXT`, заменить) и «ТАБЛИЦА» (стандартное окно);
- v2.8.0: закрытие ЛЮБЫМ способом (включая Escape) помечает welcome_seen —
  автопоказ больше не повторяется на следующем входе;
- Повторный показ: `/gg welcome` (окно выбора);
- v2.8.0: кнопка «Правила» в тайтлбаре таблицы открывает СРАЗУ окно правил
  (`Welcome:ShowRules`), а не окно выбора; окно правил доступно и ВНЕ гильд-лока;
- Правила также доступны из окна правил кнопкой «Открыть таблицу»;
- v2.7.1: текст правил виден (скролл-чайлд получает высоту из GetStringHeight), окно правил
  само подстраивает высоту под объём текста (460px..80% экрана).

## Структура репозитория

```
GoldGP/                ← корень = прямо в Interface\AddOns\
├── GoldGP/            ядро (12 файлов)
├── GoldGP_LootMaster/ мастер-лут (5 файлов, вкл. ChatThrottleLib)
├── GoldGP_Flask/      проверка настоев (3 файла, для офицеров)
├── CHANGELOG.md       история изменений по версиям
└── docs/
    ├── PROJECT_MEMORY.md    память проекта (инварианты, баги, решения) — читать перед любыми правками
    ├── RELEASE_PLAN.md      план релиза, статус фаз
    └── UI_VISUAL_AUDIT.md   аудит UI
```

## Файлы (12 GoldGP + 5 LootMaster + 3 Flask)

| Файл | Назначение |
|------|------------|
| GoldGP_Core.lua | InitDB, события, attendance, state, гильд-лок, standby-сессии, snapshot-таймаут (v2.8.0), PrintError/Print |
| GoldGP_Welcome.lua | v2.6.0: окно первого запуска (Правила/Таблица) + окно правил; v2.8.0: OnHide=MarkSeen, ShowRules без гильд-гейта |
| GoldGP_Award.lua | IncGold/IncGP, MassGold, Decay, Reset, Recurring, attendance (public note), [ОТП]-маркеры |
| GoldGP_Storage.lua | SetNote очередь, ParseNote (+[ОТП]/db-синхронизация), state-машина, парсинг ростера |
| GoldGP_UI.lua | Окно /gg, ApplyReadOnlyMode, alt visibility, standby window (офицерский гейт v2.8.1), батч-рефреши, динамический VISIBLE_ROWS, кнопка «Правила» (→ ShowRules), кнопка «Фласки» (v2.8.1: создаётся всегда + SyncFlaskButton), v2.8.1: поле поиска удалено |
| GoldGP_Options.lua | v2.8.0: 1 вкладка (Общие). «Настои» уехали в GoldGP_Flask_Options.lua |
| GoldGP_Dialog.lua | Диалоги начисления, OnTextChanged, v2.8.0: строка получателей в массовке |
| GoldGP_History.lua | Журнал, RestoreDone callback, undo с подтверждением |
| GoldGP_Slash.lua | /gg команды (включая setguild/welcome/rules; flask — диспетчер модуля) |
| GoldGP_Announce.lua | Автопубликация; v2.8.0: дебаунс по имя+тип (EP и GP независимо) |
| GoldGP_Log.lua | Уровневый гейт записи в БД, ERROR/WARN в чат |
| GoldGP_UIKit.lua | COLORS, create_button, style_editbox, apply_backdrop (без аллокаций) |
| LootMaster.lua | Протокол V2^, чанкинг 255Б (v0.7.2: FIX лишнего 0 + TestChunk), pendingAwards-очередь + TTL, CalcGP |
| LootMaster_ML.lua | OnOpenMasterLootList, GiveLootToCandidate, OnChatMsgLoot (+валидации), recoveryQueue; v0.7.2: view-записи с дедлайном и тихой очисткой |
| LootMaster_Client.lua | HandleDoYouWant, audioPlayed, SendItemWanted |
| LootMaster_Options.lua | 2 подвкладки (can_edit проверка) |
| ChatThrottleLib.lua | Сторонняя либа, не трогать |
| **GoldGP_Flask/** | **Отдельный аддон (только офицеры):** проверка настоев + вкладка «Настои», своя БД GoldGPFlaskDB + миграция |

### Структура GoldGP_Flask/

| Файл | Назначение |
|------|------------|
| GoldGP_Flask.toc | Interface 30300, SavedVariables: GoldGPFlaskDB, Dependencies: GoldGP |
| GoldGP_Flask.lua | Логика RunCheck/очередь начисления/кулдаун/канал GUILD; API: GetFlaskIDs/Add/Remove/Reset/GPAmount |
| GoldGP_Flask_Options.lua | Категория «GoldGP Фласки» в Interface Options: вкладка «Настои» (список со скроллом, add/remove/reset, GP-поле, проверка) |

## Что НЕ менять (намеренные решения)

- gold_ идентификаторы, Recurring 600/10
- v2.5.9: automatic monthly attendance reset REMOVED — manual reset only via Options UI
- Кнопки разрола: 3 (Мейн/Офф/Бесплатно)
- НЕ показывать шмотку кандидата в ML таблице
- ATT_MASS удалён — посещаемость через public note + GuildInfo
- Alt'ы видны только в рейде/группе/standby
- show_all_mode не распространяется на alt'ов
- | ЗАПРЕЩЁН в public note — использовать (N)
- Кнопка отмены только в Журнале, не в /gg
- v2.6.0: гильд-лок по умолчанию НЕ привязан (REQUIRED_GUILD_NAME = "") — привязка решается офицером через /gg setguild
- v2.6.0: welcome_seen — окно первого запуска показывается один раз на аккаунт
- v2.7.0: ParseNote НЕ стирает on_leave при отсутствии маркера, если он есть в db (см. PROJECT_MEMORY.md § Баг 1)
- v2.7.0: class_data хранит АНГЛИЙСКИЙ токен класса (WARRIOR), а не локализованное имя — на это завязаны UI-иконки/цвета
- v2.8.0: формат чанк-сообщений `CHUNK:V2^transferId^index^total^part` — РОВНО 4 поля после версии (регресс-тест: `/gg loot testchunk`)
- v2.8.0: view_-записи (ML_VIEW) чистятся БЕЗ DISCARD-рассылки — они локальные
- v2.8.0: вложение настроек фласков в ядро НЕ ВОЗВРАЩАТЬ — модуль GoldGP_Flask отдельный; ключ дебаунса Announce — "имя:тип"
- v2.8.0: контракт модулей ядра (LootMaster/Flask): только Addon.Print/PrintError, Addon.Log, Award:IncGP*, Storage:IsCurrentState*, CanEditOfficerNote()
- v2.8.1: класс игрока — только через `Addon:GetClassToken` (не читать class_data напрямую); в class_data — только валидные токены
- v2.8.2: НИКОГДА не добавлять GoldGP_Flask/GoldGP_LootMaster в OptionalDeps GoldGP.toc — цикл зависимостей переворачивал порядок загрузки (модули молча умирали); порядок обеспечивают .toc модулей (у LM — жёсткая Dependencies)
- v2.8.2: в мапе LOCALIZED_CLASS_TO_TOKEN обязательно есть "Прист"→PRIEST (ruRU-ростер говорит «Прист»); класс альта НЕ копировать от мейна
- v2.8.3: в мапе ОБЯЗАТЕЛЬНЫ и ЖЕНСКИЕ формы классов ruRU (Шаманка/Охотница/Жрица/Воительница/Паладинка/Разбойница/Чернокнижница/Друидка) — WoW возвращает имя класса с учётом ПОЛА персонажа, а GetClassInfo даёт только базовую форму; цикл GetClassInfo-достройки НЕ обрывать на первом nil
- v2.8.2: точки входа модулей — паттерн boot()+waiter (переживают нарушенный порядок загрузки); НЕ возвращать ранние "if not Addon then return end"
- v2.8.1: string.trim НЕ существует в 3.3.5a — использовать strtrim/trim_lower
- v2.8.1: гейты CanEditOfficerNote НЕ ставить в register_options панелей настроек — только к их содержимому

---

**Создано специально для гильдии MadTeaParty (sirus.su)**
