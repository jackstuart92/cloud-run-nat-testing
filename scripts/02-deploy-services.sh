#!/bin/bash
#==============================================================================
# 02-deploy-services.sh
# Builds and deploys Cloud Run services with per-service subnets
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Parse arguments
COUNT=${NUM_SERVICES}
START_INDEX=1
PARALLEL=10

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            COUNT="$2"
            shift 2
            ;;
        --start)
            START_INDEX="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--count N] [--start INDEX] [--parallel N]"
            exit 1
            ;;
    esac
done

END_INDEX=$((START_INDEX + COUNT - 1))

echo "=============================================="
echo "Cloud Run NAT Testing - Service Deployment"
echo "=============================================="
echo "Project:     ${PROJECT_ID}"
echo "Region:      ${REGION}"
echo "Services:    ${START_INDEX} to ${END_INDEX} (${COUNT} total)"
echo "Parallel:    ${PARALLEL}"
echo "=============================================="

gcloud config set project "${PROJECT_ID}"

#------------------------------------------------------------------------------
# Build Container Image
#------------------------------------------------------------------------------
echo ""
echo "[1/3] Building container image..."

# Create source directory if needed
mkdir -p "${SCRIPT_DIR}/../src/cloud-run-service"

# Generate Dockerfile
cat > "${SCRIPT_DIR}/../src/cloud-run-service/Dockerfile" << 'DOCKERFILE'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PORT=8080
EXPOSE 8080

CMD ["python", "main.py"]
DOCKERFILE

# Generate requirements.txt
cat > "${SCRIPT_DIR}/../src/cloud-run-service/requirements.txt" << 'REQUIREMENTS'
flask==3.0.0
requests==2.31.0
gunicorn==21.2.0
REQUIREMENTS

# Generate main.py
cat > "${SCRIPT_DIR}/../src/cloud-run-service/main.py" << 'PYTHON'
import os
import time
import uuid
import logging
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Configuration from environment
SERVICE_NAME = os.environ.get("K_SERVICE", "unknown")
SERVICE_REVISION = os.environ.get("K_REVISION", "unknown")
VM_A_URL = os.environ.get("VM_A_URL", "http://10.1.0.10:8080")
VM_B_URL = os.environ.get("VM_B_URL", "http://10.2.0.10:8080")
CALLBACK_BASE_URL = os.environ.get("CALLBACK_BASE_URL", "")

# Track callbacks received
callbacks_received = {}

@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "service": SERVICE_NAME,
        "revision": SERVICE_REVISION
    })

@app.route("/info", methods=["GET"])
def info():
    """Return service information"""
    return jsonify({
        "service": SERVICE_NAME,
        "revision": SERVICE_REVISION,
        "vm_a_url": VM_A_URL,
        "vm_b_url": VM_B_URL,
        "callback_base_url": CALLBACK_BASE_URL
    })

@app.route("/ping-vm", methods=["POST"])
def ping_vm():
    """
    Ping a target VM and optionally request a callback.
    
    Request body:
    {
        "target": "a" or "b",
        "request_callback": true/false,
        "data": {...}  # optional additional data
    }
    """
    data = request.get_json() or {}
    target = data.get("target", "a")
    request_callback = data.get("request_callback", False)
    
    # Select target URL
    target_url = VM_A_URL if target == "a" else VM_B_URL
    
    # Generate correlation ID
    correlation_id = str(uuid.uuid4())
    
    # Build request payload
    payload = {
        "correlation_id": correlation_id,
        "source_service": SERVICE_NAME,
        "source_revision": SERVICE_REVISION,
        "timestamp": time.time(),
        "data": data.get("data", {})
    }
    
    # Add callback URL if requested
    if request_callback and CALLBACK_BASE_URL:
        payload["callback_url"] = f"{CALLBACK_BASE_URL}/callback"
    
    logger.info(f"Pinging {target_url} with correlation_id={correlation_id}")
    
    try:
        start_time = time.time()
        response = requests.post(
            f"{target_url}/ping",
            json=payload,
            timeout=30
        )
        elapsed = time.time() - start_time
        
        result = {
            "success": True,
            "correlation_id": correlation_id,
            "target": target,
            "target_url": target_url,
            "status_code": response.status_code,
            "elapsed_ms": round(elapsed * 1000, 2),
            "response": response.json() if response.ok else response.text
        }
        
        logger.info(f"Ping successful: {correlation_id} -> {target} in {elapsed*1000:.2f}ms")
        
    except requests.exceptions.RequestException as e:
        logger.error(f"Ping failed: {correlation_id} -> {target}: {e}")
        result = {
            "success": False,
            "correlation_id": correlation_id,
            "target": target,
            "target_url": target_url,
            "error": str(e)
        }
    
    return jsonify(result)

