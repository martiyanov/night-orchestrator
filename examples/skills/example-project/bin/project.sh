#!/usr/bin/env bash
# project.sh — единственный узкий вход проектного навыка в Intake/Night
# Orchestrator (аналог ag_task.sh): владелец может безопасно разрешить этот
# скрипт Allow-Always, не открывая общий python3/shell.
#
# Разрешены ТОЛЬКО подкоманды:
#   intake  "<текст сообщения>"     — новое сообщение проекту
#   answer  "<ответ владельца>"     — ответ на уточняющий вопрос Intake
#   status  [intake_id]             — состояние / список ожидающих
#   cancel  [intake_id]             — отмена («пока не делай»)
#   backlog [intake_id]             — «положи в бэклог»
#   launch  <intake_id>             — запуск готовой задачи (через Intake;
#                                     Intake сам вызывает канонический путь)
#
# Safety: project зашит (example-project), путь к intake.py зашит, произвольный
# python/файл/project передать нельзя, eval отсутствует, всё закавычено,
# ночной оркестратор запускается ТОЛЬКО через Intake launch (никаких
# deploy/merge/push/run_task отсюда).
set -euo pipefail

PROJECT="example-project"                                   # фиксирован, не параметр
ORCH_ROOT="${ORCH_ROOT:-$HOME/.local/share/night-orchestrator}"
INTAKE_PY="$ORCH_ROOT/bin/intake.py"                  # фиксирован
SKILL_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "project.sh: REFUSED: $*" >&2; exit 1; }
usage() { echo "usage: project.sh route \"<текст>\" | {intake|answer} \"<текст>\" | status | cancel | backlog | launch <id>" >&2; exit 2; }

[ $# -ge 1 ] || usage
cmd="$1"; shift

# intake_id — строгий формат (без путей/метасимволов)
valid_id() { [[ "$1" =~ ^[0-9]{8}T[0-9]{6}-[a-z0-9-]{1,48}$ ]]; }

case "$cmd" in
    route)
        # детерминированная проверка принадлежности сообщения проекту
        # (без LLM, без побочных эффектов); Skills вызывает это первым
        [ $# -eq 1 ] || usage
        [ ${#1} -le 4000 ] || die "текст слишком длинный"
        exec python3 "$SKILL_BIN_DIR/../route.py" "$1"
        ;;
    intake|answer)
        [ $# -eq 1 ] || usage
        text="$1"
        [ ${#text} -ge 1 ] || die "пустой текст"
        [ ${#text} -le 4000 ] || die "текст слишком длинный (>4000)"
        [ "$cmd" = "intake" ] && sub=message || sub=answer; exec python3 "$INTAKE_PY" "$sub" "$text" --project "$PROJECT"
        ;;
    status|cancel|backlog)
        args=("$cmd")
        if [ $# -ge 1 ]; then
            valid_id "$1" || die "недопустимый intake_id: $1"
            # cancel/backlog в Intake принимаются без id (действуют на
            # ожидающую задачу); id допускаем только валидный и игнорируем
            # как диагностический уточнитель — передача произвольных путей
            # исключена форматом выше
            :
        fi
        [ $# -le 1 ] || usage
        exec python3 "$INTAKE_PY" "$cmd"
        ;;
    launch)
        [ $# -eq 1 ] || usage
        valid_id "$1" || die "недопустимый intake_id: $1"
        exec python3 "$INTAKE_PY" launch "$1"
        ;;
    *)
        usage
        ;;
esac
