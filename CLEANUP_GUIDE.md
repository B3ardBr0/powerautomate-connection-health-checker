# Orphaned Connection Cleanup Guide

## Overview
This guide explains how to safely clean up orphaned connections (connections not used by any flows) using the `cleanup_orphaned_connections.ps1` script.

## What Are Orphaned Connections?

**Orphaned connections** are Power Platform connections that exist but aren't being used by any active flows. They accumulate over time from:
- Deleted flows (connection remains)
- Testing and development
- Failed flow creation attempts
- Migration leftovers
- Connection duplication

## Why Clean Them Up?

### Benefits:
✅ Reduces clutter in your environment
✅ Simplifies connection management
✅ Reduces security surface area (fewer credentials stored)
✅ Improves environment hygiene

### Low Risk:
⚠️ Orphaned connections don't affect running flows
⚠️ Only delete connections you're sure aren't needed

---

## Step-by-Step Cleanup Process

### Step 1: Identify Orphaned Connections

First, run the health checker to generate a list:

```powershell
.\check_connection_health.ps1 -IncludeOrphaned
```

This creates a CSV file showing all connections including orphaned ones.

**Example output:**
```
Total Connections Found: 123
Healthy Connections: 33
Orphaned (Not Shown): 89
```

---

### Step 2: Test Cleanup (Dry Run)

Before deleting anything, see what would be deleted:

```powershell
# See what connections older than 180 days would be deleted
.\cleanup_orphaned_connections.ps1 -DryRun

# See what connections older than 1 year would be deleted
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 365 -DryRun
```

**Dry run shows:**
- Connection names
- Connector types
- Who created them
- How old they are
- **NO connections are actually deleted**

---

### Step 3: Interactive Cleanup (Recommended)

Review and delete connections one-by-one:

```powershell
# Week 1: Delete connections older than 180 days
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 180
```

**Interactive process:**
```
Connection: shared-sharepointonl-abc123...
  Type: sharepointonline
  Created: 2023-01-15 (638 days ago)
  Created By: olduser@company.com
  Environment: Production

Delete this connection? (Y/N/Q to quit): Y
  DELETED
```

For each connection you can:
- **Y** - Delete this connection
- **N** - Skip and keep this connection
- **Q** - Quit the cleanup process

---

### Step 4: Verify Results

After cleanup, run the health checker again:

```powershell
.\check_connection_health.ps1
```

**Check:**
- ✅ Total connection count decreased
- ✅ No flows showing as broken
- ✅ Orphaned count reduced

---

## Usage Examples

### Example 1: Conservative Cleanup (Recommended for Week 1)
```powershell
# Only show connections older than 1 year
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 365
```

### Example 2: Standard Cleanup
```powershell
# Default: 180 days (6 months)
.\cleanup_orphaned_connections.ps1
```

### Example 3: Aggressive Cleanup
```powershell
# Delete connections older than 90 days
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 90
```

### Example 4: Use Specific CSV
```powershell
# Use a specific health check report
.\cleanup_orphaned_connections.ps1 -CsvPath "ConnectionHealth_20251012_115418.csv"
```

### Example 5: Dry Run First (Always Recommended)
```powershell
# See what would happen without actually deleting
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 180 -DryRun

# Then run for real if results look good
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 180
```

---

## Phased Cleanup Approach (Recommended)

### Week 1: Very Old Connections
```powershell
# Delete connections older than 1 year
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 365
```

**Target:** Obviously abandoned connections from old projects

---

### Week 2: Old Connections
```powershell
# Delete connections older than 6 months
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 180
```

**Target:** Connections from completed projects or departed users

---

### Week 3: Recent Orphans
```powershell
# Delete connections older than 90 days
.\cleanup_orphaned_connections.ps1 -MinimumAgeDays 90
```

**Target:** Testing connections and short-lived experiments

---

### Week 4: Verify
```powershell
# Check that no flows were impacted
.\check_connection_health.ps1
```

**Ensure:** No new broken connections or flow failures

---

## Output Files

The cleanup script creates a log file:

**ConnectionCleanupLog_YYYYMMDD_HHMMSS.csv**

Contains:
- Connection name
- Connector type
- Created by
- Age in days
- Environment
- Status (Deleted/Failed/Skipped)
- Timestamp

**Use this log to:**
- Track what was deleted
- Troubleshoot if issues arise
- Document cleanup activities
- Restore connections if needed

---

## Safety Features

