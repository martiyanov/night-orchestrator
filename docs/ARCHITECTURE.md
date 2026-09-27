# Архитектура

```
Владелец (чат/CLI)
  │
  ▼
проектный навык (пример: examples/skills/example-project)   ← тонкий маршрутизатор
  │  bin/project.sh (единственный узкий вход)
  ▼
Intake Gate (bin/intake.py)          ← классификация, уточнения (1–3 вопроса),
  │                                    состояние INTAKE-*.json, TASK-формирование
  ▼
Night Orchestrator v1 (ядро)
  ├─ bin/task.sh new/launch/wait      ← run-каталоги, канонический запуск
  ├─ bin/night_run.sh                 ← пакетный прогон задач
  ├─ bin/run_task.sh                  ← цикл исполнения: попытки, бюджеты,
  │                                     эскалация моделей, RESULT-дисциплина
  ├─ bin/gates.sh                     ← детерминированные safety-гейты (shell)
  ├─ bin/model_call.sh                ← вызовы моделей по ролям + evidence
  │                                     + детектирование reasoning-budget
  ├─ bin/report.sh                    ← человеческий отчёт владельцу
  └─ contracts/ TASK/RESULT/INTAKE    ← машинные контракты
```

Слои и их границы:
- **Навык проекта** знает только wake-word, project_id и wrapper. Он не
  исполняет код проекта.
- **Intake** проектно-нейтрален: превращает смысл сообщения в TASK или
  backlog-черновик; состояние уточнений живёт в нём.
- **Ядро** универсально: любой проект из реестра `config/projects.json`,
  любые модели из `config/routing.json`.

Директории данных (не часть кода): `runs/` (история прогонов),
`intake/` (состояния приёма) — генерируются на месте, в git не попадают.