@app.route("/callback", methods=["POST"])
def callback():
    """
    Receive callback from VM after being pinged.
    """
    data = request.get_json() or {}
    correlation_id = data.get("correlation_id", "unknown")
    
    callbacks_received[correlation_id] = {
        "received_at": time.time(),
        "data": data,
        "source_ip": request.remote_addr
    }
    
    logger.info(f"Received callback for correlation_id={correlation_id} from {request.remote_addr}")
    
    return jsonify({
        "status": "callback_received",
        "correlation_id": correlation_id,
        "service": SERVICE_NAME
    })

@app.route("/callbacks", methods=["GET"])
def get_callbacks():
    """Return all callbacks received"""
    return jsonify({
        "service": SERVICE_NAME,
        "callbacks": callbacks_received
    })

@app.route("/test-roundtrip", methods=["POST"])
def test_roundtrip():
    """
    Full roundtrip test: Cloud Run -> VM -> Cloud Run
    
    Request body:
    {
        "target": "a" or "b",
        "wait_for_callback_ms": 5000  # optional, how long to wait for callback
    }
    """
    data = request.get_json() or {}
    target = data.get("target", "a")
    wait_ms = data.get("wait_for_callback_ms", 5000)
    
    # Generate correlation ID
    correlation_id = str(uuid.uuid4())
    
    # Select target URL
    target_url = VM_A_URL if target == "a" else VM_B_URL
    
    # Build request payload with callback
    payload = {
        "correlation_id": correlation_id,
        "source_service": SERVICE_NAME,
        "timestamp": time.time()
    }
    
    if CALLBACK_BASE_URL:
        payload["callback_url"] = f"{CALLBACK_BASE_URL}/callback"
    
    result = {
        "correlation_id": correlation_id,
        "target": target,
        "service": SERVICE_NAME,
        "phases": {}
    }
    
    # Phase 1: Ping VM
    logger.info(f"Roundtrip test: pinging {target_url}")
    phase1_start = time.time()
    try:
        response = requests.post(f"{target_url}/ping", json=payload, timeout=30)
        result["phases"]["ping_vm"] = {
            "success": True,
            "elapsed_ms": round((time.time() - phase1_start) * 1000, 2),
            "status_code": response.status_code,
            "vm_saw_source_ip": response.json().get("source_ip") if response.ok else None
        }
    except Exception as e:
        result["phases"]["ping_vm"] = {
            "success": False,
            "elapsed_ms": round((time.time() - phase1_start) * 1000, 2),
            "error": str(e)
        }
        return jsonify(result)
    
    # Phase 2: Wait for callback (if callback URL was set)
    if CALLBACK_BASE_URL:
        logger.info(f"Waiting for callback (max {wait_ms}ms)")
        phase2_start = time.time()
        deadline = phase2_start + (wait_ms / 1000)
        
        while time.time() < deadline:
            if correlation_id in callbacks_received:
                callback_data = callbacks_received[correlation_id]
                result["phases"]["callback"] = {
                    "success": True,
                    "elapsed_ms": round((callback_data["received_at"] - phase1_start) * 1000, 2),
                    "callback_source_ip": callback_data.get("source_ip"),
                    "callback_data": callback_data["data"]
                }
                break
            time.sleep(0.1)
        else:
            result["phases"]["callback"] = {
                "success": False,
                "elapsed_ms": wait_ms,
                "error": "timeout waiting for callback"
            }
    
    # Calculate total roundtrip
    total_elapsed = time.time() - phase1_start
    result["total_elapsed_ms"] = round(total_elapsed * 1000, 2)
    result["success"] = all(
        phase.get("success", False) 
        for phase in result["phases"].values()
    )
    
    logger.info(f"Roundtrip test complete: {correlation_id} success={result['success']} elapsed={total_elapsed*1000:.2f}ms")
    
    return jsonify(result)

