# Send-ADUserPasswordExpiryMessage
This script sends a heads-up email to users for whom account passwords are about to expire.

The script uses the AD 'msDS-UserPasswordExpiryTimeComputed' attribute to determine if a message will be sent. 