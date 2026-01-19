# petclinic-infra
# PetClinic Infrastructure (IaC + Monitoring + Logging)

Этот репозиторий содержит всю инфраструктуру для приложения [PetClinic](https://github.com/ilyab/petclinic):

- Локальный Kubernetes-кластер (kind)
- Helm-чарт приложения
- Мониторинг (Prometheus + Grafana)
- Логирование (ECK + Fluent Bit + Kibana)
- Скрипт полной установки

## Структура репозитория

- `kind-config.yaml` — конфигурация kind-кластера (IaC)
- `helm/petclinic-chart/` — Helm-чарт для деплоя приложения
- `setup-infra.ps1` — PowerShell-скрипт для развёртывания всего стека
- `README.md` — эта инструкция

## Требования

- kind 0.24.0+
- kubectl
- Helm 3.14+
- Docker Desktop (или Docker)
- PowerShell 7+ (или Git Bash)



## Развёртывание инфраструктуры

1. **Создай кластер kind**

```powershell
kind create cluster --name petclinic --config kind-config.yml
kind export kubeconfig --name petclinic

## Создай Kubernetes Secret в кластере
kubectl create secret docker-registry ghcr-secret `
  --docker-server=ghcr.io `
  --docker-username=# твой GitHub логин `  
  --docker-password=<твой_GHCR_TOKEN (PAT)> `  
  --docker-email=your@email.com `
  --namespace=petclinic

Проверка
kubectl get secret ghcr-secret -n petclinic -o yaml

2. **Запусти скрипт установки**

.\setup-infra.ps1

Скрипт:
-Устанавливает Prometheus + Grafana (monitoring)
-Устанавливает ECK Operator 2.16.0
-Разворачивает Elasticsearch 9.0.1
-Разворачивает Kibana 9.0.1
-Устанавливает Fluent Bit

При появлении проблем с буфером и отправкой у Fluentbit необходимо привести конфиги к следующему виду вручную:

kubectl edit configmap fluent-bit -n elastic

++++++++++++++++++++
[SERVICE]
        Daemon Off
        Flush 5
        Log_Level info
        Storage.path  /fluent-bit/storage
        Storage.sync  normal
        Storage.checksum off
        Storage.max_chunks_up 128
        Parsers_File /fluent-bit/etc/parsers.conf
        Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
        HTTP_Server On
        HTTP_Listen 0.0.0.0
        HTTP_Buffer_Size 512k
        HTTP_Max_Request_Size 1M
        HTTP_Port 2020
        Health_Check On

    [INPUT]
        Name tail
        Path /var/log/containers/*.log
        multiline.parser docker, cri
        Tag kube.*
        Refresh_Interval  5
        Mem_Buf_Limit 100MB
        storage.type filesystem
        Skip_Long_Lines On
        Buffer_Chunk_Size 8k
        Buffer_Max_Size   64k

    [INPUT]
        Name systemd
        Tag host.*
        Systemd_Filter _SYSTEMD_UNIT=kubelet.service
        Read_From_Tail On
        storage.type filesystem

    [FILTER]
        Name kubernetes
        Match kube.*
        Merge_Log On
        Keep_Log Off
        Buffer_Size         1Mb
        K8S-Logging.Parser On
        K8S-Logging.Exclude On
        Labels        Off
        Annotations   Off

    [FILTER]
        Name    modify
        Match   kube*
        Rename  log message

    [OUTPUT]
        Name es
        Match kube.*
        Host elasticsearch-es-http.elastic.svc.cluster.local
        Port  9200
        TLS On
        TLS.Verify Off
        HTTP_User elastic
        HTTP_Passwd Пароль эластика (ранее полученный)
        Logstash_Format On
        Index           fluentbit
        Type            _doc
        Time_Key        @timestamp
        Suppress_Type_Name On
        Logstash_Prefix fluentbit
        Retry_Limit False
        Generate_ID On
        Buffer_Size     1MB

++++++++++++++++++++

kubectl edit daemonset fluent-bit -n elastic

++++++++++++++++++++
Раздел volumeMounts:
добавить
        - mountPath: /fluent-bit/storage
          name: fluentbit-storage
Раздел       volumes:
добавить
      - emptyDir: {}
        name: fluentbit-storage

++++++++++++++++++++

Перезапуск 

kubectl rollout restart daemonset fluent-bit -n elastic  


3. **Доступ к сервисам**

-Kibana: kubectl port-forward svc/kibana-kb-http 5601:5601 -n elastic → http://localhost:5601 (elastic / пароль из вывода скрипта)
-Grafana: kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring → http://localhost:3000 (admin / admin)
-Prometheus: kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring → http://localhost:9090

В кибане - Stack management - Data view - create data view - index pattern = fluentbit-*
Графана и прометеус подхватывают автоматом. При желании можно сформировать дополнительные дэшборды под себя


4. **Правила внесения изменений в инфраструктуру**

-Создай feature-ветку: git flow feature start имя-изменения
-Измени параметры в kind-config.yaml, Helm-чарте или скрипте
-Разверни локально: kind delete cluster --name petclinic && kind create cluster ... && .\setup-infra.ps1
-Делай PR в develop
-После ревью мержи
-Для релиза: git flow release start v1.0.0 → мерж в main