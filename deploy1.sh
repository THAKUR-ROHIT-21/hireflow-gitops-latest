#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="hireflow"

LOCAL_PATH_MANIFEST="https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
STORAGE_CLASS="local-path"

NGINX_INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/baremetal/deploy.yaml"
INGRESS_CLASS="nginx"

CURRENT_STEP="initialization"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}✓ $*${NC}"
}

warn() {
    echo -e "${YELLOW}⚠ $*${NC}"
}

fail() {
    echo -e "${RED}✗ $*${NC}"
}

get_pod_by_label() {
    local label="$1"

    kubectl get pods \
        -n "${NAMESPACE}" \
        -l "${label}" \
        -o jsonpath='{.items[0].metadata.name}' \
        2>/dev/null || true
}

show_diagnostics() {

    echo
    echo "========================================================="
    echo "                 KUBERNETES DIAGNOSTICS"
    echo "========================================================="

    echo
    echo ">>> Nodes"
    kubectl get nodes -o wide || true

    echo
    echo ">>> StorageClasses"
    kubectl get storageclass || true

    echo
    echo ">>> Local Path Provisioner"
    kubectl get deployment local-path-provisioner \
        -n local-path-storage \
        -o wide || true

    kubectl get pods \
        -n local-path-storage \
        -o wide || true

    echo
    echo ">>> Ingress Controller"
    kubectl get deployment ingress-nginx-controller \
        -n ingress-nginx \
        -o wide || true

    kubectl get pods \
        -n ingress-nginx \
        -o wide || true

    echo
    echo ">>> Ingress Service"
    kubectl get svc \
        -n ingress-nginx || true

    echo
    echo ">>> HireFlow Pods"
    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide || true

    echo
    echo ">>> HireFlow Deployments"
    kubectl get deployments \
        -n "${NAMESPACE}" || true

    echo
    echo ">>> HireFlow Services"
    kubectl get svc \
        -n "${NAMESPACE}" || true

    echo
    echo ">>> PVC"
    kubectl get pvc \
        -n "${NAMESPACE}" || true

    echo
    echo ">>> Ingress"
    kubectl get ingress \
        -n "${NAMESPACE}" || true

    echo
    echo ">>> Events"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -80 || true

    echo
    echo ">>> Backend Logs"

    BACKEND_POD="$(get_pod_by_label "app=backend")"

    if [[ -n "${BACKEND_POD}" ]]; then

        kubectl logs \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=150 || true

        echo
        echo ">>> Previous Backend Logs"

        kubectl logs \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" \
            --previous \
            --all-containers=true \
            --tail=150 || true

    else

        echo "Backend pod not found."

    fi

    echo
    echo ">>> Frontend Logs"

    FRONTEND_POD="$(get_pod_by_label "app=frontend")"

    if [[ -n "${FRONTEND_POD}" ]]; then

        kubectl logs \
            "${FRONTEND_POD}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=150 || true

    else

        echo "Frontend pod not found."

    fi

    echo
}

on_error() {

    local exit_code=$?

    echo
    fail "Deployment failed."
    echo "Failed step : ${CURRENT_STEP}"
    echo "Exit code   : ${exit_code}"

    show_diagnostics

    exit "${exit_code}"
}

trap on_error ERR


# =========================================================
# HEADER
# =========================================================

echo
echo "========================================================="
echo "              HireFlow Kubernetes Deployment"
echo "========================================================="
echo


# =========================================================
# CHECK KUBECTL
# =========================================================

CURRENT_STEP="checking kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl is not installed."
    exit 1
fi

success "kubectl found."


# =========================================================
# CHECK CLUSTER
# =========================================================

CURRENT_STEP="checking Kubernetes connection"

log "Checking Kubernetes cluster..."

kubectl cluster-info >/dev/null

success "Kubernetes cluster is reachable."


# =========================================================
# CHECK NODES
# =========================================================

CURRENT_STEP="checking Kubernetes nodes"

log "Checking Kubernetes nodes..."

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)

if [[ "${NODE_COUNT}" -eq 0 ]]; then
    fail "No Kubernetes nodes found."
    exit 1
fi

NOT_READY_NODES=$(
    kubectl get nodes --no-headers |
    awk '$2 != "Ready" {print $1}'
)

if [[ -n "${NOT_READY_NODES}" ]]; then

    fail "Some Kubernetes nodes are not Ready:"
    echo "${NOT_READY_NODES}"

    kubectl get nodes -o wide

    exit 1
