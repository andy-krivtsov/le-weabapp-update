[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope='Function', Target="*")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', '', Scope='Function', Target="*")]

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('CertVerify', 'CertUpdate', 'CertInstall')]
    [string] $ScriptAction = 'CertVerify'
)

import-module Posh-ACME

########################################################################################################
## Variables (most variables are loaded from Azure Automation variables or local JSON file )
########################################################################################################

$localAppData = Get-Content Env:\LOCALAPPDATA
$StatePath = "$localAppData\Posh-ACME\"

$CertExpirationBoundary = 20
########################################################################################################
## Cert Functions
########################################################################################################
function Get-ACMEStoredState
{
    Remove-Item -Path $StatePath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

    $blob = Get-AzureStorageBlob -Container $StorageContainer -Blob $ZIPFileName -Context $GlobalStorageContext -ErrorAction SilentlyContinue

    if(-not $blob){
        Write-VerboseLog "Get-ACMEStoredState: Account state not found in the storage $StorageAccount\$StorageContainer"
        return $false
    }

    $blob | Get-AzureStorageBlobContent -Destination $TempFolder | Out-Null
    Expand-Archive -Path "$TempFolder\$ZIPFileName" -DestinationPath $localAppData -Force

    Write-VerboseLog "Get-ACMEStoredState: Account state (file $ZIPFileName) loaded from the storage $StorageAccount\$StorageContainer and expanded to the path $localAppData"
    return $true
}

function Set-ACMEStoredState
{
    $zipFilePath = "$TempFolder\$ZIPFileName"

    Remove-Item -Path $zipFilePath -Force -ErrorAction SilentlyContinue | Out-Null
    Compress-Archive -Path $StatePath -DestinationPath $zipFilePath -Force | Out-Null

    Set-AzureStorageBlobContent -Container $StorageContainer -Blob $ZIPFileName -Context $GlobalStorageContext -File $zipFilePath -Force | Out-Null

    Write-VerboseLog "Set-ACMEStoredState: Account state (file $ZIPFileName) saved to the storage $StorageAccount\$StorageContainer\$ZIPFileName"
}

function New-ACMECertificate
{
    #Create new account and order for certificates
    $order = New-PAOrder $DomainNames

    Write-VerboseLog "New-ACMECertificate: Created new account and order for domains: $($DomainNames -join ',')"

    #Get status of authorizations
    $order | Get-PAAuthorizations | ?{$_.HTTP01Status -ne "valid"} | %{
        $token = $_.HTTP01Token

        #generate verification data
        $verifyData = Get-KeyAuthorization -Token $token -Account (Get-PAAccount)

        #Create blob from the local file with verification data
        $fileName = Join-Path -Path $TempFolder -ChildPath $token
        $verifyData | Out-File -FilePath $fileName -Force -Encoding ascii

        Set-AzureStorageBlobContent -Container $TokenContainer -Blob $token -File  $fileName -Force  -Context $GlobalStorageContext -ErrorAction Stop | out-null

        #Send challenge acknowledge
        $_.HTTP01Url | Send-ChallengeAck

        Write-VerboseLog "New-ACMECertificate: Domain verification writed to storage: fqdn: $($_.fqdn), token: $token, storage: $StorageAccount\$TokenContainer"
    }   

    Start-Sleep -Seconds 10

    #Wait for verification
    #TODO in case of "ivalid" status on any domain - stop waiting 
    do {
        $auths = $order | Get-PAAuthorizations

        if($auths | ?{$_.HTTP01Status -eq "invalid"}){
            throw "New-ACMECertificate: can't validate domains!"
        }

        if( -not ($auths | ?{$_.HTTP01Status -ne "valid"}) ){
            break;
        }

        Write-VerboseLog "New-ACMECertificate: Verification has not finished yet, wait 10 seconds"
        Start-Sleep -Seconds 10        
    }while($true)

    #Request certificate
    $certData = New-PACertificate -Domain $DomainNames -PfxPass $PfxPassword -Force -ErrorAction Stop

    if($null -eq $certData){
        throw "New-ACMECertificate: Certificate not received!"
    }

    Write-VerboseLog "New-ACMECertificate: New certificate received. Subject: $($certData.Subject), Thumbprint: $($certData.Thumbprint), SAN: $($certData.AllSANs -join ','), Expires: $($certData.NotAfter), File: $($certData.PfxFile)"
}

