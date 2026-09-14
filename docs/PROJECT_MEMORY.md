# PROJECT MEMORY — GoldGP 2.x (skills memory)

> Этот файл — память проекта. Читай его ПЕРЕД любыми правками, чтобы не
> перечитывать 17k строк заново. После значимых правок — дополняй.

## 1. Что это и где что лежит

```
addon-analysis/
├── GoldGP/              — основной аддон (v2.8.5, Interface 30300)
│   ├── GoldGP.toc       — порядок загрузки ВАЖЕН (Core → UIKit → Log → Storage → ...)
│   │                    — НИКОГДА не добавлять модули в OptionalDeps ядра (цикл!)
│   └── *.lua            — 12 модулей (Фласки вынесены в v2.8.0)
├── GoldGP_LootMaster/   — модуль распределения лута (v0.7.4, Dependencies: GoldGP — жёсткая)
│   └── ChatThrottleLib.lua — сторонняя либа, НЕ ТРОГАТЬ
├── GoldGP_Flask/        — модуль фласков для офицеров (v0.1.2, Dependencies: GoldGP)
│                        — своя БД GoldGPFlaskDB + одноразовая миграция из GoldGPDB
├── CHANGELOG.md         — отчёты по правкам
└── PROJECT_MEMORY.md    — этот файл
```

## 2. Ключевые инварианты (нарушать нельзя)

1. **Офицерская нота = единственный серверный источник EP/GP.** Формат `"Gold,GP"`,
   alt — нота = имя main'а. В displayed GP входит `base_gp` (см. `EncodeNote`).
2. **pending_note очередь (Storage)** — до 3 значений на игрока, пишется по одному за
   проход. Все записи EP/GP идут ТОЛЬКО через `Storage:SetNote` (не GuildRosterSetOfficerNote напрямую).
3. **ParseNote не перезаписывает данные при наличии pending** — сервер шлёт устаревшие ноты во время flush.
4. **`class_data` хранит АНГЛИЙСКИЙ токен** (WARRIOR/PALADIN/...) с v2.7.0. UI (CLASS_COLORS,
   CLASS_ICON_TCOORDS) индексируется токенами. GetGuildRosterInfo возвращает ЛОКАЛЬНОЕ имя —
   конвертация в `LOCALIZED_CLASS_TO_TOKEN` (Storage.lua).
5. **`class` в GetGuildRosterInfo — 5-я позиция**, НЕ 11-я (11-й не существует в 3.3.5a):
   `name(1), rank(2), rankIndex(3), level(4), class(5), zone(6), publicNote(7), officerNote(8), online(9), status(10)`.
6. **Vacation (отпуск):** маркер `[ОТП]` в конце officer note — общий источник истины
   между офицерами; `db.global.on_leave` — локальный кэш. `ParseNote` НЕ стирает флаг
   памяти, если он есть в db. Снятие — через `SetOnLeave(false)` (чистит ноту+db+память).
7. **Чистка on_leave только после реального ростера** (`Storage:IsInitialized()`), иначе
   Баг 1 возвращается. `RosterReady` событие из Storage → `RunDeferredOnLeaveCleanup` (Core).
8. **guild_lock_ok** (Core): true/false/nil. `Addon:IsEnabled()` — главный гейт. Все новые
   действия офицера ДОЛЖНЫ проверять `IsEnabled()` + `CanEditOfficerNote()`.
9. **LootMaster GP-начисления:** ровно ОДИН путь charge → либо lootTable-loop (isML),
   либо recoveryQueue. При переносе в recoveryQueue оригинал помечается `gpProcessed=true`
   (Баг 2). `RestoreLootTable` повторяет перенос (гап логаута).
10. **pendingAwards — FIFO по (itemID, candidate).** Первый элемент = кандидат на matching
    следующего CHAT_MSG_LOOT. «Призраки» (ключ без живого лута) чистятся в 3 местах:
    ScheduleLootCleanup, OnChatMsgLoot (удалить + продолжить), TTL 10 мин. НЕ возвращать
    `return` на невалидном элементе без его удаления.
