# Project Description
Scripts for automated request and renew Let's Encrypt certificates for Azure WebApps

# Deployment to the new subscription
Use release branches (not master)

1. Prepare custom parameters from  CertAutomationParameters.Example.json 
2. Deploy template *CertAutomationTemplate.json* with custom parameters
 
 Example:

    New-AzureRmResourceGroupDeployment -Name "AutomationDeployment" -ResourceGroupName "DevAutomationTemplate" 
        -Mode Incremental -DeploymentDebugLogLevel All -TemplateFile .\ARMTemplates\CertAutomationTemplate.json
        -TemplateParameterFile .\ARMTemplates\CertAutomationParameters.Test.json -Verbose

3. Create AutomationRunAs account manually in the portal
4. Start source control sync manually in the portal
5. Run *AzureAutomation-Account-Modules-Update* runbook
6. Create custom configuration for certificate script based on *cert-update-config.json* and put it to the *LECertUpdateConfiguration* automation variable
7. Set strong password in the *LECertUpdatePfxPassword* variable
8. Check webapp redirect (put something to storage/le-public). URL:  
<http://YOUR_DOMAIN/.well-known/acme-challenge/TOKEN> 

Deploy tempalte with Alertss


# Check this after deployment template
1. Runbooks
2. PowerShell module import
3. Schedules
4. Diagnostics export settings
4. RunAs Account (create manually)
5. Source Control sync (manually after create account)



