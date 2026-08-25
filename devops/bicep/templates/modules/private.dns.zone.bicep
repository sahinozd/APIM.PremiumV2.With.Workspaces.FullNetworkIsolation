@description('Private IP address of the private endpoint.')
param PrivateIpAddress string = ''

@description('DNS zone name (e.g., privatelink.vaultcore.azure.net, privatelink.blob.core.windows.net).')
param PrivateDnsZoneName string

@description('FQDN of the resource for the DNS A record (e.g., myvault.vault.azure.net, mystgacct.blob.core.windows.net).')
param ResourceFqdn string = ''

@description('Optional location (defaults to global for private DNS zones).')
param Location string = 'global'

// Create private DNS zone if it doesn't exist
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: PrivateDnsZoneName
  location: Location
  properties: {}
}

// Create A record for the resource in the private DNS zone when an endpoint IP is supplied.
var recordName = split(ResourceFqdn, '.')[0]

resource aRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = if (!empty(PrivateIpAddress) && !empty(ResourceFqdn)) {
  name: recordName
  parent: privateDnsZone
  properties: {
    aRecords: [
      {
        ipv4Address: PrivateIpAddress
      }
    ]
    ttl: 3600
  }
}

output privateDnsZone object = {
  resourceName: privateDnsZone.name
  resourceId: privateDnsZone.id
}
