#!/usr/bin/env bash
# model_call.sh — single model call with evidence + mock mode + trigger guard.
# Keys are read from ~/.config/openclaw/secrets/providers.json at call time; never printed, never logged.
#
# Usage:
#   model_call.sh --role executor|planner|review --model provider/model \
#     --system-file F --prompt-file F --out-file F --run-dir D [--max-tokens N] [--trigger]
#
# Mock mode (selftests): MOCK_FIXTURE=/path/to/fixture.jsonl — JSONL entries
#   {"role":"executor","response":"..."} consumed in order; entry without "role" matches any.
#
# Evidence (never contains prompt text): $RUN_DIR/model_calls.jsonl
#   {ts, role, model, ok, http_status, latency_ms, prompt_chars, completion_chars, mock, fallback_used}
# Full request/response transcripts go to $RUN_DIR/transcripts/ (0700).

set -u
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SECRETS="$HOME/.config/openclaw/secrets/providers.json"

ROLE=""; MODEL=""; SYSTEM_FILE=""; PROMPT_FILE=""; OUT_FILE=""; RUN_DIR=""; MAXTOK=4096; TRIGGER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --system-file) SYSTEM_FILE="$2"; shift 2;;
    --prompt-file) PROMPT_FILE="$2"; shift 2;;
    --out-file) OUT_FILE="$2"; shift 2;;
    --run-dir) RUN_DIR="$2"; shift 2;;
    --max-tokens) MAXTOK="$2"; shift 2;;
    --trigger) TRIGGER=1; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done

_evidence() { # MODEL OK HTTP LAT_MS PCHARS CCHARS MOCK FALLBACK  (8 args, all required)
  [[ -n "$RUN_DIR" ]] || return 0
  mkdir -p "$RUN_DIR/transcripts"; chmod 700 "$RUN_DIR/transcripts" 2>/dev/null
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg role "$ROLE" \
    --arg model "$1" --arg ok "$2" --arg http "$3" --arg lat "$4" \
    --arg p "$5" --arg c "$6" --arg mock "$7" --arg fb "$8" \
    '{ts:$ts, role:$role, model:$model, ok:($ok=="1"), http_status:($http|tonumber? // $http), latency_ms:($lat|tonumber? // $lat), prompt_chars:($p|tonumber? // $p), completion_chars:($c|tonumber? // $c), mock:($mock=="1"), fallback_used:$fb}' \
    >> "$RUN_DIR/model_calls.jsonl"
}

# ---- trigger-only model guard (openai/gpt-5.6-sol must never fire without explicit trigger)
case "$MODEL" in
  openai/gpt-5.6*|*/gpt-5.6*)
    if [[ $TRIGGER -ne 1 ]]; then
      echo "TRIGGER_REQUIRED: $MODEL may only be called with explicit --trigger (TASK.explicit_review_trigger)" >&2
      _evidence "$MODEL" 0 0 0 0 0 0 "no" ; exit 43
    fi ;;
esac

# ---- mock mode -----------------------------------------------------------
if [[ -n "${MOCK_FIXTURE:-}" ]]; then
  resp="$(python3 - "$MOCK_FIXTURE" "$ROLE" "$MODEL" <<'PYEOF'
import json, sys
path, role, model = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(path).read()
dec = json.JSONDecoder()
entries, i, n = [], 0, len(raw)
while i < n:  # parse concatenated JSON values (pretty objects, arrays, JSONL)
    while i < n and raw[i] in ' \t\r\n': i += 1
    if i >= n: break
    obj, i = dec.raw_decode(raw, i)
    entries.append(obj)
if len(entries) == 1 and isinstance(entries[0], list):
    entries = entries[0]  # previously saved array
if isinstance(entries, dict): entries = [entries]
used = False
for e in entries:
    if e.get("_used"): continue
    if e.get("role") in (None, role) and e.get("model") in (None, model):
        e["_used"] = True
        used = True
        if e.get("rb_exhaust"):
            print("__RB_EXHAUST__")
        else:
            print(e["response"])
        break
