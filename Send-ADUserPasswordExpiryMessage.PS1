<#
.SYNOPSIS
	This script sends a heads-up email to users for whom account passwords are about to expire.
.DESCRIPTION
.EXAMPLE
.INPUTS
.OUTPUTS
.NOTES
Special Thanks to Robert Allen!: https://activedirectorypro.com/how-to-get-ad-users-password-expiration-date/
#>
[CMDLETBINDING()]
param (
 [Parameter(Mandatory = $True)][PSCredential]$ADCredential,
 [Parameter(Mandatory = $True)][string]$OrgUnit,
 [Parameter(Mandatory = $True)][PSCredential]$EmailCredential,
 [Parameter(Mandatory = $false)][string[]]$Bcc,
 [Alias('wi')][switch]$WhatIf
)

function Format-Obj {
 process {
  [PSCustomObject]@{
   samid      = $_.SamAccountName
   mail1      = $_.Mail
   mail2      = $_.HomePage
   expireDate = $_.ExpiryDate
   html       = $null
  }
 }
}

function Format-Message {
 begin { $baseHtml = Get-Content -Path '.\lib\PasswordWarningMessage.html' -Raw }
 process {
  $_.html = $baseHtml -replace 'MYEXPIREDATE', ([string](Get-Date $_.expireDate -Format 'D'))
  if ($_.html.length -lt 1) { Write-Error ('{0},{1}' -f $MyInvocation.MyCommand.Name, $_.samid) }
  Write-Verbose ($MyInvocation.MyCommand.Name, $_.html | Out-String)
  $_
 }
}

function Get-ADObjs ($ou, [pscredential]$cred) {
 $params = @{
  Filter     = "employeeID -like '*' -and mail -like '*@*' -and homepage -like '*@*' -and
  PasswordNeverExpires -eq 'False' -and Enabled -eq 'True'"
  Credential = $cred
  searchBase = $ou
  properties = 'HomePage', 'Mail', 'msDS-UserPasswordExpiryTimeComputed'
 }
 # Get qualifying employee user objects
 $cutOff = (Get-Date).AddDays(14)
 $users = Get-ADUser @params | Where-Object { $_.DistinguishedName -notlike '*New Employee Accounts*' } |
  Select-Object -Property 'SamAccountName', 'homepage', 'mail',
  @{Name = 'ExpiryDate'; Expression = {
    $ft = $_.'msDS-UserPasswordExpiryTimeComputed'
    # 0 and Int64.MaxValue mean no expiration is set; FromFileTime rejects them
    if ($ft -gt 0 -and $ft -lt [int64]::MaxValue) { [datetime]::FromFileTime($ft) }
   } } |
   Where-Object { ($_.ExpiryDate -is [datetime]) -and $_.ExpiryDate -lt $cutOff } | Sort-Object -Property ExpiryDate
 Write-Host ('{0},{1}' -f $MyInvocation.MyCommand.Name, @($users).count) -F Green
 $users
}

function Limit-Spam {
 begin { function targetDate ($days) { Get-Date ((Get-Date).AddDays($days)) -f yyyyMMdd } }
 process {
  $expireDateStr = Get-Date $_.expireDate -f yyyyMMdd
  if (
   ($expireDateStr -eq (targetDate 1)) -or
   ($expireDateStr -eq (targetDate 3)) -or
   ($expireDateStr -eq (targetDate 5)) -or
   ($expireDateStr -eq (targetDate 7)) -or
   ($expireDateStr -eq (targetDate 10)) -or
   ($expireDateStr -eq (targetDate 14))
  ) { return $_ }
 }
}

function Send-PwMsg {
 begin {
  $mailParams = @{
   From       = '<{0}>' -f $EmailCredential.Username
   Subject    = 'CUSD Password Expires Soon'
   SMTPServer = 'smtp.office365.com'
   Cred       = $EmailCredential # use a valid Office365 account with Flow rules in place to prevent SPAM warnings.
   UseSSL     = $True
   Port       = 587
   WhatIf     = $WhatIf
  }
  if ( $Bcc ) { $mailParams.Bcc = $Bcc } # Add Bcc to outgoing email messages.
 }
 process {
  $mailParams.HTML = $_.html
  $mailParams.To = "<$($_.mail1)>", "<$($_.mail2)>"
  $msg = $MyInvocation.MyCommand.Name, ($mailParams.To -join ','), ((Get-Date $_.expireDate -f 'D').Replace(',', ''))
  Write-Host ('{0},{1},{2}' -f $msg) -F Blue
  Send-EmailMessage @mailParams
  $mailParams
 }
}

function Show-Obj { process { Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String) } }

# ================================================
Import-Module -Name 'dbatools', 'CommonScriptFunctions', 'Mailozaurr'
Import-Module -Name ActiveDirectory -Cmdlet Get-ADUser -WarningAction SilentlyContinue -ErrorAction Stop

Get-ADObjs $OrgUnit -cred $ADCredential |
 Format-Obj |
  Limit-Spam |
   Format-Message |
    Send-PwMsg |
     Show-Obj