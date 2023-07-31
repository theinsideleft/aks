##
#Need to have Az CLI, Helm and Kubectl installed
#Need to have the 
##

############
# Set Variables
##############
$AZ_RESOURCE_GROUP="" #Your resource group
$AZ_LOCATION="" #What location you want your resources created in
$AZ_ACR_NAME="" #Name of your Azure Container Registry
$AZ_CLUSTER_NAME="" #Name of your AKS Cluster
$AZ_VNET_NAME="" #Name of your VNET
$AZ_VNET_CIDR="" #CIDR of your VNET
$AZ_AKS_CIDR="" #CIDR of your AKS Cluster Nodes
$AZ_AKS_NAME="subnet-aks" 
$AZ_SVC_LB_CIDR="" #CIDR of your Load Balancer
$AZ_SVC_LB_NAME="subnet-lb"
$AZ_GW_CIDR="" #CIDR of the Application Gateway
$AZ_GW_NAME="subnet-gw"
$AZ_AKS_Service_CIDR="" #CIDR of the AKS Services
$AZ_AKS_DNS_CIDR="" #IP address of the internal AKS DNS Server
$AZ_Internal_LB_IP="" #Internal IP address of the NGINX Load Balancer
$AZ_USER_ASSIGNED_IDENTITY_NAME="" #Managed Identity name. Another Managed identity gets created in node pool resource group when creating the AKS cluster
$AZ_SUBSCRIPTION="" #Get the subscription ID that you are using
$AZ_SERVICE_ACCOUNT_NAME="" # Workflow Identity service account that is created in the AKS Cluster
$AZ_SERVICE_ACCOUNT_NAMESPACE="" #Namespace to use for your applications and service account
$AZ_FEDERATED_IDENTITY_CREDENTIAL_NAME="" #Federated identity credential name that will be linked with the workflow service account
$AZ_APP_Config_Name="" #App Configuration name
$AZ_KeyVault_Name="" #Keyvault name
$AZ_PublicIP_Name="" #Public IP address name
$AZ_DNS_Label="" #DNS Label to attach to the public IP address
$AZ_AppGateway_Name="" #Application Gateway Name
$AZ_StorageAccount_Name="" #Storage account name
$AZ_IP_Address_Allow="" #Your IP address to whitelist in the network settings
$AZ_CertificateName="" #Your Certificate name for TLS termination
$AZ_CertificatePath="" #Path to your TLS certficate. The cert needs to be in pfx format.
$AZ_KeyVault_Certificates_Officer="" #Your azure account so you can add the certificate to the key vault
$AZ_HTTPSListnerName="" #HTTPS Listener to attach the Certificate to
$AZ_APPConfig_File="" #File to store any application settings you want to add to Application Config and Key Vault.

#Lgin to Azure - for the subscription you are using make sure you have owner rights
#az login
#az account set -s $AZ_SUBSCRIPTION

#Create Resource Group
az group create --resource-group $AZ_RESOURCE_GROUP --location $AZ_LOCATION 

#Create Azure Container Registry
az acr create --resource-group $AZ_RESOURCE_GROUP --name $AZ_ACR_NAME --sku Basic

# Create Vnet
az network vnet create -g $AZ_RESOURCE_GROUP -n $AZ_VNET_NAME --address-prefix $AZ_VNET_CIDR

# Create Azure AKS Cluster Subnet
az network vnet subnet create --resource-group $AZ_RESOURCE_GROUP --vnet-name $AZ_VNET_NAME --name $AZ_AKS_NAME --address-prefix $AZ_AKS_CIDR

# Create the subnet for Kubernetes Service Load Balancers
az network vnet subnet create --resource-group $AZ_RESOURCE_GROUP --vnet-name $AZ_VNET_NAME --name $AZ_SVC_LB_NAME --address-prefix $AZ_SVC_LB_CIDR

# Create the subnet for GW
az network vnet subnet create --resource-group $AZ_RESOURCE_GROUP --vnet-name $AZ_VNET_NAME --name $AZ_GW_NAME --address-prefix $AZ_GW_CIDR

#Get the SubnetID
$AZ_SUBNET_ID=$(az network vnet show -g $AZ_RESOURCE_GROUP -n $AZ_VNET_NAME -o tsv --query "subnets[?name=='$AZ_AKS_NAME'].id")