with open(path, "w") as f:
    f.write(json.dumps(entries, indent=1))
if not used:
    sys.exit(1)
PYEOF
  )" || { echo "mock fixture exhausted for role=$ROLE" >&2; _evidence "$MODEL" 0 0 0 0 0 1 "no"; exit 44; }
  if [[ "$resp" == "__RB_EXHAUST__" ]]; then
    : > "$OUT_FILE"
    jq -cn --arg ro "$ROLE" --arg m "$MODEL" --arg mt "$MAXTOK" \
      '{role:$ro, provider:($m|split("/")[0]), model:$m, max_tokens:($mt|tonumber), completion_tokens:($mt|tonumber), content_length:0}' \
      > "${RUN_DIR:-/tmp}/rb_event.json"
    _evidence "$MODEL" 0 200 0 0 0 1 "no"
    echo "model_call: REASONING_BUDGET_EXHAUSTED (mock)" >&2
    exit 45
  fi
  printf '%s' "$resp" > "$OUT_FILE"
  _evidence "$MODEL" 1 200 0 0 "$(wc -c <"$OUT_FILE")" 1 "no"
  exit 0
fi

# ---- resolve provider ------------------------------------------------------
provider="${MODEL%%/*}"; model_id="${MODEL#*/}"
base=""; key=""
zai_key() {
  # orchestrator-owned credentials first (config/credentials.env, 0600), then providers.json
  local k=""
  if [[ -f "$ORCH_ROOT/config/credentials.env" ]]; then
    k="$(grep -E '^ZAI_API_KEY=' "$ORCH_ROOT/config/credentials.env" | cut -d= -f2- | tr -d '"' | tr -d ' ')"
  fi
  [[ -z "$k" ]] && k="$(python3 -c "import json;print(json.load(open('$SECRETS'))['providers']['zaiBundle']['apiKey'])" 2>/dev/null)"
  printf '%s' "$k"
}
case "$provider" in
  zai)      base="https://api.z.ai/api/coding/paas/v4";  key="$(zai_key)";;
  groq)     base="https://api.groq.com/openai/v1";       key="$(python3 -c "import json;print(json.load(open('$SECRETS'))['providers']['groq']['apiKey'])" 2>/dev/null)";;
  openai)   base="https://api.openai.com/v1";            key="$(python3 -c "import json;print(json.load(open('$SECRETS'))['providers']['openai']['apiKey'])" 2>/dev/null)";;
  *) echo "unknown provider: $provider" >&2; exit 2;;
esac
if [[ -z "$key" ]]; then echo "no api key for provider $provider" >&2; exit 2; fi

