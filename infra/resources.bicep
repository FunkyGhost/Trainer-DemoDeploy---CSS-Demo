// =====================================================================
// tdd-multi-identity-acr-auth — resources (resource-group scope)
//
// Deploys the full repro lab in one azd up:
//   - VNet + subnet + NSG (SSH)
//   - Public IP + NIC
//   - TWO user-assigned managed identities (the trigger condition)
//   - Azure Container Registry (Basic)
//   - AcrPull + AcrPush for BOTH identities (failure is pure ambiguity,
//     never missing RBAC)
//   - Ubuntu 22.04 self-hosted Azure Pipelines agent VM with BOTH
//     identities attached, bootstrapped to install Docker + Azure CLI
//     and register into the Azure DevOps pool
// =====================================================================

@description('Azure region for all resources.')
param location string

@description('Tags applied to all taggable resources (includes azd-env-name).')
param tags object

@description('Deterministic token used to name resources uniquely.')
param resourceToken string

param adoOrgUrl string
param adoAgentPool string

@secure()
param adoPat string

@secure()
param adminSshPublicKey string

param adminUsername string
param vmSize string
param allowedSshSourceCidr string

@description('Pinned Azure Pipelines agent version. Bump if registration fails on an old build.')
param agentVersion string = '3.248.0'

var uamiAName  = 'id-a-${resourceToken}'
var uamiBName  = 'id-b-${resourceToken}'
var acrName    = 'acr${resourceToken}'
var vnetName   = 'vnet-${resourceToken}'
var subnetName = 'agents'
var nsgName    = 'nsg-${resourceToken}'
var pipName    = 'pip-${resourceToken}'
var nicName    = 'nic-${resourceToken}'
var vmName     = 'vm-agent-${take(resourceToken, 8)}'

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var acrPushRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')

// ---- Identities (the two that cause the ambiguity) ----
resource uamiA 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiAName
  location: location
  tags: tags
}

resource uamiB 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiBName
  location: location
  tags: tags
}

// ---- Azure Container Registry ----
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// Both identities get AcrPull + AcrPush so the only variable is identity resolution.
resource acrPullA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uamiA.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: uamiA.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPushA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uamiA.id, 'AcrPush')
  scope: acr
  properties: {
    roleDefinitionId: acrPushRoleId
    principalId: uamiA.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullB 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uamiB.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: uamiB.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPushB 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uamiB.id, 'AcrPush')
  scope: acr
  properties: {
    roleDefinitionId: acrPushRoleId
    principalId: uamiB.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Network ----
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedSshSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.40.0.0/16' ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.40.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

// ---- cloud-init: install Docker + Azure CLI, register the self-hosted agent ----
// The PAT is passed via customData on a throwaway lab VM. Acceptable for a
// short-lived demo box; run `azd down` to remove everything when finished.
var cloudInit = '''#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io curl tar jq
systemctl enable --now docker
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
id svcagent &>/dev/null || useradd -m -s /bin/bash svcagent
usermod -aG docker svcagent
mkdir -p /opt/agent && cd /opt/agent
curl -sLo agent.tar.gz https://vstsagentpackage.azureedge.net/agent/${agentVersion}/vsts-agent-linux-x64-${agentVersion}.tar.gz
tar zxf agent.tar.gz
chown -R svcagent:svcagent /opt/agent
sudo -u svcagent ./config.sh --unattended --acceptTeeEula --url ${adoOrgUrl} --auth pat --token ${adoPat} --pool ${adoAgentPool} --agent $(hostname) --replace
./svc.sh install svcagent
./svc.sh start
'''

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  // BOTH user-assigned identities attached — this is the trigger condition.
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiA.id}': {}
      '${uamiB.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output identityAClientId string = uamiA.properties.clientId
output identityBClientId string = uamiB.properties.clientId
output agentPublicIp string = pip.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${pip.properties.ipAddress}'