fi

success "All Kubernetes nodes are Ready."

kubectl get nodes -o wide


# =========================================================
# CHECK FILES
# =========================================================

CURRENT_STEP="checking manifest files"

log "Checking Kubernetes manifest files..."

FILES=(
    "k8s/namespace.yaml"
    "k8s/database-secret.yaml"
    "k8s/database-pvc.yaml"
    "k8s/database-deployment.yaml"
    "k8s/database-service.yaml"
    "k8s/backend-deployment.yaml"
    "k8s/backend-service.yaml"
    "k8s/frontend-deployment.yaml"
    "k8s/frontend-service.yaml"
    "k8s/ingress.yaml"
)

for file in "${FILES[@]}"; do

    if [[ ! -f "${file}" ]]; then

        fail "Missing file: ${file}"

        exit 1
    fi

    success "Found ${file}"

done


# =========================================================
# NAMESPACE
# =========================================================

CURRENT_STEP="creating namespace"

log "Creating namespace..."

kubectl apply -f k8s/namespace.yaml

success "Namespace ${NAMESPACE} is ready."


# =========================================================
# LOCAL PATH STORAGE
# =========================================================

CURRENT_STEP="checking storage"

log "Checking StorageClass ${STORAGE_CLASS}..."

if kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then

    success "StorageClass already exists."

else

    warn "StorageClass not found."

    log "Installing Local Path Provisioner..."

    kubectl apply \
        -f "${LOCAL_PATH_MANIFEST}"

    success "Local Path Provisioner installed."

fi


CURRENT_STEP="waiting for local path provisioner"

log "Waiting for Local Path Provisioner..."

kubectl wait \
    --for=condition=Available \
    deployment/local-path-provisioner \
    -n local-path-storage \
    --timeout=180s

success "Local Path Provisioner is ready."


# =========================================================
# VALIDATE MANIFESTS
# =========================================================

CURRENT_STEP="validating manifests"

log "Validating Kubernetes manifests..."

for file in \
    k8s/database-secret.yaml \
    k8s/database-pvc.yaml \
    k8s/database-deployment.yaml \
    k8s/database-service.yaml \
    k8s/backend-deployment.yaml \
    k8s/backend-service.yaml \
    k8s/frontend-deployment.yaml \
    k8s/frontend-service.yaml \
    k8s/ingress.yaml
do

    kubectl apply \
        --dry-run=server \
        -n "${NAMESPACE}" \
        -f "${file}" >/dev/null

    success "Validated ${file}"

done


# =========================================================
# DATABASE SECRET
# =========================================================

CURRENT_STEP="creating database secret"

log "Applying database Secret..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-secret.yaml

success "Database Secret applied."


# =========================================================
# DATABASE PVC
# =========================================================

CURRENT_STEP="creating database PVC"

log "Applying database PVC..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-pvc.yaml

success "Database PVC applied."


# =========================================================
# DATABASE
# =========================================================

CURRENT_STEP="deploying database"

log "Applying database Deployment..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-deployment.yaml

success "Database Deployment applied."


CURRENT_STEP="waiting for database"

log "Waiting for database rollout..."

kubectl rollout status \
    deployment/database \
    -n "${NAMESPACE}" \
    --timeout=180s

success "Database is Ready."


# =========================================================
# DATABASE SERVICE
# =========================================================

CURRENT_STEP="creating database service"

log "Applying database Service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-service.yaml

success "Database Service applied."


# =========================================================
# BACKEND
# =========================================================

CURRENT_STEP="deploying backend"

log "Applying backend Deployment..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/backend-deployment.yaml

success "Backend Deployment applied."


# =========================================================
# BACKEND SERVICE
# =========================================================

CURRENT_STEP="creating backend service"

log "Applying backend Service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/backend-service.yaml

success "Backend Service applied."


# =========================================================
# BACKEND ROLLOUT
# =========================================================

CURRENT_STEP="waiting for backend rollout"

log "Waiting for backend rollout..."

if ! kubectl rollout status \
    deployment/backend \
    -n "${NAMESPACE}" \
    --timeout=180s
