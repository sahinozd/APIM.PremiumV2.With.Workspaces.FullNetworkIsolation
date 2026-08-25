// Generic types
// Pruned for the "Sealing the Gateway" minimal sample: only the types api.management.bicep,
// application.gateway.bicep, network.security.group.bicep and subnet.bicep actually consume.
// The full platform's generic.types.bicep also carries alertsType, actionGroupType, and several
// per-resource RBAC role-definition types used by modules that aren't part of this sample
// (Service Bus, Key Vault, Storage, Logic Apps Standard, alerting).
@export()
@sealed()
type integrationType = {
  @description('Environment letter used for specific integration / deployment.')
  environmentLetter: 'o' | 't' | 'a' | 'p'
  @description('Full organization name used in resource group naming conventions.')
  organizationName: string
  @description('Short organization identifier used in resource naming conventions.')
  @maxLength(4)
  organizationShortName: string
  @description('Tenant specific information needed for the integration to deploy.')
  tenant: tenantType
  @description('Workload specific details.')
  workload: workloadType
}

type tenantType = {
  @description('Name of the tenant.')
  name: string
  @description('Id of the tenant.')
  id: string
}

type workloadType = {
  @description('Name of the integration itself.')
  integrationName: string
  @description('Name of the workload, e.g. hybrid integration platform.')
  name: string
  @description('Short name of the workload, e.g. hip')
  shortName: string
}
