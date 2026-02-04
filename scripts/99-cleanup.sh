#!/bin/bash
#==============================================================================
# 99-cleanup.sh
# Delete all resources created by the NAT testing framework
#==============================================================================

# Don't exit on error - we want to clean up as much as possible
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Parse arguments
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--yes|-y]"
            exit 1
            ;;
    esac
done

echo "=============================================="
echo "Cloud Run NAT Testing - Cleanup"
echo "=============================================="
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo "=============================================="

# Confirm deletion
if [ "${SKIP_CONFIRM}" != "true" ]; then
    echo ""
    echo "WARNING: This will delete ALL resources created by this testing framework:"
    echo "  - All Cloud Run services (nat-test-svc-*)"
    echo "  - All Cloud Run subnets (cr-subnet-*)"
    echo "  - NAT gateway and router"
    echo "  - Target VMs (target-vm-a, target-vm-b)"
    echo "  - VPC peerings"
    echo "  - Firewall rules"
    echo "  - VPCs (serverless-vpc, workload-vpc-a, workload-vpc-b)"
    echo "  - NAT IP addresses"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm

    if [ "${confirm}" != "yes" ]; then
        echo "Cleanup cancelled."
        exit 0
    fi
fi

gcloud config set project "${PROJECT_ID}"

#------------------------------------------------------------------------------
# Delete Cloud Run Services
#------------------------------------------------------------------------------
echo ""
echo "[1/8] Deleting Cloud Run services..."

# List and delete all nat-test-svc-* services
services=$(gcloud run services list \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --filter="metadata.name:nat-test-svc-" \
    --format="value(metadata.name)" 2>/dev/null)

if [ -n "${services}" ]; then
    echo "${services}" | while read svc; do
        echo "  Deleting ${svc}..."
        gcloud run services delete "${svc}" \
            --project="${PROJECT_ID}" \
            --region="${REGION}" \
            --quiet 2>/dev/null || true
    done
else
    echo "  No Cloud Run services found"
fi

#------------------------------------------------------------------------------
# Delete VMs
#------------------------------------------------------------------------------
echo ""
echo "[2/8] Deleting target VMs..."

for vm in "target-vm-a" "target-vm-b"; do
    if gcloud compute instances describe "${vm}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Deleting ${vm}..."
        gcloud compute instances delete "${vm}" \
            --zone="${ZONE}" \
            --project="${PROJECT_ID}" \
            --quiet
    else
        echo "  ${vm} not found"
    fi
done

#------------------------------------------------------------------------------
# Delete NAT and Router
#------------------------------------------------------------------------------
echo ""
echo "[3/8] Deleting NAT gateway and router..."

# Delete NAT
if gcloud compute routers nats describe "private-nat" --router="nat-router" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
    echo "  Deleting private-nat..."
    gcloud compute routers nats delete "private-nat" \
        --router="nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
else
    echo "  private-nat not found"
fi

# Delete router
if gcloud compute routers describe "nat-router" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
    echo "  Deleting nat-router..."
    gcloud compute routers delete "nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
else
    echo "  nat-router not found"
fi

#------------------------------------------------------------------------------
# Delete NAT IPs
#------------------------------------------------------------------------------
echo ""
echo "[4/8] Deleting NAT IP addresses..."

for i in $(seq 1 20); do
    ip_name="nat-ip-${i}"
    if gcloud compute addresses describe "${ip_name}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Deleting ${ip_name}..."
        gcloud compute addresses delete "${ip_name}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --quiet
    fi
done

#------------------------------------------------------------------------------
# Delete VPC Peerings
#------------------------------------------------------------------------------
echo ""
echo "[5/8] Deleting VPC peerings..."

peerings=(
    "serverless-to-workload-a:${SERVERLESS_VPC}"
    "workload-a-to-serverless:${WORKLOAD_VPC_A}"
    "serverless-to-workload-b:${SERVERLESS_VPC}"
    "workload-b-to-serverless:${WORKLOAD_VPC_B}"
)

for peering_info in "${peerings[@]}"; do
    IFS=':' read -r peering_name network <<< "${peering_info}"
    if gcloud compute networks peerings describe "${peering_name}" --network="${network}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Deleting ${peering_name}..."
        gcloud compute networks peerings delete "${peering_name}" \
            --network="${network}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
    fi
done

#------------------------------------------------------------------------------
# Delete Firewall Rules
#------------------------------------------------------------------------------
echo ""
echo "[6/8] Deleting firewall rules..."

firewall_rules=(
    "allow-nat-ingress-${WORKLOAD_VPC_A}"
    "allow-nat-ingress-${WORKLOAD_VPC_B}"
    "allow-iap-ssh-${WORKLOAD_VPC_A}"
    "allow-iap-ssh-${WORKLOAD_VPC_B}"
    "allow-egress-${WORKLOAD_VPC_A}"
    "allow-egress-${WORKLOAD_VPC_B}"
)

for rule in "${firewall_rules[@]}"; do
    if gcloud compute firewall-rules describe "${rule}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Deleting ${rule}..."
        gcloud compute firewall-rules delete "${rule}" \
            --project="${PROJECT_ID}" \
            --quiet
    fi
done

#------------------------------------------------------------------------------
# Delete Subnets
#------------------------------------------------------------------------------
echo ""
echo "[7/8] Deleting subnets..."

# Delete Cloud Run subnets (cr-subnet-*)
cr_subnets=$(gcloud compute networks subnets list \
    --project="${PROJECT_ID}" \
    --regions="${REGION}" \
    --filter="name:cr-subnet-" \
    --format="value(name)" 2>/dev/null)

if [ -n "${cr_subnets}" ]; then
    echo "${cr_subnets}" | while read subnet; do
        echo "  Deleting ${subnet}..."
        gcloud compute networks subnets delete "${subnet}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
    done
else
    echo "  No Cloud Run subnets found"
fi

# Delete other subnets
other_subnets=(
    "nat-pool-subnet"
    "workload-a-subnet"
    "workload-b-subnet"
)

for subnet in "${other_subnets[@]}"; do
    if gcloud compute networks subnets describe "${subnet}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Deleting ${subnet}..."
        gcloud compute networks subnets delete "${subnet}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --quiet
    fi
done

#------------------------------------------------------------------------------
# Delete VPCs
#------------------------------------------------------------------------------
echo ""
echo "[8/8] Deleting VPCs..."

for vpc in "${SERVERLESS_VPC}" "${WORKLOAD_VPC_A}" "${WORKLOAD_VPC_B}"; do
    if gcloud compute networks describe "${vpc}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Deleting ${vpc}..."
        gcloud compute networks delete "${vpc}" \
            --project="${PROJECT_ID}" \
            --quiet
    else
        echo "  ${vpc} not found"
    fi
done

#------------------------------------------------------------------------------
# Delete Container Images (optional)
#------------------------------------------------------------------------------
echo ""
echo "Optional: Delete container images"
echo "  Run manually if desired:"
echo "  gcloud container images delete gcr.io/${PROJECT_ID}/nat-test-service --force-delete-tags --quiet"

#------------------------------------------------------------------------------
# Clean up local temp files
#------------------------------------------------------------------------------
echo ""
echo "Cleaning up local temp files..."
rm -f /tmp/nat-test-*.json 2>/dev/null || true

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Cleanup Complete!"
echo "=============================================="
echo ""
echo "All NAT testing resources have been deleted."
echo ""
echo "Note: Some resources may take a few minutes to fully delete."
echo "If you encounter 'resource in use' errors, wait and retry."
