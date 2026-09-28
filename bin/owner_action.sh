#!/usr/bin/env bash
# owner_action.sh — детерминированный owner-слой UX (PROACTIVE-UX-1).
#
# Замыкает кнопочный цикл «отчёт → решение владельца → следующий шаг» БЕЗ
# изменений модели безопасности:
#   - владелец выражает решение кнопкой (callback_data "orch1:<act>:<run_id>",
#     доставляется платформой владельца, напр. OpenClaw pass-through);
#   - решение превращается в ту же единственную authorization
#     (bin/owner_auth.py create) — второго механизма авторизации НЕТ;
#   - исполнение — ТОЛЬКО зарегистрированное project_action точной формы
#     (argv/env_fixed из реестра; SHA берётся из structured state, не от
#     пользователя/модели); успех → consume + audit в log.jsonl прогона
#     (те же события PROJECT_ACTION_ALLOWED / PROJECT_ACTION_EXECUTED);
#   - stale-safe: перед действием состояние перепроверяется (статус RESULT,
#     SHA ветки vs отчётного, prior-action для production, HEAD основной
#     ветки); расхождение → «предложение устарело», ничего не исполняется;
#   - идемпотентность: уже исполненное (authorization executed для того же
#     project+action+SHA) → человеческий нейтральный ответ, не ошибка;
#   - «Вернуть на доработку» — БЕЗ git-действий: только marker-решение.
#
# Проектная универсальность: маппинг UX-ролей на действия реестра — по
# необязательному полю "ux_role" ("accept" | "production" | "staging");
# проект без ux_role просто не получает соответствующих кнопок.
#
# executor этот слой вызвать не может: скрипт живёт вне task-worktree
# (jail-guard deny), владельцем вызывается через проектный навык.
#
# Usage:
#   owner_action.sh status  <run_id>            — lifecycle + допустимые шаги
#   owner_action.sh handle  <callback_data>     — обработать нажатие кнопки
# Выход: человеческий текст (переслать владельцу) + машинный блок
#   ===OWNER_ACTION_RESULT=== {json} ===END=== (state/actions/next_offer).
set -u
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AUTH_PY="$ORCH_ROOT/bin/owner_auth.py"
AUTH_DIR="${ORCH_AUTH_DIR:-$ORCH_ROOT/authorizations}"
REG="$ORCH_ROOT/config/projects.json"
RUNS_DIR="${ORCH_RUNS_DIR:-$ORCH_ROOT/runs}"

