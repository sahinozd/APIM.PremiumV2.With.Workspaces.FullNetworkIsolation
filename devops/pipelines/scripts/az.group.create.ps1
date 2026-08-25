param(
    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# If location is unresolved/missing, try to use the existing RG location.
$locationMissingOrUnresolved = [string]::IsNullOrWhiteSpace($Location) -or ($Location -match '^\$\(.+\)$')
if ($locationMissingOrUnresolved) {
    $existingLocation = az group show --name $ResourceGroupName --query location -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingLocation)) {
        Write-Host "Resource group '$ResourceGroupName' already exists in location '$existingLocation'."
        return
    }

    throw "Location is not resolved. Define pipeline variable 'hip_workload_location' (variable group or pipeline variable) for first-time resource group creation."
}

az group create --name $ResourceGroupName --location $Location

if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI group create failed with exit code $LASTEXITCODE."
}
