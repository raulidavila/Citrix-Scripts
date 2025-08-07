<#
.SYNOPSIS
    Script for daily machine reboot
.DESCRIPTION
    This script will drain machines as much as possible and finally reboot them, in as short a time as possible.
.PARAMETER ControllerAddress
    FQDN of the DDC that will receive all the commands to manage and reboot the machines. This parameter is mandatory.
.PARAMETER RebootTag
    The tag used to identify which machines will be rebooted.
    If no Tag is given, the script will generate the Tag based on the Day and hour the script is executed.
.PARAMETER FirstPhaseTimeout
    Minutes to wait for servers to drain and reboot during the first reboot loop. Default is 60 minutes.
.PARAMETER SessionCheckInterval
    Minutes to wait between each check to see which servers have been drained and are ready for reboot. Default is 5 minutes.
.PARAMETER RegistrationWaitMinutes
    Minutes to wait for servers to Register after sending the reboot command. Default is 3 minutes.
.PARAMETER SecondPhaseTimeout
    Minutes to wait for servers to reboot and register during the second reboot loop. Default is 30 minutes.
.PARAMETER LogFile
    Path and filename for log file. Enclosed it in quotes if it contains any spaces.
    If not given, or if the script can't create or write to the file, the default is "DailyRebootLog.txt" under the same directory as the script.
.PARAMETER CountActiveSessionsOnly
    If given, when counting sessions to determine if a server has been drained the script will only consider Active sessions and ignore Disconnected sessions.
    For example if a server has 0 Active sessions and 100 Disconnected sessions, it will be considered as drained and therefore will be rebooted.
.PARAMETER NotifyUsers
    If given, the script will send a message to each user with an Active session to notify them of the reboot.
.PARAMETER LogToConsole
    If given, all logging will be shown in the Powershell console in addition to the log file. This is mostly for troubleshooting.
.PARAMETER Debugging
    If given, the amount of logging will be more detailed. This is mostly for troubleshooting.
.EXAMPLE
    PS> DrainAndRebootScript.ps1 -ControllerAddress "SomeDDC.unch.unc.edu" -RebootTag "Reboot-tag" -FirstPhaseTimeout 60 -SessionCheckInterval 5 -RegistrationWaitMinutes 3 -SecondPhaseTimeout 10 -CountActiveSessionsOnly -NotifyUsers
    This syntax of calling the script is suitable for Scheduled Tasks.
.EXAMPLE
    PS> DrainAndRebootScript.ps1 -ControllerAddress "SomeDDC.unch.unc.edu" -RebootTag "Reboot-tag" -FirstPhaseTimeout 60 -SessionCheckInterval 5 -RegistrationWaitMinutes 3 -SecondPhaseTimeout 10 -CountActiveSessionsOnly -NotifyUsers -LogToConsole -Debugging
    Script can also be run interactively and see the colored output on the Powershell console.
#>

param (
    [Parameter(Mandatory=$true)] [string] $ControllerAddress,
    [string] $RebootTag,
    [int] $FirstPhaseTimeout = 60,
    [int] $SessionCheckInterval = 5,
    [int] $RegistrationWaitMinutes = 3,
    [int] $SecondPhaseTimeout = 30,
    [string] $LogFile,
    [switch] $CountActiveSessionsOnly,
    [switch] $NotifyUsers,
    [switch] $LogToConsole,
    [switch] $Debugging
)

class VdaInfo {
    [string] $MachineName
    [int]    $SessionCount
    [bool]   $InMaintenanceMode
    [bool]   $Rebooted
    [bool]   $ReadyForUsers
}

#region Logging functions
enum LogLevel {
    Info
    Warning
    Error
    Critical
    Debug
}

function LogParameters {
    param (
        $scriptParameters,
        $RebootTag
    )

    LogDebug "The following parameters were passed to the script"
    $scriptParameters.GetEnumerator() | ForEach-Object {
        LogDebug "$($_.Key): $($_.Value)" 1
    }

    if($scriptParameters.keys.contains("CountActiveSessionsOnly") -eq $false) { LogDebug "CountActiveSessionsOnly: False" 1 }
    if($scriptParameters.keys.contains("NotifyUsers") -eq $false) { LogDebug "NotifyUsers: False" 1 }
    if($scriptParameters.keys.contains("LogToConsole") -eq $false) { LogDebug "LogToConsole: False" 1 }
    if($scriptParameters.keys.contains("Debugging") -eq $false) { LogDebug "Debugging: False" 1 }
    if($scriptParameters.keys.contains("RebootTag") -eq $false) { LogInfo "Reboot Tag not provided in script parameters. Generated Reboot Tag is $RebootTag" }
}

