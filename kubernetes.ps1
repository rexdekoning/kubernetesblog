$Cred = Get-Credential
Connect-AzAccount -SubscriptionId "[your subscrption id]" -Credential $Cred

$ResourceGroupName        = 'rdk-akstest'
$ResourceGroupLocation    = 'WestEurope'
$ServicePrincipalName     = 'AKSClusterDemo'
$KeyVaultName             = 'AKSKeyVaultRDK'
$ClusterName              = 'rdkakscluster'
$Owner                    = 'Rex de Koning'
$RegistrySKU              = 'Basic'
$RegistryName             = 'methosregistry'
$DockerEmail              = 'rex@methos.nl'
$AgenVMSize               = 'Standard_DS2_v2'
$KubernetesVersion        = '1.12.6'
$NetworkPlugin            = 'kubenet'
$AgentCount               = 1
$Tags =  @{ Owner="$Owner" };
$ServicePrincipalName += $ResourceGroupName


#Create resource group
$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if(!$resourceGroup) {
    New-AzResourceGroup -Name $resourceGroupName -Location $ResourceGroupLocation -Tag $Tags
}

$keyVault = Get-AzKeyVault -VaultName $KeyVaultName -Tag $Tags
if (!$keyVault) {
    $keyVault = New-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $ResourceGroupLocation -EnabledForTemplateDeployment -Tag $Tags
}

$servicePrincipal = Get-AzADServicePrincipal -DisplayName $ServicePrincipalName
if (!$servicePrincipal) {
    $servicePrincipal = New-AzADServicePrincipal -DisplayName $ServicePrincipalName
    $Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($servicePrincipal.Secret)
    $result = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $servicePrincipal.ApplicationId -SecretValue $servicePrincipal.Secret -Tag $Tags
    $ServicePrincipalSecret = $result
} else {
    $ServicePrincipalSecret = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $servicePrincipal.Id).SecretValueText
}

$CRSParameters = @{
    "registryName"     = $RegistryName
    "registryLocation" = $ResourceGroupLocation
    "registrySku"      = $RegistrySKU
    "adminUserEnabled" = $true
}
$UserName = ""
$Password = ""
$Server = ""
$CRSDeploy = New-AzResourceGroupDeployment -Name "Deployment" -ResourceGroupName $ResourceGroupName -TemplateFile .\crs.json -TemplateParameterObject $CRSParameters #-Verbose 
$CRSDeploy.Outputs.GetEnumerator() | ForEach-Object {
    $myObject = $_
    switch($_.Key) {
        "registryUsername" { $UserName = $myObject.value.Value; break }
        "registryPassword" { $Password = $myObject.value.Value; break }
        "registryServer"   { $Server   = $myObject.value.Value; break }
        default { break }
    }
}

$Password = ConvertTo-SecureString -String $Password -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $UserName -SecretValue $Password -Tag $Tags

$DeployParameters = @{
    "resourceName"                 = "$ClusterName"
    "location"                     = "$ResourceGroupLocation"
    "dnsPrefix"                    = "$ClusterName"
    "agentCount"                   = $AgentCount
    "agentVMSize"                  = "$AgenVMSize"
    "servicePrincipalClientId"     = "$($servicePrincipal.ApplicationId)"
    "servicePrincipalClientSecret" = "$ServicePrincipalSecret"
    "kubernetesVersion"            = "$KubernetesVersion"
    "networkPlugin"                = "$NetworkPlugin"
    "enableRBAC"                   = $true
    "enableHttpApplicationRouting" = $false
    "Owner"                        = "$Owner"
}
$Deployment = New-AzResourceGroupDeployment -Name "Deployment" -ResourceGroupName $ResourceGroupName -TemplateFile .\aks.json -TemplateParameterObject $DeployParameters #-Verbose 
$Deployment.Outputs.GetEnumerator() | ForEach-Object {
    Write-Output "$($_.Key) : $($_.value.Value)"
}


# Get AKS Cluster Credentials for kubectl
Import-AzAksCredential -ResourceGroupName $ResourceGroupName -Name $ClusterName -Force

# Get Admin user
#Import-AzAksCredential -ResourceGroupName $ResourceGroupName -Name $ClusterName -Admin -Force

#Check if our nodes are up
kubectl get nodes --output=wide

Write-Output "Container Register : $server"

Write-Output "Login to registry"
$PassWord | docker login $server -u $UserName --password-stdin

Write-Output "Download default Hello-World image"
docker pull nginxdemos/hello

Write-Output "Re-tag image"
docker tag nginxdemos/hello $server/hello:1.0

Write-Output "Push Image to CRS"
docker image push $server/hello:1.0

#Create secret to Link AKS to CRS
kubectl create secret docker-registry $server --docker-server=$server --docker-username=$UserName --docker-password=$Password --docker-email=$DockerEmail

#Check the secret
kubectl describe secret

$yaml = @"
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: my-api
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: $server/hello:1.0
        ports:
        - containerPort: 80
      imagePullSecrets:
      - name: $server
---
apiVersion: v1
kind: Service
metadata:
  name: my-api
spec:
  type: LoadBalancer
  ports:
  - port: 80
  selector:
    app: my-api
"@

#create deployment
$yaml | kubectl create -f -

#info
kubectl get service/my-api

#Get Kubernetes Dashboard
kubectl create clusterrolebinding kubernetes-dashboard --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard
kubectl proxy

http://localhost:8001/api/v1/namespaces/kube-system/services/kubernetes-dashboard/proxy/#!/login
