<#
.SYNOPSIS 
    This script automates a VM snapshot creation in ESXi environment and it do the 3rd site replication process from an ActiveCluster in Pure Storage environment.

.DETAILS
    The most important input is the POD name and the ESXi datastore (When the vmware tags are defined in the config file). The script takes VM snapshots of those stored on the datastore and after that do the replikation from ActiveCluster to 3rd site.

.PARAMETER Config
    Name of config file. The default value is config.xml

.PARAMETER ApplyRetention
    The suffix retention will be applied.

.PARAMETER OverwriteStandaloneTarget
    It create a volume (when not exists) that is always overwritten with the last snapshot.

.NOTES
    Author: Gabor Horvath - Professional Service Engineer
    E-mail: gabor@purestorage.com
    Copyright: Pure Storage Inc.
    Changed: 29.01.2018
    Status: Public
    Version: 1.0
 #>


[CmdletBinding()]
Param (
    [Parameter(Mandatory=$False,Position=1)][string]$Config = 'config.xml',
    [switch]$ApplyRetention,
    [switch]$OverwriteStandaloneTarget
)

#########################################
# Initializing/checking section         #
#########################################

$DebugPreference = "SilentlyContinue"
$InformationPreference = "SilentlyContinue"
$WarningPreference = "Continue"
$ErrorActionPreference = "Stop"

$global:configFile = $Config
$global:logFile = "runlog_" + (Get-Date -Format "yyyyMMdd_HHmmss").ToString() + ".log"

Write-Debug "Start (after parameter definition)"
if ($PSVersionTable.PSVersion.Major -lt 3) { Write-Error "The PowerShell version is $($PSVersionTable.PSVersion.Major). Please upgrade the PowerShell version to 3 or greater!" }

#region Reading config file
    Write-Debug "REGION Reading config file"
    $ScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
    try {
        Import-Module -Name $ScriptDirectory\functions.psm1 -Force
        Import-Module -Name PureStoragePowerShellSDK -Force
    }
    catch {
        Write-Error "Error while loading functions.psm1!"
    }

    [xml]$global:config = Get-Content -Path $global:configFile

    outLog "########### Starting LOG ###########" "Debug"
    outLog "Status of Preference Variables:   `n`$DebugPreference = `"$($DebugPreference)`"   `n`$InformationPreference = `"$($InformationPreference)`"   `n`$ErrorActionPreference = `"$($ErrorActionPreference)`"" "Debug"
    outLog "PARAMETER Config file: $($global:configFile)" "Debug"
    outLog "PARAMETER ApplyRetention: $($ApplyRetention)" "Debug"
    outLog "PARAMETER OverwriteStandaloneTarget: $($OverwriteStandaloneTarget)" "Debug"
    outLog "Config: $($global:config.OuterXml)" "Debug"
#endregion

#region Preparation of credentials
    outLog "REGION Preparation of credentials" "Debug"
    $credFlashArray = createCredential "FlashArray"
    if ($global:config.main.vmware) { $credvCenter = createCredential "vmware" }
#endregion


#########################################
# Connecting to the environments        #
#########################################

outLog "SECTION Connecting to the environments" "Debug"

$global:FlashArraySourceObj = New-PfaArray -EndPoint $global:config.main.FlashArray.SourceArray -Credentials $credFlashArray -IgnoreCertificateError
outLog ($global:FlashArraySourceObj | Out-String) "Debug"

$global:FlashArrayTargetObj = New-PfaArray -EndPoint $global:config.main.FlashArray.TargetArray -Credentials $credFlashArray -IgnoreCertificateError
outLog ($global:FlashArrayTargetObj | Out-String) "Debug"

if ($global:config.main.vmware) {
    $global:vCenterObj = Connect-VIServer -Server $global:config.main.vmware.vCenter -Credential $credvCenter -WarningAction SilentlyContinue
    outLog ($global:vCenterObj | Out-String) "Debug"
}

