# Liferay K8s — Manifests para AWS Marketplace

Stack completa de Liferay DXP no Kubernetes (k3s) para deploy automatizado via CloudFormation.

## Componentes

| Arquivo | O que faz |
|---------|-----------|
| `00-namespace.yaml` | Namespace `liferay` |
| `02-configmaps.yaml` | Configs do nginx e elasticsearch |
| `03-postgres.yaml` | PostgreSQL 16 (StatefulSet) |
| `04-elasticsearch.yaml` | Elasticsearch 8 (StatefulSet) |
| `05-liferay.yaml` | Liferay DXP (Deployment + PVC + Service) |
| `06-nginx.yaml` | nginx reverse proxy (NodePort 30080) |
| `07-networkpolicy.yaml` | NetworkPolicies com default-deny |
| `userdata.sh` | Bootstrap script para EC2 (usado pelo CloudFormation) |

## Deploy manual (EC2 com k3s já instalado)

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 02-configmaps.yaml
kubectl apply -f 03-postgres.yaml
kubectl apply -f 04-elasticsearch.yaml
kubectl apply -f 05-liferay.yaml
kubectl apply -f 06-nginx.yaml
kubectl apply -f 07-networkpolicy.yaml
```

Acesse em: `http://<IP-EC2>:30080`

## Imagem Docker

`elupianhez/lug-liferay:2026.q2.2`
