<#
.SYNOPSIS 
    This script automates a VM snapshot creation in ESXi environment and it do the 3rd site replication process from an ActiveCluster in Pure Storage environment.

.DESCRIPTION
    The most important input is the POD name and the ESXi datastore (When the vmware tags are defined in the config file). The script takes VM snapshots of those stored on the datastore and after that do the replikation from ActiveCluster to 3rd site.
    Important! This version for old PowerCLI

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
 #>


#Requires -Version 5
#Requires -Modules @{ModuleName='PureStoragePowerShellSDK'; ModuleVersion='1.7.4.0'}
#Requires -Modules @{ModuleName='VMware.VimAutomation.Core'; ModuleVersion='6.0.0.0'}
Using module @{ModuleName='.\ClassDefinitionandFunctions.psd1'; RequiredVersion='1.0.1.0'}


[CmdletBinding()]
Param (
    [Parameter(Mandatory=$False,Position=0)][string]$ConfigFile = 'config.xml',
    [switch]$ApplyRetention,
    [switch]$OverwriteStandaloneTarget
)


Write-Debug "Start (after parameter definition)"

$global:originalVariablePreferences = @{"DebugPreference" = $DebugPreference;
                                        "InformationPreference" = $InformationPreference;
                                        "WarningPreference" = $WarningPreference;
                                        "ErrorActionPreference" = $ErrorActionPreference
                                       }

Set-Variable -Name DebugPreference -Value "Continue" -Scope Global -Force
Set-Variable -Name InformationPreference -Value "Continue" -Scope Global -Force
Set-Variable -Name WarningPreference -Value "Continue" -Scope Global -Force
Set-Variable -Name ErrorActionPreference -Value "Stop" -Scope Global -Force


[string]$global:ConfigFile = $ConfigFile
[string]$global:LogFile = "runlog_" + (Get-Date -Format "yyyyMMdd_HHmmss").ToString() + ".log"

#region Reading config file
    Write-Debug "REGION Reading config file"
    $ScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
    try {
        Import-Module -Name $ScriptDirectory\GaborFunctions.psd1 -MinimumVersion 1.0.1.0 -Force 
    }
    catch {
        Write-Error "Error while loading GaborFunctions.psd1!"
        Exit 1
    }

    try {
        Import-Module -Name $ScriptDirectory\BusinessLogicFunctions.psm1 -Force 
    }
    catch {
        Write-Error "Error while loading BusinessLogicFunctions.psm1!"
        Exit 1
    }

    $ConfigContent = Get-Content -Path $global:ConfigFile
    [xml]$global:Config = $ConfigContent

    Out-Log "########### Starting LOG ###########"
    Out-Log "Status of Preference Variables: $($global:originalVariablePreferences.Keys | % { "   `n`$$($_) = $(Get-Variable -Name $_ -ValueOnly)"})"
    Out-Log "PARAMETER Config file: $($global:ConfigFile)"
    Out-Log "PARAMETER ApplyRetention: $($ApplyRetention)"
    Out-Log "PARAMETER OverwriteStandaloneTarget: $($OverwriteStandaloneTarget)"
    Out-Log "CONFIG: $($global:Config.OuterXml)"

    Out-Log "Checking Config file..." "Information"
    $XmlValidationResult = $null
    $XMLSchemaFile = {
        if ($ConfigContent | Select-String -Pattern "<vmware>") {
            return "$ScriptDirectory\templates\config.xsd"
        } else {
            return "$ScriptDirectory\templates\config_without_vmware.xsd"
        }
    }

    $global:Config | Test-Xml -SchemaPath (&$XMLSchemaFile)

#endregion

