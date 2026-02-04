#!/bin/bash
#==============================================================================
# 01-setup-infrastructure.sh
# Creates VPCs, subnets, NAT, peering, firewall rules, and target VMs
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "=============================================="
echo "Cloud Run NAT Testing - Infrastructure Setup"
echo "=============================================="
echo "Project:  ${PROJECT_ID}"
echo "Region:   ${REGION}"
echo "NAT Mode: ${NAT_MODE}"
echo "=============================================="

# Confirm project
gcloud config set project "${PROJECT_ID}"

#------------------------------------------------------------------------------
# Enable Required APIs
#------------------------------------------------------------------------------
echo ""
echo "[1/9] Enabling required APIs..."
gcloud services enable \
    compute.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    containerregistry.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    --quiet

#------------------------------------------------------------------------------
# Create VPCs
#------------------------------------------------------------------------------
echo ""
echo "[2/9] Creating VPCs..."

# Serverless VPC (for Cloud Run)
if ! gcloud compute networks describe "${SERVERLESS_VPC}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating ${SERVERLESS_VPC}..."
    gcloud compute networks create "${SERVERLESS_VPC}" \
        --project="${PROJECT_ID}" \
        --subnet-mode=custom \
        --bgp-routing-mode=regional
else
    echo "  ${SERVERLESS_VPC} already exists"
fi

# Workload VPC A
if ! gcloud compute networks describe "${WORKLOAD_VPC_A}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating ${WORKLOAD_VPC_A}..."
    gcloud compute networks create "${WORKLOAD_VPC_A}" \
        --project="${PROJECT_ID}" \
        --subnet-mode=custom \
        --bgp-routing-mode=regional
else
    echo "  ${WORKLOAD_VPC_A} already exists"
fi

# Workload VPC B
if ! gcloud compute networks describe "${WORKLOAD_VPC_B}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating ${WORKLOAD_VPC_B}..."
    gcloud compute networks create "${WORKLOAD_VPC_B}" \
        --project="${PROJECT_ID}" \
        --subnet-mode=custom \
        --bgp-routing-mode=regional
else
    echo "  ${WORKLOAD_VPC_B} already exists"
fi

#------------------------------------------------------------------------------
# Create Subnets
#------------------------------------------------------------------------------
echo ""
echo "[3/9] Creating subnets..."

# NAT pool subnet (for Private NAT - routable range)
if ! gcloud compute networks subnets describe "nat-pool-subnet" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating nat-pool-subnet (${NAT_POOL_CIDR})..."
    gcloud compute networks subnets create "nat-pool-subnet" \
        --project="${PROJECT_ID}" \
        --network="${SERVERLESS_VPC}" \
        --region="${REGION}" \
        --range="${NAT_POOL_CIDR}" \
        --purpose=PRIVATE_NAT
else
    echo "  nat-pool-subnet already exists"
fi

# Workload A subnet (with Private Google Access)
if ! gcloud compute networks subnets describe "workload-a-subnet" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating workload-a-subnet (${WORKLOAD_A_SUBNET_CIDR})..."
    gcloud compute networks subnets create "workload-a-subnet" \
        --project="${PROJECT_ID}" \
        --network="${WORKLOAD_VPC_A}" \
        --region="${REGION}" \
        --range="${WORKLOAD_A_SUBNET_CIDR}" \
        --enable-private-ip-google-access
else
    echo "  workload-a-subnet already exists"
fi

# Workload B subnet (with Private Google Access)
if ! gcloud compute networks subnets describe "workload-b-subnet" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating workload-b-subnet (${WORKLOAD_B_SUBNET_CIDR})..."
    gcloud compute networks subnets create "workload-b-subnet" \
        --project="${PROJECT_ID}" \
        --network="${WORKLOAD_VPC_B}" \
        --region="${REGION}" \
        --range="${WORKLOAD_B_SUBNET_CIDR}" \
        --enable-private-ip-google-access
else
    echo "  workload-b-subnet already exists"
fi

