# SnapAutomationTool-ActiveCluster-3rdSiteRepl

Snap Automaintion Tool for VMware and ActiveCluster 3rd site Replication



This project created for Pure Storage FlashArray customers who using the ActivelCluster feature with a 3rd site (DR) replication. 
Features:
 - Do the snap transfer from ActiveCluster to the 3rd site replication (Core function)
 - Create VM snapshots in the vmware environment (When the vmware secition exist in the config file)
 - Apply the predefined retention on the 3rd site. (When the parameter given)

Files:
 - config.xml  -> There is a config file.
 - encryptAES.ps1  -> Its creating the key file and the encrypted password(s)
 - function.psm1  -> stored functions for the main script
 - podbackup.ps1  -> Main script
 - podbackup_oldpowercli.ps1  -> When you has a PowerShell Verion 3 than use this.

Minimum Requirements:
 - PowerShell 3
 - PowerCLI 6.0
 - PureStoragePowerShellSDK 1.7.4.0