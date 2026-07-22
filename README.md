# Power Automate Connection Health Checker

## Overview
This PowerShell script proactively monitors Power Automate connections across all environments to identify broken, expired, or expiring connections **before** they cause flow failures. It provides comprehensive health status, flow impact assessment, and actionable recommendations.

## Why Use This Tool?

### Proactive vs. Reactive
- **Prevents failures** rather than just reporting them
- **Identifies issues early** before users experience problems
- **Maps connection impact** to understand blast radius
- **Saves time** by catching problems during maintenance windows

### Complements Flow Failure Checker
This tool works alongside the Flow Failure Checker:
- **Connection Health Checker**: Preventive maintenance (use weekly/monthly)
- **Flow Failure Checker**: Incident response (use daily)

## Prerequisites

1. **PowerShell 5.1 or later** (PowerShell 7+ recommended)
2. **Power Platform Administrator access** or appropriate permissions
3. **Internet connection** to connect to Power Platform
4. **Permissions to view**:
   - Environments
   - Connections
   - Flows (for impact assessment)

## Installation

The script will automatically install required modules if they're missing:
- `Microsoft.PowerApps.Administration.PowerShell`
- `Microsoft.PowerApps.PowerShell`

Or install them manually beforehand:

```powershell
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
Install-Module -Name Microsoft.PowerApps.PowerShell -Scope CurrentUser
```

## Usage

### Basic Usage
```powershell
.\check_connection_health.ps1
```
Checks all connections and warns about those expiring within 30 days.

### Custom Expiration Threshold
```powershell
# Warn about connections expiring in 60 days
.\check_connection_health.ps1 -DaysUntilExpiration 60

# Warn about connections expiring in 7 days (weekly check)
.\check_connection_health.ps1 -DaysUntilExpiration 7
```

### Include Orphaned Connections
```powershell
# Show connections not used by any flow
.\check_connection_health.ps1 -IncludeOrphaned
```

### Combined Parameters
```powershell
.\check_connection_health.ps1 -DaysUntilExpiration 60 -IncludeOrphaned
```

## What the Script Does

### 1. Connection Discovery
- Scans all Power Platform environments you have access to
- Retrieves all connections in each environment
- Identifies connection type (SharePoint, SQL, Teams, etc.)

### 2. Health Status Assessment
Categorizes each connection:
- **[OK] Healthy**: Connection is working properly
- **[WARN] Expiring Soon**: May expire within your threshold (default: 30 days)
- **[FAIL] Broken**: Connection has errors or has expired
- **[AUTH] Unauthorized**: Authentication failed or permissions revoked
- **[?] Unknown**: Unable to determine status

### 3. Flow Impact Analysis
- Identifies which flows use each connection
- Calculates "blast radius" (how many flows affected)
- Prioritizes critical connections (broken + high usage)

### 4. Reporting
- Real-time progress bars for environments and connections
- Color-coded console output for quick scanning
- Detailed tables for problematic connections
- CSV exports for tracking and trending

### 5. Recommendations
Provides actionable next steps based on findings:
- Immediate actions for broken connections
- Preventive maintenance for expiring connections
- Connection refresh procedures

## Output

### Console Output
```
=== Power Automate Connection Health Checker ===
Checking connections across all environments
Warning threshold: Connections expiring within 30 days

Processing Environment: Production
  Found 15 connection(s)
  [OK] SharePoint Connection (sharepointonline) - 8 flow(s)
  [FAIL] SQL Server Connection (sql) - 3 flow(s) - Authentication required or permissions revoked
  [WARN] OneDrive Connection (onedrive) - 2 flow(s) - Connection may expire soon (created 75 days ago)
  [OK] Teams Connection (teams) - 5 flow(s)

=== Summary ===
Total Environments Checked: 3
Total Connections Found: 45
Healthy Connections: 38
Expiring Soon: 4
Broken/Expired: 2
Unauthorized: 1
Orphaned (Not Shown): 5 (use -IncludeOrphaned to show)

=== CRITICAL: Broken Connections Impacting Flows ===
Environment    ConnectionName              ConnectorName  FlowsUsing  Message
-----------    --------------              -------------  ----------  -------
Production     SQL Server Connection       sql            3           Authentication required or permissions revoked
Production     Legacy API Connection       custom         2           Connection error detected
```

