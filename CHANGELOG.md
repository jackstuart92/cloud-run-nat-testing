# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-02-04

### Added

- Initial release of Cloud Run NAT Testing Framework
- Support for up to 2000 Cloud Run services with per-service subnets
- Class E (240.0.0.0/12) addressing for Cloud Run services
- Private NAT translation to routable IPs (10.255.0.0/16)
- Bidirectional communication testing:
  - Cloud Run → VM (via Private NAT)
  - VM → Cloud Run (via Private Google Access)
- Multiple test modes: basic, roundtrip, scale, bulk, debug
- NAT rule configuration script for per-destination routing
- Comprehensive logging and analysis tools
- Full cleanup script

### Infrastructure Components

- 3 VPCs: serverless-vpc, workload-vpc-a, workload-vpc-b
- VPC peering with custom route export
- Private NAT with configurable port allocation
- Target VMs with Flask-based test server
- Firewall rules for NAT pool ingress

### Scripts

- `01-setup-infrastructure.sh` - Creates VPCs, NAT, VMs
- `02-deploy-services.sh` - Deploys Cloud Run services
- `03-run-tests.sh` - Executes connectivity tests
- `04-analyze-results.sh` - Analyzes NAT logs
- `99-cleanup.sh` - Removes all resources
- `configure-nat-rules.sh` - Configures NAT rules

### Documentation

- Comprehensive README with architecture diagrams
- Detailed architecture documentation
- Per-service NAT configuration guide
- NAT rules deep dive
- Subnet requirements and IP scaling calculations
