<#
.SYNOPSIS 
    This script generate a encrypted credentials.

.DESCRIPTION
    
.PARAMETER KeyFile
    Whit this file will be the encryption mechanism salted. Default value: AES.key

.PARAMETER NewKeyRequired
    New key file will be generated. Attention! When you generates a new key file than you need generate the password files

.PARAMETER NewSecurePasswordFile
    Name of encrypted password file. Default parameter: SecCredeFA.txt

.PARAMETER UserName
    User name

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
    [string]$NewSecureCredentialFile = "SecCredFA.txt",

    [Parameter(Mandatory=$True)]
    [string]$UserName,
    
    [Parameter(Mandatory=$True)]
    [string]$Password
)


$originalErrorActionPreference = "Stop"

if ($NewKeyRequired) {
    $Key = New-Object Byte[] 32
    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
    $Key | Out-File $KeyFile
}
else {
    $key = Get-Content $KeyFile
}

$null | Out-File $NewSecureCredentialFile

@($UserName, $Password) | % {
    $SecureHash = ConvertTo-SecureString $_ -AsPlainText -Force
    $SecureHashWithKey = $SecureHash | ConvertFrom-SecureString -Key $key
    $SecureHashWithKey | Out-File $NewSecureCredentialFile -Append
}

