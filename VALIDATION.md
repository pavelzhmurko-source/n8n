# Звіт перевірки MVP

Дата: 8 листопада 2026 року.

Статуси: **PASS** — перевірка пройшла; **PARTIAL** — пройшла незалежна частина;
**BLOCKED** — потрібне інше середовище або реальний Telegram; **NOT RUN** — ще не запускалося.

## Середовища

| Середовище | Доказ |
| --- | --- |
| HP Pavilion 14-ce0064ur, Windows 11 Home 25H2, ~8 ГБ RAM | **PASS:** WSL 3.0.3, Docker Desktop 4.98.0, Engine 29.9.2, Compose 5.6.1 і `hello-world` за скриншотами користувача |
| Керована Linux-сесія, amd64 | Docker Engine 29.9.2; перевірка Compose, образів, nginx, n8n CLI, task runners і volume archive |

## Автоматизовані результати

| Перевірка | Результат | Що доведено |
| --- | --- | --- |
| `python3 -m unittest -v tests.test_package tests.test_secret_hygiene` | **PASS**, 13 тестів | Склад пакета, pinned image digest, loopback port, Compose render із runtime values, workflow guard, retries, відсутність секретів |
| `RUN_DOCKER_TESTS=1` для `tests.test_proxy_integration.ProxyIntegrationTests` | **PASS**, 2 тести | Правильний POST дає 204; хибний secret і GET — 403; REST/test routes — 404; тіло >1 МБ — 413 |
| `RUN_COMPOSE_TESTS=1 python3 -m unittest -v tests.test_compose_integration` | **PASS**, 2 тести, 100.631 с | n8n healthy, external runner зареєстрований, runner token читається з файла, proxy не має host port |
| `RUN_N8N_TESTS=1 python3 -m unittest -v tests.test_n8n_integration` | **PASS**, 2 тести, 386.348 с | Owner setup, credential/workflow import, export, publish, реєстрація production webhook і повторний старт контейнера |
| `RUN_DOCKER_TESTS=1` для backup і secret hygiene | **PASS**, 4 тести, 281.605 с | Архів volume створюється, розгортається у staging volume й містить ту саму базу; secret scan пройдено |
| PowerShell tree-sitter parse | **PASS**, 5 файлів | У module, launcher, backup, restore і test runner немає синтаксичних ERROR-вузлів |
| `RUN_TUNNEL_TESTS=1` | **PARTIAL** | cloudflared отримав адресу `trycloudflare.com`; вихідний запит назад до неї заблокований proxy хмарної сесії з 403, тому HTTP через публічну адресу тут **BLOCKED** |

Тест n8n виявив, що `/healthz/readiness` може стати готовим раніше за індекс
production webhook. Після цього launcher і тест отримали окреме очікування
реєстрації webhook. Повторна перевірка пройшла.

## Покриття T01–T17

| ID | Статус | Межа доказу |
| --- | --- | --- |
| T01 | PARTIAL | Обробка помилки й preflight реалізовані; Docker-off GUI потрібен на Windows |
| T02 | PARTIAL | Compose і n8n bootstrap PASS; Telegram setWebhook із реальним токеном BLOCKED |
| T03 | BLOCKED | Потрібен бот користувача на Windows |
| T04 | PARTIAL | У Docker proxy PASS; зовнішній запит до Quick Tunnel заблокований хмарною мережею |
| T05 | PARTIAL | Хибний secret локально відхилено; публічна перевірка очікує Windows |
| T06 | PARTIAL | Unit-тест відхиляє чужий ID, group і unsupported message; malformed JSON через повний tunnel очікує Windows |
| T07 | PARTIAL | Повтор `update_id` у guard відхилено; збереження після реального restart перевіряється E2E |
| T08 | PARTIAL | CLI export/import і логіка без перезапису є; подвійний клік GUI очікує Windows |
| T09 | PARTIAL | Контейнер і volume переживають restart у тесті; штатна Windows-кнопка ще не пройдена |
| T10 | PARTIAL | Quick Tunnel URL отримано й заміна старого URL реалізована; сон/обрив очікує Windows |
| T11 | PARTIAL | Чужий webhook не перезаписується в коді; реальна або mock API перевірка очікує Windows |
| T12 | PARTIAL | Telegram node має максимум три спроби; відмова Bot API не прогнана з mock server |
| T13 | PASS | Автоматичний scan не знайшов Telegram token або private key поза test fixture |
| T14 | PARTIAL | Таймаути й перевірка порту реалізовані; відображення у WinForms очікує Windows |
| T15 | BLOCKED | Потрібний Windows-шлях із пробілами та кирилицею |
| T16 | PARTIAL | Docker archive/staging PASS; DPAPI, ZIP manifest і повний restore очікують Windows |
| T17 | PARTIAL | nginx body limit PASS; 20 реальних Telegram-повідомлень, RAM і latency очікують Windows |

## Обов'язкове приймання на Windows

До повного статусу **готово** треба пройти [WINDOWS_ACCEPTANCE.md](WINDOWS_ACCEPTANCE.md):
WinForms, DPAPI, реальний setWebhook/response, новий URL після restart, backup/restore,
20 повідомлень, використання RAM і шлях із кирилицею. Токен вводиться лише локально.

## Відомі межі

- Quick Tunnel має тимчасову адресу й не призначений для цілодобового production.
- ngrok описаний як майбутній fallback і не реалізований.
- DPAPI backup відновлюється тим самим користувачем Windows; для VPS потрібен
  окремий захищений експорт ключів.
- Linux-перевірка PowerShell parser-ом не замінює виконання Windows PowerShell 5.1.
