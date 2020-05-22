$VerbosePreference = 'SilentlyContinue'

#Write-Host "1. Test message. Host level"
Write-Verbose "2. Test message. Verbose level" -Verbose
Write-Output "3. Test message. Output level"
#Write-Debug "4. Test message. Debug level"
#Write-Information "5. Test message. Info level"
Write-Warning "6. Test message. Warning level"
Write-Error -Message "7. Test message. Error level"

