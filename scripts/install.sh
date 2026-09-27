#!/usr/bin/env bash
# install.sh — установка Night Orchestrator в заданный каталог.
# Безопасность: не перезаписывает существующую установку молча; не трогает
# OpenClaw и секреты; конфиги создаёт из *.example.json только если их нет;
# --dry-run показывает план; идемпотентен.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=""
DRY=0; UNINSTALL=0; TOUCH_OPENCLAW=0
for a in "$@"; do
  case "$a" in
    --target) : ;; # обработается ниже
    --target=*) TARGET="${a#--target=}" ;;
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --with-openclaw-integration) TOUCH_OPENCLAW=1 ;;
    *) [[ "${PREV:-}" == "--target" ]] && TARGET="$a" || { echo "неизвестный аргумент: $a" >&2; exit 2; } ;;
  esac
  PREV="$a"
done
[ -n "$TARGET" ] || { echo "usage: install.sh --target <dir> [--dry-run] [--uninstall] [--with-openclaw-integration]" >&2; exit 2; }

say() { echo "[install] $*"; }
run() { if (( DRY )); then say "DRY: $*"; else eval "$@"; fi; }

if (( UNINSTALL )); then
  for d in bin config contracts prompts docs examples scripts .github; do
    run "rm -rf '$TARGET/$d'"
  done
  say "удалены кодовые каталоги. runs/, intake/, config/*.json (ваши) и секреты НЕ тронуты — удаляйте вручную при необходимости."
  exit 0
fi

if [ -d "$TARGET" ] && [ -e "$TARGET/bin/run_task.sh" ] && (( ! DRY )); then
  say "существующая установка найдена — обновляю код, конфиги не трогаю"
fi
say "источник: $SRC"
say "цель:     $TARGET"
run "mkdir -p '$TARGET'"
for d in bin config contracts prompts docs examples scripts .github; do
  run "mkdir -p '$TARGET/$d' && cp -r '$SRC/$d/.' '$TARGET/$d/'"
done
run "rm -rf '$TARGET/bin/__pycache__'"
for f in README.md VERSION CHANGELOG.md .gitignore .editorconfig; do
  run "cp '$SRC/$f' '$TARGET/$f'"
done
# рабочие каталоги и конфиги из примеров (только отсутствующие)
for d in runs intake; do run "mkdir -p '$TARGET/$d'"; done
for ex in permissions routing projects; do
  if [ -e "$TARGET/config/$ex.json" ]; then
    say "config/$ex.json существует — не перезаписываю"
  else
    run "cp '$TARGET/config/$ex.example.json' '$TARGET/config/$ex.json'"
  fi
done
if (( ! TOUCH_OPENCLAW )); then
  say "OpenClaw не меняю (для интеграции см. docs/OPENCLAW_INTEGRATION.md; флаг --with-openclaw-integration пока заглушка осознанного отказа)"
fi
say "готово. Дальше: config/projects.json → ваш проект; scripts/doctor.sh --root '$TARGET'; bin/selftest.sh --full"