function LogInfo([string] $text, [int] $indentLevel = 0) {
    LogText $text $indentLevel ([LogLevel]::Info)
}

function LogWarning([string] $text, [int] $indentLevel = 0) {
    LogText $text $indentLevel ([LogLevel]::Warning)
}

function LogError([string] $text, [int] $indentLevel = 0) {
    LogText $text $indentLevel ([LogLevel]::Error)
}

function LogCritical([string] $text, [int] $indentLevel = 0) {
    LogText $text $indentLevel ([LogLevel]::Critical)
}

function LogDebug([string] $text, [int] $indentLevel = 0) {
    if($Global:debugLogging) {
        LogText $text $indentLevel ([LogLevel]::Debug)
    }
}

function InitializeLog {

    $scriptDirectoryPath = $MyInvocation.PSScriptRoot

    # Check if a good path to a file was passed for the log
    if($Global:logFile -ne "") {
        try {
            [io.file]::OpenWrite($Global:logFile).close()
        } catch {
            # We could not write to that file. See if we can create our own log file in that same directory
            $Global:logFile = ($Global:logFile | Split-Path -Parent) + "\DailyRebootLog.txt"
            try {
                [io.file]::OpenWrite($Global:logFile).close()
            } catch {
                $Global:logFile = ""
            }
        }
    }

    if($Global:logFile -eq "") {
        # Logfile path was unusable or none given or the path was not good to create our own log file there
        # We will try creating a log file in the same path where the script is located
        $Global:logFile = $scriptDirectoryPath + "\DailyRebootLog.txt"
        try {
            [io.file]::OpenWrite($Global:logFile).close()
            LogWarning "LogFile parameter was not good or empty or the file is not writable or the directory was not good, but we were able to create our own file in our own directory"
        } catch {
            # We give up trying to create a log file
            $Global:logFile = ""
        }
    }
}

function LogText([string] $text, [int] $indentLevel = 0, [LogLevel] $logLevel) {
    $prefix = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$logLevel]: $(' ' * (8 - $($logLevel.ToString().Length)))"
    $text = $text.PadLeft($text.Length + ($indentLevel * 4))
    if($Global:consoleLogging) {
        LogToConsole ($prefix + $text) $logLevel $indentLevel
    }

    if($Global:logFile -ne "") {
        "$prefix $text" | Out-File -FilePath $Global:logFile -Append
    }
}

function LogToConsole([string] $text, [LogLevel] $logLevel, [int] $indentLevel) {
    switch($logLevel) {
        {$_ -in ([LogLevel]::Info), ([LogLevel]::Debug)} {
            switch($indentLevel) {
                (0) {Write-Host "$text" -ForegroundColor Blue}
                (1) {Write-Host "$text" -ForegroundColor Magenta}
                (2) {Write-Host "$text" -ForegroundColor Cyan}
            }            
        }
        ([LogLevel]::Error) {Write-Host "$text" -ForegroundColor DarkMagenta}
        ([LogLevel]::Warning) {Write-Host "$text" -ForegroundColor Yellow}
        ([LogLevel]::Critical) {Write-Host "$text" -ForegroundColor DarkRed -BackgroundColor Yellow}
    }
}

function FinishLog($processStartTime, $elapsedTime) {
    $text = "`nReboot process duration: "

    if($elapsedTime.Days -gt 0) {
        $text += "$($elapsedTime.Days) days, "
    }

    if($elaelapsedTimepsed.Hours -gt 0 -or $elapsedTime.TotalDays -gt 0) {
        $text += "$($elapsedTime.Hours) hours, "
    }

    if($elapsedTime.Minutes -gt 0 -or $elapsedTime.Hours -gt 0) {
        $text += "$($elapsedTime.Minutes) minutes, "
    }

    $text += "$($elapsedTime.Seconds) seconds`n"
    $text += "Finished Reboot process for $($processStartTime.ToString('dddd MMMM dd, yyyy'))`n$('-' * 80)"

    if($Global:consoleLogging) {
        Write-Host $text -ForegroundColor Green
    }

    if($Global:logFile -ne "") {
        $text | Out-File -FilePath $Global:logFile -Append
    }
}
#endregion

