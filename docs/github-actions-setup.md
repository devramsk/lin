# Как запускать сборку в GitHub Actions и как дать Arena право на её запуск

Документ написан по фактическому состоянию репозитория `devramsk/lin` на 16.11.2026.
Никаких платных тарифов GitHub и никаких self-hosted runner-ов здесь не используется и не требуется.

## 1. Что произошло с зависшим запуском 43585075993

Запуск [43585075993](https://github.com/devramsk/lin/actions/runs/43585075993) стоял на месте
«Waiting for a runner to pick up this job» с метками `self-hosted, linux, x64, lineage-gsi`.
Причина: workflow на момент запуска запрашивал **self-hosted** runner, а в репозитории он не зарегистрирован
(и запрещён правилами проекта). Runner-а для такой метки не существует, поэтому job ждал бесконечно
и был отменён. Текущий workflow `.github/workflows/build-gsi.yml` self-hosted-меток не содержит:
все job-ы выполняются на **GitHub-hosted `ubuntu-24.04`**, а шаг `Report resources before syncing`
дополнительно проверяет `RUNNER_ENVIRONMENT == github-hosted` и падает, если job попал на не-hosted runner.

Повторять запуск 43585075993 не нужно. После слияния этих изменений открывайте новый запуск кнопкой **Run workflow** — он будет на GitHub-hosted runner.

## 2. Жёсткие ограничения бесплатных GitHub-hosted runners (почему «просто нажми и собери» не работает)

| Параметр | Значение (публичный репозиторий) |
|---|---|
| Runner | `ubuntu-24.04`, 4 vCPU, 16 GB RAM, **~14 GB SSD** |
| Лимит времени job | 6 часов |
| Кэш Actions | 10 GB на репозиторий |
| Артефакты | max 10 GB на артефакт; на Free включено **500 MB** хранения |
| Минуты | для публичных репозиториев — бесплатно |

Сборка LineageOS 21 требует по оценке [LineageOS Wiki](https://wiki.lineageos.org/) около **400 GB** свободного места
и **~64 GB RAM** (или большой swap). Полное дерево LOS21-pre-QPR2 — это более тысячи проектов (~250–400 GB с `.repo`,
Git-объектами, LFS и `out/`). Это физически не помещается на бесплатный hosted runner.
Два последних прогона `mode=build` ([43602208859](https://github.com/devramsk/lin/actions/runs/43602208859) — с `--depth=1`,
[43863633480](https://github.com/devramsk/lin/actions/runs/43863633480) — на ubuntu-24.04) остановились на этапе `sync`
(disk guard / нехватка места). Патчи и компиляция не начинались в обоих случаях.

**Вывод:** в GitHub Actions бесплатно выполняются `preflight`, установка зависимостей, инвентаризация upstream
и поэтапная попытка `build` (с reclaim диска). Гарантированно рабочая сборка — только на постоянном Ubuntu 24.04 сервере
(см. README, раздел «Локальный сервер»). Полное «продолжение с остановленного места» между разными job-ами GitHub Actions
невозможно: VM одноразовая, `/tmp` не сохраняется, 10 GB cache не вместит `.repo` + `out/`.

## 3. Один раз включить в настройках репозитория

Все пункты — в вашем репозитории на github.com, под владельцем/администратором. Платный тариф не нужен.

1. **Settings → Actions → General → Actions permissions**: разрешить Actions
   (достаточно «Allow all actions and reusable workflows» либо «Allow ... only local + GitHub Actions» —
   наш workflow использует только `actions/checkout` и `actions/upload-artifact` + `run:`-шаги).
2. **Settings → Actions → General → Workflow permissions**: выбрать
   **«Read and write permissions»**. Иначе шаг `Commit audit bundle to repository branch`
   не сможет запушить ветку `audit/*` (workflow при этом НЕ упадёт — будет `::warning::`,
   а логи останутся в артефакте job-а). Галку «Allow GitHub Actions to create and approve pull requests»
   включать **не нужно** — аудит коммитится в отдельную ветку без PR.
3. **Settings → Actions → General → Artifact and log retention**: можно поставить 3 дня
   (наши артефакты всё равно загружаются с `retention-days: 3`; лимит Free — 500 MB).
4. Проверка, что ветка аудита не ломает default branch: ветки `audit/*` — сиротские
   (orphan), истории коммитов не пересекаются; ветку `main` они не трогают вообще.
   Удалить старую ветку аудита: `git push origin --delete audit/<run_id>-<attempt>`.

## 4. Как Arena получает право запускать Actions (без токенов в чате)

Никаких паролей/PAT/OAuth-токенов в чат передавать не нужно и нельзя. Доступ выдаётся один раз
через GitHub App, установленное на репозиторий:

1. В Arena переподключите GitHub: в настройках Arena нажмите **GitHub → Reconnect**
   (если доступ уже был — «Reconfigure access»).
2. Откроется страница установки GitHub App. Выберите **Only select repositories → devramsk/lin**.
3. Права, которые запрашивает приложение (минимум для нашей работы):
   - **Contents: Read and write** — чтобы пушить ветки, включая аудит-ветки;
   - **Workflows: Read and write** — чтобы менять файлы в `.github/workflows/`;
   - **Actions: Read and write** — чтобы диспатчить workflow и читать прогоны;
   - **Metadata: Read** (всегда обязателен).
4. Нажмите **Install / Save**.
5. Владелец репозитория может подтвердить/проверить установку:
   **GitHub → Settings → Applications → Installed GitHub Apps → (приложение Arena)**
   → должно быть видно: `Repository access: devramsk/lin` и права выше.
6. В репозитории: **Settings → Actions → General → Workflow permissions → Read and write permissions** (см. п. 3.2).
7. Проверка без сборки: в чате попросите Arena «запусти probe на текущей ветке» — он выполнит
   `gh workflow run build-gsi.yml --ref <branch> -f mode=probe` и сообщит результат.

Если после переподключения сборка всё равно получает "Resource not accessible" — значит,
в п. 3.2 или в п. 5 прав не хватает; сама сборка от этого не сломается, не будет только публикации аудит-ветки.

## 5. Как запустить сборку самому

### Из интерфейса
1. Репозиторий → **Actions** → workflow **LineageOS 21 pre-QPR2 GSI** → **Run workflow**.
2. Ветка: та, где лежит workflow (обычно `main` после слияния, либо ваша `arena/...`-ветка).
3. Параметры:
   - `mode`: `build` — попытка полной поэтапной сборки; `probe` — быстрая проверка (скрипты, зависимости, инвентарь upstream);
   - `reclaim_space`: `true` — удалить предустановленные Android SDK/.NET/GHC/PowerShell
     в одноразовой VM (рекомендуется; экономит до ~15–25 GB);
   - `shallow` / `partial`: экспериментальные, по умолчанию `false`;
   - `commit_audit`: `true` — коммитить аудит-бандл в ветку `audit/<run_id>-<attempt>`.
4. Запуск стартует только на GitHub-hosted `ubuntu-24.04`. Кнопки выбора self-hosted нет намеренно.

### Из CLI (`gh`)
```bash
gh workflow run build-gsi.yml --ref main -f mode=build -f reclaim_space=true -f commit_audit=true
gh run list --workflow=build-gsi.yml --limit 3
gh run watch <run-id> --exit-status
```

## 6. Что получится по завершении

- **Job summary** (в интерфейсе прогона): таблица событий этапов из `audit/events/*` + финальная заполненность диска.
- **Ветка `audit/<run_id>-<attempt>`** (если `commit_audit=true` и Workflow permissions = Read and write):
  - `AUDIT-INFO.txt` — какой запуск, какой коммит;
  - `AUDIT-MANIFEST.txt` — SHA-256 всех файлов; файлы > 90 MB разбиты на `.part-NN`;
  - `events/`, `logs/`, `resources.log`, `resolved-manifest.xml` (после полного sync), `SHA256SUMS` (после validate), `result.txt`.
  - Внутренний `.git` локального аудит-репозитория туда не попадает.
- **Artifacts** (хранение 3 дня, лимит Free 500 MB): те же `logs/`, `events/`, `resources.log`,
  `resolved-manifest.xml`, `SHA256SUMS`, `audit-history.bundle`, а при успехе — оба образа (`*.img`,
  без сжатия — они уже сжаты). Если квота артефактов исчерпана, шаги загрузки помечены
  `continue-on-error` и не валят job; ветка `audit/*` от квоты не зависит.
- **SHA256SUMS**: проверка образов после сборки. Не подписанные образы — как и в исходном проекте AndyCGYan.

Восстановление файлов из ветки аудита локально:
```bash
git fetch origin '+refs/heads/audit/*:refs/remotes/origin/audit/*'
git checkout audit/<run_id>-<attempt> -- .   # или: git archive / worktree
# файлы > 90 MB собираются обратно:
cat <имя>.part-* > <имя>
sha256sum -c AUDIT-MANIFEST.txt              # после ручной правки путей при необходимости
```

## 7. Повторный запуск и «продолжение с остановленного места»

- **Внутри одного job-а** этапы идут последовательно: `preflight → setup → sync → patch → build-64VN → build-64GN → validate`.
  Падение этапа останавливает цепочку; порядок в логах и сводке показывает, где остановился процесс.
- **Между запусками GitHub Actions продолжение невозможно**: VM уничтожается, диск чистый, `/tmp` не переживает job,
  кэш (10 GB) не вместит `.repo` + `out/`. Каждый `mode=build` начинает с нуля.
- **На постоянном диске** (локальный сервер, ваша рабочая станция) возобновление реальное:
  скрипт `scripts/build-gsi.sh` хранит маркеры `audit/<stage>.done` в `BUILD_ROOT` и при повторном запуске
  пропускает завершённые этапы; `repo sync`, `repopick` (пропускает уже подхваченные изменения),
  патчи (`git reset --hard` + повторное применение) и ninja в `out/` сами инкрементальны.
  Для поэтапного сценария: `STOP_AFTER=init`, `STOP_AFTER=build` и т.д.

## 8. Частые вопросы

- **«Waiting for a runner» и прогресс не идёт**: проверьте, что запуск создан на workflow из ветки, где workflow исправлен;
  убедитесь, что нет `self-hosted`-меток (их нет в текущем файле) и что не исчерпаны минуты (для публичного репозитория минуты бесплатны).
  Если очередь — это временные проблемы GitHub; проверьте [githubstatus.com](https://www.githubstatus.com). Сборка **не требует** self-hosted.
- **«No space left on device»**: ожидаемо на бесплатном runner-е на этапе `sync`; включите `reclaim_space=true`;
  если не помогает — это неустранимое на Free-плане ограничение (см. п. 2), используйте локальный сервер.
- **Workflow пропустили этап / "Missing prerequisite checkpoint"**: staged-скрипт не перепрыгивает этапы;
  диск job-а чист — запустите заново или см. раздел 7 для локального сервера.
- **Нет ветки `audit/*`**: проверьте Workflow permissions = Read and write (п. 3.2) и что `commit_audit=true`.
- **Артефакты не загрузились**: квота Free (500 MB) могла быть исчерпана; аудит-ветка при этом появляется.
- **Как отменить прогон**: Actions → нужный прогон → **Cancel workflow**. Отмена не гарантирует выгрузку логов.
- **Нужны ли платные тарифы?** Нет. Всё вышеописанное работает на бесплатном плане.
- **Можно ли использовать self-hosted runner?** Нельзя (правило проекта). Не регистрируйте self-hosted runner-ы с метками этого workflow.

## 9. Лицензии и безопасность

- `64GN` использует MindTheGapps — проверяйте лицензии Google Apps перед распространением.
- Образы не подписаны. Ключи подписи никогда не передаются в Actions и не хранятся в репозитории.
- В workflow нет секретов; `GITHUB_TOKEN` используется только job-ом `build` и только для ветки `audit/*`
  (`contents: write`), остальные job-ы — `contents: read`.
- Репозиторий публичный → логи и аудит-ветка публичны. Не добавляйте в команды сборки приватные данные.
- `reclaim-hosted-space.sh` удаляет только фиксированные системные каталоги предустановленных SDK в одноразовой VM;
  на личных машинах не запускайте.