#region Create objects
    Out-Log "REGION Create objects"
    if ([string]::IsNullOrEmpty($global:Config.main.general.KeyFile)) {
            Out-Log "The element 'KeyFile' in the section 'general' is empty!" "Error"
            Exit-Program -Exitcode 10
    }

    $Section = @("FlashArray", "vmware")
    $Section | % {
        if ([string]::IsNullOrEmpty($global:Config.main.$_.CredentialFile)) {
            Out-Log "The element 'CredentialFile' in the section '$_' is empty!" "Error"
            Exit-Program -Exitcode 11
        }
    }

    $global:ObjectList = @{}

    [FlashArray]$SourceFA1 = [FlashArray]::new(  $global:Config.main.FlashArray.SourceArray1,
                                                (Get-SecuredCredential -SecuredCredentialFile $global:Config.main.FlashArray.CredentialFile -KeyFile $global:Config.main.general.KeyFile)
                                             )
    $global:ObjectList.Add("SourceFA1", $SourceFA1)
    
    [FlashArray]$SourceFA2 = [FlashArray]::new(  $global:Config.main.FlashArray.SourceArray2,
                                                (Get-SecuredCredential -SecuredCredentialFile $global:Config.main.FlashArray.CredentialFile -KeyFile $global:Config.main.general.KeyFile)
                                             )
    $global:ObjectList.Add("SourceFA2", $SourceFA2)

    [FlashArray]$TargetFA = [FlashArray]::new(  $global:Config.main.FlashArray.TargetArray,
                                                (Get-SecuredCredential -SecuredCredentialFile $global:Config.main.FlashArray.CredentialFile -KeyFile $global:Config.main.general.KeyFile)
                                             )
    $global:ObjectList.Add("TargetFA", $TargetFA)

    if ($global:Config.main.vmware) {
        [vCenter]$vCenter = [vCenter]::new( $global:Config.main.vmware.vCenter,
                                            (Get-SecuredCredential -SecuredCredentialFile $global:Config.main.vmware.CredentialFile -KeyFile $global:Config.main.general.KeyFile)
                                          )
        try {
            Test-Connection $global:Config.main.vmware.vCenter -Count 1 | Out-Null
        }
        catch {
            Out-Log "The vCenter '$($global:Config.main.vmware.vCenter)' isn't reachable over ICMP!" "Error"
            $global:ObjectList = $null
            Exit-Program -Exitcode 15
        }
        $global:ObjectList.Add("vCenter", $vCenter)
    }

    
#endregion

#region Connecting to the environment
    Out-Log "REGION Connecting to the environment"

    Out-Log "Connecting..." "Information"
    
    $global:ObjectList.Keys | % { $global:ObjectList.Item($_).Connect() }

    $SourceActive = $null
    if ($SourceFA1.Array) {
        $SourceActive = $SourceFA1
    } elseif ($SourceFA2.Array) {
        Out-Log "Trying the second Array '$($SourceFA2.Address)'"
        $SourceActive = $SourceFA2
    } else {
        Out-Log "Both ActiveCluster member are UNAVAILABLE!" "Error"
        Exit-Program -Exitcode 20
    }
    
    if (!($TargetFA.Array)) { Exit-Program -Exitcode 21 }
    if ($global:ObjectList.ContainsKey("vCenter")) {
        if (!($vCenter.VIServer)) { Exit-Program -Exitcode 22 }
    }

    Out-Log "All Volumes:"
    $SourceActive.Volumes = Get-PfaVolumes -Array $SourceActive.Array
    Out-Log ($SourceActive.Volumes | Select-Object -Property Name,Serial | Format-Table -AutoSize | Out-String)
#endregion


#########################################
# vmware - create  section              #
#########################################
Out-Log "SECTION vmware - create"

if ($global:Config.main.vmware) {
#region vmware - create
    Out-Log "REGION vmware - create"
  #Check if the datastores stored in PureStorage and the POD contains these volumes.
    $volumePrefixPOD = '^' + $global:Config.main.FlashArray.POD + '::'
    Out-Log "Checking the which datastore on which volume stored..." "Host"
    [array]$excludedDatastores = @()
    [array]$datastores = @()
    [array]$vmsOnDataStores = @()
    $global:Config.main.vmware.Datastores | % {
        $datastores += $_.DatastoreName
        [array]$luns = (Get-Datastore -Server $vCenter.VIServer -Name $_.DatastoreName).ExtensionData.Info.Vmfs.Extent.DiskName
        for ($i = 0; $i -lt $luns.Count; $i++) {
            if ($luns[$i] -like 'naa.624a9370*') {
                $volSerial = ($luns[$i].ToUpper()).substring(12)
                $volSerial = "E9B7C03A266F4F010009C369" #REMOVE
                $pureVol = $SourceActive.Volumes | Where-Object { $_.serial -eq $volSerial }
                if (!($pureVol)) {
                    Out-Log "The volume 'Serial:$($volSerial)' isn't stored on FlashArray '$($global:Config.main.FlashArray.SourceArray1)'! The VM snapshots won't created on the datastore '$($_.DatastoreName)'!" "Warning"
                    $excludedDatastores += $_.DatastoreName
                    return
                }
            
                if ($pureVol.name -match $volumePrefixPOD) {
                    Out-Log " -  Datastore: $($_.DatastoreName)  --> $($pureVol.Name) ($($volSerial))" "Host"
                } else {
                    Out-Log "The volume '$($($pureVol.Name))' isn't stored in POD '$($global:Config.main.FlashArray.POD)'! Please move the volume into the POD!" "Warning"
                    $excludedDatastores += $_.DatastoreName
                    return
                }
    
                $vmsOnDataStore = Get-VM -Server $vCenter.VIServer -Datastore $_.DatastoreName
                $vmsOnDataStores += $vmsOnDataStore
                Out-Log ("VMs on datastore '$($_.DatastoreName)': $($vmsOnDataStore.Name)" | Out-String)
            } else {
                Out-Log "The datastore '$($_.DatastoreName)' is NOT on a Pure Storage Volume!" "Warning"
                return
            }
        }
    }
    
  #When the all datastores are excluded than Exit-Program -Exitcode 
    if ($excludedDatastores.Count -eq $datastores.Count) {
        Out-Log "All datastores has issues! Please check the logfile '$($global:LogFile)'!" "Error"
        Exit-Program -Exitcode 125
    }

  #Create snapshot on VMs
    $vCenter.VirtualMachines = $vmsOnDataStores
    New-VmwareSnapshot
#endregion 
}