11. **giveTime — защита от ложных начислений:** лут-сообщение старше 90 сек после выдачи
    = чужое получение, GP не начислять (Баг 3b).
12. **SendAddonMessage 3.3.5a — лимит 255 байт.** Любое потенциально длинное сообщение
    LootMaster уходит через `LM:TransmitChunked` (CHUNK:V2^transferId^i^total^data);
    приём через `LM:HandleChunkMessage` на входе обоих handler'ов.
13. **WoW 3.3.5a: НЕТ** C_Timer, GetNumGroupMembers, IsMasterLooter, BackdropTemplate,
    C_PetBattles и пр. Есть: GetTime, time, IsRaidLeader, GuildRosterSetPublicNote,
    GetRaidRosterInfo (11 rets). Таймеры — OnUpdate-фреймы (свой schedule в Award
    УДАЛЁН в v2.7.1 как мёртвый; живые задержки — через абсолютные метки time()/GetTime()).
14. **SendAddonMessage("GoldGP")** зарегистрирован в pcall; PrintError определены ДО
    любых рискованных вызовов в Core.
15. **UI-рефреши батчатся:** NoteChanged/NoteDeleted/StorageStateChanged → dirty-frame
    0.2с (UI.lua). Не вешать прямые RefreshStandings на частые события.
16. **Мёртвый код вычищен (v2.7.1, v2.8.4) + дубли и комментарии (v2.8.5).**
    Если кажется, что «какой-то метод надо вернуть» — сначала проверь CHANGELOG
    v2.7.1/v2.8.4: удалено ОСОЗНАННО после grep-верификации. Возвращать только
    при реальном вызове.
    АВТО-SWEEP: слово-имя экспорта встречается в 19 lua-файлах ровно 1 раз
    (только определение) = кандидат на удаление; перед любым удалением — grep-доказательство.
    ПОЛИТИКА КОММЕНТАРИЕВ (v2.8.5, релиз): история изменений в код НЕ возвращать —
    она в CHANGELOG.md. Допустимы: шапка файла, баннеры, форматы протоколов/нот,
    грабли 3.3.5a/sirus, предупреждения-инварианты, объяснения неочевидной
    текущей логики. Язык комментариев — русский.
    ВАЖНО про UI-доступ модулей: в LM_Options ссылки на UIKit — через ГЛОБАЛ
    GoldGP.UIKit.X (локальный Addon захвачен при загрузке файла и может быть
    nil при отложенном старте); в Flask_Options — Addon.UIKit (параметр boot);
    в ядре — Addon.UIKit. Общие фабрики create_section_header/create_checkbox
    живут в UIKit — НЕ копировать их обратно в файлы настроек.
17. **UI: VISIBLE_ROWS динамический** (GetVisibleRows = floor(высота скролла/22)) —
    НЕ хардкодить число строк: высота окна из профиля может быть любой (460..482+).
18. **UI: сортировка персистится** в profile.sort_order (клик по заголовку колонки);
    валидные ключи: NAME/GOLD/GP/PR/RANK/ATTEND.
19. **LM.mlFrame присваивается в CreateMLWindow (ML.lua)** — гварды скрытия ML-окна в
    EndLootSession/finish_test/TestReset РАБОТАЮТ. Если появится второе ML-окно —
    обновить ссылку.
20. **Welcome: ShowRules() — прямой API окна правил; Show(force) — окно выбора.
    Кнопка «Правила» в тайтлбаре таблицы открывает СРАЗУ правила (v2.8.0);
    окно выбора — только при первом запуске и /gg welcome. /gg rules работает
    и вне гильд-лока (ShowRules БЕЗ гейта IsEnabled — осознанно).
    OnHide welcome-фрейма = MarkSeen (Escape тоже «увидели» — автопоказ
    не повторяется).**
    Скролл-чайлд окна правил ОБЯЗАН получать высоту из body:GetStringHeight()
    ДО SetScrollChild (иначе текст невиден — баг v2.6.0-2.7.0).
