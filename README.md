# Lab: Kubernetes Elasticity & CI/CD Pipeline 🚀

## 📌 Descrição do Projeto

Ambiente de alta resiliência construído sobre **Kubernetes (Minikube v1.38.1 com runtime containerd)**, gerenciado via **Rancher 2.14.1** e integrado com uma esteira de **CI/CD automatizada via GitHub Actions**.

O laboratório demonstra na prática o ciclo completo de uma aplicação cloud-native: declaração de recursos em manifesto YAML, governança de consumo via Requests/Limits, elasticidade automática via HPA e validação contínua a cada push — do commit ao cluster em segundos.

---

## 🛠️ Tecnologias Utilizadas

| Tecnologia | Função |
|---|---|
| **Minikube v1.38.1** (driver Docker, runtime containerd) | Cluster Kubernetes local (k8s v1.35.1) |
| **kubectl** | Gerenciamento declarativo dos recursos |
| **Apache httpd 2.4** | Workload de referência para teste de carga |
| **Kubernetes HPA** (autoscaling/v2) | Elasticidade automática baseada em CPU |
| **metrics-server** | Coleta de métricas de CPU/memória para o HPA |
| **GitHub Actions** | Esteira de CI/CD automatizada |
| **Rancher 2.14.1** | Plataforma de gestão e governança do cluster |
| **Prometheus + Grafana** (rancher-monitoring 109.0.2) | Observabilidade, dashboards e alertas |

---

## 📈 Arquitetura de Elasticidade & Governança

### Governança de Recursos

Todo pod do deployment `meu-apache` opera dentro de envelopes de recurso explicitamente definidos, garantindo previsibilidade e proteção contra vizinhos ruidosos no cluster:

```
Requests: cpu: 50m  | memory: 32Mi   ← garantia mínima alocada ao pod
Limits:   cpu: 200m | memory: 64Mi   ← teto máximo permitido
```

> **Por que isso importa para o HPA:** o algoritmo de escala usa `uso_real / request` como métrica base. Com `request: 50m`, um Apache moderadamente carregado já eleva a razão acima de 50% — tornando a escala rápida e sensível por design.

### Regra de Escala (HPA `meu-apache-hpa`)

```
Mínimo de réplicas:  1 pod
Máximo de réplicas:  5 pods
Gatilho de scale-out: utilização média de CPU ≥ 50%
Gatilho de scale-down: cooldown padrão de 300 s (5 minutos)
```

O scale-out é imediato ao cruzar o limiar; o scale-down aguarda a janela de estabilização para evitar flapping.

---

## ⚡ O Teste de Carga Épico (Resultados Reais)

Carga sintética executada com **Apache Benchmark (ab)**: 500.000 requisições com 150 conexões concorrentes contra o `apache-service`.

### Resultados

| Métrica | Valor |
|---|---|
| **Total de requisições** | 500.000 |
| **Requisições com falha** | **0 (zero absoluto)** |
| **Throughput** | ~2.139 req/s |
| **Latência p50** | 34 ms |
| **Latência p95** | 264 ms |

### Comportamento do HPA durante o teste

```
Início:    1 réplica  → CPU 2% / 50%   (idle)
Sob carga: 1 → 5 réplicas em < 2 min  → CPU ~394% acumulada / 50% por pod
Fim carga: 5 → 1 réplica após ~5 min  (cooldown 300s respeitado)
Idle:      1 réplica  → CPU 2% / 50%   (normalizado)
```

O scale-out de **1 para 5 pods em menos de 2 minutos** sob uma tempestade de meio milhão de requisições — sem uma única falha — comprova a efetividade da estratégia de elasticidade reativa implementada.

---

## 🚀 Automação CI/CD

A cada push ou Pull Request na branch `main`, o GitHub Actions executa automaticamente o pipeline `.github/workflows/k8s-ci-cd.yaml`, que:

1. **Provisiona** um cluster Minikube efêmero (2 CPUs, 2 GB RAM, runtime containerd) no runner `ubuntu-latest`
2. **Habilita** o `metrics-server` para validar que o HPA teria métricas disponíveis
3. **Aplica** os manifestos `01-apache-deployment.yaml` e `02-apache-hpa.yaml`
4. **Aguarda** o rollout completo (`rollout status --timeout=120s`)
5. **Valida** o estado final do Deployment e do HPA com `kubectl get`

> A esteira passou com **sucesso absoluto na primeira execução** — zero ajustes necessários após o push inicial.

### Estrutura do Repositório

```
lab-k8s/
├── .github/
│   └── workflows/
│       └── k8s-ci-cd.yaml        # Pipeline GitHub Actions
├── 01-apache-deployment.yaml     # Deployment + Service (ClusterIP)
├── 02-apache-hpa.yaml            # HPA autoscaling/v2
├── helm/                         # Charts auxiliares
├── manifests/                    # Manifestos experimentais
└── rancher/                      # Configurações Rancher
```

---

## 🔬 Observabilidade

O cluster conta com stack completa de monitoramento instalada via Rancher UI:

- **Prometheus** coleta métricas do cluster, nodes, pods e cAdvisor (via CRI API com containerd)
- **Grafana** expõe dashboards de workload, CPU/memória por container e comportamento do HPA em tempo real
- Acesso local via `kubectl port-forward -n cattle-system service/rancher 8443:443` → `https://localhost:8443`

> **Nota técnica:** a migração do runtime Docker → containerd foi decisiva para a observabilidade. O cAdvisor integrado via CRI API popula corretamente o label `container` nas métricas, habilitando os dashboards de workload do Rancher que anteriormente ficavam vazios.

---

*Laboratório construído e documentado em 2026-05-20 · Kubernetes v1.35.1 · Minikube v1.38.1 · Rancher 2.14.1*
