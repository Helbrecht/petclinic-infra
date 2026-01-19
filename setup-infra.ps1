# setup-infra.ps1 — Развертывание infra для PetClinic

Write-Host "=== Развертывание инфраструктуры ===" -ForegroundColor Green

# Проверка кластера
Write-Host "Проверка подключения..." -ForegroundColor Yellow
kubectl get nodes

if ($LASTEXITCODE -ne 0) {
    Write-Host "Пересоздать кластер? (y/n)" -ForegroundColor Red
    $answer = Read-Host
    if ($answer -eq "y") {
        kind delete cluster --name petclinic
        kind create cluster --name petclinic --config kind-config.yml
        kind export kubeconfig --name petclinic
    } else {
        exit 1
    }
}


# Шаг 1: Prometheus + Grafana
kubectl create namespace monitoring
Write-Host "Установка Prometheus + Grafana..." -ForegroundColor Yellow
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack `
   --namespace monitoring `
   --create-namespace `
   --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=true `
   --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=true `
   --set kube-state-metrics.enabled=true `
   --set node-exporter.enabled=true `
   --set grafana.adminPassword=admin `
   --set rbac.create=true `
   --set prometheus.service.type=NodePort `
   --set grafana.service.type=NodePort `
   --timeout 5m `
   --wait

# Шаг 2: ECK Operator 2.16.0
Write-Host "Установка ECK Operator..." -ForegroundColor Yellow
kubectl create namespace elastic-system
Invoke-WebRequest -Uri "https://download.elastic.co/downloads/eck/2.16.0/crds.yaml" -OutFile "eck-crds.yaml" -UseBasicParsing
Invoke-WebRequest -Uri "https://download.elastic.co/downloads/eck/2.16.0/operator.yaml" -OutFile "eck-operator.yaml" -UseBasicParsing
kubectl apply -f eck-crds.yaml
kubectl apply -f eck-operator.yaml --namespace elastic-system
Start-Sleep -Seconds 60

# Шаг 3: Elasticsearch 9.0.1
Write-Host "Установка Elasticsearch 9.0.1..." -ForegroundColor Yellow
kubectl create namespace elastic
$esYaml = @"
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: elasticsearch
  namespace: elastic
spec:
  version: 9.0.1
  nodeSets:
  - name: default
    count: 1
    config:
      node.store.allow_mmap: false
"@
$esYaml | Out-File "elasticsearch.yaml" -Encoding utf8
kubectl apply -f elasticsearch.yaml
Start-Sleep -Seconds 240

# Шаг 4: Kibana 9.0.1
Write-Host "Установка Kibana 9.0.1..." -ForegroundColor Yellow
$kibanaYaml = @"
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: kibana
  namespace: elastic
spec:
  version: 9.0.1
  count: 1
  elasticsearchRef:
    name: elasticsearch
  config:
    server.host: "0.0.0.0"
  http:
    service:
      spec:
        type: NodePort
"@
$kibanaYaml | Out-File "kibana.yaml" -Encoding utf8
kubectl apply -f kibana.yaml
Start-Sleep -Seconds 60

$ELASTIC_PASS = kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
Write-Host "Пароль elastic: $ELASTIC_PASS"

# Шаг 5: Fluent Bit (с фиксами из опыта)
Write-Host "Установка Fluent Bit..." -ForegroundColor Yellow
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update
helm upgrade --install fluent-bit fluent/fluent-bit `
  --namespace elastic `
  --set elasticsearch.host=elasticsearch-es-http.elastic.svc.cluster.local `
  --set elasticsearch.port=9200 `
  --set elasticsearch.tls.enabled=true `
  --set elasticsearch.tls.verify=false `
  --set elasticsearch.http_user=elastic `
  --set elasticsearch.http_passwd=$ELASTIC_PASS `
  --set kubernetes.filter=true `
  --set kubernetes.labels=true `
  --set kubernetes.annotations=true `
  --set 'kubernetes.filterNamespace=petclinic' `
  --set securityContext.runAsUser=0 `
  --set securityContext.runAsGroup=0 `
  --set podSecurityContext.fsGroup=0 `
  --timeout 15m `
  --wait

Write-Host "=== Готово! ===" -ForegroundColor Green
Write-Host "Kibana: kubectl port-forward svc/kibana-kb-http 5601:5601 -n elastic → http://localhost:5601 (elastic / $ELASTIC_PASS)"
Write-Host "Discover: Data View `fluentbit-*`, фильтр `kubernetes.namespace_name : petclinic "