call_api() { # model_id  -> writes completion text to $OUT_FILE
  local m="$1"
  mkdir -p "$RUN_DIR/transcripts" 2>/dev/null; chmod 700 "$RUN_DIR/transcripts" 2>/dev/null
  local req="$RUN_DIR/transcripts/req_$$_$(date +%s%N).json"
  python3 - "$SYSTEM_FILE" "$PROMPT_FILE" "$m" "$MAXTOK" "$req" <<'PYEOF'
import json, sys
sysf, promptf, m, maxtok, out = sys.argv[1:6]
msgs = []
if sysf and sysf != "-":
    # errors="replace": command observations may carry non-UTF-8 bytes; a strict
    # decode here crashed request building (UnicodeDecodeError) and burned attempts
    msgs.append({"role": "system", "content": open(sysf, encoding="utf-8", errors="replace").read()})
msgs.append({"role": "user", "content": open(promptf, encoding="utf-8", errors="replace").read()})
json.dump({"model": m, "messages": msgs, "max_tokens": int(maxtok), "temperature": 0.2}, open(out, "w"))
PYEOF
  local http lat pchars
  pchars="$(wc -c <"$req")"
  local t0=$(date +%s%N)
  local body; body="$(curl -sS -m 480 -w '\n%{http_code}' -X POST "$base/chat/completions" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" --data @"$req")"
  local rc=$?
  lat=$(( ($(date +%s%N) - t0) / 1000000 ))
  local http_code="${body##*$'\n'}"; body="${body%$'\n'*}"
  chmod 600 "$req" 2>/dev/null
  if [[ $rc -ne 0 || "$http_code" != "200" ]]; then
    echo "model_call: http=$http_code rc=$rc body=$(printf '%s' "$body" | head -c 300)" >&2
    return 1
  fi
  printf '%s' "$body" | jq -r '.choices[0].message.content // empty' > "$OUT_FILE" 2>/dev/null
  # keep raw response transcript
  printf '%s' "$body" > "$RUN_DIR/transcripts/resp_$$_$(date +%s%N).json" 2>/dev/null
  chmod 600 "$RUN_DIR"/transcripts/resp_* 2>/dev/null
  # REASONING_BUDGET_EXHAUSTED: контент пуст/почти пуст И completion_tokens
  # у потолка max_tokens (reasoning съел output-бюджет). Vendor-нейтрально.
  local _ct _cl
  _ct="$(printf '%s' "$body" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)"
  _cl="$(wc -c < "$OUT_FILE")"
  if (( _ct >= MAXTOK * 95 / 100 && _cl < 32 )); then
    jq -cn --arg ro "$ROLE" --arg m "$MODEL" --arg mt "$MAXTOK" --arg ct "$_ct" --arg cl "$_cl" \
      '{role:$ro, provider:($m|split("/")[0]), model:$m, max_tokens:($mt|tonumber), completion_tokens:($ct|tonumber), content_length:($cl|tonumber)}' \
      > "$RUN_DIR/rb_event.json"
    echo "model_call: REASONING_BUDGET_EXHAUSTED ctok=$_ct maxtok=$MAXTOK content_len=$_cl" >&2
    return 45
  fi
  LAST_PCHARS="$pchars"; LAST_CCHARS="$(wc -c <"$OUT_FILE")"
  return 0
}

call_api "$model_id"
rc=$?
if [[ $rc -eq 45 ]]; then _evidence "$MODEL" 0 0 0 0 0 0 "no"; exit 45; fi
if [[ $rc -ne 0 ]]; then
  _evidence "$MODEL" 0 0 0 0 0 0 "no"
  # executor fallback per routing.json
  if [[ "$ROLE" == "executor" ]]; then
    fb="$(jq -r '.roles.executor.fallback // empty' "$ORCH_ROOT/config/routing.json")"
    if [[ -n "$fb" && "$fb" != "null" ]]; then
      echo "model_call: falling back to $fb" >&2
      p2="${fb%%/*}"; m2="${fb#*/}"
      case "$p2" in
        groq)   base="https://api.groq.com/openai/v1"; key="$(python3 -c "import json;print(json.load(open('$SECRETS'))['providers']['groq']['apiKey'])")";;
        openai) base="https://api.openai.com/v1";     key="$(python3 -c "import json;print(json.load(open('$SECRETS'))['providers']['openai']['apiKey'])")";;
        zai)    base="https://api.z.ai/api/coding/paas/v4"; key="$(zai_key)";;
      esac
      call_api "$m2"
      rc2=$?
      _evidence "$fb" $([[ $rc2 -eq 0 ]] && echo 1 || echo 0) 0 "${LAST_LAT:-0}" "${LAST_PCHARS:-0}" "${LAST_CCHARS:-0}" 0 "yes"
      exit $rc2
    fi
  fi
  exit 1
fi
_evidence "$MODEL" 1 0 "${LAST_LAT:-0}" "${LAST_PCHARS:-0}" "${LAST_CCHARS:-0}" 0 "no"
exit 0
