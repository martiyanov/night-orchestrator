#!/usr/bin/env bash
# night_run.sh — run a batch of TASKs and deliver the morning report.
# Usage: night_run.sh <run_dir>   (run_dir must contain tasks/*.json)
set -u
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=bin/gates.sh
source "$ORCH_ROOT/bin/gates.sh"

RUN_DIR="${1:?run_dir}"
PERMS="$ORCH_ROOT/config/permissions.json"
PROJECTS="$ORCH_ROOT/config/projects.json"
RUN_NAME="$(basename "$RUN_DIR")"

emit() { jq -cn --arg ts "$(date -u +%FT%TZ)" --arg ev "$1" --argjson d "${2:-\{\}}" '{ts:$ts,event:$ev} + $d' >> "$RUN_DIR/log.jsonl" 2>/dev/null || true; }

echo "night_run: $RUN_DIR at $(date -u +%FT%TZ)" | tee "$RUN_DIR/night.log"

# ---- preconditions --------------------------------------------------------
DEPLOY_ENABLED="$(jq -r '.DEPLOY_ENABLED' "$PERMS")"
emit RUN_STARTED "{\"run\":\"$RUN_NAME\",\"deploy_enabled\":$DEPLOY_ENABLED}"
if [[ "$DEPLOY_ENABLED" != "false" ]]; then
  echo "night_run: DEPLOY_ENABLED is not false — writable tasks will be refused (dry-run only)." | tee -a "$RUN_DIR/night.log"
fi

projects_used="$(jq -r '.project' "$RUN_DIR"/tasks/*.json | sort -u)"
for p in $projects_used; do
  repo="$(jq -r --arg p "$p" '.[$p].repo // empty' "$PROJECTS")"
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    echo "night_run: project $p not in registry or repo missing — abort" | tee -a "$RUN_DIR/night.log"
    exit 1
  fi
  dirty="$(git -C "$repo" status --porcelain | head -c 300)"
  head="$(git -C "$repo" rev-parse HEAD)"
  jq -n --arg p "$p" --arg head "$head" --arg dirty "$dirty" \
    '{project:$p, head_before:$head, dirty_before:$dirty}' >> "$RUN_DIR/preconditions.json"
  if [[ -n "$dirty" ]]; then
    echo "night_run: PRODUCTION CHECKOUT DIRTY for $p — aborting run" | tee -a "$RUN_DIR/night.log"
    emit PRODUCTION_DIRTY_ABORT "{\"project\":\"$p\"}"
    exit 1
  fi
  emit PRODUCTION_CLEAN "{\"project\":\"$p\",\"head\":\"$head\"}"
done

# ---- run tasks ------------------------------------------------------------
stop_run=0
for t in "$RUN_DIR"/tasks/*.json; do
  [[ -e "$t" ]] || continue
  tid="$(jq -r '.task_id // "unknown"' "$t")"
  echo "night_run: task $tid ($(basename "$t"))" | tee -a "$RUN_DIR/night.log"
  out="$(bash "$ORCH_ROOT/bin/run_task.sh" "$RUN_DIR" "$t" 2>&1)"
  status="$(printf '%s\n' "$out" | grep -oE 'FINAL_STATUS [A-Z_]+' | tail -1 | cut -d' ' -f2)"
  echo "night_run: task $tid -> ${status:-UNKNOWN}" | tee -a "$RUN_DIR/night.log"
  echo "$out" > "$RUN_DIR/${tid}.run_output.log"
  if [[ "$status" == "PERMISSION_VIOLATION" ]]; then
    echo "night_run: PERMISSION_VIOLATION in $tid — stopping batch" | tee -a "$RUN_DIR/night.log"
    emit BATCH_STOPPED_VIOLATION "{\"task_id\":\"$tid\"}"
    stop_run=1
    break
  fi
done

# ---- morning report -------------------------------------------------------
if [[ $stop_run -eq 0 ]]; then
  bash "$ORCH_ROOT/bin/report.sh" "$RUN_DIR" >> "$RUN_DIR/night.log" 2>&1 && \
    echo "night_run: report delivered" | tee -a "$RUN_DIR/night.log" || \
    echo "night_run: report FAILED (see night.log)" | tee -a "$RUN_DIR/night.log"
else
  # report even on violation, but skip auto-continue
  bash "$ORCH_ROOT/bin/report.sh" "$RUN_DIR" >> "$RUN_DIR/night.log" 2>&1 || true
fi

# ---- final integrity ------------------------------------------------------
jq -r 'keys[] | select(startswith("$") | not)' "$PROJECTS" | while read -r p; do
  repo="$(jq -r --arg p "$p" '.[$p].repo' "$PROJECTS")"
  [[ -d "$repo" ]] || continue
  dirty="$(git -C "$repo" status --porcelain | head -c 300)"
  jq -n --arg p "$p" --arg dirty "$dirty" --arg ts "$(date -u +%FT%TZ)" \
    '{project:$p, dirty_after:$dirty, ts:$ts}' >> "$RUN_DIR/postconditions.json"
  if [[ -n "$dirty" ]]; then
    emit PRODUCTION_DIRTY_AFTER "{\"project\":\"$p\",\"dirty\":\"$dirty\"}"
    echo "night_run: WARNING production checkout dirty after run: $p" | tee -a "$RUN_DIR/night.log"
  fi
done
emit RUN_FINISHED "{\"run\":\"$RUN_NAME\",\"stopped_violation\":$stop_run}"
echo "night_run: done" | tee -a "$RUN_DIR/night.log"
exit 0