function Update-ACMECertificate
{
    $order = Get-PAOrder

    if($null -eq $order){
        throw "Update-ACMECertificate: Get-PAOrder returned null, account/order not foud!"
    }

    $renewAfter = [DateTimeOffset]::Parse($order.RenewAfter)
    if ([DateTimeOffset]::Now -lt $renewAfter) {
        Write-VerboseLog "Update-ACMECertificate: certificate update is not needed for WebApp: $($WebAppNames[0]) (recomended date $($order.RenewAfter))"
        return $false
    } 

    Write-VerboseLog "Update-ACMECertificate: start updating certificate for WebApp: $($WebAppNames[0])"

    New-ACMECertificate

    return $true
}

########################################################################################################
## Web App management functions
########################################################################################################
function Set-AppServiceCertificate
{
    $cert = Get-PACertificate -ErrorAction Stop

    if($null -eq $cert){
         throw "Set-AppServiceCertificate: Get-PACertificate returned null, certificate not foud!"
    }

    foreach($wname in $WebAppNames){
        $webApp = Get-AzureRmWebApp -ResourceGroupName $WebAppRG -Name $wname

        $logMsgBase = "Set-AppServiceCertificate: Update SSL binding. WebApp: $($webApp.Name)"

        foreach($bind in $webApp.HostNameSslStates){
            if($DomainNames -contains $bind.Name){
                $logMsg = $logMsgBase + ", slot: Production, binding: $($bind.Name)"

                if(-not $IsDryRun){
                    $webApp | New-AzureRmWebAppSSLBinding -CertificateFilePath $cert.PfxFile -CertificatePassword $PfxPassword -Name $bind.Name -SslState "SniEnabled" -Verbose | Out-Null
                    Write-VerboseLog $logMsg
                }else{
                    Write-VerboseLog ($logMsg + "  (DRY RUN)")
                }
            }
        }

        foreach($slot in ($webApp | Get-AzureRmWebAppSlot) ){
            foreach($bind in $slot.HostNameSslStates){
                if($DomainNames -contains $bind.Name){
                    $logMsg = $logMsgBase + ", slot: $($slot.Name), binding: $($bind.Name)"

                    if(-not $IsDryRun){
                        $slot | New-AzureRmWebAppSSLBinding -CertificateFilePath $cert.PfxFile -CertificatePassword $PfxPassword -Name $bind.Name -SslState "SniEnabled" -Verbose | Out-Null
                        Write-VerboseLog $logMsg
                    }else{
                        Write-VerboseLog ($logMsg + "  (DRY RUN)")
                    }
                }
            }
        }        

        Write-VerboseLog "Set-AppServiceCertificate: new certificate has been installed for WebApp: $($webApp.Name)"
    }

    Write-VerboseLog "Set-AppServiceCertificate: New certificate has been installed to all WebApps: $($WebAppNames -join ',')"
}

function Test-WebAppCertificate{
    foreach($wname in $WebAppNames){
        $webApp = Get-AzureRmWebApp -ResourceGroupName $WebAppRG -Name $wname

        foreach($bind in ($webApp | Get-AzureRmWebAppSSLBinding) ){
            if(($DomainNames -contains $bind.Name) -and ($bind.SslState -ne 'Disabled') ){
                $certs = Get-AzureRmWebAppCertificate -Thumbprint $bind.Thumbprint
                $cert = $certs | ?{ $_.Location -eq $webApp.Location }
                
                $remainingDays = ($cert.ExpirationDate - (Get-Date)).Days

                if( $remainingDays -le $CertExpirationBoundary ){
                    Write-Warning "Test-WebAppCertificate: SSL certificate needs to be updated. WebApp: $($webApp.Name), Binding: $($bind.Name), expired in $remainingDays days!"
                }elseif ($remainingDays -le 0 ){
                    Write-Error "Test-WebAppCertificate: SSL certificate expired! WebApp: $($webApp.Name), Binding: $($bind.Name)!"
                }else{
                    Write-VerboseLog "Test-WebAppCertificate: SSL certificate is OK! WebApp: $($webApp.Name), Binding: $($bind.Name), expiration date is $($cert.ExpirationDate)"
                }
            }
        }
    }
}

########################################################################################################
## Other Functions
########################################################################################################
function Write-VerboseLog{
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true,Position=0)]
        [string] $Message
    )

    Write-Verbose -Message $Message -Verbose
}

function New-TempDirectory
{
    $parent = [System.IO.Path]::GetTempPath()
    [string] $name = [System.Guid]::NewGuid()
    return New-Item -ItemType Directory -Path ($parent | Join-Path -ChildPath $name)   
}

