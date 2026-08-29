#!/usr/bin/env bash

# =========================================================
# HireFlow Kubernetes Deployment
# Clean + Reliable Deployment Script
# =========================================================

set -Eeuo pipefail

# =========================================================
# CONFIGURATION
# =========================================================

NAMESPACE="hireflow"

STORAGE_CLASS="local-path"

LOCAL_PATH_MANIFEST="https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"

INGRESS_CLASS="nginx"

NGINX_INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/baremetal/deploy.yaml"

CLEAN_DEPLOY="${CLEAN_DEPLOY:-true}"

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

# =========================================================
# COLORS
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =========================================================
# LOGGING
# =========================================================

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

# =========================================================
# ERROR HANDLER
# =========================================================

on_error() {

    local exit_code=$?

    echo
    fail "Deployment failed."
    echo
    echo "Failed step : ${CURRENT_STEP}"
    echo "Exit code   : ${exit_code}"

    show_diagnostics || true

    echo
    fail "Fix the problem and run ./deploy.sh again."

    exit "${exit_code}"
}

trap on_error ERR

# =========================================================
# HELPER FUNCTIONS
# =========================================================

get_pod_by_label() {

    local namespace="$1"
    local label="$2"

    kubectl get pods \
        -n "${namespace}" \
        -l "${label}" \
        -o jsonpath='{.items[0].metadata.name}' \
        2>/dev/null || true
}

wait_for_pod() {

    local namespace="$1"
    local label="$2"
    local timeout="${3:-120}"

    local elapsed=0
    local pod_name=""

    while (( elapsed < timeout )); do

        pod_name="$(get_pod_by_label "${namespace}" "${label}")"

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

        sleep 3
        elapsed=$((elapsed + 3))

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

    kubectl rollout status \
        deployment/ingress-nginx-controller \
        -n ingress-nginx \
        --timeout="${timeout}s"
}

# =========================================================
# DIAGNOSTICS
# =========================================================

show_pod_diagnostics() {

    local label="$1"
    local component="$2"

    echo
    echo "---------------------------------------------------------"
    echo " ${component} DIAGNOSTICS"
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

        echo
        echo ">>> Describe"

        kubectl describe pod \
            "${pod}" \
            -n "${NAMESPACE}" \
            2>/dev/null || true

        echo
        echo ">>> Current logs"

        kubectl logs \
            "${pod}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=150 \
            2>/dev/null || true

        echo
        echo ">>> Previous logs"

        kubectl logs \
            "${pod}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --previous \
            --tail=150 \
            2>/dev/null || true

    done <<< "${pods}"
}

# =========================================================
# FULL DIAGNOSTICS
# =========================================================

show_diagnostics() {

    section "KUBERNETES DIAGNOSTICS"

    echo
    echo ">>> Nodes"

    kubectl get nodes -o wide 2>/dev/null || true

    echo
    echo ">>> StorageClass"

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
    echo ">>> Local Path Provisioner logs"

    kubectl logs \
        -n local-path-storage \
        deployment/local-path-provisioner \
        --tail=100 \
        2>/dev/null || true

    echo
    echo ">>> NGINX Ingress"

    kubectl get deployment \
        ingress-nginx-controller \
        -n ingress-nginx \
        -o wide \
        2>/dev/null || true

    kubectl get pods \
        -n ingress-nginx \
        -o wide \
        2>/dev/null || true

    kubectl get svc \
        -n ingress-nginx \
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
    echo ">>> Ingress"

    kubectl get ingress \
        -n "${NAMESPACE}" \
        2>/dev/null || true

    echo
    echo ">>> Application Events"

    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        2>/dev/null \
        | tail -60 || true

    echo
    echo ">>> Storage Events"

    kubectl get events \
        -n local-path-storage \
        --sort-by='.lastTimestamp' \
        2>/dev/null \
        | tail -40 || true

    echo
    echo ">>> Ingress Events"

    kubectl get events \
        -n ingress-nginx \
        --sort-by='.lastTimestamp' \
        2>/dev/null \
        | tail -40 || true
}

