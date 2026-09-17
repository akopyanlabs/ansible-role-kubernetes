# Changelog

Все заметные изменения в роли `kubernetes` фиксируются в этом файле.

Формат ориентирован на Keep a Changelog.

## [1.4.0] - 2026-09-17

### Fixed

- **Добавление master-ноды с `--limit`**: блок gather facts в `tasks/components/main.yml` больше не привязан к узкому тегу и добирает факты (`ansible_default_ipv4`) только недостающих мастеров — haproxy-шаблон больше не падает на undefined при запуске `--tags kubernetes_add_master_node --limit <новая нода>`.
- **Проверка «нода уже присоединена»** (`tasks/master/main.yml`, `tasks/worker/main.yml`): `stat kubelet.conf` выполняется ДО генерации `upload-certs`/join-токена; токен создаётся только если есть ноды к присоединению.
- **Masters-only inventory**: обращение к `groups[kubernetes_worker_group_name]` в `tasks/worker/main.yml` и `tasks/cis-settings/main.yml` защищено `| default([])` — `kubernetes_first_init` без группы воркеров больше не падает.
- **Calico `init-calico.yml.j2`**: литеральный плейсхолдер `CONTROLPLANE_NODESELECTOR` (не обрабатывается build-скриптом) заменён на `{{ kubernetes_calico_controlplane_nodeselector }}`; podAntiAffinity typha/kube-controllers/apiserver использует собственные лейблы (`calico-typha`, `calico-kube-controllers`, `calico-apiserver`) вместо `tigera-operator`.
- **JWT auth-config** (`templates/kubeapi/auth-config.yml.j2`): заголовок списка `audiences:` вынесен из `{% for %}` — при двух и более audiences рендерился невалидный YAML.
- **Docker apt-репозиторий**: дистрибутив больше не захардкожен (`bullseye`), используется `{{ ansible_distribution_release }}`.
- **fetch admin.conf**: права `0777` → `0600`.
- **`kubernetes_check_existing_nodes`**: сравнение с кластером теперь по master- и worker-группам.
- Дублирующееся имя таски kubelet-csr-approver в `tasks/main.yml`.

### Changed

- **BREAKING: metrics-server** — жёсткий `nodeSelector` заменён на preferred nodeAffinity + tolerations `node-role.kubernetes.io/control-plane`; дефолт `kubernetes_extensions_metrics_server_node_labels: "app"` → `"control-plane"`. Поды по умолчанию едут на control-plane ноды; прежнее поведение требовало лейбл со значением `true`, теперь достаточно наличия лейбла.
- **Affinity required → preferred везде** (продолжение работы из 1.3.0): CoreDNS-патч (`patch-core-dns.yml`) и kubelet-csr-approver переведены на `preferredDuringSchedulingIgnoredDuringExecution` с weight 100.

### Added

- **Перезапуск подов при изменении конфигов**: CoreDNS Deployment получает аннотацию `checksum/config` (checksum Corefile) — изменение конфига провоцирует rolling restart; NodeLocal DNS DaemonSet перезапускается при изменении применённого манифеста.
- **Ожидание готовности Calico**: после `init-calico` роль ждёт `Installation/status.conditions[Ready]=True` (retries 30 × 10s) — плейбук останавливается, если Calico не установился.
- **Calico node IP autodetection**: переменная `kubernetes_calico_node_address_autodetection` (`first-found`, `interface=eth.*`, `can-reach=…`; пусто — не рендерится).
- **Отключение firewalld** в `tasks/prepare` (no-op, если не установлен; переменная `kubernetes_disable_firewalld: true`).
- **Веса HAProxy backend per-master**: переменная `kubernetes_haproxy_weights` (map host → weight, дефолт 100).
- **README**: раздел «Интеграция с Keycloak (OIDC)» — переменные, настройка realm/client, ClusterRoleBinding на группы, kubelogin.

## [1.3.0] - 2026-05-07

### Changed

- **Calico CNI**: обновлён Tigera operator (chart v3.32.0, operator v1.42.0).
  - Добавлен `controlPlaneTolerations` с `operator: Exists` — все control plane компоненты Calico могут запускаться на любых нодах.
  - Добавлен `nodeAffinity` (required) на `control-plane` ноды для typha, kube-controllers, apiserver и tigera-operator.
  - Добавлен `podAntiAffinity` (required) для typha, kube-controllers и apiserver — запрещено размещение двух подов одного компонента на одной ноде.
  - Конфигурация `apiserverDeployment` перенесена из ресурса `Installation` в ресурс `APIServer` (согласно API `operator.tigera.io/v1`).
  - Исправлена вложенность `typhaDeployment` и `calicoKubeControllersDeployment`: путь `spec.template.spec.affinity` вместо `spec.affinity`.
  - Оператор tigera-operator теперь получает affinity через Helm values и build-скрипт (`tools/cni/build-calico.sh`), а не прямым редактированием шаблона.
- **Server-Side Apply**: исправлен синтаксис `kubernetes.core.k8s` во всех extension-тасках:
  - `field_manager` перемещён внутрь `server_side_apply`.
  - `force` переименован в `force_conflicts`.
  - Добавлен `apply: yes` — без него `server_side_apply` игнорировался.
- **defaults/main.yml**: переменная `kubernetes_calico_chart_version` обновлена на `v3.32.0`.

### Added

- `templates/manifests/cni/calico/v3.31.5/` — версионированные манифесты Tigera operator (chart v3.31.5).

## [1.2.0] - 2026-05-05

### Changed