#region Machine status functions. These functions query the DDC for details abuot the machines
function GetVdaSessionCount {
    param (
        [Parameter(Mandatory=$true)] [string] $machineName,
        [Parameter(Mandatory=$true)] [bool] $countActiveSessionsOnly
    )

    $sessionCount = 0
    if($machineName) {
        try {
            if($countActiveSessionsOnly) {
                $sessions = Get-BrokerSession -AdminAddress $Global:ddcAddress -MachineName $machineName -SessionState Active -ErrorAction Stop
            } else {
                $sessions = Get-BrokerSession -AdminAddress $Global:ddcAddress -MachineName $machineName -ErrorAction Stop
            }
            
            if ($sessions) {
                $sessionCount = $sessions.count
            }
        } catch {
            LogError "Error retrieving sessions for machine $machineName `n $_.Exception.Message" 1
            $sessionCount = -1
        }
    }

    $sessionCount
}

function IsMachineRegistered {
    param (
        [Parameter(Mandatory = $true)] [string] $machineName
    )

    $registered = $false
    try {
        $vda = Get-BrokerMachine -AdminAddress $Global:ddcAddress -MachineName $machineName -ErrorAction Stop
        if($vda.RegistrationState.ToString().ToUpper() -eq "REGISTERED") {
            $registered = $true
        }

        LogDebug "Registration state for $machineName is $registered" 2
    } catch {
        LogError "Could not turn off Maintenance Mode after rebooting machine $machineName `n $_.Exception.Message" 1
    }

    $registered
}

function UpdateSessionCounts {
    param (
        [System.Collections.SortedList] $vdaMachines,
        [bool] $countActiveSessionsOnly
    )

    LogInfo "Checking Session count on machines that still have 1 or more sessions" 1
    $totalSessionCount = 0
    foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
        if($vdaMachine.Value.SessionCount -ne 0) {
            $sessionCount = GetVdaSessionCount $vdaMachine.Key $countActiveSessionsOnly
            $vdaMachines[$vdaMachine.Key].SessionCount = $sessionCount
            if($sessionCount -gt 0) {
                $totalSessionCount += $sessionCount
            }
            
            LogDebug "$($vdaMachine.Key) -- found $($vdaMachines[$vdaMachine.Key].SessionCount) sessions" 2
        }
    }
    
    LogInfo "Found a total of $totalSessionCount sessions" 1
}

function AllMachinesReady {
    param (
        [Parameter(Mandatory = $true)] [System.Collections.SortedList] $vdaMachines
    )

    $readyStatus = $true
    foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
        if(!$vdaMachine.Value.ReadyForUsers) {
            $readyStatus = $false
        }
    }

    $readyStatus
}
#endregion

#region Machine update functions. These functions send commands to the DDC to modify a machine (reboot, maintenance)
function ChangeMaintenanceMode {
    param (
        [Parameter(Mandatory = $true)] [string] $machineName,
        [Parameter(Mandatory=$true)] [bool] $newMaintenanceMode
    )

    $success = $false
    if($newMaintenanceMode) {
        LogDebug "Enabling Maintenance Mode on $machineName" 2
    } else {
        LogDebug "Disabling Maintenance Mode on $machineName" 2
    }

    try {
        Set-BrokerMachine -AdminAddress $Global:ddcAddress -Machinename $machineName -InMaintenanceMode $newMaintenanceMode -ErrorAction Stop
        $success = $true
    } catch {
        LogError "Could not change Maintenance Mode on machine $machineName `n $_.Exception.Message" 1
    }

    $success
}

function RebootMachine {
    param (
        [Parameter(Mandatory = $true)] [string] $machineName
    )

    $success = $false
    try {
        LogDebug "Attempting Reboot on machine $machineName" 2
        New-BrokerHostingPowerAction -AdminAddress $Global:ddcAddress -Action Restart -MachineName $machineName
        LogDebug "Reboot command for machine $machineName was sent to DDC" 2
        $success = $true
    } catch {
        LogError "Could not reboot machine $machineName `n $_.Exception.Message" 1
    }

    $success
}