# =========================================================
# START
# =========================================================

section "HireFlow Kubernetes Deployment"

echo
info "Clean deployment mode: ${CLEAN_DEPLOY}"

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

if ! kubectl cluster-info >/dev/null 2>&1; then

    fail "Cannot connect to Kubernetes cluster."

    echo
    echo "Run:"
    echo "  kubectl get nodes"

    exit 1
fi

success "Kubernetes cluster is reachable."

# =========================================================
# CHECK NODES
# =========================================================

CURRENT_STEP="checking Kubernetes nodes"

log "Checking Kubernetes nodes..."

kubectl get nodes -o wide

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

# =========================================================
# CHECK MANIFEST FILES
# =========================================================

CURRENT_STEP="checking manifest files"

log "Checking manifest files..."

for file in "${FILES[@]}"; do

    if [[ ! -f "${file}" ]]; then

        fail "Missing file: ${file}"

        exit 1
    fi

    success "Found ${file}"

done

# =========================================================
# CLEAN OLD HIREFLOW DEPLOYMENT
# =========================================================

CURRENT_STEP="cleaning old HireFlow deployment"

if [[ "${CLEAN_DEPLOY}" == "true" ]]; then

    section "Cleaning Existing HireFlow Deployment"

    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then

        warn "Existing namespace ${NAMESPACE} found."

        log "Deleting old HireFlow namespace..."

        kubectl delete namespace "${NAMESPACE}" \
            --wait=true \
            --timeout=180s

        success "Old HireFlow namespace deleted."

    else

        success "No old HireFlow namespace found."

    fi

else

    info "Clean deployment disabled."

fi

# =========================================================
# CREATE NAMESPACE
# =========================================================

CURRENT_STEP="creating namespace"

section "Creating Namespace"

log "Creating namespace..."

kubectl apply \
    -f k8s/namespace.yaml

kubectl wait \
    --for=jsonpath='{.status.phase}'=Active \
    "namespace/${NAMESPACE}" \
    --timeout=60s \
    >/dev/null

success "Namespace ${NAMESPACE} is ready."

# =========================================================
# LOCAL PATH PROVISIONER
# =========================================================

CURRENT_STEP="checking local-path storage provisioner"

section "Checking Local Path Storage"

log "Checking StorageClass ${STORAGE_CLASS}..."

if kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then

    success "StorageClass ${STORAGE_CLASS} exists."

else

    warn "StorageClass ${STORAGE_CLASS} does not exist."

    log "Installing Local Path Provisioner..."

    kubectl apply \
        -f "${LOCAL_PATH_MANIFEST}"

    success "Local Path Provisioner installed."

fi

# =========================================================
# ENSURE LOCAL PATH PROVISIONER EXISTS
# =========================================================

CURRENT_STEP="ensuring local-path provisioner"

if ! kubectl get deployment \
    local-path-provisioner \
    -n local-path-storage \
    >/dev/null 2>&1
then

    log "Local Path Provisioner deployment not found."

    kubectl apply \
        -f "${LOCAL_PATH_MANIFEST}"

    success "Local Path Provisioner manifest applied."

fi

# =========================================================
# RESTART LOCAL PATH PROVISIONER
# =========================================================

CURRENT_STEP="restarting local-path provisioner"

log "Restarting Local Path Provisioner..."

kubectl rollout restart \
    deployment/local-path-provisioner \
    -n local-path-storage

success "Local Path Provisioner restart requested."

# =========================================================
# WAIT LOCAL PATH
# =========================================================

CURRENT_STEP="waiting for local-path provisioner"

log "Waiting for Local Path Provisioner..."

if wait_for_ingress_controller 1 >/dev/null 2>&1; then
    :
fi

if kubectl rollout status \
    deployment/local-path-provisioner \
    -n local-path-storage \
    --timeout=180s
