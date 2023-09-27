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

# Imported Functions
. .\lib\Add-Log.ps1
. .\lib\Clear-SessionData.ps1
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

Show-TestRun
Clear-SessionData

$dc = Select-DomainController $DomainControllers
New-ADSession -dc $dc -cmdlets 'Get-ADUser' -cred $ADCredential

$expiryHtmlMessagetemplate = Get-Content -Path '.\lib\PasswordWarningMessage.html' -Raw

$params = @{
	Filter     = {
		( employeeID -like "*" ) -and
		( mail -like "*@chicousd.org" ) -and
		( homepage -like "*@ChicoUSD.net" ) -and
		( PasswordNeverExpires -eq $False ) -and
		( Enabled -eq $True )
	}
	properties = 'homepage', 'mail', "msDS-UserPasswordExpiryTimeComputed"
	searchBase = $OrgUnit
}

# Get qualifying employee user objects
$users = Get-ADUser @params | Where-Object { $_.DistinguishedName -notlike "*New Employee Accounts*" } |
Select-Object -Property 'samAccountName', 'homepage', 'mail', @{Name = "ExpiryDate"; Expression = { [datetime]::FromFileTime($_."msDS-UserPasswordExpiryTimeComputed") } }

function sendMail ([string]$to, [string]$type) {
 Add-Log $type ('{0} Sending {1} message' -f $to, $type) -WhatIf:$WhatIf
 if ($WhatIf) { $mailParams.Body }
 else {
  $cnt = 0
  do {
   $cnt++
   try {
    $mailError = $null
    Send-MailMessage @mailParams -To $to -ErrorVariable mailError
    return # exit loop if successful
   }
   catch {
    $mailError
    Start-Sleep 10 # Wait 10 seconds before trying again
   }
  } while ( $cnt -lt 5 ) # try to send the mail message up to x times before throwing failure
  throw "Send-MailMessage to $to failed. Exiting script. See error messages"
  EXIT
 }
}

function notifyUsers ($usersObject, [string]$groupName) {
 BEGIN {
  Add-Log beginprocess ('Notifying {0} group' -f $groupName)
  $expiryHtmlMessagetemplate = Get-Content -Path '.\lib\PasswordWarningMessage.html' -Raw
 }
 PROCESS {
  # Check usersObject
  if ($null -ne $usersObject.count) {
   Add-Log info ('Users to Notify: ' + $usersObject.count)
   foreach (	$user in $usersObject ) {
    if ( $null -eq $user ) { continue }
    Write-Debug ('Process {0} ?' -f $user.samAccountName)
    Write-Verbose ('Processing {0}' -f $user.samAccountName)
    $myDate = Get-Date $user.ExpiryDate | Out-String
    $outgoingMessage = $expiryHtmlMessagetemplate -f $myDate
    $mailParams = @{
     From       = '<{0}>' -f $EmailCredential.Username
     Subject    = 'CUSD Password Expires Soon'
     BodyAsHTML = $True
     Body       = $outgoingMessage
     SMTPServer = 'smtp.office365.com'
     Cred       = $EmailCredential # use a valid Office365 account with Flow rules in place to prevent SPAM warnings.
     UseSSL     = $True
     Port       = 587
    }
    $office365 = '<{0}>' -f $user.mail
    $gsuite = '<{0}>' -f $user.homepage

    if ( $Bcc ) { $mailParams.Bcc = $Bcc } # Add Bcc to outgoing email messages.

    sendMail -to $office365 -type 'Office365'
    sendMail -to $gsuite -type 'GSUITE'

    # Introduce artifical delay to help combat SPAM flagging (hopefully)
    if (!$WhatIf) {
     'Sleeping for 10 seconds...'
     Start-Sleep 10
    }
    Write-Verbose ('{0},{1},Password Expiry Messages Sent' -f $user.mail, $user.homepage)
   }
  }
 }
 END {
  Add-Log endprocess ('Completed processing for {0} group' -f $groupName)
  # 'END '
 }
}
function getBeginDate ($days) { (get-date -h 0 -min 0 -sec 0).AddDays($days) }
function getEndDate ($days) { (get-date -h 23 -min 59 -sec 59).AddDays($days) }

# Gets accounts with pw expiry dates within the 1 day timeframe.
$oneDayNotify = $users | Where-Object { ($_.ExpiryDate -gt (getBeginDate 1)) -and ($_.ExpiryDate -lt (getEndDate 1)) }
# Gets accounts with pw expiry dates within the 3 day timeframe.
$threeDayNotify = $users | Where-Object { ($_.ExpiryDate -gt (getBeginDate 3)) -and ($_.ExpiryDate -lt (getEndDate 3)) }
# Gets accounts with pw expiry dates within the 7 day timeframe.
$oneWeekNotify = $users | Where-Object { ($_.ExpiryDate -gt (getBeginDate 7)) -and ($_.ExpiryDate -lt (getEndDate 7)) }
# Gets accounts with pw expiry dates within the 14 day timeframe.
$twoWeekNotify = $users | Where-Object { ($_.ExpiryDate -gt (getBeginDate 14)) -and ($_.ExpiryDate -lt (getEndDate 14)) }

if ($oneDayNotify) { notifyUsers -usersObject $oneDayNotify -groupName 'oneDayNotify' }
if ($threeDayNotify) { notifyUsers -usersObject $threeDayNotify -groupName 'threeDayNotify' }
if ($oneWeekNotify) { notifyUsers -usersObject $oneWeekNotify -groupName 'oneWeekNotify' }
if ($twoWeekNotify) { notifyUsers -usersObject $twoWeekNotify -groupName 'twoWeekNotify' }

# Start-Sleep 5 # Just a delay for test runs

Clear-SessionData
Show-TestRun