### CSV Exports

Three CSV files are automatically created with timestamps:

#### 1. `ConnectionHealth_YYYYMMDD_HHMMSS.csv`
Full health report with all connections:
- Environment details
- Connection name and ID
- Connector type
- Health status and priority
- Created date and created by
- Number of flows using connection
- Orphaned status
- Health message

#### 2. `BrokenConnections_YYYYMMDD_HHMMSS.csv`
**Critical issues only** - broken/unauthorized connections affecting flows:
- Focuses on immediate action items
- Prioritized by number of flows impacted
- Use for incident response

#### 3. `ConnectionFlowMapping_YYYYMMDD_HHMMSS.csv`
Detailed connection-to-flow relationships:
- Maps each connection to every flow using it
- Shows flow enabled status
- Useful for impact analysis
- Helps identify which flows to test after fixing connections

## Health Status Definitions

### Healthy
- Connection is authenticated and working
- No known issues
- **Action**: None required

### Expiring Soon
- Connection may expire within your threshold
- Based on creation date (OAuth tokens often expire after 90 days)
- **Action**: Schedule time to refresh during maintenance window

### Broken/Possibly Expired
- Connection has error status
- Connection is very old (>90 days) and may need refresh
- **Action**: Re-authenticate immediately if flows are affected

### Unauthorized
- Authentication failed
- Permissions may have been revoked
- Account may be disabled
- **Action**: Verify account status and re-authenticate

### Orphaned
- Connection exists but no flows use it
- **Action**: Consider removing to reduce management overhead

## Use Cases

### Weekly Maintenance Check
```powershell
# Check for connections expiring in the next 7 days
.\check_connection_health.ps1 -DaysUntilExpiration 7
```
Review the report and schedule time to refresh expiring connections.

### Monthly Comprehensive Audit
```powershell
# Include orphaned connections for cleanup
.\check_connection_health.ps1 -DaysUntilExpiration 30 -IncludeOrphaned
```
Full audit including unused connections for housekeeping.

### Pre-Migration Assessment
```powershell
# Long-range view before major changes
.\check_connection_health.ps1 -DaysUntilExpiration 90
```
Understand connection landscape before environment migrations.

### Incident Response
```powershell
# Quick check when flows are failing
.\check_connection_health.ps1
```
Identify if connection issues are causing widespread failures.

## Best Practices

### Scheduling
1. **Weekly**: Quick check with 7-day threshold
2. **Monthly**: Comprehensive audit with 30-day threshold
3. **After incidents**: Immediate check when failures occur
4. **Before changes**: Pre-check before major updates

### Connection Management
1. **Service Principals**: Use for production connections that need long-term stability
2. **Documentation**: Keep connection refresh procedures documented
3. **Ownership**: Assign connection owners for each environment
4. **Monitoring**: Track trends using CSV exports over time

### Remediation Priority
1. **Critical**: Broken connections with high flow usage
2. **High**: Unauthorized connections affecting enabled flows
3. **Medium**: Expiring connections with moderate usage
4. **Low**: Orphaned connections (cleanup when time allows)

## Interpreting Results

### High-Impact Scenarios

#### Scenario 1: Broken Connection, Many Flows
```
[FAIL] SharePoint Connection (sharepointonline) - 15 flow(s)
```
**Impact**: 15 flows will fail
**Urgency**: Immediate
**Action**: Re-authenticate connection, test critical flows

#### Scenario 2: Expiring Connection, Critical Flow
```
[WARN] SQL Connection (sql) - 1 flow(s) - Connection may expire soon (created 80 days ago)
```
**Impact**: 1 flow at risk
**Urgency**: Schedule during maintenance
**Action**: Refresh connection within next week

#### Scenario 3: Healthy Connection, No Issues
```
[OK] Teams Connection (teams) - 5 flow(s)
```
**Impact**: None
**Urgency**: None
**Action**: Continue monitoring

