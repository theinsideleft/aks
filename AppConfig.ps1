$AZ_APPConfig_File=".\Config\appconfig.secrets.json"

#Populate AppConfig and Secrets
$AppConfig = Get-Content -Path $AZ_APPConfig_File | ConvertFrom-Json

#Get the primamry connection string
$AZ_APPConfig_Credentials = $(az appconfig credential list -n $AZ_APP_Config_Name -g $AZ_RESOURCE_GROUP | ConvertFrom-Json )

foreach ($connectItem in $AZ_APPConfig_Credentials) {
    if ($connectItem.name -eq "Primary") {
        $ConnectionString = $connectItem.connectionString
        break  # Found the primary connection string, no need to continue the loop
    }
}



# Iterating through each element in the "Config" array
foreach ($configItem in $AppConfig.Config) {
    
    #No Secret = no keyvault referenece so create app config item only
    if($configItem.secret)
    {
        $KeyVaultSecret = $(az keyvault secret set --name $configItem.secret --vault-name $AZ_KeyVault_Name --value $configItem.value | ConvertFrom-Json)
        
        if($configItem.label){
            az appconfig kv set-keyvault --connection-string $ConnectionString --key $configItem.key --secret-identifier $KeyVaultSecret.id --label $configItem.label --yes 
        }
        else {
            az appconfig kv set-keyvault --connection-string $ConnectionString --key $configItem.key --secret-identifier $KeyVaultSecret.id --yes 
        }

    
    }
    else
    {
        if($configItem.label){
            az appconfig kv set --connection-string $ConnectionString --key $configItem.key --value $configItem.value --label $configItem.label --yes
        }
        else{
            az appconfig kv set --connection-string $ConnectionString --key $configItem.key --value $configItem.value --yes
        }
    }

}