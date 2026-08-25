# Validates that the API Management Internal VNet injection + Application Gateway configuration is
# internally consistent before any resource group or deployment is attempted. Failing here is cheap;
# failing after a real deployment attempt can burn a PremiumV2 activation attempt against Azure's
# 60-minute per-subscription throttle for a combination that was never going to work anyway.

param (
    [Parameter(Mandatory = $true)]
    [string]$ApiManagementInternalSubnetAddressSpace,

    [Parameter(Mandatory = $true)]
    [string]$ApplicationGatewaySubnetAddressSpace,

    [Parameter(Mandatory = $true)]
    [string]$ApplicationGatewaySslCertificateData,

    [Parameter(Mandatory = $true)]
    [string]$ApplicationGatewaySslCertificatePassword,

    [Parameter(Mandatory = $true)]
    [string]$ApiManagementSku
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$isApimInternalEnabled = -not [string]::IsNullOrWhiteSpace($ApiManagementInternalSubnetAddressSpace)
$isApplicationGatewayEnabled = -not [string]::IsNullOrWhiteSpace($ApplicationGatewaySubnetAddressSpace)
$hasCertificateData = -not [string]::IsNullOrWhiteSpace($ApplicationGatewaySslCertificateData)
$hasCertificatePassword = -not [string]::IsNullOrWhiteSpace($ApplicationGatewaySslCertificatePassword)

if ($isApimInternalEnabled -and $ApiManagementSku -ne "PremiumV2") {
    Write-Host "##[error] The API Management internal subnet is set, but the API Management SKU is '$ApiManagementSku'. Internal VNet injection is only supported on PremiumV2."
    exit 1
}

if ($isApimInternalEnabled -and -not $isApplicationGatewayEnabled) {
    Write-Host "##[error] The API Management internal subnet is set, but the Application Gateway subnet is empty."
    Write-Host "##[error] The APIM private VIP cannot be discovered through ARM APIs; this deployment uses Application Gateway backend health probing to discover and set the private DNS A record. Without Application Gateway, there is no way to configure DNS for the injected instance."
    exit 1
}

if ($isApplicationGatewayEnabled -and -not $hasCertificateData) {
    Write-Host "##[error] The Application Gateway subnet is set, but the SSL certificate data is empty."
    exit 1
}

if ($isApplicationGatewayEnabled -and -not $hasCertificatePassword) {
    Write-Host "##[error] The Application Gateway subnet is set, but the SSL certificate password is empty."
    exit 1
}

Write-Host "APIM/Application Gateway prerequisite validation passed."
