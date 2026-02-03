# Contributing to Cloud Run NAT Testing Framework

First off, thank you for considering contributing to this project! 🎉

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
  - [Reporting Bugs](#reporting-bugs)
  - [Suggesting Enhancements](#suggesting-enhancements)
  - [Pull Requests](#pull-requests)
- [Development Setup](#development-setup)
- [Style Guidelines](#style-guidelines)
- [Testing](#testing)

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include as many details as possible:

**Bug Report Template:**

```markdown
**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Run command '...'
2. See error

**Expected behavior**
A clear description of what you expected to happen.

**Environment:**
- OS: [e.g., Ubuntu 22.04, macOS 14, Windows 11]
- gcloud version: [e.g., 450.0.0]
- GCP Region: [e.g., us-central1]
- Number of services deployed: [e.g., 100]

**Additional context**
Add any other context, logs, or screenshots.
```

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- Use a clear and descriptive title
- Provide a detailed description of the suggested enhancement
- Explain why this enhancement would be useful
- List any alternatives you've considered

### Pull Requests

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests to ensure nothing is broken
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

**Pull Request Guidelines:**

- Follow the existing code style
- Update documentation as needed
- Add tests for new functionality
- Keep PRs focused - one feature/fix per PR
- Write clear commit messages

## Development Setup

### Prerequisites

- Google Cloud SDK (`gcloud`) version 400.0.0 or later
- A GCP project with billing enabled
- `bash` shell (or Git Bash on Windows)
- `jq` for JSON processing
- Docker (for building container images locally)

### Local Setup

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/cloud-run-nat-testing.git
cd cloud-run-nat-testing

# Copy and configure environment
cp config.env config.local.env
# Edit config.local.env with your settings

# Make scripts executable
chmod +x scripts/*.sh

# Verify gcloud is configured
gcloud auth list
gcloud config list
```

### Testing Changes Locally

Before submitting a PR, test your changes:

```bash
# Set a small scale for testing
export NUM_SERVICES=5

# Run infrastructure setup
./scripts/01-setup-infrastructure.sh

# Deploy test services
./scripts/02-deploy-services.sh --count 5

# Run tests
./scripts/03-run-tests.sh --test basic

# Clean up
./scripts/99-cleanup.sh
```

## Style Guidelines

### Shell Scripts

- Use `#!/bin/bash` shebang
- Use `set -e` to exit on errors
- Quote variables: `"${VAR}"` not `$VAR`
- Use lowercase for local variables, UPPERCASE for exports
- Add comments for complex logic
- Follow [Google's Shell Style Guide](https://google.github.io/styleguide/shellguide.html)

```bash
# Good
local service_name="${1}"
echo "Deploying ${service_name}..."

# Bad
service_name=$1
echo "Deploying $service_name..."
```

### Python Code

- Follow [PEP 8](https://pep8.org/) style guide
- Use type hints where appropriate
- Add docstrings to functions and classes
- Keep functions focused and small

```python
# Good
def get_service_url(service_name: str, region: str) -> str:
    """Get the Cloud Run service URL.
    
    Args:
        service_name: Name of the Cloud Run service
        region: GCP region
        
    Returns:
        The service URL
    """
    return f"https://{service_name}-xxx.{region}.run.app"
```

### Documentation

- Use clear, concise language
- Include code examples where helpful
- Keep ASCII diagrams aligned and readable
- Update the README when adding features

## Testing

### Test Categories

1. **Unit Tests**: Test individual functions (Python code)
2. **Integration Tests**: Test script execution
3. **End-to-End Tests**: Full deployment and connectivity tests

### Running Tests

```bash
# Basic connectivity test
./scripts/03-run-tests.sh --test basic --services 5

# Full test suite
./scripts/03-run-tests.sh --test all --services 10

# Analyze results
./scripts/04-analyze-results.sh
```

### Adding New Tests

When adding new test scenarios:

1. Add the test function to `scripts/03-run-tests.sh`
2. Document the test in README.md
3. Include expected results and failure conditions

## Questions?

Feel free to open an issue for any questions about contributing!
