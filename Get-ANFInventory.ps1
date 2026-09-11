#
# This script queries Azure directly for ANF accounts (no CSV import required)
# and writes all accounts, capacity pools, and volumes to CSV output files.
#
param(
    # Optional: limit the scan to specific subscription IDs. Omit to scan
    # every subscription the signed-in account can see.
    [string[]]$SubscriptionId
)

$currdate = Get-Date -Format filedate
$anf_acct_file = "$currdate-anf-accounts.csv"
$anf_pool_file = "$currdate-anf-pools.csv"
$anf_vol_file = "$currdate-anf-volumes.csv"

# Build header for account CSV file.
$anf_acct_writeln = "Name,ResourceGroupName,Location,ID,SubscriptionId,SubscriptionName"
Out-File -FilePath $anf_acct_file -InputObject $anf_acct_writeln -Encoding ASCII

# Build header for pool CSV file.
$anf_pool_writeln = "Name,ResourceGroupName,Location,ID,PoolId,Size,PoolSizeTB,ServiceLevel,ProvisioningState,TotalThroughputMibps,UtilizedThroughputMibps,UsedPercent"
Out-File -FilePath $anf_pool_file -InputObject $anf_pool_writeln -Encoding ASCII

# Build header for volume CSV file.
$anf_vol_writeln = "Name,ResourceGroupName,Location,ProvisioningState,ServiceLevel,NetworkFeatures,ProtocolTypes,Usage,ConsumedSize,MountPath,ExportList"
Out-File -FilePath $anf_vol_file -InputObject $anf_vol_writeln -Encoding ASCII

# Suppress benign SharedTokenCacheCredential fallback warnings emitted by the
# Az authentication chain during token acquisition (harmless: a later
# credential in the chain succeeds).
$WarningPreference = 'SilentlyContinue'

# Prompt Login to Azure
Connect-AzAccount

# Discover subscriptions from Azure itself instead of a CSV export.
$subscriptions = Get-AzSubscription | Where-Object { -not $SubscriptionId -or $SubscriptionId -contains $_.Id }

foreach ($sub in $subscriptions) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    Write-Host "Scanning subscription: $($sub.Name) ($($sub.Id))"

    # Query Azure directly for every ANF account in this subscription,
    # regardless of resource group.
    $anfAccounts = Get-AzResource -ResourceType "Microsoft.NetApp/netAppAccounts"

    foreach ($acctResource in $anfAccounts) {
        $anf_acct_name = $acctResource.Name
        $anf_rg = $acctResource.ResourceGroupName

        Write-Host "Processing ANF Account:  $anf_acct_name"

        $anf_acct_writeln = $($acctResource.Name) + "," + $($acctResource.ResourceGroupName) + "," + $($acctResource.Location) + "," + $($acctResource.Id) + "," + $($sub.Id) + "," + $($sub.Name)
        Out-File -FilePath $anf_acct_file -InputObject $anf_acct_writeln -Encoding ASCII -Append

        # Gather and Process Pool Data
        Get-AzNetAppFilesPool -AccountName $anf_acct_name -ResourceGroupName $anf_rg | ForEach-Object {
            $anfusedratio = $($_.UtilizedThroughputMibps) / $($_.TotalThroughputMibps)
            $anfpoolsizetb = $($_.Size) / 1099511627776
            $anfpoolname = $($_.name)
            $anfpoolname = $anfpoolname.Substring($anfpoolname.indexOf("/") + 1)
            Write-Host "Processing ANF Pool:  $anfpoolname"
            $anf_pool_writeln = $($_.Name) + "," + $($_.ResourceGroupName) + "," + $($_.Location) + "," + $($_.ID) + "," + $($_.PoolId) + "," + $($_.Size) + "," + $anfpoolsizetb + "," + $($_.ServiceLevel) + "," + $($_.ProvisioningState) + "," + $($_.TotalThroughputMibps) + "," + $($_.UtilizedThroughputMibps) + "," + $anfusedratio
            Out-File -FilePath $anf_pool_file -InputObject $anf_pool_writeln -Encoding ASCII -Append

            $volumes = Get-AzNetAppFilesVolume -AccountName $anf_acct_name -ResourceGroupName $anf_rg -PoolName $anfpoolname
            foreach ($volume in $volumes) {
                $consumedSize = 0
                $volumeConsumedDataPoints = Get-AzMetric -ResourceId $volume.Id -MetricName "VolumeLogicalSize" -StartTime 00:00:00 -EndTime 11:59:00 -TimeGrain 00:5:00 -WarningAction:SilentlyContinue -EA SilentlyContinue
                foreach ($dataPoint in $volumeConsumedDataPoints.data) {
                    if ($dataPoint.Average -gt $consumedSize) {
                        $consumedSize = $dataPoint.Average
                    }
                }

                # Gather Export and Mount Path info
                [string]$exports = ""
                [string]$mountPath = ""

                if ($volume.provisioningState -eq "Succeeded") {
                    if ($volume.securityStyle -eq "Ntfs") {
                        $mountPath = "\\" + $volume.mountTargets.smbServerFqdn + "\" + $volume.creationToken
                    }
                    else {
                        $mountPath = $volume.MountTargets.ipAddress + ":/" + $volume.creationToken

                        foreach ($index in (0, 1, 2, 3, 4)) {
                            [string]$export = $volume.ExportPolicy.Rules[$index].AllowedClients
                            if ($export.length -gt 0) {
                                [string]$permissions = 'None'
                                if ([string]$volume.ExportPolicy.Rules[$index].UnixReadOnly -eq $true) {
                                    [string]$permissions = "ReadOnly"
                                }
                                elseif ([string]$volume.ExportPolicy.Rules[$index].UnixReadWrite -eq $true) {
                                    [string]$permissions = "ReadWrite"
                                }
                                # Build the export info, can contain up to 5 export policies per volume
                                if ([string]$exports -ne [string]($export + "," + $permissions)) {
                                    if ($index -eq 0) {
                                        $exports = $export + ";" + $permissions
                                    }
                                    else {
                                        $exports = $exports + "=" + $export + ";" + $permissions
                                    }
                                }
                            }
                        }
                    }
                }
                else {
                    $mountPath = "Volume : " + $volume.provisioningState
                }

                $exports = $exports.replace(',', ';')
                $anf_vol_writeln = $($volume.Name) + "," + $($_.ResourceGroupName) + "," + $($_.Location) + "," + $($_.ProvisioningState) + "," + $($_.ServiceLevel) + "," + $volume.NetworkFeatures + "," + $volume.ProtocolTypes + "," + $volume.UsageThreshold / 1024 / 1024 / 1024 + "," + $consumedSize / 1024 / 1024 / 1024 + "," + $mountPath + "," + $exports
                Out-File -FilePath $anf_vol_file -InputObject $anf_vol_writeln -Encoding ASCII -Append
            }
        }
    }
}

# Clear Variables
Clear-Variable -Name currdate
Clear-Variable -Name anf_acct_name
Clear-Variable -Name anf_rg
Clear-Variable -Name anfusedratio
Clear-Variable -Name anfpoolsizetb
Clear-Variable -Name anf_acct_writeln
Clear-Variable -Name anf_acct_file
Clear-Variable -Name anf_pool_writeln
Clear-Variable -Name anf_pool_file
Clear-Variable -Name anf_vol_writeln
Clear-Variable -Name anf_vol_file