#Create Azure Kubernetes Service cluster.
az aks create --resource-group $AZ_RESOURCE_GROUP --name $AZ_CLUSTER_NAME --generate-ssh-keys --vm-set-type VirtualMachineScaleSets `
  --node-vm-size "Standard_DS2_v2" `
  --load-balancer-sku standard `
  --enable-managed-identity `
  --enable-oidc-issuer `
  --network-plugin azure `
  --network-policy azure `
  --vnet-subnet-id $AZ_SUBNET_ID `
  --attach-acr $AZ_ACR_NAME `
  --node-count 3 `
  --zones 1 `
  --service-cidr $AZ_AKS_Service_CIDR `
  --dns-service-ip $AZ_AKS_DNS_CIDR `
  
#Create the Managed Identity
az identity create --name $AZ_USER_ASSIGNED_IDENTITY_NAME --resource-group $AZ_RESOURCE_GROUP --location $AZ_LOCATION --subscription $AZ_SUBSCRIPTION

#Get the Client ID of the managed Identity
$AZ_USER_ASSIGNED_CLIENT_ID=$(az identity show -n $AZ_USER_ASSIGNED_IDENTITY_NAME -g $AZ_RESOURCE_GROUP --query "clientId" -otsv)


# Get service principal ID of the user-assigned identity
$AZ_SP_ID=$(az identity show --resource-group $AZ_RESOURCE_GROUP --name $AZ_USER_ASSIGNED_IDENTITY_NAME --query principalId --output tsv)


#Get the AKS OIDC_Issuer URl
$AZ_AKS_OIDC_ISSUER=$(az aks show -n $AZ_CLUSTER_NAME -g $AZ_RESOURCE_GROUP --query oidcIssuerProfile.issuerUrl -o tsv)

#Create the federated identity credential between the managed identity, service account issuer
az identity federated-credential create --name $AZ_FEDERATED_IDENTITY_CREDENTIAL_NAME --identity-name $AZ_USER_ASSIGNED_IDENTITY_NAME --resource-group $AZ_RESOURCE_GROUP --issuer $AZ_AKS_OIDC_ISSUER --subject system:serviceaccount:${AZ_SERVICE_ACCOUNT_NAMESPACE}:${AZ_SERVICE_ACCOUNT_NAME}

#Set the AKS Cluster
az aks get-credentials -n $AZ_CLUSTER_NAME -g $AZ_RESOURCE_GROUP
kubectl config use-context $AZ_CLUSTER_NAME

#Install the mutating webhook for the Workload Identity
$AZ_AZURE_TENANT_ID="$(az account show -s $AZ_SUBSCRIPTION --query tenantId -otsv)"
helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts
helm repo update
helm install workload-identity-webhook azure-workload-identity/workload-identity-webhook `
   --namespace azure-workload-identity-system `
   --create-namespace `
   --set azureTenantID="$AZ_AZURE_TENANT_ID"

#Create the workload identity service acccount in AKS
$ServiceAccountString = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $AZ_USER_ASSIGNED_CLIENT_ID
  name: $AZ_SERVICE_ACCOUNT_NAME
  namespace: $AZ_SERVICE_ACCOUNT_NAMESPACE
"@

$ServiceAccountString | kubectl apply -f -

#Check that the service account was created
kubectl get serviceAccounts

#Get the resource id of the ACR
$AZ_ACR_ResourceID=$(az acr show --resource-group $AZ_RESOURCE_GROUP --name $AZ_ACR_NAME --query id --output tsv)

# Get object ID of the Managed identity for the Management Resource Group
$AZ_MGMI_Object_ID=$(az aks show -n $AZ_CLUSTER_NAME -g $AZ_RESOURCE_GROUP --query identityProfile.kubeletidentity.objectId -o tsv)

#Add the role for the managed Id
az role assignment create --assignee-object-id $AZ_MGMI_Object_ID --assignee-principal-type "ServicePrincipal" --scope $AZ_ACR_ResourceID --role acrpull

#Create the App Config
az appconfig create -l $AZ_LOCATION -g $AZ_RESOURCE_GROUP -n $AZ_APP_Config_Name --enable-public-network --sku standard --disable-local-auth false

#Get the resource id of both managed identities
$AZ_MGMI_Resource_ID=$(az aks show -n $AZ_CLUSTER_NAME -g $AZ_RESOURCE_GROUP --query identityProfile.kubeletidentity.resourceId -o tsv)
$AZ_MI_Resource_ID=$(az ad sp show --id $AZ_SP_ID --query alternativeNames -o tsv)

