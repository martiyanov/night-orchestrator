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
- Отчёты оркестратора доставляются владельцу (report.sh), OWNER PASS/GO —
  словами владельца, кнопки с ними не связаны.

Шаблон навыка: `examples/skills/example-project/`.
