### The purpose of this Reboot script is to automate the daily reboot process of Citrix VDA machines based on Tags
### The script will attempt to keep the Reboot downtime window as short as possible and make machines available to users as quickly as possible
### Below is the logic used by the script:

1. First step is to select all machines with desired Tag

    a. The tag can be passed to the script as a parameter
    
    b. If no Tag parameter is passed, teh script will generate the tag (see code for tag generation function)

2. Loop through the servers performing Drain and Reboot dynamically. This will be done for a set amount of time

	a. Put servers in Maintenance Mode (if they're not in MM already)

	b. Optionally Notify the users that the servers will be rebooted and they should save their work, etc. (see UserNotificationMessage.txt)

	c. Check for servers in Maintenance Mode that have 0 sessions

	d. Reboot servers with 0 sessions

	e. Wait a few minutes (configurable) for machines to Reboot and Register

	f. Check rebooted servers and see if they're Registered. If any are found, disable Maintenance Mode on them so they're ready for users

3. After first reboot phase has timed out, spend N amount of time looping through all the servers that were not rebooted

	a. Reboot all servers that were not rebooted, regardless of whether they have sessions or not

	b. Wait a few minutes (configurable) for machines to Reboot and Register

	c. Check rebooted servers and see if they're Registered. If any are found, disable Maintenance Mode on them so they're ready for users

### We should never get to this point unless something went really wrong with Registration, or DDC issues rebooting, or issues with the Hypervisor, etc...
4. If at this point there's still servers that have not rebooted, reboot them and take them out of Maintenance Mode