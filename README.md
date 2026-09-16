# wkbdy2api

Локальный шлюз на `127.0.0.1`, который отдаёт WorkBuddy AI через OpenAI- и Anthropic-совместимые HTTP-API.

Всё работает только на loopback: шлюз слушает `127.0.0.1`, наружу не светится.

## Возможности

- OpenAI-совместимые ручки: `GET /v1/models`, `POST /v1/chat/completions`, `POST /v1/responses`
- Anthropic-совместимая ручка: `POST /v1/messages`
- Веб-панель управления на `/admin` с переключателем языка RU / EN / ZH (по умолчанию — русский)
- Пул OAuth-аккаунтов WorkBuddy с шифрованным хранилищем (AES-256-GCM) и выборкой `round-robin` или `random`
- Проброс стриминга от апстрима без таймаутов на стороне шлюза

## Требования

- Windows 10/11 (или Linux/macOS с bash)
- Node.js 20 или новее
- git
- pnpm — ставится скриптом развёртывания автоматически

## Быстрый старт на Windows

Одной строкой в PowerShell — из каталога, куда нужно положить проект:

```powershell
irm https://raw.githubusercontent.com/MixxxGit/WkBdy2api/feature/admin-i18n-ru-default/deploy.ps1 -OutFile deploy.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
```

Скрипт сам проверит Node.js, поставит pnpm при отсутствии, склонирует репозиторий в `.\WkBdy2api`, поставит зависимости, создаст `.env` со случайным API-ключом и ключ шифрования хранилища аккаунтов, прогонит `typecheck` и тесты, поднимет сервер и выведет адреса и ключ.

Полезные параметры:

```powershell
# не запускать сервер после развёртывания
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -NoStart

# пропустить typecheck и тесты
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -SkipTests

# развернуть в другой каталог
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -InstallDir C:\tools\wkbdy2api
```

## Ручная установка

```bash
git clone --branch feature/admin-i18n-ru-default https://github.com/MixxxGit/WkBdy2api.git
cd WkBdy2api
pnpm install
cp .env.example .env        # дальше выставить WKB2API_API_KEY
pnpm dev                    # или pnpm start
```

> Если `pnpm install` падает с `ERR_PNPM_IGNORED_BUILDS`, разрешите сборку esbuild:
> `pnpm approve-builds --yes --all` (в репозитории уже лежит `pnpm-workspace.yaml` с `allowBuilds: esbuild: true`).
> Без этого у tsx не будет бинарника esbuild и сервер не запустится.

## Запуск и остановка (Windows)

| Действие | Команда |
| --- | --- |
| Запуск | `start.bat` |
| Остановка | `stop.bat` |
| Перезапуск | `stop.bat && start.bat` |
| Логи | `logs\server.log` |

`start.bat` читает `HOST` и `PORT` из `.env`, поднимает сервер в свёрнутом окне и пишет pid в `.server.pid`. `stop.bat` снимает процесс по этому pid (или по слушателю порта) и удаляет pid-файл.

## Конфигурация

Все настройки — в `.env` (создаётся из `.env.example`):

| Переменная | Назначение |
| --- | --- |
| `WKB2API_API_KEY` | обязательный ключ для всех клиентов шлюза, минимум 16 символов |
| `HOST` | адрес прослушивания, по умолчанию `127.0.0.1` |
| `PORT` | порт, по умолчанию `7891` |
| `LOG_LEVEL` | `fatal`, `error`, `warn`, `info`, `debug` |
| `WKB2API_UPSTREAM_URL` | апстрим WorkBuddy |
| `WKB2API_UPSTREAM_UA` | User-Agent для апстрима |
| `WKB2API_ACCOUNT_STORE_PATH` | файл зашифрованного хранилища аккаунтов |
| `WKB2API_ACCOUNT_STORE_KEY_FILE` | файл ключа шифрования (32 байта, raw или base64) |
| `WKB2API_CREDENTIALS_PATH` | локальный файл credential WorkBuddy для импорта аккаунтов |
| `WKB2API_MODEL_ALIASES` | JSON с алиасами моделей для `/v1/messages` |

`account-store.key` — это ключ к зашифрованному пулу аккаунтов. Он в `.gitignore`, его нельзя коммитить и терять: без него `data/accounts.enc` не расшифровать.

## Панель управления

Открывается по адресу `http://127.0.0.1:7891/admin` (страница сама отдаётся без ключа, все данные за `/admin/api/` требуют ключ). В панели:

- статус пула аккаунтов и статистика запросов
- добавление аккаунта по токену с проверкой на апстриме, удаление аккаунта по метке
- импорт аккаунтов из локального файла credential WorkBuddy
- OAuth-вход через встроенный брокер
- выбор стратегии `round-robin` или `random`
- глобальный выбор контекстного окна; модели, не поддерживающие выбранный размер, автоматически берут свой максимальный
- переключатель языка: русский (по умолчанию), английский, китайский

## Использование API

```bash
curl http://127.0.0.1:7891/v1/models \
  -H "Authorization: Bearer $WKB2API_API_KEY"
```

```bash
curl http://127.0.0.1:7891/v1/chat/completions \
  -H "Authorization: Bearer $WKB2API_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"default-model","messages":[{"role":"user","content":"Привет"}]}'
```

## Управление reasoning

В OpenAI-совместимых запросах поддерживается `reasoning_effort`:

`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`

Значение пробрасывается в тело запроса к WorkBuddy. Настройки `thinking` из Anthropic-совместимого API конвертируются так:

| `thinking` | `reasoning_effort` |
| --- | --- |
| `disabled` | `none` |
| `adaptive` | `high` |
| budget < 2048 | `low` |
| budget >= 2048 | `medium` |
| budget >= 8192 | `high` |
| budget >= 32768 | `xhigh` |

## Метаданные моделей

`GET /v1/models` возвращает модели в формате OpenAI. Свойства WorkBuddy лежат в `x_workbuddy`:

- поддержка reasoning и режим «только reasoning»
- поддерживаемые уровни `reasoning_effort`
- размер контекстного окна по умолчанию
- все значения из `contextWindow.supportedLengths`
- поддержка изображений и вызовов инструментов
- лимиты входных и выходных токенов

В списке моделей показываются цены WorkBuddy в Credits. У моделей с несколькими `contextWindow.supportedLengths` в панели есть выбор контекста — это глобальная настройка уровня пула аккаунтов, после сохранения её используют все аккаунты.

## Разработка

```bash
pnpm install
pnpm dev          # tsx watch
pnpm typecheck    # tsc --noEmit
pnpm test         # vitest run
```

Тесты читают `wb_v3config_live.json` — снимок конфигурации моделей. В репозитории лежит `wb_v3config.public.json`; скрипт развёртывания сам делает из него копию с нужным именем. Для ручного запуска тестов:

```bash
cp wb_v3config.public.json wb_v3config_live.json
```

## Docker

```bash
docker compose up --build
```

Нужны `.env` с `WKB2API_API_KEY` и файл `./account-store.key` (32 байта). Данные аккаунтов живут в volume `wkbdy2api-data`.

## Безопасность

- Шлюз слушает только loopback. Для доступа по сети ставьте перед ним TLS-прокси.
- Ключ шифрования хранилища аккаунтов храните отдельно от `data/accounts.enc`.
- Токены аккаунтов в логах и панели не отображаются, только их форма и срок действия.
