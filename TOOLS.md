# Инструменты и версии

Все версии зафиксированы явно — в `.gitlab-ci.yml` и в `infra/setup-*.sh`. Тегов `latest`
нет: каждый прогон использует ровно те же инструменты, а обновление видно в diff.

## Платформа CI/CD

| Инструмент | Версия | Где задана | Зачем |
|---|---|---|---|
| GitLab CE | `gitlab/gitlab-ce:19.2.7-ce.0` | `infra/setup-gitlab.sh` | репозиторий, CI/CD, Container Registry |
| GitLab Runner | `gitlab/gitlab-runner:alpine-v19.2.0` | `infra/setup-gitlab.sh` | выполняет джобы (docker executor, тег `docker`) |
| Docker-in-Docker | `docker:24-dind` | `infra/setup-gitlab.sh` | отдельный Docker-демон, в котором живут джобы — не Docker хоста |

## Сборка

| Инструмент | Версия | Джоба | Зачем |
|---|---|---|---|
| Kaniko | `gcr.io/kaniko-project/executor:v1.23.2-debug` | `build-images` | сборка образов без Docker-демона и без privileged |

## Проверки безопасности

| Инструмент | Версия | Джоба | Что проверяет | Порог (гейт) |
|---|---|---|---|---|
| Gitleaks | `zricethezav/gitleaks:v8.18.4` | `gitleaks` | секреты во всей истории git | любая находка |
| Semgrep | `semgrep/semgrep:1.178.0-nonroot` | `semgrep` | SAST: Python и JavaScript | `ERROR`, `WARNING` |
| Syft | `anchore/syft:v1.54.1-debug` | `syft-sbom` | составляет SBOM (CycloneDX 1.6) по образам и `package-lock.json` | — (это опись, не проверка) |
| Dependency-Track | `dependencytrack/bundled:4.14.5` | `dt-sca` | SCA: уязвимые компоненты в SBOM | `CRITICAL`, `HIGH` |
| curl | `curlimages/curl:8.22.0` | `dt-sca` | отправка SBOM в Dependency-Track и получение находок | — |
| Trivy | `aquasec/trivy:0.50.1` | `trivy-container` | ошибки конфигурации Dockerfile (`trivy config`) | `CRITICAL`, `HIGH` |
| OWASP ZAP | `ghcr.io/zaproxy/zaproxy:2.16.1` | `zap-scan` | DAST: baseline по frontend, full scan по backend | риск `High` |

Почему именно так:

- **Syft + Dependency-Track вместо одного Trivy для SCA.** Syft делает SBOM нужной версии
  (CycloneDX 1.6) и только это. Dependency-Track хранит состояние каждого проекта между
  прогонами: одна и та же уязвимость не считается заново, видно новые и исправленные,
  false positive помечается в интерфейсе с обоснованием и перестаёт ломать гейт.
- **Trivy оставлен только для Dockerfile.** Уязвимости образов теперь считает
  Dependency-Track по SBOM; если оставить и `trivy image`, одни и те же CVE считались бы
  дважды.
- **Два источника SBOM для frontend.** В образ frontend библиотеки попадают просто
  файлами `.min.js`, без `package.json`, — по образу их не видно ни Syft, ни Trivy.
  Поэтому SBOM frontend делается по образу (ОС, nginx) и по `package-lock.json`
  (jquery, lodash, axios).
- **Источник уязвимостей Dependency-Track — OSV** (PyPI, npm, Debian, Alpine): скачивается
  один раз (~4 мин) и дальше работает офлайн. NVD без API-ключа качается часами,
  OSS Index и npm audit требуют токен или интернет при каждом анализе — выключены.

## Развёртывание (staging)

| Инструмент | Версия | Где | Зачем |
|---|---|---|---|
| Multipass | `1.16.4` (на хосте) | `infra/setup-staging-env.sh` | staging-VM |
| Ubuntu | `24.04` | `infra/setup-staging-env.sh` (`VM_IMAGE`) | ОС VM |
| Docker на VM | `docker.io` из репозитория Ubuntu (проверено на `29.1.3`) | cloud-init | запуск backend и frontend на VM |
| alpine/git | `alpine/git:2.47.2` | `test-stage` | ssh-клиент для деплоя на VM (обратный SSH-туннель к registry) |

## Телеметрия

| Инструмент | Версия | Где | Зачем |
|---|---|---|---|
| OpenSearch | `opensearchproject/opensearch:3.9.0` | `infra/setup-opensearch.sh` | хранилище находок, событий джоб и логов приложения |
| OpenSearch Dashboards | `opensearchproject/opensearch-dashboards:3.9.0` | `infra/setup-opensearch.sh` | поиск и графики |
| Fluent Bit | `fluent/fluent-bit:5.1.2` | `infra/setup-staging-env.sh` | на VM: логи контейнеров приложения → OpenSearch |
| Python | `python:3.13-alpine` | `telemetry` | `infra/telemetry.py`: находки и события джоб → OpenSearch (только стандартная библиотека) |

## На чём проверено

| | Версия |
|---|---|
| Хост | macOS 26.5.2, Apple Silicon (arm64), 16 ГБ RAM |
| Docker Desktop | Engine `28.5.1`, Compose `2.40.3` |
| Multipass | `1.16.4` |

`setup-gitlab.sh` сам выбирает платформу образов (`linux/arm64` или `linux/amd64`),
но на `amd64` стенд не проверялся.