#Add identies to the APP Config
az appconfig identity assign -g $AZ_RESOURCE_GROUP -n $AZ_APP_Config_Name --identities $AZ_MGMI_Resource_ID $AZ_MI_Resource_ID[1]

#Get Resource ID of AppConfig
$AZ_APPConfig_Resource_ID=$(az appconfig show -n $AZ_APP_Config_Name -g $AZ_RESOURCE_GROUP --query id -o tsv)

#Give the Managed Id Data Reader role
az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --scope $AZ_APPConfig_Resource_ID --role "App Configuration Data Reader"

#Add the service endpoints needed for all services to the AKS Subnet
az network vnet subnet update -g $AZ_RESOURCE_GROUP -n $AZ_AKS_NAME --vnet-name $AZ_VNET_NAME --service-endpoints Microsoft.Storage Microsoft.KeyVault

#Create Keyvault - check what network access is granted with this
az keyvault create -l $AZ_LOCATION -g $AZ_RESOURCE_GROUP -n $AZ_KeyVault_Name --enable-rbac-authorization --sku Standard

#Grant the managed-identity access to Key Vault.
$AZ_KeyVault_Scope=$(az keyvault show --resource-group $AZ_RESOURCE_GROUP --name $AZ_KeyVault_Name --query id --output tsv)

az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --role "Key Vault Reader" --scope $AZ_KeyVault_Scope 
az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --role "Key Vault Secrets Officer" --scope $AZ_KeyVault_Scope 
az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --role "Key Vault Secrets User" --scope $AZ_KeyVault_Scope 
#Had to grant access to the data protection key - I have done it to the keyvault so test/review it - Key Vault Crypto Service Encryption User 
az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --role "Key Vault Crypto Service Encryption User" --scope $AZ_KeyVault_Scope 

#Grant the VNET and AKS Subnet access to the Keyvault
az keyvault network-rule add -n $AZ_KeyVault_Name --subnet $AZ_AKS_NAME --vnet-name $AZ_VNET_NAME

#Grant access to your IP Address
az keyvault network-rule add -n $AZ_KeyVault_Name -g $AZ_RESOURCE_GROUP --ip-address $AZ_IP_Address_Allow

#Grant your account access to key vault to import certificates
az role assignment create --assignee $AZ_KeyVault_Certificates_Officer --role "Key Vault Administrator" --scope $AZ_KeyVault_Scope
#az role assignment create --assignee $AZ_KeyVault_Certificates_Officer --role "Key Vault Certificates Officer" --scope $AZ_KeyVault_Scope
#az role assignment create --assignee $AZ_KeyVault_Certificates_Officer --role "Key Vault Secrets Officer" --scope $AZ_KeyVault_Scope

#Import the certificate used for TLS termination into the keyvault.This will be used by the appgateway
az keyvault certificate import --vault-name $AZ_KeyVault_Name -n $AZ_CertificateName -f $AZ_CertificatePath


#Create Public IP
az network public-ip create -g $AZ_RESOURCE_GROUP -n $AZ_PublicIP_Name --allocation-method Static --sku Standard --dns-name $AZ_DNS_Label

#Create the App Gateway
az network application-gateway create `
  --name $AZ_AppGateway_Name `
  --location $AZ_LOCATION `
  --resource-group $AZ_RESOURCE_GROUP `
  --capacity 1 `
  --sku Standard_v2 `
  --public-ip-address $AZ_PublicIP_Name `
  --vnet-name $AZ_VNET_NAME `
  --subnet $AZ_GW_NAME `
  --servers "$AZ_Internal_LB_IP" `
  --priority 100

#Add the managed identity to the app gateway
az network application-gateway identity assign --gateway-name $AZ_AppGateway_Name -g $AZ_RESOURCE_GROUP --identity $AZ_MI_Resource_ID[1] 

#Get the secret ID from Key Vault - certificate url
$Cert = az keyvault secret show --vault-name $AZ_KeyVault_Name -n $AZ_CertificateName | ConvertFrom-Json

# Remove the version so AppGW will use the latest version in future syncs
$CertFullURL = $Cert.id
$Index = $CertFullURL.IndexOf($Cert.name)
$CertUrl = $CertFullURL.Substring(0, $Index + $Cert.name.Length)

