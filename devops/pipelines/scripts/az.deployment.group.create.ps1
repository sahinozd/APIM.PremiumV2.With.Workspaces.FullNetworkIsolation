param(
    [Parameter(Mandatory = $true)]
    [string]$ParametersFile,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$TemplateFile,

    [string[]]$TemplateParameters = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$azArguments = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroupName,
    "--template-file", $TemplateFile,
    "--parameters", $ParametersFile
)

foreach ($templateParameter in $TemplateParameters) {
    if (-not [string]::IsNullOrWhiteSpace($templateParameter)) {
        $azArguments += @("--parameters", $templateParameter)
    }
}

az @azArguments

if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI group deployment failed with exit code $LASTEXITCODE."
}
