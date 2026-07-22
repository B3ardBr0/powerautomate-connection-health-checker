<#
.SYNOPSIS
    Checks Power Automate connection health across all environments to identify broken or expiring connections.

.DESCRIPTION
    This script proactively monitors Power Automate connections to identify issues before they cause flow failures.
    It checks connection authentication status, identifies expiring credentials, and maps connections to affected flows.
    Requires the Microsoft.PowerApps.Administration.PowerShell and Microsoft.PowerApps.PowerShell modules.

    Features:
    - Progress bar showing real-time check status
    - Automatic retry logic for transient API failures (3 retries with exponential backoff)
    - Connection health status: Healthy, Expiring Soon, Expired, Broken, Unauthorized
    - Flow impact assessment (which flows use which connections)
    - CSV export of connection health with timestamps
    - Color-coded console output

.PARAMETER DaysUntilExpiration
    Number of days threshold to warn about expiring connections (default: 30)

.PARAMETER IncludeOrphaned
    Include connections not used by any flow in the report

.EXAMPLE
    .\check_connection_health.ps1
    Checks all connections and warns about those expiring in the next 30 days

.EXAMPLE
    .\check_connection_health.ps1 -DaysUntilExpiration 60
    Checks all connections and warns about those expiring in the next 60 days

.EXAMPLE
    .\check_connection_health.ps1 -IncludeOrphaned
    Includes orphaned connections (not used by any flow) in the report

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell and Microsoft.PowerApps.PowerShell modules
    Install with:
        Install-Module -Name Microsoft.PowerApps.Administration.PowerShell
        Install-Module -Name Microsoft.PowerApps.PowerShell

    Retry Logic: API calls will automatically retry up to 3 times with
    exponential backoff (2s, 4s, 8s) to handle transient failures.

    Created by wjmaritz.dev
#>

param(
    [Parameter(Mandatory=$false)]
    [int]$DaysUntilExpiration = 30,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeOrphaned
)

# Function to retry API calls with exponential backoff
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory=$false)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory=$false)]
        [int]$InitialDelaySeconds = 2
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($attempt -lt $MaxRetries) {
        try {
            return & $ScriptBlock
        }
        catch {
            $attempt++
            if ($attempt -ge $MaxRetries) {
                throw
            }

            Write-Warning "API call failed (attempt $attempt/$MaxRetries). Retrying in $delay seconds... Error: $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
            $delay = $delay * 2  # Exponential backoff
        }
    }
}

