# Cloud Run NAT Testing Framework

A comprehensive testing framework to evaluate Cloud Run NAT behavior with Class E addressing, Private NAT translation, and bidirectional VPC communication.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Network Design](#network-design)
- [Per-Service NAT Configuration](#per-service-nat-configuration)
- [NAT Rules Deep Dive](#nat-rules-deep-dive)
- [Subnet Requirements](#subnet-requirements)
- [IP Scaling Calculations](#ip-scaling-calculations)
- [Traffic Flows](#traffic-flows)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Test Scenarios](#test-scenarios)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

This framework creates a multi-VPC environment to test Cloud Run NAT behavior at scale.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                                  GCP Project                                          │
│                              Region: us-central1                                      │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         SERVERLESS VPC                                          │  │
│  │                                                                                 │  │
│  │   Cloud Run Subnets: 240.0.0.0/12 (Class E - non-routable)                     │  │
│  │   Private NAT Pool: 10.255.0.0/16 (Routable)                                   │  │
│  │                                                                                 │  │
│  │   ┌─────────────────────────────────────────────────────────────────────────┐  │  │
│  │   │  Cloud Run Services (up to 2000)                                        │  │  │
│  │   │  Each service in dedicated /24 subnet from Class E range                │  │  │
│  │   │                                                                          │  │  │
│  │   │  ┌─────────────┐  ┌─────────────┐       ┌─────────────┐                 │  │  │
│  │   │  │ Service 1   │  │ Service 2   │  ...  │ Service N   │                 │  │  │
│  │   │  │240.0.1.0/24 │  │240.0.2.0/24 │       │240.0.N.0/24 │                 │  │  │
│  │   │  └──────┬──────┘  └──────┬──────┘       └──────┬──────┘                 │  │  │
│  │   └─────────┼────────────────┼──────────────────────┼───────────────────────┘  │  │
│  │             │                │                      │                           │  │
│  │             └────────────────┼──────────────────────┘                           │  │
│  │                              │                                                  │  │
│  │                              ▼                                                  │  │
│  │   ┌─────────────────────────────────────────────────────────────────────────┐  │  │
│  │   │                    Cloud Router + Private NAT                           │  │  │
│  │   │                                                                          │  │  │
│  │   │  Translates: 240.x.x.x (Class E) → 10.255.x.x (Routable)               │  │  │
│  │   │  NAT Pool Subnet: 10.255.0.0/16 (65,534 available IPs)                 │  │  │
│  │   │                                                                          │  │  │
│  │   │  ┌─────────────────────────────────────────────────────────────────┐   │  │  │
│  │   │  │ NAT Rules (Optional - for per-destination tracking)             │   │  │  │
│  │   │  │                                                                  │   │  │  │
│  │   │  │ Rule 100: dest 10.1.0.0/16 → use NAT IPs [10.255.1.x]          │   │  │  │
│  │   │  │ Rule 200: dest 10.2.0.0/16 → use NAT IPs [10.255.2.x]          │   │  │  │
│  │   │  └─────────────────────────────────────────────────────────────────┘   │  │  │
│  │   └─────────────────────────────────────────────────────────────────────────┘  │  │
│  │                              │                                                  │  │
│  └──────────────────────────────┼──────────────────────────────────────────────────┘  │
│                                 │                                                     │
│                    VPC Peering (exports 10.255.0.0/16 routes)                        │
│                                 │                                                     │
│               ┌─────────────────┴─────────────────┐                                  │
│               │                                   │                                  │
│               ▼                                   ▼                                  │
│  ┌──────────────────────────────┐  ┌──────────────────────────────────┐             │
│  │    WORKLOAD VPC A            │  │    WORKLOAD VPC B                │             │
│  │    10.1.0.0/16               │  │    10.2.0.0/16                   │             │
│  │                              │  │                                  │             │
│  │  Private Google Access: ✓   │  │  Private Google Access: ✓       │             │
│  │                              │  │                                  │             │
│  │  ┌────────────────────────┐  │  │  ┌────────────────────────────┐  │             │
│  │  │ Target VM-A            │  │  │  │ Target VM-B                │  │             │
│  │  │ IP: 10.1.0.10          │  │  │  │ IP: 10.2.0.10              │  │             │
│  │  │                        │  │  │  │                            │  │             │
│  │  │ Receives traffic from  │  │  │  │ Receives traffic from      │  │             │
│  │  │ NAT IP: 10.255.x.x     │  │  │  │ NAT IP: 10.255.x.x         │  │             │
│  │  │                        │  │  │  │                            │  │             │
│  │  │ Calls back to Cloud    │  │  │  │ Calls back to Cloud        │  │             │
│  │  │ Run via PGA            │  │  │  │ Run via PGA                │  │             │
│  │  └────────────────────────┘  │  │  └────────────────────────────┘  │             │
│  │                              │  │                                  │             │
│  │  Firewall: Allow from       │  │  Firewall: Allow from           │             │
│  │  10.255.0.0/16              │  │  10.255.0.0/16                   │             │
│  └──────────────────────────────┘  └──────────────────────────────────┘             │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Purpose | Configuration |
|-----------|---------|---------------|
| **Serverless VPC** | Hosts Cloud Run services | 240.0.0.0/12 (Class E) |
| **Private NAT** | Translates Class E → routable IPs | NAT pool: 10.255.0.0/16 |
| **Workload VPC A** | Target workload environment | 10.1.0.0/16, PGA enabled |
| **Workload VPC B** | Target workload environment | 10.2.0.0/16, PGA enabled |
| **VPC Peering** | Connects serverless ↔ workloads | Exports custom routes |
| **Cloud Run Services** | Test subjects with VPC egress | Internal ingress, per-service subnets |
| **Target VMs** | Receive requests, send callbacks | No external IP, uses PGA for callbacks |

---

## Network Design

### VPC and CIDR Layout

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              NETWORK CIDR ALLOCATION                                 │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  SERVERLESS VPC                                                                      │
│  ─────────────                                                                       │
│  │                                                                                   │
│  ├── Cloud Run Service Subnets: 240.0.0.0/12                                        │
│  │   │                                                                               │
│  │   ├── Service 1:    240.0.1.0/24   (254 usable IPs)                              │
│  │   ├── Service 2:    240.0.2.0/24   (254 usable IPs)                              │
│  │   ├── Service 3:    240.0.3.0/24   (254 usable IPs)                              │
│  │   ├── ...                                                                         │
│  │   ├── Service 255:  240.0.255.0/24                                               │
│  │   ├── Service 256:  240.1.0.0/24                                                 │
│  │   ├── ...                                                                         │
│  │   └── Service 2000: 240.7.208.0/24                                               │
│  │                                                                                   │
│  └── Private NAT Pool Subnet: 10.255.0.0/16                                         │
│      └── NAT translated IPs allocated from this range                               │
│                                                                                      │
│  WORKLOAD VPC A                                                                      │
│  ──────────────                                                                      │
│  │                                                                                   │
│  └── Workload Subnet: 10.1.0.0/24                                                   │
│      └── VM-A: 10.1.0.10                                                            │
│                                                                                      │
│  WORKLOAD VPC B                                                                      │
│  ──────────────                                                                      │
│  │                                                                                   │
│  └── Workload Subnet: 10.2.0.0/24                                                   │
│      └── VM-B: 10.2.0.10                                                            │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Why Class E (240.0.0.0/4)?

Class E addresses (240.0.0.0 - 255.255.255.255) are traditionally reserved and non-routable on the public internet. Google Cloud now supports Class E for:

1. **Serverless VPC Access** - Cloud Run can use Class E subnets
2. **Private addressing** - Avoids conflicts with RFC1918 ranges
3. **Large address space** - ~268 million IPs available
4. **NAT requirement** - Forces NAT translation for external communication

This makes Class E ideal for testing NAT behavior since:
- Traffic MUST be NAT'd to reach RFC1918 destinations
- Easy to verify NAT is working (source IP changes from 240.x.x.x to 10.255.x.x)
- Large address space supports thousands of services

---

## Per-Service NAT Configuration

### Overview

Cloud NAT can be configured at different granularities to control which NAT IPs are used for specific traffic patterns.

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                         NAT CONFIGURATION OPTIONS                                    │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  OPTION A: Shared NAT Pool (Default)                                                │
│  ───────────────────────────────────                                                │
│                                                                                      │
│    All Cloud Run services share the same NAT IP pool                                │
│                                                                                      │
│    ┌─────────────┐                                                                  │
│    │ Service 1   │──┐                                                               │
│    │ Service 2   │──┼──→ NAT Pool [10.255.0.1, 10.255.0.2, ...] ──→ Destinations   │
│    │ Service N   │──┘                                                               │
│    └─────────────┘                                                                  │
│                                                                                      │
│    Pros: Simple, automatic load balancing across NAT IPs                            │
│    Cons: Cannot track which service used which NAT IP                               │
│                                                                                      │
│  ─────────────────────────────────────────────────────────────────────────────────  │
│                                                                                      │
│  OPTION B: Per-Destination NAT Rules                                                │
│  ───────────────────────────────────                                                │
│                                                                                      │
│    Different NAT IPs based on destination network                                   │
│                                                                                      │
│    ┌─────────────┐      ┌─────────────┐                                             │
│    │ All Services│──┬──→│ Rule 100    │──→ 10.1.0.0/16 via NAT IP 10.255.1.x       │
│    │             │  │   │ dest=VPC A  │                                             │
│    │             │  │   └─────────────┘                                             │
│    │             │  │   ┌─────────────┐                                             │
│    │             │  └──→│ Rule 200    │──→ 10.2.0.0/16 via NAT IP 10.255.2.x       │
│    └─────────────┘      │ dest=VPC B  │                                             │
│                         └─────────────┘                                             │
│                                                                                      │
│    Pros: Track traffic by destination, isolate VPC-specific issues                  │
│    Cons: Still shared within destination                                            │
│                                                                                      │
│  ─────────────────────────────────────────────────────────────────────────────────  │
│                                                                                      │
│  OPTION C: Per-Subnet Tracking (via Logging)                                        │
│  ───────────────────────────────────────────                                        │
│                                                                                      │
│    Each service has its own subnet, enabling tracking via NAT logs                  │
│                                                                                      │
│    ┌──────────────────┐                                                             │
│    │ Service 1        │                                                             │
│    │ Subnet: 240.0.1.0│──→ NAT Log: src=240.0.1.15, nat=10.255.0.47               │
│    └──────────────────┘                                                             │
│    ┌──────────────────┐                                                             │
│    │ Service 2        │                                                             │
│    │ Subnet: 240.0.2.0│──→ NAT Log: src=240.0.2.8, nat=10.255.0.47                │
│    └──────────────────┘                                                             │
│                                                                                      │
│    The pre-NAT source IP (240.0.x.x) identifies the service                        │
│                                                                                      │
│    Pros: Full visibility per-service, works with shared NAT pool                   │
│    Cons: Requires log analysis                                                      │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Configuration Commands

#### Option A: Shared NAT Pool

```bash
# Default configuration - all subnets share NAT pool
gcloud compute routers nats create private-nat \
    --router=nat-router \
    --region=us-central1 \
    --type=PRIVATE \
    --nat-all-subnet-ip-ranges \
    --nat-custom-subnet-ip-ranges=nat-pool-subnet \
    --enable-logging
```

#### Option B: Per-Destination NAT Rules

```bash
# Create NAT with rules support
gcloud compute routers nats create private-nat \
    --router=nat-router \
    --region=us-central1 \
    --type=PRIVATE \
    --nat-all-subnet-ip-ranges \
    --nat-custom-subnet-ip-ranges=nat-pool-subnet \
    --enable-logging

# Add rule for traffic to Workload VPC A
gcloud compute routers nats rules create 100 \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1 \
    --match='inIpRange(destination.ip, "10.1.0.0/16")' \
    --source-nat-active-ips=projects/PROJECT/regions/REGION/addresses/nat-ip-vpc-a

# Add rule for traffic to Workload VPC B
gcloud compute routers nats rules create 200 \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1 \
    --match='inIpRange(destination.ip, "10.2.0.0/16")' \
    --source-nat-active-ips=projects/PROJECT/regions/REGION/addresses/nat-ip-vpc-b
```

#### Option C: Per-Subnet Tracking

```bash
# Configure NAT with specific subnets (for selective NAT)
gcloud compute routers nats create private-nat \
    --router=nat-router \
    --region=us-central1 \
    --type=PRIVATE \
    --source-subnetwork-ip-ranges-to-nat=LIST_OF_SUBNETWORKS \
    --nat-custom-subnet-ip-ranges=cr-subnet-0001,cr-subnet-0002,cr-subnet-0003 \
    --enable-logging

# Query logs to track per-service NAT usage
gcloud logging read 'resource.type="nat_gateway"' \
    --format='table(jsonPayload.connection.src_ip,jsonPayload.connection.nat_ip,jsonPayload.connection.dest_ip)'
```

---

## NAT Rules Deep Dive

### How NAT Rules Work

Cloud NAT rules use Common Expression Language (CEL) to match traffic and apply specific NAT configurations.

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              NAT RULE EVALUATION                                     │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  RULE STRUCTURE                                                                      │
│  ──────────────                                                                      │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │  Rule Number: 100 (lower = higher priority)                                 │    │
│  │                                                                              │    │
│  │  Match Expression (CEL):                                                    │    │
│  │    inIpRange(destination.ip, '10.1.0.0/16')                                │    │
│  │                                                                              │    │
│  │  Action:                                                                    │    │
│  │    source_nat_active_ips: [nat-ip-1, nat-ip-2]                             │    │
│  │    source_nat_drain_ips: []  (for graceful IP removal)                     │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                      │
│  AVAILABLE MATCH EXPRESSIONS                                                         │
│  ───────────────────────────                                                         │
│                                                                                      │
│  │ Expression                                    │ Description                  │   │
│  │──────────────────────────────────────────────│──────────────────────────────│   │
│  │ inIpRange(destination.ip, 'CIDR')            │ Match destination IP range   │   │
│  │ destination.ip == 'IP'                        │ Match exact destination IP   │   │
│  │ nexthop.hub == 'HUB_URI'                     │ Match Network Connectivity   │   │
│  │                                               │ Center hub                   │   │
│  │ nexthop.hub != 'HUB_URI'                     │ Exclude specific hub         │   │
│  │                                                                                   │
│  RULE EVALUATION ORDER                                                              │
│  ─────────────────────                                                              │
│                                                                                      │
│  1. Rules evaluated in order of rule_number (ascending)                             │
│  2. First matching rule wins                                                        │
│  3. If no rules match, default NAT configuration applies                            │
│                                                                                      │
│  EXAMPLE EVALUATION                                                                 │
│  ──────────────────                                                                 │
│                                                                                      │
│  Packet: src=240.0.1.15, dest=10.1.0.10                                            │
│                                                                                      │
│    Rule 100: inIpRange(destination.ip, '10.1.0.0/16')                              │
│              ✓ MATCHES (10.1.0.10 is in 10.1.0.0/16)                               │
│              → Use NAT IPs: [10.255.1.1, 10.255.1.2]                               │
│              → Packet NAT'd: src=10.255.1.1, dest=10.1.0.10                        │
│                                                                                      │
│    Rule 200: inIpRange(destination.ip, '10.2.0.0/16')                              │
│              ✗ Not evaluated (Rule 100 already matched)                            │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### NAT Rule Commands Reference

```bash
# List all NAT rules
gcloud compute routers nats rules list \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1

# Create a new rule
gcloud compute routers nats rules create RULE_NUMBER \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1 \
    --match='MATCH_EXPRESSION' \
    --source-nat-active-ips=NAT_IP_1,NAT_IP_2

# Update a rule
gcloud compute routers nats rules update RULE_NUMBER \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1 \
    --source-nat-active-ips=NEW_NAT_IP

# Delete a rule
gcloud compute routers nats rules delete RULE_NUMBER \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1

# Describe a rule
gcloud compute routers nats rules describe RULE_NUMBER \
    --router=nat-router \
    --nat=private-nat \
    --region=us-central1
```

### Port Allocation in NAT Rules

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              PORT ALLOCATION                                         │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  Each NAT IP has 65,535 ports available for translation.                            │
│  Ports are allocated per VM/instance.                                               │
│                                                                                      │
│  ALLOCATION PARAMETERS                                                              │
│  ─────────────────────                                                              │
│                                                                                      │
│  --min-ports-per-vm=N     Minimum ports guaranteed per instance (default: 64)       │
│  --max-ports-per-vm=N     Maximum ports per instance (default: 65536)               │
│  --enable-dynamic-port-allocation   Allow dynamic scaling of ports                  │
│                                                                                      │
│  CALCULATION EXAMPLE                                                                │
│  ───────────────────                                                                │
│                                                                                      │
│  NAT Pool: 10.255.0.0/16 = 65,534 usable IPs                                       │
│  Ports per IP: 65,535                                                               │
│  Total ports: 65,534 × 65,535 = 4,294,443,390 ports                                │
│                                                                                      │
│  With min-ports-per-vm=1024:                                                        │
│    Max concurrent instances = 4,294,443,390 / 1024 = ~4.2 million                  │
│                                                                                      │
│  For 2000 services × 100 instances each = 200,000 instances:                       │
│    Ports needed = 200,000 × 1024 = 204,800,000 ports                               │
│    NAT IPs needed = 204,800,000 / 65,535 = ~3,126 IPs                              │
│                                                                                      │
│    With /16 NAT pool (65,534 IPs): ✓ More than sufficient                          │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Subnet Requirements

### Per-Service Subnet Sizing

Each Cloud Run service requires its own subnet when using Direct VPC Egress. The subnet must be large enough to accommodate the maximum number of instances.

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           SUBNET SIZING GUIDE                                        │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  FORMULA                                                                            │
│  ───────                                                                            │
│  Required IPs = max_instances + GCP_reserved(4) + buffer(~10%)                      │
│                                                                                      │
│  GCP Reserved IPs per subnet:                                                       │
│    - Network address (x.x.x.0)                                                      │
│    - Default gateway (x.x.x.1)                                                      │
│    - Reserved by GCP (x.x.x.254, x.x.x.255)                                        │
│                                                                                      │
│  SIZING TABLE                                                                       │
│  ────────────                                                                       │
│                                                                                      │
│  │ Max Instances │ Subnet Size │ Total IPs │ Usable IPs │ Headroom │              │
│  │───────────────│─────────────│───────────│────────────│──────────│              │
│  │ 10            │ /28         │ 16        │ 12         │ ✓ OK     │              │
│  │ 25            │ /27         │ 32        │ 28         │ ✓ OK     │              │
│  │ 50            │ /26         │ 64        │ 60         │ ✓ OK     │              │
│  │ 100           │ /25         │ 128       │ 124        │ ✓ OK     │              │
│  │ 200           │ /24         │ 256       │ 252        │ ✓ OK     │              │
│  │ 500           │ /23         │ 512       │ 508        │ ✓ OK     │              │
│  │ 1000          │ /22         │ 1024      │ 1020       │ ✓ OK     │              │
│                                                                                      │
│  RECOMMENDED: /24 per service (supports up to 250 instances with buffer)            │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Class E Address Space Calculation

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        CLASS E CAPACITY PLANNING                                     │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  CLASS E RANGE: 240.0.0.0/4                                                         │
│  Total IPs: 268,435,456 (~268 million)                                              │
│                                                                                      │
│  USING 240.0.0.0/12 FOR THIS FRAMEWORK                                              │
│  ─────────────────────────────────────                                              │
│  Range: 240.0.0.0 - 240.15.255.255                                                  │
│  Total IPs: 1,048,576 (~1 million)                                                  │
│                                                                                      │
│  SUBNET ALLOCATION SCHEME                                                           │
│  ────────────────────────                                                           │
│                                                                                      │
│  Using /24 per service:                                                             │
│    - Each /24 = 256 IPs                                                             │
│    - /12 contains 4,096 /24 subnets                                                │
│    - Supports up to 4,096 services                                                  │
│                                                                                      │
│  Service → Subnet Mapping:                                                          │
│                                                                                      │
│    Service Index │ Subnet CIDR        │ IP Range                                   │
│    ──────────────│────────────────────│────────────────────────────────            │
│    1             │ 240.0.1.0/24       │ 240.0.1.1 - 240.0.1.254                    │
│    2             │ 240.0.2.0/24       │ 240.0.2.1 - 240.0.2.254                    │
│    ...           │ ...                │ ...                                         │
│    255           │ 240.0.255.0/24     │ 240.0.255.1 - 240.0.255.254                │
│    256           │ 240.1.0.0/24       │ 240.1.0.1 - 240.1.0.254                    │
│    ...           │ ...                │ ...                                         │
│    2000          │ 240.7.208.0/24     │ 240.7.208.1 - 240.7.208.254                │
│                                                                                      │
│  Reserved for NAT Pool: 10.255.0.0/16 (in serverless VPC, purpose=PRIVATE_NAT)     │
│                                                                                      │
│  SCALING LIMITS                                                                     │
│  ──────────────                                                                     │
│                                                                                      │
│  │ Services │ Subnet Size │ Total IPs Needed │ Parent CIDR │ Fits in /12? │       │
│  │──────────│─────────────│──────────────────│─────────────│──────────────│       │
│  │ 100      │ /24         │ 25,600           │ /17         │ ✓ Yes        │       │
│  │ 500      │ /24         │ 128,000          │ /15         │ ✓ Yes        │       │
│  │ 1000     │ /24         │ 256,000          │ /14         │ ✓ Yes        │       │
│  │ 2000     │ /24         │ 512,000          │ /13         │ ✓ Yes        │       │
│  │ 4000     │ /24         │ 1,024,000        │ /12         │ ✓ Exactly    │       │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## IP Scaling Calculations

### Comprehensive IP Planning

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                         IP SCALING CALCULATIONS                                      │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  SCENARIO: 2000 Cloud Run services, 100 max instances each                          │
│                                                                                      │
│  1. CLOUD RUN SUBNET IPS                                                            │
│  ───────────────────────                                                            │
│     Services: 2000                                                                   │
│     Subnet per service: /24 (256 IPs)                                               │
│     Total IPs: 2000 × 256 = 512,000 IPs                                            │
│     Parent CIDR: 240.0.0.0/13 (524,288 IPs) ✓                                      │
│                                                                                      │
│  2. NAT POOL IPS                                                                    │
│  ──────────────                                                                     │
│     NAT pool: 10.255.0.0/16 (65,534 IPs)                                           │
│     Max concurrent connections: 65,534 × 65,535 ports = 4.2B connections           │
│     Per instance (1024 ports): 4,194,240 instances supported                        │
│     Required for 200,000 instances: ~3,126 NAT IPs                                 │
│     Available: 65,534 IPs ✓ (20× headroom)                                         │
│                                                                                      │
│  3. WORKLOAD VPC IPS                                                                │
│  ──────────────────                                                                 │
│     VPC A: 10.1.0.0/16 (65,534 IPs available)                                      │
│     VPC B: 10.2.0.0/16 (65,534 IPs available)                                      │
│     VMs needed: 2 (one per VPC)                                                     │
│     IP usage: Minimal ✓                                                             │
│                                                                                      │
│  SUMMARY TABLE                                                                      │
│  ─────────────                                                                      │
│                                                                                      │
│  │ Resource                    │ CIDR           │ IPs Available │ IPs Used    │    │
│  │─────────────────────────────│────────────────│───────────────│─────────────│    │
│  │ Cloud Run Subnets           │ 240.0.0.0/12   │ 1,048,576     │ 512,000     │    │
│  │ NAT Pool                    │ 10.255.0.0/16  │ 65,534        │ ~3,126      │    │
│  │ Workload VPC A              │ 10.1.0.0/16    │ 65,534        │ 1           │    │
│  │ Workload VPC B              │ 10.2.0.0/16    │ 65,534        │ 1           │    │
│  │─────────────────────────────│────────────────│───────────────│─────────────│    │
│  │ TOTAL                       │                │ 1,245,178     │ 515,128     │    │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Traffic Flows

### Flow 1: Cloud Run → VM (Outbound via NAT)

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                    FLOW 1: Cloud Run → VM (via Private NAT)                          │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  Step 1: Cloud Run Service initiates request                                        │
│  ───────────────────────────────────────────                                        │
│                                                                                      │
│    Cloud Run Instance                                                               │
│    ├── Service: nat-test-svc-0001                                                   │
│    ├── Subnet: 240.0.1.0/24                                                         │
│    ├── Instance IP: 240.0.1.15                                                      │
│    └── Request: POST http://10.1.0.10:8080/ping                                     │
│                                                                                      │
│                           │                                                          │
│                           ▼                                                          │
│                                                                                      │
│  Step 2: Private NAT translates source IP                                           │
│  ────────────────────────────────────────                                           │
│                                                                                      │
│    Cloud NAT Gateway                                                                │
│    ├── Receives: src=240.0.1.15, dst=10.1.0.10:8080                                │
│    ├── Matches: Rule 100 (dest in 10.1.0.0/16)                                     │
│    ├── Allocates: NAT IP 10.255.0.47, port 32456                                   │
│    └── Sends: src=10.255.0.47:32456, dst=10.1.0.10:8080                            │
│                                                                                      │
│    NAT Log Entry:                                                                   │
│    {                                                                                │
│      "connection": {                                                                │
│        "src_ip": "240.0.1.15",                                                     │
│        "src_port": 45678,                                                          │
│        "nat_ip": "10.255.0.47",                                                    │
│        "nat_port": 32456,                                                          │
│        "dest_ip": "10.1.0.10",                                                     │
│        "dest_port": 8080,                                                          │
│        "protocol": "TCP"                                                           │
│      }                                                                              │
│    }                                                                                │
│                                                                                      │
│                           │                                                          │
│                           ▼                                                          │
│                                                                                      │
│  Step 3: VPC Peering routes to Workload VPC                                         │
│  ───────────────────────────────────────────                                        │
│                                                                                      │
│    VPC Peering                                                                      │
│    ├── Source VPC: serverless-vpc                                                   │
│    ├── Dest VPC: workload-vpc-a                                                     │
│    ├── Route: 10.1.0.0/16 via peering                                              │
│    └── Packet forwarded to workload-vpc-a                                           │
│                                                                                      │
│                           │                                                          │
│                           ▼                                                          │
│                                                                                      │
│  Step 4: VM receives request with NAT'd source                                      │
│  ─────────────────────────────────────────────                                      │
│                                                                                      │
│    Target VM-A (10.1.0.10)                                                          │
│    ├── Receives: src=10.255.0.47:32456, dst=10.1.0.10:8080                         │
│    ├── Source IP seen: 10.255.0.47 (NAT'd, routable)                               │
│    ├── NOT: 240.0.1.15 (original, non-routable)                                    │
│    └── Processes request, logs source IP                                           │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Flow 2: VM → Cloud Run (Callback via Private Google Access)

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│              FLOW 2: VM → Cloud Run (via Private Google Access)                      │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  Step 1: VM initiates callback to Cloud Run                                         │
│  ───────────────────────────────────────────                                        │
│                                                                                      │
│    Target VM-A (10.1.0.10)                                                          │
│    ├── Received callback_url from Cloud Run request                                 │
│    ├── Gets identity token from metadata server                                     │
│    └── Request: POST https://nat-test-svc-0001-xyz.run.app/callback                │
│                                                                                      │
│                           │                                                          │
│                           ▼                                                          │
│                                                                                      │
│  Step 2: Private Google Access routes internally                                    │
│  ────────────────────────────────────────────                                       │
│                                                                                      │
│    Private Google Access                                                            │
│    ├── Subnet has private_ip_google_access = true                                   │
│    ├── VM has no external IP                                                        │
│    ├── DNS resolves *.run.app to Google's internal IPs                             │
│    └── Traffic routes via Google's internal network (not internet)                 │
│                                                                                      │
│                           │                                                          │
│                           ▼                                                          │
│                                                                                      │
│  Step 3: Cloud Run receives callback                                                │
│  ───────────────────────────────────                                                │
│                                                                                      │
│    Cloud Run Service (nat-test-svc-0001)                                            │
│    ├── Receives authenticated request                                               │
│    ├── Source IP: Google's internal infrastructure                                  │
│    ├── Identity: VM's service account (verified via token)                         │
│    ├── Correlates with original request via correlation_id                         │
│    └── Roundtrip complete!                                                          │
│                                                                                      │
│  NOTES ON PRIVATE GOOGLE ACCESS                                                     │
│  ──────────────────────────────                                                     │
│                                                                                      │
│  • Requires: private_ip_google_access=true on subnet                               │
│  • VM needs: No external IP, but valid service account                             │
│  • Cloud Run needs: ingress=internal-and-cloud-load-balancing                      │
│  • Authentication: VM gets identity token from metadata server                     │
│                                                                                      │
│  Benefits:                                                                          │
│  • Traffic never leaves Google's network                                           │
│  • No NAT required for Google API access                                           │
│  • Lower latency than going through internet                                       │
│  • More secure (no public IP exposure)                                             │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Complete Roundtrip Sequence

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                         COMPLETE ROUNDTRIP SEQUENCE                                  │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  Timeline:                                                                          │
│                                                                                      │
│  T+0ms     Cloud Run (240.0.1.15) sends request                                    │
│     │      POST http://10.1.0.10:8080/ping                                         │
│     │      Body: { correlation_id: "abc123", callback_url: "https://..." }         │
│     │                                                                               │
│     ▼                                                                               │
│  T+1ms     Private NAT translates                                                   │
│     │      240.0.1.15:45678 → 10.255.0.47:32456                                    │
│     │                                                                               │
│     ▼                                                                               │
│  T+2ms     VPC Peering forwards to workload-vpc-a                                  │
│     │                                                                               │
│     ▼                                                                               │
│  T+5ms     VM-A receives request                                                    │
│     │      Source IP seen: 10.255.0.47 ✓                                           │
│     │      Logs: "Received ping from 10.255.0.47"                                  │
│     │                                                                               │
│     ▼                                                                               │
│  T+10ms    VM-A initiates callback                                                  │
│     │      Gets identity token from metadata server                                │
│     │      POST https://nat-test-svc-0001-xyz.run.app/callback                     │
│     │                                                                               │
│     ▼                                                                               │
│  T+15ms    Private Google Access routes internally                                  │
│     │                                                                               │
│     ▼                                                                               │
│  T+25ms    Cloud Run receives callback                                              │
│     │      Matches correlation_id: "abc123"                                        │
│     │      Roundtrip complete!                                                     │
│     │                                                                               │
│     ▼                                                                               │
│  T+30ms    Cloud Run returns response                                               │
│            { success: true, total_elapsed_ms: 30 }                                  │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Required Tools

- Google Cloud SDK (`gcloud`) version 400.0.0 or later
- `jq` for JSON processing
- `curl` for API calls
- `bash` shell (or Git Bash on Windows)

### GCP Project Requirements

- A GCP project with billing enabled
- Owner or Editor role on the project
- Required APIs enabled (setup script handles this):
  - `compute.googleapis.com`
  - `run.googleapis.com`
  - `cloudbuild.googleapis.com`
  - `containerregistry.googleapis.com`
  - `logging.googleapis.com`

### Quota Requirements

For full-scale testing (2000 services):

| Resource | Required | Default Quota | Notes |
|----------|----------|---------------|-------|
| VPC Networks | 3 | 15 | Should be fine |
| Subnets | 2005 | 250 | **Request increase** |
| Cloud Run Services | 2000 | 1000 | **Request increase** |
| Cloud Run Instances | 200,000 | Varies | Depends on region |
| Static External IPs | 10-100 | 23 | May need increase |

---

## Quick Start

```bash
# 1. Clone and configure
cd cloud-run-nat-testing
export PROJECT_ID="your-project-id"
export REGION="us-central1"

# 2. Make scripts executable
chmod +x scripts/*.sh

# 3. Setup infrastructure (VPCs, NAT, VMs)
./scripts/01-setup-infrastructure.sh

# 4. Deploy Cloud Run services (start small)
./scripts/02-deploy-services.sh --count 10

# 5. Run basic connectivity test
./scripts/03-run-tests.sh --test basic

# 6. Configure per-destination NAT (optional)
./scripts/configure-nat-rules.sh per-destination

# 7. Run scale test
./scripts/03-run-tests.sh --test scale

# 8. Analyze results
./scripts/04-analyze-results.sh

# 9. Scale up when ready
./scripts/02-deploy-services.sh --count 100 --start 11

# 10. Cleanup when done
./scripts/99-cleanup.sh
```

---

## Configuration Reference

All configuration is in `config.env`:

```bash
# Scale settings
NUM_SERVICES=10              # Number of services to deploy
MAX_INSTANCES_PER_SERVICE=10 # Max instances per service
CONCURRENCY=80               # Concurrent requests per instance

# NAT configuration
NAT_MODE="shared"            # shared | per-destination | per-service
NAT_IP_COUNT=2               # Number of NAT IPs to allocate
NAT_MIN_PORTS_PER_VM=1024    # Minimum ports per instance

# Network ranges
SERVERLESS_CIDR="240.0.0.0/12"   # Class E for Cloud Run
NAT_POOL_CIDR="10.255.0.0/16"    # Private NAT pool
WORKLOAD_A_CIDR="10.1.0.0/16"    # Workload VPC A
WORKLOAD_B_CIDR="10.2.0.0/16"    # Workload VPC B
```

---

## Test Scenarios

| Test | Command | Description |
|------|---------|-------------|
| Basic | `./scripts/03-run-tests.sh --test basic` | Verify connectivity to both VMs |
| Roundtrip | `./scripts/03-run-tests.sh --test roundtrip` | Full Cloud Run → VM → Cloud Run flow |
| Scale | `./scripts/03-run-tests.sh --test scale` | All services simultaneously |
| Bulk | `./scripts/03-run-tests.sh --test bulk` | Multiple requests per service |

---

## Troubleshooting

### Common Issues

1. **"Subnet already exists"**: Run cleanup and retry, or use `--start` flag to continue from a specific index

2. **"NAT IP exhausted"**: Increase NAT_IP_COUNT or use larger NAT pool CIDR

3. **"Connection timeout"**: Check firewall rules allow traffic from 10.255.0.0/16

4. **"Callback failed"**: Verify Private Google Access is enabled and Cloud Run ingress allows internal

### Debugging Commands

```bash
# Check NAT status
gcloud compute routers get-nat-mapping-info nat-router --region=$REGION

# View NAT logs
gcloud logging read 'resource.type="nat_gateway"' --limit=50

# Test VM connectivity
gcloud compute ssh target-vm-a --zone=$ZONE --tunnel-through-iap

# Check Cloud Run service status
gcloud run services describe nat-test-svc-0001 --region=$REGION
```

---

## License

MIT License - See LICENSE file for details.
