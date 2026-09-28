# Конфигурация

Все конфиги — JSON в `config/`, создаются из `*.example.json`.

## projects.json — реестр проектов
`repo` (чекаут), `worktree_root` (task-worktrees), `default_branch`,
`bootstrap` (доки для контекста исполнителя), `test_command`,
`test_venv_python`, `forbidden_paths` (запрет записи/чтения), `guard_roots`
(целые недоступные корни, напр. production), `forbidden_operations`
(документируемые инварианты).

### project_actions — точные проектные разрешения (необязательно)
Проект может описать действия, разрешённые в writable-режиме ТОЛЬКО при
точном совпадении команды (например, штатный staging deploy):

```json
"project_actions": {
  "staging_deploy": {
    "description": "штатный staging deploy; production не затрагивается",
    "mode": "writable",
    "argv": ["bash", "ops/deploy-staging.sh"],
    "env_from_model": [
      {"name": "STAGING_SHA", "pattern": "^[0-9a-f]{40}$"}
    ],
    "env_fixed": {
      "STAGING_ENV_FILE": "~/src/example-project/.env.staging"
    }
  }
}
```

Гарантии (детерминированный guard, не промпты):
- команда обязана совпасть с spec токен-в-токен: ведущие env-присваивания
  строго по `env_from_model` (имя + pattern), `argv` без добавок — любые
  опции, `;`/`&&`/`|`/`$()`/редиректы ломают совпадение и дают DENY;
- путь скрипта обязан лежать внутри task-worktree, быть обычным файлом и
  не симлинком; guard_roots не должны встречаться в токенах;
- только writable-режим; проекты без `project_actions` не меняют поведение;
- `env_fixed` добавляет оркестратор при исполнении (значения из реестра;
  `~/` раскрывается, `$VAR` — нет): секреты/канонические пути не проходят
  через команду модели;
- разрешённое действие фиксируется в audit trail (`PROJECT_ACTION_ALLOWED`).

### owner-authorized actions (0.1.6)
Действие с полем `"owner_auth": {"sha_env": "AG_ACCEPT_SHA"}` исполняется
ТОЛЬКО при активной authorization владельца: `bin/owner_auth.py create/check/consume`
(состояние — `authorizations/AUTH-*.json`). Authorization привязана к
project+action+SHA(40hex), одноразовая (consume после успешного исполнения),
идемпотентный create; `--requires-prior-action` связывает цепочки
(production_go требует executed owner_accept того же SHA — OWNER PASS не
даёт production автоматически). Без authorization точная форма действия —
FATAL DENY с точной причиной. Audit: PROJECT_ACTION_ALLOWED /
PROJECT_ACTION_EXECUTED (+consume) в log.jsonl прогона.

Production deploy остаётся запрещённым универсальными правилами guard
(паттерны deploy, guard_roots) для ВСЕХ проектов; `project_actions` —
точечное разрешение, а не ослабление общих запретов.

### UX-роли и кнопки владельца (PROACTIVE-UX-1, 0.2.0)
Необязательное поле действия `"ux_role": "staging" | "accept" |
"production"` связывает проектное действие с кнопкой следующего шага
(guard это поле игнорирует; без него кнопки этого типа проекту не
предлагаются). Кнопки отчёта включаются `"buttons": true` в
`config/report.json` (переопределяется env `ORCH_REPORT_BUTTONS`).
Обработка нажатий — `bin/owner_action.sh handle orch1:<act>:<run_id>`
(обычно вызывается проектным навыком; см. docs/EXECUTION_LIFECYCLE.md
и docs/SAFETY_MODEL.md, контур 7).

## permissions.json — политика исполнения
`execution_profile` (fast/balanced/economy) и per-profile бюджеты:
max_agent_turns, task_hard_budget_minutes, exploration limits
(max_read_calls_before_write, max_exploration_minutes, max_repeat_reads,
max_compactions_before_escalation), post_write_extra_turns, лимиты history.
Глобально: `DEPLOY_ENABLED` (для автономной работы — всегда false),
retry-политика, таймауты команд.

## routing.json — модели по ролям
См. docs/MODEL_ROUTING.md.

## Переменные окружения
- `ORCH_ROOT` — корень установки (по умолчанию
  `$HOME/.local/share/night-orchestrator`);
- `INTAKE_PROJECT` — проект по умолчанию для Intake;
- `INTAKE_DIR` — каталог состояний Intake;
- `ORCH_REPORT_TOKEN` — команда/значение токена для отправки отчётов
  (если не задан — используется источник по умолчанию);
- `MOCK_FIXTURE` — фикстуры моделей для самопроверки.

Никакие абсолютные пути хоста в коде не зашиты; всё через `ORCH_ROOT` и
реестр.
