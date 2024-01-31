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
 # PSSession to Domain Controller and Use Active Directory CMDLETS
 [Parameter(Mandatory = $True)]
 [string]$OrgUnit,
 [Parameter(Mandatory = $True)]
 [Alias('ADCred')]
 [System.Management.Automation.PSCredential]$ADCredential,
 [Parameter(Mandatory = $True)]
 [Alias('MailCred', 'emailCred')]
 # Use an Microsoft email account with looser restriction on your SPAM filter
 [System.Management.Automation.PSCredential]$EmailCredential,
 # Add a recipient to monitor sent messages.
 [Parameter(Mandatory = $false)]
 [array]$Bcc,
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
  Write-Verbose ($_.html | Out-String)
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
 begin { function myDate ($days) { Get-Date ((Get-Date).AddDays($days)) -f yyyyMMdd } }
 process {
  $expireDateStr = Get-Date $_.expireDate -f yyyyMMdd
  if ($expireDateStr -eq (myDate 1)) { return $_ }
  if ($expireDateStr -eq (myDate 3)) { return $_ }
  if ($expireDateStr -eq (myDate 7)) { return $_ }
  if ($expireDateStr -eq (myDate 14)) { return $_ }
 }
}

function Send-PwMsg {
 begin {
  $mailParams = @{
   From       = '<{0}>' -f $EmailCredential.Username
   Subject    = 'CUSD Password Expires Soon'
   BodyAsHTML = $True
   Body       = $_.html
   SMTPServer = 'smtp.office365.com'
   Cred       = $EmailCredential # use a valid Office365 account with Flow rules in place to prevent SPAM warnings.
   UseSSL     = $True
   Port       = 587
   Bcc        = $null
  }
  if ( $Bcc ) { $mailParams.Bcc = $Bcc } # Add Bcc to outgoing email messages.
 }
 process {
  $to = "<$($_.mail1)>", "<$($_.mail2)>"
  Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, ($to -join ','), $_.expireDate)
  if (!$WhatIf) { Send-MailMessage @mailParams -To $to }
  $_
 }
}

function Show-Obj { Process { Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String) } }

# ======================== Main ========================
# Imported Functions
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

Show-TestRun

$dc = Select-DomainController $DomainControllers
New-ADSession -dc $dc -cmdlets 'Get-ADUser' -cred $ADCredential

Get-ADObjs |
Format-Obj |
Limit-Spam |
Format-Message |
Send-PwMsg |
Show-Obj