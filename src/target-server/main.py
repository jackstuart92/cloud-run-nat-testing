"""
Target Server for NAT Testing

This server runs on VMs in the workload VPCs and:
1. Receives pings from Cloud Run services (via Private NAT)
2. Logs the source IP seen (should be NAT pool IP, not Class E)
3. Optionally calls back to Cloud Run services (via Private Google Access)
"""

import os
import time
import logging
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Get VM identity from environment or hostname
VM_ID = os.environ.get("VM_ID", os.environ.get("HOSTNAME", "unknown"))


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "vm_id": VM_ID
    })


@app.route("/ping", methods=["POST"])
def ping():
    """
    Receive ping from Cloud Run service.
    Log the source IP and optionally call back.
    
    Expected request body:
    {
        "correlation_id": "uuid",
        "source_service": "service-name",
        "callback_url": "https://...",  # optional
        "timestamp": 1234567890.123,
        "data": {...}  # optional
    }
    """
    source_ip = request.remote_addr
    data = request.get_json() or {}
    
    correlation_id = data.get("correlation_id", "unknown")
    source_service = data.get("source_service", "unknown")
    callback_url = data.get("callback_url")
    
    # Log the incoming request with source IP
    logger.info(
        f"Received ping from {source_ip} | "
        f"correlation_id={correlation_id} | "
        f"source_service={source_service}"
    )
    
    response = {
        "vm_id": VM_ID,
        "source_ip": source_ip,
        "timestamp": time.time(),
        "correlation_id": correlation_id,
        "received_data": data
    }
    
    # If callback URL provided, call back to Cloud Run
    if callback_url:
        logger.info(f"Initiating callback to {callback_url}")
        try:
            # Get identity token for authenticated Cloud Run services
            # This uses the VM's service account via metadata server
            token = get_identity_token(callback_url)
            
            headers = {}
            if token:
                headers["Authorization"] = f"Bearer {token}"
            
            callback_payload = {
                "vm_id": VM_ID,
                "original_source_ip": source_ip,
                "correlation_id": correlation_id,
                "timestamp": time.time()
            }
            
            callback_response = requests.post(
                callback_url,
                json=callback_payload,
                headers=headers,
                timeout=30
            )
            
            response["callback_status"] = callback_response.status_code
            response["callback_success"] = callback_response.ok
            
            if callback_response.ok:
                try:
                    response["callback_response"] = callback_response.json()
                except:
                    response["callback_response"] = callback_response.text
                logger.info(f"Callback successful: {callback_response.status_code}")
            else:
                response["callback_response"] = callback_response.text
                logger.warning(f"Callback returned non-OK: {callback_response.status_code}")
                
        except Exception as e:
            logger.error(f"Callback failed: {e}")
            response["callback_error"] = str(e)
            response["callback_success"] = False
    
    return jsonify(response)


@app.route("/echo", methods=["GET", "POST"])
def echo():
    """Simple echo endpoint for basic connectivity testing"""
    return jsonify({
        "vm_id": VM_ID,
        "source_ip": request.remote_addr,
        "method": request.method,
        "path": request.path,
        "headers": dict(request.headers),
        "args": dict(request.args),
        "timestamp": time.time()
    })


@app.route("/stats", methods=["GET"])
def stats():
    """Return server statistics"""
    return jsonify({
        "vm_id": VM_ID,
        "uptime_seconds": time.time() - app.start_time,
        "timestamp": time.time()
    })


def get_identity_token(audience):
    """
    Get identity token from GCE metadata server for calling Cloud Run.
    This allows the VM to authenticate to Cloud Run services.
    """
    try:
        metadata_url = (
            "http://metadata.google.internal/computeMetadata/v1/"
            f"instance/service-accounts/default/identity?audience={audience}"
        )
        response = requests.get(
            metadata_url,
            headers={"Metadata-Flavor": "Google"},
            timeout=5
        )
        if response.ok:
            return response.text
    except Exception as e:
        logger.warning(f"Failed to get identity token: {e}")
    return None


# Store start time for uptime tracking
app.start_time = time.time()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    logger.info(f"Starting target server on port {port}, VM_ID={VM_ID}")
    app.run(host="0.0.0.0", port=port, debug=False)