then

    fail "Backend rollout failed."

    echo
    echo "================ BACKEND STATUS ================"

    kubectl get pods \
        -n "${NAMESPACE}" \
        -l app=backend \
        -o wide

    echo
    echo "================ BACKEND DESCRIPTION ================"

    BACKEND_POD="$(get_pod_by_label "app=backend")"

    if [[ -n "${BACKEND_POD}" ]]; then

        kubectl describe pod \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" || true

        echo
        echo "================ CURRENT LOGS ================"

        kubectl logs \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=150 || true

        echo
        echo "================ PREVIOUS LOGS ================"

        kubectl logs \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" \
            --previous \
            --all-containers=true \
            --tail=150 || true

    fi

    exit 1
fi

success "Backend is Ready."


# =========================================================
# FRONTEND
# =========================================================

CURRENT_STEP="deploying frontend"

log "Applying frontend Deployment..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/frontend-deployment.yaml

success "Frontend Deployment applied."


# =========================================================
# FRONTEND SERVICE
# =========================================================

CURRENT_STEP="creating frontend service"

log "Applying frontend Service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/frontend-service.yaml

success "Frontend Service applied."


# =========================================================
# FRONTEND ROLLOUT
# =========================================================

CURRENT_STEP="waiting for frontend rollout"

log "Waiting for frontend rollout..."

if ! kubectl rollout status \
    deployment/frontend \
    -n "${NAMESPACE}" \
    --timeout=180s
then

    fail "Frontend rollout failed."

    echo
    echo "================ FRONTEND STATUS ================"

    kubectl get pods \
        -n "${NAMESPACE}" \
        -l app=frontend \
        -o wide

    echo
    echo "================ FRONTEND DESCRIPTION ================"

    FRONTEND_POD="$(get_pod_by_label "app=frontend")"

    if [[ -n "${FRONTEND_POD}" ]]; then

        kubectl describe pod \
            "${FRONTEND_POD}" \
            -n "${NAMESPACE}" || true

        echo
        echo "================ FRONTEND LOGS ================"

        kubectl logs \
            "${FRONTEND_POD}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=150 || true

    fi

    echo
    echo "================ FRONTEND DEPLOYMENT ================"

    kubectl describe deployment \
        frontend \
        -n "${NAMESPACE}" || true

    exit 1

fi

success "Frontend is Ready."


# =========================================================
# INGRESS CONTROLLER
# =========================================================

CURRENT_STEP="installing nginx ingress controller"

log "Checking NGINX Ingress Controller..."

if kubectl get ingressclass "${INGRESS_CLASS}" >/dev/null 2>&1; then

    success "IngressClass ${INGRESS_CLASS} already exists."

else

    warn "IngressClass not found."

    log "Installing NGINX Ingress Controller..."

    kubectl apply \
        -f "${NGINX_INGRESS_MANIFEST}"

    success "NGINX Ingress Controller applied."

fi


# =========================================================
# WAIT INGRESS
# =========================================================

CURRENT_STEP="waiting for nginx ingress"

log "Waiting for NGINX Ingress Controller..."

kubectl wait \
    --for=condition=Available \
    deployment/ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=180s

success "NGINX Ingress Controller is Ready."


# =========================================================
# INGRESS
# =========================================================

CURRENT_STEP="creating ingress"

log "Applying application Ingress..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/ingress.yaml

success "Application Ingress applied."


# =========================================================
# FINAL CHECK
# =========================================================

CURRENT_STEP="final health check"

log "Checking final application state..."

echo

kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

echo

kubectl get deployments \
    -n "${NAMESPACE}"

echo

kubectl get svc \
    -n "${NAMESPACE}"

echo

kubectl get pvc \
    -n "${NAMESPACE}"

echo

kubectl get ingress \
    -n "${NAMESPACE}"


# =========================================================
# FINAL POD CHECK
# =========================================================

log "Verifying all application Pods..."

if ! kubectl wait \
    --for=condition=Ready \
    pods \
    -n "${NAMESPACE}" \
    --all \
    --timeout=180s
then

    fail "Some application Pods are not Ready."

    show_diagnostics

    exit 1
fi


# =========================================================
# COMPLETE
# =========================================================

echo
echo "========================================================="
echo "                 DEPLOYMENT COMPLETE"
echo "========================================================="
echo

success "HireFlow deployment completed successfully."

echo

echo "Application Pods:"
kubectl get pods -n "${NAMESPACE}" -o wide

echo

echo "Services:"
kubectl get svc -n "${NAMESPACE}"

echo

echo "Ingress:"
kubectl get ingress -n "${NAMESPACE}"

echo

echo "Ingress Controller:"
kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx

echo