# Установка

```bash
git clone <repo> && cd night-orchestrator
./scripts/install.sh --target ~/.local/share/night-orchestrator
```

`install.sh`: копирует код, создаёт рабочие каталоги (runs/, intake/),
генерирует `config/*.json` из `*.example.json` (не перезаписывает существующие
молча), НЕ трогает OpenClaw и секреты, поддерживает `--dry-run`.

Затем:
1. Опишите свой проект в `config/projects.json` (repo, worktree_root,
   forbidden_paths, guard_roots, bootstrap, test_command).
2. Назначьте модели ролям в `config/routing.json`; при необходимости
   добавьте провайдера в `bin/model_call.sh` и источник ключа.
3. `./scripts/doctor.sh --root <target>` — проверка окружения.
4. `./bin/selftest.sh --full` — самопроверка.

Обновление: повторный `install.sh` обновляет код, конфиги не трогает.
Откат: `install.sh --uninstall` удаляет только то, что ставил (после
подтверждения; runs/ и конфиги остаются — удаляйте вручную).
