# Architecture Deep Dive

This document provides detailed architecture diagrams and explanations for the Cloud Run NAT Testing Framework.

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [VPC Network Topology](#vpc-network-topology)
- [NAT Translation Flow](#nat-translation-flow)
- [Private NAT Configuration](#private-nat-configuration)
- [Per-Service Subnet Layout](#per-service-subnet-layout)
- [Bidirectional Communication](#bidirectional-communication)
- [Firewall Rules](#firewall-rules)
- [Scaling Architecture](#scaling-architecture)

---

## High-Level Architecture

```
┌────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                         GCP PROJECT                                                 │
│                                                                                                     │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────────┐ │
│  │                                    SERVERLESS VPC                                              │ │
│  │                                    ══════════════                                              │ │
│  │                                                                                                │ │
│  │   ┌─────────────────────────────────────────────────────────────────────────────────────────┐ │ │
│  │   │                          CLOUD RUN SERVICE LAYER                                        │ │ │
│  │   │                          ════════════════════════                                        │ │ │
│  │   │                                                                                          │ │ │
│  │   │    ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐        ┌──────────┐             │ │ │
│  │   │    │ Service  │ │ Service  │ │ Service  │ │ Service  │  ...   │ Service  │             │ │ │
│  │   │    │    1     │ │    2     │ │    3     │ │    4     │        │   2000   │             │ │ │
│  │   │    │          │ │          │ │          │ │          │        │          │             │ │ │
│  │   │    │240.0.1.0 │ │240.0.2.0 │ │240.0.3.0 │ │240.0.4.0 │        │240.7.208 │             │ │ │
│  │   │    │   /24    │ │   /24    │ │   /24    │ │   /24    │        │   /24    │             │ │ │
│  │   │    └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘        └────┬─────┘             │ │ │
│  │   │         │            │            │            │                   │                   │ │ │
│  │   └─────────┼────────────┼────────────┼────────────┼───────────────────┼───────────────────┘ │ │
│  │             │            │            │            │                   │                     │ │
│  │             └────────────┴────────────┴────────────┴───────────────────┘                     │ │
│  │                                       │                                                       │ │
│  │                                       ▼                                                       │ │
│  │   ┌─────────────────────────────────────────────────────────────────────────────────────────┐ │ │
│  │   │                              CLOUD ROUTER                                                │ │ │
│  │   │   ┌─────────────────────────────────────────────────────────────────────────────────┐   │ │ │
│  │   │   │                           PRIVATE NAT                                            │   │ │ │
│  │   │   │                                                                                  │   │ │ │
│  │   │   │   Source Translation: 240.x.x.x (Class E) ──→ 10.255.x.x (Routable)            │   │ │ │
│  │   │   │                                                                                  │   │ │ │
│  │   │   │   NAT Pool: 10.255.0.0/16 (65,534 IPs × 65,535 ports = 4.2B connections)       │   │ │ │
│  │   │   │                                                                                  │   │ │ │
│  │   │   │   ┌─────────────────────────────────────────────────────────────────────────┐   │   │ │ │
│  │   │   │   │ NAT Rules (Optional)                                                    │   │   │ │ │
│  │   │   │   │                                                                          │   │   │ │ │
│  │   │   │   │ Rule 100: dest=10.1.0.0/16 → NAT via 10.255.1.0/24                      │   │   │ │ │
│  │   │   │   │ Rule 200: dest=10.2.0.0/16 → NAT via 10.255.2.0/24                      │   │   │ │ │
│  │   │   │   └─────────────────────────────────────────────────────────────────────────┘   │   │ │ │
│  │   │   │                                                                                  │   │ │ │
│  │   │   └──────────────────────────────────────────────────────────────────────────────────┘   │ │ │
│  │   └──────────────────────────────────────────────────┬──────────────────────────────────────┘ │ │
│  │                                                      │                                        │ │
│  └──────────────────────────────────────────────────────┼────────────────────────────────────────┘ │
│                                                         │                                          │
│                          ┌──────────────────────────────┴──────────────────────────────┐           │
│                          │                      VPC PEERING                             │           │
│                          │                                                              │           │
│                          │  Exports routes: 10.255.0.0/16 (NAT pool)                   │           │
│                          │  Imports routes: 10.1.0.0/16, 10.2.0.0/16 (workloads)       │           │
│                          └──────────────────────────────┬──────────────────────────────┘           │
│                                                         │                                          │
│                    ┌────────────────────────────────────┴────────────────────────────────┐         │
│                    │                                                                      │         │
│                    ▼                                                                      ▼         │
│  ┌─────────────────────────────────────────────┐    ┌─────────────────────────────────────────────┐│
│  │           WORKLOAD VPC A                    │    │           WORKLOAD VPC B                    ││
│  │           ══════════════                    │    │           ══════════════                    ││
│  │                                             │    │                                             ││
│  │   CIDR: 10.1.0.0/16                        │    │   CIDR: 10.2.0.0/16                        ││
│  │   Private Google Access: ENABLED           │    │   Private Google Access: ENABLED           ││
│  │                                             │    │                                             ││
│  │   ┌─────────────────────────────────────┐  │    │   ┌─────────────────────────────────────┐  ││
│  │   │   Subnet: 10.1.0.0/24               │  │    │   │   Subnet: 10.2.0.0/24               │  ││
│  │   │                                      │  │    │   │                                      │  ││
│  │   │   ┌────────────────────────────┐    │  │    │   │   ┌────────────────────────────┐    │  ││
│  │   │   │     TARGET VM-A            │    │  │    │   │   │     TARGET VM-B            │    │  ││
│  │   │   │     ════════════            │    │  │    │   │   │     ════════════            │    │  ││
│  │   │   │                            │    │  │    │   │   │                            │    │  ││
│  │   │   │   IP: 10.1.0.10            │    │  │    │   │   │   IP: 10.2.0.10            │    │  ││
│  │   │   │   No External IP           │    │  │    │   │   │   No External IP           │    │  ││
│  │   │   │                            │    │  │    │   │   │                            │    │  ││
│  │   │   │   Receives: 10.255.x.x     │    │  │    │   │   │   Receives: 10.255.x.x     │    │  ││
│  │   │   │   (NAT'd source)           │    │  │    │   │   │   (NAT'd source)           │    │  ││
│  │   │   │                            │    │  │    │   │   │                            │    │  ││
│  │   │   │   Sends via: PGA           │    │  │    │   │   │   Sends via: PGA           │    │  ││
│  │   │   │   (to Cloud Run)           │    │  │    │   │   │   (to Cloud Run)           │    │  ││
│  │   │   └────────────────────────────┘    │  │    │   │   └────────────────────────────┘    │  ││
│  │   │                                      │  │    │   │                                      │  ││
│  │   └─────────────────────────────────────┘  │    │   └─────────────────────────────────────┘  ││
│  │                                             │    │                                             ││
│  │   Firewall: Allow ingress from             │    │   Firewall: Allow ingress from             ││
│  │             10.255.0.0/16 on TCP:8080      │    │             10.255.0.0/16 on TCP:8080      ││
│  │                                             │    │                                             ││
│  └─────────────────────────────────────────────┘    └─────────────────────────────────────────────┘│
│                                                                                                     │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## VPC Network Topology

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              VPC NETWORK TOPOLOGY                                    │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│                         ┌───────────────────────────────┐                           │
│                         │      SERVERLESS-VPC           │                           │
│                         │                               │                           │
│                         │  Primary Range: 240.0.0.0/12  │                           │
│                         │  (Class E - Non-routable)     │                           │
│                         │                               │                           │
│                         │  Purpose: Cloud Run Direct    │                           │
│                         │           VPC Egress          │                           │
│                         │                               │                           │
│                         └───────────────┬───────────────┘                           │
│                                         │                                            │
│                         ┌───────────────┴───────────────┐                           │
│                         │                               │                            │
│              ┌──────────▼──────────┐       ┌───────────▼───────────┐               │
│              │                     │       │                       │               │
│              │  VPC Peering:       │       │  VPC Peering:         │               │
│              │  serverless-to-     │       │  serverless-to-       │               │
│              │  workload-a         │       │  workload-b           │               │
│              │                     │       │                       │               │
│              │  Export Custom      │       │  Export Custom        │               │
│              │  Routes: YES        │       │  Routes: YES          │               │
│              │                     │       │                       │               │
│              └──────────┬──────────┘       └───────────┬───────────┘               │
│                         │                               │                            │
│              ┌──────────▼──────────┐       ┌───────────▼───────────┐               │
│              │   WORKLOAD-VPC-A    │       │   WORKLOAD-VPC-B      │               │
│              │                     │       │                       │               │
│              │  CIDR: 10.1.0.0/16  │       │  CIDR: 10.2.0.0/16    │               │
│              │  (RFC1918 Private)  │       │  (RFC1918 Private)    │               │
│              │                     │       │                       │               │
│              │  Purpose: Target    │       │  Purpose: Target      │               │
│              │           Workloads │       │           Workloads   │               │
│              │                     │       │                       │               │
│              └─────────────────────┘       └───────────────────────┘               │
│                                                                                      │
│                                                                                      │
│  ROUTE ADVERTISEMENT                                                                │
│  ═══════════════════                                                                │
│                                                                                      │
│  Serverless VPC exports:                                                            │
│    • 10.255.0.0/16 (NAT pool) → Workload VPCs can route responses                  │
│                                                                                      │
│  Workload VPCs export:                                                              │
│    • 10.1.0.0/16 (VPC A) → Serverless VPC can reach VPC A                          │
│    • 10.2.0.0/16 (VPC B) → Serverless VPC can reach VPC B                          │
│                                                                                      │
│  Note: 240.0.0.0/12 is NOT exported (Class E is non-routable)                      │
│        NAT translates to 10.255.x.x before traffic leaves serverless VPC           │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## NAT Translation Flow

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            NAT TRANSLATION FLOW                                      │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  STEP 1: CLOUD RUN INSTANCE SENDS PACKET                                            │
│  ════════════════════════════════════════                                           │
│                                                                                      │
│    ┌─────────────────────────────────────────────────────────────────┐              │
│    │  Cloud Run Instance                                             │              │
│    │  Service: nat-test-svc-0001                                     │              │
│    │  Subnet: 240.0.1.0/24                                           │              │
│    │  Instance IP: 240.0.1.15                                        │              │
│    │                                                                  │              │
│    │  Outgoing Packet:                                               │              │
│    │  ┌────────────────────────────────────────────────────────────┐ │              │
│    │  │ Src IP: 240.0.1.15    │ Src Port: 45678                   │ │              │
│    │  │ Dst IP: 10.1.0.10     │ Dst Port: 8080                    │ │              │
│    │  │ Protocol: TCP                                              │ │              │
│    │  └────────────────────────────────────────────────────────────┘ │              │
│    └─────────────────────────────────────────────────────────────────┘              │
│                              │                                                       │
│                              ▼                                                       │
│                                                                                      │
│  STEP 2: PACKET REACHES CLOUD NAT                                                   │
│  ════════════════════════════════                                                   │
│                                                                                      │
│    ┌─────────────────────────────────────────────────────────────────┐              │
│    │  Cloud NAT Gateway (Private NAT)                                │              │
│    │                                                                  │              │
│    │  1. Check NAT Rules:                                            │              │
│    │     Rule 100: match "inIpRange(dest, '10.1.0.0/16')" ✓ MATCH   │              │
│    │                                                                  │              │
│    │  2. Select NAT IP from rule's pool:                             │              │
│    │     Available: [10.255.1.1, 10.255.1.2, ...]                   │              │
│    │     Selected: 10.255.1.1                                        │              │
│    │                                                                  │              │
│    │  3. Allocate source port:                                       │              │
│    │     Port range for this instance: 32456-33479 (1024 ports)     │              │
│    │     Selected: 32456                                             │              │
│    │                                                                  │              │
│    │  4. Create connection tracking entry:                           │              │
│    │     240.0.1.15:45678 ↔ 10.255.1.1:32456 → 10.1.0.10:8080      │              │
│    │                                                                  │              │
│    │  5. Rewrite packet:                                             │              │
│    │  ┌────────────────────────────────────────────────────────────┐ │              │
│    │  │ Src IP: 10.255.1.1    │ Src Port: 32456                   │ │              │
│    │  │ Dst IP: 10.1.0.10     │ Dst Port: 8080                    │ │              │
│    │  │ Protocol: TCP                                              │ │              │
│    │  └────────────────────────────────────────────────────────────┘ │              │
│    └─────────────────────────────────────────────────────────────────┘              │
│                              │                                                       │
│                              ▼                                                       │
│                                                                                      │
│  STEP 3: PACKET FORWARDED VIA VPC PEERING                                           │
│  ════════════════════════════════════════                                           │
│                                                                                      │
│    ┌─────────────────────────────────────────────────────────────────┐              │
│    │  VPC Peering: serverless-vpc → workload-vpc-a                   │              │
│    │                                                                  │              │
│    │  Route lookup for 10.1.0.10:                                    │              │
│    │    10.1.0.0/16 → via peering to workload-vpc-a ✓               │              │
│    │                                                                  │              │
│    │  Packet forwarded unchanged                                     │              │
│    └─────────────────────────────────────────────────────────────────┘              │
│                              │                                                       │
│                              ▼                                                       │
│                                                                                      │
│  STEP 4: VM RECEIVES NAT'd PACKET                                                   │
│  ════════════════════════════════                                                   │
│                                                                                      │
│    ┌─────────────────────────────────────────────────────────────────┐              │
│    │  Target VM-A (10.1.0.10)                                        │              │
│    │                                                                  │              │
│    │  Incoming Packet:                                               │              │
│    │  ┌────────────────────────────────────────────────────────────┐ │              │
│    │  │ Src IP: 10.255.1.1    │ Src Port: 32456   ← NAT'd!        │ │              │
│    │  │ Dst IP: 10.1.0.10     │ Dst Port: 8080                    │ │              │
│    │  └────────────────────────────────────────────────────────────┘ │              │
│    │                                                                  │              │
│    │  VM sees source as 10.255.1.1 (routable)                       │              │
│    │  NOT 240.0.1.15 (Class E, non-routable)                        │              │
│    │                                                                  │              │
│    │  Log: "Received request from 10.255.1.1:32456"                 │              │
│    └─────────────────────────────────────────────────────────────────┘              │
│                                                                                      │
│  STEP 5: RESPONSE FOLLOWS REVERSE PATH                                              │
│  ═════════════════════════════════════                                              │
│                                                                                      │
│    VM Response → NAT (reverse translation) → Cloud Run Instance                     │
│    10.1.0.10:8080 → 10.255.1.1:32456 → [NAT] → 240.0.1.15:45678                   │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Private NAT Configuration

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                         PRIVATE NAT CONFIGURATION                                    │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  PRIVATE NAT vs PUBLIC NAT                                                          │
│  ═════════════════════════                                                          │
│                                                                                      │
│  ┌─────────────────────────────────┐    ┌─────────────────────────────────┐        │
│  │       PUBLIC NAT                │    │       PRIVATE NAT               │        │
│  │       ══════════                │    │       ═══════════               │        │
│  │                                 │    │                                 │        │
│  │  • Translates to EXTERNAL IPs  │    │  • Translates to INTERNAL IPs  │        │
│  │  • For internet egress         │    │  • For VPC-to-VPC traffic      │        │
│  │  • Uses public IP addresses    │    │  • Uses private IP addresses   │        │
│  │  • Typical use: internet       │    │  • Typical use: overlapping    │        │
│  │    access from private VMs     │    │    CIDRs, Class E translation  │        │
│  │                                 │    │                                 │        │
│  │  type: PUBLIC                  │    │  type: PRIVATE                 │        │
│  │  nat-external-ip-pool: [...]   │    │  nat-custom-subnet-ip-ranges:  │        │
│  │                                 │    │    nat-pool-subnet             │        │
│  └─────────────────────────────────┘    └─────────────────────────────────┘        │
│                                                                                      │
│                                                                                      │
│  CONFIGURATION DETAILS                                                              │
│  ═════════════════════                                                              │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                                                                              │   │
│  │  NAT Name: private-nat                                                      │   │
│  │  Router: nat-router                                                         │   │
│  │  Region: us-central1                                                        │   │
│  │  Type: PRIVATE                                                              │   │
│  │                                                                              │   │
│  │  Source Subnets: ALL_SUBNETWORKS (all Cloud Run subnets)                   │   │
│  │                                                                              │   │
│  │  NAT Pool Subnet: nat-pool-subnet                                          │   │
│  │    CIDR: 10.255.0.0/16                                                     │   │
│  │    Purpose: PRIVATE_NAT                                                    │   │
│  │    Available IPs: 65,534                                                   │   │
│  │                                                                              │   │
│  │  Port Allocation:                                                           │   │
│  │    Min Ports Per VM: 1024                                                  │   │
│  │    Max Ports Per VM: 65536                                                 │   │
│  │    Dynamic Allocation: ENABLED                                             │   │
│  │                                                                              │   │
│  │  Logging: ENABLED                                                          │   │
│  │    Log filter: ERRORS_ONLY | TRANSLATIONS_ONLY | ALL                       │   │
│  │                                                                              │   │
│  │  Endpoint Independent Mapping: ENABLED                                     │   │
│  │    (Better connection reuse, required for some protocols)                  │   │
│  │                                                                              │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│                                                                                      │
│  gcloud COMMAND                                                                     │
│  ═════════════                                                                      │
│                                                                                      │
│  gcloud compute routers nats create private-nat \                                   │
│      --router=nat-router \                                                          │
│      --region=us-central1 \                                                         │
│      --type=PRIVATE \                                                               │
│      --nat-all-subnet-ip-ranges \                                                   │
│      --nat-custom-subnet-ip-ranges=nat-pool-subnet \                               │
│      --min-ports-per-vm=1024 \                                                      │
│      --enable-dynamic-port-allocation \                                             │
│      --enable-logging                                                               │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Per-Service Subnet Layout

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        PER-SERVICE SUBNET LAYOUT                                     │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  SUBNET ALLOCATION FROM 240.0.0.0/12                                                │
│  ═════════════════════════════════════                                              │
│                                                                                      │
│  Parent CIDR: 240.0.0.0/12                                                          │
│  Range: 240.0.0.0 - 240.15.255.255                                                  │
│  Total /24 subnets available: 4,096                                                 │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                                                                              │   │
│  │  Service Index │ Subnet Name    │ CIDR             │ IP Range              │   │
│  │  ══════════════│════════════════│══════════════════│═══════════════════════│   │
│  │  1             │ cr-subnet-0001 │ 240.0.1.0/24     │ 240.0.1.1-254        │   │
│  │  2             │ cr-subnet-0002 │ 240.0.2.0/24     │ 240.0.2.1-254        │   │
│  │  3             │ cr-subnet-0003 │ 240.0.3.0/24     │ 240.0.3.1-254        │   │
│  │  ...           │ ...            │ ...              │ ...                   │   │
│  │  255           │ cr-subnet-0255 │ 240.0.255.0/24   │ 240.0.255.1-254      │   │
│  │  256           │ cr-subnet-0256 │ 240.1.0.0/24     │ 240.1.0.1-254        │   │
│  │  257           │ cr-subnet-0257 │ 240.1.1.0/24     │ 240.1.1.1-254        │   │
│  │  ...           │ ...            │ ...              │ ...                   │   │
│  │  512           │ cr-subnet-0512 │ 240.1.255.0/24   │ 240.1.255.1-254      │   │
│  │  513           │ cr-subnet-0513 │ 240.2.0.0/24     │ 240.2.0.1-254        │   │
│  │  ...           │ ...            │ ...              │ ...                   │   │
│  │  2000          │ cr-subnet-2000 │ 240.7.208.0/24   │ 240.7.208.1-254      │   │
│  │                                                                              │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│                                                                                      │
│  SUBNET FORMULA                                                                     │
│  ══════════════                                                                     │
│                                                                                      │
│  For service index N (1-based):                                                     │
│                                                                                      │
│    second_octet = (N - 1) / 256                                                     │
│    third_octet  = (N - 1) % 256                                                     │
│    subnet_cidr  = 240.{second_octet}.{third_octet}.0/24                            │
│                                                                                      │
│  Examples:                                                                          │
│    Service 1:    240.0.1.0/24    (0/256=0, 0%256=1)                                │
│    Service 256:  240.0.255.0/24  (255/256=0, 255%256=255)                          │
│    Service 257:  240.1.0.0/24    (256/256=1, 256%256=0)                            │
│    Service 2000: 240.7.208.0/24  (1999/256=7, 1999%256=207+1=208)                  │
│                                                                                      │
│                                                                                      │
│  SUBNET CAPACITY                                                                    │
│  ═══════════════                                                                    │
│                                                                                      │
│  Each /24 subnet:                                                                   │
│    Total IPs: 256                                                                   │
│    Reserved: 4 (network, gateway, broadcast, GCP)                                  │
│    Usable: 252                                                                      │
│                                                                                      │
│  For Cloud Run with max_instances=100:                                              │
│    Required: ~110 IPs (instances + buffer)                                         │
│    Available: 252 IPs                                                              │
│    Headroom: 142 IPs (129% capacity) ✓                                             │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Bidirectional Communication

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                       BIDIRECTIONAL COMMUNICATION                                    │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│                                                                                      │
│    CLOUD RUN                          NAT                         TARGET VM         │
│  ┌───────────┐                    ┌─────────┐                   ┌───────────┐       │
│  │           │                    │         │                   │           │       │
│  │  Service  │   ─────────────►   │ Private │   ─────────────►  │   VM-A    │       │
│  │   0001    │   240.0.1.15:x     │   NAT   │   10.255.0.47:y   │ 10.1.0.10 │       │
│  │           │                    │         │                   │           │       │
│  │           │   ◄─────────────   │         │   ◄─────────────  │           │       │
│  │           │   Response         │         │   Response        │           │       │
│  │           │                    │         │                   │           │       │
│  └─────┬─────┘                    └─────────┘                   └─────┬─────┘       │
│        │                                                               │             │
│        │                                                               │             │
│        │                    ┌─────────────────┐                       │             │
│        │                    │                 │                        │             │
│        │  ◄─────────────────│ Private Google  │◄───────────────────── │             │
│        │  Callback via PGA  │     Access      │  VM calls *.run.app   │             │
│        │                    │                 │                        │             │
│        │                    └─────────────────┘                       │             │
│        │                                                               │             │
│        ▼                                                               ▼             │
│                                                                                      │
│                                                                                      │
│  DIRECTION 1: Cloud Run → VM (via Private NAT)                                      │
│  ═════════════════════════════════════════════                                      │
│                                                                                      │
│    Cloud Run (240.0.1.15)                                                           │
│         │                                                                            │
│         │ POST http://10.1.0.10:8080/ping                                           │
│         │ Body: { callback_url: "https://svc-0001.run.app/callback" }               │
│         ▼                                                                            │
│    Private NAT                                                                       │
│         │ Translates: 240.0.1.15 → 10.255.0.47                                      │
│         ▼                                                                            │
│    VPC Peering                                                                       │
│         │ Routes to workload-vpc-a                                                  │
│         ▼                                                                            │
│    VM-A (10.1.0.10)                                                                 │
│         │ Receives request from 10.255.0.47 (NAT'd source)                          │
│         │ Processes request                                                          │
│         ▼                                                                            │
│    VM-A initiates callback...                                                        │
│                                                                                      │
│                                                                                      │
│  DIRECTION 2: VM → Cloud Run (via Private Google Access)                            │
│  ════════════════════════════════════════════════════════                           │
│                                                                                      │
│    VM-A (10.1.0.10)                                                                 │
│         │                                                                            │
│         │ 1. Get identity token from metadata server:                               │
│         │    GET http://metadata.google.internal/.../identity?audience=...          │
│         │                                                                            │
│         │ 2. POST https://svc-0001-xyz.run.app/callback                             │
│         │    Headers: Authorization: Bearer <token>                                 │
│         │    Body: { correlation_id: "...", vm_id: "target-vm-a" }                 │
│         ▼                                                                            │
│    Private Google Access                                                            │
│         │ • Subnet has private_ip_google_access=true                               │
│         │ • VM has no external IP                                                   │
│         │ • DNS resolves *.run.app to internal Google IPs                          │
│         │ • Traffic stays on Google backbone (no internet)                          │
│         ▼                                                                            │
│    Cloud Run (svc-0001)                                                             │
│         │ • Receives authenticated callback                                          │
│         │ • Correlates with original request                                        │
│         │ • Roundtrip complete!                                                      │
│         ▼                                                                            │
│    Returns response to VM                                                            │
│                                                                                      │
│                                                                                      │
│  KEY REQUIREMENTS FOR BIDIRECTIONAL FLOW                                            │
│  ════════════════════════════════════════                                           │
│                                                                                      │
│  Cloud Run → VM:                                                                    │
│    ✓ Cloud Run service with VPC egress (--vpc-egress=all-traffic)                  │
│    ✓ Private NAT configured with NAT pool subnet                                   │
│    ✓ VPC peering with route export                                                  │
│    ✓ Firewall allows ingress from NAT pool (10.255.0.0/16)                         │
│                                                                                      │
│  VM → Cloud Run:                                                                    │
│    ✓ Workload subnet has private_ip_google_access=true                             │
│    ✓ VM has no external IP (uses PGA instead)                                      │
│    ✓ VM has service account with Cloud Run Invoker role                            │
│    ✓ Cloud Run ingress allows internal traffic                                      │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Firewall Rules

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              FIREWALL RULES                                          │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  WORKLOAD VPC FIREWALL RULES                                                        │
│  ═══════════════════════════                                                        │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ Rule: allow-nat-ingress-workload-vpc-a                                      │   │
│  │                                                                              │   │
│  │   Direction: INGRESS                                                        │   │
│  │   Priority: 1000                                                            │   │
│  │   Action: ALLOW                                                             │   │
│  │                                                                              │   │
│  │   Source Ranges: 10.255.0.0/16 (NAT pool)                                  │   │
│  │   Target Tags: nat-target                                                   │   │
│  │                                                                              │   │
│  │   Protocols/Ports:                                                          │   │
│  │     - TCP: 8080 (HTTP API)                                                 │   │
│  │     - ICMP (for connectivity testing)                                      │   │
│  │                                                                              │   │
│  │   Purpose: Allow Cloud Run (via NAT) to reach target VMs                   │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ Rule: allow-iap-ssh-workload-vpc-a                                          │   │
│  │                                                                              │   │
│  │   Direction: INGRESS                                                        │   │
│  │   Priority: 1000                                                            │   │
│  │   Action: ALLOW                                                             │   │
│  │                                                                              │   │
│  │   Source Ranges: 35.235.240.0/20 (IAP forwarding range)                    │   │
│  │   Target Tags: nat-target                                                   │   │
│  │                                                                              │   │
│  │   Protocols/Ports:                                                          │   │
│  │     - TCP: 22 (SSH)                                                        │   │
│  │                                                                              │   │
│  │   Purpose: Allow SSH via Identity-Aware Proxy for debugging                │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │ Rule: allow-egress-workload-vpc-a                                           │   │
│  │                                                                              │   │
│  │   Direction: EGRESS                                                         │   │
│  │   Priority: 1000                                                            │   │
│  │   Action: ALLOW                                                             │   │
│  │                                                                              │   │
│  │   Destination Ranges: 0.0.0.0/0 (all destinations)                         │   │
│  │                                                                              │   │
│  │   Protocols/Ports: ALL                                                      │   │
│  │                                                                              │   │
│  │   Purpose: Allow VMs to make outbound calls                                │   │
│  │            (needed for PGA to Cloud Run and metadata server)               │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│                                                                                      │
│  SERVERLESS VPC (Implicit Rules)                                                    │
│  ═══════════════════════════════                                                    │
│                                                                                      │
│  Cloud Run manages its own network security. The VPC egress configuration          │
│  determines how traffic flows:                                                      │
│                                                                                      │
│    --vpc-egress=all-traffic                                                         │
│      All egress goes through VPC (and thus through NAT)                            │
│                                                                                      │
│    --vpc-egress=private-ranges-only                                                 │
│      Only RFC1918/RFC6598 traffic goes through VPC                                 │
│      Internet traffic goes directly (not through NAT)                              │
│                                                                                      │
│  For this testing framework, we use all-traffic to ensure NAT is used              │
│  for all destinations.                                                              │
│                                                                                      │
│                                                                                      │
│  TRAFFIC FLOW WITH FIREWALL RULES                                                   │
│  ═════════════════════════════════                                                  │
│                                                                                      │
│    Cloud Run                                                                        │
│        │                                                                             │
│        │ (egress via VPC)                                                           │
│        ▼                                                                             │
│    Private NAT                                                                       │
│        │                                                                             │
│        │ src: 10.255.x.x (NAT'd)                                                    │
│        ▼                                                                             │
│    VPC Peering                                                                       │
│        │                                                                             │
│        │ crosses to workload-vpc-a                                                  │
│        ▼                                                                             │
│    Firewall Check                                                                    │
│        │                                                                             │
│        │ allow-nat-ingress: 10.255.0.0/16 → tcp:8080 ✓                             │
│        ▼                                                                             │
│    VM-A (10.1.0.10:8080)                                                            │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Scaling Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            SCALING ARCHITECTURE                                      │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  HORIZONTAL SCALING: 2000 SERVICES                                                  │
│  ═════════════════════════════════                                                  │
│                                                                                      │
│    ┌─────────────────────────────────────────────────────────────────────────┐     │
│    │                     CLOUD RUN SERVICES                                   │     │
│    │                                                                          │     │
│    │   ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐         ┌─────┐             │     │
│    │   │Svc 1│ │Svc 2│ │Svc 3│ │Svc 4│ │Svc 5│   ...   │Svc  │             │     │
│    │   │     │ │     │ │     │ │     │ │     │         │2000 │             │     │
│    │   └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘         └──┬──┘             │     │
│    │      │       │       │       │       │               │                 │     │
│    │   240.0.1  240.0.2  240.0.3  240.0.4  240.0.5    240.7.208            │     │
│    │    /24      /24      /24      /24      /24         /24                 │     │
│    │                                                                          │     │
│    └──────────────────────────────────┬───────────────────────────────────────┘     │
│                                       │                                              │
│                                       ▼                                              │
│    ┌─────────────────────────────────────────────────────────────────────────┐     │
│    │                      PRIVATE NAT GATEWAY                                 │     │
│    │                                                                          │     │
│    │   NAT Pool: 10.255.0.0/16                                               │     │
│    │   Available IPs: 65,534                                                 │     │
│    │   Ports per IP: 65,535                                                  │     │
│    │   Total capacity: 4.2 billion connections                               │     │
│    │                                                                          │     │
│    │   With 1024 ports per instance:                                         │     │
│    │   Max instances: 4,194,240                                              │     │
│    │                                                                          │     │
│    └─────────────────────────────────────────────────────────────────────────┘     │
│                                                                                      │
│                                                                                      │
│  VERTICAL SCALING: INSTANCES PER SERVICE                                            │
│  ═══════════════════════════════════════                                            │
│                                                                                      │
│    Each service can scale from 0 to max_instances:                                  │
│                                                                                      │
│    ┌─────────────────────────────────────────────────────────────────┐             │
│    │  Service: nat-test-svc-0001                                     │             │
│    │  Subnet: 240.0.1.0/24 (254 usable IPs)                         │             │
│    │  Max Instances: 100                                             │             │
│    │                                                                  │             │
│    │   Instance 1    Instance 2    Instance 3         Instance N    │             │
│    │   240.0.1.2     240.0.1.3     240.0.1.4    ...   240.0.1.N+1   │             │
│    │   ┌────────┐    ┌────────┐    ┌────────┐         ┌────────┐    │             │
│    │   │Container│   │Container│   │Container│        │Container│    │             │
│    │   │  :8080  │   │  :8080  │   │  :8080  │        │  :8080  │    │             │
│    │   └────────┘    └────────┘    └────────┘         └────────┘    │             │
│    │                                                                  │             │
│    │   All instances share the service's subnet                      │             │
│    │   All egress through same NAT gateway                           │             │
│    └─────────────────────────────────────────────────────────────────┘             │
│                                                                                      │
│                                                                                      │
│  TOTAL CAPACITY CALCULATION                                                         │
│  ═════════════════════════                                                          │
│                                                                                      │
│    Services:           2,000                                                        │
│    Instances/Service:  100 (max)                                                    │
│    Total Instances:    200,000                                                      │
│                                                                                      │
│    Subnet IPs needed:  2,000 × 256 = 512,000 IPs                                   │
│    Parent CIDR:        240.0.0.0/13 (524,288 IPs) ✓                                │
│                                                                                      │
│    NAT ports needed:   200,000 × 1,024 = 204,800,000 ports                         │
│    NAT IPs needed:     204,800,000 / 65,535 = 3,126 IPs                            │
│    NAT pool size:      10.255.0.0/16 (65,534 IPs) ✓                                │
│                                                                                      │
│    Headroom:           20× more NAT IPs than required                              │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Summary

This architecture provides:

1. **Isolation**: Each Cloud Run service has its own subnet
2. **Scalability**: Supports 2000+ services with 100+ instances each
3. **Observability**: NAT logs show pre-NAT source IPs for tracking
4. **Flexibility**: NAT rules can customize per-destination behavior
5. **Bidirectional**: Full roundtrip testing via NAT and PGA
6. **Cost Efficiency**: Private NAT uses internal IPs (no external IP costs)

For questions or issues, see the main [README.md](../README.md) or run the analysis script:

```bash
./scripts/04-analyze-results.sh
```
