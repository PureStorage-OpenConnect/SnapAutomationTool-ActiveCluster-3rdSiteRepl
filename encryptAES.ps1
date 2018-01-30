#Description: Encrypt with AES the APIToken

#Author: Gabor Horvath - Professional Service Engineer
#E-mail: gabor@purestorage.com
#Copyright: Pure Storage Inc.
#Changed: 11.12.2017
#Status: Public
#Version: 1.0

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