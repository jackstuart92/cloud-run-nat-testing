#!/bin/bash
#==============================================================================
# 03-run-tests.sh
# Execute NAT connectivity and scale tests
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Parse arguments
TEST_TYPE="basic"
SERVICE_COUNT=${NUM_SERVICES}
REQUESTS_PER_SVC=${REQUESTS_PER_SERVICE}

while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            TEST_TYPE="$2"
            shift 2
            ;;
        --services)
            SERVICE_COUNT="$2"
            shift 2
            ;;
        --requests)
            REQUESTS_PER_SVC="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --test TYPE       Test type: basic, roundtrip, scale, bulk (default: basic)"
            echo "  --services N      Number of services to test (default: ${NUM_SERVICES})"
            echo "  --requests N      Requests per service for bulk test (default: ${REQUESTS_PER_SERVICE})"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=============================================="
echo "Cloud Run NAT Testing - Test Execution"
echo "=============================================="
echo "Project:      ${PROJECT_ID}"
echo "Region:       ${REGION}"
echo "Test Type:    ${TEST_TYPE}"
echo "Services:     ${SERVICE_COUNT}"
echo "=============================================="

gcloud config set project "${PROJECT_ID}"

# Get identity token for calling Cloud Run services
get_identity_token() {
    gcloud auth print-identity-token 2>/dev/null
}