# Function to check and install required modules
function Install-RequiredModules {
    $requiredModules = @(
        'Microsoft.PowerApps.Administration.PowerShell',
        'Microsoft.PowerApps.PowerShell'
    )

    foreach ($module in $requiredModules) {
        if (!(Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing module: $module" -ForegroundColor Yellow
            try {
                Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
                Write-Host "Successfully installed $module" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to install $module. Error: $_"
                return $false
            }
        }

        # Import the module
        Import-Module $module -ErrorAction Stop
    }
    return $true
}

# Function to determine connection health status
function Get-ConnectionHealthStatus {
    param(
        [Parameter(Mandatory=$true)]
        $Connection,

        [Parameter(Mandatory=$false)]
        [int]$DaysThreshold = 30
    )

    $status = @{
        Status = "Unknown"
        Color = "Gray"
        Priority = 0
        Message = ""
    }

    # Check connection status properties
    $connStatus = $Connection.Statuses

    if ($connStatus) {
        # Check for error status
        if ($connStatus.Status -eq "Error" -or $connStatus.Error) {
            $status.Status = "Broken"
            $status.Color = "Red"
            $status.Priority = 1
            $status.Message = if ($connStatus.Error) { $connStatus.Error.Message } else { "Connection error detected" }
            return $status
        }

        # Check for connected status
        if ($connStatus.Status -eq "Connected") {
            $status.Status = "Healthy"
            $status.Color = "Green"
            $status.Priority = 5
            $status.Message = "Connection is healthy"
            return $status
        }

        # Check for unauthorized
        if ($connStatus.Status -eq "Unauthenticated" -or $connStatus.Status -eq "Unauthorized") {
            $status.Status = "Unauthorized"
            $status.Color = "Red"
            $status.Priority = 1
            $status.Message = "Authentication required or permissions revoked"
            return $status
        }
    }

    # Check expiration if available
    if ($Connection.CreatedTime) {
        $createdDate = [DateTime]$Connection.CreatedTime
        $daysSinceCreated = ((Get-Date) - $createdDate).Days

        # Many OAuth tokens expire after 90 days, API keys vary
        # This is a heuristic - actual expiration depends on connector type
        if ($daysSinceCreated -gt 90) {
            $status.Status = "PossiblyExpired"
            $status.Color = "Red"
            $status.Priority = 2
            $status.Message = "Connection is older than 90 days, may need refresh"
            return $status
        }
        elseif ($daysSinceCreated -gt (90 - $DaysThreshold)) {
            $status.Status = "ExpiringSoon"
            $status.Color = "Yellow"
            $status.Priority = 3
            $status.Message = "Connection may expire soon (created $daysSinceCreated days ago)"
            return $status
        }
    }

    # Default to unknown if we can't determine status
    $status.Status = "Unknown"
    $status.Color = "Gray"
    $status.Priority = 4
    $status.Message = "Unable to determine connection health"

    return $status
}

# Function to get flows using a specific connection
function Get-FlowsUsingConnection {
    param(
        [Parameter(Mandatory=$true)]
        $Connection,

        [Parameter(Mandatory=$true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory=$false)]
        $AllFlows  # Optional: pass pre-fetched flows to avoid repeated API calls
    )

    try {
        # Use pre-fetched flows if available, otherwise fetch them
        $flows = $AllFlows
        if (!$flows) {
            try {
                $flows = Invoke-WithRetry -ScriptBlock {
                    Get-AdminFlow -EnvironmentName $EnvironmentName
                }
            }
            catch {
                # If admin cmdlet fails (e.g., personal default environment), try user cmdlet
                Write-Verbose "Admin cmdlet failed, trying user cmdlet for flows. Error: $($_.Exception.Message)"
                $flows = Invoke-WithRetry -ScriptBlock {
                    Get-Flow -EnvironmentName $EnvironmentName
                }
            }
        }

        $flowsUsingConnection = @()

        # Extract multiple identifiers from the connection for matching
        $connectionName = $Connection.ConnectionName
        $connectionDisplayName = $Connection.DisplayName

        # Try to get full connection ID from different possible sources
        $fullConnectionId = $null
        if ($Connection.Internal.id) {
            $fullConnectionId = $Connection.Internal.id
        }
        elseif ($Connection.ConnectionId) {
            $fullConnectionId = $Connection.ConnectionId
        }

        # DIAGNOSTIC: Log connection identifiers (first connection only to avoid spam)
        if ($script:FirstConnectionDiagnostic -ne $true) {
            Write-Host "    [DIAGNOSTIC] Connection identifiers:" -ForegroundColor Magenta
            Write-Host "      - ConnectionName: $connectionName" -ForegroundColor Magenta
            Write-Host "      - DisplayName: $connectionDisplayName" -ForegroundColor Magenta
            Write-Host "      - Full Connection ID: $fullConnectionId" -ForegroundColor Magenta
            Write-Host "      - Internal.id: $($Connection.Internal.id)" -ForegroundColor Magenta
            $script:FirstConnectionDiagnostic = $true
        }

        $flowConnectionIdsFound = @()

        foreach ($flow in $flows) {
            # Check if flow uses this connection
            if ($flow.Internal.properties.connectionReferences) {
                $connectionRefs = $flow.Internal.properties.connectionReferences

                foreach ($ref in $connectionRefs.PSObject.Properties) {
                    $connRef = $ref.Value

                    # The flow's connection reference has a 'connectionName' property (not connection.id)
                    $flowConnName = $connRef.connectionName

                    if ($flowConnName) {
                        # DIAGNOSTIC: Collect unique flow connection names for logging
                        if ($flowConnectionIdsFound.Count -lt 5 -and $flowConnName -notin $flowConnectionIdsFound) {
                            $flowConnectionIdsFound += $flowConnName
                        }

                        # Match strategy: Direct comparison of connectionName
                        # Flow has: connectionName = "shared-microsoftforms-00000000-0000-0000-0000-000000000000"
                        # Connection has: ConnectionName = "shared-microsoftbookings-00000000-0000-0000-0000-000000000000"
                        if ($connectionName -and $flowConnName -eq $connectionName) {
                            $flowsUsingConnection += @{
                                FlowName = $flow.DisplayName
                                FlowId = $flow.FlowName
                                Enabled = $flow.Enabled
                            }
                            Write-Verbose "    Matched connection: $connectionName to flow: $($flow.DisplayName)"
                            break  # Stop checking other refs in this flow
                        }
                    }
                }
            }
        }

        # DIAGNOSTIC: Log sample flow connection names (first connection only)
        if ($script:FirstFlowConnectionDiagnostic -ne $true -and $flowConnectionIdsFound.Count -gt 0) {
            Write-Host "    [DIAGNOSTIC] Sample flow connection names found (first 5):" -ForegroundColor Magenta
            foreach ($fid in $flowConnectionIdsFound) {
                Write-Host "      - $fid" -ForegroundColor Magenta
            }
            $script:FirstFlowConnectionDiagnostic = $true
        }

        return $flowsUsingConnection
    }
    catch {
        Write-Warning "Could not retrieve flows for connection. Error: $($_.Exception.Message)"
        return @()
    }
}

# Main script execution
Write-Host "=== Power Automate Connection Health Checker ===" -ForegroundColor Cyan
Write-Host "Checking connections across all environments" -ForegroundColor Cyan
Write-Host "Warning threshold: Connections expiring within $DaysUntilExpiration days" -ForegroundColor Cyan
Write-Host ""

# Check and install required modules
Write-Host "Checking required PowerShell modules..." -ForegroundColor Yellow
if (!(Install-RequiredModules)) {
    Write-Error "Failed to install required modules. Exiting."
    exit 1
}

# Connect to Power Platform
Write-Host "Connecting to Power Platform..." -ForegroundColor Yellow
try {
    Add-PowerAppsAccount
}
catch {
    Write-Error "Failed to connect to Power Platform. Error: $_"
    exit 1
}

Write-Host "Successfully connected!" -ForegroundColor Green
Write-Host ""

# Get all environments with retry logic
Write-Host "Retrieving environments..." -ForegroundColor Yellow
try {
    # Get admin environments
    $adminEnvironments = Invoke-WithRetry -ScriptBlock { Get-AdminPowerAppEnvironment }

    # Get user's personal/default environments (includes default environment with personal flows)
    $userEnvironments = Invoke-WithRetry -ScriptBlock { Get-PowerAppEnvironment }

    # Combine and deduplicate environments by EnvironmentName
    $allEnvironments = @{}

    # Add admin environments first
    foreach ($env in $adminEnvironments) {
        if ($env.EnvironmentName) {
            $allEnvironments[$env.EnvironmentName] = $env
        }
    }

    # Add user environments (this will include default environment)
    foreach ($env in $userEnvironments) {
        if ($env.EnvironmentName -and !$allEnvironments.ContainsKey($env.EnvironmentName)) {
            $allEnvironments[$env.EnvironmentName] = $env
        }
    }

    # Convert back to array
    $environments = $allEnvironments.Values | Sort-Object DisplayName

    Write-Host "Found $($environments.Count) environment(s) (admin + personal/default)" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Error "Failed to retrieve environments after multiple retries. Error: $_"
    exit 1
}

# Initialize counters and collections
$totalConnections = 0
$healthyConnections = 0
$brokenConnections = 0
$expiringConnections = 0
$unauthorizedConnections = 0
$orphanedConnections = 0
$connectionDetails = @()
$connectionFlowMapping = @()
$processedEnvironments = 0

# Process each environment
foreach ($env in $environments) {
    $processedEnvironments++
    $envPercentComplete = [math]::Round(($processedEnvironments / $environments.Count) * 100)

    Write-Progress -Id 1 -Activity "Scanning Environments" `
                   -Status "Processing: $($env.DisplayName)" `
                   -PercentComplete $envPercentComplete `
                   -CurrentOperation "Environment $processedEnvironments of $($environments.Count)"

    Write-Host "Processing Environment: $($env.DisplayName)" -ForegroundColor Cyan

    try {
        # Get all connections in this environment with retry logic
        # Try admin cmdlet first, fall back to user cmdlet if needed (for personal/default environments)
        $connections = $null
        $connectionRetrievalMethod = "Unknown"
        $adminAttempted = $false

        try {
            Write-Verbose "  Trying Get-AdminPowerAppConnection for environment: $($env.EnvironmentName)"
            $connections = Invoke-WithRetry -ScriptBlock {
                Get-AdminPowerAppConnection -EnvironmentName $env.EnvironmentName
            }
            $adminAttempted = $true

            # If admin cmdlet succeeds but returns no connections, try user cmdlet as fallback
            if (!$connections -or $connections.Count -eq 0) {
                $connectionRetrievalMethod = "Admin (empty)"
                Write-Host "  Admin cmdlet returned no connections, trying user cmdlet..." -ForegroundColor Yellow
            }
            else {
                $connectionRetrievalMethod = "Admin"
                Write-Verbose "  Successfully retrieved $($connections.Count) connections using Admin cmdlet"
            }
        }
        catch {
            # If admin cmdlet throws error, note it and continue to fallback
            Write-Host "  Admin cmdlet failed, trying user cmdlet..." -ForegroundColor Yellow
            Write-Verbose "  Admin cmdlet error: $($_.Exception.Message)"
            $connectionRetrievalMethod = "Admin (error)"
        }

        # If admin didn't return connections, try user cmdlet
        if (!$connections -or $connections.Count -eq 0) {
            try {
                Write-Verbose "  Trying Get-PowerAppConnection (no -EnvironmentName) for user connections"
                # For personal/default environment, Get-PowerAppConnection works differently
                # It may need to be called without EnvironmentName parameter
                $allUserConnections = Invoke-WithRetry -ScriptBlock {
                    Get-PowerAppConnection
                }

                # Filter connections for this specific environment
                if ($allUserConnections) {
                    $connections = $allUserConnections | Where-Object {
                        $_.Internal.properties.environment.name -eq $env.EnvironmentName
                    }

                    if ($connections -and $connections.Count -gt 0) {
                        $connectionRetrievalMethod = "User (filtered)"
                        Write-Host "  Found connections using user cmdlet!" -ForegroundColor Green
                        Write-Verbose "  Successfully retrieved $($connections.Count) connections using User cmdlet (filtered)"
                    }
                    else {
                        $connectionRetrievalMethod = "User (filtered, empty)"
                        Write-Verbose "  User cmdlet returned connections but none matched this environment"
                    }
                }
                else {
                    $connectionRetrievalMethod = "User (empty)"
                    Write-Verbose "  User cmdlet returned no connections"
                }
            }
            catch {
                Write-Verbose "  User cmdlet also failed. Error: $($_.Exception.Message)"
                $connectionRetrievalMethod = "Failed"
            }
        }

        # If no connections found via cmdlets, try extracting from flows
        if (!$connections -or $connections.Count -eq 0) {
            Write-Host "  No connections found via cmdlets, extracting from flows..." -ForegroundColor Yellow

            try {
                # Get flows to extract connection references
                $flows = $null
                try {
                    $flows = Invoke-WithRetry -ScriptBlock {
                        Get-AdminFlow -EnvironmentName $env.EnvironmentName
                    }
                }
                catch {
                    $flows = Invoke-WithRetry -ScriptBlock {
                        Get-Flow -EnvironmentName $env.EnvironmentName
                    }
                }

                if ($flows) {
                    Write-Host "  Found $($flows.Count) flow(s), analyzing connection references..." -ForegroundColor White

                    # Extract unique connections from flows
                    $extractedConnections = @{}

                    foreach ($flow in $flows) {
                        if ($flow.Internal.properties.connectionReferences) {
                            foreach ($ref in $flow.Internal.properties.connectionReferences.PSObject.Properties) {
                                $connRef = $ref.Value
                                $connId = $connRef.connection.id

                                if ($connId -and !$extractedConnections.ContainsKey($connId)) {
                                    # Create a pseudo-connection object from flow metadata
                                    $extractedConnections[$connId] = [PSCustomObject]@{
                                        ConnectionName = ($connId -split '/')[-1]
                                        DisplayName = $connRef.displayName
                                        Internal = @{
                                            properties = @{
                                                apiId = "/providers/Microsoft.PowerApps/apis/$($connRef.api.name)"
                                                environment = @{
                                                    name = $env.EnvironmentName
                                                }
                                            }
                                        }
                                        CreatedTime = $null  # Not available from flow metadata
                                        CreatedBy = @{ displayName = "Unknown (from flow)" }
                                        Statuses = @{ Status = "Unknown" }  # Can't determine status from flow
                                        IsExtractedFromFlow = $true
                                    }
                                }
                            }
                        }
                    }

                    if ($extractedConnections.Count -gt 0) {
                        $connections = $extractedConnections.Values
                        $connectionRetrievalMethod = "Extracted from flows"
                        Write-Host "  Extracted $($connections.Count) unique connection(s) from flow definitions" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  No connection references found in flows" -ForegroundColor Gray
                    }
                }
            }
            catch {
                Write-Verbose "  Failed to extract connections from flows. Error: $($_.Exception.Message)"
            }
        }

        if (!$connections -or $connections.Count -eq 0) {
            Write-Host "  No connections found in this environment (method: $connectionRetrievalMethod)" -ForegroundColor Gray
            Write-Host "  Note: This environment may only use built-in/shared connections" -ForegroundColor Gray
            Write-Host ""
            continue
        }

        # Ensure connections is treated as an array (handle single connection case)
        if ($connections -isnot [System.Array]) {
            $connections = @($connections)
        }

        $connectionCount = $connections.Count
        Write-Host "  Found $connectionCount connection(s)" -ForegroundColor White

        # Pre-fetch flows once for this environment (performance optimization)
        Write-Host "  Retrieving flows for connection matching..." -ForegroundColor Yellow
        $envFlows = $null
        $flowRetrievalMethod = "Unknown"

        try {
            # Try admin cmdlet first
            $envFlows = Invoke-WithRetry -ScriptBlock {
                Get-AdminFlow -EnvironmentName $env.EnvironmentName
            }

            if ($envFlows -and $envFlows.Count -gt 0) {
                $flowRetrievalMethod = "Admin"
            }
            else {
                # Admin succeeded but returned empty, try user cmdlet
                $flowRetrievalMethod = "Admin (empty)"
                $envFlows = $null
            }
        }
        catch {
            # Admin cmdlet failed, try user cmdlet
            Write-Verbose "  Admin flow cmdlet failed: $($_.Exception.Message)"
            $flowRetrievalMethod = "Admin (error)"
        }

        # If admin didn't return flows, try user cmdlet
        if (!$envFlows -or $envFlows.Count -eq 0) {
            try {
                Write-Verbose "  Trying Get-Flow (no -EnvironmentName) for user flows"
                # For personal/default environment, Get-Flow works differently
                # Call without EnvironmentName parameter, then filter
                $allUserFlows = Invoke-WithRetry -ScriptBlock {
                    Get-Flow
                }

                # Filter flows for this specific environment
                if ($allUserFlows) {
                    $envFlows = $allUserFlows | Where-Object {
                        $_.Internal.properties.environment.name -eq $env.EnvironmentName
                    }

                    if ($envFlows -and $envFlows.Count -gt 0) {
                        $flowRetrievalMethod = "User (filtered)"
                        Write-Host "  Found flows using user cmdlet!" -ForegroundColor Green
                    }
                    else {
                        $flowRetrievalMethod = "User (filtered, empty)"
                    }
                }
            }
            catch {
                Write-Warning "  Could not retrieve flows for matching. Error: $($_.Exception.Message)"
                $flowRetrievalMethod = "Failed"
            }
        }

        if ($envFlows -and $envFlows.Count -gt 0) {
            Write-Host "  Found $($envFlows.Count) flow(s) for matching (method: $flowRetrievalMethod)" -ForegroundColor Green

            # DIAGNOSTIC: Examine flow structure to understand where connection references are stored
            if ($script:FirstFlowStructureDiagnostic -ne $true) {
                Write-Host "    [DIAGNOSTIC] Examining flow structure..." -ForegroundColor Magenta
                $sampleFlow = $envFlows | Select-Object -First 1
                Write-Host "      - Sample flow DisplayName: $($sampleFlow.DisplayName)" -ForegroundColor Magenta
                Write-Host "      - Has Internal property: $($null -ne $sampleFlow.Internal)" -ForegroundColor Magenta
                Write-Host "      - Has Internal.properties: $($null -ne $sampleFlow.Internal.properties)" -ForegroundColor Magenta
                Write-Host "      - Has connectionReferences: $($null -ne $sampleFlow.Internal.properties.connectionReferences)" -ForegroundColor Magenta

                if ($sampleFlow.Internal.properties.connectionReferences) {
                    $refCount = ($sampleFlow.Internal.properties.connectionReferences.PSObject.Properties | Measure-Object).Count
                    Write-Host "      - Number of connection refs in sample: $refCount" -ForegroundColor Magenta

                    # Show first connection reference structure
                    $firstRef = $sampleFlow.Internal.properties.connectionReferences.PSObject.Properties | Select-Object -First 1
                    if ($firstRef) {
                        Write-Host "      - First ref name: $($firstRef.Name)" -ForegroundColor Magenta
                        Write-Host "      - Has connection.id: $($null -ne $firstRef.Value.connection.id)" -ForegroundColor Magenta

                        # If connection.id doesn't exist, show what properties ARE available
                        if (!$firstRef.Value.connection.id) {
                            Write-Host "      - connection.id is NULL! Checking what properties exist:" -ForegroundColor Red
                            Write-Host "      - Has 'connection' property: $($null -ne $firstRef.Value.connection)" -ForegroundColor Magenta

                            if ($firstRef.Value.connection) {
                                Write-Host "      - Properties in 'connection' object:" -ForegroundColor Magenta
                                $firstRef.Value.connection.PSObject.Properties | ForEach-Object {
                                    Write-Host "        - $($_.Name): $($_.Value)" -ForegroundColor Magenta
                                }
                            }

                            Write-Host "      - All properties in connection reference:" -ForegroundColor Magenta
                            $firstRef.Value.PSObject.Properties | ForEach-Object {
                                Write-Host "        - $($_.Name): $($_.Value)" -ForegroundColor Magenta
                            }
                        }
                        else {
                            Write-Host "      - connection.id value: $($firstRef.Value.connection.id)" -ForegroundColor Magenta
                        }
                    }
                }
                else {
                    Write-Host "      - connectionReferences is NULL or doesn't exist" -ForegroundColor Red
                    Write-Host "      - Checking alternative locations..." -ForegroundColor Magenta
                    Write-Host "      - Has definition: $($null -ne $sampleFlow.Internal.properties.definition)" -ForegroundColor Magenta
                    Write-Host "      - Has connectionReferences (top level): $($null -ne $sampleFlow.connectionReferences)" -ForegroundColor Magenta
                }

                $script:FirstFlowStructureDiagnostic = $true
            }
        }
        else {
            Write-Host "  No flows found for matching (method: $flowRetrievalMethod)" -ForegroundColor Yellow
        }

        $processedConnections = 0

        # Check each connection
        foreach ($conn in $connections) {
            $processedConnections++
            $totalConnections++

            # Safely calculate percentage (avoid division by zero)
            $connPercentComplete = if ($connectionCount -gt 0) {
                [math]::Round(($processedConnections / $connectionCount) * 100)
            } else {
                0
            }

            Write-Progress -Id 2 -Activity "Checking Connections in $($env.DisplayName)" `
                           -Status "Checking: $($conn.DisplayName)" `
                           -PercentComplete $connPercentComplete `
                           -CurrentOperation "Connection $processedConnections of $connectionCount"

            # Get health status
            $healthStatus = Get-ConnectionHealthStatus -Connection $conn -DaysThreshold $DaysUntilExpiration

            # Get flows using this connection (pass full connection object and pre-fetched flows)
            $flowsUsing = Get-FlowsUsingConnection -Connection $conn -EnvironmentName $env.EnvironmentName -AllFlows $envFlows
            $flowCount = $flowsUsing.Count

            # Determine if orphaned
            $isOrphaned = ($flowCount -eq 0)

            # Skip orphaned if not requested
            if ($isOrphaned -and !$IncludeOrphaned) {
                $orphanedConnections++
                continue
            }

            # Update counters
            switch ($healthStatus.Status) {
                "Healthy" { $healthyConnections++ }
                "Broken" { $brokenConnections++ }
                "PossiblyExpired" { $brokenConnections++ }
                "ExpiringSoon" { $expiringConnections++ }
                "Unauthorized" { $unauthorizedConnections++ }
            }

            if ($isOrphaned) { $orphanedConnections++ }

            # Store connection details
            $connectionDetails += [PSCustomObject]@{
                Environment = $env.DisplayName
                EnvironmentId = $env.EnvironmentName
                ConnectionName = $conn.DisplayName
                ConnectionId = $conn.ConnectionName
                ConnectorName = $conn.Internal.properties.apiId -replace '.*/providers/Microsoft.PowerApps/apis/', ''
                Status = $healthStatus.Status
                Priority = $healthStatus.Priority
                Message = $healthStatus.Message
                CreatedDate = $conn.CreatedTime
                CreatedBy = $conn.CreatedBy.displayName
                FlowsUsing = $flowCount
                IsOrphaned = $isOrphaned
            }

            # Store connection-flow mappings
            foreach ($flow in $flowsUsing) {
                $connectionFlowMapping += [PSCustomObject]@{
                    Environment = $env.DisplayName
                    ConnectionName = $conn.DisplayName
                    ConnectionId = $conn.ConnectionName
                    FlowName = $flow.FlowName
                    FlowId = $flow.FlowId
                    FlowEnabled = $flow.Enabled
                    ConnectionStatus = $healthStatus.Status
                }
            }

            # Display connection status
            $statusSymbol = switch ($healthStatus.Status) {
                "Healthy" { "[OK]" }
                "ExpiringSoon" { "[WARN]" }
                "Broken" { "[FAIL]" }
                "PossiblyExpired" { "[FAIL]" }
                "Unauthorized" { "[AUTH]" }
                "Unknown" { "[?]" }
                default { "[?]" }
            }

            $displayText = "  $statusSymbol $($conn.DisplayName) ($($conn.Internal.properties.apiId -replace '.*/providers/Microsoft.PowerApps/apis/', '')) - $($flowCount) flow(s)"
            if ($healthStatus.Message) {
                $displayText += " - $($healthStatus.Message)"
            }
            if ($isOrphaned) {
                $displayText += " [ORPHANED]"
            }

            Write-Host $displayText -ForegroundColor $healthStatus.Color
        }

        Write-Progress -Id 2 -Activity "Checking Connections" -Completed
        Write-Host ""
    }
    catch {
        Write-Warning "  Could not retrieve connections for environment: $($env.DisplayName). Error: $($_.Exception.Message)"
        Write-Host ""
    }
}