# Specify the secret ID from Key Vault 
az network application-gateway ssl-cert create --gateway-name $AZ_AppGateway_Name -g $AZ_RESOURCE_GROUP --name $Cert.name --key-vault-secret-id $CertUrl

#Create HTTPS Listener that uses cert for TLS Termination
az network application-gateway frontend-port create --name "httpsport" --gateway-name $AZ_AppGateway_Name -g $AZ_RESOURCE_GROUP --port 443

az network application-gateway http-listener create --name $AZ_HTTPSListnerName --gateway-name $AZ_AppGateway_Name -g $AZ_RESOURCE_GROUP --frontend-port "httpsport" --ssl-cert $Cert.name

#Then need to create rules when applications deployed

#Create Storage account
az storage account create -n $AZ_StorageAccount_Name -g $AZ_RESOURCE_GROUP  -l $AZ_LOCATION --sku Standard_LRS --subnet $AZ_AKS_NAME --vnet-name $AZ_VNET_NAME --default-action Deny

#Get the Connection String
$AZ_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -g $AZ_RESOURCE_GROUP  -n $AZ_StorageAccount_Name --query "connectionString" -o tsv)

#Add your IP address to the allowed list
az storage account network-rule add -g $AZ_RESOURCE_GROUP --account-name  $AZ_StorageAccount_Name --ip-address $AZ_IP_Address_Allow

#Create file shares + containers
az storage share create --account-name $AZ_StorageAccount_Name --name "Whatever you want to call your file share"--connection-string $AZ_STORAGE_CONNECTION_STRING

#Containers - create a container
az storage container create -n "Whatever you want to call your container" --connection-string $AZ_STORAGE_CONNECTION_STRING --public-access off

#Give the managed ID Storage Blob Data Contributor to the storage account
#Get Storage Scope
$AZ_Storage_Scope=$(az storage account show -n $AZ_StorageAccount_Name -g $AZ_RESOURCE_GROUP --query id -o tsv)
az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --role "Storage Blob Data Contributor" --scope $AZ_Storage_Scope

#Give the managed id reader role to the resource group
$AZ_ResourceGroup_Scope=$(az group show -n $AZ_RESOURCE_GROUP --query id -o tsv)
az role assignment create --assignee-object-id $AZ_SP_ID --assignee-principal-type "ServicePrincipal" --role "Reader" --scope $AZ_ResourceGroup_Scope

#Create ingress namespace
kubectl create namespace ingress-basic

#Need to have Helm installed to install the nginx ingress
# Add the ingress-nginx repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

#Install Ingress
helm install ingress-nginx ingress-nginx/ingress-nginx `
    --version 4.1.3 `
    --namespace ingress-basic `
    --set controller.replicaCount=2 `
    --set controller.nodeSelector."kubernetes\.io/os"=linux `
    --set controller.image.registry=k8s.gcr.io `
    --set controller.image.image=ingress-nginx/controller `
    --set controller.image.tag=v1.2.1 `
    --set controller.image.digest="" `
    --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux `
    --set controller.service.loadBalancerIP=$AZ_Internal_LB_IP `
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true `
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz `
    --set controller.admissionWebhooks.patch.image.registry=k8s.gcr.io `
    --set controller.admissionWebhooks.patch.image.image=ingress-nginx/kube-webhook-certgen `
    --set controller.admissionWebhooks.patch.image.tag=v1.1.1 `
    --set controller.admissionWebhooks.patch.image.digest="" `
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux `
    --set defaultBackend.image.registry=k8s.gcr.io `
    --set defaultBackend.image.image=defaultbackend-amd64 `
    --set defaultBackend.image.tag=1.5 `
    --set defaultBackend.image.digest=""


#Create AKS components needed by the applications using kubectl
#change the host name in any ingress files
kubectl apply -f aks-hello-world.yaml
kubectl apply -f aks-hello-world-ingress.yaml

#Create HTTPS to HTTP rule
az network application-gateway rule create -g $AZ_RESOURCE_GROUP --gateway-name $AZ_AppGateway_Name -n HTTPToHTTPS --http-listener $AZ_HTTPSListnerName --rule-type Basic --address-pool appGatewayBackendPool --http-settings appGatewayBackendHttpSettings --priority 10

#Build and push images to ACR and then deploy!
#Update the deployment files to have the correct acr path and image version
