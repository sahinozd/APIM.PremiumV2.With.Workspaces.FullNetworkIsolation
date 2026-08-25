# Sealing the Gateway, minimal working sample

A self-contained, deployable extraction of the Bicep behind ["Sealing the Gateway"](https://sahinozdemir.nl) (part 2 of the Azure API Management v2 series, following [part 1](https://sahinozdemir.nl/deploying-azure-api-management-v2-with-vnet-injection-workspaces-and-a-workspace-gateway-the-parts-nobody-documented/)):

- API Management v2 (PremiumV2), **main gateway in Internal mode**, no public inbound of its own
- A **workspace gateway**, also Internal, serving two sample workspaces
- **Application Gateway (WAF_v2)** as the only public entry point, routing to both the main gateway and the workspace gateway
- The pipeline validation and DNS-discovery scripts that make the above actually reachable, since VNet injection has no supported API to read its own private IP

This folder is pruned down from the full Hybrid Integration Platform repo to *only* what this pattern needs. Read [What was removed and why](#what-was-removed-and-why) before you go looking for Service Bus, alerting, or auth, they're deliberately not here.

## Architecture

```
Internet
   |  443 / HTTPS
   v
Application Gateway (WAF_v2, OWASP 3.2, Prevention)      [sn-*-agw, public, undelegated]
   |
   |--> APIM main gateway (PremiumV2, Internal)           [sn-*-apim, Internal]
   |
   `--> Workspace gateway "main" (WorkspaceGatewayPremium) [sn-*-apim-gw-main, Internal]
            |
            `-- serves workspaces: sample-workspace-a, sample-workspace-b

All of the above lives in one VNet (vnet-{org}-core-{env}), deployed by the
network template. No workload VNet, no peering, single resource group per tier.
```

## File map

```
README.md

network/pipeline/
  pipeline.yml                          Azure DevOps pipeline entry point for the network deployment

core/pipeline/
  pipeline.yml                          Azure DevOps pipeline entry point for the core deployment

network/deployment/
  templates/platform.network.resources.bicep      entry point: builds the VNet + APIM private DNS zone
  parameters/platform.network.resources.parameters.bicepparam   #{token}# values for the pipeline path

core/deployment/
  templates/platform.core.resources.bicep         entry point: builds APIM + workspace gateway + Application Gateway
  parameters/platform.core.resources.parameters.bicepparam      #{token}# values for the pipeline path

devops/bicep/templates/
  platform.network.bicep               orchestration: VNet, private DNS zone, VNet link
  platform.core.bicep                  orchestration: subnets, NSGs, APIM module, App Gateway module
  modules/
    virtual.network.bicep              creates the VNet
    private.dns.zone.bicep             creates a private DNS zone (+ optional A record)
    private.dns.vnet.link.bicep        links a private DNS zone to a VNet
    subnet.bicep                       creates one subnet + associates its NSG
    network.security.group.bicep       creates one NSG from a flattened rule list
    api.management.bicep               APIM service, workspaces, workspace gateways, configConnections
    application.gateway.bicep          WAF policy + Application Gateway + per-gateway backend routing
  types/
    generic.types.bicep                integrationType and its sub-types
    module.types.bicep                 apiManagementConfigurationType, applicationGatewayConfigurationType
    platform.core.types.bicep          mainCoreConfigurationType (core entry point's input contract)
    platform.network.types.bicep       mainNetworkConfigurationType (network entry point's input contract)

devops/pipelines/
  scripts/
    az.group.create.ps1                                    idempotent resource group creation
    az.deployment.group.create.ps1                          thin az deployment group create wrapper
    validate.apim.applicationgateway.prerequisites.ps1       fail-fast config gate, run before deploying
    set.apim.internal.dns.record.ps1                         finds the main gateway's VIP, writes the DNS record
  templates/
    pipeline.core.template.yml / pipeline.network.template.yml    sourceRoot + stage template wiring
    stages/stages.core.yml / stages.network.yml                    the "Ontwikkel" (dev) deploy stage
    jobs/jobs.deploy.platform.core.infra.yml / ...network...        Azure DevOps deployment-job wrapper
    steps/deploy/platform.core.infra.yml / ...network...            the actual step sequence (validate, deploy, set DNS)
```

Two ways to run this: the **Azure CLI walkthrough** below (fastest way to try it out, no Azure DevOps needed), or the **Azure DevOps pipeline** (`core/pipeline/pipeline.yml` and `network/pipeline/pipeline.yml`), documented after it. Both drive the exact same Bicep.

## Prerequisites

- An Azure subscription, with **PremiumV2 API Management available in your target region**, check [Microsoft's regional availability list](https://learn.microsoft.com/en-us/azure/api-management/v2-service-tiers-overview) before picking a region; not every region has it.
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) with the Bicep tooling (`az bicep install`), or the standalone `bicep` CLI.
- PowerShell 7+ with the `Az` module (`Install-Module Az`) for the two pipeline scripts.
- Contributor rights on the target subscription (or at minimum on the resource groups you create below).
- A TLS certificate as a base64-encoded PFX for the Application Gateway listener. Self-signed is fine for trying this out:

  ```powershell
  $cert = New-SelfSignedCertificate -DnsName "agw-demo.example.com" -CertStoreLocation "cert:\CurrentUser\My" -KeyExportPolicy Exportable -KeySpec KeyExchange
  $pwd  = ConvertTo-SecureString -String "ChangeMe123!" -Force -AsPlainText
  Export-PfxCertificate -Cert $cert -FilePath ".\agw-demo.pfx" -Password $pwd
  $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes(".\agw-demo.pfx"))
  $b64 | Out-File ".\agw-demo.pfx.b64" -NoNewline
  ```

  Browsers will flag a self-signed cert; that's expected for a local test. Use a real certificate for anything beyond a smoke test.

## Deploy via Azure CLI

All commands assume `bash`/`pwsh` in the repo root of this folder, and that you're logged in (`az login`) with the right subscription selected (`az account set --subscription <id>`).

Pick your naming values once and reuse them everywhere below:

```bash
ORG_NAME="contoso"          # OrganizationName
ORG_SHORT="con"             # OrganizationShortName, max 4 chars
ENV_LETTER="o"               # o | t | a | p
LOCATION="norwayeast"        # must have PremiumV2 APIM available
WORKLOAD_NAME="sample"
WORKLOAD_SHORT="smp"
```

### 1. Deploy the network

```bash
az group create -n "rg-${ORG_NAME}-network-${ENV_LETTER}" -l $LOCATION

az deployment group create \
  -g "rg-${ORG_NAME}-network-${ENV_LETTER}" \
  --template-file network/deployment/templates/platform.network.resources.bicep \
  --parameters \
    AddressSpaceVirtualNetwork="10.0.0.0/16" \
    OrganizationName=$ORG_NAME \
    OrganizationShortName=$ORG_SHORT \
    EnvironmentLetter=$ENV_LETTER \
    WorkloadName=$WORKLOAD_NAME \
    WorkloadShortName=$WORKLOAD_SHORT
```

This creates the VNet (`vnet-{org}-core-{env}`) and the private DNS zone for APIM's own hostname (empty for now, the record gets written in step 4).

### 2. Validate the config before spending a PremiumV2 activation attempt on it

PremiumV2 activation is slow and rate-limited per subscription (roughly a 60-minute throttle window). This script catches dead-end combinations, Internal mode without an Application Gateway, or injection on a non-PremiumV2 SKU, before you burn that window on a deployment that was never going to work.

```pwsh
pwsh ./devops/pipelines/scripts/validate.apim.applicationgateway.prerequisites.ps1 `
  -ApiManagementInternalSubnetAddressSpace "10.0.1.0/24" `
  -ApplicationGatewaySubnetAddressSpace "10.0.5.0/24" `
  -ApplicationGatewaySslCertificateData (Get-Content ./agw-demo.pfx.b64 -Raw) `
  -ApplicationGatewaySslCertificatePassword "ChangeMe123!" `
  -ApiManagementSku "PremiumV2"
```

### 3. Deploy core: APIM, workspace gateway, Application Gateway

```bash
az group create -n "rg-${ORG_NAME}-core-${ENV_LETTER}" -l $LOCATION

az deployment group create \
  -g "rg-${ORG_NAME}-core-${ENV_LETTER}" \
  --template-file core/deployment/templates/platform.core.resources.bicep \
  --parameters \
    AddressSpaceCoreApimanagementInternal="10.0.1.0/24" \
    AddressSpaceCoreApimanagementGatewayMain="10.0.9.0/24" \
    ApiManagementGatewayMainVirtualNetworkType="Internal" \
    AddressSpaceCoreApplicationGateway="10.0.5.0/24" \
    ApplicationGatewaySslCertificateData="$(cat agw-demo.pfx.b64)" \
    ApplicationGatewaySslCertificatePassword="ChangeMe123!" \
    ApiManagementPublisherEmail="you@example.com" \
    ApiManagementPublisherName="Sample" \
    ApiManagementSku="PremiumV2" \
    WorkloadName=$WORKLOAD_NAME \
    WorkloadShortName=$WORKLOAD_SHORT \
    EnvironmentLetter=$ENV_LETTER \
    OrganizationName=$ORG_NAME \
    OrganizationShortName=$ORG_SHORT
```

This is the long step, PremiumV2 provisioning with VNet injection commonly takes 30–60+ minutes. Grab a coffee.

### 4. Write the DNS record for the main gateway's private IP

VNet injection doesn't register DNS automatically the way private endpoints do, and there is no supported API to read the injected instance's private IP (confirmed against CLI, REST, Resource Graph, Portal, and Network Watcher, all come back empty). This script finds it by probing candidate addresses against Application Gateway's own backend-health check, since Application Gateway is the only thing in the VNet that can see whether a candidate address is actually the right one.

```pwsh
pwsh ./devops/pipelines/scripts/set.apim.internal.dns.record.ps1 `
  -ApiManagementName "apim-v2-${ORG_SHORT}-core-${ENV_LETTER}" `
  -PrivateDnsZoneName "apim-v2-${ORG_SHORT}-core-${ENV_LETTER}.azure-api.net" `
  -PrivateDnsZoneResourceGroupName "rg-${ORG_NAME}-network-${ENV_LETTER}" `
  -VirtualNetworkName "vnet-${ORG_SHORT}-core-${ENV_LETTER}" `
  -VirtualNetworkResourceGroupName "rg-${ORG_NAME}-network-${ENV_LETTER}" `
  -SubnetName "sn-${ORG_SHORT}-core-apim-${ENV_LETTER}" `
  -ApplicationGatewayName "agw-${ORG_SHORT}-core-${ENV_LETTER}" `
  -ApplicationGatewayResourceGroupName "rg-${ORG_NAME}-core-${ENV_LETTER}"
```

It walks candidate addresses, writes each as the DNS A record, waits, and checks Application Gateway's backend health, so this can take a few minutes per candidate tried. It's idempotent: re-running it re-checks the existing record's health first and does nothing if it's still correct.

### 5. Verify

```bash
AGW_FQDN=$(az deployment group show \
  -g "rg-${ORG_NAME}-core-${ENV_LETTER}" \
  -n "core-core-template" \
  --query "properties.outputs.applicationGatewayFqdn.value" -o tsv)

curl -k "https://${AGW_FQDN}/status-0123456789abcdef"
```

A `200 OK` with an empty body means Application Gateway can reach the injected APIM main gateway over its private path. `-k` is needed only if you used the self-signed certificate from the prerequisites section.

## Azure DevOps variable library

The CLI walkthrough above needs none of this. If you run the pipeline path instead (`core/pipeline/pipeline.yml` and `network/pipeline/pipeline.yml`), both pull their values from a **variable group** (the platform calls it `HybridIntegrationPlatform-{env}`, see `stages.core.yml` / `stages.network.yml`), and the `core`/`network` entry points read theirs through a `*.bicepparam` file using `#{token}#` placeholders that Azure DevOps' `qetza.replacetokens` task substitutes at build time. Both `.bicepparam` files are included in this sample (`core/deployment/parameters/` and `network/deployment/parameters/`), already using the tokens below, so defining the variable group is all that's left to make the pipeline path work.

**`network/deployment/parameters/platform.network.resources.parameters.bicepparam`** (backs `network/deployment/templates/platform.network.resources.bicep`):

| Bicep parameter | `#{token}#` | Deploy-step CLI equivalent (§1) |
|---|---|---|
| `AddressSpaceVirtualNetwork` | `#{hip_vnet_addressspace}#` | `AddressSpaceVirtualNetwork` |
| `WorkloadName` | `#{hip_workload_name}#` | `WorkloadName` |
| `WorkloadShortName` | `#{hip_workload_shortname}#` | `WorkloadShortName` |
| `EnvironmentLetter` | `#{hip_do_environmentletter}#` | `EnvironmentLetter` |
| `OrganizationName` | `#{hip_organization_name}#` | `OrganizationName` |
| `OrganizationShortName` | `#{hip_organization_shortname}#` | `OrganizationShortName` |

The full platform's version of this file also carries `AddressSpaceCoreVirtualNetwork` (`#{hip_vnet_core_addressspace}#`) and `CoreSubscriptionId` (`#{hip_core_subscription_id}#`) for the workload/core VNet split this sample doesn't have; leave those out.

**`core/deployment/parameters/platform.core.resources.parameters.bicepparam`** (backs `core/deployment/templates/platform.core.resources.bicep`):

| Bicep parameter | `#{token}#` | Deploy-step CLI equivalent (§3) |
|---|---|---|
| `AddressSpaceCoreApimanagementInternal` | `#{hip_subnet_core_apimanagement_internal}#` | `AddressSpaceCoreApimanagementInternal` |
| `AddressSpaceCoreApimanagementGatewayMain` | `#{hip_subnet_core_apimanagement_gateway_main}#` | `AddressSpaceCoreApimanagementGatewayMain` |
| `ApiManagementGatewayMainVirtualNetworkType` | `#{hip_apimanagement_gateway_main_virtual_network_type}#` | `ApiManagementGatewayMainVirtualNetworkType` |
| `AddressSpaceCoreApplicationGateway` | `#{hip_subnet_core_applicationgateway}#` | `AddressSpaceCoreApplicationGateway` |
| `ApplicationGatewaySslCertificateData` | `#{hip_apimanagement_agw_ssl_certificate_data}#` | `ApplicationGatewaySslCertificateData` |
| `ApplicationGatewaySslCertificatePassword` | `#{hip_apimanagement_agw_ssl_certificate_password}#` | `ApplicationGatewaySslCertificatePassword` |
| `ApiManagementPublisherEmail` | `#{hip_apimanagement_publisher_email}#` | `ApiManagementPublisherEmail` |
| `ApiManagementPublisherName` | `#{hip_apimanagement_publisher_name}#` | `ApiManagementPublisherName` |
| `ApiManagementSku` | `#{hip_apimanagement_sku}#` | `ApiManagementSku` |
| `WorkloadName` | `#{hip_workload_name}#` | `WorkloadName` |
| `WorkloadShortName` | `#{hip_workload_shortname}#` | `WorkloadShortName` |
| `EnvironmentLetter` | `#{hip_do_environmentletter}#` | `EnvironmentLetter` |
| `OrganizationName` | `#{hip_organization_name}#` | `OrganizationName` |
| `OrganizationShortName` | `#{hip_organization_shortname}#` | `OrganizationShortName` |

The full platform's version of this file also carries `AddressSpaceCoreServicebusBackend`, `AlertEmailAddress`, `AreAlertsEnabled`, `SkuServiceBus`, `TenantId`, and `TenantName`, all removed here along with Service Bus, alerting, and the Entra app registration, see [What was removed and why](#what-was-removed-and-why).

One variable is used directly as a pipeline `$(...)` variable rather than as a bicepparam token: **`hip_workload_location`**, the `-Location` argument on both `az group create` calls in `platform.core.infra.yml` (the CLI walkthrough's `$LOCATION` above).

**Secret variables**: `hip_apimanagement_agw_ssl_certificate_data` and `hip_apimanagement_agw_ssl_certificate_password` need to be marked *secret* in the variable group, secret variables aren't automatically exposed to the replace-tokens task the way plain ones are, so confirm your pipeline step maps them explicitly (an `env:` block, or an equivalent) if substitution doesn't pick them up.

## Deploy via Azure DevOps pipeline

Everything below assumes an Azure DevOps project with this repository added as a source (import the GitHub repo, or push it into an Azure Repos project, either works) and the `qetza.replacetokens` extension installed from the Marketplace, the pipeline steps depend on it.

1. **Create the variable group.** Project settings → Pipelines → Library → *+ Variable group*, name it `HybridIntegrationPlatform-o` (the `-o` suffix matches `EnvironmentLetter: "o"` in `stages.core.yml`/`stages.network.yml`; use a different suffix and a matching stage if you want a different environment letter). Add every variable from the two tables above, plus `hip_workload_location`. Mark `hip_apimanagement_agw_ssl_certificate_data` and `hip_apimanagement_agw_ssl_certificate_password` as secret (the padlock icon next to the value).

2. **Create a service connection.** Project settings → Service connections → *New service connection* → Azure Resource Manager, scoped to the subscription you're deploying into. Name it to match the pipelines' `serviceConnectionBase` default plus the environment suffix the stage templates append, e.g. a connection named `Azure ARM - apim-full-isolation-sample - Ontwikkel` matches `core/pipeline/pipeline.yml`'s default unchanged. Either name it exactly that, or override `serviceConnectionBase` when you create the pipeline in the next step.

3. **Create the two pipelines.** Pipelines → *New pipeline* → point it at this repo → "Existing Azure Pipelines YAML file" → `/network/pipeline/pipeline.yml`. Repeat for `/core/pipeline/pipeline.yml`. Name them so it's obvious which is which, e.g. "network-infra" and "core-infra".

4. **Run network first, then core.** `platform.core.bicep` looks up the VNet built by the network deployment as an *existing* resource, so the network pipeline has to succeed at least once before the core pipeline can. After that, re-running either independently is safe.

5. **The core pipeline's DNS step still needs the Application Gateway to exist first.** It's the same "Set API Management internal DNS record" step from the CLI walkthrough's §4, now running automatically as the last step of the core pipeline's single job, conditioned on both `hip_subnet_core_apimanagement_internal` and `hip_subnet_core_applicationgateway` being set in the variable group. Leave either blank to skip Internal-mode APIM or Application Gateway entirely, the same opt-in/opt-out behavior the CLI parameters give you.

Verification is the same `curl` smoke test as CLI walkthrough §5, just read `applicationGatewayFqdn` from the pipeline run's deployment output (or `az deployment group show`, same command) instead of a shell variable.

## What was removed and why

The full platform repo bundles this pattern together with several unrelated concerns. All of it was stripped out here so the sample only carries what's needed to stand up private APIM + workspace gateway + WAF Application Gateway:

| Removed | Was for | Where it lived |
|---|---|---|
| Service Bus namespace + subnet + private endpoint | Messaging backbone for the wider integration platform | `platform.core.bicep`, `platform.core.types.bicep` |
| Action group, resource-health alerts | Ops alerting on APIM/Application Gateway health | `platform.core.bicep`, `api.management.bicep`, `application.gateway.bicep`, both type files |
| Log Analytics workspace, diagnostic settings | Raw log/metric export | Same files as above |
| Application Insights, APIM request-level logger | Per-API tracing/correlation | `platform.core.bicep`, `api.management.bicep` |
| Entra app registration for APIM's OAuth2 audience | Auth on published APIs | `platform.core.bicep` (`entraApiManagementAppRegistration` module, not included) |
| Workload VNet + VNet peering | Backend reachability from a separate application VNet | `platform.network.bicep`, `platform.network.types.bicep` |
| `privatelink.*` DNS zones for Key Vault, Storage, App Service, Service Bus | Private endpoint resolution for those services | `platform.network.bicep` |

None of these are hard to add back, they follow the same module pattern as everything that's here, but they'd have padded this sample with resources and parameters that don't touch the isolation pattern the two blog posts are actually about.

## Known gotchas

- **The `apim-v2-` naming.** `platform.core.bicep` names the service `apim-v2-{org}-core-{env}` (there's a `// TODO: change back to apim- without v2` comment right above it in the source). Match this exactly in the DNS script's `-ApiManagementName` and `-PrivateDnsZoneName` arguments, it's easy to typo out the `v2` and have the script silently target a resource that doesn't exist.
- **The Azure Portal will show a "De service is onderbroken" ("the service is disrupted") banner** on the APIM Overview page the moment the main gateway goes Internal. It isn't actually broken, the portal running in your browser just can't reach a management surface that's no longer public. Check the SLA/scale/API-count fields below the banner; if those resolve, the service is fine.
- **Internal mode is create-time-only in one direction, not the other.** Going from no VNet injection to injected requires recreating the instance. Flipping an already-injected instance between `External` and `Internal` (`ApiManagementGatewayMainVirtualNetworkType`) is a cheap in-place property update.
- **The Application Gateway subnet must exist before step 4 works.** `set.apim.internal.dns.record.ps1` uses Application Gateway's backend health as its only way to verify a candidate IP; without it, DNS for the injected instance can't be configured at all. `validate.apim.applicationgateway.prerequisites.ps1` (step 2) catches this combination before you get that far.
- **PremiumV2 provisioning is slow.** Budget 30–60+ minutes for step 3, and be aware of the ~60-minute per-subscription throttle on PremiumV2 activation attempts mentioned in the validation script, back-to-back failed attempts can compound this.

## Teardown

```bash
az group delete -n "rg-${ORG_NAME}-core-${ENV_LETTER}" --yes --no-wait
az group delete -n "rg-${ORG_NAME}-network-${ENV_LETTER}" --yes --no-wait
```

## Further reading

- [Part 1: VNet injection, workspaces & the workspace gateway](https://sahinozdemir.nl/deploying-azure-api-management-v2-with-vnet-injection-workspaces-and-a-workspace-gateway-the-parts-nobody-documented/)
- Part 2: Sealing the gateway (this sample's source article)
