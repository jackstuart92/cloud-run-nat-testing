#!/bin/bash
#==============================================================================
# configure-nat-rules.sh
# Configure NAT rules for per-service or per-destination NAT mapping
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "=============================================="
echo "Cloud Run NAT - Rule Configuration"
echo "=============================================="
echo "Project:  ${PROJECT_ID}"
echo "Region:   ${REGION}"
echo "NAT Mode: ${NAT_MODE}"
echo "=============================================="

gcloud config set project "${PROJECT_ID}"

show_help() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  show              Show current NAT configuration
  per-destination   Configure NAT rules per destination VPC
  per-service       Configure NAT rules per service subnet (requires more IPs)
  shared            Reset to shared NAT pool (all services use same IPs)
  add-rule          Add a custom NAT rule

Options:
  --nat-ips N       Number of NAT IPs to allocate (default: ${NAT_IP_COUNT})

Examples:
  $0 show
  $0 per-destination
  $0 per-service --nat-ips 10
  $0 add-rule --match "10.1.0.0/16" --nat-ip nat-ip-1

EOF
}

#------------------------------------------------------------------------------
# Show Current Configuration
#------------------------------------------------------------------------------
show_config() {
    echo ""
    echo "Current NAT Configuration:"
    echo "=========================="
    
    gcloud compute routers nats describe "private-nat" \
        --router="nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="yaml" 2>/dev/null || echo "NAT not configured"
    
    echo ""
    echo "NAT Rules:"
    echo "=========="
    gcloud compute routers nats rules list \
        --router="nat-router" \
        --nat="private-nat" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="table(ruleNumber,match,action.sourceNatActiveIps)" 2>/dev/null || echo "No rules configured"
    
    echo ""
    echo "Allocated NAT IPs:"
    echo "=================="
    gcloud compute addresses list \
        --project="${PROJECT_ID}" \
        --regions="${REGION}" \
        --filter="name:nat-ip-" \
        --format="table(name,address,status)"
}

