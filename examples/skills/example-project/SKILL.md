---
name: example-project
description: Example project skill showing the generic pattern — OpenClaw assistant → project skill → Intake → Night Orchestrator. Replace project id, wake word and paths for your own project.
---

# Example-project — шаблон проектного навыка

Тонкий маршрутизатор: распознать явное обращение к проекту → вызвать
ЕДИНСТВЕННЫЙ вход `bin/project.sh` → переслать владельцу вопросы/статусы.

## Активация
1. Префикс «Найт:» / «Найт,» / «/night» → запрос к проекту (убрать префикс).
2. Диалог уже в контексте проекта → продолжать без префикса.
3. Похоже, но не явно → предложить продолжить в контексте проекта и ждать.
4. Личные запросы → обычный ассистент, навык не вызывается.

## Действия (только wrapper `bin/project.sh`)
- `bin/project.sh route "<текст>"` — проектное ли сообщение (детерминированно);
- `bin/project.sh intake "<текст>"` — новое сообщение проекту;
- `bin/project.sh answer "<ответ>"` — ответ владельца на вопрос;
- `bin/project.sh status` — состояние/ожидающие;
- `bin/project.sh cancel` / `bin/project.sh backlog` — отменить / в бэклог;
- `bin/project.sh launch <intake_id>` — запуск готовой задачи.

## Границы
- Никаких прямых python3/run_task/deploy/push/merge из навыка.
- OWNER PASS и OWNER GO — только явные слова владельца.
- project_id — в project.json навыка; профиль — в реестре оркестратора.