outLog "All Volumes:" "Debug"
$pfaVolumes = Get-PfaVolumes -Array $global:FlashArraySourceObj
outLog ($pfaVolumes | Select-Object -Property Name,Serial | Format-Table -AutoSize | Out-String) "Debug"

#########################################
# vmware - create  section              #
#########################################
outLog "SECTION vmware - create" "Debug"

if ($global:config.main.vmware) {
#region vmware - create
    outLog "REGION vmware - create" "Debug"
  #Check if the datastores stored in PureStorage and the POD contains these volumes.
    $volumePrefixPOD = '^' + $global:config.main.FlashArray.POD + '::'
    outLog "Checking the which datastore on which volume stored..." "Debug"
    [array]$excludedDatastores = @()
    [array]$datastores = @()
    $global:config.main.vmware.Datastores | % {
        $datastores += $_.DatastoreName
        [array]$luns = (Get-Datastore -Name $_.DatastoreName).ExtensionData.Info.Vmfs.Extent.DiskName
        for ($i = 0; $i -lt $luns.Count; $i++) {
            if ($luns[$i] -like 'naa.624a9370*') {
                $volSerial = ($luns[$i].ToUpper()).substring(12)
                $pureVol = $pfaVolumes | Where-Object { $_.serial -eq $volSerial }
                if (!($pureVol)) {
                    outLog "The volume 'Serial:$($volSerial)' isn't stored on FlashArray '$($global:config.main.FlashArray.SourceArray)'! The VM snapshots won't created on the datastore '$($_.DatastoreName)'!" "Warning"
                    $excludedDatastores += $_.DatastoreName
                    return
                }
            
                if ($pureVol.name -match $volumePrefixPOD) {
                    outLog " -  Datastore: $($_.DatastoreName)  --> $($pureVol.Name) ($($volSerial))" "Console"
                } else {
                    outLog "The volume '$($($pureVol.Name))' isn't stored in POD '$($global:config.main.FlashArray.POD)'! Please move the volume into the POD!" "Warning"
                    $excludedDatastores += $_.DatastoreName
                    return
                }
    
                $vmsOnDataStore = Get-VM -Datastore $_.DatastoreName 
                outLog ("VMs on datastore '$($_.DatastoreName)': $($vmsOnDataStore.Name)" | Out-String) "Debug"
            } else {
                outLog "The datastore '$($_.DatastoreName)' is NOT on a Pure Storage Volume!" "Warning"
                return
            }
        }
    }
    
  #When the all datastores are excluded than EndProgram
    if ($excludedDatastores.Count -eq $datastores.Count) {
        outLog "All datastores has issues! Please check the logfile '$($global:logFile)'!" "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 125
    }

  #Create snapshot on VMs
    outLog "creating VM snapshots..." "Console"
    $taskTab = @{}
    foreach($vm in $vmsOnDataStore.Name)
    {
        $snapname = $vm + "-podbackup"
        $taskTab[(New-Snapshot -VM $vm -Name $snapname -Quiesce -Memory -RunAsync).Id] = $snapname
    }

    $j = 0
    outLog ( $taskTab | Out-String) "Debug"
    $runningTasks = $taskTab.Count
    while($runningTasks -gt 0)
    {
        Get-Task | % {
        if ($taskTab.ContainsKey($_.Id) -and $_.State -eq "Success") {
                $taskTab.Remove($_.Id)
                $runningTasks--
            } elseif ($taskTab.ContainsKey($_.Id) -and $_.State -eq "Error") {
                $taskTab.Remove($_.Id)
                $runningTasks--
            }
        }
        $j++
        outLog "Waiting for Snapshot creating... I'm waiting for $($global:config.main.vmware.WaitTaskSeconds) seconds. Trying $j" "Console"
        Start-Sleep -Seconds $global:config.main.vmware.WaitTaskSeconds
    }
#endregion 
}


#########################################
# FlashArray - source section           #
#########################################
outLog "SECTION FlashArray - source" "Console"

