# Интеграция с OpenClaw

OpenClaw — личный ассистент с несколькими проектами; Night Orchestrator —
универсальный исполнитель. Связка — проектный навык:

```
OpenClaw main → project skill (wake-word, напр. «Найт:») → bin/project.sh
  → intake.py --project <id> → Task/вопросы → ядро
```

- Навык кладётся в `<workspace агента>/skills/<name>/SKILL.md`; индексация
  автоматическая (проверка: `openclaw skills list --agent main`).
- Изоляция: навык активируется только wake-word/явным контекстом; личные
  сообщения идут мимо; неоднозначное — вопрос-подтверждение.
- Безопасный вход: один wrapper `bin/project.sh` (Allow-Always на его
  префикс), никаких прямых python3 из навыка.
- Отчёты оркестратора доставляются владельцу (report.sh).

## Кнопки следующего шага (PROACTIVE-UX-1, 0.2.0)

Владелец не должен знать внутренние команды (OWNER PASS/GO, SHA): после
значимого этапа система сама предлагает понятные следующие шаги.

- `report.sh` при `buttons: true` (config/report.json) прикладывает к
  отчёту inline-кнопки с `callback_data = orch1:<action>:<run_id>`
  (подписи человеческие; допустимые действия вычисляются из статуса
  RESULT и реестра проекта — см. docs/EXECUTION_LIFECYCLE.md).
- Нажатие кнопки платформа владельца доставляет агенту текстом
  (OpenClaw: «callback_data: orch1:…» pass-through). Навык передаёт его
  в ЕДИНЫЙ вход wrapper'а (`project.sh callback "<data>"`), тот — в
  `bin/owner_action.sh handle`, который перепроверяет состояние
  (stale/prior/SHA/уже-выполнено) и исполняет ТОЛЬКО зарегистрированное
  действие через owner_auth (см. docs/SAFETY_MODEL.md, контур 7).
- Ответ wrapper'а (человеческий текст) пересылается владельцу как есть;
  блок `===NEXT_OFFER=== {text, buttons}` — отправляется как новое
  сообщение с кнопками (Telegram message action + presentation;
  требуется `channels.telegram.actions.sendMessage`).
- Правила языка: внутренние термины (OWNER PASS/GO, project_action,
  SHA, PERMISSION_VIOLATION, ALREADY_EXECUTED) владельцу не
  показываются — только человеческие формулировки; техника доступна в
  «📋 Подробнее»/диагностике. Навык никогда не конструирует callback_data
  сам и не выполняет git/deploy в обход wrapper'а.

Шаблон навыка: `examples/skills/example-project/`.

## Приоритет lifecycle-фраз над intake (PROACTIVE-UX-RELEASE-ROUTING-1, 0.2.2)

Решение владельца по жизненному циклу — не новая задача. Навык ОБЯЗАН
до intake прогонять `bin/owner_phrase.py --project <id> --text "<сообщение>"`
(обычно через подкоманду wrapper'а): INTENT=none → обычный intake-путь;
INTENT=accept/deploy → выполнить ДОСЛОВНО команду из блока ===EXECUTE===
(orch1:pass/deploy) и переслать ответ; INTENT=question — задать вопрос
владельцу (список кандидатов / «сначала приёмка» / «нужен релизный
коммит»). Никогда не переформулировать разрешение в «запусти …» и не
создавать coding-run для merge/deploy. Ответ различает SHA: принятый на
staging / текущая main / в рабочем боте — не называть фича-коммит
«проверенной версией», если поверх есть обязательный fix.