### The Script Won't:
❌ Delete connections used by active flows
❌ Delete connections newer than your threshold
❌ Delete connections without your confirmation (unless `-AutoConfirm` used)

### The Script Will:
✅ Show detailed info before each deletion
✅ Let you skip any connection
✅ Create a log of all deletions
✅ Handle errors gracefully
✅ Allow you to quit at any time

---

## Troubleshooting

### Problem: "No CSV files found"
**Solution:** Run the health checker first:
```powershell
.\check_connection_health.ps1 -IncludeOrphaned
```

### Problem: "Failed to delete connection"
**Reasons:**
- Connection is being used by a Power App (not a flow)
- Insufficient permissions
- Connection is managed/protected

**Solution:** Note the connection name and investigate manually in the portal

### Problem: "Accidentally deleted a needed connection"
**Solution:**
- Re-create the connection in Power Automate portal
- Update affected flows to use the new connection
- Connection references in flows will need to be updated

### Problem: Script shows 0 connections to clean
**Reasons:**
- All orphaned connections are newer than your threshold
- No orphaned connections exist (great!)
- CSV file doesn't contain orphaned data

**Solution:**
- Lower the `-MinimumAgeDays` parameter
- Run health checker with `-IncludeOrphaned` flag

---

## Parameters Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-CsvPath` | Latest CSV | Path to ConnectionHealth CSV file |
| `-MinimumAgeDays` | 180 | Only show connections older than this |
| `-DryRun` | Off | Show what would be deleted without deleting |
| `-AutoConfirm` | Off | Delete all without prompting (DANGEROUS!) |

---

## Best Practices

### ✅ DO:
1. **Always run with `-DryRun` first**
2. **Start with high age threshold** (365+ days)
3. **Review creation dates** and creator names
4. **Keep the cleanup logs** for audit trail
5. **Verify no flow failures** after cleanup
6. **Clean up in phases** over several weeks

### ❌ DON'T:
1. **Don't use `-AutoConfirm`** unless you're absolutely sure
2. **Don't delete all orphaned connections at once**
3. **Don't cleanup right before major deployments**
4. **Don't ignore connections created by service accounts**
5. **Don't cleanup without reviewing the dry run output**

---

## FAQ

### Q: How do I know if a connection is safe to delete?
**A:** If it's orphaned (not used by any flow) and old (180+ days), it's usually safe. However, check:
- Created by a service account? → Keep it
- Recently created? → Might be for future use
- Unknown purpose? → Skip it for now

### Q: What happens if I delete a connection by mistake?
**A:** You'll need to re-create it and update any affected flows/apps. The cleanup log will help you remember what was deleted.

### Q: Can I restore deleted connections?
**A:** No, deletion is permanent. You'll need to re-create the connection with the same credentials.

### Q: Will this delete connections used by Power Apps?
**A:** No, the health checker only looks at flows. However, Power Apps might use connections that appear orphaned to flows. Be cautious!

### Q: How often should I run cleanup?
**A:** Monthly or quarterly is reasonable. Don't overdo it - orphaned connections don't hurt anything.

---

## Example Cleanup Session

```powershell
# Step 1: Generate the list
PS> .\check_connection_health.ps1 -IncludeOrphaned
Found 123 connections
Orphaned: 89

# Step 2: See what would be deleted
PS> .\cleanup_orphaned_connections.ps1 -DryRun
Found 45 orphaned connections older than 180 days
[Shows list...]

# Step 3: Actually clean up (interactive)
PS> .\cleanup_orphaned_connections.ps1

Connection: shared-teams-old123
  Type: teams
  Created: 2023-05-10 (520 days ago)
  Created By: john.doe@company.com

Delete this connection? (Y/N/Q): Y
  DELETED

[Review each connection...]

=== Cleanup Summary ===
Connections reviewed: 45
Deleted: 30
Skipped: 15
Failed: 0

Deletion log exported to: ConnectionCleanupLog_20251012_140530.csv

# Step 4: Verify
PS> .\check_connection_health.ps1
Total Connections Found: 93  # Down from 123!
Orphaned: 59  # Down from 89!
```

---

## Support

If you encounter issues:
1. Check the cleanup log CSV for details
2. Review the DEVELOPMENT_JOURNAL.md for technical details
3. Verify your permissions in Power Platform Admin Center
4. Test with `-DryRun` before actual deletion

---

**Created by wjmaritz.dev**

**Remember**: Cleanup is optional! Orphaned connections don't break anything - this is just housekeeping.