function BulkChangeMaintenanceMode {
    param (
        [System.Collections.SortedList] $vdaMachines,
        [bool] $newMaintenanceMode, # TRUE == Turn On MM, FALSE == Turn Off MM,
        [bool] $forceChange = $false
    )

    LogInfo "Updating Maintenance Mode on machines as needed" 1
    $totalMachinesChanged = 0
    foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
        if($forceChange -or ($vdaMachine.Value.InMaintenanceMode -ne $newMaintenanceMode -and !$vdaMachine.Value.ReadyForUsers)) {
            if(ChangeMaintenanceMode $vdaMachine.Key $newMaintenanceMode) {
                $vdaMachines[$vdaMachine.Key].InMaintenanceMode = $newMaintenanceMode
                $totalMachinesChanged++
            }
        }
    }

    # Give the DDC a few seconds to ensure the SQL DB is updated
    Start-Sleep -Seconds 5
    LogInfo "Total Machines updated: $totalMachinesChanged" 1
}

function RebootMachinesAsNeeded {
    param (
        [System.Collections.SortedList] $vdaMachines
    )

    LogInfo "Rebooting machines that have 0 sessions" 1
    $totalMachinesRebooted = 0
    foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
        if($vdaMachine.Value.SessionCount -eq 0 -and !$vdaMachine.Value.Rebooted) {
            if(RebootMachine $vdaMachine.Key) {
                $vdaMachines[$vdaMachine.Key].Rebooted = $true
                $totalMachinesRebooted++
            }
        }
    }

    # Give the DDC a few seconds to ensure the SQL DB is updated
    Start-Sleep -Seconds 5
    LogInfo "Total Machines rebooted: $totalMachinesRebooted" 1
}

function ReadNotificationMessage {
    $message = [PSCustomObject]@{
        Title = ""
        Body = ""
    }
    $inputFilePath = $MyInvocation.PSScriptRoot + "\UserNotificationMessage.txt"
    
    if(Test-Path -Path $inputFilePath) {
        $fileContents = Get-Content $inputFilePath | Where-Object { -not ([string]::IsNullOrWhiteSpace($_) -or $_.StartsWith("#")) }
        LogDebug "Read $($fileContents.Count) lines from $inputFilePath"
        if($fileContents.Count -lt 2) {
            LogError "The User Notification Message file does not contain enough lines for the user notification" 1
            return $null
        }

        foreach($line in $fileContents) {
            if($message.Title -eq "") {
                $message.Title = $line
            } else {
                $message.Body += $line + "`n"
            }
        }
        # Remove the trailing CRLF
        $message.Body = $message.Body.Substring(0, $message.Body.Length - 1)
    } else {
        LogError "Could not find Notification Message file at the following path: ""$inputFilePath"""
        return $null
    }

    return $message
}

