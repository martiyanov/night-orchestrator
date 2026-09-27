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

Production deploy остаётся запрещённым универсальными правилами guard
(паттерны deploy, guard_roots) для ВСЕХ проектов; `project_actions` —
точечное разрешение, а не ослабление общих запретов.

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
