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
