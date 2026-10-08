# Инфраструктура (infra)

Здесь лежат скрипты, которые поднимают локальный DevSecOps-стенд для приложения
VulnShop. Стенд целиком работает на одной машине и состоит из трёх частей:

1. GitLab CE с раннером и Docker-in-Docker — в нём крутится CI/CD.
2. Staging-виртуалка на Multipass — сюда пайплайн деплоит приложение и здесь его
   сканирует OWASP ZAP.
3. Телеметрия на OpenSearch + Dashboards — сюда стекаются находки сканеров,
   события джоб пайплайна и логи приложения с VM.

Всё разворачивается тремя setup-скриптами. Каждый идёт по шагам, пишет подробный лог
в соседний `*.log` файл и идемпотентен: повторный запуск ничего не ломает и не
дублирует, а только доводит стенд до нужного состояния. Флаг `--reset` сносит то,
что создал этот скрипт (вместе с данными), и поднимает заново.

Скрипты работают относительно своей папки, поэтому их можно запускать откуда угодно.

## Требования

- macOS или Linux, Docker с Compose v2 (Docker Desktop), Multipass, `git`, `openssl`, `curl`.
- Права `sudo`: при первом запуске `setup-gitlab.sh` дописывает `127.0.0.1 gitlab.test`
  в `/etc/hosts`, чтобы GitLab открывался в браузере.
- Интернет при первом запуске: скачать образы, а новой VM — поставить Docker через
  cloud-init. Дальше всё работает офлайн.

## Порядок запуска

```bash
./setup-gitlab.sh          # 1. GitLab + раннер + DinD, импорт репозитория
./setup-staging-env.sh     # 2. staging-VM (нужен GitLab: его CA и проект для CI-переменных)
./setup-opensearch.sh      # 3. OpenSearch + Dashboards (нужны GitLab и запущенная VM)
```

Почему именно так:

- `setup-staging-env.sh` берёт CA из `certs/` и записывает CI-переменные в проект
  GitLab, поэтому идёт после `setup-gitlab.sh`.
- `setup-opensearch.sh` подключается к docker-сети GitLab, а порт `9200` для Fluent Bit
  публикует на адресе, через который VM видит хост. Если VM не запущена, этот порт не
  откроется (скрипт об этом напишет) — тогда его достаточно просто запустить ещё раз.
- Fluent Bit на VM от OpenSearch не зависит: пока OpenSearch нет, он копит логи на диске
  и повторяет отправку.

Первый пайплайн стартует сам, когда `setup-gitlab.sh` импортирует репозиторий, — ещё до
VM и CI-переменных, поэтому деплой и ZAP в нём упадут. После третьего скрипта пайплайн
нужно запустить вручную: Build → Pipelines → Run pipeline.

## Как снести всё

Порядок обратный: OpenSearch подключён к сети GitLab, и пока он в ней, сеть не удалится.

```bash
./setup-opensearch.sh --reset   # или: docker compose -p telemetry down -v
docker compose -p gitlab down -v
multipass delete --purge staging
```

## Скрипты

### setup-gitlab.sh

Поднимает локальный GitLab CE и всё, что нужно для CI/CD.

Что делает по шагам:

- если в `/etc/hosts` нет `gitlab.test`, дописывает `127.0.0.1 gitlab.test` (через `sudo`);
- создаёт собственный CA и подписывает им сертификат для `gitlab.test`
  (в SAN: `DNS:gitlab.test`, `IP:127.0.0.1`); если сертификаты уже есть — пропускает;
- пишет `docker-compose.yml` (compose-проект `gitlab`) и поднимает три контейнера:
  - `gitlab` — GitLab CE и Container Registry на порту `5050`;
  - `gitlab-dind` — отдельный Docker-демон, внутри которого выполняются все CI-джобы;
  - `gitlab-runner` — забирает джобы у GitLab и запускает их в DinD;
- ждёт, пока поднимется Rails и ответит HTTPS;
- задаёт пароль root, только если root ещё ни разу не входил; токен API (PAT)
  создаётся при каждом запуске заново, старые токены скрипта отзываются;
- регистрирует раннер (тег `docker`, без untagged-джоб); если раннер уже рабочий — не трогает;
- применяет базовые настройки безопасности: регистрация закрыта, проекты приватные,
  обязательная 2FA, минимальная длина пароля 12;