then

    success "Local Path Provisioner rollout completed."

else

    fail "Local Path Provisioner failed."

    kubectl get deployment \
        local-path-provisioner \
        -n local-path-storage \
        -o wide \
        || true

    kubectl get pods \
        -n local-path-storage \
        -o wide \
        || true

    kubectl logs \
        -n local-path-storage \
        deployment/local-path-provisioner \
        --tail=200 \
        || true

    exit 1

fi

# =========================================================
# VERIFY LOCAL PATH POD
# =========================================================

CURRENT_STEP="verifying local-path provisioner"

LOCAL_PATH_POD="$(
    kubectl get pods \
        -n local-path-storage \
        -l app=local-path-provisioner \
        -o jsonpath='{.items[0].metadata.name}'
)"

if [[ -z "${LOCAL_PATH_POD}" ]]; then

    fail "Local Path Provisioner pod not found."

    exit 1
fi

success "Local Path Provisioner pod: ${LOCAL_PATH_POD}"

kubectl get pod \
    "${LOCAL_PATH_POD}" \
    -n local-path-storage \
    -o wide

# =========================================================
# VERIFY STORAGE CLASS
# =========================================================

CURRENT_STEP="verifying storage class"

if ! kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then

    fail "StorageClass ${STORAGE_CLASS} is unavailable."

    exit 1
fi

success "StorageClass ${STORAGE_CLASS} is available."

kubectl get storageclass "${STORAGE_CLASS}"

# =========================================================
# VALIDATE MANIFESTS
# =========================================================

CURRENT_STEP="validating Kubernetes manifests"

section "Validating Kubernetes Manifests"

for file in "${VALIDATION_FILES[@]}"; do

    if kubectl apply \
        --dry-run=server \
        -n "${NAMESPACE}" \
        -f "${file}" \
        >/dev/null
    then

        success "Validated ${file}"

    else

        fail "Invalid Kubernetes manifest: ${file}"

        exit 1
    fi

done

# =========================================================
# DATABASE SECRET
# =========================================================

CURRENT_STEP="creating database secret"

section "Deploying Database"

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

# =========================================================
# DATABASE PVC
# =========================================================

CURRENT_STEP="creating database PVC"

log "Creating database PVC..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-pvc.yaml

success "Database PVC created."

# =========================================================
# WAIT PVC
# =========================================================

CURRENT_STEP="waiting for database PVC"

log "Waiting for database PVC to become Bound..."

if wait_for_pvc "database-pvc" 180; then

    success "Database PVC is Bound."

else

    PVC_RESULT=$?

    if [[ "${PVC_RESULT}" -eq 2 ]]; then

        fail "Database PVC entered Lost state."

    else

        fail "Database PVC did not become Bound."

    fi

    kubectl describe pvc \
        database-pvc \
        -n "${NAMESPACE}" \
        || true

    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -60 \
        || true

    exit 1
fi

kubectl get pvc \
    -n "${NAMESPACE}"

# =========================================================
# DATABASE SERVICE FIRST
# =========================================================

CURRENT_STEP="creating database service"

log "Creating database service before database deployment..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-service.yaml

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
# DATABASE DEPLOYMENT
# =========================================================

CURRENT_STEP="deploying database"

log "Deploying PostgreSQL..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/database-deployment.yaml

success "Database Deployment created."

# =========================================================
# WAIT DATABASE POD
# =========================================================

CURRENT_STEP="waiting for database pod"

log "Waiting for database Pod..."

if DB_POD_NAME="$(wait_for_pod "${NAMESPACE}" "app=database" 60)"; then

    success "Database Pod created: ${DB_POD_NAME}"

else

    fail "Database Pod was not created."

    show_pod_diagnostics \
        "app=database" \
        "DATABASE"

    exit 1
fi

# =========================================================
# DATABASE ROLLOUT
# =========================================================

CURRENT_STEP="waiting for database rollout"

