# Контракт RESULT

Схема: `contracts/RESULT.schema.json`. Каждый прогон заканчивается
машинно-читаемым RESULT:

- статусы: READY_FOR_OWNER_PASS / NO_CHANGE_REQUIRED / NEEDS_OWNER_INPUT /
  BLOCKED / FAILED / PERMISSION_VIOLATION (+ legacy-алиасы);
- обязательные смысловые поля: summary, files_changed, checks, next;
- факты раннера: reason, evidence[], tests[], writes, commit_sha,
  next_action, attempts, model_calls (без текстов промптов).

Дисциплина: невалидный RESULT → один repair → структурный BLOCKED из фактов.
Заглушек нет. Пример: `examples/RESULT.example.json`.