## Troubleshooting

### PowerShell Execution Policy Error
If you get this error when trying to run the script:
```
.\check_connection_health.ps1 : File C:\...\check_connection_health.ps1 cannot be loaded.
The file C:\...\check_connection_health.ps1 is not digitally signed. You cannot run this
script on the current system. For more information about running scripts and setting
execution policy, see about_Execution_Policies at https:/go.microsoft.com/fwlink/?LinkID=135170.
```

**Quick Fix (Current Session Only)**:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\check_connection_health.ps1
```
This bypasses the execution policy **only for your current PowerShell session**. When you close PowerShell, the policy reverts to its original setting.

**Permanent Fix (Recommended)**:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
This allows locally created scripts to run while still requiring downloaded scripts to be signed. This is a good balance between security and usability.

**Why This Happens**:
Windows PowerShell has security policies that prevent unsigned scripts from running. Since this script is not digitally signed, Windows blocks it by default.

**Security Note**:
- `Bypass`: No restrictions; all scripts run (use temporarily for testing)
- `RemoteSigned`: Local scripts run freely, downloaded scripts must be signed (recommended)
- `Unrestricted`: Similar to Bypass but prompts for downloaded scripts
- Never use `Set-ExecutionPolicy` with `-Scope LocalMachine` unless you're an administrator managing the entire system

### Authentication Issues
If you get authentication errors:
```powershell
# Clear cached credentials and re-authenticate
Add-PowerAppsAccount -Endpoint "prod"
```

### Module Installation Issues
Run PowerShell as Administrator:
```powershell
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Force -AllowClobber
Install-Module -Name Microsoft.PowerApps.PowerShell -Force -AllowClobber
```

### Slow Execution
For large tenants with many environments:
- Script may take 10-30 minutes
- Progress bars show real-time status
- API throttling is handled automatically with retries

### Missing Connections
If connections don't appear:
- Verify you have admin access to the environment
- Check if connections are in a different environment
- Ensure you have permissions to view connections

### API Throttling
The script includes automatic retry logic:
- 3 retries with exponential backoff
- 2s, 4s, 8s delays between retries
- Handles transient API failures gracefully

## Comparison: Connection Health vs. Flow Failure Checker

| Aspect | Connection Health Checker | Flow Failure Checker |
|--------|--------------------------|---------------------|
| **Purpose** | Preventive maintenance | Incident response |
| **Timing** | Before failures occur | After failures occur |
| **Focus** | Connection authentication | Flow run history |
| **Frequency** | Weekly/Monthly | Daily |
| **Value** | Prevents downtime | Identifies problems |
| **Scope** | All connections | Failed flow runs |
| **Use Case** | Proactive monitoring | Reactive troubleshooting |

## Advanced Usage

### Automated Scheduled Monitoring
Create a scheduled task to run weekly:
```powershell
# Create a scheduled task (Windows Task Scheduler)
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-File C:\Scripts\check_connection_health.ps1 -DaysUntilExpiration 7"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9am
Register-ScheduledTask -TaskName "Weekly Connection Health Check" `
    -Action $action -Trigger $trigger
```

### Email Reports
Combine with PowerShell email functionality:
```powershell
.\check_connection_health.ps1 | Out-File -FilePath "ConnectionReport.txt"
Send-MailMessage -To "admin@company.com" `
    -From "automation@company.com" `
    -Subject "Weekly Connection Health Report" `
    -Body (Get-Content "ConnectionReport.txt" -Raw) `
    -SmtpServer "smtp.company.com"
```

### Filtering Results
Filter CSV exports for specific scenarios:
```powershell
# Import and filter for high-priority issues
$report = Import-Csv "ConnectionHealth_20251012_143022.csv"
$critical = $report | Where-Object { $_.Status -eq "Broken" -and $_.FlowsUsing -gt 5 }
$critical | Format-Table
```

### Integration with Monitoring Tools
Export to JSON for integration with monitoring systems:
```powershell
$report = Import-Csv "ConnectionHealth_20251012_143022.csv"
$report | ConvertTo-Json | Out-File "ConnectionHealth.json"
```