- **Ingress контроллер**: ingress-nginx заменён на Traefik (Helm chart v34.2.0, Traefik v3.3.2).
  - Один образ вместо трёх (`docker.io/traefik:v3.3.2`).
  - Манифесты хранятся в версионированных директориях (`templates/manifests/ingress/traefik/v34.2.0/`).
  - CRD IngressRoute, Middleware, TLSOption доступны из коробки.
- **Тег**: `kubernetes_install_ingress_nginx` → `kubernetes_install_ingress`.
- **defaults/main.yml**: переменные `kubernetes_extensions_ingress_nginx_*` заменены на `kubernetes_extensions_traefik_*`.
- **tools/push-images.sh**: ingress-компонент обновлён для Traefik (один образ).

### Added

- `tools/ingress/build-traefik.sh` — скрипт генерации манифестов Traefik из Helm chart с Jinja2 для registry и NodePort.
- `templates/manifests/ingress/traefik/v34.2.0/` — версионированные манифесты Traefik (chart v34.2.0).
- `tasks/extensions/ingress/traefik.yml` — задача установки Traefik с динамическим поиском манифестов.

### Removed

- `templates/manifests/ingress/ingress-nginx.yml.j2` — заменён версионированными манифестами Traefik.
- `tasks/extensions/ingress/ingress-nginx.yml` — заменён `traefik.yml`.

## [1.1.0] - 2026-05-05

### Changed

- Обновлены версии тегов образов:
  - `pause: 3.9` → `3.10`
  - `k8s-dns-node-cache: 1.24.0` → `1.26.8`
  - `kubelet-csr-approver: v1.2.6` → `v1.2.14`
  - `metrics-server: v0.7.2` → `v0.8.1`
- `kubernetes_extensions_kubelet_csr_approver_enabled` включён по умолчанию (`true`).


- **Calico CNI**: единый файл `install-calico-operator.yml.j2` заменён на версионированные директории по версии Helm chart'а Tigera operator (`templates/manifests/cni/calico/v3.32.0/`).
- **Задача установки Calico** (`tasks/extensions/cni/calico.yml`): переписана на динамический поиск манифестов через `with_filetree` и `ansible.builtin.find` вместо фиксированного списка файлов.
- **Переменная `kubernetes_calico_cni_image_repository`**: теперь подставляется только как registry (например `quay.io`), полный путь образа (`tigera/operator:v1.40.8`) остаётся из `helm template`.
- **defaults/main.yml**: добавлена переменная `kubernetes_calico_chart_version` для указания активной версии чарта.

### Removed

- Файл `templates/manifests/cni/calico/install-calico-operator.yml.j2` — заменён версионированными манифестами.
- Переменная `kubernetes_tigera_image_tag` — тег образа берётся из сгенерированного манифеста.

### Added

- `templates/manifests/cni/calico/v3.32.0/` — версионированные манифесты Tigera operator (Helm chart v3.32.0, operator v1.40.8).
- `tools/cni/build-calico.sh` — скрипт генерации манифестов из Helm chart с подстановкой Jinja2 для registry.
- `tools/cni/push-calico-images.sh` — скрипт публикации Calico-образов в приватный registry (14 Linux-образов).

## [1.0.1] - 2026-04-22

### Changed

- Перенесена подготовка `kube-apiserver` auth config в [tasks/components/main.yml](tasks/components/main.yml), чтобы использовать общую настройку компонентов вместо дублирования в сценариях bootstrap и join.
- Отрефакторен [tasks/components/main.yml](tasks/components/main.yml): задачи сгруппированы в block'и по типам работ (`packages`, `haproxy`, `kube-apiserver auth`, `containerd`, `services`, `cli tools`).
- Добавлена переменная `kubernetes_kubectl_user_home` для управления путём пользовательского kubeconfig.
- `kubeadm init`, `join master` и `join worker` сделаны идемпотентнее через проверки существования `admin.conf` и `kubelet.conf`.
- Исправлены права на директории private registry config для `containerd`: `0755` вместо `0644`.
- Поведение `kubernetes_add_worker_node` уточнено: `cordon`, labels и taints применяются только к новым worker нодам в рамках текущего onboarding.
- Добавлена поддержка `kubernetes_node_labels` и `kubernetes_node_taints` в [tasks/enviroment/node-labels.yml](tasks/enviroment/node-labels.yml).
- Добавлен merge существующих и новых taints вместо полного перезаписывания `spec.taints`.

## [1.0.0] - 2026-04-01

### Added

- Добавлен `systemd` override для `haproxy` через `override.conf`.
- Добавлены настройки `kubernetes_haproxy_oom_score_adjust` и `kubernetes_haproxy_restart_sec` в [defaults/main.yml](defaults/main.yml).
- В `haproxy` добавлены настройки `OOMScoreAdjust`, `Restart=on-failure` и `RestartSec`.
- Скрипт [haproxy-state.sh](files/haproxy/haproxy-state.sh) расширен режимами:
  - обычная табличная сводка
  - `--down`
  - `--watch <seconds>`
  - `--json`
- В `haproxy-state.sh` добавлены:
  - summary по backend-серверам
  - расширенные колонки `address`, `sessions`, `weight`, `check`
  - цветной вывод статусов
  - базовые проверки наличия `socat` и stats socket
- Полностью обновлён [README.md](README.md):
  - добавлено описание архитектуры роли
  - добавлены примеры inventory, vars и playbook
  - добавлено описание тегов
  - добавлены примеры использования `haproxy-state`

### Fixed

- Исправлено имя файла `haproxy-state.sh` в роли.
- Исправлена совместимость `haproxy-state.sh` с используемой реализацией `awk`.
- Исправлена опечатка в примере `kubernetes_service_cidr` в [README.md](README.md).