#region Prechecking
    outLog "REGION Prechecking" "Console"
    
  #Array is online?
    outLog "Checking if the array $($global:config.main.FlashArray.SourceArray) is online..." "Console"
    try {
        $arrayTest = Get-PfaArrayID $global:FlashArraySourceObj
        outLog ($arrayTest | Out-String) "Debug"
    }
    catch {
        outLog "The source array isn't online!" "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 51
    }

  #POD exists and online?
    outLog "Checking if the pod '$($global:config.main.FlashArray.POD)' exists and healty..." "Console"
    $cmd = "purepod list $($global:config.main.FlashArray.POD)"
    $clires = runCLICommand $cmd $credFlashArray
    if ($clires -ne $null) {
        $clires | % {
            if (!($_ -match '\sonline\s')) {
                outLog "The POD '$($global:config.main.FlashArray.POD)' is not healty! Please repair it!" "Error"
                EndProgram $global:FlashArraySourceObj $global:vCenterObj 26
            }
        }
    }

  #Is POD empty?
    outLog "Checking if the pod '$($global:config.main.FlashArray.POD)' has any volumes..." "Console"
    $volumePrefixPOD = '^' + $global:config.main.FlashArray.POD + '::'
    $PODvolumes = $pfaVolumes | Where-Object { $_.name -match $volumePrefixPOD }
    outLog ($PODvolumes | Out-String) "Debug"
    if (($PODvolumes | measure).Count -lt 1) {
        outLog "The POD is empty or doesn't exists! POD: $($global:config.main.FlashArray.POD)" "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 27
    }

  #async Volumes exists?
    outLog "Checking if the async volumes are exists..." "Console"
    $PODvolumes | % {
        $chunkVolName = $_.name -split '::'
        $basename = "$($chunkVolName[1])-async"
        $resGetVol = Get-PfaVolumes -Array $global:FlashArraySourceObj | Where-Object {$_.name -like $basename}
        if ([string]::IsNullOrEmpty($resGetVol)) {
            outlog "   +---> The volume '$($_.name)' has NOT async partner! It will be created." "Console"
            outLog (New-PfaVolume -Array $global:FlashArraySourceObj -VolumeName $basename -Size 1 -Unit M | Out-String) "Debug" 
        } else {
            outLog "   +---> The volume '$($_.name)' has an async partner: $($basename)" "Console"
        }
    }

  #async PGroup exists? When doesn't exists than create it.
    outLog "Checking if the protecion group '$($global:config.main.FlashArray.POD)-async' exists..." "Console"
    $asyncPGroup = $global:config.main.FlashArray.POD + "-async"
    $resultPGroup = Get-PfaProtectionGroups -Array $global:FlashArraySourceObj | Where-Object {$_.name -match $asyncPGroup}
    outLog ($resultPGroup | Out-String) "Debug"
    if (($resultPGroup | measure).Count -lt 1) {
        outLog "   +---> The protection group '$asyncPGroup' will be created." "Console"
        [array]$asyncVolumes = @()
        $PODvolumes | % { $asyncVolumes += "$($_.name)-async" } 
        outLog (New-PfaProtectionGroup -Array $global:FlashArraySourceObj -Name $asyncPGroup -Volumes ($asyncVolumes -replace "^.*::",'') -Targets ($global:config.main.FlashArray.TargetArray -replace "\..*",'') | Out-String) "Debug"
    }
    
  #Is any transfer in progress? 
    outLog "Checking if a transfer is in progress, POD: '$($global:config.main.FlashArray.POD)-async' ..." "Console"
    $runningTransfersObj = Get-PfaProtectionGroupSnapshotReplicationStatus -Array $global:FlashArraySourceObj -Name "$($global:config.main.FlashArray.POD)-async"
    
    outLog ($runningTransfersObj | Out-String) "Debug"
    $runningTransfersObj | % {
        if ($_.progress -notmatch "^\s*$") {
            outLog "Transfer is processing! Try again later!" "Error"
            EndProgram $global:FlashArraySourceObj $global:vCenterObj 33
        }
    }

