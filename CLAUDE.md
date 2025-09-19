# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

VMTags-v2.0 is a high-performance PowerShell automation system for managing vCenter VM tags and permissions at enterprise scale. The system processes thousands of VMs with parallel processing capabilities and provides 70-85% performance improvements over previous versions.

## Commands

### Primary Execution Commands

```powershell
# Using Launcher (Recommended)
.\VM_TagPermissions_Launcher.ps1 -Environment KLEB -UseStoredCredentials
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -UseStoredCredentials -ForceDebug

# Direct execution with parallel processing
.\Scripts\set-VMtagPermissions.ps1 -vCenterServer "vcenter.domain.com" -Environment "KLEB" -AppPermissionsCsvPath ".\Data\KLEB\AppTagPermissions_KLE.csv" -OsMappingCsvPath ".\Data\KLEB\OS-Mappings_KLE.csv" -CredentialPath "credentials.xml" -EnableParallelProcessing -MaxParallelThreads 8

# Dry run mode for testing
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -DryRun

# Aria Operations integration
.\Aria-VMTags-Wrapper.ps1 -Environment KLEB -EnableDebug
```

### Credential Management

```powershell
# List stored credentials
.\VM_TagPermissions_Launcher.ps1 -ListStoredCredentials

# Clean up expired credentials
.\VM_TagPermissions_Launcher.ps1 -CleanupExpiredCredentials

# Clear all credentials (requires confirmation)
.\VM_TagPermissions_Launcher.ps1 -ClearAllCredentials
```

## Architecture

### Core Components

**Launcher Architecture:**
- `VM_TagPermissions_Launcher.ps1`: Enhanced launcher with credential management and environment-specific configuration
- `ConfigFiles/VMTagsConfig.psd1`: Centralized configuration with environment-specific settings, parallel processing parameters, and security policies

**Main Processing Engine:**
- `Scripts/set-VMtagPermissions.ps1`: Core script with advanced parallel processing, thread-safe logging, and intelligent batch strategies
- `Aria-VMTags-Wrapper.ps1`: Aria Operations integration wrapper for enterprise monitoring

### Parallel Processing Architecture

**Thread-Safe Design:**
- Mutex-synchronized logging prevents concurrent write conflicts
- Concurrent collections (ConcurrentQueue, ConcurrentBag) for thread-safe VM processing
- Background progress reporting with real-time performance metrics

**Intelligent Batch Strategies:**
- **RoundRobin**: Sequential distribution across threads
- **PowerStateBalanced**: Balances powered on/off VMs across threads
- **ComplexityBalanced**: Distributes VMs based on complexity scoring (tags, permissions, etc.)

**Performance Features:**
- Configurable thread counts (1-10) with environment-specific optimization
- Real-time progress tracking with comprehensive performance analytics
- Exponential backoff retry logic for robust error handling
- Memory-optimized concurrent collections for enterprise-scale inventories

### Configuration Management

**Environment-Specific Settings:**
- DEV: 4 threads, RoundRobin strategy, relaxed security, extended credential expiry
- PROD: 8 threads, ComplexityBalanced strategy, strict security, short credential expiry
- KLEB: 6 threads, PowerStateBalanced strategy, balanced security settings
- OT: 4 threads, RoundRobin strategy, most restrictive security (no stored credentials)

**Security Architecture:**
- Per-environment credential policies with automatic expiration
- Encrypted credential storage with AES256 encryption
- Comprehensive audit logging for compliance requirements
- File permission management for sensitive data protection

### Data Processing Flow

1. **Environment Detection**: Launcher loads environment-specific configuration from VMTagsConfig.psd1
2. **Credential Management**: Retrieves stored credentials or prompts for new ones based on environment policy
3. **Parallel Processing**: Distributes VMs across threads using selected batch strategy
4. **Tag Assignment**: Applies OS tags based on guest OS pattern matching from CSV configurations
5. **Permission Management**: Assigns application team permissions based on CSV mappings
6. **Reporting**: Generates comprehensive CSV reports with performance metrics and error analysis

### CSV Configuration Architecture

**Application Permissions CSV Structure:**
- Maps application teams to specific VM tags, roles, and security groups
- Supports complex role-based access control (RBAC) scenarios
- Environment-specific tag categories (vCenter-DEV-App-team, vCenter-PROD-App-team, etc.)

