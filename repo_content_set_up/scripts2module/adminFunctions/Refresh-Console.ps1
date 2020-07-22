function Refresh-Console {
    <#
    .SYNOPSIS
    Use this function for invoking update of central repository data on MGM server, DFS repository share and on given computer.
    In case you run this function to synchronize new content to localhost, new content will be automatically imported to this console.
    For best user experience, by default just changed files are processed and synchronized. Caveat of this approach is, that NTFS permissions won't be set/reset if change in Variables module, customConfig.ps1 or modulesConfig.ps1 isn't detected (in such case use force switch).

    .DESCRIPTION
    Use this function for invoking update of central repository data on MGM server, DFS repository share and on given computer.
    In case you run this function to synchronize new content to localhost, new content will be automatically imported to this console.
    For best user experience, by default just changed files are processed and synchronized. Caveat of this approach is, that NTFS permissions won't be set/reset if change in Variables module, customConfig.ps1 or modulesConfig.ps1 isn't detected (in such case use force switch).

    Default behaviour:
    - run Repo_sync scheduled task on MGM server (i.e. repo_sync.ps1)
        - pull new data to MGM server repository from cloud repository
        - process ALL pulled data and copy them to DFS repository share
    - run PS_env_set_up scheduled task on given computer (i.e. PS_env_set_up.ps1)
        - download data from DFS repository to the client
        - if running locally, import data to this running Powershell console (not applicable if omitConsoleRefresh is used!)
            - update of $env:PATH included

    Customized behaviour:
    Using parameters as synchronize, moduleToSync, force etc you can limit, what data will be synced.
    This of course make the client data update much faster.
    New temporary scheduled task will be created to apply custom parameters.

    .PARAMETER justLocalRefresh
    Skip update of MGM and DFS repository i.e. just download actual content from DFS repository.

    .PARAMETER computerName
    Remote computer where you want to sync new data.
    Powershell consoles won't be updated, so users will have to close and reopen them!

    .PARAMETER force
    Switch for forcing full DFS repository synchronization.
    Otherwise just changes in yet unprocessed commits will be processed and synchronized.

    .PARAMETER omitConsoleRefresh
    Omit "refresh" of Powershell console where this command runs.
    So new data will be downloaded to client, but console state won't change.

    .PARAMETER synchronize
    What kind of sync actions should be taken.

    Possible values are:
    - module
        synchronization of Modules will occur
    - custom
        synchronization of Custom section will occur
    - profile
        synchronization of Powershell Profile will occur

    Default is module, custom and profile i.e. full synchronization.

    .PARAMETER moduleToSync
    Can be used to limit synchronization of Powershell modules, so just subset of them will be synced.
    Accept list of modules names.

    .PARAMETER customToSync
    Can be used to limit synchronization of Custom folders, so just subset of them will be synced.
    Accept list of Custom folders names.

    .PARAMETER omitDeletion
    Switch to omit deletion of unused modules, scheduled tasks, powershell profile or custom folders.
    Use when you want sync cycle to be as fast as possible.

    .PARAMETER PS_env_set_up
    Network path to PS_env_set_up.ps1 script.

    Default is (Join-Path $_repoShare "PS_env_set_up.ps1").

    .PARAMETER repoSyncServer
    Name of MGM server. i.e. server which synchronizes pulled GIT repository data to central repository share location (DFS).

    .PARAMETER repo_Sync
    Local path to repo_sync.ps1 script (stored on $repoSyncServer).

    Default is "C:\Windows\Scripts\Repo_Sync\Repo_Sync.ps1".

    .EXAMPLE
    Refresh-Console

    Update MGM server repository (just changed data), than DFS repository and in the end, download data from DFS to this PC and import them to this console.

    .EXAMPLE
    Refresh-Console -force

    Update MGM server repository (even unchanged data will be processed), than DFS repository and in the end, download data from DFS to this PC and import them to this console.

    .EXAMPLE
    ref -computerName APP-15

    Update MGM server repository (just changed data), than DFS repository and in the end, download data from DFS to APP-15 client.

    .EXAMPLE
    Refresh-Console -computerName APP-15 -justLocalRefresh

    Skip update of MGM server repository and DFS repository and just download data from DFS to APP-15 client.

    .EXAMPLE
    Refresh-Console -synchronize module -moduleToSync Scripts -omitDeletion -omitConsoleRefresh

    Update MGM server repository (just changed data), than DFS repository and in the end download just Powershell module 'Scripts' from DFS to this client.
    Modules, profile, custom foldere or scheduled tasks that shouldn't be here anymore won't be deleted. New data won't be imported to this console either.

    .EXAMPLE
    Refresh-Console -moduleToSync Scripts

    Update MGM server repository (just changed data), than DFS repository and in the end download data from DFS locally. According to synchronization of modules, just Powershell module 'Scripts' will be downloaded. New data will be imported to this console.

    .EXAMPLE
    Refresh-Console -synchronize module, custom -moduleToSync Scripts -customToSync FileServices -omitDeletion

    Update MGM server repository (just changed data), than DFS repository and in the end download just Powershell module 'Scripts' and Custom folder 'FileServices' from DFS to this client.
    Modules, profile, custom foldere or scheduled tasks that shouldn't be here anymore won't be deleted. New data will be imported to this console.
    #>

    [cmdletbinding()]
    [Alias("ref")]
    param (
        [switch] $justLocalRefresh
        ,
        [string] $computerName
        ,
        [switch] $force
        ,
        [switch] $omitConsoleRefresh
        ,
        [ValidateSet('module', 'custom', 'profile')]
        [string[]] $synchronize = @('module', 'custom', 'profile')
        ,
        [string[]] $moduleToSync
        ,
        [string[]] $customToSync
        ,
        [switch] $omitDeletion
        ,
        [ValidateScript( {
                If (Test-Path -Path $_ -PathType Leaf) {
                    $true
                } else {
                    Throw "$_ doesn't exist"
                }
            })]
        [ValidateNotNullOrEmpty()]
        [string] $PS_env_set_up = (Join-Path $_repoShare "PS_env_set_up.ps1")
        ,
        [ValidateNotNullOrEmpty()]
        [string] $repoSyncServer = $_repoSyncServer
        ,
        [ValidateNotNullOrEmpty()]
        [string] $repo_Sync = "C:\Windows\Scripts\Repo_Sync\Repo_Sync.ps1"
    )

    if ($computerName -and $omitConsoleRefresh) {
        Write-Warning "Parameter omitConsoleRefresh will be ignored. On remote machine refresh of console never being done."
    }

    # scriptblock for starting the scheduled task (original or custom one)
    $startScriptBlock = {
        $waitTime = 60

        Start-ScheduledTask $taskName -ErrorAction Stop

        $started = Get-Date
        while (((Get-ScheduledTask $taskName -ErrorAction silentlyContinue).state -ne "Ready") -and $started.AddSeconds($waitTime) -ge (Get-Date)) {
            Start-Sleep -Milliseconds 200
        }

        if ((Get-ScheduledTask $taskName -ErrorAction silentlyContinue).state -ne 'Ready') {
            Write-Warning "Task is still running"
            return
        }
        if (($lastTaskResult = (Get-ScheduledTaskInfo $taskName).lastTaskResult) -ne 0) {
            Write-Error "Task failed with error $lastTaskResult"
        }
    }


    #
    #region update MGM hence DFS repository data
    if (!$justLocalRefresh) {
        #region create ScriptBlock defining sched. task to run
        if ($force) {
            # synchronize everything i.e. use default scheduled task
            $prepareScriptBlockTxt = @'
            $taskName = "Repo_sync"
'@
            $endScriptBlockTxt = ''
        } else {
            # synchronize just changed content to DFS share i.e. create custom scheduled task, that will run without force switch
            Write-Verbose "Custom scheduled task for MGM sync, will be created"

            $params = ""
            if ($omitDeletion) {
                $params += " -omitDeletion"
            }

            # scriptblock for creation of custom scheduled task
            $prepareScriptBlockTxt = @'
        $taskName = "Repo_sync_custom" + (Get-Random)
        $Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-ExecutionPolicy ByPass -NoProfile -Command `"&{`"$repo_Sync`"$params}`""
        $Task = New-ScheduledTask -Action $Action -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries)
        $null = $Task | Register-ScheduledTask -TaskName $taskName -User "SYSTEM" -Force
'@
            $prepareScriptBlockTxt = $prepareScriptBlockTxt -replace '\$params', $params -replace '\$repo_Sync', $repo_Sync

            $endScriptBlockTxt = 'Unregister-ScheduledTask -TaskName $taskName -Confirm:$false'
        }

        $startScriptBlockTxt = "Write-Host 'Waiting for end of DFS repository data sync'" + $startScriptBlock.ToString()

        # merge scriptblocks together
        $scriptBlock = [ScriptBlock]::Create($prepareScriptBlockTxt + "`n" + $startScriptBlockTxt + "`n" + $endScriptBlockTxt)
        Write-Verbose ("`n" + $scriptBlock.ToString())
        #endregion create ScriptBlock defining sched. task to run

        #region run sched. task i.e. repo_sync.ps1
        try {
            Invoke-Command -ComputerName $repoSyncServer -ScriptBlock $scriptBlock -ErrorAction stop
        } catch {
            if ($_.exception.gettype().fullname -match "System.Management.Automation.Remoting.PSRemotingTransportException" -and $_.exception.message -match "access is denied") {
                throw "Access denied when connecting to $repoSyncServer"
            } else {
                Write-Error $_
                throw "`nCheck the log 'C:\Windows\Temp\Repo_sync.ps1.log' on $repoSyncServer for details."
            }
        }
        #endregion run sched. task i.e.  repo_sync.ps1
    } else {
        Write-Warning "You skipped sync of DFS repository data"
    }
    #endregion update MGM hence DFS repository data


    #
    #region update client data
    if ($synchronize) {
        $userName = $env:USERNAME
        $architecture = $env:PROCESSOR_ARCHITECTURE
        $psModulePath = $env:PSModulePath

        #region create ScriptBlock defining sched. task to run
        if ($synchronize.count -ne 3 -or $moduleToSync -or $customToSync -or $omitDeletion) {
            # synchronizatin of data is customized, custom sched. task will be created
            Write-Verbose "Custom scheduled task for client sync, will be created"

            $params = ""

            $params += (" -synchronize " + ($synchronize -join ", "))

            if ($moduleToSync) {
                $params += (" -moduleToSync " + (($moduleToSync | % { "'$_'" } ) -join ","))
            }
            if ($customToSync) {
                $params += (" -customToSync " + (($customToSync | % { "'$_'" } ) -join ","))
            }
            if ($omitDeletion) {
                $params += " -omitDeletion"
            }

            # scriptblock for creation of custom scheduled task
            $prepareScriptBlockTxt = @'
        $taskName = "PS_env_set_up_custom" + (Get-Random)
        $Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-ExecutionPolicy ByPass -NoProfile -Command `"&{`"$PS_env_set_up`"$params}`""
        $Task = New-ScheduledTask -Action $Action -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries)
        $null = $Task | Register-ScheduledTask -TaskName $taskName -User "SYSTEM" -Force
'@
            $prepareScriptBlockTxt = $prepareScriptBlockTxt -replace '\$params', $params -replace '\$PS_env_set_up', $PS_env_set_up
            $endScriptBlockTxt = 'Unregister-ScheduledTask -TaskName $taskName -Confirm:$false'
        } else {
            # no customization of task needed, use the default one
            $prepareScriptBlockTxt = '$taskName = "PS_env_set_up"'
            $endScriptBlockTxt = ''
        }

        $startScriptBlockTxt = 'Write-Host "Waiting for end of local data sync on $env:COMPUTERNAME"' + $startScriptBlock.ToString()

        # merge scriptblocks together
        $scriptBlock = [ScriptBlock]::Create($prepareScriptBlockTxt + "`n" + $startScriptBlockTxt + "`n" + $endScriptBlockTxt)
        Write-Verbose ("`n" + $scriptBlock.ToString())
        #endregion create ScriptBlock defining sched. task to run

        #region run PS_env_set_up.ps1
        if (!$computerName) {
            # updating localhost
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptBlock)
            $encodedCommand = [Convert]::ToBase64String($bytes)
            $pParams = @{
                filePath     = "powershell.exe"
                ArgumentList = "-noprofile -encodedCommand $encodedCommand"
                Wait         = $true
                ErrorAction  = "Stop"
            }

            if (-not (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
                # non-admin console ie I need to invoke new admin console to have enough permission to start PS_env_set_up sched. task
                $pParams.Verb = "runas"
                $pParams.Wait = $true
            } else {
                # admin console ie I have enough permission to start PS_env_set_up sched. task here
                $pParams.NoNewWindow = $true
            }

            try {
                Start-Process @pParams
            } catch {
                if ($_ -match "The operation was canceled by the user") {
                    Write-Warning "You have skipped sync of local client data"
                } else {
                    Write-Error $_
                    Write-Error "`nCheck the log 'C:\Windows\Temp\PS_env_set_up.ps1.log' for details."
                }
            }


            #
            #region refresh console
            if (!$omitConsoleRefresh) {
                Write-Warning "To apply changes made in Powershell Profile you will have to open new PS console"

                function Get-EnvironmentVariableNames([System.EnvironmentVariableTarget] $Scope) {
                    switch ($Scope) {
                        'User' { Get-Item 'HKCU:\Environment' | Select-Object -ExpandProperty Property }
                        'Machine' { Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' | Select-Object -ExpandProperty Property }
                        'Process' { Get-ChildItem Env:\ | Select-Object -ExpandProperty Key }
                        default { throw "Unsupported environment scope: $Scope" }
                    }
                }

                function Get-EnvironmentVariable([string] $Name, [System.EnvironmentVariableTarget] $Scope) {
                    [Environment]::GetEnvironmentVariable($Name, $Scope)
                }

                # update registry entry, that store commit identifier which was actual when this console started/was updated
                # to be able later compare it with actual system commit state and show number of commits behind in console Title (more about this in profile.ps1)
                $commitHistoryPath = "$env:SystemRoot\Scripts\commitHistory"
                if ($consoleCommit = Get-Content $commitHistoryPath -First 1 -ErrorAction SilentlyContinue) {
                    $null = New-ItemProperty HKCU:\Software -Name "consoleCommit_$PID" -PropertyType string -Value $consoleCommit -Force
                }

                # update of system environment variables (PATH included)
                # inspired by https://github.com/chocolatey/choco/blob/stable/src/chocolatey.resources/helpers/functions/Update-SessionEnvironment.ps1

                # User scope is last on purpose, to overwrite other scopes in case of conflict
                'Process', 'Machine', 'User' | % {
                    $scope = $_
                    Get-EnvironmentVariableNames -Scope $scope | % {
                        Write-Verbose "Setting variable $_"
                        Set-Item "Env:$($_)" -Value (Get-EnvironmentVariable -Scope $scope -Name $_)
                    }
                }
                # save content of system and user PATH into console variable Env:PATH
                Write-Verbose "`nSetting variable PATH"
                $paths = 'Machine', 'User' | % {
                    (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
                } | Select-Object -Unique
                $Env:PATH = $paths -join ';' -replace ";;", ";"

                # because some variables values are replaced by incorrect values by this update process, replace them by correct one
                if ($userName) { $env:USERNAME = $userName }
                if ($architecture) { $env:PROCESSOR_ARCHITECTURE = $architecture }
                $env:PSModulePath = $psModulePath

                # reimport of currently loaded PS modules
                # just modules that can be updated by this CI/CD solution, so just System modules
                $importedModule = Get-Module | where { $_.name -notmatch "^tmp_" -and $_.path -like "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\*" } | select -exp name
                if ($moduleToSync) {
                    $importedModule = $importedModule | ? { $_ -in $moduleToSync }
                }
                if ($importedModule) {
                    Write-Verbose "`nRemove loaded modules"
                    $importedModule | Remove-Module -Force -Confirm:$false -WarningAction SilentlyContinue
                    Write-Verbose "`nReimport modules again: $($importedModule.name -join ', ')"
                    $importedModule | Import-Module -Force -Global -WarningAction SilentlyContinue
                }
            }
            #endregion refresh console
        } else {
            # update should be started on remote computer
            try {
                Invoke-Command -ComputerName $computerName -ScriptBlock $scriptBlock -ErrorAction stop
            } catch {
                if ($_ -match "The system cannot find the file specified") {
                    Write-Error "Unable to finish the sync on $env:COMPUTERNAME, because sched. task $taskName wasn't found.`nIs GPO PS_env_set_up linked to this computer?"
                } else {
                    Write-Error $_
                    Write-Error "`nCheck the log 'C:\Windows\Temp\PS_env_set_up.ps1.log' on $env:COMPUTERNAME for details."
                }
            }
        }
        #endregion run PS_env_set_up.ps1
    }
    #endregion update client data
}