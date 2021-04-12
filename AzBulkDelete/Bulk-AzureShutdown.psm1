<#
Shutdown resources
John Savill

Need to auth for PowerShell Azure module

Permissions required:
*/read permission on all objects to see
Microsoft.Compute/virtualMachineScaleSets/deallocate/action VMSS
Microsoft.Compute/virtualMachines/deallocate/action VM
Microsoft.ContainerService/managedClusters/write  AKS
#>

function Bulk-AzureShutdown
{
    Param (
        [Parameter(Mandatory=$true,
        ValueFromPipeline=$false)]
        [String[]]
        $InputCSV,
        [Parameter(Mandatory=$true,
        ValueFromPipeline=$false)]
        [String[]]
        $ExcludeSubList,
        [Parameter(Mandatory=$false,
        ValueFromPipeline=$false)]
        [Switch]
        $Pretend
    )

    $statusGood = $true

    #read in resources
    try {
        $resourceList = Import-Csv -Path $InputCSV
    }
    catch {
        Write-Error "Error reading resource file: `n $_ "
        $statusGood = $false
    }

    #List of protected subs
    try {
        $excludeSubArrayDetail = Import-Csv -Path $ExcludeSubList
        $protectSubList = $excludeSubArrayDetail | select-object -Property 'Sub ID' -ExpandProperty 'Sub ID'
        #[string[]]$protectSubList = Get-Content -Path $ExcludeSubList #OLD CODE IF TEXT FILE
    }
    catch {
        Write-Error "Error reading subscription exception file: `n $_ "
        $statusGood = $false
    }

    if($statusGood)
    {
        #Create array of custom objects for resources
        $resourceObjectArray = @()
        $exemptObjectArray = @()

        $vmcount = 0
        $vmsscount = 0
        $akscount = 0
        $unknowncount = 0

        Write-Output "Performing data analysis`n`n"

        foreach($resource in $resourceList)
        {
            #check the subscription is not in the exception list
            if($protectSubList -contains $resource.subscriptionID) #not case sensitive
            {
                Write-Output "  $($resource.'Resource Name') is in an exempt subscription and will be skipped [$($resource.subscriptionID)]"
                $exemptResource = $true
            }
            else {
                $exemptResource = $false

                #Only count resources that are not exempt
                switch ($resource.'Rsc Type') {
                    'VM' {$vmcount++}
                    'VMSS' {$vmsscount++}
                    'AKS' {$akscount++}
                    Default {$unknowncount++}
                }
            }

            #Custom hash table to convert to custom object
            $resourceEntry = @{'SubName'=$resource.Subscription;
	        'SubID'=$resource.SubscriptionID;
	        'ResourceType'=$resource.'Rsc Type';
	        'ResourceName'=$resource.'Resource Name';
	        'ResourceID'=$resource.RscID;
            'ExemptStatus'=$exemptResource;
            'ActionStatus'='';
            'Information'='';
            }
	        $resourceObject = New-Object -TypeName PSObject -Property $resourceEntry

            if($exemptResource) #we will track the exempt in a separate object array so they cannot be processed by the action code
            {
                $exemptObjectArray += $resourceObject
            }
            else
            {
                $resourceObjectArray += $resourceObject
            }
        } #end of foreach looking at each resource

        $origResourceCount = ($resourceList | Measure-Object).Count
        $actionResourceCount = ($resourceObjectArray | Measure-Object).Count
        $exemptResourceCount = ($exemptObjectArray | Measure-Object).Count

        Write-Output "`n`nOut of $origResourceCount a total of $exemptResourceCount resource[s] are in protected subscriptions and $actionResourceCount will be actioned"
        Write-Output "VM Count :   $vmcount"
        Write-Output "VMSS Count : $vmsscount"
        Write-Output "AKS Count :  $akscount"

        write-output "`nDo you wish to proceed with actions?"
        $userInput = Read-Host -Prompt 'Type YES (upper case) to continue>'

        if($userInput -ceq 'YES') #Must be uppercase
        {
            Write-Output "`nContinuing. Pausing for 10 seconds if need to cancel"
            Start-Sleep -Seconds 10


            Write-Output "`nStarting actions at $(get-date)"
            #Here goes
            foreach($actionObject in $resourceObjectArray)
            {
                Write-Output " - Resource $($actionObject.ResourceName) $($actionObject.ResourceType) will be stopped"

                if(!$Pretend)
                {
                    Set-AzContext -Subscription $actionObject.SubID  > $null #change to the subscription of the object quietly

                    try {
                        $resourceObjInfo  = Get-AzResource -Id $actionObject.ResourceID #get the object based on the known ID
                    }
                    catch {
                        Write-Error "Error finding object $($actionObject.ResourceID)"
                        $actionObject.ActionStatus = "ErrorNotFound"
                    }

                    if($null -ne $resourceObjInfo) #if found an object
                    {
                        switch ($actionObject.ResourceType)
                        {
                            'VM'
                            {
                                try {
                                    $status = Stop-AzVM -Name $resourceObjInfo.Name -ResourceGroupName $resourceObjInfo.ResourceGroupName -Force -NoWait
                                    if($status.StatusCode -ne 'Accepted')   #would be Succeeded if not using NoWait against Status property
                                    {
                                        Write-Error " * Error stopping $($resourceObjInfo.Name) - $($status.status)"
                                        $actionObject.ActionStatus = "ErrorStopping"
                                    }
                                    else {
                                        $actionObject.ActionStatus = "Success"
                                    }
                                }
                                catch {
                                    Write-Error "Error stopping $($resourceObjInfo.Name) $_"
                                    $actionObject.ActionStatus = "ErrorDuringStopAction"
                                }
                            }
                            'VMSS'
                            {
                                try {
                                    $status = Stop-AzVmss -VMScaleSetName $resourceObjInfo.Name -ResourceGroupName $resourceObjInfo.ResourceGroupName -Force -AsJob
                                    if($status.State -eq 'Failed')  #if not asjob we would check -ne 'Succeeded' against .Status but as job we really look for Running and don't want failed
                                    {
                                        Write-Error " * Error stopping $($resourceObjInfo.Name) - $($status.status)"
                                        $actionObject.ActionStatus = "ErrorStopping"
                                    }
                                    else {
                                        $actionObject.ActionStatus = "Success"
                                    }
                                }
                                catch {
                                    Write-Error "Error stopping $($resourceObjInfo.Name) $_"
                                    $actionObject.ActionStatus = "ErrorDuringStopAction"
                                }
                            }
                            'AKS'
                            {

                                $cluster = get-azakscluster -name $resourceObjInfo.Name -ResourceGroupName $resourceObjInfo.ResourceGroupName

                                if(($cluster.AgentPoolProfiles | Where-Object {$_.Mode -eq "System"}).count -eq 0) #if the system pool is 0 its already stopped
                                {
                                    Write-Output " $($resourceObjInfo.Name) is already stopped"
                                    $actionObject.ActionStatus = "Success"
                                    $actionObject.Information = "AlreadyStopped"
                                }
                                else
                                {

                                    if($cluster.AgentPoolProfiles.Type -eq 'VirtualMachineScaleSets') #can only stop if built on VMSS
                                    {
                                        #Write-Output "Resource AKS Cluster $clusterName is VMSS-based and is being stopped"
                                        #https://docs.microsoft.com/en-us/rest/api/aks/managedclusters/stop

                                        <#
                                        #Create token
                                        $accessToken = (Get-AzAccessToken).Token #ARM audience
                                        $authHeader = @{
                                            'Content-Type'='application/json'
                                            'Authorization'='Bearer ' + $accessToken
                                        }

                                        #Submit the REST call
                                        $resp = Invoke-WebRequest -Uri "https://management.azure.com/subscriptions/$($actionObject.SubID)/resourceGroups/$($resourceObjInfo.ResourceGroupName)/providers/Microsoft.ContainerService/managedClusters/$($resourceObjInfo.Name)/stop?api-version=2021-02-01" -Method POST -Headers $authHeader
                                        if($resp.StatusCode -eq 202)
                                        {
                                            write-output "Stop submitted successfully"
                                            $actionObject.ActionStatus = "Success"
                                        }
                                        else
                                        {
                                            write-output "Stop submit failed, $($resp.StatusCode) - $($resp.StatusDescription)"
                                            $actionObject.ActionStatus = "ErrorDuringStopAction"
                                        }
                                        #>
                                        write-output "Skipping AKS currently"
                                        $actionObject.ActionStatus = "Success"
                                        $actionObject.Information = "Skipped"
                                        #az aks stop --name $clusterName --resource-group $clusterRG
                                    }
                                    else
                                    {
                                        Write-Output "Resource AKS Cluster $clusterName is NOT VMSS-based and cannot be stopped.`nUser mode pools could be set to 0 and the system pool to 1 to minimize cost."
                                        $actionObject.ActionStatus = "CannotBeStopped"
                                        <#$nodePools = $cluster.AgentPoolProfiles
                                        foreach($nodePool in $nodePools)
                                        {
                                            if($nodePool.Mode -eq 'System')
                                            {
                                                #Scale to 1 as cannot shut down

                                            }
                                            else
                                            {
                                                #Scale to 0

                                            }
                                            $URLPutContent = "https://management.azure.com/subscriptions/$subID/resourceGroups/$clusterRG/providers/Microsoft.ContainerService/managedClusters/$clusterName?api-version=2020-11-01"
                                            $resp = Invoke-WebRequest -Uri $URLPostContent -Method Put -Headers $authHeader
                                            if($resp.StatusCode -eq 202)
                                            {
                                                write-output "Stop submitted succesfully"
                                            }
                                            else
                                            {
                                                write-output "Stop submit failed, $($resp.StatusCode) - $($resp.StatusDescription)"
                                            }
                                        } #>
                                    } #end of if VMSS based AKS
                                } #end of if not already stopped
                            } #AKS
                            Default {
                                Write-Error " * Resource $($actionObject.ResourceName) $($actionObject.ResourceType) unsupported type"
                                $actionObject.ActionStatus = "UnsupportedObject"
                            }
                        } #end of switch statement for type
                    }
                    else
                    {
                        Write-Error " * Resource $($actionObject.ResourceName) $($actionObject.ResourceType) was not found"
                        $actionObject.ActionStatus = "ObjectNotFound"
                    } #end of if resource not null
                } #end of if pretend
            } #for each object

            Write-Output "`nCompleted actions at $(get-date)"

            #write out to file the exception list of resources
            $exemptObjectArray | ConvertTo-Json | Out-File -FilePath '.\exemptresource.json'
            $exemptCount = ($exemptObjectArray | measure-object).Count

            #write out to file the resources that did not succeed
            $resourceObjectArray | Where-Object {$_.ActionStatus -ne 'Success'} | ConvertTo-Json | Out-File -FilePath '.\errorresource.json'
            $failedCount = ($resourceObjectArray | Where-Object {$_.ActionStatus -ne 'Success'} | Measure-Object).Count

            Write-Output "Completed. Files have been created in local folder for the exempt ($exemptCount) and failed ($failedCount) resources."

        } #if typed Yes
        else
        {
           Write-Output "Aborted."
        }
    } #if status good
}