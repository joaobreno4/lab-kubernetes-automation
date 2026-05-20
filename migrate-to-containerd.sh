#!/usr/bin/env bash
# migrate-to-containerd.sh
# Migra o cluster minikube de Docker runtime para containerd,
# corrigindo a ausência de métricas per-container no cAdvisor.
#
# Pré-requisito: /etc/hosts com "192.168.49.2 rancher.local" (o script verifica).
# Uso: bash migrate-to-containerd.sh [--skip-rancher-monitoring]

set -euo pipefail

###############################################################################
# Configuração — ajuste se necessário
###############################################################################
MINIKUBE_DRIVER="docker"
MINIKUBE_RUNTIME="containerd"
MINIKUBE_K8S_VERSION="v1.35.1"
MINIKUBE_MEMORY="8192"
MINIKUBE_CPUS="4"
MINIKUBE_DISK="20000mb"

RANCHER_HOSTNAME="rancher.local"
RANCHER_BOOTSTRAP_PASSWORD="admin12345678"
RANCHER_CHART_VERSION="2.14.1"

CERT_MANAGER_CHART_VERSION="v1.20.2"

SKIP_RANCHER_MONITORING="${1:-}"  # passe --skip-rancher-monitoring para pular

###############################################################################
# Utilitários
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()    { echo -e "${GREEN}[OK] $*${NC}"; }
warn()  { echo -e "${YELLOW}[AVISO] $*${NC}"; }
die()   { echo -e "${RED}[ERRO] $*${NC}"; exit 1; }

wait_for_deploy() {
    local ns="$1" deploy="$2" timeout="${3:-300}"
    log "Aguardando deployment/$deploy em $ns (timeout ${timeout}s)..."
    kubectl rollout status deployment/"$deploy" -n "$ns" --timeout="${timeout}s"
}

wait_for_pods_ready() {
    local ns="$1" label="$2" count="${3:-1}" timeout="${4:-300}"
    log "Aguardando $count pod(s) com label '$label' em $ns..."
    local elapsed=0
    while true; do
        local ready
        ready=$(kubectl get pods -n "$ns" -l "$label" --field-selector=status.phase=Running \
                  -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null \
                | tr ' ' '\n' | grep -c '^true$' 2>/dev/null || echo 0)
        [[ "$ready" -ge "$count" ]] && { ok "$deploy pronto ($ready/$count pods)"; return 0; }
        [[ "$elapsed" -ge "$timeout" ]] && die "Timeout aguardando $label em $ns"
        sleep 10; elapsed=$((elapsed + 10))
        log "  ainda aguardando... ($ready/$count prontos, ${elapsed}s)"
    done
}

###############################################################################
# FASE 0 — Pré-verificações
###############################################################################
log "=== FASE 0: Pré-verificações ==="

command -v minikube >/dev/null || die "minikube não encontrado"
command -v kubectl  >/dev/null || die "kubectl não encontrado"
command -v helm     >/dev/null || die "helm não encontrado"

# /etc/hosts
if ! grep -q "$RANCHER_HOSTNAME" /etc/hosts 2>/dev/null; then
    warn "$RANCHER_HOSTNAME não encontrado em /etc/hosts."
    warn "Execute manualmente como root ANTES de continuar:"
    warn "  echo '192.168.49.2 $RANCHER_HOSTNAME' | sudo tee -a /etc/hosts"
    read -rp "Pressione ENTER após adicionar a entrada, ou Ctrl+C para cancelar..."
fi

ok "Pré-verificações concluídas"

###############################################################################
# FASE 1 — Destruir e recriar o cluster
###############################################################################
log "=== FASE 1: Parando e deletando o cluster atual ==="
warn "ATENÇÃO: Esta ação é IRREVERSÍVEL. O cluster será deletado."
read -rp "Confirma? (sim/não): " confirm
[[ "$confirm" == "sim" ]] || die "Operação cancelada pelo usuário."

minikube stop --profile minikube 2>/dev/null || true
minikube delete --profile minikube 2>/dev/null || true
ok "Cluster antigo removido"