# Clear progress bars
Write-Progress -Id 1 -Activity "Scanning Environments" -Completed
Write-Progress -Id 2 -Activity "Checking Connections" -Completed

# Display summary
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Total Environments Checked: $($environments.Count)" -ForegroundColor White
Write-Host "Total Connections Found: $totalConnections" -ForegroundColor White
Write-Host ""
Write-Host "Healthy Connections: $healthyConnections" -ForegroundColor Green
Write-Host "Expiring Soon: $expiringConnections" -ForegroundColor Yellow
Write-Host "Broken/Expired: $brokenConnections" -ForegroundColor Red
Write-Host "Unauthorized: $unauthorizedConnections" -ForegroundColor Red
if ($IncludeOrphaned) {
    Write-Host "Orphaned (No Flows): $orphanedConnections" -ForegroundColor Gray
}
else {
    Write-Host "Orphaned (Not Shown): $orphanedConnections (use -IncludeOrphaned to show)" -ForegroundColor Gray
}
Write-Host ""

# Display detailed results for problematic connections
$problematicConnections = $connectionDetails | Where-Object {
    $_.Status -ne "Healthy" -and $_.Status -ne "Unknown"
} | Sort-Object Priority, FlowsUsing -Descending

if ($problematicConnections.Count -gt 0) {
    Write-Host "=== Connections Requiring Attention ===" -ForegroundColor Red
    $problematicConnections | Select-Object Environment, ConnectionName, ConnectorName, Status, FlowsUsing, Message | Format-Table -AutoSize
    Write-Host ""
}