- импортирует в GitLab репозиторий (все ветки и теги);
- сохраняет `gitlab-secrets.json`.

Все порты GitLab опубликованы только на `127.0.0.1`: `443` (веб и API), `5050` (registry),
`2222` (SSH), `80` (редирект на HTTPS). Снаружи машины GitLab не виден.

Переменные окружения:

- `REPO_SRC` — какой репозиторий импортировать (по умолчанию тот, в котором лежит скрипт);
- `PROJECT_NAME` — имя проекта в GitLab (по умолчанию имя папки репозитория,
  проект получается `root/<имя>`);
- `RUNNER_DNS` — DNS для контейнеров джоб (по умолчанию `192.168.65.7`, DNS Docker Desktop;
  пустое значение — не задавать).

`--reset` удаляет контейнеры, их тома и сгенерированные файлы (`certs/`, `gitlab/`,
`runner/`, `docker-compose.yml`, `gitlab-secrets.json`).

В конце скрипт печатает адрес проекта, логин, пароль (если задавал его в этом запуске)
и новый PAT.

### setup-staging-env.sh

Создаёт staging-окружение — виртуальную машину Multipass (Ubuntu), куда пайплайн
деплоит приложение.

Что делает по шагам:

- генерирует SSH-ключ деплоя (`.staging/deploy_key`), если его ещё нет;
- пишет cloud-init: при создании VM он ставит `docker.io`, `docker-compose-v2` и `ufw`;
- создаёт VM, если её нет, запускает, если она выключена, и ждёт окончания cloud-init;
- настраивает VM:
  - пользователь `deploy` в группе `docker`, вход только по ключу;
  - CA GitLab в системном хранилище доверенных сертификатов;
  - `gitlab.test` → `127.0.0.1` в `/etc/hosts` VM (туда приходит туннель деплоя);
  - SSH: без паролей и без root; пробрасывать порты разрешено только `deploy` и только
    на `127.0.0.1:5050` и `127.0.0.1:443`;
  - ufw: входящие запрещены, SSH разрешён только из подсети Multipass;
- доставляет на VM образ Fluent Bit: у VM может не быть интернета, поэтому образ
  скачивает хост и передаёт файлом (`docker save` → `multipass transfer` → `docker load`);
- настраивает Fluent Bit: принимает логи контейнеров приложения от Docker
  (log driver `fluentd`, `127.0.0.1:24224`), разбирает строки access-лога
  (IP, метод, путь, код ответа) и отправляет их в OpenSearch на хосте, в индекс
  `app-logs-ГГГГ.ММ.ДД`; контейнер пересоздаётся, только если изменились конфиг или образ;
- сохраняет host-key VM в `.staging/known_hosts` (берёт его изнутри VM, а не по сети);
- записывает в CI/CD-переменные проекта `STAGING_HOST`, `STAGING_USER`,
  `STAGING_SSH_KEY`, `STAGING_KNOWN_HOSTS` (все protected, ключ и known_hosts — типа file).

Как деплой-джоба доставляет образы: registry слушает только `127.0.0.1` хоста, поэтому
джоба открывает обратный SSH-туннель (`-R 127.0.0.1:5050` и `-R 127.0.0.1:443`), и VM
делает `docker pull` через него (`443` нужен для выдачи токенов registry).

Переменные окружения: `VM_NAME` (по умолчанию `staging`), `VM_IMAGE` (`24.04`),
`VM_CPUS` (`2`), `VM_MEMORY` (`2G`), `VM_DISK` (`15G`), `FLUENT_BIT_IMAGE`
(`fluent/fluent-bit:5.1.2`), `PROJECT_PATH` (по умолчанию `root/<имя папки репозитория>`),
`CA_FILE`, `STAGING_DIR`.

`--reset` удаляет VM и папку `.staging/`.

### setup-opensearch.sh

Поднимает телеметрию.

Что делает по шагам:

- пишет `telemetry/docker-compose.yml` (compose-проект `telemetry`) и поднимает
  OpenSearch и OpenSearch Dashboards, дожидаясь, пока оба станут healthy;
