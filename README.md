# Beacon Hub

Приложение для статус-бара macOS: статусы пайплайнов GitLab CI/CD и лимиты подписки Claude в одной панели.

## Быстрый старт

```bash
make install     # собрать → поставить в /Applications → запустить
```

| Команда | Что делает |
|---|---|
| `make install` | release-сборка, установка в `/Applications`, перезапуск |
| `make dev` | debug-запуск с логами в терминал (Ctrl+C останавливает) |
| `make package` | universal-zip (Apple Silicon + Intel) в `dist/` для отправки |
| `make release` | выпустить версию на GitHub (см. «Выпуск версии») |
| `make uninstall` | остановить и удалить из `/Applications` |
| `make icon` | перегенерировать иконку |

Требования: macOS 14+, Xcode или Command Line Tools.

## Авторизация

**GitLab.** Подхватывается из `glab` автоматически (`brew install glab && glab auth login`), поддерживается несколько хостов, включая self-hosted. OAuth-токены glab обновляются сами: при 401 приложение вызывает `glab api`, и тот освежает токен. Если glab нет, в настройках есть «Добавить хост с токеном»: Personal Access Token со scope `read_api`, хранится в Keychain.

**Claude.** Логин не нужен: используется токен Claude Code из Keychain (`Claude Code-credentials`), читается через `/usr/bin/security`. Достаточно установленного и залогиненного `claude`. Эндпоинт `api.anthropic.com/api/oauth/usage` **неофициальный**. Если сломается, правка нужна в `Providers/ClaudeUsageProvider.swift → parse`.

**Яндекс Трекер.** OAuth-токен (живёт ~год) в Keychain, запись `beaconhub-yandex-tracker`; получается в Настройки → Трекер. Тот же токен может использовать MCP трекера в Claude Code (команда для конфига есть в настройках). Для облачной организации используется заголовок `X-Cloud-Org-ID`. Запросы к трекеру идут последовательно: на параллельные он отвечает 429.

## Панель

Вкладки: **Сводка** (таймер, события и задачи трекера, только упавшие и идущие пайплайны, лимиты Claude) · **Задачи** (В работе / Ждут / Мои / События, карточка задачи со статусами, списанием времени, таймером и комментариями) · **Заметки** (заметки и чеклисты: строка ввода сверху, `[] молоко; хлеб` создаёт чеклист, пункты отмечаются прямо в списке; закреплённые видны в «Сводке», заметку можно привязать к задаче трекера; хранятся в `~/Library/Application Support/BeaconHub/Notes`) · **CI** · **Claude**. В строке задачи при наведении появляются ▶ таймер и ⏱ списание, по правому клику открывается меню. В статус-баре отображаются ⏱ время таймера и ●N непрочитанных событий.

Отладка вёрстки: `BEACONHUB_SNAPSHOT_DIR=/путь "/Applications/Beacon Hub.app/Contents/MacOS/BeaconHub"` рисует все вкладки в PNG и завершается. `BEACONHUB_NOTES_FILE=/путь/notes.json` подменяет файл заметок, чтобы не трогать настоящие.

## Инструменты

| Инструмент | Клавиша по умолчанию | Разрешение macOS |
|---|---|---|
| Текст с экрана (OCR ru/en + QR) | ⌘⇧2 | Запись экрана |
| История буфера обмена | ⌥⌘V | Универсальный доступ (только для вставки сразу в поле) |

Сочетания, лимит истории и режим вставки настраиваются на вкладке «Инструменты». В панели истории: ↑↓ для выбора, ↩ вставить, ⌘1–9 быстрая вставка, ⌘P закрепить, ⌘⌫ удалить. История хранится в `~/Library/Application Support/BeaconHub/Clipboard`, пароли из менеджеров паролей не сохраняются.

## Скачать

Готовые сборки лежат в [Releases](https://github.com/shuraman69/beacon-hub/releases). Скачай zip, распакуй, перетащи в «Программы» и один раз выполни команду ниже. История изменений в [CHANGELOG.md](CHANGELOG.md).

## Выпуск версии

1. По ходу работы записывай изменения в `CHANGELOG.md` → «Не выпущено».
2. `make release` (patch), `make release BUMP=minor` или `make release V=1.0.0`.

Скрипт переносит «Не выпущено» в раздел версии, обновляет `VERSION`, собирает universal zip, коммитит, ставит тег `vX.Y.Z`, пушит и создаёт GitHub Release с zip и текстом из CHANGELOG. Нужен `gh` (`brew install gh && gh auth login`).

## Раздача другим

`make package` создаёт `dist/BeaconHub-<версия>.zip`. Без Developer ID сборка не нотаризована, поэтому получателю нужно один раз выполнить:

```bash
xattr -dr com.apple.quarantine "/Applications/Beacon Hub.app"
```

С сертификатом Developer ID и профилем notarytool: `NOTARY_PROFILE=<имя> make package`.

## Устройство

```
Sources/BeaconHub/
├── App/        точка входа, AppState (опрос, уведомления), статус-бар, настройки
├── Auth/       Keychain, конфиг glab, токен Claude Code
├── Providers/  GitLabAPI/GitLabProvider, ClaudeUsageProvider
├── Notes/      заметки и чеклисты (NotesStore)
├── Tracker/    API и состояние Яндекс Трекера
├── Tools/      OCR, история буфера, тосты
├── Core/       модели, форматтеры, запуск CLI
└── UI/         панель и окно настроек (SwiftUI)
```

Как добавить новый источник: провайдер в `Providers/` (async-функция fetch), поле состояния и вызов в `AppState.refresh`, секция в `UI/PanelView.swift`, тумблер в настройках.
