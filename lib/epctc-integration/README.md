# clsecure × EPCTC Testing Integration

This directory contains integration modules for running EPCTC tests within clsecure sandboxes.

## Overview

The testing integration provides:

- **Isolated Test Environments**: Each test suite runs in its own sandbox
- **Auto Risk Detection**: Tests automatically categorized by risk profile
- **Parallel Execution**: Run multiple test suites concurrently
- **Result Synchronization**: Automatic sync of test results from sandbox to host
- **Quality Gates**: Integration with EPCTC quality gates

## Files

| File | Description |
|------|-------------|
| `test-integration.sh` | Core integration library with risk detection, result sync, and quality gates |
| `clsecure-epctc-test` | Main wrapper script for running tests in sandbox |
| `clsecure-epctc-test-parallel` | Parallel test execution across multiple sandboxes |
| `epctc-test-enhanced` | Enhanced EPCTC test command with auto-isolation |
| `epctc-test-config.example` | Example configuration file |

## Quick Start

### 1. Basic Test Execution

```bash
# Run tests with auto-detected isolation
clsecure-epctc-test --test-type unit --auto-profile

# Run integration tests with network access
clsecure-epctc-test --test-type integration --allow-network

# Run E2E tests with Docker access
clsecure-epctc-test --test-type e2e --allow-network --allow-docker
```

### 2. Parallel Test Execution

```bash
# Run unit, integration, and e2e tests in parallel
clsecure-epctc-test-parallel --suites unit,integration,e2e --max-parallel 3

# Use custom configuration
clsecure-epctc-test-parallel --config my-test-config.json
```

### 3. Configuration File

Create `.clsecure/epctc-test-config`:

```ini
[test-risk-profiles]
tier_1_patterns = "test_*.py,*_test.go"
tier_1_isolation = "namespace"
tier_1_network = false

tier_3_patterns = "test_e2e*,cypress*"
tier_3_isolation = "namespace"
tier_3_network = true
tier_3_docker = true

[quality-gates]
test-coverage-threshold = 80
```

## Risk Profiles

| Tier | Patterns | Isolation | Network | Docker | Use Case |
|------|----------|-----------|---------|--------|----------|
| tier_1 | `test_*.py`, `*_test.go` | namespace | ✗ | ✗ | Unit tests |
| tier_2 | `test_integration*` | namespace | ✓ | ✗ | Integration tests |
| tier_3 | `test_e2e*`, `cypress*` | namespace | ✓ | ✓ | E2E tests |
| tier_4 | `test_security*`, `fuzz*` | namespace | ✗ | ✗ | Security tests |

## Integration with EPCTC

### Enhanced Test Command

Replace `/epctc-test` with the enhanced version in your `.claude/commands/epctc-test`:

```bash
#!/bin/bash
# Use enhanced test command with automatic isolation
exec epctc-test-enhanced "$@"
```

### Quality Gate Integration

Test results automatically update EPCTC quality gates:

```json
{
  "test-session-123": {
    "manifest": { ... },
    "summary": {
      "tests": 42,
      "failures": 0,
      "coverage": 85,
      "passed": true
    }
  }
}
```

## Test Result Structure

```
.clsecure/test-results/
└── {session-name}/
    ├── manifest.json      # Session metadata
    ├── summary.json       # Test summary
    ├── junit.xml          # JUnit test results
    ├── coverage/          # Coverage reports
    ├── clsecure.log       # Sandbox execution log
    └── artifacts/         # Additional artifacts
```

## Advanced Usage

### Custom Test Configuration

```json
{
  "test_suites": [
    {
      "type": "unit",
      "pattern": "tests/unit",
      "isolation": {
        "mode": "namespace",
        "network": false,
        "docker": false
      }
    },
    {
      "type": "security",
      "pattern": "tests/security",
      "isolation": {
        "mode": "namespace",
        "network": false,
        "docker": false,
        "readonly": true
      }
    }
  ]
}
```

### Programmatic Usage

```bash
source lib/epctc-integration/test-integration.sh

# Detect risk profile
PROFILE=$(detect_test_risk_profile "test_security_auth.py")
echo "Profile: $PROFILE"

# Get isolation config
CONFIG=$(get_isolation_for_profile "$PROFILE")
echo "Config: $CONFIG"

# Run parallel tests
TEST_CONFIGS='[
  {"type": "unit", "isolation": {"mode": "namespace"}},
  {"type": "e2e", "isolation": {"mode": "namespace", "network": true}}
]'
run_parallel_tests "$TEST_CONFIGS" 2
```

## Troubleshooting

### Check Test Sessions

```bash
clsecure-epctc-test --list-sessions
```

### View Session Logs

```bash
cat .clsecure/test-results/{session-name}/clsecure.log
```

### Cleanup Old Sessions

```bash
# Remove sessions older than 7 days
clsecure-epctc-test --cleanup 7
```

## Security Considerations

1. **Untrusted test code** runs in isolated sandboxes with no host access
2. **Network isolation** prevents test code from exfiltrating data
3. **Read-only mode** for security tests prevents filesystem modifications
4. **Ephemeral sandboxes** can be destroyed after test completion
5. **Audit trail** of all test executions with isolation metadata
