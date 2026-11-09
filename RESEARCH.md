# Дослідження компонентів

Перевірено 8 листопада 2026 року. Мета дослідження — обрати стабільні офіційні
компоненти, які працюють у Docker Desktop на Windows 11 amd64.

## Tunnel

### Обрано: cloudflared

- Офіційний репозиторій: [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared).
- Репозиторій містить сам клієнт tunnel, а не лише SDK.
- Є офіційний Docker image і Quick Tunnel без окремого акаунта чи власного домену.
- Тег `2026.10.7` підтверджений у Git; образ перевірений і зафіксований у Compose
  разом із digest `sha256:4955524a…c5ba`.
- Для сумісності з Docker Desktop використовується транспорт HTTP/2. Tunnel
  звертається лише до внутрішнього nginx `http://proxy:8080`.

Quick Tunnel дає випадкову адресу й не має вимог доступності production-сервісу.
Це прийнятно для уроку, де launcher реєструє нову адресу після запуску.

### Fallback: ngrok

- Офіційний відкритий репозиторій [ngrok/ngrok-go](https://github.com/ngrok/ngrok-go)
  є SDK для вбудовування ingress у Go-програми; актуальний перевірений тег —
  `v2.4.0`.
- Це не готова заміна CLI для нашого PowerShell + Compose пакета.
- Готовий ngrok agent потребує окремого акаунта, authtoken і перевірки поточних
  тарифних обмежень.

Тому ngrok записаний як ручний майбутній fallback, але не входить до MVP. Такий
вибір не додає другий секрет і другий нестабільний шлях запуску для початківця.

## n8n і proxy

- n8n: офіційний репозиторій [n8n-io/n8n](https://github.com/n8n-io/n8n), тег
  `n8n@3.1.0`. Офіційні CLI-команди `import:credentials`, `import:workflow`,
  `export:workflow` і `publish:workflow` перевіряються інтеграційним тестом.
- Task runners: офіційний образ тієї самої версії `3.1.0`; runner винесений із
  процесу n8n відповідно до актуального режиму external.
- Proxy: офіційний Docker image nginx `1.30.6-alpine`. У пакеті немає складної
  конфігурації ingress: лише один точний POST-маршрут, secret header, ліміт
  розміру й частоти.

Повні image references і SHA-256 digest зберігаються в [compose.yaml](compose.yaml).
Оновлення версій виконується свідомо: спочатку тести, потім зміна тегу й digest.