21. **Чанк-формат LootMaster: `CHUNK:V2^transferId^index^total^part` — РОВНО 4 поля
    после версии (v0.7.2: был лишний 0 → все сообщения >190 байт терялись).
    Строит части BuildChunkMessages; регресс-тест: `/gg loot testchunk` → OK.
    Приём — HandleChunkMessage на ВХОДЕ обоих handler'ов (до парсинга команды).**
22. **view_-записи (ML_VIEW, ключ `view_<itemID>`) — ЛОКАЛЬНЫЕ копии кандидата:
    создаются с announcedAt=time()/timeout=60 и чистятся в ScheduleLootCleanup
    БЕЗ DISCARD-рассылки и без HandleDiscard.**
23. **standby-snapshot имеет таймаут (v2.8.0): watch-фрейм в Core (Start/Stop
    StandbySnapshotWatch), 10 сек на chunks после STB_META; по истечении —
    сброс standby_snapshot + сообщение игроку. Live-список НЕ трогается.**
24. **Фласки — ОТДЕЛЬНЫЙ аддон GoldGP_Flask (v2.8.0). Ядро НЕ содержит
    GoldGP_Flask.lua и вкладки «Настои» в Options. Детект модуля — Addon.Flask
    (экспортируется модулем после гварда Addon). Кнопка в UI и диспетчер
    /gg flask гейтятся на Addon.Flask. Контракт модулей ядра: только
    Addon.Print/PrintError, Addon.Log, Award:IncGP*, Storage:IsCurrentState*,
    CanEditOfficerNote(). Миграция GoldGPDB→GoldGPFlaskDB ОДНОРАЗОВАЯ
    (флаг migrated; старые flask_ids/flask_gp_amount обнуляются).**
25. **Announce-дебаунс: ключ individual_debounce = "имя:тип" (gold/gp),
    имя игрока в info.player (НЕ в ключе — публикация берёт оттуда).**
26. **Кнопка «Фласки» (v2.8.1) создаётся ВСЕГДА, видимость — только через
    UI:SyncFlaskButton()** (модуль Addon.Flask + state.can_edit). Она
    вызывается из CreateMainWindow/Show/ApplyReadOnlyMode и конца
    GoldGP_Flask.lua. НЕ возвращать одноразовый детект "if Addon.Flask then
    создать кнопку" — это источник бага «кнопки нет» (v2.8.0).
27. **Класс игрока (v2.8.1) берётся ТОЛЬКО через Addon:GetClassToken(name,
    main)** — цепочка class_data[name] → class_data[main] → живой UnitClass
    (state.raid_units из RAID_ROSTER_UPDATE / парти-скан). В class_data
    пишутся ТОЛЬКО валидные токены (Storage NormalizeClassToken +
    Addon.CLASS_TOKENS из UIKit); невалидное значение НЕ перезаписывает
    валидное. Атлас/TCOORDS иконок — корректны, не трогать.
28. **Панели Interface Options (LM + Flask, v2.8.1) регистрируются ВСЕГДА**;
    гейт CanEditOfficerNote применять К СОДЕРЖИМОМУ панелей (скрытие кнопок +
    пояснение, перепроверка в OnShow). НЕ возвращать молчаливый ранний
    return в register_options — это баг «настройки исчезли» (репорт 2.8.0).
29. **Функция «Замены» (standby) — полностью офицерская (v2.8.1):** гейт
    state.can_edit в UI:ShowStandbyWindow, SetStandby, /gg standby-мутациях,
    whisper-фильтре (лидер + офицер). Приём STB-дельт НЕ гейтится (синхронизация
    отображения для рейд-сообщников). list/status/sync — пассивный просмотр.
30. **string.trim НЕ существует в Lua/WoW 3.3.5a.** Для trim использовать
    strtrim (FrameXML) с gsub-fallback (см. trim_lower в Core). В старом коде
    мог остаться msg:lower():trim() — это краш на каждом вызове.
31. **Поле поиска в таблице /gg УДАЛЕНО (v2.8.1)** — filter_text/filter_box не
    существуют; кэш standings = sig(sort_order, raid, show_all, cache_ver,
    member_count). Если поиск понадобится — возвращать вместе с веткой в
    get_standings_sorted и полем в сигнатуре кэша.
