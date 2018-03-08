function Get-TimeStamp
{
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss").ToString()
}


function Out-Log
{
    <#
    .SYNOPSIS 
        Write an output and log.

    .DESCRIPTION
        Write the text with an appropriate formating method and append to the log file with timestamp and severity.

    .PARAMETER Text
        Text to be written.

    .PARAMETER Severity
        For formating

    .NOTES
        For the logging please use the variable [string]$global:LogFile in the main script!
    #>


    Param (
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
        [ValidateNotNullOrEmpty()]
        $Text,

        [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
        [ValidateSet("Host","Debug","Information","Verbose","Warning","Error")]
        [string]$Severity = "Debug"
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"

    if ([string]::IsNullOrEmpty($global:LogFile)) {
        Write-Error "The varible `$global:LogFile is null or empty! Please use in a main script this variable!"
    }

    switch ($Severity)
    {
        "Host" { Write-Host $Text }
        "Debug" { Write-Debug $Text }
        "Information" { if ($PSVersionTable.PSVersion.Major -ge 5) { Write-Information $Text } else { Write-Verbose $Text } }
        "Verbose" { Write-Verbose $Text }
        "Warning" { Write-warning $Text }
        "Error" { Write-Host $Text -ForegroundColor Red -BackgroundColor Black }
        default { Write-Error "The severity of function Out-Log is not appropiate!`nPlease use following severities: ( Console, Debug, Info, Verbose, Warning, Error )" }
    }

    $outfile = "$(Get-TimeStamp) - $($Severity): $Text"
    $outfile | Out-File -FilePath $global:LogFile -Append
    
    $ErrorActionPreference = $previousErrorActionPreference
}


function Exit-Program
{
    <#
    .SYNOPSIS 
        Finishes running the program.

    .DESCRIPTION
        Logs the end of program and exiting.

    .PARAMETER Exitcode
        Exit code

    .NOTICE
        To disconnect from the environment please use the hash $global:ObjectList
        To restore the variable preference please use the hash $global:originalVariablePreference

    #>


    Param (
        [Parameter(Mandatory=$false,ValueFromPipeline=$false,Position=0)]
        $Exitcode = 0
    )

    Begin {
        $function = '{0}' -f $MyInvocation.MyCommand
        Out-Log "CALLING function '$function'"
    }
    
    Process {
        if ($global:ObjectList -ne $null) {
            $global:ObjectList.Keys | % { $global:ObjectList.Item($_).Disconnect() }
        }
    }

    End {
        $global:originalVariablePreferences.Keys | % { Set-Variable -Name $_ -Value $global:originalVariablePreferences.Item($_) -Scope Global -Force }
    
        Out-Log "########### END ###########"
        Exit $Exitcode
    }
}


Function Get-XmlSchema
{
    param($SchemaPath)

    try
    {
        $schemaItem = Get-Item $SchemaPath
        $stream = $schemaItem.OpenRead()
        $schema = [Xml.Schema.XmlSchema]::Read($stream, $null)
        return $schema
    }
    catch
    {
        throw
    }
    finally
    {
        if($stream) {
            $stream.Close()
        }
    }
}


function Test-XmlSchema
{
    param (
        [Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [xml]$XmlData,
       
        [Parameter(Mandatory=$true,ValueFromPipeline=$false,ValueFromPipelineByPropertyName=$false)]
        [ValidateNotNullOrEmpty()]
        [String]$SchemaPath
    )

    $schemas = New-Object System.Xml.Schema.XmlSchemaSet
    $schemas.CompilationSettings.EnableUpaCheck = $false
    $schema = Get-XmlSchema $SchemaPath
    [void]($schemas.Add($schema))
    $schemas.Compile()
      
    try
    {
        $xmlData.Schemas = $schemas

        #Validate the schema. This will fail if is invalid schema
        $xmlData.Validate($null)
        return $true
    }
    catch [System.Xml.Schema.XmlSchemaValidationException]
    {
        return $false
    }
}


function Test-Xml
{
    <#
    .SYNOPSIS 
        Validate the XML config file

    .DESCRIPTION
        Reading the secure hashes and decrypt it. After the decryption create a credential and return it.

    .PARAMETER XmlData
        The content of config

    .PARAMETER SchemaPath
        This is an XML Schema file (xsd) 
    #>


    Param (
        [Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [xml]$XmlData,
       
        [Parameter(Mandatory=$true,ValueFromPipeline=$false,ValueFromPipelineByPropertyName=$false)]
        [ValidateNotNullOrEmpty()]
        [String]$SchemaPath
    )

    Begin {
        $function = '{0}' -f $MyInvocation.MyCommand
        Out-Log "CALLING function '$function' {"
        Out-Log "VALIDATION: $SchemaPath"
    }

    Process {    
        if ($XmlData | Test-XmlSchema -SchemaPath $SchemaPath) {
            Out-Log "VALIDATION: SUCCESS"
        } else {
            Out-Log "The configuration '$global:ConfigFile' isn't valid! Please check it!" "Error"
            Exit-Program -Exitcode 1
        }
    }

    End {
        Out-Log "RETURNING function '$function' }"
    }
}


function Get-EncryptedData
{
    Param($hash, $key)

    return ($hash | ConvertTo-SecureString -Key $key | % {[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_))})
}


function Get-SecuredCredential
{
    <#
    .SYNOPSIS 
        Read the encrypted credential from secure file

    .DESCRIPTION
        Reading the secure hashes and decrypt it. After the decryption create a credential and return it.

    .PARAMETER SecuredCredentialFile
        This file contains the encrypted user name and password hash

    .PARAMETER KeyFile
        With this key file is encrypted the user name and password 
    #>


    Param (
        [Parameter(Mandatory=$true,ValueFromPipeline=$false)]
        [ValidateNotNullOrEmpty()]
        $SecuredCredentialFile,

        [Parameter(Mandatory=$true,ValueFromPipeline=$false)]
        [ValidateNotNullOrEmpty()]
        $KeyFile
    )

    Begin {
        $function = '{0}' -f $MyInvocation.MyCommand
        Out-Log "CALLING function '$function' {"
    }

    Process {
        $Credential = $null
        if (Test-Path -Path $KeyFile) {
            $key = Get-Content $KeyFile
            if (Test-Path -Path $SecuredCredentialFile) {
                [array]$SecureHashWithKey = Get-Content $SecuredCredentialFile
                $DecryptedUserName = $SecureHashWithKey[0] | ConvertTo-SecureString -Key $Key  
                $DecryptedPassword = $SecureHashWithKey[1] | ConvertTo-SecureString -Key $Key
                $Credential = New-Object System.Management.Automation.PSCredential((Get-EncryptedData -hash $SecureHashWithKey[0] -key $key), $DecryptedPassword)
                return $Credential
            } else {
                Out-Log "The credential file '$SecuredCredentialFile' doesn't exist!" "Error"
                Exit-Program -Exitcode 5
            }
        } else {
            Out-Log "The KeyFile '$KeyFile' doesn't exist!" "Error"
            Exit-Program -Exitcode 6
        }
    }

    End {
        Out-Log "RETURNING function '$function' }"
    }
}