**OS Mapping CSV Structure:**
- Guest OS pattern matching with regex support
- Automatic OS tag assignment based on detected operating system
- Role and security group mapping per OS type
- Special handling for domain controllers (ReadOnly permissions)

## Development Guidelines

### PowerShell Script Development

- All scripts accept a `-LogPath` parameter for centralized logging
- Use structured error handling with try/catch blocks and exponential backoff
- Output data as JSON for consumption by external systems
- Include proper connection cleanup in finally blocks
- Follow thread-safe programming patterns for parallel processing scenarios

### Configuration Updates

Environment settings are managed in `ConfigFiles/VMTagsConfig.psd1`:
```powershell
Settings = @{
    EnableParallelProcessing = $true
    MaxParallelThreads = 6
    BatchStrategy = "PowerStateBalanced"
    EnableProgressTracking = $true
    EnableErrorHandling = $true
    RetryDelaySeconds = 2
    MaxOperationRetries = 3
}
```

### Security Requirements

- Never commit organizational CSV files from `/Data/` directories
- All credential files in `/Credentials/` are git-ignored
- Log files in `/Logs/` and reports in `/Reports/` are excluded from version control
- Use SecureString for password handling where possible
- Validate all PowerCLI module requirements before script execution

## Project Structure

```
VMTags-v2.0/
├── VM_TagPermissions_Launcher.ps1     # Enhanced launcher with credential management
├── Scripts/set-VMtagPermissions.ps1   # Main processing engine with parallel capabilities
├── Aria-VMTags-Wrapper.ps1           # Aria Operations integration wrapper
├── ConfigFiles/VMTagsConfig.psd1     # Centralized configuration management
├── Data/[ENV]/                       # Environment-specific CSV files (git-ignored)
├── Logs/                             # Execution logs (git-ignored)
├── Reports/                          # Generated CSV reports (git-ignored)
├── Credentials/                      # Stored authentication files (git-ignored)
└── Backup/                          # Configuration backups (git-ignored)
```

## Environment-Specific Behavior

### Performance Optimization per Environment

| Environment | Threads | Strategy | Batch Size | Security Level |
|-------------|---------|----------|------------|----------------|
| DEV | 4 | RoundRobin | 50 | Relaxed (testing) |
| PROD | 8 | ComplexityBalanced | 100 | Strict (enterprise) |
| KLEB | 6 | PowerStateBalanced | 75 | Balanced (mixed workload) |
| OT | 4 | RoundRobin | 50 | Maximum (no stored creds) |

### PowerCLI Configuration per Environment

- **DEV**: Certificate validation disabled, faster timeouts for development
- **PROD/KLEB**: Certificate warnings enabled, longer timeouts for reliability
- **OT**: Certificate validation required, maximum security settings

### Credential Management Policies

- **DEV**: Auto-store credentials, 60-day expiry, validation disabled for speed
- **PROD**: Manual credential approval, 14-day expiry, mandatory validation
- **KLEB**: Balanced security, 21-day expiry, validation enabled
- **OT**: No stored credentials allowed, interactive authentication required

## Common Operations

### Testing and Validation
```powershell
# Test configuration and connectivity
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -DryRun -ForceDebug

# Validate CSV files and environment settings
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -ForceDebug
```

### High-Performance Execution
```powershell
# Enterprise-scale parallel processing
.\Scripts\set-VMtagPermissions.ps1 -vCenterServer "vcenter.domain.com" -Environment "PROD" -EnableParallelProcessing -MaxParallelThreads 10 -BatchStrategy "ComplexityBalanced" -EnableProgressTracking -EnableErrorHandling
```

### Monitoring and Maintenance
```powershell
# Review stored credentials
.\VM_TagPermissions_Launcher.ps1 -ListStoredCredentials

# Clean up expired credentials
.\VM_TagPermissions_Launcher.ps1 -CleanupExpiredCredentials
```

## Integration Notes

### Aria Operations Integration
The system includes native Aria Operations integration through `Aria-VMTags-Wrapper.ps1` for enterprise monitoring and alerting. Logs are formatted in Aria-compatible JSON structure for seamless SIEM integration.

### PowerCLI Requirements
- VMware PowerCLI 13.0+ required
- PowerShell 7.0+ for optimal parallel processing performance
- Minimum 4GB RAM recommended for parallel processing scenarios
- Multi-core processor recommended for thread-based operations