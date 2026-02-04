#!/bin/bash
#==============================================================================
# 04-analyze-results.sh
# Analyze NAT behavior from Cloud Logging and test results
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "=============================================="
echo "Cloud Run NAT Testing - Results Analysis"
echo "=============================================="
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo "=============================================="

gcloud config set project "${PROJECT_ID}"

#------------------------------------------------------------------------------
# NAT Logging Analysis
#------------------------------------------------------------------------------
echo ""
echo "[1/4] Analyzing NAT Logs..."
echo "==========================="

# Query NAT logs from the last hour
echo ""
echo "NAT connection logs (last 1 hour):"
gcloud logging read "resource.type=\"nat_gateway\" AND timestamp>=\"$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)\"" \
    --project="${PROJECT_ID}" \
    --format="table(timestamp,jsonPayload.connection.src_ip,jsonPayload.connection.nat_ip,jsonPayload.connection.dest_ip,jsonPayload.connection.dest_port)" \
    --limit=50 2>/dev/null || echo "  No NAT logs found (logging may take a few minutes to appear)"

# NAT IP usage summary
echo ""
echo "NAT IP allocation summary:"
gcloud logging read "resource.type=\"nat_gateway\" AND timestamp>=\"$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)\"" \
    --project="${PROJECT_ID}" \
    --format="json" \
    --limit=1000 2>/dev/null | \
    jq -r '[.[] | .jsonPayload.connection.nat_ip] | group_by(.) | map({nat_ip: .[0], count: length}) | sort_by(-.count) | .[] | "\(.nat_ip): \(.count) connections"' 2>/dev/null || echo "  Unable to aggregate NAT IP usage"

#------------------------------------------------------------------------------
# Cloud Run Service Logs
#------------------------------------------------------------------------------
echo ""
echo "[2/4] Analyzing Cloud Run Logs..."
echo "=================================="

# Get recent Cloud Run request logs
echo ""
echo "Recent Cloud Run requests (last 30 minutes):"
gcloud logging read "resource.type=\"cloud_run_revision\" AND timestamp>=\"$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)\" AND textPayload:\"Pinging\"" \
    --project="${PROJECT_ID}" \
    --format="table(timestamp,resource.labels.service_name,textPayload)" \
    --limit=20 2>/dev/null || echo "  No Cloud Run logs found"

# Count requests per service
echo ""
echo "Request counts per service (last 30 minutes):"
gcloud logging read "resource.type=\"cloud_run_revision\" AND httpRequest.requestUrl:\"ping-vm\" AND timestamp>=\"$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)\"" \
    --project="${PROJECT_ID}" \
    --format="json" \
    --limit=1000 2>/dev/null | \
    jq -r '[.[] | .resource.labels.service_name] | group_by(.) | map({service: .[0], requests: length}) | sort_by(-.requests) | .[:10] | .[] | "\(.service): \(.requests) requests"' 2>/dev/null || echo "  Unable to count requests"

#------------------------------------------------------------------------------
# VM Logs Analysis
#------------------------------------------------------------------------------
echo ""
echo "[3/4] Analyzing VM Target Server Logs..."
echo "========================================"

echo ""
echo "Source IPs seen by VM-A (last 30 minutes):"
gcloud logging read "resource.type=\"gce_instance\" AND resource.labels.instance_id:\"target-vm-a\" AND textPayload:\"Received ping from\" AND timestamp>=\"$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)\"" \
    --project="${PROJECT_ID}" \
    --format="json" \
    --limit=500 2>/dev/null | \
    jq -r '[.[] | .textPayload | capture("from (?<ip>[0-9.]+)") | .ip] | group_by(.) | map({source_ip: .[0], count: length}) | sort_by(-.count) | .[] | "  \(.source_ip): \(.count) requests"' 2>/dev/null || echo "  No VM-A logs found"

echo ""
echo "Source IPs seen by VM-B (last 30 minutes):"
gcloud logging read "resource.type=\"gce_instance\" AND resource.labels.instance_id:\"target-vm-b\" AND textPayload:\"Received ping from\" AND timestamp>=\"$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)\"" \
    --project="${PROJECT_ID}" \
    --format="json" \
    --limit=500 2>/dev/null | \
    jq -r '[.[] | .textPayload | capture("from (?<ip>[0-9.]+)") | .ip] | group_by(.) | map({source_ip: .[0], count: length}) | sort_by(-.count) | .[] | "  \(.source_ip): \(.count) requests"' 2>/dev/null || echo "  No VM-B logs found"