die() { echo "owner_action: REFUSED: $*" >&2; exit 2; }
[ $# -eq 2 ] || die "usage: owner_action.sh status <run_id> | handle <callback_data>"
CMD="$1"; ARG="$2"

valid_run_id() { [[ "$1" =~ ^[0-9]{8}-[a-z0-9][a-z0-9-]{0,47}$ ]]; }
valid_callback() { [[ "$1" =~ ^orch1:(pass|fix|details|staging|deploy|defer|status):[0-9]{8}-[a-z0-9][a-z0-9-]{0,47}$ ]]; }

emit_run() { # run_dir EVENT json
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg ev "$2" --argjson d "${3:-\{\}}" \
    '{ts:$ts, event:$ev} + $d' >> "$1/log.jsonl" 2>/dev/null || true
}

result_file() { # run_dir -> path (stdout)
  local d
  for d in "$1"/*/; do
    [ -f "${d}RESULT.json" ] && { printf '%s\n' "${d}RESULT.json"; return 0; }
  done
  return 1
}

project_of_run() { # run_dir -> project (stdout)
  local d f p
  for d in "$1"/*/ "$1"/; do
    for f in "$d"tasks/*.json; do
      [ -f "$f" ] || continue
      p="$(jq -r '.project // empty' "$f" 2>/dev/null)" || continue
      [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
  done
  return 1
}

# --------------------------------------------------------- state computation --
# Глобалы: RUN_ID RUN_DIR PROJECT PROF REPO_DIR DEF_BRANCH RES RES_STATUS
#          BRANCH SHA ACCEPT_NAME PROD_NAME STAGE_NAME STAGING_DONE ACCEPTED DEPLOYED DECISION
compute_state() {
  RUN_ID="$1"
  RUN_DIR="$RUNS_DIR/$RUN_ID"
  [ -d "$RUN_DIR" ] || die "прогон не найден: $RUN_ID"
  local rf; rf="$(result_file "$RUN_DIR")" || rf=""
  if [ -z "$rf" ]; then RES=""; RES_STATUS="RUNNING"; return; fi
  RES="$(jq -c . "$rf")"
  RES_STATUS="$(jq -r '.status // "UNKNOWN"' <<<"$RES")"
  BRANCH="$(jq -r '.branch // empty' <<<"$RES")"
  PROJECT="$(project_of_run "$RUN_DIR")" || PROJECT="$(jq -r '.project // empty' <<<"$RES")"
  [ -n "$PROJECT" ] || die "не удалось определить проект прогона $RUN_ID"
  PROF="$(jq -c --arg p "$PROJECT" '.[$p] // empty' "$REG")"
  [ -n "$PROF" ] || die "проект отсутствует в реестре: $PROJECT"
  REPO_DIR="$(jq -r '.repo // empty' <<<"$PROF")"; REPO_DIR="${REPO_DIR/#\~/$HOME}"
  DEF_BRANCH="$(jq -r '.default_branch // "main"' <<<"$PROF")"
  ACCEPT_NAME="$(jq -r '.project_actions // {} | to_entries[] | select(.value.ux_role=="accept") | .key' <<<"$PROF" | head -1)"
  PROD_NAME="$(jq -r  '.project_actions // {} | to_entries[] | select(.value.ux_role=="production") | .key' <<<"$PROF" | head -1)"
  STAGE_NAME="$(jq -r '.project_actions // {} | to_entries[] | select(.value.ux_role=="staging") | .key' <<<"$PROF" | head -1)"
  # полный SHA ветки задачи (fallback — commit_sha из RESULT, если он полный)
  SHA=""
  if [ -n "$BRANCH" ] && [ -d "$REPO_DIR" ]; then
    SHA="$(git -C "$REPO_DIR" rev-parse --verify --quiet "$BRANCH^{commit}" 2>/dev/null || true)"
  fi
  if [ -z "$SHA" ]; then
    local cs; cs="$(jq -r '.commit_sha // empty' <<<"$RES")"
    [[ "$cs" =~ ^[0-9a-f]{40}$ ]] && SHA="$cs"
  fi
  STAGING_DONE=0
  if [ -n "$STAGE_NAME" ] && [ -s "$RUN_DIR/log.jsonl" ]; then
    [ "$(jq -s --arg a "$STAGE_NAME" --arg s "$SHA" \
        'map(select(.event=="PROJECT_ACTION_ALLOWED" or .event=="PROJECT_ACTION_EXECUTED")
            | select(.action==$a and ((.sha // "")=="" or .sha==$s))) | length > 0' \
        "$RUN_DIR/log.jsonl" 2>/dev/null)" == "true" ] && STAGING_DONE=1
  fi
  auth_executed() { # action sha -> 0/1 (явный булев вывод: jq -e на пустом входе даёт rc=0)
    [ -n "$1" ] && [ -n "$2" ] || return 1
    [ "$(ORCH_AUTH_DIR="$AUTH_DIR" python3 "$AUTH_PY" list --all --project "$PROJECT" 2>/dev/null \
        | jq -s --arg a "$1" --arg s "$2" \
          'map(select(.action==$a and .sha==$s and .status=="executed")) | length > 0')" == "true" ]
  }
  ACCEPTED=0; auth_executed "$ACCEPT_NAME" "$SHA" && ACCEPTED=1
  DEPLOYED=0; auth_executed "$PROD_NAME" "$SHA" && DEPLOYED=1
  DECISION=""
  [ -f "$RUN_DIR/.owner_decision.json" ] && DECISION="$(jq -r '.decision // empty' "$RUN_DIR/.owner_decision.json" 2>/dev/null)"
}

report_sha() { # sha, зафиксированный в отчёте (для stale-сверки)
  [ -s "$RUN_DIR/report_actions.json" ] \
    && jq -r '.sha // empty' "$RUN_DIR/report_actions.json" 2>/dev/null || true
}

# --------------------------------------------------------------- исполнение --
exec_registered() { # action_name sha -> rc (лог: $RUN_DIR/owner_action.log)
  local name="$1" sha="$2"
  local spec; spec="$(jq -c --arg n "$name" '.project_actions[$n]' <<<"$PROF")"
  [ "$spec" != "null" ] || die "действие не зарегистрировано: $name"
  local -a ARGV=()
  mapfile -t ARGV < <(jq -r '.argv[]' <<<"$spec")
  [ "${#ARGV[@]}" -ge 2 ] || die "argv действия короче ожидаемого: $name"
  [ "${ARGV[0]}" == "bash" ] || die "ожидался argv[0]=bash: $name"
  [ "${ARGV[1]}" != "/*" ] || die "argv действия должен быть относительным: $name"
  local sp="$REPO_DIR/${ARGV[1]}"
  [ -f "$sp" ] && [ ! -L "$sp" ] || die "скрипт действия не найден или не обычный файл: ${ARGV[1]}"
  local sha_env; sha_env="$(jq -r '.owner_auth.sha_env // .env_from_model[0].name // empty' <<<"$spec")"
  [ -n "$sha_env" ] || die "у действия нет sha-env: $name"
  local -a ENVARGS=()
  local k v
  while IFS=$'\t' read -r k v; do
    v="${v/#\~/$HOME}"
    ENVARGS+=("$k=$v")
  done < <(jq -r '(.env_fixed // {}) | to_entries[] | "\(.key)\t\(.value)"' <<<"$spec")
  ENVARGS+=("$sha_env=$sha")
  local log="$RUN_DIR/owner_action.log"
  printf '== %s owner_action: %s sha=%s\n' "$(date -u +%FT%TZ)" "$name" "$sha" >> "$log"
  ( cd "$REPO_DIR" && timeout 900 env "${ENVARGS[@]}" "${ARGV[@]}" ) >> "$log" 2>&1
}

auth_create() { # action sha extra-args... -> печатает JSON authorization
  ORCH_AUTH_DIR="$AUTH_DIR" python3 "$AUTH_PY" create --project "$PROJECT" \
    --action "$1" --sha "$2" --source-note "telegram button ${3:-}" "${@:4}"
}

auth_consume() { # auth_id result_text
  ORCH_AUTH_DIR="$AUTH_DIR" python3 "$AUTH_PY" consume --id "$1" --result "$2" >/dev/null 2>&1 || true
}

run_owner_action() { # ux_role-action_name sha needs_auth requires_prior run_id cb
  local name="$1" sha="$2" needs_auth="$3" prior="$4" rid="$5" cb="$6"
  local auth_id=""
  if [ "$needs_auth" == "1" ]; then
    local -a extra=()
    [ -n "$prior" ] && extra=(--requires-prior-action "$prior")
    auth_id="$(auth_create "$name" "$sha" "$cb" "${extra[@]}" 2>/dev/null | jq -r '.id // empty')" \
      || { emit_run "$RUN_DIR" OWNER_ACTION_REFUSED "{\"action\":\"$name\",\"sha\":\"$sha\",\"reason\":\"prior-action requirement\"}"; \
           echo "❌ Этот шаг сейчас недоступен (не выполнен обязательный предыдущий шаг). Текущее состояние:"; cmd_status_inner; return 3; }
    [ -n "$auth_id" ] || die "не удалось создать authorization для $name"
  fi
  emit_run "$RUN_DIR" PROJECT_ACTION_ALLOWED "{\"task_id\":\"$(jq -r '.task_id // ""' <<<"$RES")\",\"action\":\"$name\",\"sha\":\"$sha\",\"source\":\"owner_button\"}"
  exec_registered "$name" "$sha"
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -n "$auth_id" ] && auth_consume "$auth_id" "executed rc=0 owner-button run=$rid"
    emit_run "$RUN_DIR" PROJECT_ACTION_EXECUTED "{\"task_id\":\"$(jq -r '.task_id // ""' <<<"$RES")\",\"action\":\"$name\",\"sha\":\"$sha\",\"auth_id\":\"$auth_id\",\"source\":\"owner_button\"}"
  else
    emit_run "$RUN_DIR" PROJECT_ACTION_FAILED "{\"task_id\":\"$(jq -r '.task_id // ""' <<<"$RES")\",\"action\":\"$name\",\"sha\":\"$sha\",\"rc\":$rc}"
    echo "🔴 Не получилось выполнить шаг. Авторизация не израсходована — можно повторить."
    echo "Технические детали: $RUN_DIR/owner_action.log"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------ тексты ---
L_PASS="✅ Принять изменения"; L_FIX="🔧 Вернуть на доработку"; L_DET="📋 Подробнее"
L_STG="🧪 Выложить тестовую версию"; L_DEP="🚀 Выложить в рабочий бот"; L_DEF="⏸ Позже"

buttons_json() { # pairs action|label ...
  local out="[" first=1 a l
  for p in "$@"; do
    a="${p%%|*}"; l="${p#*|}"
    [ $first -eq 1 ] && first=0 || out+=","
    out+="{\"label\":\"$l\",\"callback_data\":\"orch1:$a:$RUN_ID\"}"
  done
  printf '%s]' "$out"
}

offer_block() { # text buttons_json
  echo "===NEXT_OFFER==="
  jq -cn --arg t "$1" --argjson b "$2" '{text:$t, buttons:$b}'
  echo "===END_OFFER==="
}

machine_json() { # state actions_json
  echo "===OWNER_ACTION_RESULT==="
  jq -cn --arg r "$RUN_ID" --arg s "$1" --argjson a "$2" '{run_id:$r, state:$s, actions:$a}'
  echo "===END==="
}

details_text() {
  local tid; tid="$(jq -r '.task_id // "?"' <<<"$RES")"
  local nums n
  n="$(jq -r '[.checks[]?.detail // "" | scan("[0-9]+ passed")] | max // empty' <<<"$RES")"
  [ -n "$n" ] && nums="$n успешно" || nums="см. отчёт прогона"
  local st="не выкладывалась"; [ "$STAGING_DONE" == "1" ] && st="выложена"
  local pd="не обновлялся"; [ "$DEPLOYED" == "1" ] && pd="обновлён (${SHA:0:7})"
  echo "Задача: $tid"
  [ -n "$BRANCH" ] && echo "Ветка: $BRANCH"
  [ -n "$SHA" ] && echo "Коммит: ${SHA:0:7}"
  echo "Тесты: $nums"
  echo "Staging: $st"
  echo "Production: $pd"
}

next_step_label() {
  case "$1" in
    B) echo "$L_STG" ;; C) echo "$L_PASS" ;; D) echo "$L_DEP" ;;
    E) echo "готово, шагов нет" ;; *) echo "—" ;;
  esac
}

cmd_status_inner() {
  local state actions="[]"
  if [ -z "$RES" ]; then
    state="A"
    echo "⏳ Задача ещё выполняется (прогон $RUN_ID)."
    echo "Готовых действий пока нет — отчёт придёт по завершении."
  elif [ "$DECISION" == "request_changes" ]; then
    state="FIX"
    echo "🔧 Задача возвращена владельцем на доработку."
    echo "Изменения остались на ветке${BRANCH:+ $BRANCH}; в основную версию ничего не влито, рабочий бот не менялся."
    echo "Следующий шаг — описать, что поправить: «Агон: доработай задачу …»"
    actions="$(buttons_json "details|$L_DET")"
  elif [ "$DEPLOYED" == "1" ]; then
    state="E"
    echo "✅ Готово. Новая версия работает в рабочем боте."
    actions="$(buttons_json "details|$L_DET")"
  elif [ "$ACCEPTED" == "1" ]; then
    state="D"
    echo "Изменения добавлены в основную версию."
    echo
    echo "Выложить их в рабочий бот?"
    if [ -n "$PROD_NAME" ]; then
      actions="$(buttons_json "deploy|$L_DEP" "defer|$L_DEF" "details|$L_DET")"
    else
      actions="$(buttons_json "details|$L_DET")"
    fi
  else
    case "$RES_STATUS" in
      READY_FOR_OWNER_PASS|PASS|OWNER_GATE)
        if [ "$STAGING_DONE" != "1" ] && [ -n "$STAGE_NAME" ]; then
          state="B"
          echo "🟢 Проверки прошли успешно."
          echo "Тестовая версия ещё не выкладывалась — выложить её и проверить?"
          actions="$(buttons_json "staging|$L_STG" "details|$L_DET")"
        else
          state="C"
          echo "🟢 Тестовая версия готова."
          echo "Проверки прошли успешно."
          echo
          echo "Что делаем дальше?"
          actions="$(buttons_json "pass|$L_PASS" "fix|$L_FIX" "details|$L_DET")"
        fi ;;
      NEEDS_OWNER_INPUT)
        state="F"
        echo "🟡 Прогон ждёт вашего ответа — см. вопросы в отчёте."
        actions="$(buttons_json "details|$L_DET")" ;;
      NO_CHANGE_REQUIRED)
        state="F"
        echo "🟢 Изменения не требуются — задачу можно закрыть."
        actions="$(buttons_json "details|$L_DET")" ;;
      *)
        state="F"
        echo "🔴 Прогон завершился со статусом «$RES_STATUS»."
        echo "Что произошло и что чинить — в отчёте прогона (кнопка «Подробнее»)."
        actions="$(buttons_json "details|$L_DET")" ;;
    esac
  fi
  machine_json "$state" "$actions"
}

# ---------------------------------------------------------------- handlers ---
stale_reply() {
  echo "Это предложение уже устарело — состояние задачи изменилось."
  echo "Актуальный статус:"
  echo
  cmd_status_inner
}

cmd_pass() {
  [ -n "$RES" ] || { echo "⏳ Задача ещё выполняется — принимать пока нечего."; machine_json "A" "[]"; return 0; }
  [ "$RES_STATUS" == "READY_FOR_OWNER_PASS" ] || [ "$RES_STATUS" == "PASS" ] || {
    stale_reply; return 0; }
  [ "$DECISION" == "request_changes" ] && { echo "Задача уже возвращена на доработку — сначала доработка."; machine_json "FIX" "[]"; return 0; }
  [ -n "$ACCEPT_NAME" ] || { echo "❌ Для этого проекта приём изменений не настроен."; machine_json "F" "[]"; return 0; }
  [ -n "$SHA" ] || { stale_reply; return 0; }
  local rsha; rsha="$(report_sha)"
  [ -n "$rsha" ] && [ "${SHA#"$rsha"}" == "$SHA" ] && [ "$rsha" != "$SHA" ] && { stale_reply; return 0; }
  if [ "$ACCEPTED" == "1" ]; then
    echo "Это уже выполнено: изменения приняты в основную версию."
    echo "Текущее состояние:"
    echo
    cmd_status_inner
    return 0
  fi
  run_owner_action "$ACCEPT_NAME" "$SHA" 1 "" "$RUN_ID" "orch1:pass:$RUN_ID" || return 1
  echo "Изменения добавлены в основную версию."
  if [ -n "$PROD_NAME" ] && jq -e --arg p "$PROJECT" '(.[$p].release // null) != null' "$REG" >/dev/null 2>&1; then
    # PROACTIVE-UX-RELEASE-FLOW-2: следующий шаг — подготовка выпуска
    # (state machine выпуска в release_flow.py), не непосредственный deploy
    echo
    echo "Нужно подготовить выпуск."
    echo "===NEXT_OFFER==="
    jq -cn '{text:"Изменения приняты.\n\nНужно подготовить выпуск.", buttons:[
      {label:"📦 Подготовить выпуск", callback_data:"orch1:release-prepare:now"},
      {label:"⏸ Позже", callback_data:"orch1:release-defer:x"},
      {label:"📋 Подробнее", callback_data:"orch1:release-details:x"}]}'
    echo "===END_OFFER==="
  elif [ -n "$PROD_NAME" ]; then
    echo
    echo "Выложить их в рабочий бот?"
    offer_block "Изменения добавлены в основную версию.

Выложить их в рабочий бот?" "$(buttons_json "deploy|$L_DEP" "defer|$L_DEF" "details|$L_DET")"
  fi
}

cmd_deploy() {
  [ -n "$RES" ] || { echo "⏳ Задача ещё выполняется."; machine_json "A" "[]"; return 0; }
  [ -n "$PROD_NAME" ] || { echo "❌ Для этого проекта выкладка в рабочий бот не настроена."; machine_json "F" "[]"; return 0; }
  [ -n "$SHA" ] || { stale_reply; return 0; }
  if [ "$DEPLOYED" == "1" ]; then
    echo "Это уже выполнено: новая версия уже работает в рабочем боте."
    echo "Текущее состояние:"
    echo
    cmd_status_inner
    return 0
  fi
  [ "$ACCEPTED" == "1" ] || {
    echo "❌ Сначала нужно принять изменения (шаг «Принять изменения») — выкладывать в рабочий бот можно только принятые."
    machine_json "C" "[]"; return 0; }
  # stale: основная ветка обязана стоять ровно на принятом SHA (ff-only accept)
  if [ -d "$REPO_DIR" ]; then
    local head; head="$(git -C "$REPO_DIR" rev-parse --verify --quiet "$DEF_BRANCH" 2>/dev/null || true)"
    [ "$head" == "$SHA" ] || { stale_reply; return 0; }
  fi
  run_owner_action "$PROD_NAME" "$SHA" 1 "$ACCEPT_NAME" "$RUN_ID" "orch1:deploy:$RUN_ID" || return 1
  echo "✅ Готово. Новая версия работает в рабочем боте."
}

cmd_staging() {
  [ -n "$RES" ] || { echo "⏳ Задача ещё выполняется."; machine_json "A" "[]"; return 0; }
  [ "$RES_STATUS" == "READY_FOR_OWNER_PASS" ] || [ "$RES_STATUS" == "PASS" ] || { stale_reply; return 0; }
  [ -n "$STAGE_NAME" ] || { echo "❌ Для этого проекта тестовая выкладка не настроена."; machine_json "F" "[]"; return 0; }
  [ -n "$SHA" ] || { stale_reply; return 0; }
  [ "$STAGING_DONE" == "1" ] && {
    echo "Это уже выполнено: тестовая версия уже выложена."
    echo "Текущее состояние:"
    echo
    cmd_status_inner
    return 0; }
  # staging не требует authorization владельца (штатное действие после тестов),
  # но фиксируем исполнение в аудите прогона
  run_owner_action "$STAGE_NAME" "$SHA" 0 "" "$RUN_ID" "orch1:staging:$RUN_ID" || return 1
  echo "🧪 Тестовая версия выложена. Проверьте её — затем можно принять изменения."
  offer_block "Тестовая версия готова.
Проверки прошли успешно.

Что делаем дальше?" "$(buttons_json "pass|$L_PASS" "fix|$L_FIX" "details|$L_DET")"
}

cmd_fix() {
  [ -n "$RES" ] || { echo "⏳ Задача ещё выполняется."; machine_json "A" "[]"; return 0; }
  [ "$DECISION" == "request_changes" ] && {
    echo "Уже отмечено: задача возвращена на доработку."; machine_json "FIX" "[]"; return 0; }
  local tmp="$RUN_DIR/.owner_decision.json.tmp"
  jq -n --arg ts "$(date -u +%FT%TZ)" '{decision:"request_changes", ts:$ts}' > "$tmp" \
    && mv "$tmp" "$RUN_DIR/.owner_decision.json"
  emit_run "$RUN_DIR" OWNER_DECISION_RECORDED '{"decision":"request_changes","source":"owner_button"}'
  echo "Понял: возвращаю задачу на доработку."
  echo "Изменения остались на ветке${BRANCH:+ $BRANCH}; в основную версию ничего не влито, рабочий бот не менялся."
  echo "Опишите, что нужно поправить: «Агон: доработай задачу …»"
  machine_json "FIX" "[]"
}

cmd_details() {
  [ -n "$RES" ] || { echo "⏳ Задача ещё выполняется — подробностей результата пока нет."; machine_json "A" "[]"; return 0; }
  details_text
  local st
  if [ "$DEPLOYED" == "1" ]; then st="E"; elif [ "$ACCEPTED" == "1" ]; then st="D";
  elif [ "$DECISION" == "request_changes" ]; then st="FIX";
  elif [ "$RES_STATUS" == "READY_FOR_OWNER_PASS" ] || [ "$RES_STATUS" == "PASS" ]; then
    if [ "$STAGING_DONE" != "1" ] && [ -n "$STAGE_NAME" ]; then st="B"; else st="C"; fi
  else st="F"; fi
  echo "Следующий допустимый шаг: $(next_step_label "$st")"
  [ -n "$ACCEPT_NAME" ] && [ "$st" == "C" ] && echo "(технически: $ACCEPT_NAME)"
  [ -n "$PROD_NAME" ] && [ "$st" == "D" ] && echo "(технически: $PROD_NAME)"
  machine_json "$st" "[]"
}

cmd_defer() {
  echo "Хорошо — отложили. Вернуться можно в любой момент:"
  echo "«Агон: статус задачи $RUN_ID» или кнопка «📋 Подробнее» под отчётом."
  machine_json "D" "[]"
}

# -------------------------------------------------------------------- main ---
case "$CMD" in
  status)
    valid_run_id "$ARG" || die "недопустимый run_id: $ARG"
    compute_state "$ARG"
    cmd_status_inner
    ;;
  handle)
    valid_callback "$ARG" || die "недопустимый callback: $ARG"
    act="${ARG#orch1:}"; act="${act%%:*}"
    rid="${ARG##*:}"
    compute_state "$rid"
    case "$act" in
      pass)     cmd_pass ;;
      deploy)   cmd_deploy ;;
      staging)  cmd_staging ;;
      fix)      cmd_fix ;;
      details)  cmd_details ;;
      defer)    cmd_defer ;;
      status)   cmd_status_inner ;;
    esac
    ;;
  *) die "неизвестная команда: $CMD" ;;
esac