32. **НИКОГДА не объявлять GoldGP_Flask/GoldGP_LootMaster в OptionalDeps
    GoldGP.toc (v2.8.2):** цикл «ядро ↔ модули» переворачивал порядок загрузки
    на кастом-клиенте — модули молча умирали на "if not Addon then return end"
    (фласки нет, настроек LM нет, ошибок нет). Порядок обеспечивают .toc
    МОДУЛЕЙ (у LM — жёсткая Dependencies: GoldGP).
33. **Все 5 точек входа модулей переживают нарушенный порядок загрузки
    (v2.8.2):** Flask.lua / Flask_Options.lua / LM main / LM Client / LM ML
    обёрнуты в boot(Addon[, LM/Flask]) + waiter (ADDON_LOADED/PLAYER_LOGIN,
    OnUpdate-кап 30с). LM main создаёт глобаль GoldGPLootMaster ДО boot и
    выносит пост-инициализацию в LM:_PostLoadInit (guard postload_done);
    Client/ML в отложенном пути сами вызывают InitClient/InitML, если LM.db
    уже готов (в нормальном пути LM.db ещё нет — вызов остаётся за main).
    НЕ возвращать ранние "if not Addon then return end" в модулях — это
    источник тихой смерти. Новые файлы модулей — по этому же паттерну.
34. **Классы (v2.8.2):** алиас "Прист"→PRIEST ОБЯЗАТЕЛЕН (ruRU-ростер говорит
    «Прист», GetClassInfo — «Жрец»); LOCALIZED_CLASS_TO_TOKEN достраивается
    рантайм из GetClassInfo (pcall, не перезаписывает hardcoded);
    класс альта НЕ копируется от мейна (ParseNote); самолечение — ТОЛЬКО из
    живых источников СОБСТВЕННОГО класса (raid_units/UnitClass), без
    наследования. Диагностика — /gg classdiag (Addon:GetClassDiagnostics +
    Storage DebugNormalizeClassToken).
35. **ЖЕНСКИЕ формы классов (v2.8.3) ОБЯЗАТЕЛЬНЫ в LOCALIZED_CLASS_TO_TOKEN:**
    WoW возвращает строку класса С УЧЁТОМ ПОЛА персонажа (GetGuildRosterInfo /
    UnitClass): Шаман/Шаманка, Охотник/Охотница, Жрец/Жрица, Воин/Воительница,
    Паладин/Паладинка, Разбойник/Разбойница, Чернокнижник/Чернокнижница,
    Друид/Друидка; «Маг» и «Рыцарь смерти» — одинаковы для обоих полов.
    GetClassInfo() даёт ТОЛЬКО базовую форму — рантайм-достройка женские
    строки НЕ добавляет (подтверждено classdiag: «Шаманка» НЕ МАПИТСЯ).
    Цикл GetClassInfo-достройки НЕ должен break'аться на первом nil.
    Самосбор UnitClass("player") — добавляет строку СВОЕГО класса, если её нет.

## 3. Карта модулей (что где менять)