log "Criando novo cluster com containerd runtime..."
minikube start \
    --driver="$MINIKUBE_DRIVER" \
    --container-runtime="$MINIKUBE_RUNTIME" \
    --kubernetes-version="$MINIKUBE_K8S_VERSION" \
    --memory="$MINIKUBE_MEMORY" \
    --cpus="$MINIKUBE_CPUS" \
    --disk-size="$MINIKUBE_DISK" \
    --addons=ingress,default-storageclass,storage-provisioner

ok "Cluster minikube criado com containerd"

log "Verificando cAdvisor per-container (validação imediata)..."
sleep 15
CADVISOR_CHECK=$(kubectl get --raw "/api/v1/nodes/minikube/proxy/metrics/cadvisor" 2>/dev/null \
    | grep 'container_cpu_usage_seconds_total' | grep -v 'container=""' | grep -v '^#' | wc -l || echo 0)
if [[ "$CADVISOR_CHECK" -gt 0 ]]; then
    ok "cAdvisor per-container metrics confirmadas ($CADVISOR_CHECK séries com container label)"
else
    warn "Ainda sem métricas per-container. O containerd pode estar inicializando — continue."
fi

###############################################################################
# FASE 2 — cert-manager
###############################################################################
log "=== FASE 2: Instalando cert-manager $CERT_MANAGER_CHART_VERSION ==="

helm repo update jetstack 2>/dev/null || helm repo add jetstack https://charts.jetstack.io

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_CHART_VERSION" \
    --set installCRDs=true \
    --wait --timeout 5m

wait_for_deploy cert-manager cert-manager 180
wait_for_deploy cert-manager cert-manager-webhook 180
ok "cert-manager instalado"

###############################################################################
# FASE 3 — Rancher
###############################################################################
log "=== FASE 3: Instalando Rancher $RANCHER_CHART_VERSION ==="

helm repo update rancher-stable 2>/dev/null || helm repo add rancher-stable https://releases.rancher.com/server-charts/stable

kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

helm install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --version "$RANCHER_CHART_VERSION" \
    --set hostname="$RANCHER_HOSTNAME" \
    --set bootstrapPassword="$RANCHER_BOOTSTRAP_PASSWORD" \
    --set ingress.tls.source=rancher \
    --wait --timeout 10m

log "Aguardando Rancher ficar totalmente operacional (pode levar 5-8 min)..."
wait_for_deploy cattle-system rancher 600
ok "Rancher instalado e operacional"

