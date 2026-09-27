# Операции

- Запуск задачи: `bin/task.sh new <run-id>` → положить TASK.json в
  `runs/<run-id>/tasks/` → `bin/night_run.sh runs/<run-id>`; или через
  Intake: `bin/intake.py message "…" --project <id>` → `launch <intake_id>`.
- Ожидание: `bin/task.sh wait <run-id>`.
- Стоп (мягкий): `bin/task.sh stop <run-id>` (файл STOP; завершение на
  границе хода).
- Отчёт вручную: `bin/report.sh [--no-send] runs/<run-id>`.
- Проблемы: `runs/<run-id>/<task>/failure_evidence.txt`, `gate_evidence.txt`,
  `model_calls.jsonl`; самопроверка: `bin/selftest.sh --full`.
- Завершённые run-id не переиспользуются: продолжение — новый run-id
  (Intake делает это сам через `from-result`).

Инциденты и откат: у ядра нет доступа к production (guard_roots + OWNER
границы), поэтому откат исполнения = удаление task-worktree/ветки; ничего в
основных чекаутах не меняется.
