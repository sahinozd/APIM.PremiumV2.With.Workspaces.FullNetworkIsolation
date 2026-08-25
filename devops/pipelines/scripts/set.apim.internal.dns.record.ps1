# Upserts the private DNS A record for a VNet-injected (Internal mode) API Management instance's
# default gateway hostname. VNet injection has no automatic DNS registration the way private
# endpoints get, so the caller is responsible for mapping the dynamically-assigned private VIP to the
# instance's hostname ("<name>.azure-api.net") themselves.
#
# Zone shape: per Microsoft's guidance for VNet injection, the zone is named after the full instance
# hostname (e.g. "apim-v2-org-core-o.azure-api.net"), not a shared "privatelink.*" suffix zone, with
# the record at the zone apex ("@"). See platform.network.bicep.
#
# The VIP has no supported discovery API (confirmed against a live deployment: CLI, raw REST, Resource
# Graph, Portal, Network Watcher all come back empty; the internal load balancer backing injection
# lives in a Microsoft-internal subscription invisible to any customer-facing API). Workaround: since
# Application Gateway sits in the same VNet, its backend-health check can verify a candidate IP even
# though no API can read it directly. Azure's documented address allocation (5 reserved + 2 instance
# units + 1 load balancer) puts the VIP reliably among the first few usable addresses, so this script
# walks candidates in that range and upserts the DNS record to whichever one reports Healthy. Requires
# Application Gateway to exist; it's the only available prober, and this fails outright without one
# rather than guessing blind. Revisit if Microsoft ever exposes the VIP through a supported API.
#
# Idempotent: the VIP can change if the injection subnet is recreated, so this re-verifies the
# existing record's health first (fast path) before falling back to a full candidate sweep.

param (
    [Parameter(Mandatory = $true)]
    [string]$ApiManagementName,

    [Parameter(Mandatory = $true)]
    [string]$PrivateDnsZoneName,

    [Parameter(Mandatory = $true)]
    [string]$PrivateDnsZoneResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $true)]
    [string]$VirtualNetworkResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SubnetName,

    # Required for auto-discovery: Application Gateway's backend-health check is the only available
    # connectivity prober. Existence (not just this name being passed) is checked before proceeding.
    [Parameter(Mandatory = $false)]
    [string]$ApplicationGatewayName,

    [Parameter(Mandatory = $false)]
    [string]$ApplicationGatewayResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ApplicationGatewayBackendPoolName = "apim-backend-pool",

    [Parameter(Mandatory = $false)]
    [string]$ApplicationGatewayBackendHttpSettingsName = "apim-backend-http-settings",

    # How many candidate addresses to try, starting after Azure's reserved block. 20 is generous
    # headroom over the documented 3-address allocation (2 instance units + 1 load balancer).
    [Parameter(Mandatory = $false)]
    [int]$MaxCandidates = 20,

    # Seconds to wait after each DNS change before checking backend health, giving Application Gateway
    # time to re-resolve the backend FQDN. Not independently verified against a live deployment for
    # exact timing. Increase if candidates are consistently reported unhealthy despite being correct.
    [Parameter(Mandatory = $false)]
    [int]$WaitSecondsPerCandidate = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-ApimDnsRecord {
    param ([string]$IpAddress)

    $existingRecordSet = Get-AzPrivateDnsRecordSet -ResourceGroupName $PrivateDnsZoneResourceGroupName -ZoneName $PrivateDnsZoneName -Name "@" -RecordType A -ErrorAction SilentlyContinue

    if ($existingRecordSet) {
        $existingIp = $existingRecordSet.Records | Select-Object -First 1 -ExpandProperty Ipv4Address
        if ($existingIp -eq $IpAddress) {
            return
        }
        $existingRecordSet.Records.Clear()
        $existingRecordSet.Records.Add((New-AzPrivateDnsRecordConfig -IPv4Address $IpAddress))
        Set-AzPrivateDnsRecordSet -RecordSet $existingRecordSet | Out-Null
    } else {
        New-AzPrivateDnsRecordSet -ResourceGroupName $PrivateDnsZoneResourceGroupName -ZoneName $PrivateDnsZoneName -Name "@" -RecordType A -Ttl 3600 -PrivateDnsRecords (New-AzPrivateDnsRecordConfig -IPv4Address $IpAddress) | Out-Null
    }
}