| Задача | Файл | Где |
|--------|------|-----|
| Права/гейт офицера | Core.lua | `IsEnabled`, `CanEditOfficerNote`, state.can_edit |
| Гильд-лок | Core.lua | `REQUIRED_GUILD_NAME` (верх файла), `CheckGuildLock`, `UpdateGuildLock`, `DoWorldInit` |
| Welcome-окно / правила | GoldGP_Welcome.lua | `RULES_TEXT` (заглушка!), `EnsureWelcomeFrame`, `ShowRules`, `FitRulesFrameToContent` |
| Формулы/начисления | Award.lua | `IncGold`/`IncGP`/`MassGold`/`Decay`; `EncodeNote` (маркер [ОТП]) |
| Парсинг ростера/нот | Storage.lua | `FrameOnUpdate`, `ParseNote`, `ParseGuildInfo` (@DECAY_P и др.) |
| Посещаемость | Storage.lua | `ParsePublicNote` (спек (N)), `SetPublicNote`; total — `@ATT_TOTAL` в GuildInfo |
| Standby/замены | Core.lua | `SetStandby` (гейты: ОФИЦЕР + лидер), STB_* протокол, `standby_session` (leader-scoped), snapshot-таймаут (Start/StopStandbySnapshotWatch); гейт can_edit также в UI:ShowStandbyWindow и Slash |
| Таблица/строки | UI.lua | `CreateRow`, `UpdateRow` (класс — `Addon:GetClassToken`), `get_standings_sorted` (кэш по сигнатуре), `GetVisibleRows` |
| Кнопка «Фласки» | UI.lua + Flask.lua | `UI:SyncFlaskButton` (видимость = модуль + офицер), `MaybeShowFlaskHint`; notify из конца Flask.lua |
| Класс-резолв | Core.lua + Storage.lua + UIKit.lua | `Addon:GetClassToken`, `state.raid_units` (RAID_ROSTER_UPDATE), `NormalizeClassToken` + `Addon.CLASS_TOKENS` + `GetClassInfo`-достройка мапы, `/gg classdiag` |
| Порядок загрузки модулей | все .toc + 5 boot-файлов | GoldGP.toc БЕЗ OptionalDeps; LM.toc — Dependencies; boot+waiter (инвариант 33) |
| ML выдача лута | LootMaster_ML.lua | `GiveLootToCandidate` (slotID-first), `OnChatMsgLoot` (matching+charge) |
| GP-таблица предметов | LootMaster.lua | `CalcGP`, `GetFixedGP`, `gp_overrides` |
| Чанкинг/протокол | LootMaster.lua | `BuildChunkMessages`, `TransmitChunked`, `HandleChunkMessage`, `TestChunk` |
| Фласки | GoldGP_Flask/ | `RunCheck` (Flask.lua), вкладка «Настои» (Flask_Options.lua); в ядре — гейт кнопки (UI.lua) и диспетчер (Slash.lua) |
| Логирование | Log.lua | `write_log` (уровневый гейт с v2.7.0) |

## 4. История багов (не регрессировать)

- **Баг 1 (v2.7.0 исправлен):** стирание on_leave при логине — async GuildRoster vs CleanupOldData.
  Тест: поставить отпуск офицером → перелог → статус должен остаться.
- **Баг 2 (v2.7.0):** двойное GP при смене ML — recoveryQueue копия без пометки оригинала.
  Тест: выдать лут с неуспевшим списаться GP → передать ML другому → GP списывается ОДИН раз.
- **Баг 3 (v2.7.0):** призраки в pendingAwards блокировали очередь; чужой лут считался выдачей.
  Тест: отменить выдачу → выдать второй такой же предмет этому игроку → должен выдаться;
  лутнуть самому такой же предмет через 2+ мин после выдачи → GP НЕ должен списаться.
- **UX-баги (v2.7.1 исправлены):** (а) текст правил невиден — скролл-чайлд без высоты;
  (б) последняя строка /gg под footer — захардкоженный VISIBLE_ROWS=15 при высоте окна 460.
- **Скрытые баги (v2.7.1 исправлены):** (а) self.UI:Print не существует → уведомления
  о standby-лидере молчали (теперь Addon.Print); (б) LM.mlFrame не присваивался → ML-окно
  не скрывалось при EndLootSession/finish_test/TestReset.
- **Чанкинг (v0.7.2 исправлен):** лишний `0` в CHUNK-format → сообщения >190 байт
  (DO_YOU_WANT с ruRU-линками) молча терялись. Тест: `/gg loot testchunk` → OK.
- **ML_VIEW (v0.7.2 исправлен):** view-записи умирали с первого тика cleanup'а
  (нет announcedAt → дедлайн 70) + DISCARD-рассылка для локальной записи.
- **Announce (v2.8.0 исправлен):** EP и GP одному игроку сливались в одну запись
  дебаунса (ключ только по имени) → «+60 EP» вместо двух корректных записей.
- **Кнопка «Фласки» (v2.8.1 исправлен):** одноразовый детект Addon.Flask при
  создании окна → кнопка молча не появлялась. Теперь создание всегда, видимость
  динамическая (SyncFlaskButton) + разовая диагностика при открытии таблицы.