#------------------------------------------------------------------------------
# Create VPC Peering
#------------------------------------------------------------------------------
echo ""
echo "[4/9] Creating VPC peering..."

# Serverless VPC <-> Workload VPC A
if ! gcloud compute networks peerings describe "serverless-to-workload-a" --network="${SERVERLESS_VPC}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating peering: ${SERVERLESS_VPC} -> ${WORKLOAD_VPC_A}..."
    gcloud compute networks peerings create "serverless-to-workload-a" \
        --project="${PROJECT_ID}" \
        --network="${SERVERLESS_VPC}" \
        --peer-network="${WORKLOAD_VPC_A}" \
        --export-custom-routes \
        --import-custom-routes
else
    echo "  serverless-to-workload-a peering already exists"
fi

if ! gcloud compute networks peerings describe "workload-a-to-serverless" --network="${WORKLOAD_VPC_A}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating peering: ${WORKLOAD_VPC_A} -> ${SERVERLESS_VPC}..."
    gcloud compute networks peerings create "workload-a-to-serverless" \
        --project="${PROJECT_ID}" \
        --network="${WORKLOAD_VPC_A}" \
        --peer-network="${SERVERLESS_VPC}" \
        --export-custom-routes \
        --import-custom-routes
else
    echo "  workload-a-to-serverless peering already exists"
fi

# Serverless VPC <-> Workload VPC B
if ! gcloud compute networks peerings describe "serverless-to-workload-b" --network="${SERVERLESS_VPC}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating peering: ${SERVERLESS_VPC} -> ${WORKLOAD_VPC_B}..."
    gcloud compute networks peerings create "serverless-to-workload-b" \
        --project="${PROJECT_ID}" \
        --network="${SERVERLESS_VPC}" \
        --peer-network="${WORKLOAD_VPC_B}" \
        --export-custom-routes \
        --import-custom-routes
else
    echo "  serverless-to-workload-b peering already exists"
fi

if ! gcloud compute networks peerings describe "workload-b-to-serverless" --network="${WORKLOAD_VPC_B}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating peering: ${WORKLOAD_VPC_B} -> ${SERVERLESS_VPC}..."
    gcloud compute networks peerings create "workload-b-to-serverless" \
        --project="${PROJECT_ID}" \
        --network="${WORKLOAD_VPC_B}" \
        --peer-network="${SERVERLESS_VPC}" \
        --export-custom-routes \
        --import-custom-routes
else
    echo "  workload-b-to-serverless peering already exists"
fi

#------------------------------------------------------------------------------
# Create Cloud Router
#------------------------------------------------------------------------------
echo ""
echo "[5/9] Creating Cloud Router..."

if ! gcloud compute routers describe "nat-router" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating nat-router..."
    gcloud compute routers create "nat-router" \
        --project="${PROJECT_ID}" \
        --network="${SERVERLESS_VPC}" \
        --region="${REGION}"
else
    echo "  nat-router already exists"
fi

#------------------------------------------------------------------------------
# Allocate NAT IPs
#------------------------------------------------------------------------------
echo ""
echo "[6/9] Allocating NAT IPs..."

for i in $(seq 1 ${NAT_IP_COUNT}); do
    NAT_IP_NAME="nat-ip-${i}"
    if ! gcloud compute addresses describe "${NAT_IP_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Allocating ${NAT_IP_NAME}..."
        gcloud compute addresses create "${NAT_IP_NAME}" \
            --project="${PROJECT_ID}" \
            --region="${REGION}"
    else
        echo "  ${NAT_IP_NAME} already exists"
    fi
done

# Build list of NAT IP names
NAT_IP_LIST=""
for i in $(seq 1 ${NAT_IP_COUNT}); do
    if [ -n "${NAT_IP_LIST}" ]; then
        NAT_IP_LIST="${NAT_IP_LIST},"
    fi
    NAT_IP_LIST="${NAT_IP_LIST}nat-ip-${i}"
done

#------------------------------------------------------------------------------
# Create Private NAT Gateway
#------------------------------------------------------------------------------
echo ""
echo "[7/9] Creating Private NAT Gateway..."