function Test-ApimBackendHealthy {
    $health = Get-AzApplicationGatewayBackendHealth -ResourceGroupName $ApplicationGatewayResourceGroupName -Name $ApplicationGatewayName -ErrorAction Stop
    foreach ($pool in $health.BackendAddressPools) {
        if ($pool.BackendAddressPool.Id -notlike "*/$ApplicationGatewayBackendPoolName") { continue }
        foreach ($settings in $pool.BackendHttpSettingsCollection) {
            if ($settings.BackendHttpSettings.Id -notlike "*/$ApplicationGatewayBackendHttpSettingsName") { continue }
            foreach ($server in $settings.Servers) {
                if ($server.Health -eq "Healthy") { return $true }
            }
        }
    }
    return $false
}

# ApplicationGatewayName/ResourceGroupName are always passed by the pipeline (deterministic naming,
# same as every other resource name here) regardless of whether Application Gateway is actually
# configured for this environment. So existence, not just presence of the parameter, is what decides
# whether auto-discovery is possible.
$applicationGatewayExists = $false
if ($ApplicationGatewayName) {
    $applicationGatewayExists = $null -ne (Get-AzApplicationGateway -ResourceGroupName $ApplicationGatewayResourceGroupName -Name $ApplicationGatewayName -ErrorAction SilentlyContinue)
}

if (-not $applicationGatewayExists) {
    Write-Host "##[error] No Application Gateway found (not configured for this environment, or not yet deployed). There is no way to discover or verify the API Management private VIP without it, since it's the only resource inside the VNet that can act as a connectivity prober. DNS for the injected APIM instance cannot be configured automatically until an Application Gateway exists."
    exit 1
}

# Resolve the injection subnet's address range so candidates come from the correct block.
$virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $VirtualNetworkResourceGroupName -Name $VirtualNetworkName -ErrorAction Stop
$subnet = $virtualNetwork.Subnets | Where-Object { $_.Name -eq $SubnetName }
if (-not $subnet) {
    Write-Host "##[error] Subnet '$SubnetName' not found in virtual network '$VirtualNetworkName'."
    exit 1
}
$subnetCidr = $subnet.AddressPrefix[0]
$networkBase = $subnetCidr.Split('/')[0]
$baseOctets = $networkBase.Split('.') | ForEach-Object { [int]$_ }
$baseAsInt = ($baseOctets[0] -shl 24) + ($baseOctets[1] -shl 16) + ($baseOctets[2] -shl 8) + $baseOctets[3]

function ConvertTo-IpString {
    param ([long]$IntValue)
    $o1 = ($IntValue -shr 24) -band 255
    $o2 = ($IntValue -shr 16) -band 255
    $o3 = ($IntValue -shr 8) -band 255
    $o4 = $IntValue -band 255
    return "$o1.$o2.$o3.$o4"
}

# Azure reserves the first 4 addresses (network, gateway, 2x DNS) and the last (broadcast) in every
# subnet. Candidates start at .4, immediately after that reserved block.
$candidateStart = $baseAsInt + 4
$candidates = 0..($MaxCandidates - 1) | ForEach-Object { ConvertTo-IpString -IntValue ($candidateStart + $_) }

# Fast path: if a record already exists and is already healthy, don't touch anything.
$existingRecordSet = Get-AzPrivateDnsRecordSet -ResourceGroupName $PrivateDnsZoneResourceGroupName -ZoneName $PrivateDnsZoneName -Name "@" -RecordType A -ErrorAction SilentlyContinue
if ($existingRecordSet) {
    $existingIp = $existingRecordSet.Records | Select-Object -First 1 -ExpandProperty Ipv4Address
    Write-Host "Existing A record found ($existingIp). Checking whether it's still healthy before searching."
    if (Test-ApimBackendHealthy) {
        Write-Host "Existing record is still healthy. No change needed."
        exit 0
    }
    Write-Host "Existing record is no longer healthy (VIP may have changed). Starting candidate search."
}

Write-Host "Searching for the API Management internal VIP in $subnetCidr (candidates: $($candidates[0]) - $($candidates[-1]))..."

foreach ($candidate in $candidates) {
    Write-Host "--- Trying $candidate ---"
    Set-ApimDnsRecord -IpAddress $candidate
    Start-Sleep -Seconds $WaitSecondsPerCandidate

    if (Test-ApimBackendHealthy) {
        Write-Host "Found it: $candidate is healthy. A record upsert complete."
        exit 0
    }
}

Write-Host "##[error] Exhausted $MaxCandidates candidates ($($candidates[0]) - $($candidates[-1])) in $subnetCidr without finding a healthy backend. The VIP may be outside this range (increase MaxCandidates), Application Gateway may not have finished provisioning yet, or something else is blocking connectivity (check NSG rules). The DNS record has been left pointing at the last candidate tried ($($candidates[-1]))."
exit 1
