<#
.SYNOPSIS 
    This script generate a encrypted password for credentials.

.DESCRIPTION
    
.PARAMETER KeyFile
    Whit this file will be the encryption mechanism salted. Default value: AES.key

.PARAMETER NewKeyRequired
    New key file will be generated. Attention! When you generates a new key file than you need generate the password files

.PARAMETER NewSecurePasswordFile
    Name of encrypted password file. Default parameter: SecFileFA.txt

.PARAMETER Password
    Password

.NOTES
    Author: Gabor Horvath - Professional Service Engineer
    E-mail: gabor@purestorage.com
    Copyright: Pure Storage Inc.
 #>


Param (
    [Parameter(Mandatory=$False,Position=1)]
    [string]$KeyFile = "AES.key",

    [switch]$NewKeyRequired,

    [Parameter(Mandatory=$False)]
    [string]$NewSecurePasswordFile = "SecFileFA.txt",

    [Parameter(Mandatory=$True)]
    [string]$Password
)


$ErrorActionPreference = "Stop"

if ($NewKeyRequired) {
    $Key = New-Object Byte[] 32
    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
    $Key | Out-File $KeyFile
}
else {
    $key = Get-Content $KeyFile
}

$SecureAPITokenHash = ConvertTo-SecureString $Password -AsPlainText -Force
$SecureAPITokenHashWithKey = $SecureAPITokenHash | ConvertFrom-SecureString -Key $key
$SecureAPITokenHashWithKey | Out-File $NewSecurePasswordFile

Write-Output $SecureAPITokenHashWithKey