function NotifyUsers {
    param (
        [System.Collections.SortedList] $vdaMachines
    )

    $notificationMessage = ReadNotificationMessage
    if($null -eq $notificationMessage) {
        return
    }

    LogInfo "Notifying users as needed" 1
    $totalSessionsNotified = 0
    foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
        try {
            $sessions = Get-BrokerSession -AdminAddress $Global:ddcAddress -MachineName $vdaMachine.Key -ErrorAction Stop
        } catch {
            # If we could not enumerate sessions for this server, we'll simply continue to the next server
            LogWarning "Could not enumerate sessions for user notification on server $($vdaMachine.Key). `n $_.Exception.Message"
            continue
        }

        LogDebug "Notifying users with sessions in $($vdaMachine.Key)" 2
        foreach($session in $sessions) {
            try {
                Send-BrokerSessionMessage $session -AdminAddress $Global:ddcAddress -MessageStyle Exclamation `
                    -Title $notificationMessage.Title -Text $notificationMessage.Body -ErrorAction Ignore
                $totalSessionsNotified++
            } catch {
                # Ignoring any errors here and just logging them
                LogDebug "Could not notify user $($session.Username) with session on server $($session.MachineName)" 1
            }
        }
    }

    LogInfo "Total sessions notified: $totalSessionsNotified" 1
}
#endregion

#region Logic functions. These are the main functions that control the script logic, along with some helper functions
function LockRebootSchedule {
    param (
        [string] $rebootTag
    )

    $lockFile = "$($MyInvocation.PSScriptRoot)\$rebootTag.lok"
    if(Test-Path $lockFile) {
        ## This reboot schedule is already running
        return $false
    }

    New-Item -Path $lockFile

    if($Global:consoleLogging) {
        Write-Host "`n$('-' * 80)`nStarting Reboot process for $(Get-Date -Format 'dddd MMMM dd, yyyy @ HH:mm:ss tt')`n" -ForegroundColor Green
    }

    if($Global:logFile -ne "") {
        "`n$('-' * 80)" | Out-File -FilePath $Global:logFile -Append
        "Starting Reboot process for $(Get-Date -Format 'dddd MMMM dd, yyyy @ HH:mm:ss tt')`n" | Out-File -FilePath $Global:logFile -Append
    }

    return $true
}

function UnlockRebootSchedule {
    param (
        [string] $rebootTag
    )

    $lockFile = "$($MyInvocation.PSScriptRoot)\$rebootTag.lok"
    if(Test-Path $lockFile) {
        LogInfo "Removing Lock File ""$lockFile"""
        try {
            Remove-Item -Path $lockFile
        } catch {
            LogError "Could not remove lock file ""$lockFile"""
        }
    }
}

<#
.SYNOPSIS
Generate Reboot Tag

.DESCRIPTION
Ths function will generate a Reboot Tag based on the day of the of the week and a specific format.
The function is only used if a Reboot tag was not passed in the parameters to the script
If Reboot tags already exist in the environment before implementing this script, this function must
    be changed to produce tags compatible with the existing tags

.NOTES
In the Reboot tag the first day of the week (Sunday) has a value of 1
The parts of the Reboot tag are:
    Day    -- The literal string "Day"
    1-7    -- A number specifying the day of the week, starting with 1. Sun == 1 -- Sat == 7
    1-12   -- The hour of the reboot in 12 hour format
    ampm   -- The AM or PM modifier for the hour
    Reboot -- The literal string "Reboot"
Samples of the Reboot tag format used in this case:
    Day1-4pm-Reboot -- Reboot time would be Monday at 04:00 PM
    Day5-2am-Reboot -- Reboot time would be Thursday at 02:00 AM
#>
function CreateRebootTag {
    $now = Get-Date
    # We add one because our tags use a 1 based value for the Day of the week. Sun == 1 -- Sat == 7
    $dow = $now.DayOfWeek + 1
    $hour = $now.Hour
    if($hour -lt 12) {
        $ampm = "am"
    }else {
        $ampm = "pm"
        if($hour -gt 12) {
            $hour -= 12
        }
    }

    "Day$([int]$dow)-$hour$ampm-Reboot"
}

function MarkCompletedMachines{
    param (
        [System.Collections.SortedList] $vdaMachines
    )

    LogInfo "Checking rebooted machines that completed Registration and turning off Maintenance Mode on them" 1

    foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
        if($vdaMachine.Value.Rebooted -and !$vdaMachine.Value.ReadyForUsers) {
            if(IsMachineRegistered $vdaMachine.Key) {
                if(ChangeMaintenanceMode $vdaMachine.Key $false) {
                    $vdaMachines[$vdaMachine.Key].InMaintenanceMode = $false
                    $vdaMachines[$vdaMachine.Key].ReadyForUsers = $true
                }
            }
        }
    }

    # Give the DDC a few seconds to ensure the SQL DB is updated
    Start-Sleep -Seconds 5
}

<#
.SYNOPSIS
Main reboot logic

.DESCRIPTION
This function runs through the logic of attempting to drain the servers of user sessions and rebooting them
The action of attempting to "Drain" a server has three steps:
 1. Putting the machine in Maintenance Mode
 2. Sending a Notification to users (controlled by teh script parameters)
 3. Waiting for a specific amount of time (firstPhaseTimeout paramter value) or until all users have logged off (whichever comes first)
If the server has not drained in the specified amount of time, it will be rebooted regardless of how many user sessions are still active in that server

.PARAMETER firstPhaseTimeout
Minutes to wait for servers to drain and reboot during the first reboot loop

.PARAMETER sessioncheckInterval
Minutes to wait between each check to see which servers have been drained and are ready for reboot

.PARAMETER registrationWaitMinutes
Minutes to wait for servers to Register after sending the reboot command

.PARAMETER countActiveSessionsOnly
Whether to consider Active sessions and ignore Disconnected sessions

.PARAMETER notifyUsers
Whether to send a message to each user with an Active session to notify them of the reboot

.PARAMETER secondPhaseTimeout
Minutes to wait for servers to reboot and register during the second reboot loop

