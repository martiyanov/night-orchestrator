# Конфигурация

Все конфиги — JSON в `config/`, создаются из `*.example.json`.

## projects.json — реестр проектов
`repo` (чекаут), `worktree_root` (task-worktrees), `default_branch`,
`bootstrap` (доки для контекста исполнителя), `test_command`,
`test_venv_dir`, `forbidden_paths` (запрет записи/чтения), `guard_roots`
(целые недоступные корни, напр. production), `forbidden_operations`
(документируемые инварианты).

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
