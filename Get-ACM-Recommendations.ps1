<#
.SYNOPSIS
  The purpose of the script is to combine recommendations from Azure Cost Management (ACM) with information on the Azure Virtual Machine and environment.
.DESCRIPTION
  Using Azure Resource Graph queries to gather recommendations from Azure Cost Management and information on the Virtual Machine and Network Interface.
  Then using indices to combine the data and create the report.

  The ACM thresholds (CPU, Memory, Network) are 7 day p95 averages. ACM uses these averages to make it's recommendations.
.INPUTS
  Update the Azure SubscriptionID to run on the correct subscription. 
.OUTPUTS
  Report is saved on the desktop as AzCM_Recs_FILECREATIONDATE.csv
.NOTES
  Version:        1.0
  Author:         Ryan Krokson / Microsoft
  Creation Date:  7/9/2020
  Purpose/Change: Initial script development
  
.EXAMPLE
  ./Get-ACM-Recommendations.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>

Param(
	[Parameter(
		Mandatory=$True,
		HelpMessage='Error: Please enter an Azure SubscriptionID.'
	)]$SubscriptionID
)
#Variables to set file name and file save location.
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$FileCreationDate = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
$FileName = "AzCM_Recs_" + $FileCreationDate + ".csv"
$reportSaveLocation = Join-Path -Path $DesktopPath -ChildPath $FileName

#Variable to run script for a single subscription
$subscriptions = Get-AzSubscription -SubscriptionId "$subscriptionID"

#Starting script to loop through recommendations and build report
$report = @()

foreach ($subscription in $subscriptions) {
    # Set subscription
    Set-AzContext $subscription
    $subscription = Get-AzContext
    $subscriptionName = $subscription.Subscription.Name
    $subId = $subscription.Subscription.Id

    # Get all Azure Cost Management Recommendations for the subscription with Azure Resource Graph (ARG has a limit of 5000. Anything over 5000 will be truncated.)
    $recquery = "advisorresources | where subscriptionId == ""$($subId)"" | where properties.category == 'Cost' | where properties.recommendationTypeId =='e10b1381-5f0a-47ff-8c7b-37bd13d7c974' | extend components = extractall(@""^/subscriptions/(.*)/resourceGroups/(.*)/providers/([a-zA-Z0-9]+\.[a-zA-Z0-9]+/[a-zA-Z0-9]+)/(.*)"", ['id'])[0] |project id, Recommendation=properties.shortDescription.problem, subscriptionId, ResourceGroup=resourceGroup, name=properties.extendedProperties.roleName, CurrentSku=properties.extendedProperties.currentSku, RecommendedSku=properties.extendedProperties.targetSku, CpuPercent=properties.extendedProperties.underutilizedCpuThreshold, MemoryPercent=properties.extendedProperties.underutilizedMemoryThreshold, NetworkPercent=properties.extendedProperties.underutilizedNetworkThreshold, vmResourceId=properties.resourceMetadata.resourceId, properties"
    $recs = Search-azgraph -Query $recquery -First 5000
    
    # Get all VMs with Azure Resource Graph (ARG has a limit of 5000. Anything over 5000 will be truncated.)
    $vmquery = "Resources | where subscriptionId == ""$($subId)"" | where type =~ 'Microsoft.Compute/virtualMachines' | project  resourceID=id, name, location, applicationID=tags.ApplicationID, market=tags.Market, nicID=properties.networkProfile.networkInterfaces[0].id"
    $vms = Search-azgraph -query $vmquery -First 5000
    
    # Get all VM NICs with Azure Resource Graph (ARG has a limit of 5000. Anything over 5000 will be truncated.)
    $nicquery = "Resources | where subscriptionId == ""$($subId)"" | where type =~ 'microsoft.network/networkinterfaces' | project  id, accelnet=properties.enableAcceleratedNetworking"
    $vmNICs = Search-AzGraph -Query $nicquery -First 5000

    Write-Host -ForegroundColor Green "Located" $($recs.Count) "Recommendations within subscription" $($subscriptionName)
    $counterPosition = 1

    foreach ($rec in $recs) {
        Write-Host -ForegroundColor Green "Pulling recommendation for virtual machine" $($rec.Name) "within" $($subscriptionName) "-" $($counterPosition)"/"$($recs.Count)
        $info = "" | Select-Object recommendation, vmName, subscriptionName, subscriptionID, resourceId, vmSKU, recommendedSKU, vmLocation, marketTag, applicationID, cpuPercent, memoryPercent, networkPercent, accelNetEnabled
        
        # Array of VM IDs
        $vmIDs = $vms.resourceID
        # Index of VM IDs
        $vmIDIndex = [array]::IndexOf($vmIDs, $rec.vmResourceId)
        # VM - acquired from $vms object
        $vm = $vms[$vmIDIndex]

        # Array of NIC IDs
        $vmNicIds = $vmNics.Id
        # Index of NIC IDs
        $vmNicIdIndex = [array]::IndexOf($vmNicIds, $vm.networkInterface)
        # VM NIC - acquired from $vmNics object 
        $vmNic = $vmNics[$vmNicIdIndex]

        $info.vmName = $vm.Name
        $info.vmLocation = $vm.Location
        $info.recommendation = $rec.recommendation
        $info.resourceId = $rec.vmResourceId
        $info.marketTag = $vm.Market
        $info.applicationID = $vm.ApplicationID
        $info.vmSKU = $rec.CurrentSku
        $info.recommendedSKU = $rec.recommendedSKU
        $info.subscriptionName = $subscriptionName
        $info.subscriptionID = $subId
        $info.cpuPercent = $rec.CpuPercent
        $info.memoryPercent = $rec.memoryPercent
        $info.networkPercent = $rec.networkPercent
        $info.accelNetEnabled = $vmNic.accelNet
        $report+=$info
        $counterPosition++

    }
}
$report | Format-Table recommendation, vmName, subscriptionName, subscriptionID, resourceId, vmSKU, recommendedSKU, vmLocation, marketTag, applicationID, cpuPercent, memoryPercent, networkPercent, accelNetEnabled
$report | Export-Csv -Path $reportSaveLocation -NoTypeInformation

