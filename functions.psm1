#Description: This file contains funtions of podbackup.ps1

#Author: Gabor Horvath - Professional Service Engineer
#Copyright: Pure Storage GmbH.
#Changed: 22.01.2018
#Status: Public
#Version: 1.0


function getTimeStamp
{
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss").ToString()
}


function outLog
{
    Param (
        $text,
        [ValidateSet("Console","Debug","Info","Warning","Error")]
        $severity
    )

    switch ($severity)
    {
        "Console" { Write-Host $text }
        "Debug" { Write-Debug $text }
        "Info" { Write-Information $text }
        "Warning" { Write-warning $text }
        "Error" { Write-Host $text -ForegroundColor Red }
        default { Write-Error "The severity of function outLog is not appropiate!"; Exit}
    }

    $outfile = "$(getTimeStamp) - $($severity): $text"
    $outfile | Out-File -FilePath $global:logFile -Append
}


function EndProgram
{
    Param ($FlashArray, $vCenter, $exitcode)

    $function = '{0}' -f $MyInvocation.MyCommand
    outLog "CALLING function '$function'" "Debug"

    Disconnect-PfaArray -Array $FlashArray
    Disconnect-VIServer $vCenter -Confirm:$false
    Remove-Module -Name PureStoragePowerShellSDK
    outLog "########### END ###########" "Debug"
    Exit $exitcode
}


function runCLICommand
{
    Param ($cmd, $credFlasArray)

    $function = '{0}' -f $MyInvocation.MyCommand
    outLog "CALLING function '$function' {" "Debug"
    outLog "CLI Command: $($cmd)" "Debug"
    $clires = $null
    try {
        $clires = New-PfaCLICommand -EndPoint $global:config.main.FlashArray.SourceArray -Credentials $credFlashArray -CommandText $cmd
    } catch {
        outLog ($global:error[0].ToString()) "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 120
    }
    [array]$clires = $clires.Split([Environment]::NewLine)
    outLog ($clires | Out-String) "Debug"
    $clires = $clires[1..($clires.Length-2)]
        
    outLog "RETURNING function '$function' }" "Debug"

return $clires
}


function createCredential
{
    Param ($info)

    $function = '{0}' -f $MyInvocation.MyCommand
    outLog "CALLING function '$function' {" "Debug"

    outLog "Decrypting $info Password..." "Debug" 
    $key = Get-Content $global:config.main.general.KeyFile
    $SecureAPITokenHashWithKey = Get-Content $global:config.main.$info.SecureFile
    $Decrypted = $SecureAPITokenHashWithKey | ConvertTo-SecureString -Key $key
    $credential = New-Object System.Management.Automation.PSCredential($global:config.main.$info.User, $Decrypted)

    outLog "RETURNING function '$function' }" "Debug"

return $credential
}


function connectVolume
{
    Param($localvolCopyName)
    
    $function = '{0}' -f $MyInvocation.MyCommand
    outLog "CALLING function '$function' {" "Debug"

    Start-Sleep -Seconds 1
    if ($global:config.main.FlashArray.HostGroup -ne $null) {
        outLog "Connecting the volume '$localvolCopyName' to the HostGroup '$($global:config.main.FlashArray.HostGroup)' ..." "Info"
        outLog (New-PfaHostGroupVolumeConnection -Array $global:FlashArraySourceObj -HostGroupName $localconfig.HostGroupName -VolumeName $localvolCopyName | Out-String) "Debug"
    } elseif ($global:config.main.FlashArray.Host -ne $null) {
        outLog "Connecting the volume '$localvolCopyName' to the Host '$($global:config.main.FlashArray.Host)' ..." "Info"
        outLog (New-PfaHostVolumeConnection -Array $global:FlashArraySourceObj -HostName $localconfig.HostName -VolumeName $localvolCopyName | Out-String) "Debug"
    } else {
        outLog "The Host or HostGroup isn't defined in the config file!" "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 197
    }

    outLog "RETURNING function '$function' }" "Debug"

return $(Get-PfaVolume -Array $global:FlashArraySourceObj -Name $localvolCopyName).serial
}