#########################################
# FlashArray - source section           #
#########################################
Out-Log "SECTION FlashArray - source" "Host"

#region Prechecking
    Out-Log "REGION Prechecking" "Host"
    
  #Array is online?
    Out-Log "Checking if the array $($global:Config.main.FlashArray.SourceArray1) is online..." "Host"
    try {
        Out-Log (Get-PfaArrayID -Array $SourceActive.Array | Out-String)
    }
    catch {
        Out-Log "The source array '$($SourceActive.Address)' isn't online!" "Error"
        Exit-Program -Exitcode 51
    }

  #POD exists and online?
    Out-Log "Checking if the pod '$($global:config.main.FlashArray.POD)' exists and healty..." "Host"
    $cmd = "purepod list $($global:config.main.FlashArray.POD)"
    $clires = Invoke-PureCLICommand -Command $cmd -FlashArrayObject $SourceActive
    if ($clires -ne $null) {
        $clires | % {
            if (!($_ -match '\sonline\s')) {
                Out-Log "The POD '$($global:config.main.FlashArray.POD)' is not healty! Please repair it!" "Error"
                Exit-Program -Exitcode 26
            }
        }
    }

  #Is POD empty?
    Out-Log "Checking if the pod '$($global:config.main.FlashArray.POD)' has any volumes..." "Host"
    Out-Log ($SourceActive.getPODVolumes($global:Config.main.FlashArray.POD) | Out-String)
    if (($SourceActive.getPODVolumes($global:Config.main.FlashArray.POD) | measure).Count -lt 1) {
        Out-Log "The POD '$($global:config.main.FlashArray.POD)' is empty or doesn't exist!" "Error"
        Exit-Program -Exitcode 27
    }

  #async Volumes exists?
    Out-Log "Checking if the async volumes are exists..." "Host"
    $SourceActive.getPODVolumes($global:Config.main.FlashArray.POD) | % {
        $chunkVolName = $_.name -split '::'
        $basename = "$($chunkVolName[1])-async"
        $resGetVol = $SourceActive.Volumes | Where-Object {$_.name -like $basename}
        if ([string]::IsNullOrEmpty($resGetVol)) {
            Out-Log "   +---> The volume '$($_.name)' has NOT async partner! It will be created." "Host"
            Out-Log (New-PfaVolume -Array $SourceActive.Array -VolumeName $basename -Size 1 -Unit M | Out-String)
        } else {
            Out-Log "   +---> The volume '$($_.name)' has an async partner: $($basename)" "Host"
        }
    }

  #async PGroup exists? When doesn't exists than create it.
    Out-Log "Checking if the protecion group '$($global:config.main.FlashArray.POD)-async' exists..." "Host"
    $SourceActive.ProtectionGroups = Get-PfaProtectionGroups -Array $SourceActive.Array
    $asyncPGroup = $global:config.main.FlashArray.POD + "-async"
    Out-Log ($SourceActive.getAsyncPGroups($asyncPGroup) | Out-String)
    if (($SourceActive.getAsyncPGroups($asyncPGroup) | measure).Count -lt 1) {
        Out-Log "   +---> The protection group '$asyncPGroup' will be created." "Host"
        [array]$asyncVolumes = @()
        $SourceActive.getPODVolumes($global:Config.main.FlashArray.POD) | % { $asyncVolumes += "$($_.name)-async" } 
        Out-Log (New-PfaProtectionGroup -Array $SourceActive.Array -Name $asyncPGroup -Volumes ($asyncVolumes -replace "^.*::",'') -Targets ($TargetFA.Address -replace "\..*",'') | Out-String)
    }
    
  #Is any transfer in progress? 
    Out-Log "Checking if a transfer is in progress, POD: '$($global:config.main.FlashArray.POD)-async' ..." "Host"
    $runningTransfersObj = Get-PfaProtectionGroupSnapshotReplicationStatus -Array $SourceActive.Array -Name "$($global:config.main.FlashArray.POD)-async"
    Out-Log ($runningTransfersObj | Out-String)
    $runningTransfersObj | % {
        if ($_.progress -notmatch "^\s*$") {
            Out-Log "Transfer is processing! Try again later!" "Error"
            Exit-Program -Exitcode 33
        }
    }