@app.route("/bulk-test", methods=["POST"])
def bulk_test():
    """
    Run multiple ping tests in sequence.
    
    Request body:
    {
        "count": 10,
        "target": "a" or "b" or "both",
        "delay_ms": 100
    }
    """
    data = request.get_json() or {}
    count = data.get("count", 10)
    target = data.get("target", "both")
    delay_ms = data.get("delay_ms", 100)
    
    results = []
    targets = ["a", "b"] if target == "both" else [target]
    
    for i in range(count):
        for t in targets:
            target_url = VM_A_URL if t == "a" else VM_B_URL
            correlation_id = str(uuid.uuid4())
            
            try:
                start = time.time()
                response = requests.post(
                    f"{target_url}/ping",
                    json={"correlation_id": correlation_id, "source_service": SERVICE_NAME},
                    timeout=30
                )
                elapsed = time.time() - start
                
                results.append({
                    "index": i,
                    "target": t,
                    "success": True,
                    "elapsed_ms": round(elapsed * 1000, 2),
                    "source_ip_seen": response.json().get("source_ip") if response.ok else None
                })
            except Exception as e:
                results.append({
                    "index": i,
                    "target": t,
                    "success": False,
                    "error": str(e)
                })
            
            if delay_ms > 0:
                time.sleep(delay_ms / 1000)
    
    # Summary statistics
    successful = [r for r in results if r.get("success")]
    failed = [r for r in results if not r.get("success")]
    
    return jsonify({
        "service": SERVICE_NAME,
        "total_requests": len(results),
        "successful": len(successful),
        "failed": len(failed),
        "avg_latency_ms": round(sum(r["elapsed_ms"] for r in successful) / len(successful), 2) if successful else 0,
        "source_ips_seen": list(set(r.get("source_ip_seen") for r in successful if r.get("source_ip_seen"))),
        "results": results
    })

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
PYTHON

# Build and push image
echo "  Building and pushing container image..."
cd "${SCRIPT_DIR}/../src/cloud-run-service"

gcloud builds submit \
    --project="${PROJECT_ID}" \
    --tag="${SERVICE_IMAGE}" \
    --quiet

echo "  Image built: ${SERVICE_IMAGE}"

#------------------------------------------------------------------------------
# Create Per-Service Subnets
#------------------------------------------------------------------------------
echo ""
echo "[2/3] Creating per-service subnets..."

create_subnet() {
    local idx=$1
    local subnet_name=$(get_subnet_name $idx)
    local subnet_cidr=$(get_service_subnet_cidr $idx)
    
    if ! gcloud compute networks subnets describe "${subnet_name}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Creating ${subnet_name} (${subnet_cidr})..."
        gcloud compute networks subnets create "${subnet_name}" \
            --project="${PROJECT_ID}" \
            --network="${SERVERLESS_VPC}" \
            --region="${REGION}" \
            --range="${subnet_cidr}" \
            --quiet
    fi
}

export -f create_subnet get_subnet_name get_service_subnet_cidr
export PROJECT_ID REGION SERVERLESS_VPC

# Create subnets in parallel
seq ${START_INDEX} ${END_INDEX} | xargs -P ${PARALLEL} -I {} bash -c 'create_subnet {}'

echo "  Subnets created"

#------------------------------------------------------------------------------
# Deploy Cloud Run Services
#------------------------------------------------------------------------------
echo ""
echo "[3/3] Deploying Cloud Run services..."

deploy_service() {
    local idx=$1
    local service_name=$(get_service_name $idx)
    local subnet_name=$(get_subnet_name $idx)
    
    # Get service URL for callback (need to deploy first without callback, then update)
    # For now, we'll set callback URL to empty and update later if needed
    
    echo "  Deploying ${service_name}..."
    
    gcloud run deploy "${service_name}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --image="${SERVICE_IMAGE}" \
        --platform=managed \
        --no-allow-unauthenticated \
        --ingress="${INGRESS_SETTING}" \
        --vpc-egress=all-traffic \
        --network="${SERVERLESS_VPC}" \
        --subnet="${subnet_name}" \
        --min-instances=0 \
        --max-instances="${MAX_INSTANCES_PER_SERVICE}" \
        --concurrency="${CONCURRENCY}" \
        --cpu="${SERVICE_CPU}" \
        --memory="${SERVICE_MEMORY}" \
        --timeout="${REQUEST_TIMEOUT}" \
        --set-env-vars="VM_A_URL=http://${VM_A_IP}:8080,VM_B_URL=http://${VM_B_IP}:8080" \
        --quiet 2>/dev/null
    
    echo "    ${service_name} deployed"
}