#endregion

#region Cloning and copying
    outLog "REGION Cloning and copying" "Console"

  #POD cloning
    outLog "Cloning the pod '$($global:config.main.FlashArray.POD)'..." "Console"
    $cmd = "purepod clone $($global:config.main.FlashArray.POD) $($global:config.main.FlashArray.POD)-podbackup"
    runCLICommand $cmd $credFlashArray | Out-Null

  #Copying the volumes
    outLog "Copying each volume from the pod clone '$($global:config.main.FlashArray.POD)-podbackup'..." "Console"
    $pattern = $global:config.main.FlashArray.POD + '-podbackup::'
    $PODvolumes = Get-PfaVolumes -Array $global:FlashArraySourceObj | Where-Object {$_.name -match $pattern}
    outLog ($PODvolumes | Out-String) "Debug"
    if (($PODvolumes | measure).Count -lt 1) {
        outLog "The clone POD doesn't exists or no volumes copied! POD: $($global:config.main.FlashArray.POD)-podbackup" "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 28
    }
    $PODvolumes | % {
        $chunkVolName = $_.name -split '::'
        $basename = "$($chunkVolName[1])-async"

      #Check the volumes if contained in the async PGroup. When not containing than it will be added
        if (!($resultPGroup | Where-Object {$_.volumes -match $basename})) {
            outLog "Adding the volume '$($basename)' tothe protection group '$($global:config.main.FlashArray.POD)-async'..." "Console"
            outLog (Add-PfaVolumesToProtectionGroup -Array $global:FlashArraySourceObj -Name "$($global:config.main.FlashArray.POD)-async" -VolumesToAdd $basename | Out-String) "Debug"
        }

      #Overwrite the async volume. This volume will be replicated
        outLog (New-PfaVolume -Array $global:FlashArraySourceObj -Source $_.name -VolumeName $basename -Overwrite | Out-String) "Debug"

      #Delete pending snapshots
        $cmd = "purevol eradicate `$(purevol listobj --pending-only --type snap `"$($basename)`")"
        runCLICommand $cmd $credFlashArray | Out-Null
    }
#endregion 

#region Replicating and cleaning up
    outLog "REGION Replicating and cleaning up" "Console"

    outLog "Replicating the protection group '$($global:config.main.FlashArray.POD)' ..." "Console"
    try {
        $resReplicateObj = New-PfaProtectionGroupSnapshot -Array $global:FlashArraySourceObj -Protectiongroupname "$($global:config.main.FlashArray.POD)-async" -ApplyRetention -ReplicateNow
        outLog ($resReplicateObj | Out-String) "Debug"
    } catch {
        outLog ($resReplicateObj | Out-String) "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 266
    }
    $pgroupSnapName = $resReplicateObj.name  

  #Checking if the transfer is completed
    outLog "Checking if the pgroup transfer is completed..." "Console"
    $numberOfTrying = 0
    while ($true)
    {
        $numberOfTrying++
        outLog "Waiting for tranfser... I'm waiting for $($global:config.main.FlashArray.WaitTransferSeconds) seconds. Trying $($numberOfTrying)" "Console"
        Start-Sleep -Seconds $global:config.main.FlashArray.WaitTransferSeconds
        $runningTransfersObj = Get-PfaProtectionGroupSnapshotReplicationStatus -Array $global:FlashArraySourceObj -Name "$($global:config.main.FlashArray.POD)-async"
        outLog ($runningTransfersObj | Out-String) "Debug"
        $runningTransfersObj | Where-Object { $_.name -like $pgroupSnapName} | % {
            if ($_.completed -notmatch "^\s*$") {
                outLog "The transfer is completed. Started: $($_.created) | Completed: $($_.completed)" "Console"
                break
            }
        }
    }

  #Cleanin up - first delete/eradicate volumes
    outLog "Cleaning up..." "Console"
    $basename = $global:config.main.FlashArray.POD + "-podbackup"
    $PODvolumes = Get-PfaVolumes -Array $global:FlashArraySourceObj | Where-Object {$_.name -match $basename}
    outLog "Getting the cloned volumes in cloned POD '$basename' ..." "Debug"
    outLog ($PODvolumes | Out-String) "Debug"
    $PODvolumes | % {
        outLog " - $($_.name)" "Console"
        outLog (Remove-PfaVolumeOrSnapshot -Array $global:FlashArraySourceObj -Name $_.name) "Debug"
        outLog (Remove-PfaVolumeOrSnapshot -Array $global:FlashArraySourceObj -Name $_.name -Eradicate) "Debug"
    }

  #Get Pending PGroup and delete/eradicate it
    outLog "Destorying the pending PGroup..." "Console"
    $cmd = "purepgroup list --pending --nvp"
    outLog "CLI Command: $($cmd)" "Debug"
    try {
        $clires = New-PfaCLICommand -EndPoint $global:config.main.FlashArray.SourceArray -Credentials $credFlashArray -CommandText $cmd
    } catch {
        outLog ($global:error[0].ToString()) "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 120
    }
    [array]$clires = $clires.Split([Environment]::NewLine)
    outLog ($clires | Out-String) "Debug"
    if ($clires) {
        $clires | % {
            if ($_ -match "^Name=$($global:config.main.FlashArray.POD)-podbackup::") {
                outLog (Remove-PfaProtectionGroupOrSnapshot -Array $global:FlashArraySourceObj -Name ($_ -replace "^Name=",'')) "Debug"
                outLog (Remove-PfaProtectionGroupOrSnapshot -Array $global:FlashArraySourceObj -Name ($_ -replace "^Name=",'') -Eradicate) "Debug"   
            }
        }
    }

  #Destroy POD
    OutLog "Destroying the POD '$($global:config.main.FlashArray.POD)-podbackup' ..." "Console"
    $cmd = "purepod destroy $($global:config.main.FlashArray.POD)-podbackup"
    runCLICommand $cmd $credFlashArray | Out-Null

  #Eradicate POD
    $cmd = "purepod eradicate $($global:config.main.FlashArray.POD)-podbackup"
    runCLICommand $cmd $credFlashArray | Out-Null

#endregion


#########################################
# vmware - delete  section              #
#########################################
if ($global:config.main.vmware) {
    outLog "SECTION vmware - delete" "Console"

    outLog "Delete VM snapshots..." "Console"
    foreach($vm in $vmsOnDataStore.Name)
    {
        $snapshot = Get-Snapshot -VM $vm | Where-Object { $_.Name -like "$vm-podbackup" }
        if ($snapshot) {
            outlog ($snapshot | Remove-Snapshot -Confirm:$false -RunAsync | Out-String) "Console"
        } else {
            outLog "The VM '$vm' hasn't any podbackup snapshot!" "Warning"
        }
    }
}


#########################################
# FlashArray - target section           #
#########################################
outLog "SECTION FlashArray - target" "Console"

#region FlashArray - target
    outlog "REGION FlashArray - target" "Debug"

  #Create volume copy from transfered snapshot  
    outLog "Creating volume copy from target snapshot..." "Console"
    $basesource = $global:config.main.FlashArray.SourceArray -split '\.'
    $allTargetSnapshots = Get-PfaAllVolumeSnapshots -Array $global:FlashArrayTargetObj
    $snapNameSuffix = "^$($basesource[0]):$pgroupSnapName"
    $sortedTargetSnapshot = $allTargetSnapshots | Where-Object { $_.name -match  $snapNameSuffix }
    outLog ($sortedTargetSnapshot | Out-String) "Debug"
    if ($sortedTargetSnapshot -ne $null) {
        $sortedTargetSnapshot | % {
            $newTargetVolumeName = $_.name -replace ".*\.",''
            $newTargetVolumeName = $newTargetVolumeName -replace "-async",''
            $actuallyStandaloneVolume = $newTargetVolumeName
            $newTargetVolumeName = "$($global:config.main.FlashArray.TargetPrefix)-$newTargetVolumeName-$(Get-Date -Format "yyyyMMdd-HHmm")"
            outLog "   +---> New Volume: $newTargetVolumeName" "Console"
            outLog (New-PfaVolume -Array $global:FlashArrayTargetObj -Source $_.name -VolumeName $newTargetVolumeName | Out-String) "Debug"
            if ($OverwriteStandaloneTarget) {
                $res = Get-PfaVolumes -Array $global:FlashArrayTargetObj | Where-Object { $_.name -like $actuallyStandaloneVolume }
                if ($res -ne $null) {
                    outLog "Owerwriteing the Standalone volume '$actuallyStandaloneVolume'  with the SnapshotCopy '$newTargetVolumeName' ... " "Console"
                    outLog (New-PfaVolume -Array $global:FlashArrayTargetObj -Source $newTargetVolumeName -VolumeName $actuallyStandaloneVolume -Overwrite | Out-String) "Debug"
                } else {
                    outLog "Creating the Standalone volume '$actuallyStandaloneVolume' ... " "Debug"
                    New-PfaVolume -Array $global:FlashArrayTargetObj -VolumeName $actuallyStandaloneVolume -Size 1 -Unit M | Out-Null
                    outLog (New-PfaVolume -Array $global:FlashArrayTargetObj -Source $newTargetVolumeName -VolumeName $actuallyStandaloneVolume -Overwrite | Out-String) "Debug"
                }
            }
          
          #Apply retention
            if ($ApplyRetention) {
                $pattern = "\d{8}-\d{4}$"
                outLog "Apply retention on volume '$($newTargetVolumeName -replace $pattern,'')' ..." "Console"
                $prefixPlusVolumeName = $newTargetVolumeName -replace "\d{8}-\d{4}$",""
                $targetVolumes = Get-PfaVolumes -Array $global:FlashArrayTargetObj | Where-Object { $_.name -match $prefixPlusVolumeName}
                if ($targetVolumes -ne $null) {
                    if (($targetVolumes | measure).Count -gt $global:config.main.FlashArray.TargetRetention) {
                        $countOfDelete = ($targetVolumes | measure).Count - $global:config.main.FlashArray.TargetRetention
                        outLog "Count of delete: $countOfDelete" "Debug"
                        $hashVolumesCreated = @{}
                        $targetVolumes | % { $hashVolumesCreated[[datetime]$_.created] = $_.name }
                        $sortedHashVolumesCreated = $hashVolumesCreated.GetEnumerator() | Sort-Object -Property Name
                        outLog "Sorted volume on target with Prefix '$($global:config.main.FlashArray.TargetPrefix)':" "Debug"
                        outLog ($sortedHashVolumesCreated | Out-String) "Debug"
                        for ($i = 0; $i -lt $countOfDelete; $i++)
                        {
                            $targetVolumeNameToDelete = ($sortedHashVolumesCreated | Select-Object -Index $i).Value
                            outLog "The following volmue will be deleted: $targetVolumeNameToDelete" "Console"
                            outLog (Remove-PfaVolumeOrSnapshot -Array $global:FlashArrayTargetObj -Name $targetVolumeNameToDelete | Out-String) "Debug"
                            outLog (Remove-PfaVolumeOrSnapshot -Array $global:FlashArrayTargetObj -Name $targetVolumeNameToDelete -Eradicate | Out-String) "Debug"
                        }
                    }
                }
            }
        }
     } else {
        outLog "There is no target snapshot of ProtectionGroup '$($basesource[0]):$($global:config.main.FlashArray.POD)-async'!" "Error"
        EndProgram $global:FlashArraySourceObj $global:vCenterObj 322
     }
#endregion


#########################################
# End of script section                 #
#########################################

EndProgram $global:FlashArraySourceObj $global:vCenterObj 0