## Security Considerations

### What the Script Does NOT Do
- Does not modify any connections
- Does not change flow configurations
- Does not access flow data or run history details
- Does not store credentials

### What the Script DOES Do (Read-Only)
- Reads connection metadata
- Reads connection health status
- Reads flow names and enabled status
- Reads environment information

### Permissions Required
The account running the script needs:
- Power Platform Administrator role OR
- Environment-specific permissions to view connections and flows

### Credentials
- Authentication uses interactive browser sign-in
- Credentials are not stored by the script
- Uses Microsoft's official PowerShell modules

## Output Files Management

### Automatic File Creation
Every run creates timestamped files:
- `ConnectionHealth_YYYYMMDD_HHMMSS.csv`
- `BrokenConnections_YYYYMMDD_HHMMSS.csv` (if broken connections found)
- `ConnectionFlowMapping_YYYYMMDD_HHMMSS.csv`

### File Retention
Consider implementing retention policies:
```powershell
# Example: Delete CSV files older than 90 days
Get-ChildItem -Path $PSScriptRoot -Filter "ConnectionHealth_*.csv" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
    Remove-Item
```

### Version Control
- CSV files are excluded via `.gitignore`
- Only script files should be committed to version control
- Store reports separately from code

## FAQ

### Q: How often should I run this?
**A**: Weekly for proactive monitoring, monthly for comprehensive audits, and immediately when troubleshooting failures.

### Q: What does "orphaned connection" mean?
**A**: A connection that exists but isn't used by any flows. Consider removing to reduce clutter.

### Q: Can this script fix broken connections?
**A**: No, this is a read-only diagnostic tool. It identifies problems; you must manually re-authenticate connections.

### Q: Why do some connections show as "Unknown"?
**A**: The API may not provide enough information to determine health status. Check manually in the portal.

### Q: Does this work with custom connectors?
**A**: Yes, it checks all connection types including custom connectors.

### Q: Can I run this in an automated pipeline?
**A**: Yes, but interactive authentication requires user sign-in. Consider using service principal authentication for fully automated scenarios.

### Q: How accurate is the expiration detection?
**A**: It's heuristic-based (90-day threshold for OAuth). Actual expiration varies by connector type.

### Q: What if I have hundreds of environments?
**A**: The script handles large tenants with progress bars and retry logic. Execution time scales with environment count.

## Support & Feedback

### Getting Help
1. Review this README for common scenarios
2. Check the DEVELOPMENT_JOURNAL.md for implementation notes
3. Review error messages for specific guidance
4. Verify permissions and module installation

### Known Limitations
- Cannot predict exact expiration dates (varies by connector)
- Some connection types may not report full health status
- Large tenants may experience long execution times
- API throttling may occur in very large environments (handled automatically)

## Contributing

Suggestions for improvements:
1. Additional health checks for specific connector types
2. Enhanced expiration date prediction
3. Integration with monitoring platforms
4. Custom connector-specific logic

## Version History

### v1.0.0 (2025-10-12)
- Initial release
- Connection health checking across all environments (including personal/default)
- Flow impact assessment with accurate connection-to-flow matching
- CSV exports (3 types):
  - Full connection health report
  - Critical broken connections only
  - Detailed connection-flow mapping
- Retry logic with exponential backoff (3 retries, 2s/4s/8s delays)
- Orphaned connection detection
- Color-coded console output
- Configurable expiration threshold
- Progress bars for large environments
- Support for both admin and user/personal environments

**Key Technical Fixes**:
- Personal/default environment support: Implemented fallback to `Get-Flow` without `-EnvironmentName` parameter for environments where admin cmdlets return empty results
- Connection matching fix: Corrected flow connection reference property from `connection.id` (non-existent) to `connectionName` (actual property)
- Diagnostic instrumentation: Added comprehensive diagnostics to discover actual API response structures

## Credits

Created by wjmaritz.dev

## License

Use freely for your Power Platform monitoring needs.

---

**Proactive monitoring prevents problems. Check connections before they break flows.**
