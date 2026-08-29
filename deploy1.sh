```bash
#!/usr/bin/env bash

# =========================================================
# HireFlow Kubernetes Deployment Script
# =========================================================

set -Eeuo pipefail

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

NAMESPACE="hireflow"

STORAGE_CLASS="local-path"
LOCAL_PATH_MANIFEST="https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"

INGRESS_CLASS="nginx"
NGINX_INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/baremetal/deploy.yaml"

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

VALIDATION_FILES=(
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

CURRENT_STEP="initialization"

# ---------------------------------------------------------
# Colors
# ---------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------
# Logging Functions
# ---------------------------------------------------------

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

info() {
    echo -e "${CYAN}ℹ $*${NC}"
}

section() {
    echo
    echo "========================================================="
    echo " $*"
    echo "========================================================="
}

# ---------------------------------------------------------
# Kubernetes Helper Functions
# ---------------------------------------------------------

get_pod_by_label() {
    local label="$1"

    kubectl get pods \
        -n "${NAMESPACE}" \
        -l "${label}" \
        -o jsonpath='{.items[0].metadata.name}' \
        2>/dev/null || true
}

wait_for_pod() {
    local label="$1"
    local timeout="${2:-60}"

    local elapsed=0
    local pod_name=""

    while (( elapsed < timeout )); do

        pod_name="$(get_pod_by_label "${label}")"

        if [[ -n "${pod_name}" ]]; then
            echo "${pod_name}"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

wait_for_pvc() {
    local pvc_name="$1"
    local timeout="${2:-180}"

    local elapsed=0
    local status=""

    while (( elapsed < timeout )); do

        status="$(
            kubectl get pvc "${pvc_name}" \
                -n "${NAMESPACE}" \
                -o jsonpath='{.status.phase}' \
                2>/dev/null || true
        )"

        case "${status}" in

            Bound)
                return 0
                ;;

            Lost)
                return 2
                ;;

            "")
                status="Pending"
                ;;

        esac

        echo "  PVC status: ${status}"

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

wait_for_deployment() {
    local deployment="$1"
    local timeout="${2:-180}"

    kubectl rollout status \
        "deployment/${deployment}" \
        -n "${NAMESPACE}" \
        --timeout="${timeout}s"
}

wait_for_ingress_controller() {
    local timeout="${1:-180}"

    kubectl wait \
        --namespace ingress-nginx \
        --for=condition=Available \
        deployment/ingress-nginx-controller \
        --timeout="${timeout}s"
}

# ---------------------------------------------------------
# Resource Diagnostics
# ---------------------------------------------------------

show_resource_diagnostics() {
    local resource_type="$1"
    local resource_name="$2"

    echo
    echo ">>> ${resource_type}: ${resource_name}"

    kubectl describe \
        "${resource_type}" \
        "${resource_name}" \
        -n "${NAMESPACE}" \
        2>/dev/null || true
}

show_pod_diagnostics() {
    local label="$1"
    local component="$2"

    echo
    echo "---------------------------------------------------------"
    echo " ${component} POD DIAGNOSTICS"
    echo "---------------------------------------------------------"

    kubectl get pods \
        -n "${NAMESPACE}" \
        -l "${label}" \
        -o wide \
        2>/dev/null || true

    local pods

    pods="$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l "${label}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
            2>/dev/null || true
    )"

    if [[ -z "${pods}" ]]; then
        warn "No ${component} pods found."
        return 0
    fi

    while IFS= read -r pod; do

        [[ -z "${pod}" ]] && continue

        echo
        echo ">>> Pod: ${pod}"

        kubectl describe pod \
            "${pod}" \
            -n "${NAMESPACE}" \
            2>/dev/null || true

        echo
        echo ">>> Current logs: ${pod}"

        kubectl logs \
            "${pod}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=100 \
            2>/dev/null || true

        echo
        echo ">>> Previous container logs: ${pod}"

        kubectl logs \
            "${pod}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --previous \
            --tail=100 \
            2>/dev/null || true

    done <<< "${pods}"
}

# ---------------------------------------------------------
# Full Diagnostics
# ---------------------------------------------------------

show_diagnostics() {

    section "KUBERNETES DIAGNOSTICS"

    echo
    echo ">>> Nodes"
    kubectl get nodes -o wide 2>/dev/null || true

    echo
    echo ">>> StorageClasses"
    kubectl get storageclass 2>/dev/null || true

    echo
    echo ">>> Local Path Provisioner"
    kubectl get deployment \
        local-path-provisioner \
        -n local-path-storage \
        -o wide \
        2>/dev/null || true

    kubectl get pods \
        -n local-path-storage \
        -o wide \
        2>/dev/null || true

    echo
    echo ">>> NGINX Ingress Controller"
    kubectl get deployment \
        ingress-nginx-controller \
        -n ingress-nginx \
        -o wide \
        2>/dev/null || true

    kubectl get pods \
        -n ingress-nginx \
        -o wide \
        2>/dev/null || true

    echo
    echo ">>> NGINX Services"
    kubectl get svc \
        -n ingress-nginx \
        2>/dev/null || true

    echo
    echo ">>> IngressClasses"
    kubectl get ingressclass \
        2>/dev/null || true

    echo
    echo ">>> Application Pods"
    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide \
        2>/dev/null || true

    echo
    echo ">>> Deployments"
    kubectl get deployments \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> ReplicaSets"
    kubectl get rs \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> Services"
    kubectl get svc \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> PVC"
    kubectl get pvc \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> Secrets"
    kubectl get secrets \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> Ingress"
    kubectl get ingress \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> Recent Application Events"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        2>/dev/null \
        | tail -50 || true

    echo
    echo ">>> Recent Ingress Events"
    kubectl get events \
        -n ingress-nginx \
        --sort-by='.lastTimestamp' \
        2>/dev/null \
        | tail -30 || true
}

# ---------------------------------------------------------
# Error Handler
# ---------------------------------------------------------

on_error() {

    local exit_code=$?

    echo

    fail "Deployment failed."
    echo
    echo "Failed step : ${CURRENT_STEP}"
    echo "Exit code   : ${exit_code}"

    show_diagnostics

    echo
    fail "Fix the problem and run the script again."

    exit "${exit_code}"
}

trap on_error ERR

# =========================================================
# START
# =========================================================

section "HireFlow Kubernetes Deployment"

# ---------------------------------------------------------
# Check kubectl
# ---------------------------------------------------------

CURRENT_STEP="checking kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl is not installed."
    exit 1
fi

success "kubectl found."

# ---------------------------------------------------------
# Check Kubernetes Connection
# ---------------------------------------------------------

CURRENT_STEP="checking Kubernetes connection"

log "Checking Kubernetes cluster..."

if ! kubectl cluster-info >/dev/null 2>&1; then

    fail "Cannot connect to Kubernetes cluster."

    echo
    echo "Run:"
    echo "  kubectl get nodes"

    exit 1
fi

success "Kubernetes cluster is reachable."

# ---------------------------------------------------------
# Check Nodes
# ---------------------------------------------------------

CURRENT_STEP="checking Kubernetes nodes"

log "Checking Kubernetes nodes..."

NODE_COUNT="$(
    kubectl get nodes \
        --no-headers \
        2>/dev/null \
        | wc -l
)"

if [[ "${NODE_COUNT}" -eq 0 ]]; then
    fail "No Kubernetes nodes found."
    exit 1
fi

NOT_READY_NODES="$(
    kubectl get nodes \
        --no-headers \
        2>/dev/null \
        | awk '$2 != "Ready" {print $1}'
)"

if [[ -n "${NOT_READY_NODES}" ]]; then

    fail "Some Kubernetes nodes are not Ready:"
    echo "${NOT_READY_NODES}"

    exit 1
fi

success "All Kubernetes nodes are Ready."

kubectl get nodes -o wide

# ---------------------------------------------------------
# Check Manifest Files
# ---------------------------------------------------------

CURRENT_STEP="checking manifest files"

log "Checking manifest files..."

for file in "${FILES[@]}"; do

    if [[ ! -f "${file}" ]]; then
        fail "Missing file: ${file}"
        exit 1
    fi

    success "Found ${file}"

done

# ---------------------------------------------------------
# Namespace
# ---------------------------------------------------------

CURRENT_STEP="creating namespace"

log "Creating namespace..."

kubectl apply \
    -f k8s/namespace.yaml

if kubectl wait \
    --for=jsonpath='{.status.phase}'=Active \
    "namespace/${NAMESPACE}" \
    --timeout=60s \
    >/dev/null 2>&1
then
    success "Namespace ${NAMESPACE} is ready."
else
    fail "Namespace ${NAMESPACE} did not become ready."
    exit 1
fi

# ---------------------------------------------------------
# Local Path Provisioner
# ---------------------------------------------------------

CURRENT_STEP="checking local-path storage provisioner"

log "Checking StorageClass ${STORAGE_CLASS}..."

if kubectl get storageclass "${STORAGE_CLASS}" \
    >/dev/null 2>&1
then

    success "StorageClass ${STORAGE_CLASS} already exists."

else

    warn "StorageClass ${STORAGE_CLASS} not found."

    log "Installing Rancher Local Path Provisioner..."

    kubectl apply \
        -f "${LOCAL_PATH_MANIFEST}"

    success "Local Path Provisioner manifest applied."

fi

# ---------------------------------------------------------
# Wait for Local Path Provisioner
# ---------------------------------------------------------

CURRENT_STEP="waiting for local-path provisioner"

log "Waiting for Local Path Provisioner..."

if kubectl wait \
    --for=condition=available \
    deployment/local-path-provisioner \
    -n local-path-storage \
    --timeout=180s \
    >/dev/null 2>&1
then

    success "Local Path Provisioner is ready."

else

    fail "Local Path Provisioner did not become ready."

    kubectl get deployment \
        local-path-provisioner \
        -n local-path-storage \
        || true

    kubectl get pods \
        -n local-path-storage \
        -o wide \
        || true

    kubectl get events \
        -n local-path-storage \
        --sort-by='.lastTimestamp' \
        | tail -40 \
        || true

    exit 1
fi

# ---------------------------------------------------------
# Verify StorageClass
# ---------------------------------------------------------

CURRENT_STEP="verifying storage class"

log "Verifying StorageClass ${STORAGE_CLASS}..."

if ! kubectl get storageclass "${STORAGE_CLASS}" \
    >/dev/null 2>&1
then

    fail "StorageClass ${STORAGE_CLASS} is unavailable."
    exit 1

fi

success "StorageClass ${STORAGE_CLASS} is available."

kubectl get storageclass "${STORAGE_CLASS}"

# ---------------------------------------------------------
# Validate Manifests
# ---------------------------------------------------------

CURRENT_STEP="validating Kubernetes manifests"

log "Validating manifests..."

for file in "${VALIDATION_FILES[@]}"; do

    if ! kubectl apply \
        --dry-run=server \
        -n "${NAMESPACE}" \
        -f "${file}" \
        >/dev/null
    then

        fail "Invalid Kubernetes manifest: ${file}"
        exit 1

    fi

    success "Validated ${file}"

done

# =========================================================
# DATABASE
# =========================================================

section "Deploying Database"

# ---------------------------------------------------------
# Database Secret
# ---------------------------------------------------------

CURRENT_STEP="creating database secret"

log "Creating database Secret..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-secret.yaml

if kubectl get secret database-secret \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
then

    success "Database Secret is available."

else

    fail "Database Secret was not created."
    exit 1

fi

# ---------------------------------------------------------
# Database PVC
# ---------------------------------------------------------

CURRENT_STEP="creating database PVC"

log "Creating database PVC..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-pvc.yaml

success "Database PVC created/updated."

# ---------------------------------------------------------
# Database Deployment
# ---------------------------------------------------------

CURRENT_STEP="deploying database"

log "Deploying database..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-deployment.yaml

success "Database Deployment created/updated."

# ---------------------------------------------------------
# Wait for Database Pod
# ---------------------------------------------------------

CURRENT_STEP="waiting for database pod"

log "Waiting for database Pod..."

if DB_POD_NAME="$(wait_for_pod "app=database" 60)"; then

    success "Database Pod was created."

else

    fail "Database Pod was not created."

    show_resource_diagnostics \
        "deployment" \
        "database"

    exit 1

fi

kubectl get pods \
    -n "${NAMESPACE}" \
    -l app=database \
    -o wide

# ---------------------------------------------------------
# Wait for PVC
# ---------------------------------------------------------

CURRENT_STEP="waiting for database PVC"

log "Waiting for database PVC to become Bound..."

if wait_for_pvc "database-pvc" 180; then

    success "Database PVC is Bound."

else

    PVC_RESULT=$?

    if [[ "${PVC_RESULT}" -eq 2 ]]; then
        fail "Database PVC entered Lost state."
    else
        fail "Database PVC did not become Bound within 180 seconds."
    fi

    kubectl describe pvc \
        database-pvc \
        -n "${NAMESPACE}" \
        || true

    kubectl get pods \
        -n "${NAMESPACE}" \
        -l app=database \
        -o wide \
        || true

    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -50 \
        || true

    exit 1
fi

# ---------------------------------------------------------
# Database Rollout
# ---------------------------------------------------------

CURRENT_STEP="waiting for database rollout"

log "Waiting for database rollout..."

if wait_for_deployment "database" 180; then

    success "Database is ready."

else

    fail "Database rollout failed."

    show_pod_diagnostics \
        "app=database" \
        "DATABASE"

    exit 1
fi

# ---------------------------------------------------------
# Database Service
# ---------------------------------------------------------

CURRENT_STEP="creating database service"

log "Creating database service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-service.yaml

success "Database service is ready."

if kubectl get svc database-service \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
then

    success "Database service is available."

else

    fail "Database service was not created."
    exit 1

fi

# =========================================================
# BACKEND
# =========================================================

section "Deploying Backend"

# ---------------------------------------------------------
# Backend Deployment
# ---------------------------------------------------------

CURRENT_STEP="deploying backend"

log "Deploying backend..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/backend-deployment.yaml

success "Backend Deployment created/updated."

# ---------------------------------------------------------
# Backend Rollout
# ---------------------------------------------------------

CURRENT_STEP="waiting for backend rollout"

log "Waiting for backend rollout..."

if wait_for_deployment "backend" 180; then

    success "Backend is ready."

else

    fail "Backend rollout failed."

    show_pod_diagnostics \
        "app=backend" \
        "BACKEND"

    exit 1
fi

# ---------------------------------------------------------
# Backend Service
# ---------------------------------------------------------

CURRENT_STEP="creating backend service"

log "Creating backend service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/backend-service.yaml

success "Backend service is ready."

if kubectl get svc backend-service \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
then

    success "Backend service is available."

else

    fail "Backend service was not created."
    exit 1

fi

# =========================================================
# FRONTEND
# =========================================================

section "Deploying Frontend"

# ---------------------------------------------------------
# Frontend Deployment
# ---------------------------------------------------------

CURRENT_STEP="deploying frontend"

log "Deploying frontend..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/frontend-deployment.yaml

success "Frontend Deployment created/updated."

# ---------------------------------------------------------
# Frontend Rollout
# ---------------------------------------------------------

CURRENT_STEP="waiting for frontend rollout"

log "Waiting for frontend rollout..."

if wait_for_deployment "frontend" 180; then

    success "Frontend is ready."

else

    fail "Frontend rollout failed."

    show_pod_diagnostics \
        "app=frontend" \
        "FRONTEND"

    exit 1
fi

# ---------------------------------------------------------
# Frontend Service
# ---------------------------------------------------------

CURRENT_STEP="creating frontend service"

log "Creating frontend service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/frontend-service.yaml

success "Frontend service is ready."

if kubectl get svc frontend-service \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
then

    success "Frontend service is available."

else

    fail "Frontend service was not created."
    exit 1

fi

# =========================================================
# NGINX INGRESS
# =========================================================

section "Configuring NGINX Ingress"

# ---------------------------------------------------------
# Check / Install NGINX
# ---------------------------------------------------------

CURRENT_STEP="installing nginx ingress controller"

log "Checking NGINX Ingress Controller..."

if kubectl get ingressclass "${INGRESS_CLASS}" \
    >/dev/null 2>&1
then

    success "IngressClass ${INGRESS_CLASS} already exists."

else

    warn "IngressClass ${INGRESS_CLASS} not found."

    log "Installing NGINX Ingress Controller..."

    kubectl apply \
        -f "${NGINX_INGRESS_MANIFEST}"

    success "NGINX Ingress Controller manifest applied."

fi

# ---------------------------------------------------------
# Wait for NGINX
# ---------------------------------------------------------

CURRENT_STEP="waiting for nginx ingress controller"

log "Waiting for NGINX Ingress Controller..."

if wait_for_ingress_controller 180; then

    success "NGINX Ingress Controller is ready."

else

    fail "NGINX Ingress Controller did not become ready."

    kubectl get deployment \
        ingress-nginx-controller \
        -n ingress-nginx \
        -o wide \
        || true

    kubectl get pods \
        -n ingress-nginx \
        -o wide \
        || true

    kubectl get svc \
        -n ingress-nginx \
        || true

    kubectl get events \
        -n ingress-nginx \
        --sort-by='.lastTimestamp' \
        | tail -50 \
        || true

    exit 1
fi

# ---------------------------------------------------------
# Verify IngressClass
# ---------------------------------------------------------

CURRENT_STEP="verifying nginx ingress class"

log "Verifying IngressClass ${INGRESS_CLASS}..."

if ! kubectl get ingressclass "${INGRESS_CLASS}" \
    >/dev/null 2>&1
then

    fail "IngressClass ${INGRESS_CLASS} was not created."

    kubectl get ingressclass || true

    exit 1
fi

success "IngressClass ${INGRESS_CLASS} is available."

kubectl get ingressclass "${INGRESS_CLASS}"

# ---------------------------------------------------------
# Check NGINX Service
# ---------------------------------------------------------

CURRENT_STEP="checking nginx ingress service"

log "Checking NGINX Ingress Service..."

if ! kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx \
    >/dev/null 2>&1
then

    fail "NGINX Ingress Controller Service was not created."
    exit 1
fi

success "NGINX Ingress Controller Service is available."

kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx

# ---------------------------------------------------------
# Application Ingress
# ---------------------------------------------------------

CURRENT_STEP="creating ingress"

log "Creating ingress..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/ingress.yaml

success "Ingress is created."

# ---------------------------------------------------------
# Verify Application Ingress
# ---------------------------------------------------------

CURRENT_STEP="checking ingress"

log "Checking frontend ingress..."

if kubectl get ingress frontend-ingress \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
then

    success "Frontend Ingress is available."

else

    fail "Frontend Ingress was not created."
    exit 1
fi

# =========================================================
# FINAL HEALTH CHECK
# =========================================================

section "Final Application Health Check"

CURRENT_STEP="checking final application health"

log "Checking final application health..."

if kubectl wait \
    --for=condition=Ready \
    pods \
    -n "${NAMESPACE}" \
    --all \
    --timeout=180s \
    >/dev/null 2>&1
then

    success "All application Pods are Ready."

else

    fail "Not all application Pods became Ready."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide

    echo
    echo "Recent events:"

    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -50 \
        || true

    exit 1
fi

# =========================================================
# DEPLOYMENT COMPLETE
# =========================================================

section "DEPLOYMENT COMPLETE"

echo
echo "Namespace:"
kubectl get namespace "${NAMESPACE}"

echo
echo "StorageClass:"
kubectl get storageclass "${STORAGE_CLASS}"

echo
echo "NGINX Ingress Controller:"
kubectl get deployment \
    ingress-nginx-controller \
    -n ingress-nginx

echo
echo "IngressClass:"
kubectl get ingressclass "${INGRESS_CLASS}"

echo
echo "NGINX Service:"
kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx

echo
echo "Secrets:"
kubectl get secrets \
    -n "${NAMESPACE}"

echo
echo "Pods:"
kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

echo
echo "Deployments:"
kubectl get deployments \
    -n "${NAMESPACE}"

echo
echo "Services:"
kubectl get svc \
    -n "${NAMESPACE}"

echo
echo "PVC:"
kubectl get pvc \
    -n "${NAMESPACE}"

echo
echo "Ingress:"
kubectl get ingress \
    -n "${NAMESPACE}"

echo
echo "========================================================="
success "HireFlow deployment completed successfully."
echo "========================================================="
echo
```
