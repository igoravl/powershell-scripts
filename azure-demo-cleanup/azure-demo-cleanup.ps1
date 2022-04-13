[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [guid[]]
    $SubscriptionIds = @('93a87285-3629-4b5e-bd88-22b1c62fa1d2'),

    [Parameter()]
    [string]
    $ResourceGroupPrefix = 'rg-demo-',

    [Parameter()]
    [string]
    $ResourceGroupSuffix = '',

    [Parameter()]
    [int]
    $DefaultExpirationDays = 3,

    [Parameter()]
    [string]
    $ExpirationTagName = 'days',

    [Parameter()]
    [string]
    $ResourceTagName = 'demo',

    [Parameter()]
    [string]
    $PinnedTagName = 'pinned',

    [Parameter()]
    [switch]
    $IncludeResources,

    [Parameter()]
    [switch]
    $Force
)

### Private functions ###

Function InvokeAzureApi([string] $Url, [string] $Method = 'GET') {
    # Prepare the authentication header
    $azContext = Get-AzContext
    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
    $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
    $authHeader = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $token.AccessToken
    }

    # Call the REST API
    $response = Invoke-RestMethod -Uri $Url -Method $Method -Headers $authHeader

    # Return the response, expanding the 'value' property (if present)
    if ($response.value) { 
        return $response.value 
    }

    return $response 
}

Function ProcessResourceGroup([object]$ResourceGroup) {

    $rg = $ResourceGroup

    if($rgDeletionList | Where-Object {$_.name -eq $rg.name}) {
        # Skipping resource group because it is already scheduled for deletion
        return
    }

    Write-Host "`n$($rg.name)"

    if($rg.tags.$PinnedTagName)
    {
        Write-Host "[-] Resource group is pinned. Ignoring..."
        return
    }

    # Check whether the resource group has a "days" tag
    $days = $rg.tags.days
    $expiration = 0

    if ($days -and -not [int]::TryParse($days, [ref]$expiration)) {
        Write-Host "[!] The value of the 'days' tag is not an integer: '$($days)'. Defaulting to DefaultExpirationDays ($DefaultExpirationDays) days."
        $expiration = $DefaultExpirationDays
    }
    elseif (-not $days) {
        Write-Host "[!] Tag 'days' not present. Defaulting to DefaultExpirationDays ($DefaultExpirationDays) days."
        $expiration = $DefaultExpirationDays
    }

    # Check whether the resource group has been created more than $days days ago
    $created = [datetime]::Parse($rg.createdTime)
    $lifetime = ([datetime]::Now - $created).TotalDays

    if ($lifetime -gt $expiration) {
        # Add the resource group to the deletion list
        Write-Host "[+] Resource group is expired. Adding to deletion list."
        Write-Output $rg
    }
    else {
        # Resource group is not expired. Ignore it.
        Write-Host "[-] Resource group is set to expire in $($expiration - $lifetime) days. Ignoring..."
    }
}

Function ProcessResource([object]$Resource) {
    $obj = $Resource

    if($objDeletionList | Where-Object {$_.name -eq $obj.name}) {
        # Skipping resource because it is already scheduled for deletion
        return
    }

    if($rgDeletionList | Where-Object {$_.name -eq $obj.ResourceGroupName}) {
        # Skipping resource because its resource group is already scheduled for deletion
        return
    }

    Write-Host "`n$($obj.name)"

    if($obj.tags.$PinnedTagName)
    {
        Write-Host "[-] Resource group is pinned. Ignoring..."
        return
    }

    # Check whether the resource group has a "days" tag
    $days = $obj.tags.days
    $expiration = 0

    if ($days -and -not [int]::TryParse($days, [ref]$expiration)) {
        Write-Host "[!] The value of the 'days' tag is not an integer: '$($days)'. Defaulting to DefaultExpirationDays ($DefaultExpirationDays) days."
        $expiration = $DefaultExpirationDays
    }
    elseif (-not $days) {
        Write-Host "[!] Tag 'days' not present. Defaulting to DefaultExpirationDays ($DefaultExpirationDays) days."
        $expiration = $DefaultExpirationDays
    }

    # Check whether the resource group has been created more than $days days ago
    $created = [datetime]::Parse($obj.Properties.creationTime)
    $lifetime = ([datetime]::Now - $created).TotalDays

    if ($lifetime -gt $expiration) {
        # Add the resource group to the deletion list
        Write-Host "[+] Resource is expired. Adding to deletion list."
        Write-Output $obj
    }
    else {
        # Resource group is not expired. Ignore it.
        Write-Host "[-] Resource is set to expire in $($expiration - $lifetime) days. Ignoring..."
    }
}

### Script body ###

# Process each subscription
foreach ($sub in $SubscriptionIds) {

    $azContext = Get-AzContext

    if ($azContext.Subscription.Id -ne $sub) {
        # Set the Azure context to the current subscription
        Set-AzContext -Subscription $sub -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
    }

    # Create collections to hold the deletion lists
    $rgDeletionList = @()
    $objDeletionList = @()

    # Use the REST API to get the resource group list, since the cmdlet does not return creation time
    $restUri = "https://management.azure.com/subscriptions/$sub/resourcegroups?api-version=2019-08-01&%24expand=createdTime,tags"
    $allResourceGroups = InvokeAzureApi -url $restUri -Method Get

    # Find all resource groups with a name matching both the prefix and the suffix
    Write-Host "=== Processing resource groups matching '$("$ResourceGroupPrefix*$ResourceGroupSuffix")' ==="

    $rgDeletionList += $allResourceGroups `
    | Where-Object { $_.name -like "$ResourceGroupPrefix*$ResourceGroupSuffix" } `
    | Foreach-Object { ProcessResourceGroup -ResourceGroup $_ }

    # Find all resource groups with a "demo" tag
    Write-Host "`n=== Processing resource groups with tag ${ResourceTagName}:true ==="

    $rgDeletionList += $allResourceGroups `
    | Where-Object { [bool] $_.tags.$ResourceTagName } `
    | Foreach-Object { ProcessResourceGroup -ResourceGroup $_ }

    # Find all resources with a "demo" tag
    Write-Host "`n=== Processing individual resources with tag ${ResourceTagName}:true ==="

    $objDeletionList += Get-AzResource -TagName $ResourceTagName -TagValue 'true' `
    | Foreach-Object { Get-AzResource -Name $_.Name -ExpandProperties } `
    | Foreach-Object { ProcessResource -Resource $_ }

    # Delete all resource groups in the deletion list
    Write-Host "`n=== Deleting resource groups ===`n"
    
    $rgDeletionList `
    | Foreach-Object { Write-Host $_.name; Remove-AzResourceGroup -Name $_.name -WhatIf | Out-Null }

    # Delete all individual resources in the deletion list
    Write-Host "`n=== Deleting individual resources ===`n"
    
    $objDeletionList `
    | Foreach-Object { Write-Host $_.name; Remove-AzResource -ResourceId $_.Id -WhatIf }
}