###############################################################################
# FASE 4 — rancher-monitoring (via Helm com valores mínimos)
###############################################################################
if [[ "$SKIP_RANCHER_MONITORING" != "--skip-rancher-monitoring" ]]; then
    log "=== FASE 4: Instalando rancher-monitoring ==="
    warn "Aguardando Rancher inicializar Fleet e projetos (90s)..."
    sleep 90

    # Descobrir o novo systemProjectId gerado pelo Rancher
    log "Detectando systemProjectId do cluster 'local'..."
    RANCHER_URL="https://${RANCHER_HOSTNAME}"
    # Tentar obter token via bootstrap
    TOKEN_RESP=$(curl -sk -X POST "${RANCHER_URL}/v3-public/localProviders/local?action=login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\"}" 2>/dev/null || true)

    RANCHER_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || true)

    if [[ -n "$RANCHER_TOKEN" ]]; then
        SYSTEM_PROJECT_ID=$(curl -sk -H "Authorization: Bearer ${RANCHER_TOKEN}" \
            "${RANCHER_URL}/v3/projects?clusterId=local" \
            | python3 -c "
import sys, json
d = json.load(sys.stdin)
for p in d.get('data', []):
    if p.get('name') == 'System':
        print(p['id'])
        break" 2>/dev/null || true)
        ok "systemProjectId detectado: $SYSTEM_PROJECT_ID"
    else
        SYSTEM_PROJECT_ID="p-xxxxx"
        warn "Não foi possível detectar systemProjectId automaticamente."
        warn "Instale rancher-monitoring via Rancher UI: Apps > Monitoring"
    fi

    # Adicionar repo rancher-monitoring se necessário
    helm repo add rancher-monitoring \
        "https://releases.rancher.com/server-charts/stable" 2>/dev/null || true

    helm install rancher-monitoring-crd \
        rancher-monitoring/rancher-monitoring-crd \
        --namespace cattle-monitoring-system \
        --create-namespace \
        --wait --timeout 5m 2>/dev/null || warn "CRDs de monitoring já instalados ou não encontrados — continue via UI"

    helm install rancher-monitoring \
        rancher-monitoring/rancher-monitoring \
        --namespace cattle-monitoring-system \
        --create-namespace \
        --set global.cattle.clusterId=local \
        --set global.cattle.clusterName=local \
        --set global.cattle.systemProjectId="${SYSTEM_PROJECT_ID}" \
        --set global.cattle.url="https://${RANCHER_HOSTNAME}" \
        --set prometheus.prometheusSpec.retentionSize=50GiB \
        --wait --timeout 10m 2>/dev/null || {
            warn "Instalação via helm falhou. Por favor, instale o monitoring via Rancher UI:"
            warn "  1. Acesse https://${RANCHER_HOSTNAME}"
            warn "  2. Vá em Apps > Charts > Monitoring"
            warn "  3. Instale com os defaults"
        }
else
    log "=== FASE 4: Pulando rancher-monitoring (--skip-rancher-monitoring) ==="
    warn "Instale manualmente via Rancher UI: Apps > Charts > Monitoring"
fi

###############################################################################
# FASE 5 — Workloads lab-estudos
###############################################################################
log "=== FASE 5: Recriando workloads em lab-estudos ==="

kubectl create namespace lab-estudos --dry-run=client -o yaml | kubectl apply -f -

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "${SCRIPT_DIR}/manifests/apache-app.yaml"
ok "meu-apache aplicado"

helm repo update bitnami 2>/dev/null || helm repo add bitnami https://charts.bitnami.com/bitnami
helm install meu-webserver bitnami/nginx \
    --namespace lab-estudos \
    --wait --timeout 5m
ok "meu-webserver-nginx instalado"

###############################################################################
# FASE 6 — Validação final
###############################################################################
log "=== FASE 6: Validação ==="
sleep 20

log "Checando cAdvisor metrics per-container para lab-estudos..."
FINAL_CHECK=$(kubectl get --raw "/api/v1/nodes/minikube/proxy/metrics/cadvisor" 2>/dev/null \
    | grep 'container_cpu_usage_seconds_total' \
    | grep 'lab-estudos' \
    | grep -v 'container=""' \
    | grep -v '^#' \
    | wc -l || echo 0)

echo ""
if [[ "$FINAL_CHECK" -gt 0 ]]; then
    ok "✓ cAdvisor per-container metrics: $FINAL_CHECK séries encontradas para lab-estudos"
    ok "✓ O dashboard 'Rancher / Workload' deve funcionar após o Prometheus scraper (~2 min)"
else
    warn "Métricas per-container ainda não disponíveis. Verifique:"
    warn "  kubectl get --raw '/api/v1/nodes/minikube/proxy/metrics/cadvisor' | grep container_cpu | grep lab-estudos"
fi

echo ""
log "=== RESUMO ==="
kubectl get all -n lab-estudos 2>/dev/null || true
echo ""
ok "Migração concluída!"
echo ""
echo -e "${YELLOW}PRÓXIMOS PASSOS:${NC}"
echo "  1. Aguarde ~2 min para o Prometheus coletar dados"
echo "  2. Acesse o Grafana e abra 'Rancher / Workload'"
echo "  3. Selecione: namespace=lab-estudos, kind=ReplicaSet, workload=meu-apache-<hash>"
echo "  4. Se o monitoring não foi instalado, acesse https://${RANCHER_HOSTNAME} > Apps > Monitoring"
