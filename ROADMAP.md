# Roadmap реалізації

Оновлено 8 листопада 2026 року.

Правило роботи: документація → тест компонента → реалізація → перевірка.
Секрети не передаються в чат. Позначка **реалізовано** означає, що код існує;
окрема колонка показує межі фактичної перевірки.

| Етап | Робота | Стан | Перевірка |
| --- | --- | --- | --- |
| 0 | ТЗ, архітектура, план тестів; Docker користувача | Завершено | Docker Engine, Compose і `hello-world` підтверджені на HP Pavilion |
| 1 | Версії, tunnel, proxy, CLI bootstrap і передавання секретів | Завершено | Версії та digest зафіксовані; офіційний CLI і Quick Tunnel створення перевірені |
| 2 | Fixtures і тести конфігурації, proxy, workflow та lifecycle | Завершено частково | Автотести створені; mock Telegram API і Windows PowerShell execution ще потрібні |
| 3 | Compose, локальний n8n, external runners, volume і bootstrap | Реалізовано | Compose readiness, runner registration, CLI import/export/publish перевіряються в Linux |
| 4 | nginx, cloudflared, webhook secret, allowlist і deduplication | Реалізовано | Локальний proxy пройдено; зовнішній HTTP до Quick Tunnel заблокований політикою хмарного тестового середовища |
| 5 | WinForms launcher і керування життєвим циклом | Реалізовано | Синтаксис перевірено parser-ом; потрібний запуск у Windows PowerShell 5.1 |
| 6 | README, troubleshooting, backup/restore і VPS-план | Завершено | Docker volume archive перевіряється; DPAPI restore потребує Windows |
| 7 | Приймання на HP Pavilion із реальним ботом | Очікує користувацького середовища | Потрібні T01–T17, 20 повідомлень, RAM і час відповіді |

Поточна точка: пакет і доступні автоматизовані перевірки зібрані. Наступний
етап — запуск [start.cmd](start.cmd) на цільовому Windows-ПК, локальне введення
токена й проходження [WINDOWS_ACCEPTANCE.md](WINDOWS_ACCEPTANCE.md). Токен не
потрібно надсилати розробнику або додавати в репозиторій.