- **Настройки LM/Flask (v2.8.1 исправлен):** молчаливый гейт CanEditOfficerNote
  в register_options → категория настроек исчезала из Interface Options.
  Теперь панели регистрируются всегда, офицерство — к содержимому (OnShow).
- **Иконки классов (v2.8.1 исправлен):** у части игроков (присты/шаманы/ханты)
  иконка/цвет пропадали: (а) class=nil из ростера затирал класс на каждом
  проходе; (б) ParseNote альта затирал его класс nil-классом мейна; (в) сырая
  локализованная строка вне таблицы. Теперь: NormalizeClassToken (валидные
  токены, сохранение валидного), alt-guard + самовосстановление классов альтов
  в конце прохода, GetClassToken с fallback на мейн и живой UnitClass (рейд:
  state.raid_units).
- **string.trim (v2.8.1 исправлен):** msg:lower():trim() в whisper-фильтре —
  string.trim не существует в 3.3.5a → Lua-error на каждом шепоте у не-лидеров.
  Заменено на trim_lower (strtrim + fallback).
- **ЦИКЛ ЗАВИСИМОСТЕЙ .toc (v2.8.2 исправлен):** OptionalDeps модулей в
  GoldGP.toc (появился в v2.8.0) перевернул порядок загрузки — Flask/LM
  грузились РАНЬШЕ ядра и молча умирали на "if not Addon then return end":
  кнопки «Фласки» нет, настроек LM нет, ошибок нет (репорт v2.8.1: фиксы 2.8.1
  не помогли, т.к. файлы модулей вообще не исполнялись). Убран OptionalDeps,
  LM.toc — жёсткая Dependencies, все 5 точек входа модулей — boot+waiter.
- **«Прист»/иконки (v2.8.2 исправлен):** ruRU-ростер возвращает «Прист» (мапа
  знала только «Жрец») → у прист не было иконки/цвета; класс альта копировался
  от мейна → хант-альт воина показывал иконку воина; самолечение v2.8.1
  наследовало класс мейна альтам. Теперь: алиас «Прист» + GetClassInfo-достройка
  мапы + собственный класс альта + самолечение только из живых источников.
  Диагностика: /gg classdiag (вывод — пользователю на отправку).
- **«Шаманка» без иконки (v2.8.3 исправлен):** WoW возвращает имя класса
  с учётом ПОЛА персонажа — «Шаманка»/«Охотница»/«Жрица»/... не входили в мапу
  (там были только мужские формы, а GetClassInfo тоже даёт только базовые).
  classdiag v2.8.2 показал: «Шаманка» ×1 НЕ МАПИТСЯ (Электробабка), «Шаман» ×1
  → SHAMAN (мужчина). Именно это было истинной причиной «у одних хантов есть,
  у других нет» (пол, а не класс). Теперь: все 8 женских форм ruRU в мапе,
  цикл GetClassInfo без break на nil, самосбор своей формы через UnitClass,
  classdiag показывает игроков БЕЗ строки класса (раньше молча пропускались).
- **Историческое:** pending_note один (v1.x) → очередь; STANDBY_SET|… → STB_* protocol
  (session/revision); LootMaster V1^ → V2^ (lootKey первым полем).

## 5. Тестирование без клиента (как проверяли)

- Синтакс: `luaparse` (Lua 5.1) по всем файлам — 19 файлов (12 ядро + 5 LM + 2 Flask).
- Логические прогоны: анализ сценариев по коду (state-машина Storage, протоколы).
- В игре: ручные чек-листы выше; `LM:TestFull()` / `/gg loot testfull` — встроенные
  тесты LootMaster (testMode, без реальных записей); `/gg loot testchunk` —
  регресс-тест чанкинга (v0.7.2).

## 6. Среда (sirus.su quirks)

- `RegisterAddonMessagePrefix` может отсутствовать/крашиться → все вызовы в pcall.
- `GUILD_ROSTER_UPDATE` часто не приходит после flush → State-машина имеет recovery-таймеры
  (STALE_WAITING 3с → CURRENT; REMOTE_FLUSHING 7с → roster; FLUSHING 5 попыток → CURRENT).
