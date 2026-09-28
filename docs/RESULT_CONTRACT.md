# Контракт RESULT

Схема: `contracts/RESULT.schema.json`. Каждый прогон заканчивается
машинно-читаемым RESULT:

- статусы: READY_FOR_OWNER_PASS / NO_CHANGE_REQUIRED / NEEDS_OWNER_INPUT /
  BLOCKED / FAILED / PERMISSION_VIOLATION (+ legacy-алиасы);
- обязательные смысловые поля: summary, files_changed, checks, next;
- факты раннера: reason, evidence[], tests[], writes, commit_sha,
  next_action, attempts, model_calls (без текстов промптов);
- `next_actions` (необязательно, PROACTIVE-UX-1): подсказки следующих
  шагов для человеческого UI — массив `{id, action, label?,
  requires_confirmation?}`; `action` — внутреннее имя project_action или
  null («никакого машинного действия»). Авторитетный источник допустимых
  действий — вычисляемый ядром жизненный цикл (`bin/owner_action.sh`),
  а не текст модели; consumers игнорируют неизвестные элементы.

Дисциплина: невалидный RESULT → один repair → структурный BLOCKED из фактов.
Заглушек нет. Пример: `examples/RESULT.example.json`.