log "Waiting for PostgreSQL to become Ready..."

if wait_for_deployment "database" 180; then

    success "Database is Ready."

else

    fail "Database rollout failed."

    show_pod_diagnostics \
        "app=database" \
        "DATABASE"

    exit 1
fi

# =========================================================
# DATABASE ENDPOINT
# =========================================================

CURRENT_STEP="checking database service endpoints"

log "Checking database endpoints..."

sleep 3

kubectl get endpoints \
    database-service \
    -n "${NAMESPACE}" \
    || true

# =========================================================
# BACKEND
# =========================================================

CURRENT_STEP="deploying backend"

section "Deploying Backend"

log "Creating Backend Service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/backend-service.yaml

success "Backend Service created."

log "Deploying Backend..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/backend-deployment.yaml

success "Backend Deployment created."

# =========================================================
# BACKEND POD
# =========================================================

CURRENT_STEP="waiting for backend pod"

log "Waiting for Backend Pod..."

if BACKEND_POD_NAME="$(wait_for_pod "${NAMESPACE}" "app=backend" 60)"; then

    success "Backend Pod created: ${BACKEND_POD_NAME}"

else

    fail "Backend Pod was not created."

    show_pod_diagnostics \
        "app=backend" \
        "BACKEND"

    exit 1
fi

# =========================================================
# BACKEND ROLLOUT
# =========================================================

CURRENT_STEP="waiting for backend rollout"

log "Waiting for Backend rollout..."

if wait_for_deployment "backend" 240; then

    success "Backend is Ready."

else

    fail "Backend rollout failed."

    show_pod_diagnostics \
        "app=backend" \
        "BACKEND"

    exit 1
fi

# =========================================================
# BACKEND ENDPOINT
# =========================================================

log "Checking Backend endpoints..."

kubectl get endpoints \
    backend-service \
    -n "${NAMESPACE}" \
    || true

# =========================================================
# FRONTEND
# =========================================================

CURRENT_STEP="deploying frontend"

section "Deploying Frontend"

log "Creating Frontend Service..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/frontend-service.yaml

success "Frontend Service created."

log "Deploying Frontend..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/frontend-deployment.yaml

success "Frontend Deployment created."

# =========================================================
# FRONTEND POD
# =========================================================

CURRENT_STEP="waiting for frontend pod"

log "Waiting for Frontend Pod..."

if FRONTEND_POD_NAME="$(wait_for_pod "${NAMESPACE}" "app=frontend" 60)"; then

    success "Frontend Pod created: ${FRONTEND_POD_NAME}"

else

    fail "Frontend Pod was not created."

    show_pod_diagnostics \
        "app=frontend" \
        "FRONTEND"

    exit 1
fi

# =========================================================
# FRONTEND ROLLOUT
# =========================================================

CURRENT_STEP="waiting for frontend rollout"

log "Waiting for Frontend rollout..."

if wait_for_deployment "frontend" 240; then

    success "Frontend is Ready."

else

    fail "Frontend rollout failed."

    show_pod_diagnostics \
        "app=frontend" \
        "FRONTEND"

    exit 1
fi

# =========================================================
# FRONTEND ENDPOINT
# =========================================================

log "Checking Frontend endpoints..."

kubectl get endpoints \
    frontend-service \
    -n "${NAMESPACE}" \
    || true

# =========================================================
# NGINX INGRESS
# =========================================================

CURRENT_STEP="checking nginx ingress"

section "Configuring NGINX Ingress"

log "Checking NGINX Ingress Controller..."

if kubectl get deployment \
    ingress-nginx-controller \
    -n ingress-nginx \
    >/dev/null 2>&1
then

    success "NGINX Ingress Controller already exists."

else

    warn "NGINX Ingress Controller not found."

    log "Installing NGINX Ingress Controller..."

    kubectl apply \
        -f "${NGINX_INGRESS_MANIFEST}"

    success "NGINX Ingress Controller installed."