# Display high-impact broken connections
$criticalConnections = $connectionDetails | Where-Object {
    ($_.Status -eq "Broken" -or $_.Status -eq "PossiblyExpired" -or $_.Status -eq "Unauthorized") -and $_.FlowsUsing -gt 0
} | Sort-Object FlowsUsing -Descending

if ($criticalConnections.Count -gt 0) {
    Write-Host "=== CRITICAL: Broken Connections Impacting Flows ===" -ForegroundColor Red
    $criticalConnections | Select-Object Environment, ConnectionName, ConnectorName, FlowsUsing, Message | Format-Table -AutoSize
    Write-Host ""
}

# Export to CSV files
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

if ($connectionDetails.Count -gt 0) {
    # Export full connection health report
    $csvPath = Join-Path $PSScriptRoot "ConnectionHealth_$timestamp.csv"
    $connectionDetails | Sort-Object Priority, FlowsUsing -Descending | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Host "Full health report exported to: $csvPath" -ForegroundColor Green
}

if ($criticalConnections.Count -gt 0) {
    # Export critical connections only
    $criticalCsvPath = Join-Path $PSScriptRoot "BrokenConnections_$timestamp.csv"
    $criticalConnections | Export-Csv -Path $criticalCsvPath -NoTypeInformation
    Write-Host "Critical connections exported to: $criticalCsvPath" -ForegroundColor Red
}