export -f deploy_service get_service_name get_subnet_name
export SERVICE_IMAGE MAX_INSTANCES_PER_SERVICE CONCURRENCY SERVICE_CPU SERVICE_MEMORY REQUEST_TIMEOUT
export VM_A_IP VM_B_IP SERVERLESS_VPC

# Deploy services in parallel
seq ${START_INDEX} ${END_INDEX} | xargs -P ${PARALLEL} -I {} bash -c 'deploy_service {}'

#------------------------------------------------------------------------------
# Update Services with Callback URLs
#------------------------------------------------------------------------------
echo ""
echo "Updating services with callback URLs..."

update_callback_url() {
    local idx=$1
    local service_name=$(get_service_name $idx)
    
    # Get the service URL
    local service_url=$(gcloud run services describe "${service_name}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format='value(status.url)' 2>/dev/null)
    
    if [ -n "${service_url}" ]; then
        gcloud run services update "${service_name}" \
            --project="${PROJECT_ID}" \
            --region="${REGION}" \
            --update-env-vars="CALLBACK_BASE_URL=${service_url}" \
            --quiet 2>/dev/null
        echo "  ${service_name}: ${service_url}"
    fi
}

export -f update_callback_url get_service_name

# Update callback URLs
seq ${START_INDEX} ${END_INDEX} | xargs -P ${PARALLEL} -I {} bash -c 'update_callback_url {}'

#------------------------------------------------------------------------------
# Grant IAM permissions for Cloud Run access
#------------------------------------------------------------------------------
echo ""
echo "Configuring IAM permissions..."

# Get the default compute service account (for VM -> Cloud Run callbacks)
COMPUTE_SA=$(gcloud iam service-accounts list \
    --project="${PROJECT_ID}" \
    --filter="email:compute@developer.gserviceaccount.com" \
    --format="value(email)" 2>/dev/null | head -1)

if [ -n "${COMPUTE_SA}" ]; then
    echo "  Granting Cloud Run Invoker to compute service account..."
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${COMPUTE_SA}" \
        --role="roles/run.invoker" \
        --quiet 2>/dev/null || true
fi

# Grant Cloud Run Invoker to the current user (for running tests)
CURRENT_USER=$(gcloud config get-value account 2>/dev/null)
if [ -n "${CURRENT_USER}" ]; then
    echo "  Granting Cloud Run Invoker to current user (${CURRENT_USER})..."
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${CURRENT_USER}" \
        --role="roles/run.invoker" \
        --quiet 2>/dev/null || true
fi

echo "  IAM permissions configured"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Service Deployment Complete!"
echo "=============================================="
echo ""
echo "Deployed ${COUNT} Cloud Run services (${START_INDEX} to ${END_INDEX})"
echo ""
echo "Each service has:"
echo "  - Dedicated subnet from Class E range (240.0.x.0/24)"
echo "  - VPC egress through Private NAT"
echo "  - Ingress: ${INGRESS_SETTING}"
echo ""
echo "IAM Permissions granted:"
echo "  - Cloud Run Invoker for current user (for testing)"
echo "  - Cloud Run Invoker for compute service account (for VM callbacks)"
echo ""
echo "Service URLs:"
for i in $(seq ${START_INDEX} $((START_INDEX + 2))); do
    if [ $i -le ${END_INDEX} ]; then
        service_name=$(get_service_name $i)
        url=$(gcloud run services describe "${service_name}" \
            --project="${PROJECT_ID}" \
            --region="${REGION}" \
            --format='value(status.url)' 2>/dev/null)
        echo "  ${service_name}: ${url}"
    fi
done
if [ ${COUNT} -gt 3 ]; then
    echo "  ... and $((COUNT - 3)) more"
fi
echo ""
echo "=============================================="
echo "Next step: ./scripts/03-run-tests.sh --test debug"
echo "=============================================="