#endregion

#region Cloning and copying
    Out-Log "REGION Cloning and copying" "Host"

  #POD cloning
    Out-Log "Cloning the pod '$($global:config.main.FlashArray.POD)'..." "Host"
    $cmd = "purepod clone $($global:config.main.FlashArray.POD) $($global:config.main.FlashArray.POD)-podbackup"
    Invoke-PureCLICommand -Command $cmd -FlashArrayObject $SourceActive | Out-Null

  #Copying the volumes
    Out-Log "Copying each volume from the pod clone '$($global:config.main.FlashArray.POD)-podbackup'..." "Host"
    $SourceActive.Volumes = Get-PfaVolumes -Array $SourceActive.Array
    $pattern = $global:config.main.FlashArray.POD + '-podbackup::'
    $PODBackupVolumes = $SourceActive.Volumes | Where-Object {$_.name -match $pattern}
    Out-Log ($PODBackupVolumes | Out-String)
    if (($PODBackupVolumes | measure).Count -lt 1) {
        Out-Log "The clone POD '$($global:config.main.FlashArray.POD)-podbackup' doesn't exist or no volumes copied!" "Error"
        Exit-Program -Exitcode 28
    }
    $PODBackupVolumes | % {
        $chunkVolName = $_.name -split '::'
        $basename = "$($chunkVolName[1])-async"

      #Check the volumes if contained in the async PGroup. When not containing than it will be added
        if (!($SourceActive.getAsyncPGroups($asyncPGroup) | Where-Object {$_.volumes -match $basename})) {
            Out-Log "   +---> Adding the volume '$($basename)' to the Protection Group '$($global:config.main.FlashArray.POD)-async'..." "Host"
            Out-Log (Add-PfaVolumesToProtectionGroup -Array $SourceActive.Array -Name "$($global:config.main.FlashArray.POD)-async" -VolumesToAdd $basename | Out-String)
        }

      #Overwrite the async volume. This volume will be replicated
        Out-Log (New-PfaVolume -Array $SourceActive.Array -Source $_.name -VolumeName $basename -Overwrite | Out-String)

      #Delete pending snapshots
        $cmd = "purevol eradicate `$(purevol listobj --pending-only --type snap `"$($basename)`")"
        Invoke-PureCLICommand -Command $cmd -FlashArrayObject $SourceActive | Out-Null
    }
#endregion 

#region Replicating and cleaning up
    Out-Log "REGION Replicating and cleaning up" "Host"

    Out-Log "Replicating the protection group '$($global:config.main.FlashArray.POD)' ..." "Host"
    try {
        $resReplicateObj = New-PfaProtectionGroupSnapshot -Array $SourceActive.Array -Protectiongroupname "$($global:config.main.FlashArray.POD)-async" -ApplyRetention -ReplicateNow
        Out-Log ($resReplicateObj | Out-String)
    } catch {
        Out-Log "Replication failure:" "Error"
        Out-Log ($resReplicateObj | Out-String) "Error"
        Exit-Program -Exitcode 266
    }
    $pgroupSnapName = $resReplicateObj.name  

  #Checking if the transfer is completed
    Out-Log "Checking if the pgroup transfer is completed..." "Host"
    $numberOfTrying = 0
    while ($true)
    {
        $numberOfTrying++
        Out-Log "Waiting for tranfser... I'm waiting for $($global:config.main.FlashArray.WaitTransferSeconds) seconds. Trying $($numberOfTrying)" "Host"
        Start-Sleep -Seconds $global:config.main.FlashArray.WaitTransferSeconds
        $runningTransfersObj = Get-PfaProtectionGroupSnapshotReplicationStatus -Array $SourceActive.Array -Name "$($global:config.main.FlashArray.POD)-async"
        Out-Log ($runningTransfersObj | Out-String)
        $runningTransfersObj | Where-Object { $_.name -like $pgroupSnapName} | % {
            if ($_.completed -notmatch "^\s*$") {
                Out-Log "The transfer is completed. Started: $($_.created) | Completed: $($_.completed)" "Host"
                break
            }
        }
    }

  #Cleanin up - first delete/eradicate volumes
    Out-Log "Cleaning up..." "Host"
    $basename = $global:config.main.FlashArray.POD + "-podbackup"
    $PODBackupVolumes = $SourceActive.Volumes | Where-Object {$_.name -match $basename}
    Out-Log "Getting the cloned volumes in cloned POD '$basename' ..."
    Out-Log ($PODBackupVolumes | Out-String)
    $PODBackupVolumes | % {
        Out-Log " - $($_.name)" "Host"
        Out-Log (Remove-PfaVolumeOrSnapshot -Array $SourceActive.Array -Name $_.name)
        Out-Log (Remove-PfaVolumeOrSnapshot -Array $SourceActive.Array -Name $_.name -Eradicate)
    }

  #Get Pending PGroup and delete/eradicate it
    Out-Log "Destorying the pending Protection Group..." "Host"
    $cmd = "purepgroup list --pending --nvp"
    Out-Log "CLI Command: $($cmd)"
    try {
        $clires = New-PfaCLICommand -EndPoint $SourceActive.Address -Credentials $SourceActive.Credential -CommandText $cmd
    } catch {
        Out-Log "General error message:"
        Out-Log ($global:error[0].ToString()) "Error"
        Exit-Program -Exitcode 120
    }
    [array]$clires = $clires.Split([Environment]::NewLine)
    Out-Log ($clires | Out-String)
    if ($clires) {
        $clires | % {
            if ($_ -match "^Name=$($global:config.main.FlashArray.POD)-podbackup::") {
                Out-Log (Remove-PfaProtectionGroupOrSnapshot -Array $SourceActive.Array -Name ($_ -replace "^Name=",''))
                Out-Log (Remove-PfaProtectionGroupOrSnapshot -Array $SourceActive.Array -Name ($_ -replace "^Name=",'') -Eradicate)  
            }
        }
    }

  #Destroy POD
    Out-Log "Destroying the POD '$($global:config.main.FlashArray.POD)-podbackup' ..." "Host"
    $cmd = "purepod destroy $($global:config.main.FlashArray.POD)-podbackup"
    Invoke-PureCLICommand -Command $cmd -FlashArrayObject $SourceActive | Out-Null

  #Eradicate POD
    $cmd = "purepod eradicate $($global:config.main.FlashArray.POD)-podbackup"
    Invoke-PureCLICommand -Command $cmd -FlashArrayObject $SourceActive | Out-Null

#endregion


#########################################
# vmware - delete  section              #
#########################################
if ($global:config.main.vmware) {
    Out-Log "SECTION vmware - delete" "Host"

    Out-Log "Delete VM snapshots..." "Host"
    foreach($vm in $vCenter.VirtualMachines.Name)
    {
        $snapshot = Get-Snapshot -VM $vm -Server $vCenter.VIServer | Where-Object { $_.Name -like "$vm-podbackup" }
        if ($snapshot) {
            Out-Log ($snapshot | Remove-Snapshot -Confirm:$false -RunAsync | Out-String)
        } else {
            Out-Log "The VM '$vm' hasn't any podbackup snapshot!" "Warning"
        }
    }
}


#########################################
# FlashArray - target section           #
#########################################
Out-Log "SECTION FlashArray - target" "Host"

#region FlashArray - target
    Out-Log "REGION FlashArray - target"

  #Create volume copy from transfered snapshot  
    Out-Log "Creating volume copy from target snapshot..." "Host"
    $basesource = $global:Config.main.FlashArray.SourceArray1 -split '\.'
    $allTargetSnapshots = Get-PfaAllVolumeSnapshots -Array $TargetFA.Array
    $snapNameSuffix = "^$($basesource[0]):$pgroupSnapName"
    $sortedTargetSnapshot = $allTargetSnapshots | Where-Object { $_.name -match  $snapNameSuffix }
    Out-Log ($sortedTargetSnapshot | Out-String)
    if ($sortedTargetSnapshot -ne $null) {
        $sortedTargetSnapshot | % {
            $newTargetVolumeName = $_.name -replace ".*\.",''
            $newTargetVolumeName = $newTargetVolumeName -replace "-async",''
            $actuallyStandaloneVolume = $newTargetVolumeName
            $newTargetVolumeName = "$($global:config.main.FlashArray.TargetPrefix)-$newTargetVolumeName-$(Get-Date -Format "yyyyMMdd-HHmm")"
            Out-Log "   +---> New Volume: $newTargetVolumeName" "Host"
            Out-Log (New-PfaVolume -Array $TargetFA.Array -Source $_.name -VolumeName $newTargetVolumeName | Out-String)
            if ($OverwriteStandaloneTarget) {
                $res = Get-PfaVolumes -Array $TargetFA.Array | Where-Object { $_.name -like $actuallyStandaloneVolume }
                if ($res -ne $null) {
                    Out-Log "      +---> Owerwriteing the Standalone volume '$actuallyStandaloneVolume'  with the SnapshotCopy '$newTargetVolumeName' ... " "Host"
                    Out-Log (New-PfaVolume -Array $TargetFA.Array -Source $newTargetVolumeName -VolumeName $actuallyStandaloneVolume -Overwrite | Out-String)
                } else {
                    Out-Log "      +---> Creating the Standalone volume '$actuallyStandaloneVolume' ... "
                    New-PfaVolume -Array $TargetFA.Array -VolumeName $actuallyStandaloneVolume -Size 1 -Unit M | Out-Null
                    Out-Log "      +---> Owerwriteing the Standalone volume '$actuallyStandaloneVolume'  with the SnapshotCopy '$newTargetVolumeName' ... " "Host"
                    Out-Log (New-PfaVolume -Array $TargetFA.Array -Source $newTargetVolumeName -VolumeName $actuallyStandaloneVolume -Overwrite | Out-String)
                }
            }
          
          #Apply retention
            if ($ApplyRetention) {
                $pattern = "\d{8}-\d{4}$"
                Out-Log "Apply retention on volume '$($newTargetVolumeName -replace $pattern,'')' ..." "Host"
                $prefixPlusVolumeName = $newTargetVolumeName -replace "\d{8}-\d{4}$",""
                $targetVolumes = Get-PfaVolumes -Array $TargetFA.Array | Where-Object { $_.name -match $prefixPlusVolumeName}
                if ($targetVolumes -ne $null) {
                    if (($targetVolumes | measure).Count -gt $global:config.main.FlashArray.TargetRetention) {
                        $countOfDelete = ($targetVolumes | measure).Count - $global:config.main.FlashArray.TargetRetention
                        Out-Log "Count of delete: $countOfDelete"
                        $hashVolumesCreated = @{}
                        $targetVolumes | % { $hashVolumesCreated[[datetime]$_.created] = $_.name }
                        $sortedHashVolumesCreated = $hashVolumesCreated.GetEnumerator() | Sort-Object -Property Name
                        Out-Log "Sorted volume on target with Prefix '$($global:config.main.FlashArray.TargetPrefix)':"
                        Out-Log ($sortedHashVolumesCreated | Out-String)
                        for ($i = 0; $i -lt $countOfDelete; $i++)
                        {
                            $targetVolumeNameToDelete = ($sortedHashVolumesCreated | Select-Object -Index $i).Value
                            Out-Log "   +--->The following volmue will be deleted: $targetVolumeNameToDelete" "Host"
                            Out-Log (Remove-PfaVolumeOrSnapshot -Array $TargetFA.Array -Name $targetVolumeNameToDelete | Out-String)
                            Out-Log (Remove-PfaVolumeOrSnapshot -Array $TargetFA.Array -Name $targetVolumeNameToDelete -Eradicate | Out-String)
                        }
                    }
                }
            }
        }
     } else {
        Out-Log "There is no target snapshot of Protection Group '$($basesource[0]):$($global:config.main.FlashArray.POD)-async'!" "Error"
        Exit-Program -Exitcode 322
     }
#endregion


#########################################
# End of script section                 #
#########################################


Exit-Program