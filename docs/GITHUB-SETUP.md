# Публикация GoldGP на GitHub через VS Code — пошаговая инструкция

> Репозиторий уже подготовлен: git инициализирован, первый коммит и тег `v2.8.6` созданы,
> `.gitignore` / `.gitattributes` / `LICENSE` / `README.md` на месте.
> Осталось: поставить Git (если ещё нет), войти в GitHub и нажать «Publish».

---

## Шаг 1. Установите Git для Windows (один раз)

1. Скачайте: https://git-scm.com/download/win
2. Установите (кнопки Next; в пункте редактора можно выбрать «Use Visual Studio Code as Git's default editor»)
3. Проверка: в VS Code откройте терминал (**Ctrl + `**) и введите `git --version` — должна появиться версия
4. Если VS Code был открыт во время установки — перезапустите его

## Шаг 2. Аккаунт GitHub

- Если нет аккаунта: https://github.com → **Sign up**
- Запомните свой ник (например `madteaparty-officer`)

## Шаг 3. Представьтесь Git (один раз на компьютер)

В терминале VS Code:

```bash
git config --global user.name "ВашНик"
git config --global user.email "почта-от-github@example.com"
```

> Почту лучше указать ту же, что в GitHub → Settings → Emails — тогда коммиты
> будут связаны с вашим профилем (зелёные квадратики в graph).

**Опционально** — переподписать уже готовый первый коммит своим именем:

```bash
git commit --amend --reset-author --no-edit
```

## Шаг 4. Публикация

### Способ A — прямо из VS Code (рекомендуется, 4 клика)

1. **File → Open Folder** → папка репозитория `GoldGP`
2. Слева иконка **Source Control** (ветвление) — там будет кнопка **«Publish Branch»**
3. VS Code предложит войти в GitHub: **Allow** → откроется браузер → **Authorize**
4. Введите имя репозитория: `GoldGP`, выберите **public** (или private) → подтверждение

Готово — репозиторий создан на github.com и код запушен.

### Способ B — через сайт github.com

1. https://github.com/new → Repository name: `GoldGP` → Public → **Create repository**
   **НЕ добавляйте** галочки README / .gitignore / license — всё уже есть в репо!
2. В терминале VS Code (в папке репозитория):

```bash
git remote add origin https://github.com/ВАШ_НИК/GoldGP.git
git push -u origin main --follow-tags
```

3. При первом push Windows спросит вход → откроется браузер (Git Credential Manager) → **Authorize**

## Шаг 5. Проверка

- Обновите страницу `https://github.com/ВАШ_НИК/GoldGP` — видны папки аддонов, README отрисован
- Вкладка **Tags** — тег `v2.8.6` на месте

## Как показывать проект другим нейронкам

- Просто дайте ссылку: `https://github.com/ВАШ_НИК/GoldGP`
- Ссылка на сырой текст файла (удобнее для ИИ): на странице файла кнопка **Raw**
- Главный файл контекста: `docs/PROJECT_MEMORY.md` (инварианты, история багов, решения)
- Второй по важности: `CHANGELOG.md` (что менялось между версиями)

## Ежедневный цикл правок

**В VS Code:** вкладка Source Control → `+` (Stage All) → сообщение коммита → **Commit** → **Sync Changes**

**В терминале:**

```bash
git add -A
git commit -m "v2.8.7: что изменилось"
git push
```

## Обновление аддона в WoW из репозитория

```bash
# один раз (в ПУСТУЮ папку AddOns):
git clone https://github.com/ВАШ_НИК/GoldGP.git "C:\Games\WoW\Interface\AddOns"

# все последующие обновления:
cd "C:\Games\WoW\Interface\AddOns"
git pull
```

## Если что-то пошло не так

| Проблема | Решение |
|----------|---------|
| push отклонён (rejected) | `git pull --rebase` затем снова `git push` |
| VS Code не видит git | перезапустить VS Code после установки Git |
| неверный автор коммита | `git commit --amend --reset-author --no-edit` (пока не запушено) |
| пушили мусор и хотите откатить | `git revert <hash>` — безопасный откат (создаёт новый коммит) |
