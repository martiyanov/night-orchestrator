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

## Жизненный цикл владельца (PROACTIVE-UX-1, 0.2.0)

После завершения прогона детерминированный слой `bin/owner_action.sh`
вычисляет состояние и ДОПУСТИМЫЕ следующие шаги (кнопки отчёта
`orch1:<action>:<run_id>`; подписи — человеческие, внутренние имена
действий владельцу не показываются):

```
A выполняется         → действий нет (только статус)
B зелёные проверки, staging не выкладывался (роль staging в реестре)
                      → [🧪 Выложить тестовую версию] [📋 Подробнее]
C staging выложен / готово к приёмке
                      → [✅ Принять изменения] [🔧 Вернуть на доработку] [📋 Подробнее]
D изменения приняты (owner_accept executed)
                      → [🚀 Выложить в рабочий бот] [⏸ Позже] [📋 Подробнее]
E production обновлён (production_go executed)
                      → «Готово. Новая версия работает в рабочем боте.»
F блок/ошибка         → объяснение + [📋 Подробнее] (ложных действий нет)
G повтор выполненного → нейтральный статус, НЕ ошибка (ALREADY_EXECUTED)
stale (состояние изменилось с момента показа кнопки)
                      → «предложение устарело» + актуальный статус,
                        ничего не исполняется
```

Кнопка = явное решение владельца (семантика OWNER PASS / OWNER GO).
Исполнение: `owner_auth.py create` (единственный механизм авторизации,
второго нет) → зарегистрированное project_action точной формы (argv/env
из реестра; SHA — из structured state прогона) → consume после успеха +
audit в log.jsonl (PROJECT_ACTION_ALLOWED / PROJECT_ACTION_EXECUTED /
PROJECT_ACTION_FAILED / OWNER_DECISION_RECORDED). Prior-action и
SHA-границы проверяются повторно при каждом нажатии; HEAD основной ветки
для production обязан совпадать с принятым SHA. «Вернуть на доработку» —
marker-решение `.owner_decision.json` без git-действий.

Команды: `bin/owner_action.sh status <run_id>` (жизненный цикл + шаги),
`bin/owner_action.sh handle <callback_data>` (нажатие кнопки; формат
строго `orch1:(pass|fix|details|staging|deploy|defer|status):<run_id>`).
Выход: человеческий текст для владельца + машинный блок
`===OWNER_ACTION_RESULT=== {json}` (state/actions) и после успешного
шага — `===NEXT_OFFER=== {text, buttons}` для следующего сообщения.
Отчёт (`report.sh`) прикладывает кнопки при `buttons: true`
(config/report.json) и всегда пишет машинный `report_actions.json`
(run_id, project, sha, branch, state — основа stale-сверки).

## Lifecycle выпуска (PROACTIVE-UX-RELEASE-FLOW-2, 0.3.0)

`bin/release_flow.py` — детерминированная state machine (состояние ВСЕГДА
вычисляется из фактов, не из текста):

```
A DEVELOPMENT → (run: STAGING_READY → приёмка кода owner_accept)
C CODE_ACCEPTED → D RELEASE_NEEDED --prepare--> E RELEASE_CANDIDATE_READY
  --accept(exact RC)--> F RELEASE_ACCEPTED → G PRODUCTION_READY (main==RC)
  --deploy(production_go exact RC)--> H PRODUCTION_DONE
```

SHA-модель (различаются всегда): accepted_code_sha / main_sha /
release_candidate_sha / production_sha.

`prepare` — первоклассный примитив подготовки релиза: только release-файлы
(allowlist), один коммит (VERSION + черновик заметок), канонический gate
до коммита, идемпотентность, stale-дрейф-контроль (state/, docs/ — можно;
app-код — STOP до повторной приёмки). Не требует отдельной owner_auth:
не повышает риск, вызывается только явной командой владельца. Deploy —
по-прежнему точная авторизация exact RC (release_accept → production_go).

Callback-неймспейс выпуска: `orch1:release-(prepare|accept|deploy|defer|
details|status):(now|<rc7>|x)` — обрабатывается release_flow.py handle
(stale/already-safe).
