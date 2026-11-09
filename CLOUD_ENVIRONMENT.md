# Робота у хмарному середовищі Codex

Репозиторій: `/workspace/n8n`. Використовуйте наявний checkout і не створюйте
worktree без прямого запиту користувача. Перед редагуванням перевіряйте `git status`.

Окрема інсталяція залежностей не потрібна: швидкі тести використовують Python 3
і Node.js середовища, Docker-тести — керований Docker daemon. Постійний сервер
між задачами не потрібний.

Швидка перевірка:

```bash
cd /workspace/n8n
python3 tests/run_tests.py
```

Перевірки за типом змін:

```bash
RUN_DOCKER_TESTS=1 python3 tests/run_tests.py
RUN_COMPOSE_TESTS=1 python3 -m unittest -v tests.test_compose_integration
RUN_N8N_TESTS=1 python3 -m unittest -v tests.test_n8n_integration
RUN_TUNNEL_TESTS=1 python3 -m unittest -v tests.test_proxy_integration.PublicTunnelIntegrationTests
```

Тести створюють лише ресурси з префіксом `coursekit-...-test`. Після них треба
перевірити, що такі контейнери, мережі й volumes прибрані.

Хмарна мережа дозволяє cloudflared створити Quick Tunnel, але може блокувати
зворотний HTTPS-запит до випадкового `trycloudflare.com` із кодом 403. Це
обмеження середовища фіксується як BLOCKED, а публічний E2E проходиться на Windows.

Не вводьте реальний Telegram token у хмарі. WinForms, Windows PowerShell 5.1,
DPAPI, шлях із кирилицею та реальний Telegram перевіряються за
[WINDOWS_ACCEPTANCE.md](WINDOWS_ACCEPTANCE.md) на цільовому ноутбуці.
