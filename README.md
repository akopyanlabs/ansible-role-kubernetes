# Kubernetes Ansible Role

Роль для развёртывания Kubernetes-кластера с `kubeadm`.

Основная архитектурная особенность роли: обращения к Kubernetes API проходят через локальный `haproxy` на control-plane нодах. Это позволяет не зависеть от внешнего load balancer и держать кластер максимально автономным.

## Требования

- Python `3.11+`
- Установленные Python-зависимости из [requirements.txt](requirements.txt)
- Ansible-контроллер с доступом по SSH ко всем нодам
- Подготовленный inventory с группами master и worker нод

Установка зависимостей:

```bash
pip install -r requirements.txt
```

## Что делает роль

Роль покрывает следующие этапы:

- подготовка ОС для Kubernetes
- установка `containerd`, `kubeadm`, `kubelet`, `kubectl` и сопутствующих пакетов
- настройка локального `haproxy` для доступа к Kubernetes API
- инициализация первого control-plane узла
- добавление дополнительных control-plane и worker нод
- установка сетевых и инфраструктурных расширений
- применение части hardening-настроек

Структура задач:

- `tasks/prepare`: подготовка ОС
- `tasks/components`: установка пакетов и базовых компонентов
- `tasks/init-cluster`: первичная инициализация кластера
- `tasks/master`: подключение дополнительных control-plane нод
- `tasks/worker`: подключение worker нод
- `tasks/extensions`: CNI, DNS, ingress, metrics, CSR approver
- `tasks/enviroment`: вспомогательные задачи
- `tasks/cis-settings`: CIS-настройки

## Особенности архитектуры

Роль рассчитана на автономный кластер без внешнего LB:

- `controlPlaneEndpoint` в `kubeadm` указывает на локальный адрес `haproxy`
- на control-plane нодах поднимается локальный `haproxy`
- `haproxy` балансирует трафик Kubernetes API между master-нодами

Проверить состояние backend-нод в `haproxy` можно так:

```bash
haproxy-state
haproxy-state --down
haproxy-state --watch 2
```

Скрипт использует stats socket HAProxy и показывает:

- список backend-серверов
- их адреса
- статус `UP/DOWN/MAINT`
- число сессий
- weight
- результат healthcheck

## Основные переменные

Полный список переменных находится в [defaults/main.yml](defaults/main.yml). Ниже только самые важные.

### Kubernetes

```yaml
kubernetes_cluster_name: "kubernetes"
kubernetes_version: "1.33"
kubernetes_kubectl_user_home: "{{ ansible_user_dir }}"
kubernetes_master_group_name: "kubernetes_master"
kubernetes_worker_group_name: "kubernetes_worker"
kubernetes_pod_cidr: "10.137.0.0/18"
kubernetes_service_cidr: "10.137.64.0/18"
kubernetes_image_repository: "registry.k8s.io"
```

### Control Plane Endpoint

По умолчанию роль использует локальный `haproxy`:

```yaml
kubernetes_loadbalancer_apiserver_ip: "127.0.0.1"
kubernetes_loadbalancer_apiserver_port: 8443
kubernetes_apiserver_port: "6443"
```

### HAProxy

```yaml
kubernetes_haproxy_packages:
  - haproxy
  - socat

kubernetes_haproxy_oom_score_adjust: -900
kubernetes_haproxy_restart_sec: 5s
```

### Containerd

```yaml
kubernetes_containerd_sandbox_image: "{{ kubernetes_image_repository }}/pause:3.9"
kubernetes_containerd_package_version: "1.7.27-1"
kubernetes_containerd_private_registries_config_dir: "/etc/containerd/registries.d"
```

### Calico

```yaml
kubernetes_calico_chart_version: "v3.32.0"
kubernetes_calico_cni_image_repository: "quay.io"
kubernetes_calico_dataplane_type: "Iptables"
kubernetes_calico_encapulation_type: "IPIP"
```

Манифесты Tigera operator хранятся в версионированных директориях:

```
templates/manifests/cni/calico/
  v3.32.0/
    values.yaml
    manifests/             # helm template --output-dir
  init-calico.yml.j2      # Installation CR
```

Для генерации манифестов новой версии и публикации образов в приватный registry:

```bash
# Генерация манифестов Calico из Helm chart
./tools/cni/build-calico.sh v3.32.0

# Генерация манифестов Traefik из Helm chart
./tools/ingress/build-traefik.sh v34.2.0

# Публикация образов в приватный registry
./tools/push-images.sh harbor.company.local --dry-run
./tools/push-images.sh harbor.company.local all --k8s-version 1.33.3
```

### Traefik Ingress

```yaml
kubernetes_extensions_traefik_chart_version: "v34.2.0"
kubernetes_extensions_traefik_image_repo: "docker.io"
kubernetes_extensions_traefik_http_node_port: 30080
kubernetes_extensions_traefik_https_node_port: 30443
```