fi

# =========================================================
# RESTART NGINX ONLY IF NEEDED
# =========================================================

CURRENT_STEP="checking nginx ingress health"

NGINX_READY="$(
    kubectl get deployment \
        ingress-nginx-controller \
        -n ingress-nginx \
        -o jsonpath='{.status.readyReplicas}' \
        2>/dev/null || echo "0"
)"

NGINX_DESIRED="$(
    kubectl get deployment \
        ingress-nginx-controller \
        -n ingress-nginx \
        -o jsonpath='{.spec.replicas}' \
        2>/dev/null || echo "1"
)"

if [[ "${NGINX_READY:-0}" != "${NGINX_DESIRED:-1}" ]]; then

    warn "NGINX Ingress Controller is not fully Ready."

    log "Restarting NGINX Ingress Controller..."

    kubectl rollout restart \
        deployment/ingress-nginx-controller \
        -n ingress-nginx

else

    success "NGINX Ingress Controller is already healthy."

fi

# =========================================================
# WAIT NGINX
# =========================================================

CURRENT_STEP="waiting for nginx ingress controller"

log "Waiting for NGINX Ingress Controller..."

if wait_for_ingress_controller 240; then

    success "NGINX Ingress Controller is Ready."

else

    fail "NGINX Ingress Controller did not become Ready."

    kubectl get deployment \
        ingress-nginx-controller \
        -n ingress-nginx \
        -o wide \
        || true

    kubectl get pods \
        -n ingress-nginx \
        -o wide \
        || true

    kubectl logs \
        -n ingress-nginx \
        deployment/ingress-nginx-controller \
        --tail=150 \
        || true

    kubectl get events \
        -n ingress-nginx \
        --sort-by='.lastTimestamp' \
        | tail -60 \
        || true

    exit 1
fi

# =========================================================
# VERIFY INGRESS CLASS
# =========================================================

CURRENT_STEP="verifying nginx ingress class"

if kubectl get ingressclass "${INGRESS_CLASS}" \
    >/dev/null 2>&1
then

    success "IngressClass ${INGRESS_CLASS} is available."

else

    fail "IngressClass ${INGRESS_CLASS} was not created."

    kubectl get ingressclass || true

    exit 1
fi

kubectl get ingressclass "${INGRESS_CLASS}"

# =========================================================
# NGINX SERVICE
# =========================================================

CURRENT_STEP="checking nginx service"

if kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx \
    >/dev/null 2>&1
then

    success "NGINX Ingress Service is available."

else

    fail "NGINX Ingress Service was not created."

    exit 1
fi

kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx

# =========================================================
# APPLICATION INGRESS
# =========================================================

CURRENT_STEP="creating application ingress"

log "Creating HireFlow Ingress..."

kubectl apply \
    -n "${NAMESPACE}" \
    -f k8s/ingress.yaml

success "HireFlow Ingress created."

# =========================================================
# VERIFY INGRESS
# =========================================================

CURRENT_STEP="checking application ingress"

if kubectl get ingress frontend-ingress \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
then

    success "Frontend Ingress is available."

else

    fail "Frontend Ingress was not created."

    exit 1
fi

kubectl get ingress \
    -n "${NAMESPACE}"

# =========================================================
# FINAL POD HEALTH
# =========================================================

CURRENT_STEP="final application health check"

section "Final Application Health Check"

log "Waiting for all HireFlow Pods..."

if kubectl wait \
    --for=condition=Ready \
    pods \
    -n "${NAMESPACE}" \
    --all \
    --timeout=240s \
    >/dev/null 2>&1
then

    success "All HireFlow Pods are Ready."

else

    fail "Not all HireFlow Pods became Ready."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide

    echo
    echo ">>> Database diagnostics"

    show_pod_diagnostics \
        "app=database" \
        "DATABASE"

    echo
    echo ">>> Backend diagnostics"

    show_pod_diagnostics \
        "app=backend" \
        "BACKEND"

    echo
    echo ">>> Frontend diagnostics"

    show_pod_diagnostics \
        "app=frontend" \
        "FRONTEND"

    exit 1