if ($connectionFlowMapping.Count -gt 0) {
    # Export connection-flow mapping
    $mappingCsvPath = Join-Path $PSScriptRoot "ConnectionFlowMapping_$timestamp.csv"
    $connectionFlowMapping | Export-Csv -Path $mappingCsvPath -NoTypeInformation
    Write-Host "Connection-flow mapping exported to: $mappingCsvPath" -ForegroundColor Green
}

Write-Host ""

# Display recommendations
if ($brokenConnections -gt 0 -or $unauthorizedConnections -gt 0) {
    Write-Host "=== Recommended Actions ===" -ForegroundColor Yellow
    Write-Host "1. Review broken/unauthorized connections in the Power Automate portal" -ForegroundColor White
    Write-Host "2. Re-authenticate connections with valid credentials" -ForegroundColor White
    Write-Host "3. Update affected flows to use working connections" -ForegroundColor White
    Write-Host "4. Test flows after fixing connections" -ForegroundColor White
    Write-Host ""
}

if ($expiringConnections -gt 0) {
    Write-Host "=== Preventive Maintenance ===" -ForegroundColor Yellow
    Write-Host "1. Schedule time to refresh expiring connections" -ForegroundColor White
    Write-Host "2. Consider using service principals for long-lived connections" -ForegroundColor White
    Write-Host "3. Document connection refresh procedures" -ForegroundColor White
    Write-Host ""
}

Write-Host "Script completed." -ForegroundColor Cyan
Write-Host "Created by wjmaritz.dev" -ForegroundColor Gray
