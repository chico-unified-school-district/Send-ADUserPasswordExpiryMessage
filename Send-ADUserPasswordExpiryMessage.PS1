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
 [Parameter(Mandatory = $True)]
 [Alias('DCs')]
 [string[]]$DomainControllers,
 [Parameter(Mandatory = $True)]
 [PSCredential]$ADCredential,
 [Parameter(Mandatory = $True)]
 [string]$OrgUnit,
 [Parameter(Mandatory = $True)]
 [Alias('MailCred')]
 [PSCredential]$EmailCredential,
 [Parameter(Mandatory = $false)]
 [string[]]$Bcc,
 [Alias('wi')]
 [switch]$WhatIf
)

function Format-Obj {
 process {
  $obj = '' | Select-Object samid, mail1, mail2, expireDate, html
  $obj.samid = $_.SamAccountName
  $obj.mail1 = $_.Mail
  $obj.mail2 = $_.HomePage
  $obj.expireDate = $_.ExpiryDate
  $obj
 }
}

function Format-Message {
 begin { $baseHtml = Get-Content -Path '.\lib\PasswordWarningMessage.html' -Raw }
 process {
  $_.html = $baseHtml -f ([string](Get-DAte $_.expireDate -Format 'D'))
  if ($_.html.length -lt 1) { Write-Error ('{0},{1}' -f $MyInvocation.MyCommand.Name, $_.samid) }
  $_
 }
}

function Get-ADObjs {
 $params = @{
  Filter     = "employeeID -like '*' -and mail -like '*@*' -and homepage -like '*@*' -and
   PasswordNeverExpires -eq 'False' -and Enabled -eq 'True'"
  searchBase = $OrgUnit
  properties = 'HomePage', 'Mail', "msDS-UserPasswordExpiryTimeComputed"
 }
 # Get qualifying employee user objects
 $cutOff = (Get-Date).AddDays(14)
 $users = Get-ADUser @params | Where-Object { $_.DistinguishedName -notlike "*New Employee Accounts*" } |
 Select-Object -Property 'SamAccountName', 'homepage', 'mail',
 @{Name = "ExpiryDate"; Expression = { [datetime]::FromFileTime($_."msDS-UserPasswordExpiryTimeComputed") } } |
 Where-Object { ($_.ExpiryDate -is [datetime]) -and $_.ExpiryDate -lt $cutOff } | Sort-Object -Property ExpiryDate
 if ($users) { Write-Host ('{0},{1}' -f $MyInvocation.MyCommand.Name, $users.count) }
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
   BodyAsHTML = $True
   SMTPServer = 'smtp.office365.com'
   Cred       = $EmailCredential # use a valid Office365 account with Flow rules in place to prevent SPAM warnings.
   UseSSL     = $True
   Port       = 587
  }
  if ( $Bcc ) { $mailParams.Bcc = $Bcc } # Add Bcc to outgoing email messages.
 }
 process {
  $mailParams.Body = $_.html
  $mailParams.To = "<$($_.mail1)>", "<$($_.mail2)>"
  $msg = $MyInvocation.MyCommand.Name, ($mailParams.To -join ','), ((Get-Date $_.expireDate -f 'D').Replace(',', ''))
  Write-Host ('{0},{1},{2}' -f $msg)
  if (!$WhatIf) { Send-MailMessage @mailParams }
  $mailParams
 }
}

function Show-Obj { Process { Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String) } }

# ======================== Main ========================
# Imported Functions
. .\lib\Load-Module.ps1
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

Show-TestRun
New-ADSession -dc (Select-DomainController $DomainControllers) -cmdlets 'Get-ADUser' -cred $ADCredential
Get-ADObjs |
Format-Obj |
Limit-Spam |
Format-Message |
Send-PwMsg |
Show-Obj