# Delete existing NAT if present (to reconfigure)
if gcloud compute routers nats describe "private-nat" --router="nat-router" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Deleting existing private-nat for reconfiguration..."
    gcloud compute routers nats delete "private-nat" \
        --router="nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
fi

echo "  Creating Private NAT (mode: ${NAT_MODE})..."

# Note: Private NAT uses internal IP ranges instead of external IPs
# The NAT pool subnet (10.255.0.0/16 with purpose=PRIVATE_NAT) provides the translated addresses
# The --nat-all-subnet-ip-ranges flag specifies which SOURCE subnets to NAT
# The NAT pool is automatically selected from subnets with purpose=PRIVATE_NAT

# IMPORTANT: endpoint-types must include ENDPOINT_TYPE_MANAGED_PROXY_LB for Cloud Run Direct VPC Egress
gcloud compute routers nats create "private-nat" \
    --router="nat-router" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --type=PRIVATE \
    --nat-all-subnet-ip-ranges \
    --endpoint-types=ENDPOINT_TYPE_VM,ENDPOINT_TYPE_MANAGED_PROXY_LB \
    --min-ports-per-vm="${NAT_MIN_PORTS_PER_VM}" \
    --enable-logging

echo "  Private NAT created successfully"

# Display NAT configuration
echo ""
echo "  NAT Configuration Summary:"
gcloud compute routers nats describe "private-nat" \
    --router="nat-router" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="yaml(name,type,sourceSubnetworkIpRangesToNat,minPortsPerVm,enableEndpointIndependentMapping)"

#------------------------------------------------------------------------------
# Create Firewall Rules
#------------------------------------------------------------------------------
echo ""
echo "[8/9] Creating firewall rules..."

# Allow ingress from NAT pool to workload VPCs
for VPC in "${WORKLOAD_VPC_A}" "${WORKLOAD_VPC_B}"; do
    RULE_NAME="allow-nat-ingress-${VPC}"
    if ! gcloud compute firewall-rules describe "${RULE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Creating ${RULE_NAME}..."
        gcloud compute firewall-rules create "${RULE_NAME}" \
            --project="${PROJECT_ID}" \
            --network="${VPC}" \
            --direction=INGRESS \
            --priority=1000 \
            --action=ALLOW \
            --rules=tcp:8080,icmp \
            --source-ranges="${NAT_POOL_CIDR}" \
            --target-tags="nat-target"
    else
        echo "  ${RULE_NAME} already exists"
    fi
done

# Allow SSH via IAP for debugging
for VPC in "${WORKLOAD_VPC_A}" "${WORKLOAD_VPC_B}"; do
    RULE_NAME="allow-iap-ssh-${VPC}"
    if ! gcloud compute firewall-rules describe "${RULE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Creating ${RULE_NAME}..."
        gcloud compute firewall-rules create "${RULE_NAME}" \
            --project="${PROJECT_ID}" \
            --network="${VPC}" \
            --direction=INGRESS \
            --priority=1000 \
            --action=ALLOW \
            --rules=tcp:22 \
            --source-ranges="35.235.240.0/20" \
            --target-tags="nat-target"
    else
        echo "  ${RULE_NAME} already exists"
    fi
done

# Allow egress from workload VPCs (for Private Google Access to Cloud Run)
for VPC in "${WORKLOAD_VPC_A}" "${WORKLOAD_VPC_B}"; do
    RULE_NAME="allow-egress-${VPC}"
    if ! gcloud compute firewall-rules describe "${RULE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Creating ${RULE_NAME}..."
        gcloud compute firewall-rules create "${RULE_NAME}" \
            --project="${PROJECT_ID}" \
            --network="${VPC}" \
            --direction=EGRESS \
            --priority=1000 \
            --action=ALLOW \
            --rules=all \
            --destination-ranges="0.0.0.0/0"
    else
        echo "  ${RULE_NAME} already exists"
    fi
done

#------------------------------------------------------------------------------
# Create Target VMs
#------------------------------------------------------------------------------
echo ""
echo "[9/9] Creating target VMs..."

