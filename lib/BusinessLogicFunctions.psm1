function New-VmwareSnapshot
{
    Param ()

    Begin {
        $function = '{0}' -f $MyInvocation.MyCommand
        Out-Log "CALLING function '$function' {"
    }

    Process {
        Out-Log "creating VM snapshots..." "Host"
        $taskTab = @{}
        foreach($vm in $global:ObjectList.vCenter.VirtualMachines.Name)
        {
            $snapname = $vm + "-podbackup"
            $taskTab[(New-Snapshot -Server $global:ObjectList.vCenter.VIServer -VM $vm -Name $snapname -Quiesce -Memory -RunAsync).Id] = $snapname
        }

        $j = 0
        Out-Log ( $taskTab | Out-String)
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
            Out-Log "Waiting for Snapshot creating... I'm waiting for $($global:Config.main.vmware.WaitTaskSeconds) seconds. Trying $j" "Host"
            Start-Sleep -Seconds $global:Config.main.vmware.WaitTaskSeconds
        }
    }

    End {
        Out-Log "RETURNING function '$function' }"
    }
}


function Invoke-PureCLICommand
{
    Param (
        $Command,
        $FlashArrayObject
    )

    Begin {
        $function = '{0}' -f $MyInvocation.MyCommand
        Out-Log "CALLING function '$function' {"
    }
    
    Process {
        Out-Log "CLI Command: $($Command)"
        $clires = $null
        try {
            $clires = New-PfaCLICommand -EndPoint $FlashArrayObject.Address -Credentials $FlashArrayObject.Credential -CommandText $Command
        } catch {
            Out-Log "General error message:" "Error"
            Out-Log ($global:error[0].ToString()) "Error"
            Exit-Program -Exitcode 120
        }
        [array]$clires = $clires.Split([Environment]::NewLine)
        Out-Log ($clires | Out-String) "Debug"
        $clires = $clires[1..($clires.Length-2)]
    }
            
    End {
        Out-Log "RETURNING function '$function' }"
        return $clires
    }
}