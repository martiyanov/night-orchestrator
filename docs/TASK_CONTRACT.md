# Контракт TASK

Схема: `contracts/TASK.schema.json`. Обязательные поля: `project, task_id,
goal, risk, mode, allowed_paths, forbidden_paths, bootstrap, checks,
owner_gates`. Важно: `checks` — список ОБЪЕКТОВ `{name, command?,
timeout_seconds?}` (исполняемые проверки), не строки.

- `mode`: read_only (проверки/исследование) | writable (изменения в
  allowed_paths).
- `risk`: LOW/MEDIUM/HIGH (MEDIUM+ проходит рецензию).
- `requires_full_offline_gate`: true — перед RESULT гоняется полный набор
  проверок проекта (`test_command`).
- Примеры: `examples/TASK.example.json`; правила формирования — docs/TASK_CREATION.md.