#------------------------------------------------------------------------------
# Configure Per-Destination NAT
#------------------------------------------------------------------------------
configure_per_destination() {
    echo ""
    echo "Configuring Per-Destination NAT Rules..."
    echo "========================================"
    echo ""
    echo "This will create rules so:"
    echo "  - Traffic to Workload VPC A (${WORKLOAD_A_CIDR}) uses NAT IP 1"
    echo "  - Traffic to Workload VPC B (${WORKLOAD_B_CIDR}) uses NAT IP 2"
    echo ""
    
    # Ensure we have at least 2 NAT IPs
    if [ ${NAT_IP_COUNT} -lt 2 ]; then
        NAT_IP_COUNT=2
    fi
    
    # Allocate NAT IPs if needed
    for i in $(seq 1 ${NAT_IP_COUNT}); do
        NAT_IP_NAME="nat-ip-${i}"
        if ! gcloud compute addresses describe "${NAT_IP_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
            echo "Allocating ${NAT_IP_NAME}..."
            gcloud compute addresses create "${NAT_IP_NAME}" \
                --project="${PROJECT_ID}" \
                --region="${REGION}"
        fi
    done
    
    # Get NAT IP self-links
    NAT_IP_1=$(gcloud compute addresses describe "nat-ip-1" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(selfLink)")
    
    NAT_IP_2=$(gcloud compute addresses describe "nat-ip-2" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(selfLink)")
    
    # Delete existing rules
    echo "Clearing existing NAT rules..."
    for rule_num in $(gcloud compute routers nats rules list \
        --router="nat-router" \
        --nat="private-nat" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(ruleNumber)" 2>/dev/null); do
        gcloud compute routers nats rules delete "${rule_num}" \
            --router="nat-router" \
            --nat="private-nat" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
    done
    
    # Create rule for Workload VPC A
    echo "Creating rule for Workload VPC A..."
    gcloud compute routers nats rules create 100 \
        --router="nat-router" \
        --nat="private-nat" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --match="inIpRange(destination.ip, '${WORKLOAD_A_CIDR}')" \
        --source-nat-active-ips="${NAT_IP_1}"
    
    # Create rule for Workload VPC B
    echo "Creating rule for Workload VPC B..."
    gcloud compute routers nats rules create 200 \
        --router="nat-router" \
        --nat="private-nat" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --match="inIpRange(destination.ip, '${WORKLOAD_B_CIDR}')" \
        --source-nat-active-ips="${NAT_IP_2}"
    
    echo ""
    echo "Per-destination NAT rules configured!"
    echo ""
    echo "Traffic routing:"
    NAT_IP_1_ADDR=$(gcloud compute addresses describe "nat-ip-1" --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)")
    NAT_IP_2_ADDR=$(gcloud compute addresses describe "nat-ip-2" --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)")
    echo "  → ${WORKLOAD_A_CIDR} via NAT IP: ${NAT_IP_1_ADDR}"
    echo "  → ${WORKLOAD_B_CIDR} via NAT IP: ${NAT_IP_2_ADDR}"
}

#------------------------------------------------------------------------------
# Configure Per-Service NAT (Advanced)
#------------------------------------------------------------------------------
configure_per_service() {
    echo ""
    echo "Configuring Per-Service NAT Rules..."
    echo "====================================="
    echo ""
    echo "WARNING: This requires 1 NAT IP per service subnet."
    echo "For ${NUM_SERVICES} services, you need ${NUM_SERVICES} NAT IPs."
    echo ""
    
    read -p "Continue? (yes/no): " confirm
    if [ "${confirm}" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
    
    # This is complex - each Cloud Run service subnet needs its own NAT rule
    # We'll create a rule that matches source subnet and assigns specific NAT IP
    
    # Note: Cloud NAT rules match on DESTINATION, not source
    # For per-service source NAT, we need to use subnet-level NAT IP assignment
    # This is done via the NAT configuration, not rules
    
    echo ""
    echo "Per-service NAT requires subnet-level configuration."
    echo "Updating NAT to use specific subnets with assigned IPs..."
    
    # For each service, allocate a NAT IP and configure the subnet mapping
    # This is done through the NAT's subnetwork configuration
    
    # First, allocate NAT IPs for each service
    for i in $(seq 1 ${NUM_SERVICES}); do
        NAT_IP_NAME="nat-ip-svc-${i}"
        if ! gcloud compute addresses describe "${NAT_IP_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
            echo "  Allocating ${NAT_IP_NAME}..."
            gcloud compute addresses create "${NAT_IP_NAME}" \
                --project="${PROJECT_ID}" \
                --region="${REGION}"
        fi
    done
    
    echo ""
    echo "NAT IPs allocated. Building subnet-to-NAT-IP mapping..."
    
    # Build the complex NAT configuration with per-subnet NAT IP assignment
    # This requires recreating the NAT with specific subnet configurations
    
    # Delete existing NAT
    echo "Recreating NAT with per-service configuration..."
    gcloud compute routers nats delete "private-nat" \
        --router="nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet 2>/dev/null || true
    
    # Build subnet list with NAT IP assignments
    # Note: This is a simplified version - full per-service would need
    # individual NAT IP assignment per subnet which isn't directly supported
    # We use NAT rules based on the destination instead
    
    # Recreate NAT with custom subnet configuration
    SUBNET_LIST=""
    for i in $(seq 1 ${NUM_SERVICES}); do
        subnet_name=$(get_subnet_name $i)
        if [ -n "${SUBNET_LIST}" ]; then
            SUBNET_LIST="${SUBNET_LIST},"
        fi
        SUBNET_LIST="${SUBNET_LIST}${subnet_name}"
    done
    
    gcloud compute routers nats create "private-nat" \
        --router="nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --type=PRIVATE \
        --nat-custom-subnet-ip-ranges="${SUBNET_LIST}" \
        --min-ports-per-vm="${NAT_MIN_PORTS_PER_VM}" \
        --enable-logging
    
    echo ""
    echo "Per-service NAT configuration applied."
    echo ""
    echo "Note: True per-service NAT IP assignment requires advanced configuration."
    echo "The current setup uses per-subnet NAT with shared pool."
    echo "For tracking, rely on subnet IP → service mapping in logs."
}

#------------------------------------------------------------------------------
# Reset to Shared NAT
#------------------------------------------------------------------------------
configure_shared() {
    echo ""
    echo "Resetting to Shared NAT Pool..."
    echo "==============================="
    
    # Delete existing rules
    echo "Clearing NAT rules..."
    for rule_num in $(gcloud compute routers nats rules list \
        --router="nat-router" \
        --nat="private-nat" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(ruleNumber)" 2>/dev/null); do
        gcloud compute routers nats rules delete "${rule_num}" \
            --router="nat-router" \
            --nat="private-nat" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
    done
    
    # Update NAT to use all subnets with auto IP allocation
    echo "Updating NAT configuration..."
    gcloud compute routers nats update "private-nat" \
        --router="nat-router" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --nat-all-subnet-ip-ranges 2>/dev/null || true
    
    echo ""
    echo "NAT reset to shared pool configuration."
}

#------------------------------------------------------------------------------
# Add Custom Rule
#------------------------------------------------------------------------------
add_custom_rule() {
    local match_cidr=""
    local nat_ip_name=""
    local rule_number=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --match)
                match_cidr="$2"
                shift 2
                ;;
            --nat-ip)
                nat_ip_name="$2"
                shift 2
                ;;
            --rule-number)
                rule_number="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [ -z "${match_cidr}" ] || [ -z "${nat_ip_name}" ]; then
        echo "Error: --match and --nat-ip are required"
        echo "Example: $0 add-rule --match '10.1.0.0/16' --nat-ip nat-ip-1"
        exit 1
    fi
    
    # Auto-assign rule number if not provided
    if [ -z "${rule_number}" ]; then
        rule_number=$(($(gcloud compute routers nats rules list \
            --router="nat-router" \
            --nat="private-nat" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --format="value(ruleNumber)" 2>/dev/null | sort -n | tail -1) + 100))
        rule_number=${rule_number:-100}
    fi
    
    # Get NAT IP self-link
    nat_ip_link=$(gcloud compute addresses describe "${nat_ip_name}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(selfLink)" 2>/dev/null)
    
    if [ -z "${nat_ip_link}" ]; then
        echo "Error: NAT IP ${nat_ip_name} not found"
        exit 1
    fi
    
    echo "Creating NAT rule ${rule_number}..."
    echo "  Match: inIpRange(destination.ip, '${match_cidr}')"
    echo "  NAT IP: ${nat_ip_name}"
    
    gcloud compute routers nats rules create "${rule_number}" \
        --router="nat-router" \
        --nat="private-nat" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --match="inIpRange(destination.ip, '${match_cidr}')" \
        --source-nat-active-ips="${nat_ip_link}"
    
    echo "Rule created successfully!"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
case "${1:-show}" in
    show)
        show_config
        ;;
    per-destination)
        shift
        configure_per_destination "$@"
        show_config
        ;;
    per-service)
        shift
        configure_per_service "$@"
        show_config
        ;;
    shared)
        shift
        configure_shared "$@"
        show_config
        ;;
    add-rule)
        shift
        add_custom_rule "$@"
        show_config
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