### Metrics / DNS

```yaml
kubernetes_extensions_metrics_server_image_repo: "registry.k8s.io/metrics-server/metrics-server"
kubernetes_extensions_node_local_dns_image_repo: "registry.k8s.io/dns/k8s-dns-node-cache"
```

### Node Labels / Taints

```yaml
kubernetes_node_labels: []
kubernetes_node_taints: []
```

## Интеграция с Keycloak (OIDC)

Роль поддерживает аутентификацию в Kubernetes API через JWT-issuer — например, realm Keycloak.

### Что делает роль

- рендерит `AuthenticationConfiguration` (`apiserver.config.k8s.io/v1beta1`) в `/etc/kubernetes/auth/config.yaml`
- передаёт его в kube-apiserver через `--authentication-config` (подключается в шаблоне kubeadm-конфига при включённом audit-логе — `kubernetes_kubeapi_audit_enabled: true`)
- маппит claims токена на username/groups Kubernetes

### Переменные

```yaml
kubernetes_kubeapi_auth_jwt_auth_enabled: true

# Realm Keycloak
kubernetes_kubeapi_auth_jwt_auth_issuer_url: "https://keycloak.example.com/realms/k8s"
kubernetes_kubeapi_auth_jwt_auth_issuer_discovery_url: "https://keycloak.example.com/realms/k8s/.well-known/openid-configuration"

# Audience = Client ID в Keycloak
kubernetes_kubeapi_auth_jwt_auth_audiences: ["kubernetes"]

# CA для HTTPS Keycloak (путь на ansible-контроллере; обязателен, если свой CA)
kubernetes_kubeapi_auth_jwt_auth_ca_file: "files/keycloak-ca.crt"

# Claims
kubernetes_kubeapi_auth_jwt_auth_username_claim: "email"
kubernetes_kubeapi_auth_jwt_auth_groups_claim: "groups"
kubernetes_kubeapi_auth_jwt_auth_username_prefix: ""
kubernetes_kubeapi_auth_jwt_auth_groups_prefix: ""
```

### Настройка Keycloak

1. В realm создайте client `kubernetes` (для kubectl — public client с Standard Flow).
2. Для проброса групп в токен добавьте client scope / mapper типа **Group Membership** с token claim `groups`.
3. Пользователь получит группы Keycloak в claim `groups` — они станут группами Kubernetes (`cluster-admin`, `platform-team`, ...).

### Доступ группам

Пример выдачи прав группе Keycloak:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: keycloak-cluster-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: Group
    name: cluster-admins # группа Keycloak
    apiGroup: rbac.authorization.k8s.io
```

### kubectl

Через плагин [kubelogin](https://github.com/int128/kubelogin) (`kubectl oidc-login`):

```yaml
# ~/.kube/config
users:
  - name: oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://keycloak.example.com/realms/k8s
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=email
          - --oidc-extra-scope=groups
```

## Пример переменных

Пример минимального vars-файла:

```yaml
kubernetes_dnf_repo: "https://repo.example.com/v{{ kubernetes_version.split('.')[:2] | join('.') }}/rpm/"

kubernetes_packages:
  - kubectl-0:1.33.3-150500.1.1.x86_64
  - kubeadm-0:1.33.3-150500.1.1.x86_64
  - kubelet-0:1.33.3-150500.1.1.x86_64
  - cri-tools-1.33.0-150500.1.1
  - containerd-1:1.7.1-2.x86_64
  - python3-kubernetes
  - python3-openshift

kubernetes_version: "1.33.3"
kubernetes_cluster_name: "K8S-CLUSTER"
kubernetes_master_group_name: "k8s_masters"
kubernetes_worker_group_name: "k8s_workers"

kubernetes_image_repository: "repo.example.com"
kubernetes_containerd_sandbox_image: "{{ kubernetes_image_repository }}/pause:3.10"

kubernetes_calico_cni_image_repository: "{{ kubernetes_image_repository }}"

kubernetes_extensions_traefik_image_repo: "{{ kubernetes_image_repository }}"

kubernetes_extensions_kubelet_csr_approver_provider_regex: "^.*\\.example\\.com$"
kubernetes_extensions_kubelet_csr_approver_image_repo: "repo.example.com/postfinance/kubelet-csr-approver"
kubernetes_extensions_kubelet_csr_approver_image_tag: "v1.2.6"

kubernetes_extensions_node_local_dns_image_repo: "repo.example.com/dns/k8s-dns-node-cache"
kubernetes_extensions_node_local_dns_image_tag: "1.24.0"
kubernetes_extensions_metrics_server_image_repo: "repo.example.com/metrics-server/metrics-server"
kubernetes_extensions_metrics_server_image_tag: "v0.7.2"
```

## Пример inventory

```yaml
k8s_masters:
  hosts:
    master01.example.com:
    master02.example.com:
    master03.example.com:

k8s_workers:
  hosts:
    worker01.example.com:
    worker02.example.com:
    worker03.example.com:
  vars:
    kubernetes_node_labels:
      - "app"
    kubernetes_node_taints:
      - key: "node-role.kubernetes.io/app"
        value: "true"
        effect: "NoSchedule"
```

Важно:

- все master-ноды должны входить в группу `kubernetes_master_group_name`
- все worker-ноды должны входить в группу `kubernetes_worker_group_name`
- `inventory_hostname` должен корректно резолвиться между нодами

## Пример playbook

```yaml
- name: Install Kubernetes cluster
  hosts: "k8s"
  become: true
  roles:
    - role: kubernetes
```

## Теги

Роль завязана на запуск через теги. Это важно: без нужных тегов основная часть задач не выполнится.

Основные теги:

- `kubernetes_prepare`: подготовка ОС
- `kubernetes_components`: установка пакетов и базовых компонентов
- `kubernetes_first_init`: инициализация первого control-plane узла и последующая базовая раскатка
- `kubernetes_add_master_node`: добавление дополнительных control-plane нод
- `kubernetes_add_worker_node`: добавление worker нод
- `kubernetes_add_node_label`: проставление labels нодам
- `kubernetes_cis_settings`: применение CIS-настроек
- `kubernetes_fetch_admin_conf`: скачать `admin.conf` на ansible controller
- `kubernetes_check_existing_nodes`: показать ноды, которые отсутствуют в кластере
- `kubernetes_install_cni`: установка Calico
- `kubernetes_install_node_local_dns`: установка NodeLocal DNS
- `kubernetes_patch_coredns`: патч CoreDNS
- `kubernetes_install_kubelet_csr_approver`: установка kubelet CSR approver
- `kubernetes_install_ingress`: установка Traefik
- `kubernetes_install_metrics_server`: установка metrics-server

Примеры запуска:

```bash
# Полная первичная инициализация
ansible-playbook -i inventory.yml play-kubernetes.yml --tags kubernetes_first_init

# Добавить worker-ноды
ansible-playbook -i inventory.yml play-kubernetes.yml --tags kubernetes_add_worker_node

# Обновить только базовые компоненты
ansible-playbook -i inventory.yml play-kubernetes.yml --tags kubernetes_components

# Установить metrics-server
ansible-playbook -i inventory.yml play-kubernetes.yml --tags kubernetes_install_metrics_server
```

## Что настраивается на нодах

### Prepare

Роль выполняет:

- установку hostname в FQDN
- загрузку kernel-модулей `br_netfilter` и `overlay`
- настройку `sysctl`
- отключение swap
- настройку audit policy для `kube-apiserver` на master-нодах

### Components

Роль настраивает:

- репозитории пакетов
- установку `kubeadm`, `kubelet`, `kubectl`, `containerd`
- локальный `haproxy`
- `containerd`
- `crictl`
- при необходимости `calicoctl`

Для `haproxy` дополнительно настраивается:

- `OOMScoreAdjust`
- `Restart=on-failure`
- `RestartSec`

## Поведение Join

- `kubernetes_first_init` и `kubernetes_add_master_node` не повторяют `kubeadm init/join`, если нода уже инициализирована или присоединена.
- `kubernetes_add_worker_node` выполняет `prepare`, `components`, `join`, `cordon` и первичную установку labels/taints только для новых worker нод.
- `cordon` не применяется во время `kubernetes_first_init`.
- kubeconfig пользователя копируется в `{{ kubernetes_kubectl_user_home }}/.kube/config`.

## Labels И Taints

- `kubernetes_node_labels` применяются как labels вида `node-role.kubernetes.io/<label>=true`.
- `kubernetes_node_taints` задаются списком объектов Kubernetes taint.
- taints не перетираются целиком: роль читает текущие taints ноды и добавляет новые поверх существующих.
- текущая merge-логика для taints ориентируется на поле `key`.

## Полезные команды

```bash
# Показать доступные названия пакетов в dnf repo
dnf repoquery <package_name>

# Показать содержимое пакета
dnf repoquery -l <package_name>

# Показать состояние backend-нод HAProxy
haproxy-state

# Показать только проблемные backend-нод
haproxy-state --down

# Смотреть состояние HAProxy в реальном времени
haproxy-state --watch 2

# Uncordon всех нод
kubectl get nodes --no-headers | awk '{print $1}' | xargs -n1 kubectl uncordon
```

## Замечания

- Формат `kubernetes_packages` зависит от пакетного менеджера и вашего репозитория.
- Для `apt` и `dnf` наборы пакетов и строки версий могут отличаться.
- Для multi-master сценария критично, чтобы локальный `haproxy` был корректно настроен и запущен на control-plane нодах.
- Если вы меняете `controlPlaneEndpoint`, проверьте также SAN'ы сертификатов API server.