.PARAMETER serverList
Array with VDA Objects identified with the Reboot Tag
#>
function DrainAndRebootServers {
    param (
        [Parameter(Mandatory = $true)] [int] $firstPhaseTimeout,
        [Parameter(Mandatory = $true)] [int] $sessioncheckInterval,
        [Parameter(Mandatory = $true)] [int] $registrationWaitMinutes,
        [Parameter(Mandatory = $true)] [bool] $countActiveSessionsOnly,
        [Parameter(Mandatory = $true)] [bool] $notifyUsers,
        [Parameter(Mandatory = $true)] [int] $secondPhaseTimeout,
        [Parameter(Mandatory = $true)] $serverList
    )

    # Extract only the properties we need for easier consumption in the rest of the function
    $vdaMachines = [System.Collections.SortedList]@{}
    foreach($server in $serverList) {
        $vdaMachines[$server.MachineName] = [VdaInfo]@{
            MachineName = $server.MachineName;
            SessionCount = -1;  ## Initialize to less than zero to force checking the session count on the very first iteration
            InMaintenanceMode = $server.InMaintenanceMode;
            Rebooted = $false;
            ReadyForUsers = $false
        }
    }

    # Even though the Wait Interval is passed as minutes, we will convert it to seconds for more precision inside the loop
    $checkIntervalSeconds = ($sessioncheckInterval * 60)
    $timeoutInSeconds = ($firstPhaseTimeout * 60)
    
    ##### Main loop to handle draining servers #####
    $iteration = 1
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $timeoutInSeconds) {
        LogInfo "First phase of reboot process. Loop Iteration #$iteration"

        # Put all VDAs in Maintenance Mode, for those that are not in MM already
        # Also save the MM status to memory to avoid hammering the DDC with constant calls during every check
        BulkChangeMaintenanceMode -vdaMachines $vdaMachines -newMaintenanceMode $true -forceChange $false

        # Notify users that the server will be rebooted
        if($notifyUsers) {
            NotifyUsers $vdaMachines
            $notifyUsers = $false # Notification only needs to be done once
        }

        # Record the Session count for each VDA at this point in time
        # Do this only for VDAs with more than 0 sessions (or -1 for initial run)
        UpdateSessionCounts $vdaMachines $countActiveSessionsOnly

        # Attempt to Reboot any machines that do not have sessions and have not been rebooted
        RebootMachinesAsNeeded $vdaMachines

        # Wait n minutes before the next step to give time for the reboots and the Registration process
        LogInfo "Pausing for $registrationWaitMinutes minutes to wait for machines to Register" 1
        Start-Sleep -Seconds ($registrationWaitMinutes * 60)

        # Check for any rebooted machines that are Registered, then take them out of Maintenance Mode and set them to Ready
        MarkCompletedMachines $vdaMachines

        # Check if all machines are ready
        if(AllMachinesReady $vdaMachines) {
            LogInfo "All Machines were rebooted and are ready for users during Phase one. Phase two will NOT be executed"
            # If we get here then we exit the function, which will exit the script completely
            return
        }

        # If the time left for the process is less than the loop interval, adjust it accordingly
        # For example if we have 3 minutes left from the original 60, it doesn't make sense to wait 5 minutes before the next check
        $elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds)
        $timeLeft = $timeoutInSeconds - $elapsedSeconds
        if($timeLeft -le $checkIntervalSeconds) {
            $checkIntervalSeconds = $timeLeft - 1 # Subtract one to make sure the while loop executes at least one more time
            if($checkIntervalSeconds -le 0) {
                $checkIntervalSeconds = 1
            }
            LogInfo "Waiting only $checkIntervalSeconds seconds because the time left for First phase ($timeLeft seconds) was less than Session Check Interval ($sessioncheckInterval minutes)"
        } else {
            LogInfo "Waiting $sessioncheckInterval minutes before next loop iteration"
        }

        Start-Sleep -Seconds $checkIntervalSeconds
        LogInfo "Total time elapsed after iteration #$iteration : $elapsedSeconds seconds -- Time left: $timeLeft seconds`n"
        $iteration++
    }
    ##### End loop for draining servers #####

    # If we get here, it means we reached the FirstPhaseTimeout threshold and some machines did not complete the reboot process
    # We will now attempt to reboot any leftover machines, that were not processed in the first reboot loop, and get them ready

    $totalRebootedMachines = ($vdaMachines.GetEnumerator() | Where-Object {$_.Value.Rebooted}).Count
    LogWarning "First phase rebooted $totalRebootedMachines machines in the allotted $FirstPhaseTimeout minutes. Proceeding with Second Phase to reboot the rest of the machines`n"

    # Even though the Wait Interval is passed as minutes, we will convert it to seconds for more precision inside the loop
    $timeoutInSeconds = ($secondPhaseTimeout * 60)

    ##### Loop for rebooting servers #####
    $timer.Restart()
    $iteration = 1
    while ($timer.Elapsed.TotalSeconds -lt $timeoutInSeconds) {
        LogInfo "Second phase of reboot process. Loop Iteration #$iteration"
        $iteration++

        # Attempt to Reboot machines at the start of every iteration. If a reboot fails then we can try it again
        LogInfo "Rebooting any machines that were not rebooted during the first phase" 1
        foreach($vdaMachine in $vdaMachines.GetEnumerator()) {
            if(!$vdaMachine.Value.ReadyForUsers -and !$vdaMachine.Value.Rebooted) {
                if(RebootMachine $vdaMachine.Key) {
                    $vdaMachines[$vdaMachine.Key].Rebooted = $true
                }
            }
        }

        # Wait n minutes before the next step to give time for the reboots and the Registration process to start
        Start-Sleep -Seconds ($registrationWaitMinutes * 60)

        # Check for any rebooted machines that are Registered and take them out of Maintenance Mode
        MarkCompletedMachines $vdaMachines

        # Check if all machines are ready and, if so, break from the loop
        if(AllMachinesReady $vdaMachines) {
            LogInfo "All Machines were rebooted and are ready for users." 1
            return
        }

        LogInfo "Total time elapsed after iteration #$iteration : $([Math]::Round($timer.Elapsed.TotalSeconds)) seconds -- Time left: $($timeoutInSeconds - [Math]::Round($timer.Elapsed.TotalSeconds)) seconds`n"
    }
    ##### End Loop for rebooting servers #####

    #########################################
    ##### We should never ever get here #####
    #########################################
    # What to do with all the machines that for some reason failed to be rebooted?
    # For now we will get them out of Maintenance Mode, regardless of their Registration state, because their Registration state is unknown at this point
    LogCritical "After first and second reboot phases, there are still some machines that either did not reboot or did not register. Maintenance Mode will be turned off on them, but they should be checked."
    BulkChangeMaintenanceMode -vdaMachines $vdaMachines -newMaintenanceMode $false -forceChange $true
}
#endregion