fi

# =========================================================
# FINAL SERVICE CHECK
# =========================================================

CURRENT_STEP="final service check"

section "Service Health"

kubectl get svc \
    -n "${NAMESPACE}" \
    -o wide

echo

kubectl get endpoints \
    -n "${NAMESPACE}"

# =========================================================
# FINAL PVC CHECK
# =========================================================

CURRENT_STEP="final storage check"

section "Storage Health"

kubectl get pvc \
    -n "${NAMESPACE}"

PVC_STATUS="$(
    kubectl get pvc database-pvc \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}'
)"

if [[ "${PVC_STATUS}" != "Bound" ]]; then

    fail "Database PVC is not Bound: ${PVC_STATUS}"

    exit 1
fi

success "Database PVC is Bound."

# =========================================================
# FINAL INGRESS CHECK
# =========================================================

CURRENT_STEP="final ingress check"

section "Ingress Health"

kubectl get ingress \
    -n "${NAMESPACE}" \
    -o wide

kubectl describe ingress \
    frontend-ingress \
    -n "${NAMESPACE}" \
    | tail -50

# =========================================================
# FINAL STATUS
# =========================================================

section "DEPLOYMENT COMPLETE"

echo

echo "========================================================="
echo " Namespace"
echo "========================================================="

kubectl get namespace "${NAMESPACE}"

echo

echo "========================================================="
echo " Nodes"
echo "========================================================="

kubectl get nodes -o wide

echo

echo "========================================================="
echo " StorageClass"
echo "========================================================="

kubectl get storageclass "${STORAGE_CLASS}"

echo

echo "========================================================="
echo " Local Path Provisioner"
echo "========================================================="

kubectl get deployment \
    local-path-provisioner \
    -n local-path-storage

kubectl get pods \
    -n local-path-storage \
    -o wide

echo

echo "========================================================="
echo " NGINX Ingress Controller"
echo "========================================================="

kubectl get deployment \
    ingress-nginx-controller \
    -n ingress-nginx

kubectl get svc \
    ingress-nginx-controller \
    -n ingress-nginx

echo

echo "========================================================="
echo " HireFlow Pods"
echo "========================================================="

kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

echo

echo "========================================================="
echo " HireFlow Deployments"
echo "========================================================="

kubectl get deployments \
    -n "${NAMESPACE}"

echo

echo "========================================================="
echo " HireFlow Services"
echo "========================================================="

kubectl get svc \
    -n "${NAMESPACE}" \
    -o wide

echo

echo "========================================================="
echo " HireFlow PVC"
echo "========================================================="

kubectl get pvc \
    -n "${NAMESPACE}"

echo

echo "========================================================="
echo " HireFlow Ingress"
echo "========================================================="

kubectl get ingress \
    -n "${NAMESPACE}" \
    -o wide

echo

echo "========================================================="
echo " FINAL EVENTS"
echo "========================================================="

kubectl get events \
    -n "${NAMESPACE}" \
    --sort-by='.lastTimestamp' \
    | tail -30

echo

echo "========================================================="
echo " SUCCESS"
echo "========================================================="

success "HireFlow deployment completed successfully."

echo
info "Useful commands:"
echo
echo "  kubectl get pods -n hireflow -o wide"
echo "  kubectl get svc -n hireflow"
echo "  kubectl get pvc -n hireflow"
echo "  kubectl get ingress -n hireflow"
echo "  kubectl get endpoints -n hireflow"
echo
echo "  kubectl logs -n hireflow deployment/backend --tail=100"
echo "  kubectl logs -n hireflow deployment/frontend --tail=100"
echo "  kubectl logs -n hireflow deployment/database --tail=100"
echo
echo "  kubectl describe pod -n hireflow <pod-name>"
echo