#------------------------------------------------------------------------------
# NAT Configuration Analysis
#------------------------------------------------------------------------------
echo ""
echo "[4/4] NAT Configuration Details..."
echo "=================================="

echo ""
echo "NAT Gateway Configuration:"
gcloud compute routers nats describe "private-nat" \
    --router="nat-router" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="yaml" 2>/dev/null || echo "  NAT not found"

echo ""
echo "NAT Status and Metrics:"
gcloud compute routers get-nat-mapping-info "nat-router" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="table(instanceName,ipCidrRange,natIpPortRanges)" 2>/dev/null || echo "  No NAT mappings available"

#------------------------------------------------------------------------------
# Port Allocation Analysis
#------------------------------------------------------------------------------
echo ""
echo "Port Allocation Analysis:"
echo "========================="

# Calculate theoretical limits
echo ""
echo "Theoretical NAT Capacity:"
echo "  NAT Pool CIDR: ${NAT_POOL_CIDR}"

# Parse CIDR to get number of IPs
IFS='/' read -r base_ip prefix <<< "${NAT_POOL_CIDR}"
num_ips=$((2 ** (32 - prefix) - 2))  # Subtract network and broadcast

echo "  Available IPs in pool: ${num_ips}"
echo "  Ports per IP: 65535"
echo "  Total theoretical ports: $((num_ips * 65535))"
echo ""
echo "  With ${NAT_MIN_PORTS_PER_VM} min ports per VM:"
echo "  Max concurrent VMs/instances: $((num_ips * 65535 / NAT_MIN_PORTS_PER_VM))"

#------------------------------------------------------------------------------
# Test Results Summary
#------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Recent Test Results Files"
echo "=============================================="

echo ""
echo "Available result files:"
ls -la /tmp/nat-test-*.json 2>/dev/null | while read line; do
    echo "  $line"
done || echo "  No result files found in /tmp/"

# If there are result files, show latest summary
LATEST_BASIC=$(ls -t /tmp/nat-test-basic-*.json 2>/dev/null | head -1)
LATEST_SCALE=$(ls -t /tmp/nat-test-scale-*.json 2>/dev/null | head -1)
LATEST_BULK=$(ls -t /tmp/nat-test-bulk-*.json 2>/dev/null | head -1)

if [ -n "${LATEST_BASIC}" ]; then
    echo ""
    echo "Latest Basic Test Results (${LATEST_BASIC}):"
    local total=$(jq 'length' "${LATEST_BASIC}")
    local success_a=$(jq '[.[] | select(.vm_a.success == true)] | length' "${LATEST_BASIC}")
    local success_b=$(jq '[.[] | select(.vm_b.success == true)] | length' "${LATEST_BASIC}")
    echo "  Services tested: ${total}"
    echo "  VM A success: ${success_a}/${total}"
    echo "  VM B success: ${success_b}/${total}"
fi

if [ -n "${LATEST_SCALE}" ]; then
    echo ""
    echo "Latest Scale Test Results (${LATEST_SCALE}):"
    jq '.' "${LATEST_SCALE}"
fi

if [ -n "${LATEST_BULK}" ]; then
    echo ""
    echo "Latest Bulk Test Results (${LATEST_BULK}):"
    local total_req=$(jq '[.[] | .result.total_requests] | add' "${LATEST_BULK}")
    local total_success=$(jq '[.[] | .result.successful] | add' "${LATEST_BULK}")
    echo "  Total requests: ${total_req}"
    echo "  Successful: ${total_success}"
    echo "  Success rate: $(echo "scale=2; ${total_success} * 100 / ${total_req}" | bc)%"
fi

#------------------------------------------------------------------------------
# Recommendations
#------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Analysis Complete"
echo "=============================================="
echo ""
echo "Key things to verify:"
echo "  1. NAT IPs should be from 10.255.0.0/16 range (Private NAT pool)"
echo "  2. VMs should see consistent source IPs (not 240.x.x.x)"
echo "  3. Check for port exhaustion errors in NAT logs"
echo "  4. Verify callback success (VM -> Cloud Run via Private Google Access)"
echo ""
echo "For deeper analysis, query Cloud Logging directly:"
echo "  gcloud logging read 'resource.type=\"nat_gateway\"' --limit=100"
echo ""
echo "Or use the Cloud Console:"
echo "  https://console.cloud.google.com/logs/query?project=${PROJECT_ID}"