- применяет шаблоны индексов — заранее задаёт типы полей для `findings*`,
  `pipeline-events*` и `app-logs*`;
- создаёт index patterns в Dashboards и импортирует дашборды из `telemetry/dashboards/*.ndjson`;
- записывает в CI/CD-переменные проекта `OPENSEARCH_URL` (не protected: это не секрет).

Как к OpenSearch обращаются:

| Кто | Адрес |
|---|---|
| хост (браузер, CLI) | `http://127.0.0.1:9200`, Dashboards — `http://127.0.0.1:5601` |
| CI-джобы в DinD | `http://172.30.0.20:9200` — постоянный IP в сети GitLab |
| Fluent Bit на VM | `http://<шлюз VM>:9200`, обычно `192.168.252.1` |

OpenSearch работает в режиме одного узла, heap по умолчанию `512m` (GitLab уже занимает
заметную часть памяти). Security plugin выключен: порты опубликованы только на
`127.0.0.1` и на адресе моста Multipass, снаружи машины их не видно. Для продакшена это
не годится — нужны TLS и пользователи.

Переменные окружения: `OPENSEARCH_IP`, `OPENSEARCH_HEAP`, `VM_NAME`, `PROJECT_PATH`.

`--reset` удаляет контейнеры, том с данными и `telemetry/docker-compose.yml`.

### telemetry.py

Python-скрипт джобы `telemetry` — последней джобы пайплайна (стадия `report`,
`when: always`, поэтому выполняется даже при красных гейтах). Только стандартная
библиотека: в джобе не нужен `pip`.

Что делает:

- читает JSON-отчёты сканеров из артефактов предыдущих джоб: Gitleaks (секреты),
  Semgrep (SAST), Trivy (SCA, образы, Dockerfile), OWASP ZAP (DAST); если какого-то
  отчёта нет, пишет предупреждение и отправляет остальные;
- приводит находки к единой схеме: `tool`, `category`, `rule_id`, `title`, `severity`
  (`critical/high/medium/low/info`), `location`, `fingerprint`;
- `fingerprint` — устойчивый отпечаток находки, одинаковый между прогонами (в него не
  входят digest образа и IP VM); по нему можно понять, какие находки новые,
  повторяющиеся и исправленные;
- сами секреты из отчёта Gitleaks в OpenSearch не отправляет — только правило и место;
- берёт список джоб пайплайна из GitLab API (хватает встроенного `CI_JOB_TOKEN`) и пишет
  события в `pipeline-events`: имя, стадия, статус, длительность, причина падения;
- печатает сводку «инструмент → число находок по severity» и отправляет всё в OpenSearch
  через `_bulk`; `_id` постоянный, поэтому перезапуск джобы перезаписывает документы,
  а не дублирует их.

Настройки берёт из переменных окружения CI: `OPENSEARCH_URL`, `CI_PIPELINE_ID`,
`CI_COMMIT_SHA`, `CI_JOB_ID`, `CI_JOB_TOKEN` и т.д.; папку с отчётами — из `REPORT_DIR`
(по умолчанию текущая).

## Файлы, которые создают скрипты

В git лежат только скрипты, `telemetry.py`, этот README и дашборды
(`telemetry/dashboards/`). Всё остальное генерируется и исключено в `.gitignore`:

- `docker-compose.yml` — compose стенда GitLab (`gitlab`, `dind`, `gitlab-runner`,
  сеть `172.30.0.0/24`);
- `telemetry/docker-compose.yml` — compose телеметрии (`opensearch`, `dashboards`);
- `certs/` — локальный CA (`ca.crt`, `ca.key`, `ca.srl`);
- `gitlab/config/ssl/` — ключ и сертификат `gitlab.test`;
- `runner/config/` — конфиг раннера с его токеном;
- `.staging/` — ключ деплоя (`deploy_key`, `deploy_key.pub`), `known_hosts`, cloud-init;
- `gitlab-secrets.json` — ключи шифрования GitLab;
- `*.log` — логи setup-скриптов.

Секреты среди них: `certs/ca.key`, `gitlab/config/ssl/gitlab.test.key`,
`runner/config/config.toml`, `.staging/deploy_key`, `gitlab-secrets.json`. Они нужны
только локальному стенду и не должны попадать в репозиторий.