# Create startup script file (avoids shell escaping issues with --metadata)
STARTUP_SCRIPT_FILE=$(mktemp)
cat > "${STARTUP_SCRIPT_FILE}" << 'STARTUP_EOF'
#!/bin/bash
set -e

# Log startup
exec > >(tee /var/log/startup-script.log) 2>&1
echo "Starting VM setup at $(date)"

# Wait for network to be ready
echo "Waiting for network..."
for i in {1..30}; do
    if curl -s --connect-timeout 5 https://www.google.com > /dev/null 2>&1; then
        echo "Network is ready"
        break
    fi
    echo "Waiting for network... attempt $i/30"
    sleep 10
done

# Update and install packages with retries
echo "Installing packages..."
for i in {1..3}; do
    apt-get update && break
    echo "apt-get update failed, retry $i/3"
    sleep 10
done

for i in {1..3}; do
    apt-get install -y python3 python3-pip && break
    echo "apt-get install failed, retry $i/3"
    sleep 10
done

# Install Python packages (--break-system-packages for PEP 668 compliance on newer Debian)
echo "Installing Python packages..."
for i in {1..3}; do
    pip3 install --break-system-packages flask requests && break
    echo "pip3 install failed, retry $i/3"
    sleep 10
done

# Create the target server application
echo "Creating target server..."
cat > /opt/target-server.py << 'PYEOF'
from flask import Flask, request, jsonify
import requests
import logging
import os
import time

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

VM_ID = os.environ.get("VM_ID", "unknown")

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy", "vm_id": VM_ID})

@app.route("/ping", methods=["POST"])
def ping():
    """Receive ping from Cloud Run, optionally call back"""
    source_ip = request.remote_addr
    data = request.get_json() or {}
    
    response = {
        "vm_id": VM_ID,
        "source_ip": source_ip,
        "timestamp": time.time(),
        "received_data": data
    }
    
    app.logger.info(f"Received ping from {source_ip}: {data}")
    
    # If callback URL provided, call back to Cloud Run
    callback_url = data.get("callback_url")
    if callback_url:
        try:
            app.logger.info(f"Calling back to {callback_url}")
            callback_response = requests.post(
                callback_url,
                json={
                    "vm_id": VM_ID,
                    "original_source_ip": source_ip,
                    "correlation_id": data.get("correlation_id"),
                    "timestamp": time.time()
                },
                timeout=30
            )
            response["callback_status"] = callback_response.status_code
            response["callback_response"] = callback_response.json() if callback_response.ok else callback_response.text
        except Exception as e:
            app.logger.error(f"Callback failed: {e}")
            response["callback_error"] = str(e)
    
    return jsonify(response)

