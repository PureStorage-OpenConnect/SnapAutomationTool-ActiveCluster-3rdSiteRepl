class Server {
    [string]$Address
    [System.Management.Automation.PSCredential]$Credential
}


class FlashArray : Server {
    [PurePowerShell.PureArray]$Array
    [System.Object[]]$Volumes
    [System.Object[]]$ProtectionGroups

    FlashArray() {
        $this.Address = $null
        $this.Credential = $null
    }

    FlashArray(
        [string]$addr,
        [System.Management.Automation.PSCredential]$cred
    ){
        $this.Address = $addr
        $this.Credential = $cred
    }

    [void] Connect() {
        try {
            $this.Array = New-PfaArray -EndPoint $this.Address -Credentials $this.Credential -IgnoreCertificateError
            Out-Log "The connection to '$($this.Address)' is SUCCESSFUL: `n$($this.Array | Out-String)"
        }
        catch {
            Out-Log "The connection to '$($this.Address)' was unsuccessful!`n$($Error[0])" "Error"
        }
    }

    [void] Disconnect() {
        if ($this.Array) {
            Out-Log "Disconnecting '$($this.Address)'"
            Disconnect-PfaArray -Array $this.Array -ErrorAction SilentlyContinue
            $this.Array = $null
        }
    }

    [System.Object[]] getPODVolumes([string]$pattern) {
        $volumePrefixPOD = '^' + $pattern + '::'
        return ($this.Volumes | Where-Object { $_.name -match $volumePrefixPOD })
    }

    [System.Object[]] getAsyncPGroups([string]$pattern) {
        return ($this.ProtectionGroups | Where-Object { $_.name -match $pattern })
    }
}


class vCenter : Server {
    [VMware.VimAutomation.ViCore.Types.V1.VIServer]$VIServer
    $VirtualMachines

    vCenter(){
        $this.Address = $null
        $this.Credential = $null

    }

    vCenter(
        [string]$addr,
        [System.Management.Automation.PSCredential]$cred
    ){
        $this.Address = $addr
        $this.Credential = $cred
    }

    [void] Connect() {
        try {
            $this.VIServer = Connect-VIServer -Server $this.Address -Credential $this.Credential -NotDefault
            Out-Log "The connection to '$($this.Address)' is SUCCESSFUL: `n$($this.vIServer | Out-String)"            
        }
        catch {
            Out-Log "The connection to '$($this.Address)' was unsuccessful!`n$($Error[0])" "Error"
        }
    }

    [void] Disconnect() {
        if ($this.VIServer) {
            Out-Log "Disconnecting '$($this.Address)'"
            Disconnect-VIServer -Server $this.VIServer -Force -Confirm:$false
            $this.VIServer = $null
        }
    }
}