function Connect-ToAzure
{
    if($runEnv -eq "local"){
        Write-VerboseLog "Connect-ToAzure: run on the develper workstation! SP='$LocalDevAppId', certificate='$LocalCertThumbprint'"

        Add-AzureRmAccount -ServicePrincipal -TenantId $TenantId -ApplicationId $LocalDevAppId -CertificateThumbprint $LocalCertThumbprint | Out-Null
        Set-AzureRmContext -SubscriptionId $SubscriptionId | Out-Null
    }else{
        $connectionName = "AzureRunAsConnection" 
        Write-VerboseLog "Connect-ToAzure: run in the Azure Automation. Run As connection: $connectionName!"

        $ServicePrincipalConnection = Get-AutomationConnection -Name $connectionName
        Add-AzureRmAccount -ServicePrincipal -TenantId $ServicePrincipalConnection.TenantId -ApplicationId $ServicePrincipalConnection.ApplicationId -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Out-Null
        Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId  | Out-Null        
    }

    $subInfo = Get-AzureRmSubscription
    Write-VerboseLog "Connect-ToAzure: TenantId = $($subInfo.TenantId), SubscriptionId = $($subInfo.SubscriptionId)"
}

function Clear-TokenStorageContainer
{
    Get-AzureStorageBlob -Container $TokenContainer -Context $GlobalStorageContext | Remove-AzureStorageBlob -Force   
}

function Get-Configuration
{   
    #if this is a local run
    $cmdCheck = get-command 'Get-AutomationVariable' -ErrorAction SilentlyContinue
    
    if($null -eq $cmdCheck){
        $confData = Get-Content -Path "./local-configuration.json" -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $Global:runEnv = "local"
        $Global:PfxPassword = $confData.PfxPassword
        $Global:LocalDevAppId = $confData.LocalDevAppId
        $Global:LocalCertThumbprint = $confData.LocalCertThumbprint
    }else{
        $confData = Get-AutomationVariable -Name "LECertUpdateConfiguration" -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $Global:runEnv = "azure"
        $Global:PfxPassword = Get-AutomationVariable -Name "LECertUpdatePfxPassword" -ErrorAction Stop
    }

    $Global:StorageAccount = $confData.StorageAccount
    $Global:StorageContainer = $confData.StorageContainer
    $Global:TokenContainer = $confData.TokenContainer 

    $Global:TenantId = $confData.TenantId
    $Global:SubscriptionId = $confData.SubscriptionId

    $Global:DomainNames = $confData.DomainNames
    $Global:DomainContact = $confData.DomainContact

    $Global:WebAppNames = $confData.WebAppNames
    $Global:WebAppRG = $confData.WebAppRG 

    $Global:StateFileSuffix = $confData.StateFileSuffix

    $Global:LEServer = $confData.LEServer
    $Global:IsDryRun = $confData.IsDryRun

    Write-VerboseLog -Message "Configuration: $($confData | ConvertTo-Json -Compress )"
}

########################################################################################################
## Main
########################################################################################################
$VerbosePreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

#Load configuration and write configuration to the Verbose output
Get-Configuration

#Connect to Azure
Connect-ToAzure

if($ScriptAction -eq 'CertVerify'){
    Write-VerboseLog "Certificate script: daily WebApp certificate expiration date check run!"
    Test-WebAppCertificate
    return
}

Write-VerboseLog "Certificate script: weekly update WebApp certificate run!"

$ZIPFileName = "posh-acme-state-$StateFileSuffix.zip"

if($LEServer -eq 'LE_STAGE'){
    $ZIPFileName = "posh-acme-state-stage-$StateFileSuffix.zip"
}

Write-VerboseLog -Message "Certificate script: configuration: LEServer: $LEServer, IsDryRun: $IsDryRun"

#Create temp directory
$TempFolder = New-TempDirectory
Write-VerboseLog "Certificate script: created temporary folder: $TempFolder"    

$GlobalStorageContext = New-AzureStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount

#Load existed LE account state from Azure storage
$isStateLoaded = Get-ACMEStoredState

#Select LE Server
Set-PAServer $LEServer

$certUpdate = $false   
$certInstall = $false

#Create new account if account state was not loaded from storage
if(-not $isStateLoaded){
    New-PAAccount -AcceptTOS -Contact $DomainContact -Force
    New-ACMECertificate
    $certUpdate = $true
    $certInstall = $true
}else{
    if($ScriptAction -eq 'CertInstall'){
        $certInstall = $true;
    }else{
        $certUpdate = Update-ACMECertificate
        $certInstall = $certUpdate
    }
}

if($certInstall){
    Set-AppServiceCertificate
}

if($certUpdate){
    Set-ACMEStoredState
}

Remove-Item -Path $TempFolder -Force -Recurse
Clear-TokenStorageContainer