@app.route("/echo", methods=["GET", "POST"])
def echo():
    """Simple echo endpoint"""
    return jsonify({
        "vm_id": VM_ID,
        "source_ip": request.remote_addr,
        "method": request.method,
        "headers": dict(request.headers),
        "args": dict(request.args),
        "timestamp": time.time()
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
PYEOF

# Create systemd service
cat > /etc/systemd/system/target-server.service << 'SVCEOF'
[Unit]
Description=NAT Test Target Server
After=network.target

[Service]
Type=simple
Environment=VM_ID=%H
ExecStart=/usr/bin/python3 /opt/target-server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable target-server
systemctl start target-server

echo "VM setup completed at $(date)"
echo "SUCCESS" > /var/log/startup-complete
STARTUP_EOF

# VM A (with ephemeral external IP for package installation during startup)
# Note: External IP is required for startup script to download packages from PyPI
if ! gcloud compute instances describe "target-vm-a" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating target-vm-a (with external IP for package installation)..."
    gcloud compute instances create "target-vm-a" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --machine-type="${VM_MACHINE_TYPE}" \
        --network-interface="network=${WORKLOAD_VPC_A},subnet=workload-a-subnet,private-network-ip=${VM_A_IP},network-tier=STANDARD" \
        --image-family="${VM_IMAGE_FAMILY}" \
        --image-project="${VM_IMAGE_PROJECT}" \
        --tags="nat-target" \
        --scopes="cloud-platform" \
        --metadata-from-file="startup-script=${STARTUP_SCRIPT_FILE}"
else
    echo "  target-vm-a already exists"
    # Ensure VM has external IP for package installation
    if ! gcloud compute instances describe "target-vm-a" --zone="${ZONE}" --project="${PROJECT_ID}" \
        --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null | grep -q '.'; then
        echo "  Adding external IP to target-vm-a..."
        gcloud compute instances add-access-config "target-vm-a" \
            --zone="${ZONE}" \
            --project="${PROJECT_ID}" \
            --access-config-name="External NAT" 2>/dev/null || true
    fi
fi

# VM B (with ephemeral external IP for package installation during startup)
if ! gcloud compute instances describe "target-vm-b" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Creating target-vm-b (with external IP for package installation)..."
    gcloud compute instances create "target-vm-b" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --machine-type="${VM_MACHINE_TYPE}" \
        --network-interface="network=${WORKLOAD_VPC_B},subnet=workload-b-subnet,private-network-ip=${VM_B_IP},network-tier=STANDARD" \
        --image-family="${VM_IMAGE_FAMILY}" \
        --image-project="${VM_IMAGE_PROJECT}" \
        --tags="nat-target" \
        --scopes="cloud-platform" \
        --metadata-from-file="startup-script=${STARTUP_SCRIPT_FILE}"
else
    echo "  target-vm-b already exists"
    # Ensure VM has external IP for package installation
    if ! gcloud compute instances describe "target-vm-b" --zone="${ZONE}" --project="${PROJECT_ID}" \
        --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null | grep -q '.'; then
        echo "  Adding external IP to target-vm-b..."
        gcloud compute instances add-access-config "target-vm-b" \
            --zone="${ZONE}" \
            --project="${PROJECT_ID}" \
            --access-config-name="External NAT" 2>/dev/null || true
    fi
fi

# Clean up temp file
rm -f "${STARTUP_SCRIPT_FILE}"

# Wait for VMs to be ready
echo ""
echo "  Waiting for VMs to complete startup (this may take 2-3 minutes)..."
echo "  Checking VM health..."

for vm in "target-vm-a" "target-vm-b"; do
    echo "  Waiting for ${vm}..."
    for i in {1..36}; do  # Wait up to 3 minutes
        # Check if the target-server is responding
        health=$(gcloud compute ssh "${vm}" --zone="${ZONE}" --tunnel-through-iap \
            --command="curl -s localhost:8080/health 2>/dev/null || echo 'not ready'" 2>/dev/null || echo "ssh failed")
        
        if echo "${health}" | grep -q '"status": "healthy"'; then
            echo "    ${vm} is ready!"
            break
        fi
        
        if [ $i -eq 36 ]; then
            echo "    WARNING: ${vm} may not be ready. Check logs with:"
            echo "      gcloud compute ssh ${vm} --zone=${ZONE} --tunnel-through-iap --command='sudo journalctl -u target-server -n 20'"
        fi
        
        sleep 5
    done
done

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Infrastructure Setup Complete!"
echo "=============================================="
echo ""
echo "VPCs created:"
echo "  - ${SERVERLESS_VPC} (240.0.0.0/12 Class E for Cloud Run)"
echo "  - ${WORKLOAD_VPC_A} (10.1.0.0/16)"
echo "  - ${WORKLOAD_VPC_B} (10.2.0.0/16)"
echo ""
echo "Private NAT:"
echo "  - NAT Pool: ${NAT_POOL_CIDR}"
echo "  - Translates: 240.x.x.x -> 10.255.x.x"
echo ""
echo "Target VMs:"
echo "  - target-vm-a: ${VM_A_IP}:8080 (in workload-vpc-a)"
echo "  - target-vm-b: ${VM_B_IP}:8080 (in workload-vpc-b)"
echo ""
echo "VPC Peering: serverless-vpc <-> workload-vpc-a, workload-vpc-b"
echo ""
echo "=============================================="
echo "Next step: ./scripts/02-deploy-services.sh --count 10"
echo "=============================================="
