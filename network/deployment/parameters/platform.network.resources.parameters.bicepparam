using '../templates/platform.network.resources.bicep'

// Values are #{token}# placeholders substituted by Azure DevOps' qetza.replacetokens task from the
// "HybridIntegrationPlatform-{env}" variable group at pipeline run time, see README.md's "Azure
// DevOps variable library" section for what to define.

param AddressSpaceVirtualNetwork = '#{hip_vnet_addressspace}#'

param WorkloadName = '#{hip_workload_name}#'

param WorkloadShortName = '#{hip_workload_shortname}#'

param EnvironmentLetter = any('#{hip_do_environmentletter}#')

param OrganizationName = any('#{hip_organization_name}#')

param OrganizationShortName = any('#{hip_organization_shortname}#')
