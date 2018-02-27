# SnapAutomationTool-ActiveCluster-3rdSiteRepl

Snap Automaintion Tool for VMware and ActiveCluster 3rd site Replication



This project created for Pure Storage FlashArray customers who using the ActivelCluster feature with a 3rd site (DR) replication. 
Features:
 - Do the snap transfer from ActiveCluster to the 3rd site replication (Core function)
 - Create VM snapshots in the vmware environment (When the vmware secition exist in the config file)
 - Apply the predefined retention on the 3rd site. (When the parameter given)

Files:
 - BusinessLogicFunctions.psm1  -> This file stored the functions fo the business logic
 - ClassDefinitionandFunctions.psd1  -> Manifest for ClassDefinitionandFunctions.psm1
 - ClassDefinitionandFunctions.psm1  -> This file stored the classes and the class methods.
 - EncryptCredential.ps1  -> Its creating the key file and the encrypted credential. (It isn't neccesary to the script running)
 - GaborFunctions.psd1  -> Manifest for GaborFunctions.psm1
 - GaborFunctions.psm1  -> Helper functions
 - podbackup.ps1  -> Main script

Minimum Requirements:
 - PowerShell 5.0
 - PowerCLI 6.0
 - PureStoragePowerShellSDK 1.7.4.0