# Call a Cloud Run service
call_service() {
    local service_name=$1
    local endpoint=$2
    local data=$3
    
    local url=$(gcloud run services describe "${service_name}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format='value(status.url)' 2>/dev/null)
    
    if [ -z "${url}" ]; then
        echo "ERROR: Could not get URL for ${service_name}"
        return 1
    fi
    
    local token=$(get_identity_token)
    
    curl -s -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${data}" \
        "${url}${endpoint}"
}

#------------------------------------------------------------------------------
# Test Functions
#------------------------------------------------------------------------------

run_basic_test() {
    echo ""
    echo "Running Basic Connectivity Test..."
    echo "=================================="
    
    local results_file="/tmp/nat-test-basic-$(date +%Y%m%d-%H%M%S).json"
    echo "[]" > "${results_file}"
    
    for i in $(seq 1 ${SERVICE_COUNT}); do
        local service_name=$(get_service_name $i)
        echo ""
        echo "Testing ${service_name}..."
        
        # Test ping to VM A
        echo "  Pinging VM A (10.1.0.10)..."
        local result_a=$(call_service "${service_name}" "/ping-vm" '{"target": "a"}')
        echo "    Result: $(echo "${result_a}" | jq -c '{success, elapsed_ms, source_ip: .response.source_ip}')"
        
        # Test ping to VM B
        echo "  Pinging VM B (10.2.0.10)..."
        local result_b=$(call_service "${service_name}" "/ping-vm" '{"target": "b"}')
        echo "    Result: $(echo "${result_b}" | jq -c '{success, elapsed_ms, source_ip: .response.source_ip}')"
        
        # Append to results
        jq --arg svc "${service_name}" \
           --argjson ra "${result_a}" \
           --argjson rb "${result_b}" \
           '. += [{"service": $svc, "vm_a": $ra, "vm_b": $rb}]' \
           "${results_file}" > "${results_file}.tmp" && mv "${results_file}.tmp" "${results_file}"
    done
    
    echo ""
    echo "Results saved to: ${results_file}"
    
    # Summary
    echo ""
    echo "Summary:"
    echo "--------"
    local total=$(jq 'length' "${results_file}")
    local success_a=$(jq '[.[] | select(.vm_a.success == true)] | length' "${results_file}")
    local success_b=$(jq '[.[] | select(.vm_b.success == true)] | length' "${results_file}")
    echo "  Total services tested: ${total}"
    echo "  VM A connectivity: ${success_a}/${total}"
    echo "  VM B connectivity: ${success_b}/${total}"
    
    # Extract unique NAT IPs seen
    echo ""
    echo "NAT IPs observed (source IPs seen by VMs):"
    jq -r '[.[] | .vm_a.response.source_ip, .vm_b.response.source_ip] | unique | .[]' "${results_file}" 2>/dev/null | sort -u | while read ip; do
        if [ -n "$ip" ] && [ "$ip" != "null" ]; then
            echo "  - ${ip}"
        fi
    done
}

run_roundtrip_test() {
    echo ""
    echo "Running Roundtrip Test (Cloud Run -> VM -> Cloud Run)..."
    echo "========================================================="
    
    local results_file="/tmp/nat-test-roundtrip-$(date +%Y%m%d-%H%M%S).json"
    echo "[]" > "${results_file}"
    
    for i in $(seq 1 ${SERVICE_COUNT}); do
        local service_name=$(get_service_name $i)
        echo ""
        echo "Testing roundtrip for ${service_name}..."
        
        # Test roundtrip to VM A
        echo "  Roundtrip via VM A..."
        local result_a=$(call_service "${service_name}" "/test-roundtrip" '{"target": "a", "wait_for_callback_ms": 10000}')
        local success_a=$(echo "${result_a}" | jq -r '.success')
        local total_ms_a=$(echo "${result_a}" | jq -r '.total_elapsed_ms')
        echo "    Success: ${success_a}, Total: ${total_ms_a}ms"
        
        # Test roundtrip to VM B
        echo "  Roundtrip via VM B..."
        local result_b=$(call_service "${service_name}" "/test-roundtrip" '{"target": "b", "wait_for_callback_ms": 10000}')
        local success_b=$(echo "${result_b}" | jq -r '.success')
        local total_ms_b=$(echo "${result_b}" | jq -r '.total_elapsed_ms')
        echo "    Success: ${success_b}, Total: ${total_ms_b}ms"
        
        # Append to results
        jq --arg svc "${service_name}" \
           --argjson ra "${result_a}" \
           --argjson rb "${result_b}" \
           '. += [{"service": $svc, "roundtrip_a": $ra, "roundtrip_b": $rb}]' \
           "${results_file}" > "${results_file}.tmp" && mv "${results_file}.tmp" "${results_file}"
    done
    
    echo ""
    echo "Results saved to: ${results_file}"
    
    # Summary
    echo ""
    echo "Summary:"
    echo "--------"
    local total=$(jq 'length' "${results_file}")
    local success_a=$(jq '[.[] | select(.roundtrip_a.success == true)] | length' "${results_file}")
    local success_b=$(jq '[.[] | select(.roundtrip_b.success == true)] | length' "${results_file}")
    local avg_a=$(jq '[.[] | select(.roundtrip_a.success == true) | .roundtrip_a.total_elapsed_ms] | add / length' "${results_file}")
    local avg_b=$(jq '[.[] | select(.roundtrip_b.success == true) | .roundtrip_b.total_elapsed_ms] | add / length' "${results_file}")
    
    echo "  Total services tested: ${total}"
    echo "  VM A roundtrip success: ${success_a}/${total} (avg: ${avg_a}ms)"
    echo "  VM B roundtrip success: ${success_b}/${total} (avg: ${avg_b}ms)"
}

run_scale_test() {
    echo ""
    echo "Running Scale Test (all services simultaneously)..."
    echo "===================================================="
    
    local results_file="/tmp/nat-test-scale-$(date +%Y%m%d-%H%M%S).json"
    local temp_dir="/tmp/nat-test-scale-$$"
    mkdir -p "${temp_dir}"
    
    echo "Triggering ${SERVICE_COUNT} services in parallel..."
    local start_time=$(date +%s.%N)
    
    # Launch all requests in parallel
    for i in $(seq 1 ${SERVICE_COUNT}); do
        local service_name=$(get_service_name $i)
        (
            result=$(call_service "${service_name}" "/ping-vm" '{"target": "a"}' 2>/dev/null)
            echo "${result}" > "${temp_dir}/${service_name}.json"
        ) &
    done
    
    # Wait for all to complete
    wait
    
    local end_time=$(date +%s.%N)
    local total_time=$(echo "${end_time} - ${start_time}" | bc)
    
    echo "All requests completed in ${total_time}s"
    
    # Aggregate results
    echo "Aggregating results..."
    echo '{"services": [], "summary": {}}' > "${results_file}"
    
    local success_count=0
    local fail_count=0
    local total_latency=0
    local nat_ips=()
    
    for f in "${temp_dir}"/*.json; do
        if [ -f "$f" ]; then
            local svc_name=$(basename "$f" .json)
            local success=$(jq -r '.success // false' "$f" 2>/dev/null)
            local latency=$(jq -r '.elapsed_ms // 0' "$f" 2>/dev/null)
            local src_ip=$(jq -r '.response.source_ip // "unknown"' "$f" 2>/dev/null)
            
            if [ "$success" == "true" ]; then
                ((success_count++))
                total_latency=$(echo "${total_latency} + ${latency}" | bc)
                nat_ips+=("$src_ip")
            else
                ((fail_count++))
            fi
        fi
    done
    
    local avg_latency=0
    if [ $success_count -gt 0 ]; then
        avg_latency=$(echo "scale=2; ${total_latency} / ${success_count}" | bc)
    fi
    
    # Count unique NAT IPs
    local unique_ips=$(printf '%s\n' "${nat_ips[@]}" | sort -u | wc -l)
    
    echo ""
    echo "Scale Test Results:"
    echo "==================="
    echo "  Total services:     ${SERVICE_COUNT}"
    echo "  Successful:         ${success_count}"
    echo "  Failed:             ${fail_count}"
    echo "  Total time:         ${total_time}s"
    echo "  Avg latency:        ${avg_latency}ms"
    echo "  Unique NAT IPs:     ${unique_ips}"
    echo ""
    echo "  Requests/second:    $(echo "scale=2; ${SERVICE_COUNT} / ${total_time}" | bc)"
    
    # Cleanup
    rm -rf "${temp_dir}"
    
    # Save summary
    cat > "${results_file}" << EOF
{
    "test_type": "scale",
    "timestamp": "$(date -Iseconds)",
    "total_services": ${SERVICE_COUNT},
    "successful": ${success_count},
    "failed": ${fail_count},
    "total_time_seconds": ${total_time},
    "avg_latency_ms": ${avg_latency},
    "unique_nat_ips": ${unique_ips},
    "requests_per_second": $(echo "scale=2; ${SERVICE_COUNT} / ${total_time}" | bc)
}
EOF
    
    echo ""
    echo "Results saved to: ${results_file}"
}

run_bulk_test() {
    echo ""
    echo "Running Bulk Test (${REQUESTS_PER_SVC} requests per service)..."
    echo "================================================================"
    
    local results_file="/tmp/nat-test-bulk-$(date +%Y%m%d-%H%M%S).json"
    echo "[]" > "${results_file}"
    
    for i in $(seq 1 ${SERVICE_COUNT}); do
        local service_name=$(get_service_name $i)
        echo ""
        echo "Bulk testing ${service_name} (${REQUESTS_PER_SVC} requests to each VM)..."
        
        local result=$(call_service "${service_name}" "/bulk-test" "{\"count\": ${REQUESTS_PER_SVC}, \"target\": \"both\", \"delay_ms\": ${REQUEST_DELAY_MS}}")
        
        local successful=$(echo "${result}" | jq -r '.successful')
        local failed=$(echo "${result}" | jq -r '.failed')
        local avg_latency=$(echo "${result}" | jq -r '.avg_latency_ms')
        local nat_ips=$(echo "${result}" | jq -r '.source_ips_seen | join(", ")')
        
        echo "  Successful: ${successful}, Failed: ${failed}, Avg latency: ${avg_latency}ms"
        echo "  NAT IPs seen: ${nat_ips}"
        
        # Append to results
        jq --arg svc "${service_name}" \
           --argjson res "${result}" \
           '. += [{"service": $svc, "result": $res}]' \
           "${results_file}" > "${results_file}.tmp" && mv "${results_file}.tmp" "${results_file}"
    done
    
    echo ""
    echo "Results saved to: ${results_file}"
    
    # Overall summary
    echo ""
    echo "Overall Summary:"
    echo "================"
    local total_requests=$(jq '[.[] | .result.total_requests] | add' "${results_file}")
    local total_successful=$(jq '[.[] | .result.successful] | add' "${results_file}")
    local total_failed=$(jq '[.[] | .result.failed] | add' "${results_file}")
    local overall_avg=$(jq '[.[] | .result.avg_latency_ms] | add / length' "${results_file}")
    
    echo "  Total requests:  ${total_requests}"
    echo "  Successful:      ${total_successful}"
    echo "  Failed:          ${total_failed}"
    echo "  Success rate:    $(echo "scale=2; ${total_successful} * 100 / ${total_requests}" | bc)%"
    echo "  Avg latency:     ${overall_avg}ms"
    
    # All unique NAT IPs across all services
    echo ""
    echo "All NAT IPs observed:"
    jq -r '[.[] | .result.source_ips_seen[]] | unique | .[]' "${results_file}" | while read ip; do
        echo "  - ${ip}"
    done
}

#------------------------------------------------------------------------------
# Run Selected Test
#------------------------------------------------------------------------------

case ${TEST_TYPE} in
    basic)
        run_basic_test
        ;;
    roundtrip)
        run_roundtrip_test
        ;;
    scale)
        run_scale_test
        ;;
    bulk)
        run_bulk_test
        ;;
    all)
        run_basic_test
        run_roundtrip_test
        run_scale_test
        run_bulk_test
        ;;
    *)
        echo "Unknown test type: ${TEST_TYPE}"
        echo "Available: basic, roundtrip, scale, bulk, all"
        exit 1
        ;;
esac

echo ""
echo "=============================================="
echo "Test Complete!"
echo "=============================================="
echo ""
echo "To analyze NAT behavior in detail, run:"
echo "  ./scripts/04-analyze-results.sh"
