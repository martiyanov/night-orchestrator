# Жизненный цикл исполнения

```
TASK.json → task.sh new <run-id> → night_run.sh
  → preconditions (реестр, чистый основной чекаут, DEPLOY_ENABLED=false)
  → worktree + ветка night/<TASK>-<ts>
  → попытки исполнителя:
       чтение (лимит) → запись (открывает post-write бюджет)
       → тесты → FULL-гейт по TASK.requires_full_offline_gate
       → [review для MEDIUM/HIGH] → RESULT
  → RESULT-дисциплина (repair ≤1, структурный BLOCKED при повторном сбое)
  → отчёт владельцу (всегда, идемпотентно)
  → run завершён; merge/push — только OWNER PASS, deploy — только OWNER GO
```

Статусы финала: READY_FOR_OWNER_PASS, NO_CHANGE_REQUIRED,
NEEDS_OWNER_INPUT, BLOCKED, FAILED, PERMISSION_VIOLATION.

Ожидание завершения: `bin/task.sh wait <run-id>` — адаптивный опрос,
мгновенный выход на терминальное состояние.