- Не полагаться на echo собственного RAID-broadcast — явный self-delivery.
- Кириллица: strlower не приводит кириллицу; сравнение гильдий — точное + ASCII-lower fallback.
- **Имена классов ГЕНДЕРНЫ (ruRU):** GetGuildRosterInfo/UnitClass дают
  «Шаманка»/«Охотница»/«Жрица»/... для женских персонажей; GetClassInfo — только
  базовую форму. Сравнивать строки классов можно только с учётом обеих форм
  (инвариант 35).

## 7. Что было осознанно НЕ сделано

### v2.8.6 (Фазы 4–5: визуал P1/P2 + веб)

- **Системный GameTooltip ОСТАВЛЕН** (решение по P2-3): тёмная перекраска требует
  ГЛОБАЛЬНОГО хука `GameTooltip:SetBackdropColor`/`SetBackdropBorderColor` — на
  3.3.5 он заденет чужие аддоны и Blizzard-UI (аукцион, банк). Дефолтный бежевый
  тултип узнаваем игроками. Пересмотреть только при явном спросе.
- **Кастомный скроллбар НЕ делаем** (P2-4): аудит — «только если будет спрос».
- **ML_ROW_HEIGHT = 20 (список ставок ML) НЕ поднимался до 24**: это отдельная
  компактная таблица выборов ML, аудит P2-2 касался таблиц 22px (ростер, журнал).
- **Fallback-заглушки UIKit в ML.lua/Client.lua** (`UIKit.X or function...`)
  ОСТАВЛЕНЫ: Фаза 1 чистила только Options-файлы; шапки заменены на chrome, но
  решение о полном удалении заглушек в ML/Client — отдельно (низкий приоритет:
  UIKit гарантирован Dependencies).
- **Client-окно выросло на 8px** (`CHROME_H`) под полноценный тайтлбар: прежний
  заголовок был свободным FontString; SavedVariables-миграция не нужна (позиция
  окна не зависит от высоты).
- **Мокапы на веб-странице** — HTML-реконструкции, НЕ игровые скриншоты; подписаны
  честно. Заменить реальными скриншотами, если появятся (W-3 закрыта мокапами).
- `og-image.png` без текста версии — не устареет при бампах.
- **Анимации/кастомный шрифт** (P3 из аудита) — не делаем, см. UI_VISUAL_AUDIT §2 P3.

### v2.8.5 (Фазы 2–3 релизной чистки)

- Объединение `create_header_btn` (UI.lua/History.lua) и титлбаров 4 окон
  ОТОЖДЕНО в визуальную фазу (P2-1 `UIKit.create_window_chrome`): сигнатуры
  различаются (sort_key), объединять без визуального прохода рискованно.
- Версии в СТРОКАХ-литералах не тронуты (help /gg loot, Log:Info, att_hint) —
  это код/пользовательский текст, не комментарии.
- Провenance-комментарии («Вдохновлено EPGP…») оставлены — происхождение,
  а не история изменений.
- Англоязычные комментарии живой логики не переводились массово (перевод —
  только при переписывании смешанного комментария).
- Попутный ФИКС Flask_Options: якорь notice не-офицера `count_label` (nil-глобал)
  → `panel_data.count_label` (позиция пояснения теперь под «Всего настоев»).

### v2.8.4 (Фаза 1 релизной чистки)

- LOOTTYPE-нумерация в wire-протоколе НЕ перенумерована (BANK=4, FREE=5, зазор на
  месте удалённого DISENCHANT=3): значения уезжают по сети в LOOTED-сообщениях —
  совместимость важнее эстетики.
- Wire-формат GEAR (7 полей с itemID2/gp2/ilvl2) НЕ ужимался до 4: клиент продолжает
  слать 7, ML игнорирует лишние. Изменение формата требует синхронного обновления
  обеих сторон и отдельного регресс-теста — не оправдано для чистки.
