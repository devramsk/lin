# LineageOS 21 pre-QPR2 Light GSI — сборка на Ubuntu 24.04

Цель проекта — неподписанные образы `64VN` и `64GN`. Репозиторий содержит **только скрипты, workflow и документацию**:
Android-дерево загружается `repo` в отдельный рабочий каталог; сотни гигабайт исходников и образы в Git не включены.
`64GN` использует MindTheGapps — проверьте лицензии перед распространением.

## Жёсткие требования и честные ограничения

- Сборка выполняется на **Ubuntu 24.04 x86_64** (локальный сервер — рекомендуемый и единственный подтверждённый путь).
- GitHub Actions: **только GitHub-hosted `ubuntu-24.04`**. Self-hosted runner-ы запрещены и не используются.
- Бесплатный GitHub-hosted runner (публичный репозиторий): 4 vCPU, 16 GB RAM, **~14 GB SSD**, лимит job — 6 часов,
  кэш 10 GB, артефакты 500 MB. LineageOS 21 рекомендует ~400 GB свободного места и ~64 GB RAM
  ([LineageOS Wiki](https://wiki.lineageos.org/)). **Полная сборка на бесплатном hosted runner-е не помещается** — это физика, а не недостаток скриптов.
  Два последних прогона `mode=build` ([43602208859](https://github.com/devramsk/lin/actions/runs/43602208859), [43863633480](https://github.com/devramsk/lin/actions/runs/43863633480)) остановились на этапе `sync` из-за места на диске.
- Проверка «минимум 400 GiB свободно» **удалена** из обоих скриптов; вместо неё во время build-этапа работает
  дисковый guard (`scripts/run-with-disk-guard.sh`, порог настраивается `DISK_RESERVE_GIB`, по умолчанию 3 GiB).
- Платный тариф GitHub не требуется; self-hosted runner-ы не регистрируются и не подключаются.

## Локальный сервер (Ubuntu 24.04) — рекомендуемый путь

```bash
# один раз: пакеты и инструмент repo
sudo -v
BUILD_ROOT=/opt/dev/lin/lineage-work bash scripts/build-gsi.sh
```

- `BUILD_ROOT` должен быть **абсолютным путём** на диске с большим запасом (рекомендуется ≥ 450 GB свободно).
- Прогон **возобновляемый**: при повторном запуске той же командой завершённые этапы пропускаются
  (маркеры `audit/<stage>.done` внутри `BUILD_ROOT`), `repo sync` / `repopick` / патчи / ninja сами инкрементальны.
  Сообщение `Refusing to reuse ...` возникает только для каталога, который НЕ был создан этим скриптом;
  каталог, созданный предыдущим прогоном, определяется автоматически и продолжается ("Adopting existing build root ...").
  Для каталога, созданного скриптом, но потерявшего маркер, есть явный `FORCE_ADOPT=1`.
- Этапы: `deps` (apt) → `init` (git identity, LFS, `repo`, `repo init`, пиннинг `lineage_build_unified` / `lineage_patches_unified`)
  → `build` (`bash lineage_build_unified/build_unified.sh treble 64VN 64GN`, внутри дисковый guard) → `validate` (sha256).
- Поэтапный запуск (микрозадачи): `STOP_AFTER=deps|init|build` остановит выполнение после указанного этапа.
- Результаты: образы в `$BUILD_ROOT/home/build-output/`, логи и события — `$BUILD_ROOT/audit/logs` и `audit/events`,
  локальный аудит-репозиторий — `$BUILD_ROOT/audit/.git`, SHA256SUMS — `$BUILD_ROOT/audit/SHA256SUMS`.
- Полезные переопределения: `INSTALL_DEPS=0` (не ставить пакеты), `DISK_GUARD=0` (выключить guard),
  `DISK_RESERVE_GIB=5`, `STOP_AFTER=init`, `ALLOW_NON_2404=1` (не рекомендуется).
- Если предыдущий прогон прервался: просто повторите ту же команду. Для сценариев `RESUME_INTERRUPTED=1` см. ниже про `staged-build-gsi.sh`.

> Ошибка, с которой вы попали на эту страницу — `Refusing to reuse /opt/dev/lin/lineage-work; select a fresh BUILD_ROOT` —
> устранена: теперь такой каталог определяется как корень предыдущего прогона и сборка продолжается с остановленного места.
> Перезапустите на сервере: `BUILD_ROOT=/opt/dev/lin/lineage-work bash scripts/build-gsi.sh`

## GitHub Actions — что реально работает бесплатно

Workflow `.github/workflows/build-gsi.yml` (только `workflow_dispatch`):

| Job | Что делает | Гарантия |
|---|---|---|
| `preflight` | `bash -n`, все тесты, отчёт о ресурсах; в `probe` — установка зависимостей на ubuntu-24.04 | Быстро, надёжно |
| `upstream-inventory` | Клонирует два pinned upstream-репозитория + манифест, считает SHA/патчи, заливает inventory | Быстро |
| `build` (только `mode=build`) | Поэтапно: setup → sync → patch → build-64VN → build-64GN → validate, параллельный resource-монитор, аудит-коммит в ветку `audit/<run_id>-<attempt>`, артефакты | **Не гарантирован**: ~14 GB SSD не вместят ~400 GB дерева |

Запуск: **Actions → LineageOS 21 pre-QPR2 GSI → Run workflow**, выберите ветку и `mode` (`build` по умолчанию),
оставьте `reclaim_space=true`. Или: `gh workflow run build-gsi.yml --ref main -f mode=build`.
Полная инструкция, включая выдачу Arena права на запуск Actions без токенов в чате: **[docs/github-actions-setup.md](docs/github-actions-setup.md)**.

Почему job больше никогда не «висит в ожидании self-hosted runner-а»: в `runs-on` везде `ubuntu-24.04`,
шаг `Report resources before syncing` падает при не-hosted окружении. Зависший запуск
[43585075993](https://github.com/devramsk/lin/actions/runs/43585075993) был создан тогдашней редакцией workflow
с self-hosted-метками; он отменён, повторно запускать его не нужно.

### Аудит и коммиты

- Микрозаписи о ходе сборки сначала пишутся в `${TMPDIR:-/tmp}`, затем атомарно переносятся в `audit/events/`
  и фиксируются коммитами в локальный аудит-репозиторий внутри `BUILD_ROOT` (и, в GitHub Actions,
  дополнительно коммитятся в ветку `audit/<run_id>-<attempt>` скриптом `scripts/commit-audit.sh`;
  файлы больше 90 MB разбиваются на `.part-NN`, SHA-256 — в `AUDIT-MANIFEST.txt`).
- Аудит-коммит в ветку выполняется только job-ом `build` и только если `commit_audit=true`
  и в настройках репозитория включены **Workflow permissions → Read and write**.
  Если право не выдано, job не падает: будет `::warning::` и артефакт с теми же файлами.
- Между запусками GitHub Actions сборка не возобновляется (VM одноразовая); каждый `mode=build` начинается заново.
  Возобновление работает только на постоянном диске (см. «Локальный сервер»).

## Почему все исходники не «собраны в один репозиторий»

- LOS21-pre-QPR2 тянет ~1060 проектов (~250–400 GB с `.repo`, Git-объектами, LFS и `out/`).
- GitHub: жёсткий лимит 100 MB на git-объект, практический лимит репозитория — гигабайты, не терабайты;
  Actions: ~14 GB диска на runner-е, 10 GB кэша, 6 часов. Даже shallow/partial-clone не решают квадратичную проблему.
- «Полный сбор всех репозиториев» для сборки выполняется самим прогоном: `repo init` + `repo sync`
  по манифесту `LOS21-pre-QPR2/android` (branch `lineage-21.0`) + два pinned upstream-репозитория
  (`lineage_build_unified`, `lineage_patches_unified`). После успешного `sync` в аудит сохраняется
  `repo manifest -r` — точный список коммитов всех полученных проектов.

## Скрипты и контрольные точки

- `scripts/build-gsi.sh` — монолитная сборка с возобновлением (маркеры `audit/*.done`), Ubuntu 24.04-only, без проверки 400 GiB.
- `scripts/staged-build-gsi.sh` — поэтапная сборка по микрозадачам (`STAGE=setup|sync|patch|build-64VN|build-64GN|validate|all`),
  `.done`-маркеры, запрет повторного запуска прерванного не-build этапа; явный `RESUME_INTERRUPTED=1` снимает запрет.
  Запускать только на постоянном диске.
- `scripts/run-with-disk-guard.sh` — останавливает этап, когда свободного места остаётся меньше `DISK_RESERVE_GIB` (по умолчанию 3 GiB).
- `scripts/reclaim-hosted-space.sh` — удаляет предустановленные SDK в одноразовой GitHub-hosted VM (по умолчанию включено в `build`).
- `scripts/install-build-deps.sh` / `scripts/build-dependencies.sh` — пакеты для Ubuntu 22.04/24.04 (24.04 — без устаревших ncurses5).
- `scripts/audit-upstream.sh` — проверка pinned upstream-репозиториев и манифеста (используется в `upstream-inventory`).
- `scripts/commit-audit.sh` — коммит аудит-бандла в ветку `audit/<run_id>-<attempt>`; токен никогда не попадает в URL/логи
  (авторизация через `http.extraheader`); файлы > 90 MB разбиваются на `.part-NN`.
- `tests/` — офлайн-тесты контрактов скриптов (резюмирование, отказы, дисковый guard, инвентарь, аудит-коммит).

Источники: [характеристики GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[лимиты Actions](https://docs.github.com/en/actions/reference/limits),
[кэш Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching),
[инструкция LineageOS](https://wiki.lineageos.org/devices/TP1803/build/),
[upstream](https://github.com/AndyCGYan/lineage_build_unified/tree/lineage-21-pre-qpr2-light).

## Статус проверок

- Установка зависимостей на Ubuntu 22.04/24.04 проверена в [probe 43863438540](https://github.com/devramsk/lin/actions/runs/43863438540).
- `mode=build` на hosted runner-е падал на `sync` (нехватка места): [43593537771](https://github.com/devramsk/lin/actions/runs/43593537771),
  [43602208859](https://github.com/devramsk/lin/actions/runs/43602208859), [43863633480](https://github.com/devramsk/lin/actions/runs/43863633480).
  Готовых образов из CI на момент написания нет; **полная сборка подтверждается только на постоянном Ubuntu 24.04 сервере.**
- Поэтапное возобновление на локальном сервере реализовано маркерами; полное "interrupt → resume → identical image"
  ещё не проверено сквозным прогоном (см. `docs/staged-compilation.md`).
