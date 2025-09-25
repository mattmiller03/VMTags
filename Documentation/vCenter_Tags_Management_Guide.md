# vCenter Tags Management Guide

## Overview

This guide provides comprehensive instructions for managing VM tags and permissions in vCenter using the VMTags-v2.0 automation system. This system provides high-performance parallel processing capabilities for enterprise-scale tag management.

## Quick Start

### Prerequisites

- VMware PowerCLI 13.0+
- PowerShell 7.0+
- vCenter access with appropriate permissions
- Minimum 4GB RAM (recommended for parallel processing)

### Basic Execution

```powershell
# Using the launcher (recommended approach)
.\VM_TagPermissions_Launcher.ps1 -Environment [DEV|PROD|KLEB|OT] -UseStoredCredentials

# Dry run for testing
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -DryRun

# With debug logging
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -UseStoredCredentials -ForceDebug
```

## Environment Configuration

### Available Environments

| Environment | Threads | Strategy | Security Level | Use Case |
|-------------|---------|----------|----------------|----------|
| **DEV** | 4 | RoundRobin | Relaxed | Development/Testing |
| **PROD** | 8 | ComplexityBalanced | Strict | Production |
| **KLEB** | 6 | PowerStateBalanced | Balanced | Mixed workloads |
| **OT** | 4 | RoundRobin | Maximum | Operational Technology |

### Environment Selection Guidelines

- **DEV**: Use for testing configurations and new CSV files
- **PROD**: Production environment with maximum performance
- **KLEB**: Balanced approach for mixed infrastructure
- **OT**: High security, no credential storage allowed

## Credential Management

### Stored Credentials

```powershell
# List current stored credentials
.\VM_TagPermissions_Launcher.ps1 -ListStoredCredentials

# Clean expired credentials
.\VM_TagPermissions_Launcher.ps1 -CleanupExpiredCredentials

# Clear all credentials (requires confirmation)
.\VM_TagPermissions_Launcher.ps1 -ClearAllCredentials
```

### Credential Policies by Environment

- **DEV**: 60-day expiry, auto-store enabled
- **PROD**: 14-day expiry, manual approval required
- **KLEB**: 21-day expiry, balanced security
- **OT**: No stored credentials, interactive only

## CSV Configuration Files

### Application Permissions CSV

Location: `Data/[ENVIRONMENT]/AppTagPermissions_[ENV].csv`

**Required Columns:**
- `TagName`: VM tag identifier
- `TeamName`: Application team name
- `Role`: vCenter role (ReadOnly, Operator, etc.)
- `SecurityGroup`: AD security group
- `Environment`: Target environment

**Example:**
```csv
TagName,TeamName,Role,SecurityGroup,Environment
vCenter-PROD-App-WebTeam,Web Team,Operator,AD-WebTeam-Ops,PROD
vCenter-PROD-App-DBTeam,Database Team,ReadOnly,AD-DBTeam-Viewers,PROD
```

### OS Mapping CSV

Location: `Data/[ENVIRONMENT]/OS-Mappings_[ENV].csv`

**Required Columns:**
- `OSPattern`: Guest OS pattern (regex supported)
- `OSTag`: OS tag to assign
- `DefaultRole`: Default role for OS type
- `SecurityGroup`: Default security group

**Example:**
```csv
OSPattern,OSTag,DefaultRole,SecurityGroup
*Windows Server 2019*,Windows-2019,Operator,AD-Windows-Admins
*Ubuntu*,Linux-Ubuntu,ReadOnly,AD-Linux-Users
*Domain Controller*,Windows-DC,ReadOnly,AD-DC-Viewers
```

## Performance Optimization

### Parallel Processing Settings

Configure in `ConfigFiles/VMTagsConfig.psd1`:

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

### Batch Strategies

- **RoundRobin**: Sequential distribution across threads
- **PowerStateBalanced**: Balances powered on/off VMs
- **ComplexityBalanced**: Distributes based on VM complexity

### Thread Count Guidelines

- **Small environments** (< 500 VMs): 2-4 threads
- **Medium environments** (500-2000 VMs): 4-6 threads
- **Large environments** (> 2000 VMs): 6-10 threads

## Advanced Features

### Hierarchical Tag Inheritance

Enable automatic tag inheritance from folder/resource pool hierarchies:

```powershell
.\Scripts\set-VMtagPermissions.ps1 -EnableHierarchicalInheritance -InheritanceCategories "App,Function"
```

### Multi-vCenter Enhanced Linked Mode

Test connectivity across multiple vCenters:

```powershell
.\Test-MultiVCenter.ps1 -Environment KLEB -TestConnectivity
```

### Aria Operations Integration

For enterprise monitoring:

```powershell
.\Aria-VMTags-Wrapper.ps1 -Environment KLEB -EnableDebug
```

## Monitoring and Reporting

### Log Files

Logs are automatically generated in `Logs/` directory:
- Execution logs with timestamps
- Error logs with stack traces
- Performance metrics and timing data

### CSV Reports

Generated reports in `Reports/` directory include:
- VM processing results
- Tag assignment status
- Permission changes
- Performance analytics

### Real-time Monitoring

Enable progress tracking for live monitoring:
```powershell
-EnableProgressTracking
```

## Troubleshooting

### Common Issues

**Connection Failures:**
- Verify PowerCLI module installation
- Check network connectivity to vCenter
- Validate stored credentials

**Performance Issues:**
- Reduce thread count for stability
- Check available system memory
- Review vCenter resource utilization

**Permission Errors:**
- Verify vCenter role assignments
- Check CSV file permissions mapping
- Validate security group membership

### Debug Mode

Enable comprehensive logging:
```powershell
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -ForceDebug
```

### Validation Testing

Test configurations without making changes:
```powershell
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -DryRun
```

## Security Best Practices

### Data Protection

- Never commit CSV files to version control
- Store credentials in encrypted format only
- Use least privilege access principles
- Regularly rotate stored credentials

### File Permissions

Ensure proper permissions on:
- `/Data/` directories (CSV files)
- `/Credentials/` directory (encrypted credentials)
- `/Logs/` directory (execution logs)

### Network Security

- Use encrypted connections to vCenter
- Enable certificate validation in production
- Implement network segmentation where possible

## Automation Integration

### CI/CD Pipeline Integration

For automated execution:
```powershell
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -AutomationMode
```

### Scheduled Execution

Configure Windows Task Scheduler or cron jobs for regular execution with appropriate environment and security settings.

## Support and Maintenance

### Regular Maintenance Tasks

1. **Weekly**: Review execution logs for errors
2. **Monthly**: Clean expired credentials
3. **Quarterly**: Update CSV configurations
4. **Semi-annually**: Review and update security policies

### Performance Monitoring

Monitor key metrics:
- Execution time per environment
- Thread utilization efficiency
- Error rates and retry statistics
- Memory and CPU usage patterns

### Configuration Updates

When updating CSV files:
1. Test in DEV environment first
2. Validate with dry run mode
3. Review logs for any issues
4. Deploy to production with monitoring

## Contact Information

For technical support or questions about this system, contact:
- Systems Administration Team
- VMware Infrastructure Team
- Security Team (for permission-related issues)

## Version History

- v2.0: High-performance parallel processing implementation
- v1.0: Original single-threaded implementation

---

*This document should be reviewed and updated quarterly to reflect any changes in environment configuration or organizational requirements.*