########################
## Main process Start ##
########################

#region - Global Variables shared by the functions
$Global:ddcAddress = $ControllerAddress
$Global:debugLogging = $Debugging
$Global:logFile = $LogFile
$Global:consoleLogging = $LogToConsole
#endregion

if($RebootTag -eq "") {
    $RebootTag = CreateRebootTag
}

InitializeLog

# First of all, make sure no Reboot Script is running for this same Tag
if(-not (LockRebootSchedule $RebootTag)) {
    # An instance of the script is already running with the same Tag. ABORT...
    LogCritical "An instance of the script is already running with Tag ""$RebootTag"". ABORTING..."
    return
}

LogParameters $PSBoundParameters $RebootTag

$scriptTimer = [System.Diagnostics.Stopwatch]::StartNew()
$processStartTime = Get-Date

# Get a list of VDA Objects that match the Reboot Tag
try {
    $servers = Get-BrokerMachine -AdminAddress $Global:ddcAddress -MaxRecordCount 1500  -ErrorAction Stop | Where-Object {($_.Tags.ToUpper() -contains $RebootTag.ToUpper())}
} catch {
    LogCritical "Could not enumerate servers from Delivery Controller $($Global:ddcAddress) `n $_.Exception.Message"
}

if($null -ne $servers -and $servers.count -gt 0) {
    LogInfo "A total of $($servers.count) servers were found with tag ""$RebootTag"""
    DrainAndRebootServers `
        -firstPhaseTimeout $FirstPhaseTimeout `
        -sessioncheckInterval $SessionCheckInterval `
        -registrationWaitMinutes $RegistrationWaitMinutes `
        -countActiveSessionsOnly $CountActiveSessionsOnly `
        -notifyUsers $NotifyUsers `
        -secondPhaseTimeout $SecondPhaseTimeout `
        -serverList $servers
} else {
    LogWarning "No servers were found with tag ""$RebootTag"""
}

UnlockRebootSchedule $RebootTag
FinishLog $processStartTime $scriptTimer.Elapsed
