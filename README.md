<<<<<<< HEAD
# VMTags
Repository for VMTags project
=======
# VMTags 2.0 - High-Performance vCenter VM Tags & Permissions Management

![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)
![VMware](https://img.shields.io/badge/VMware-vCenter%208.0+-green.svg)

## 🚀 Version 2.0 Features

**VMTags 2.0** is a high-performance rewrite of the VM tags and permissions management system, designed for large-scale vCenter environments with hundreds or thousands of VMs.

### ⚡ Performance Enhancements
- **Parallel Processing**: Multi-threaded VM processing using PowerShell runspaces
- **Batch Operations**: Intelligent batching of VM operations for optimal performance
- **Configurable Threads**: 1-10 parallel threads (default: 4)
- **Scalable Batching**: 10-500 VMs per batch (default: 50)

### 🎯 Core Capabilities
- **Automated OS Tag Assignment**: Intelligent OS detection and tagging
- **Application Team Permissions**: CSV-driven permission management
- **Domain Controller Handling**: Special ReadOnly permissions for DCs
- **Comprehensive Reporting**: Detailed CSV reports and analytics
- **Multi-Environment Support**: DEV, PROD, KLEB, OT configurations

### 🔧 Enhanced Features
- **Thread-Safe Logging**: Concurrent operation logging without conflicts
- **Real-Time Progress**: Live progress tracking with performance metrics
- **Enhanced Error Handling**: Robust error recovery and reporting
- **Inherited Permission Detection**: Smart handling of folder-inherited permissions

## 📋 Requirements

- **PowerShell 7.0+** (PowerShell Core)
- **VMware PowerCLI 13.0+**
- **vCenter Server 8.0+** (compatible with 7.x)
- **Windows Server 2019+** or **Windows 10/11**
- **Appropriate vCenter Permissions**: 
  - Tag management
  - Permission assignment
  - VM inventory access

## 🚦 Quick Start

### 1. Basic Execution
```powershell
.\set-VMtagPermissions.ps1 -vCenterServer "vcenter.domain.com" -Environment "KLEB" -AppPermissionsCsvPath ".\Data\KLEB\AppTagPermissions_KLE.csv" -OsMappingCsvPath ".\Data\KLEB\OS-Mappings_KLE.csv" -CredentialPath "C:\secure\credentials.xml"
```

### 2. High-Performance Mode
```powershell
.\set-VMtagPermissions.ps1 -vCenterServer "vcenter.domain.com" -Environment "KLEB" -AppPermissionsCsvPath ".\Data\KLEB\AppTagPermissions_KLE.csv" -OsMappingCsvPath ".\Data\KLEB\OS-Mappings_KLE.csv" -CredentialPath "C:\secure\credentials.xml" -MaxParallelThreads 8 -BatchSize 100
```

### 3. Using Launcher (Recommended)
```powershell
.\VM_TagPermissions_Launcher.ps1 -Environment KLEB -UseStoredCredentials
```

## ⚙️ Configuration

### Parallel Processing Parameters
- **MaxParallelThreads**: 1-10 threads (default: 4)
  - 1-2: Low resource usage
  - 4-6: Balanced performance
  - 8-10: Maximum performance (high CPU/memory)

- **BatchSize**: 10-500 VMs per batch (default: 50)
  - 10-25: Conservative batching
  - 50-100: Balanced batching
  - 200-500: Aggressive batching

### Environment Configuration
Edit `ConfigFiles/VMTagsConfig.psd1` for environment-specific settings:
- vCenter server endpoints
- Tag category names
- Credential storage locations
- Logging preferences

## 📁 Directory Structure
```
VMTags-v2.0/
├── set-VMtagPermissions.ps1      # Main script
├── VM_TagPermissions_Launcher.ps1 # Launcher script
├── Aria-VMTags-Wrapper.ps1       # Aria Operations wrapper
├── Data/
│   ├── KLEB/                     # KLEB environment data
│   ├── DEV/                      # DEV environment data
│   └── PROD/                     # PROD environment data
├── ConfigFiles/
│   └── VMTagsConfig.psd1         # Configuration file
├── Reports/                      # Generated CSV reports
├── Logs/                         # Execution logs
└── Temp/                         # Temporary files
```

## 📊 Performance Metrics

### Version 1.0 vs 2.0 Comparison
| Metric | v1.0 | v2.0 | Improvement |
|--------|------|------|-------------|
| 100 VMs | ~15 min | ~4 min | **73% faster** |
| 500 VMs | ~75 min | ~12 min | **84% faster** |
| 1000 VMs | ~150 min | ~20 min | **87% faster** |

*Performance results may vary based on vCenter performance, network latency, and system resources.*

## 🔍 CSV File Formats

### Application Permissions CSV
```csv
TagCategory,TagType,TagName,RoleName,SecurityGroupDomain,SecurityGroupName
vCenter-Kleber-App-team,App-team,Exchange-admins,Enterprise Exchange Team,DLA-Kleber.local,Directory Services Exchange Team
vCenter-Kleber-App-team,App-team,ACAS-Admins,ACAS-Admin-Team,DLA-Kleber.local,ACAS Administrators
```

### OS Mappings CSV
```csv
GuestOSPattern,TargetTagName,SecurityGroupName,RoleName,TagType,SecurityGroupDomain
Microsoft Windows Server 2022.*,Windows-server,Windows Server Team,Windows Server Team,OS,DLA-Kleber.local
Microsoft Windows Server 2019.*,Windows-server,Windows Server Team,Windows Server Team,OS,DLA-Kleber.local
Red Hat Enterprise Linux 9.*,RHEL,Unix Server Admins,Unix Server Team,OS,DLA-Kleber.local
```

## 🛠️ Troubleshooting

### Common Issues

1. **PowerCLI Connection Issues**
   - Ensure PowerCLI 13.0+ is installed
   - Verify vCenter connectivity on port 443
   - Check credential validity

2. **Performance Issues**
   - Reduce `MaxParallelThreads` if experiencing high resource usage
   - Adjust `BatchSize` based on vCenter performance
   - Monitor vCenter CPU and memory during execution

3. **Permission Assignment Failures**
   - Check for inherited permissions (highlighted in logs)
   - Verify security group existence in SSO domain
   - Ensure proper vCenter permissions for the executing user

### Debug Mode
Enable detailed logging:
```powershell
.\set-VMtagPermissions.ps1 [...] -EnableScriptDebug
```

## 📈 Monitoring & Reports

### Generated Reports
- **PermissionAssignmentResults**: Detailed permission assignment results
- **ExecutionSummary**: High-level execution statistics
- **VMsWithOnlyInheritedPermissions**: VMs with folder-inherited permissions
- **VMsNeedingAttention**: VMs requiring manual review

### Log Locations
- **Execution Logs**: `.\Logs\VMTags_[Environment]_[Timestamp].log`
- **CSV Reports**: `.\Reports\[Environment]\[ReportName]_[Timestamp].csv`

## 🔄 Upgrade from Version 1.0

VMTags 2.0 is fully backward compatible with v1.0 configurations:
1. Copy your existing CSV files to the `Data/` directory
2. Update `ConfigFiles/VMTagsConfig.psd1` if needed
3. Run using the same parameters as v1.0

New v2.0 parameters are optional and use sensible defaults.

## 📝 Version History

### Version 2.0.0
- ✨ **NEW**: Parallel processing with configurable thread count
- ✨ **NEW**: Batch processing for large VM inventories
- ✨ **NEW**: Real-time progress tracking and performance metrics
- ✨ **NEW**: Thread-safe logging system
- 🔧 **IMPROVED**: Enhanced error handling and recovery
- 🔧 **IMPROVED**: Optimized PowerCLI operations

### Version 1.0.0
- ✅ Stable production release
- ✅ Core VM tagging and permission functionality
- ✅ CSV-driven configuration
- ✅ Multi-environment support

## 🤝 Contributing

This project is part of the vCenter Migration Tool suite. For issues, feature requests, or contributions, please follow the established development practices.

## 📄 License

Internal use only - DLA vCenter Migration Project

---

*VMTags 2.0 - Built for Performance, Designed for Scale*
>>>>>>> aa6ed84 (Initial commit - VMTags 2.0 High-Performance Edition)