- Параметр `award_type` в Dialog:ShowAwardPlayer ОСТАВЛЕН (там award_player_state.type
  реально читается) — убран только в ShowMassAward/OnMassStart.
- Fallback-геттеры заменены на `error("GoldGP UIKit не загружен")`, а не удалены
  совсем: сохранена динамическая резолв-точка (UIKit берётся в момент вызова,
  а не при загрузке файла — критично для отложенного старта модулей, инвариант 33).
- Boot-тела Flask_Options/LM по-прежнему без ре-индентации (см. v2.8.2).

### v2.7.1 → v2.8.4

- Список «осознанно НЕ удалены (совместимость/задел)» из v2.7.1
  (RESPONSE/LOOTTYPE.DISENCHANT, standby_snapshot.revision, loot.gpValue50,
  gear.item2/gp2/ilvl2, award_type в ShowMassAward) ПОЛНОСТЬЮ УДАЛЕН в v2.8.4
  (Фаза 1 RELEASE_PLAN) после sweep-верификации. meta_received_at ушел ещё в v2.8.0.

### v2.8.3

- Женские формы ДОБАВЛЕНЫ только для ruRU (локаль гильдии). Если придёт репорт
  с другой локали — формы берутся из её classdiag (структура таблицы готова).
- «Друидка»/«Паладинка» и пр. взяты по практике клиента; лишняя запись в мапе
  безвредна (не совпала — просто никогда не сработает), недостающая — ловится
  classdiag.
- Хранение в class_data по-прежнему ТОКЕНА (не строк ростера) — миграция старых
  сохранёнок не нужна: token уже нормализован с v2.8.1, а старые данные без
  токена долечиваются проходом ростера.

### v2.8.2

- GetClassToken по-прежнему не кэширует fallback-результат в class_data
  (запись — за ростер-проходом и самолечением); меньше гонок.
- boot-тела файлов модулей оставлены без ре-индентации (замыкание) — читаемый
  дифф важнее эстетики; при следующем касании файла можно переиндентировать.
- /gg classdiag печатает RAW строки как есть (без hex/байт-дампа) — если
  вывод не выявит причину, добавить байт-дамп в следующей итерации.

### v2.8.1

- `list/status/sync` standby-команд оставлены доступными всем (пассивный
  просмотр; [Замена]-пометки и так видны всем рейд-сообщникам через STB-синк).
- Панели настроек LM/Flask видны не-офицерам (с пояснением вместо кнопок) —
  плата за гарантию «настройки не исчезают». Если нужна полная скрытность —
  вернуть гейт регистрации, но тогда снова возможен репорт «исчезли настройки».
- GetClassToken не кэширует fallback-результат в class_data (только читает) —
  запись остаётся за ростер-проходом; так менее рискованно для гонок.

### v2.7.1

- Осознанно НЕ удалены (совместимость/задел): RESPONSE/LOOTTYPE.DISENCHANT (5),
  standby_snapshot.revision, loot.gpValue50, gear.item2/gp2/ilvl2,
  параметр award_type в Dialog:ShowMassAward.
  (meta_received_at из этого списка УШЁЛ в v2.8.0 — таймаут реализован.)

### v2.8.0

- Миграция GoldGPDB→GoldGPFlaskDB переносит ТОЛЬКО flask_ids и flask_gp_amount —
  прочие настройки ядра не трогаются.
- Ветка сортировки CLASS удалена сознательно: если понадобится — вернуть вместе
  с заголовком колонки (см. комментарий в get_standings_sorted).
- Правки «MED/LOW косметики» (alt-в-отпуске без пометки в строке и пр.) — не тронуты.

### v2.7.0

- Остальные MED/LOW находки аудита (get_standings_sorted двойные GetMemberData,
  INVTYPE_SLOTS на каждое DO_YOU_WANT, UpdateRow tooltip-аллокации, History per-award
  Refresh при открытом журнале) — не влияют на корректность; делать при заметных фризах.
  (частично закрыто v2.7.1: UpdateRow selected-ветка удалена)
- Персистентное восстановление pendingAwards после рестарта — очереди не персистятся
  осознанно (giveTime-fallback покрывает recovery).
