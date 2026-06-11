#!/bin/bash
set -euo pipefail
exec > /var/log/liferay-setup.log 2>&1

# ─────────────────────────────────────────────
# PARÂMETROS — substituídos pelo CloudFormation
# ─────────────────────────────────────────────
DB_PASSWORD="${DB_PASSWORD}"
LIFERAY_IMAGE="${LIFERAY_IMAGE}"          # ex: elupianhez/lug-liferay:2026.q2.2
REGISTRY_SERVER="${REGISTRY_SERVER}"      # deixar vazio se registry pública
REGISTRY_USER="${REGISTRY_USER}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD}"
STORAGE_TYPE="${STORAGE_TYPE}"            # pvc | s3
S3_BUCKET="${S3_BUCKET}"                  # só usado se STORAGE_TYPE=s3
JVM_MEMORY="${JVM_MEMORY}"               # ex: 4g
LICENSE_XML="${LICENSE_XML}"              # conteúdo XML da licença

# ─────────────────────────────────────────────
# IP PÚBLICO DA INSTÂNCIA
# ─────────────────────────────────────────────
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "[setup] IP público: $PUBLIC_IP"

# ─────────────────────────────────────────────
# 1. INSTALAR K3S
# ─────────────────────────────────────────────
echo "[setup] Instalando k3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.5+k3s1" sh -

echo "[setup] Aguardando k3s ficar pronto..."
until kubectl get nodes | grep -q " Ready"; do sleep 3; done
echo "[setup] k3s pronto."

# ─────────────────────────────────────────────
# 2. CRIAR NAMESPACE
# ─────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: liferay
EOF

# ─────────────────────────────────────────────
# 3. SECRET — banco de dados
# ─────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: liferay-secret
  namespace: liferay
type: Opaque
stringData:
  DATABASE: "lportal"
  DB_USER: "lportal"
  DB_PASSWORD: "${DB_PASSWORD}"
EOF

# ─────────────────────────────────────────────
# 4. IMAGEPULLSECRET — registry privada (opcional)
# ─────────────────────────────────────────────
if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASSWORD" ]; then
  echo "[setup] Criando imagePullSecret para registry privada..."
  kubectl create secret docker-registry registry-secret \
    --docker-server="${REGISTRY_SERVER:-https://index.docker.io/v1/}" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASSWORD" \
    --namespace=liferay \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ─────────────────────────────────────────────
# 5. CONFIGMAP — licença Liferay
# ─────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: liferay-license
  namespace: liferay
data:
  activation-key.xml: |
$(echo "$LICENSE_XML" | sed 's/^/    /')
EOF

# ─────────────────────────────────────────────
# 6. CONFIGMAP — portal-ext.properties
# ─────────────────────────────────────────────
# Storage: monta propriedades de S3 se necessário
if [ "$STORAGE_TYPE" = "s3" ]; then
  STORAGE_PROPS="dl.store.impl=com.liferay.portal.store.s3.S3Store
dl.store.s3.bucket.name=${S3_BUCKET}
dl.store.s3.region=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)"
else
  STORAGE_PROPS=""
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: liferay-portal-ext
  namespace: liferay
data:
  portal-ext.properties: |
    # Database
    jdbc.default.driverClassName=org.postgresql.Driver
    jdbc.default.url=jdbc:postgresql://liferay-database:5432/\${env:jdbc_database}
    jdbc.default.username=\${env:jdbc_default_username}
    jdbc.default.password=\${env:jdbc_default_password}

    # Web
    web.server.protocol=http
    web.server.host=${PUBLIC_IP}
    web.server.http.port=30080
    company.security.auth.requires.https=false

    # Company
    company.default.locale=pt_BR
    company.default.name=Liferay
    company.default.web.id=liferay.com
    locales.enabled=pt_BR,en_US

    # Admin
    admin.email.from.address=admin@liferay.com
    admin.email.from.name=Administrator
    default.admin.password=admin
    default.admin.email.address.prefix=admin
    default.admin.first.name=Admin
    default.admin.last.name=User

    # Misc
    terms.of.use.required=false
    passwords.default.policy.change.required=false
    upgrade.database.auto.run=true
    company.security.strangers.verify=false

    # Storage
    ${STORAGE_PROPS}
EOF

# ─────────────────────────────────────────────
# 7. BAIXAR MANIFESTS DO GITHUB
# ─────────────────────────────────────────────
MANIFESTS_DIR="/opt/liferay-k8s"
MANIFESTS_REPO="https://raw.githubusercontent.com/elerum-tecnologia/liferay-k8s/main"

mkdir -p "$MANIFESTS_DIR"

for f in 02-configmaps.yaml 03-postgres.yaml 04-elasticsearch.yaml 06-nginx.yaml 07-networkpolicy.yaml; do
  curl -sf "$MANIFESTS_REPO/$f" -o "$MANIFESTS_DIR/$f"
done

# manifest do Liferay: substitui imagem e ajusta storage
curl -sf "$MANIFESTS_REPO/05-liferay.yaml" | \
  sed "s|image: elupianhez/lug-liferay:.*|image: ${LIFERAY_IMAGE}|g" | \
  sed "s|-Xms[^ ]*|-Xms${JVM_MEMORY}|g" | \
  sed "s|-Xmx[^ ]*|-Xmx${JVM_MEMORY}|g" \
  > "$MANIFESTS_DIR/05-liferay.yaml"

# se storage = s3, remove o PVC do Liferay e o volumeMount liferay-data
if [ "$STORAGE_TYPE" = "s3" ]; then
  echo "[setup] Modo S3: removendo PVC do Liferay..."
  # Remove o bloco PVC (primeiros ~12 linhas até o primeiro ---)
  sed -i '/^kind: PersistentVolumeClaim/,/^---/d' "$MANIFESTS_DIR/05-liferay.yaml"
fi

# adiciona imagePullSecrets se necessário
if [ -n "$REGISTRY_USER" ]; then
  sed -i '/securityContext:/i\      imagePullSecrets:\n        - name: registry-secret' "$MANIFESTS_DIR/05-liferay.yaml"
fi

# ─────────────────────────────────────────────
# 8. KUSTOMIZATION
# ─────────────────────────────────────────────
cat > "$MANIFESTS_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: liferay
resources:
  - 02-configmaps.yaml
  - 03-postgres.yaml
  - 04-elasticsearch.yaml
  - 05-liferay.yaml
  - 06-nginx.yaml
  - 07-networkpolicy.yaml
EOF

# ─────────────────────────────────────────────
# 9. APLICAR MANIFESTS
# ─────────────────────────────────────────────
echo "[setup] Aplicando manifests..."
kubectl apply -k "$MANIFESTS_DIR/"

# ─────────────────────────────────────────────
# 10. LIBERAR TRAFEGO EXTERNO NO NGINX
# ─────────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: liferay-allow-nginx-external
  namespace: liferay
spec:
  podSelector:
    matchLabels:
      app: liferay-nginx
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - port: 80
EOF

echo "[setup] Concluído. Liferay disponível em: http://${PUBLIC_IP}:30080"
echo "[setup] Login: admin@liferay.com / admin"
