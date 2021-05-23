#Requires -Version 5.1

<#
.SYNOPSIS
Installation script for PowerShell managing solution hosted at https://github.com/ztrhgf/Powershell_CICD_repository
Contains same steps as described at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md

.DESCRIPTION
Installation script for PowerShell managing solution hosted at https://github.com/ztrhgf/Powershell_CICD_repository
Contains same steps as described at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md

.PARAMETER noEnvModification
Switch to omit changes of your environment i.e. just customization of cloned folders content 'repo_content_set_up' will be made.

.PARAMETER iniFile
Path to text ini file that this script uses as storage for values the user entered during this scripts run.
So next time, they can be used to speed up whole installation process.

Default is "Powershell_CICD_repository.ini" in root of user profile, so it can't be replaced when user reset cloned repository etc.

.NOTES
Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

[CmdletBinding()]
param (
    [switch] $noEnvModification
    ,
    [string] $iniFile = (Join-Path $env:USERPROFILE "Powershell_CICD_repository.ini")
)

$Host.UI.RawUI.Windowtitle = "Installer of PowerShell CI/CD solution"

$transcript = Join-Path $env:USERPROFILE ((Split-Path $PSCommandPath -Leaf) + ".log")
Start-Transcript $transcript -Force

$ErrorActionPreference = "Stop"

# char that is between name of variable and its value in ini file
$divider = "="
# list of variables needed for installation, will be saved to iniFile 
$setupVariable = @{}
# name of GPO that will be used for connecting computers to this solution
$GPOname = 'PS_env_set_up'

# hardcoded PATHs for TEST installation
$repositoryShare = "\\$env:COMPUTERNAME\repositoryShare"
$repositoryShareLocPath = Join-Path $env:SystemDrive "repositoryShare"
$remoteRepository = Join-Path $env:SystemDrive "myCompanyRepository_remote"
$userRepository = Join-Path $env:SystemDrive "myCompanyRepository"


if ((Get-WmiObject -Class Win32_OperatingSystem).ProductType -in (2, 3)) {
    ++$isServer
}

#region helper functions
function _pressKeyToContinue {
    Write-Host "`nPress any key to continue" -NoNewline
    $null = [Console]::ReadKey('?')
}

function _continue {
    param ($text, [switch] $passthru)

    $t = "Continue? (Y|N)"
    if ($text) {
        $t = "$text. $t"
    }

    $choice = ""
    while ($choice -notmatch "^[Y|N]$") {
        $choice = Read-Host $t
    }
    if ($choice -eq "N") {
        if ($passthru) {
            return $choice
        }
        else {
            break
        }
    }

    if ($passthru) {
        return $choice
    }
}

function _skip {
    param ($text)

    $t = "Skip? (Y|N)"
    if ($text) {
        $t = "$text. $t"
    }
    $t = "`n$t"

    $choice = ""
    while ($choice -notmatch "^[Y|N]$") {
        $choice = Read-Host $t
    }
    if ($choice -eq "N") {
        return $false
    }
    else {
        return $true
    }
}

function _getComputerMembership {
    # Pull the gpresult for the current server
    $Lines = gpresult /s $env:COMPUTERNAME /v /SCOPE COMPUTER
    # Initialize arrays
    $cgroups = @()
    # Out equals false by default
    $Out = $False
    # Define start and end lines for the section we want
    $start = "The computer is a part of the following security groups"
    $end = "Resultant Set Of Policies for Computer"
    # Loop through the gpresult output looking for the computer security group section
    ForEach ($Line In $Lines) {
        If ($Line -match $start) { $Out = $True }
        If ($Out -eq $True) { $cgroups += $Line }
        If ($Line -match $end) { Break }
    }
    $cgroups | % { $_.trim() }
}

function _startProcess {
    [CmdletBinding()]
    param (
        [string] $filePath = ''
        ,
        [string] $argumentList = ''
        ,
        [string] $workingDirectory = (Get-Location)
        ,
        [switch] $dontWait
        ,
        # lot of git commands output verbose output to error stream
        [switch] $outputErr2Std
    )

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.WorkingDirectory = $workingDirectory
    $p.StartInfo.FileName = $filePath
    $p.StartInfo.Arguments = $argumentList
    [void]$p.Start()
    if (!$dontWait) {
        $p.WaitForExit()
    }
    $p.StandardOutput.ReadToEnd()
    if ($outputErr2Std) {
        $p.StandardError.ReadToEnd()
    }
    else {
        if ($err = $p.StandardError.ReadToEnd()) {
            Write-Error $err
        }
    }
}

function _setVariable {
    # function defines variable and fills it with value find in ini file or entered by user
    param ([string] $variable, [string] $readHost, [switch] $optional, [switch] $passThru)

    $value = $setupVariable.GetEnumerator() | ? { $_.name -eq $variable -and $_.value } | select -exp value
    if (!$value) {
        if ($optional) {
            $value = Read-Host "    - (OPTIONAL) Enter $readHost"
        }
        else {
            while (!$value) {
                $value = Read-Host "    - Enter $readHost"
            }
        }
    }
    else {
        # Write-Host "   - variable '$variable' will be: $value" -ForegroundColor Gray
    }
    if ($value) {
        # replace whitespaces so as quotes
        $value = $value -replace "^\s*|\s*$" -replace "^[`"']*|[`"']*$"
        $setupVariable.$variable = $value
        New-Variable $variable $value -Scope script -Force -Confirm:$false
    }
    else {
        if (!$optional) {
            throw "Variable $variable is mandatory!"
        }
    }

    if ($passThru) {
        return $value
    }
}

function _saveInput {
    # call after each successfuly ended section, so just correct inputs will be stored
    if (Test-Path $iniFile -ea SilentlyContinue) {
        Remove-Item $iniFile -Force -Confirm:$false
    }
    $setupVariable.GetEnumerator() | % {
        if ($_.name -and $_.value) {
            $_.name + "=" + $_.value | Out-File $iniFile -Append -Encoding utf8
        }
    }
}

function _setPermissions {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $path
        ,
        $readUser
        ,
        $writeUser
        ,
        [switch] $resetACL
    )

    if (!(Test-Path $path)) {
        throw "Path isn't accessible"
    }

    $permissions = @()

    if (Test-Path $path -PathType Container) {
        # it is folder
        $acl = New-Object System.Security.AccessControl.DirectorySecurity

        if ($resetACL) {
            # reset ACL, i.e. remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        }
        else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            if ($readUser) {
                $readUser | ForEach-Object {
                    $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
            }
            if ($writeUser) {
                $writeUser | ForEach-Object {
                    $permissions += @(, ("$_", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
            }
        }
    }
    else {
        # it is file

        $acl = New-Object System.Security.AccessControl.FileSecurity
        if ($resetACL) {
            # reset ACL, ie remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        }
        else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            if ($readUser) {
                $readUser | ForEach-Object {
                    $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
                }
            }

            if ($writeUser) {
                $writeUser | ForEach-Object {
                    $permissions += @(, ("$_", "FullControl", 'Allow'))
                }
            }
        }
    }

    $permissions | ForEach-Object {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule $_
        $acl.AddAccessRule($ace)
    }

    try {
        # Set-Acl cannot be used because of bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    }
    catch {
        throw "There was an error when setting NTFS rights: $_"
    }
}

function _copyFolder {
    [cmdletbinding()]
    Param (
        [string] $source
        ,
        [string] $destination
        ,
        [string] $excludeFolder = ""
        ,
        [switch] $mirror
    )

    Begin {
        [Void][System.IO.Directory]::CreateDirectory($destination)
    }

    Process {
        if ($mirror) {
            $result = Robocopy.exe "$source" "$destination" /MIR /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
        }
        else {
            $result = Robocopy.exe "$source" "$destination" /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
        }

        $copied = 0
        $failures = 0
        $duration = ""
        $deleted = @()
        $errMsg = @()

        $result | ForEach-Object {
            if ($_ -match "\s+Dirs\s+:") {
                $lineAsArray = (($_.Split(':')[1]).trim()) -split '\s+'
                $copied += $lineAsArray[1]
                $failures += $lineAsArray[4]
            }
            if ($_ -match "\s+Files\s+:") {
                $lineAsArray = ($_.Split(':')[1]).trim() -split '\s+'
                $copied += $lineAsArray[1]
                $failures += $lineAsArray[4]
            }
            if ($_ -match "\s+Times\s+:") {
                $lineAsArray = ($_.Split(':', 2)[1]).trim() -split '\s+'
                $duration = $lineAsArray[0]
            }
            if ($_ -match "\*EXTRA \w+") {
                $deleted += @($_ | ForEach-Object { ($_ -split "\s+")[-1] })
            }
            if ($_ -match "^ERROR: ") {
                $errMsg += ($_ -replace "^ERROR:\s+")
            }
            # captures errors like: 2020/04/27 09:01:27 ERROR 2 (0x00000002) Accessing Source Directory C:\temp
            if ($match = ([regex]"^[0-9 /]+ [0-9:]+ ERROR \d+ \([0-9x]+\) (.+)").Match($_).captures.groups) {
                $errMsg += $match[1].value
            }
        }

        return [PSCustomObject]@{
            'Copied'   = $copied
            'Failures' = $failures
            'Duration' = $duration
            'Deleted'  = $deleted
            'ErrMsg'   = $errMsg
        }
    }
}

function _installGIT {
    $installedGITVersion = ( (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*) + (Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*) | ? { $_.DisplayName -and $_.Displayname.Contains('Git version') }) | select -exp DisplayVersion

    if (!$installedGITVersion -or $installedGITVersion -as [version] -lt "2.27.0") {
        # get latest download url for git-for-windows 64-bit exe
        $url = "https://api.github.com/repos/git-for-windows/git/releases/latest"
        if ($asset = Invoke-RestMethod -Method Get -Uri $url | % { $_.assets } | ? { $_.name -like "*64-bit.exe" }) {
            "      - downloading"
            $installer = "$env:temp\$($asset.name)"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest $asset.browser_download_url -OutFile $installer 
            $ProgressPreference = 'Continue'
            
            "      - installing"
            $install_args = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
            Start-Process -FilePath $installer -ArgumentList $install_args -Wait

            Start-Sleep 3

            # update PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
     
        }
        else {
            Write-Warning "Skipped!`nURL $url isn't accessible, install GIT manually"

            _continue
        }
    }
    else {
        "      - already installed"
    }
}

function _installGITCredManager {
    $ErrorActionPreference = "Stop"
    $url = "https://github.com/Microsoft/Git-Credential-Manager-for-Windows/releases/latest"
    $asset = Invoke-WebRequest $url -UseBasicParsing
    try {
        $durl = (($asset.RawContent -split "`n" | ? { $_ -match '<a href="/.+\.exe"' }) -split '"')[1]
    }
    catch {}
    if ($durl) {
        $url = "github.com" + $durl
        $installer = "$env:temp\gitcredmanager.exe"
        "      - downloading"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest $url -OutFile $installer 
        $ProgressPreference = 'Continue'
        "      - installing"
        $install_args = "/VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
        Start-Process -FilePath $installer -ArgumentList $install_args -Wait
    }
    else {
        Write-Warning "Skipped!`nURL $url isn't accessible, install GIT Credential Manager for Windows manually"
    
        _continue
    }
}

function _installVSC {
    $codeCmdPath = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
    if ((Test-Path "$env:ProgramFiles\Microsoft VS Code\Code.exe") -or (Test-Path "$env:USERPROFILE\AppData\Local\Programs\Microsoft VS Code\Code.exe")) {
        "      - already installed"
        return
    }
    $vscInstaller = "$env:TEMP\vscode-stable.exe"
    Remove-Item -Force $vscInstaller -ErrorAction SilentlyContinue
    "      - downloading"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest "https://update.code.visualstudio.com/latest/win32-x64/stable" -OutFile $vscInstaller 
    $ProgressPreference = 'Continue'
    "      - installing"
    $loadInf = '@
[Setup]
Lang=english
Dir=C:\Program Files\Microsoft VS Code
Group=Visual Studio Code
NoIcons=0
Tasks=desktopicon,addcontextmenufiles,addcontextmenufolders,addtopath
@'
    $infPath = Join-Path $env:TEMP load.inf
    $loadInf | Out-File $infPath
    Start-Process $vscInstaller -ArgumentList "/VERYSILENT /LOADINF=${infPath} /mergetasks=!runcode" -Wait
}

function _createSchedTask {
    param ($xmlDefinition, $taskName)
    $result = schtasks /CREATE /XML "$xmlDefinition" /TN "$taskName" /F

    if (!$?) {
        throw "Unable to create scheduled task $taskName"
    }
}

function _startSchedTask {
    param ($taskName)
    $result = schtasks /RUN /I /TN "$taskName"

    if (!$?) {
        throw "Task $taskName finished with error. Check '$env:SystemRoot\temp\repo_sync.ps1.log'"
    }
}

function _exportCred {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $credential
        ,
        [string] $xmlPath = "C:\temp\login.xml"
        ,
        [Parameter(Mandatory = $true)]
        [string] $runAs
    )

    begin {
        # transform relative path to absolute
        try {
            $null = Split-Path $xmlPath -Qualifier -ea Stop
        }
        catch {
            $xmlPath = Join-Path (Get-Location) $xmlPath
        }

        # remove existing xml
        Remove-Item $xmlPath -ea SilentlyContinue -Force

        # create destination folder
        [Void][System.IO.Directory]::CreateDirectory((Split-Path $xmlPath -Parent))
    }

    process {
        $login = $credential.UserName
        $pswd = $credential.GetNetworkCredential().password

        $command = @"
            # just in case auto-load of modules would be broken
            import-module `$env:windir\System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security -ea Stop
            `$pswd = ConvertTo-SecureString `'$pswd`' -AsPlainText -Force
            `$credential = New-Object System.Management.Automation.PSCredential $login, `$pswd
            Export-Clixml -inputObject `$credential -Path $xmlPath -Encoding UTF8 -Force -ea Stop
"@

        # encode as base64
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
        $encodedString = [Convert]::ToBase64String($bytes)
        #TODO idealne pomoci schtasks aby bylo univerzalnejsi
        $A = New-ScheduledTaskAction -Argument "-executionpolicy bypass -noprofile -encodedcommand $encodedString" -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        if ($runAs -match "\$") {
            # under gMSA account
            $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType Password
        }
        else {
            # under system account
            $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType ServiceAccount
        }
        $S = New-ScheduledTaskSettingsSet
        $taskName = "cred_export"
        try {
            $null = New-ScheduledTask -Action $A -Principal $P -Settings $S -ea Stop | Register-ScheduledTask -Force -TaskName $taskName -ea Stop
        }
        catch {
            if ($_ -match "No mapping between account names and security IDs was done") {
                throw "Account $runAs doesn't exist or cannot be used on $env:COMPUTERNAME"
            }
            else {
                throw "Unable to create scheduled task for exporting credentials.`nError was:`n$_"
            }
        }

        Start-Sleep -Seconds 1
        Start-ScheduledTask $taskName

        Start-Sleep -Seconds 5
        $result = (Get-ScheduledTaskInfo $taskName).LastTaskResult
        try {
            Unregister-ScheduledTask $taskName -Confirm:$false -ea Stop
        }
        catch {
            throw "Unable to remove scheduled task $taskName. Remove it manually, it contains the credentials!"
        }

        if ($result -ne 0) {
            throw "Export of the credentials end with error"
        }

        if ((Get-Item $xmlPath).Length -lt 500) {
            # sometimes sched. task doesn't end with error, but xml contained gibberish
            throw "Exported credentials are not valid"
        }
    }
}
#endregion helper functions

# store function definitions so I can recreate them in scriptblock
$allFunctionDefs = "function _continue { ${function:_continue} };function _pressKeyToContinue { ${function:_pressKeyToContinue} }; function _skip { ${function:_skip} }; function _installGIT { ${function:_installGIT} }; function _installGITCredManager { ${function:_installGITCredManager} }; function _createSchedTask { ${function:_createSchedTask} }; function _exportCred { ${function:_exportCred} }; function _startSchedTask { ${function:_startSchedTask} }; function _setPermissions { ${function:_setPermissions} }; function _getComputerMembership { ${function:_getComputerMembership} }; function _startProcess { ${function:_startProcess} }"

#region initial
if (!$noEnvModification) {
    Clear-Host
    @"
####################################
#   INSTALL OPTIONS
####################################

1) TEST installation
    - suitable for fast and safe test of the features, this solution offers
        - run this installer on test computer (preferably VM (Windows Sandbox, Virtualbox, Hyper-V, ...))
        - no prerequisities needed like 
            - Active Directory
            - cloud repository
    - goal was, to have this as simple as possible, so installer automatically:
        - install VSC, GIT
        - creates GIT repository in $remoteRepository
            - and clone it to $userRepository
        - creates folder $repositoryShareLocPath and share it as $repositoryShare
        - creates security group repo_reader, repo_writer
        - creates required scheduled tasks
        - creates and set global PowerShell profile
        - start VSC editor with your new repository, so you can start your testing immediately :)
        
2) Standard installation (Active Directory needed)
    - this script will set up your own GIT repository and your environment by:
        - creating repo_reader, repo_writer AD groups
        - create shared folder for serving repository data to clients
        - customize generic data from repo_content_set_up folder to match your environment
        - copy customized data to your repository
        - set up your repository
            - activate custom git hooks
            - set git user name and email
        - commit & push new content of your repository
        - set up MGM server
            - copy there Repo_sync folder
            - create Repo_sync scheduled task
            - export repo_puller credentials
        - copy exported credentials from MGM to local repository, commmit and push it
        - create GPO '$GPOname' that will be used for connecting clients to this solution
            - linking GPO has to be done manually
    - NOTE: every step has to be explicitly confirmed

3) Update of existing installation
    - NO MODIFICATION OF YOUR ENVIRONMENT WILL BE MADE
        - just customization of generic data in repo_content_set_up folder to match your environment
            - merging with your own repository etc has to be done manually
"@

    $choice = ""
    while ($choice -notmatch "^[1|2|3]$") {
        $choice = Read-Host "Choose install option (1|2|3)"
    }
    if ($choice -eq 1) {
        $testInstallation = 1

        if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            # not running "as Administrator" - so relaunch as administrator
        
            # get command line arguments and reuse them
            $arguments = $myInvocation.line -replace [regex]::Escape($myInvocation.InvocationName), ""
        
            Start-Process powershell.exe -Verb RunAs -ArgumentList ('-noprofile -file "{0}" {1}' -f ($myinvocation.MyCommand.Definition), $arguments) # -noexit nebo -WindowStyle Hidden
        
            # exit from the current, unelevated, process
            exit
        }
    }
    if ($choice -in 1, 2) {
        $noEnvModification = $false
    }
    else {
        $noEnvModification = $true
    }
}

Clear-Host

if (!$noEnvModification -and !$testInstallation) {
    @"
####################################
#   BEFORE YOU CONTINUE
####################################

- create cloud or locally hosted GIT !private! repository (tested with Azure DevOps but probably will work also with GitHub etc)
   - create READ only account in that repository (repo_puller)
       - create credentials for this account, that can be used in unnatended way (i.e. alternate credentials in Azure DevOps)
   - install newest version of 'Git' and 'Git Credential Manager for Windows' and clone your repository locally
        - using 'git clone' command under account, that has write permission to the repository i.e. yours

   - NOTE:
        - it is highly recommended to use 'Visual Studio Code (VSC)' editor to work with the repository content because it provides:
            - unified admin experience through repository VSC workspace settings
            - integration & control of GIT
            - auto-formatting of the code etc
        - more details can be found at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md
"@

    _pressKeyToContinue
}
elseif ($testInstallation) {
    "   - installing 'GIT'"
    _installGIT

    "   - installing 'VSC'"
    _installVSC

    Install-PackageProvider -Name nuget -Force -ForceBootstrap -Scope allusers | Out-Null
    
    # if (!(Get-Module -ListAvailable PSScriptAnalyzer)) {
    #     "   - installing 'PSScriptAnalyzer' PS module"
    #     Install-Module PSScriptAnalyzer -SkipPublisherCheck -Force
    # }

    "   - updating 'PackageManagement' PS module"
    # solves issue https://github.com/PowerShell/vscode-powershell/issues/2824
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-Module -Name PackageManagement -Force -ea SilentlyContinue

    "   - enabling running of PS scripts"
    # because of PS global profile loading
    Set-ExecutionPolicy Bypass -Force
}

# TODO nekam napsat ze je potreba psremoting

if (!$testInstallation) {
    Clear-Host
}
else {
    ""
}

if (!$noEnvModification -and !$testInstallation) {
    @"
############################
!!! ANYONE WHO CONTROL THIS SOLUTION IS DE FACTO ADMINISTRATOR ON EVERY COMPUTER CONNECTED TO IT !!!
So:
    - just approved users should have write access to GIT repository
    - for accessing cloud GIT repository, use MFA if possible
    - MGM server (processes repository data and uploads them to share) has to be protected so as the server that hosts that repository share
############################
"@

    _pressKeyToContinue
    Clear-Host

    @"
############################

Your input will be stored to '$iniFile'. So next time you start this script, its content will be automatically used.

############################
"@
}

if (!$testInstallation) {
    _pressKeyToContinue
    Clear-Host
}
else {
    ""
}
#endregion initial

try {
    #region import variables
    # import variables from ini file
    # '#' can be used for comments, so skip such lines
    if (Test-Path $iniFile) {
        Write-host "- Importing variables from $iniFile" -ForegroundColor Green
        Get-Content $iniFile -ea SilentlyContinue | ? { $_ -and $_ -notmatch "^\s*#" } | % {
            $line = $_
            if (($line -split $divider).count -ge 2) {
                $position = $line.IndexOf($divider)
                $name = $line.Substring(0, $position) -replace "^\s*|\s*$"
                $value = $line.Substring($position + 1) -replace "^\s*|\s*$"
                "   - variable $name` will have value: $value"

                # fill hash so I can later export (updated) variables back to file
                $setupVariable.$name = $value
            }
        }

        _pressKeyToContinue
    }
    #endregion import variables

    if (!$testInstallation) {
        Clear-Host
    }

    #region checks
    Write-host "- Checking permissions etc" -ForegroundColor Green

    # # computer isn't in domain
    # if (!$noEnvModification -and !(Get-WmiObject -Class win32_computersystem).partOfDomain) {
    #     Write-Warning "This PC isn't joined to domain. AD related steps will have to be done manually."

    #     ++$skipAD

    #     _continue
    # }

    # is local administrator
    if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Warning "Not running as administrator. Symlink for using repository PowerShell snippets file in VSC won't be created"
        ++$notAdmin
    
        _pressKeyToContinue
    }

    if (!$testInstallation) {
        # is domain admin
        if (!$noEnvModification -and !((whoami /all) -match "Domain Admins|Enterprise Admins")) {
            Write-Warning "You are not member of Domain nor Enterprise Admin group. AD related steps will have to be done manually."

            ++$notADAdmin

            _continue
        }

        # ActiveDirectory PS module is available
        if (!$noEnvModification -and !(Get-Module ActiveDirectory -ListAvailable)) {
            Write-Warning "ActiveDirectory PowerShell module isn't installed (part of RSAT)."

            if (!$notAdmin -and ((_continue "Proceed with installation" -passthru) -eq "Y")) {
                if ($isServer) {
                    $null = Add-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools
                }
                else {
                    try {
                        $null = Get-WindowsCapability -Name "*activedirectory*" -Online -ErrorAction Stop | Add-WindowsCapability -Online -ErrorAction Stop 
                    }
                    catch {
                        Write-Warning "Unable to install RSAT AD tools.`nAD related steps will be skipped, so make them manually."
                        ++$noADmodule
                        _pressKeyToContinue
                    }
                }
            }
            else {
                Write-Warning "AD related steps will be skipped, so make them manually."
                ++$noADmodule
                _pressKeyToContinue
            }
        }

        # GroupPolicy PS module is available
        if (!$noEnvModification -and !(Get-Module GroupPolicy -ListAvailable)) {
            Write-Warning "GroupPolicy PowerShell module isn't installed (part of RSAT)."

            if (!$notAdmin -and ((_continue "Proceed with installation" -passthru) -eq "Y")) {
                if ($isServer) {
                    $null = Add-WindowsFeature -Name GPMC -IncludeManagementTools
                }
                else {
                    try {
                        $null = Get-WindowsCapability -Name "*grouppolicy*" -Online -ErrorAction Stop | Add-WindowsCapability -Online -ErrorAction Stop 
                    }
                    catch {
                        Write-Warning "Unable to install RSAT GroupPolicy tools.`nGPO related steps will be skipped, so make them manually."
                        ++$noGPOmodule
                        _pressKeyToContinue
                    }
                }
            }
            else {
                Write-Warning "GPO related steps will be skipped, so make them manually."
                ++$noGPOmodule
                _pressKeyToContinue
            }
        }

        if ($notADAdmin -or $noADmodule) {
            ++$skipAD
        }

        if ($notADAdmin -or $noGPOmodule) {
            ++$skipGPO
        }
    }

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    #endregion checks


    if (!$testInstallation) {
        _SetVariable MGMServer "the name of the MGM server (will be used for pulling, processing and distributing of repository data to repository share)."
        if ($MGMServer -like "*.*") {
            $MGMServer = ($MGMServer -split "\.")[0]
            Write-Warning "$MGMServer was in FQDN format. Just hostname was used"
        }
        if (!$noADmodule -and !(Get-ADComputer -Filter "name -eq '$MGMServer'")) {
            throw "$MGMServer doesn't exist in AD"
        }
    }
    else {
        # test installation
        $MGMServer = $env:COMPUTERNAME
        "   - For testing purposes, this computer will host MGM server role too"
    }

    if (!$testInstallation) {
        _saveInput
        Clear-Host
    }
    else {
        ""
    }

    #region create repo_reader, repo_writer
    if (!$testInstallation) {
        Write-Host "- Creating repo_reader, repo_writer AD security groups" -ForegroundColor Green

        if (!$noEnvModification -and !$skipAD -and !(_skip)) {
            'repo_reader', 'repo_writer' | % {
                if (Get-ADGroup -filter "samaccountname -eq '$_'") {
                    "   - $_ already exists"
                }
                else {
                    if ($_ -match 'repo_reader') {
                        $right = "read"
                    }
                    else {
                        $right = "modify"
                    }
                    New-ADGroup -Name $_ -GroupCategory Security -GroupScope Universal -Description "Members have $right permission to repository share content."
                    " - created $_"
                }
            }
        }
        else {
            Write-Warning "Skipped!`n`nCreate them manually"
        }
    }
    else {
        Write-Host "- Creating repo_reader, repo_writer security groups" -ForegroundColor Green

        'repo_reader', 'repo_writer' | % {
            if (Get-LocalGroup $_ -ea SilentlyContinue) {
                # already exists
            }
            else {
                if ($_ -match 'repo_reader') {
                    $right = "read"
                }
                else {
                    $right = "modify"
                }
                $null = New-LocalGroup -Name $_ -Description "Members have $right right to repository share." # max 48 chars!
            }
        }
    }
    #endregion create repo_reader, repo_writer

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region adding members to repo_reader, repo_writer
    if (!$testInstallation) {
        Write-Host "- Adding members to repo_reader, repo_writer AD groups" -ForegroundColor Green
        "   - add 'Domain Computers' to repo_reader group"
        "   - add 'Domain Admins' and $MGMServer to repo_writer group"
    
        if (!$noEnvModification -and !$skipAD -and !(_skip)) {
            "   - adding 'Domain Computers' to repo_reader group (DCs are not members of this group!)"
            Add-ADGroupMember -Identity 'repo_reader' -Members "Domain Computers"
            "   - adding 'Domain Admins' and $MGMServer to repo_writer group"
            Add-ADGroupMember -Identity 'repo_writer' -Members "Domain Admins", "$MGMServer$"
        }
        else {
            Write-Warning "Skipped! Fill them manually.`n`n - repo_reader should contains computers which you want to join to this solution i.e. 'Domain Computers' (if you choose just subset of computers, use repo_reader and repo_writer for security filtering on lately created GPO $GPOname)`n - repo_writer should contains 'Domain Admins' and $MGMServer server"
        }

        ""
        Write-Warning "RESTART $MGMServer (and rest of the computers) to apply new membership NOW!"
    }
    else {
        Write-Host "- Adding members to repo_reader, repo_writer groups" -ForegroundColor Green
        # "   - adding SYSTEM to repo_reader group"
        # Add-LocalGroupMember -Name 'repo_reader' -Member "SYSTEM"
        "   - adding Administrators and SYSTEM to repo_writer group"
        "Administrators", "SYSTEM" | % {
            if ($_ -notin (Get-LocalGroupMember -Name 'repo_writer' | select @{n = "Name"; e = { ($_.Name -split "\\")[-1] } } | select -exp Name)) {
                Add-LocalGroupMember -Name 'repo_writer' -Member $_
            }
        } 
        
    }
    #endregion adding members to repo_reader, repo_writer
    
    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region set up shared folder for repository data
    Write-Host "- Creating shared folder for hosting repository data" -ForegroundColor Green
    if (!$testInstallation) {
        _SetVariable repositoryShare "UNC path to folder, where the repository data should be stored (i.e. \\mydomain\dfs\repository)"
    }
    else {
        "   - For testing purposes $repositoryShare will be used"
    }
    if ($repositoryShare -notmatch "^\\\\[^\\]+\\[^\\]+") {
        throw "$repositoryShare isn't valid UNC path"
    }

    $permissions = "`n`t`t- SHARE`n`t`t`t- Everyone - FULL CONTROL`n`t`t- NTFS`n`t`t`t- SYSTEM, repo_writer - FULL CONTROL`n`t`t`t- repo_reader - READ"

    if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
        "   - Testing, whether '$repositoryShare' already exists"
        try {
            $repositoryShareExists = Test-Path $repositoryShare
        }
        catch {
            # in case this script already created that share but this user isn't yet in repo_writer, he will receive access denied error when accessing it
            if ($_ -match "access denied") {
                ++$accessDenied
            }
        }
        if ($repositoryShareExists -or $accessDenied) {
            if (!$testInstallation) {
                Write-Warning "Share '$repositoryShare' already exists.`n`tMake sure, that ONLY following permissions are set:$permissions`n`nNOTE: it's content will be replaced by repository data eventually!"
            }
        }
        else {
            # share or some part of its path doesn't exist
            $isDFS = ""
            if (!$testInstallation) {
                # for testing installation I will use common UNC share
                while ($isDFS -notmatch "^[Y|N]$") {
                    ""
                    $isDFS = Read-Host "   - Is '$repositoryShare' DFS share? (Y|N)"
                }
            }
            if ($isDFS -eq "Y") {
                #TODO pridat podporu pro tvorbu DFS share
                Write-Warning "Skipped! Currently this installer doesn't support creation of DFS share.`nMake share manually with ONLY following permissions:$permissions"
            }
            else {
                # creation of non-DFS shared folder
                $repositoryHost = ($repositoryShare -split "\\")[2]
                if (!$testInstallation -and !$noADmodule -and !(Get-ADComputer -Filter "name -eq '$repositoryHost'")) {
                    throw "$repositoryHost doesn't exist in AD"
                }

                $parentPath = "\\" + [string]::join("\", $repositoryShare.Split("\")[2..3])

                if (($parentPath -eq $repositoryShare) -or ($parentPath -ne $repositoryShare -and !(Test-Path $parentPath -ea SilentlyContinue))) {
                    # shared folder doesn't exist, can't deduce local path from it, so get it from the user
                    ""
                    if (!$testInstallation) {
                        _SetVariable repositoryShareLocPath "local path to folder, which will be than shared as '$parentPath' (on $repositoryHost)"
                    }
                    else {
                        "   - For testing purposes, repository share will be stored locally in '$repositoryShareLocPath'"
                    }
                }
                else {
                    ""
                    "   - Share $parentPath already exists. Folder for repository data will be created (if necessary) and JUST NTFS permissions will be set."
                    Write-Warning "So make sure, that SHARE permissions are set to: Everyone - FULL CONTROL!"

                    _pressKeyToContinue
                }

                $invokeParam = @{}
                if (!$testInstallation) {
                    if ($notADAdmin) {
                        while (!$repositoryHostSession) {
                            $repositoryHostSession = New-PSSession -ComputerName $repositoryHost -Credential (Get-Credential -Message "Enter admin credentials for connecting to $repositoryHost through psremoting") -ErrorAction SilentlyContinue
                        }
                    }
                    else {
                        $repositoryHostSession = New-PSSession -ComputerName $repositoryHost
                    }
                    $invokeParam.Session = $repositoryHostSession
                }
                else {
                    # testing installation i.e. locally
                }

                $invokeParam.argumentList = $repositoryShareLocPath, $repositoryShare, $allFunctionDefs
                $invokeParam.ScriptBlock = {
                    param ($repositoryShareLocPath, $repositoryShare, $allFunctionDefs)

                    # recreate function from it's definition
                    foreach ($functionDef in $allFunctionDefs) {
                        . ([ScriptBlock]::Create($functionDef))
                    }

                    $shareName = ($repositoryShare -split "\\")[3]

                    if ($repositoryShareLocPath) {
                        # share doesn't exist yet
                        # create folder (and subfolders) and share it
                        if (Test-Path $repositoryShareLocPath) {
                            Write-Warning "$repositoryShareLocPath already exists on $env:COMPUTERNAME!"
                            _continue "Content will be eventually overwritten"
                        }
                        else {
                            [Void][System.IO.Directory]::CreateDirectory($repositoryShareLocPath)

                            # create subfolder structure if UNC path contains them as well
                            $subfolder = [string]::join("\", $repositoryShare.split("\")[4..1000])
                            $subfolder = Join-Path $repositoryShareLocPath $subfolder 
                            [Void][System.IO.Directory]::CreateDirectory($subfolder)

                            # share the folder
                            "       - share $repositoryShareLocPath as $shareName"
                            $null = Remove-SmbShare -Name $shareName -Force -Confirm:$false -ErrorAction SilentlyContinue
                            $null = New-SmbShare -Name $shareName -Path $repositoryShareLocPath -FullAccess Everyone

                            # set NTFS permission
                            "       - setting NTFS permissions on $repositoryShareLocPath"
                            _setPermissions -path $repositoryShareLocPath -writeUser SYSTEM, repo_writer -readUser repo_reader
                        }
                    }
                    else {
                        # share already exists
                        # create folder for storing repository, set NTFS permissions and check SHARE permissions 
                        $share = Get-SmbShare $shareName
                        $repositoryShareLocPath = $share.path

                        # create subfolder structure if UNC path contains them as well
                        $subfolder = [string]::join("\", $repositoryShare.split("\")[4..1000])
                        $subfolder = Join-Path $repositoryShareLocPath $subfolder
                        [Void][System.IO.Directory]::CreateDirectory($subfolder)

                        # set NTFS permission
                        "`n   - setting NTFS permissions on $repositoryShareLocPath"
                        _setPermissions -path $repositoryShareLocPath -writeUser SYSTEM, repo_writer -readUser repo_reader

                        # check/set SHARE permission
                        $sharePermission = Get-SmbShareAccess $shareName
                        if (!($sharePermission | ? { $_.accountName -eq "Everyone" -and $_.AccessControlType -eq "Allow" -and $_.AccessRight -eq "Full" })) {
                            "      - share $shareName doesn't contain valid SHARE permissions, EVERYONE should have FULL CONTROL access (access to repository data is driven by NTFS permissions)."
                            
                            _pressKeyToContinue "Current share $repositoryShare will be un-shared and re-shared with correct SHARE permissions"

                            Remove-SmbShare -Name $shareName -Force -Confirm:$false            
                            New-SmbShare -Name $shareName -Path $repositoryShareLocPath -FullAccess EVERYONE
                        }
                        else {
                            "      - share $shareName already has correct SHARE permission, no action needed"
                        }
                    }
                }

                Invoke-Command @invokeParam

                if ($repositoryHostSession) {
                    Remove-PSSession $repositoryHostSession -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        Write-Warning "Skipped!`n`n - Create shared folder '$repositoryShare' manually and set there following permissions:$permissions"
    }
    #endregion set up shared folder for repository data

    if (!$testInstallation) {
        _saveInput
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region customize cloned data
    $repo_content_set_up = Join-Path $PSScriptRoot "repo_content_set_up"
    $_other = Join-Path $PSScriptRoot "_other"
    Write-Host "- Customizing generic data to match your environment by replacing '__REPLACEME__<number>' in content of '$repo_content_set_up' and '$_other'" -ForegroundColor Green
    if (!(Test-Path $repo_content_set_up -ea SilentlyContinue)) {
        throw "Unable to find '$repo_content_set_up'. Clone repository https://github.com/ztrhgf/Powershell_CICD_repository again"
    }
    if (!(Test-Path $_other -ea SilentlyContinue)) {
        throw "Unable to find '$_other'. Clone repository https://github.com/ztrhgf/Powershell_CICD_repository again"
    }

    if (!$testInstallation) {
        Write-Host "`n   - Gathering values for replacing __REPLACEME__<number> string:" -ForegroundColor DarkGreen
        "       - in case, you will need to update some of these values in future, clone again this repository, edit content of $iniFile and run this wizard again`n"
        $replacemeVariable = @{
            1 = $repositoryShare
            2 = _setVariable repositoryURL "Cloning URL of your own GIT repository. Will be used on MGM server" -passThru
            3 = $MGMServer
            4 = _setVariable computerWithProfile "name of computer(s) (without ending $, divided by comma) that should get:`n       - global Powershell profile (shows number of commits this console is behind in Title etc)`n       - adminFunctions module (Refresh-Console function etc)`n" -passThru
            5 = _setVariable smtpServer "IP or hostname of your SMTP server. Will be used for sending error notifications (recipient will be specified later)" -optional -passThru
            6 = _setVariable adminEmail "recipient(s) email address (divided by comma), that should receive error notifications. Use format it@contoso.com" -optional -passThru
            7 = _setVariable 'from' "sender email address, that should be used for sending error notifications. Use format robot@contoso.com" -optional -passThru
        }
    }
    else {
        # there will be created GIT repository for test installation

        $repositoryURL = $remoteRepository
        $computerWithProfile = $env:COMPUTERNAME
        Write-Warning "So this computer will get:`n - global Powershell profile (shows number of commits this console is behind in Title etc)`n - adminFunctions module (Refresh-Console function etc)`n"

        $replacemeVariable = @{
            1 = $repositoryShare
            2 = $repositoryURL
            3 = $MGMServer
            4 = $computerWithProfile
        }
    }

    # replace __REPLACEME__<number> for entered values in cloned files
    $replacemeVariable.GetEnumerator() | % {
        # in files, __REPLACEME__<number> format is used where user input should be placed
        $name = "__REPLACEME__" + $_.name
        $value = $_.value

        # variables that support array convert to "a", "b", "c" format
        if ($_.name -in (4, 6) -and $value -match ",") {
            $value = $value -split "," -replace "\s*$|^\s*"
            $value = $value | % { "`"$_`"" }
            $value = $value -join ", "
        }

        # variable is repository URL, convert it to correct format
        if ($_.name -eq 2) {
            # remove leading http(s):// because it is already mentioned in repo_sync.ps1
            $value = $value -replace "^http(s)?://"
            # remove login i.e. part before @
            $value = $value.Split("@")[-1]
        }

        # remove quotation, replace string is already quoted in files
        $value = $value -replace "^\s*[`"']" -replace "[`"']\s*$"

        if (!$testInstallation) {
            "   - replacing: $name for: $value"
        } else {
            Write-Verbose "   - replacing: $name for: $value"
        }

        Get-ChildItem $repo_content_set_up, $_other -Include *.ps1, *.psm1, *.xml -Recurse | % {
            (Get-Content $_.fullname) -replace $name, $value | Set-Content $_.fullname
        }

        #TODO zkontrolovat/upozornit na soubory kde jsou replaceme (exclude takovych kde nezadal uzivatel zadnou hodnotu)
    }
    #endregion customize cloned data

    if (!$testInstallation) {
        _saveInput
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region warn about __CHECKME__
    Write-Host "- Searching for __CHECKME__ in $repo_content_set_up" -ForegroundColor Green
    $fileWithCheckMe = Get-ChildItem $repo_content_set_up -Recurse | % { if ((Get-Content $_.fullname -ea SilentlyContinue -Raw) -match "__CHECKME__") { $_.fullname } }
    # remove this script from the list
    $fileWithCheckMe = $fileWithCheckMe | ? { $_ -ne $PSCommandPath }
    if ($fileWithCheckMe) {
        Write-Warning "(OPTIONAL CUSTOMIZATIONS) Search for __CHECKME__ string in the following files and decide what to do according to information that follows there (save any changes before continue):"
        $fileWithCheckMe | % { "   - $_" }
    }
    #endregion warn about __CHECKME__

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region copy customized repository data to user own repository
    if (!$testInstallation) {
        _SetVariable userRepository "path to ROOT of your locally cloned company repository '$repositoryURL'"
    }
    else {
        Write-Host " - Creating new GIT repository '$remoteRepository'. It will be used instead of your own cloud repository like GitHub or Azure DevOps. DON'T MAKE ANY CHANGES HERE." -ForegroundColor Green
        [Void][System.IO.Directory]::CreateDirectory($remoteRepository)
        Set-Location $remoteRepository
        $result = _startProcess git init
        #FIXME https://stackoverflow.com/questions/3221859/cannot-push-into-git-repository
        $result = _startProcess git "config receive.denyCurrentBranch updateInstead"

        ""

        Write-Host " - Cloning '$remoteRepository' to '$userRepository'. So in '$userRepository' MAKE YOUR CHANGES." -ForegroundColor Green
        Set-Location (Split-Path $userRepository -Parent)
        $result = _startProcess git "clone --local $remoteRepository $(Split-Path $userRepository -Leaf)" -outputErr2Std
    }

    if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
        if (!(Test-Path (Join-Path $userRepository ".git") -ea SilentlyContinue)) {
            throw "$userRepository isn't cloned GIT repository (.git folder is missing)"
        }

        Write-Host "- Copying customized repository data ($repo_content_set_up) to your own company repository ($userRepository)" -ForegroundColor Green
        $result = _copyFolder $repo_content_set_up $userRepository
        if ($err = $result.errMsg) {
            throw "Copy failed:`n$err"
        }
    }
    else {
        Write-Warning "Skipped!`n`n - Copy CONTENT of $repo_content_set_up to ROOT of your locally cloned company repository. Review the changes to prevent loss of any of your customization (preferably merge content of customConfig.ps1 and Variables.psm1 instead of replacing them completely) and COMMIT them"
    }
    #endregion copy customized repository data to user own repository

    if (!$testInstallation) {
        _pressKeyToContinue
        _saveInput
        Clear-Host
    }
    else {
        ""
    }

    #region configure user repository
    if ($env:USERDNSDOMAIN) {
        $userDomain = $env:USERDNSDOMAIN
    }
    else {
        $userDomain = "$env:COMPUTERNAME.com"
    }
    Write-Host "- Configuring repository '$userRepository'" -ForegroundColor Green

    if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
        $currPath = Get-Location
        Set-Location $userRepository

        # just in case user installed GIT after launch of this console, update PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        "   - setting GIT user name to '$env:USERNAME'"
        git config user.name $env:USERNAME

        "   - setting GIT user email to '$env:USERNAME@$userDomain'"
        git config user.email "$env:USERNAME@$userDomain"

        $VSCprofile = Join-Path $env:APPDATA "Code\User"
        $profileSnippets = Join-Path $VSCprofile "snippets"
        [Void][System.IO.Directory]::CreateDirectory($profileSnippets)
        $profilePSsnippet = Join-Path $profileSnippets "powershell.json"
        $repositoryPSsnippet = Join-Path $userRepository "powershell.json"
        "   - creating symlink '$profilePSsnippet' for '$repositoryPSsnippet', so VSC can offer these PowerShell snippets"
        if (!$notAdmin -and (Test-Path $VSCprofile -ea SilentlyContinue) -and !(Test-Path $profilePSsnippet -ea SilentlyContinue)) {
            [Void][System.IO.Directory]::CreateDirectory($profileSnippets)
            $null = New-Item -itemtype symboliclink -path $profileSnippets -name "powershell.json" -value $repositoryPSsnippet
        }
        else {
            Write-Warning "Skipped.`n`nYou are not running this script with admin privileges or VSC isn't installed or '$profilePSsnippet' already exists"
        }

        # to avoid message 'warning: LF will be replaced by CRLF'
        $null = _startProcess git "config core.autocrlf false" -outputErr2Std -dontWait
        
        # commit without using hooks, to avoid possible problem with checks (because of wrong encoding, missing PSScriptAnalyzer etc), that could stop it 
        "   - commiting & pushing changes to repository $repositoryURL"
        $null = git add .
        $null = _startProcess git "commit --no-verify -m initial" -outputErr2Std -dontWait
        $null = _startProcess git "push --no-verify" -outputErr2Std

        "   - activating GIT hooks for automation of checks, git push etc"
        $null = _startProcess git 'config core.hooksPath ".\.githooks"'

        # to set default value again
        $null = _startProcess git "config core.autocrlf true" -outputErr2Std -dontWait

        Set-Location $currPath
    }
    else {
        Write-Warning "Skipped!`n`nFollow instructions in $(Join-Path $repo_content_set_up '!!!README!!!.txt') file"
    }
    #endregion configure user repository

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region preparation of MGM server
    $MGMRepoSync = "\\$MGMServer\C$\Windows\Scripts\Repo_sync"
    $userRepoSync = Join-Path $userRepository "custom\Repo_sync"
    Write-Host "- Setting MGM server ($MGMServer)" -ForegroundColor Green
    if (!$testInstallation) {
        @"
   - copy Repo_sync folder to '$MGMRepoSync'
   - install newest version of 'GIT'
   - create scheduled task 'Repo_sync' from 'Repo_sync.xml'
   - export 'repo_puller' account alternate credentials to '$MGMRepoSync\login.xml' (only SYSTEM account on $MGMServer will be able to read them!)
   - copy exported credentials from $MGMServer to $userRepoSync
   - commit&push exported credentials (so they won't be automatically deleted from $MGMServer, after this solution starts working)

"@
    }

    if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
        "   - copying Repo_sync folder to '$MGMRepoSync'"
        if (!$testInstallation) {
            if ($notADAdmin) {
                while (!$MGMServerSession) {
                    $MGMServerSession = New-PSSession -ComputerName $MGMServer -Credential (Get-Credential -Message "Enter admin credentials for connecting to $MGMServer through psremoting") -ErrorAction SilentlyContinue
                }
            }
            else {
                $MGMServerSession = New-PSSession -ComputerName $MGMServer
            }

            if ($notADAdmin) {
                $destination = "C:\Windows\Scripts\Repo_sync"

                # remove existing folder, otherwise Copy-Item creates eponymous subfolder and copies the content to it
                Invoke-Command -Session $MGMServerSession {
                    param ($destination)
                    if (Test-Path $destination -ea SilentlyContinue) {
                        Remove-Item $destination -Recurse -Force
                    }
                } -ArgumentList $destination

                Copy-Item -ToSession $MGMServerSession $userRepoSync -Destination $destination -Force -Recurse
            }
            else {
                # copy using admin share
                $result = _copyFolder $userRepoSync $MGMRepoSync 
                if ($err = $result.errMsg) {
                    throw "Copy failed:`n$err"
                }
            }
        }
        else {
            # local copy
            $destination = "C:\Windows\Scripts\Repo_sync"
            $result = _copyFolder $userRepoSync $destination
            if ($err = $result.errMsg) {
                throw "Copy failed:`n$err"
            }
        }

        $invokeParam = @{
            ArgumentList = $repositoryShare, $allFunctionDefs, $testInstallation
        }
        if ($MGMServerSession) {
            $invokeParam.session = $MGMServerSession
        }
        $invokeParam.ScriptBlock = {
            param ($repositoryShare, $allFunctionDefs, $testInstallation)

            # recreate function from it's definition
            foreach ($functionDef in $allFunctionDefs) {
                . ([ScriptBlock]::Create($functionDef))
            }

            $MGMRepoSync = "C:\Windows\Scripts\Repo_sync"
            $taskName = 'Repo_sync'

            if (!$testInstallation) {
                "   - checking that $env:COMPUTERNAME is in AD group repo_writer"
                if (!(_getComputerMembership -match "repo_writer")) {
                    throw "Check failed. Make sure, that $env:COMPUTERNAME is in repo_writer group and restart it to apply new membership. Than run this script again"
                }
            }

            "   - installing newest 'GIT'"
            _installGIT

            # "   - downloading & installing 'GIT Credential Manager'"
            # _installGITCredManager

            $Repo_syncXML = "$MGMRepoSync\Repo_sync.xml"
            "   - creating scheduled task '$taskName' from $Repo_syncXML"
            _createSchedTask $Repo_syncXML $taskName

            if (!$testInstallation) {
                "   - exporting repo_puller account alternate credentials to '$MGMRepoSync\login.xml' (only SYSTEM account on $env:COMPUTERNAME will be able to read them!)"
                _exportCred -credential (Get-Credential -Message 'Enter credentials (that can be used in unattended way) for GIT "repo_puller" account, you created earlier') -runAs "NT AUTHORITY\SYSTEM" -xmlPath "$MGMRepoSync\login.xml"
            }

            "   - starting scheduled task '$taskName' to fill $repositoryShare immediately"
            _startSchedTask $taskName

            "      - checking, that the task ends up succesfully"
            while (($result = ((schtasks /query /tn "$taskName" /v /fo csv /nh) -split ",")[6]) -eq '"267009"') {
                # task is running
                Start-Sleep 1
            }
            if ($result -ne '"0"') {
                throw "Task '$taskName' ends up with error ($($result -replace '"')). Check C:\Windows\Temp\Repo_sync.ps1.log on $env:COMPUTERNAME for more information"
            }
        }

        Invoke-Command @invokeParam

        if (!$testInstallation) {
            "   - copying exported credentials from $MGMServer to $userRepoSync"
            if ($notADAdmin) {
                Copy-Item -FromSession $MGMServerSession "C:\Windows\Scripts\Repo_sync\login.xml" -Destination "$userRepoSync\login.xml" -force
            }
            else {
                # copy using admin share
                Copy-Item "$MGMRepoSync\login.xml" "$userRepoSync\login.xml" -Force
            }

            if ($MGMServerSession) {
                Remove-PSSession $MGMServerSession -ErrorAction SilentlyContinue
            }

            "   - committing exported credentials (so they won't be automatically deleted from MGM server, after this solution starts)"
            $currPath = Get-Location
            Set-Location $userRepository
            $null = git add .
            $null = _startProcess git 'commit --no-verify -m "repo_puller creds for $MGMServer"' -outputErr2Std -dontWait
            $null = _startProcess git "push --no-verify" -outputErr2Std
            # git push # push should be done automatically thanks to git hooks
            Set-Location $currPath
        }
    }
    else {
        Write-Warning "Skipped!`n`nFollow instruction in configuring MGM server section https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md#on-server-which-will-be-used-for-cloning-and-processing-cloud-repository-data-and-copying-result-to-dfs-ie-mgm-server"
    }
    #endregion preparation of MGM server

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region create GPO (PS_env_set_up scheduled task)
    if (!$testInstallation) {
        $GPObackup = Join-Path $_other "PS_env_set_up GPO"
        Write-Host "- Creating GPO $GPOname for creating sched. task, that will synchronize repository data from share to clients" -ForegroundColor Green
        if (!$noEnvModification -and !$skipGPO -and !(_skip)) {
            if (Get-GPO $GPOname -ErrorAction SilentlyContinue) {
                $choice = ""
                while ($choice -notmatch "^[Y|N]$") {
                    $choice = Read-Host "GPO $GPOname already exists. Replace it? (Y|N)"
                }
                if ($choice -eq "Y") {
                    $null = Import-GPO -BackupGpoName $GPOname -Path $GPObackup -TargetName $GPOname 
                }
                else {
                    Write-Warning "Skipped creation of $GPOname"
                }
            }
            else {
                $null = Import-GPO -BackupGpoName $GPOname -Path $GPObackup -TargetName $GPOname -CreateIfNeeded 
            }
        }
        else {
            Write-Warning "Skipped!`n`nCreate GPO by following https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md#in-active-directory-1 or using 'Import settings...' wizard in GPMC. GPO backup is stored in '$GPObackup'"
        }
    }
    else {
        # testing installation i.e. sched. task has to be created manually (instead of GPO)
        Write-Host "- Creating PS_env_set_up scheduled task, that will synchronize repository data from share to this client" -ForegroundColor Green

        $PS_env_set_up_schedTaskDefinition = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
    <RegistrationInfo>
    <Author>CONTOSO\adminek</Author>
    <URI>\PS_env_set_up</URI>
    </RegistrationInfo>
    <Triggers>
    <TimeTrigger>
        <Repetition>
        <Interval>PT10M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
        </Repetition>
        <StartBoundary>2019-04-10T14:31:23</StartBoundary>
        <Enabled>true</Enabled>
    </TimeTrigger>
    </Triggers>
    <Principals>
    <Principal id="Author">
        <UserId>S-1-5-18</UserId>
        <RunLevel>HighestAvailable</RunLevel>
    </Principal>
    </Principals>
    <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
        <Duration>PT5M</Duration>
        <WaitTimeout>PT1H</WaitTimeout>
        <StopOnIdleEnd>false</StopOnIdleEnd>
        <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
        <Interval>PT1M</Interval>
        <Count>3</Count>
    </RestartOnFailure>
    </Settings>
    <Actions Context="Author">
    <Exec>
        <Command>powershell.exe</Command>
        <Arguments>-ExecutionPolicy ByPass -NoProfile `"$repositoryShare\PS_env_set_up.ps1`"</Arguments>
    </Exec>
    </Actions>
</Task>
"@

        $PS_env_set_up_schedTaskDefinitionFile = "$env:TEMP\432432432.xml"
        $PS_env_set_up_schedTaskDefinition | Out-File $PS_env_set_up_schedTaskDefinitionFile -Encoding ascii -Force
        _createSchedTask $PS_env_set_up_schedTaskDefinitionFile "PS_env_set_up"
        "   - starting scheduled task 'PS_env_set_up' to synchronize repository data from share to this client"
        _startSchedTask "PS_env_set_up"
    }
    #endregion create GPO (PS_env_set_up scheduled task)

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    #region finalize installation
    Write-Host "FINALIZING INSTALLATION" -ForegroundColor Green
    if (!$noEnvModification -and !$skipAD -and !$skipGPO -and !$notAdmin) {
        # enought rights to process all steps
    }
    else {
        "- DO NOT FORGET TO DO ALL SKIPPED TASKS MANUALLY"
    }
    if (!$testInstallation) {
        Write-Warning "- Link GPO $GPOname to OU(s) with computers, that should be driven by this tool.`n    - don't forget, that also $MGMServer server has to be in such OU!"
        @"
    - for ASAP test that synchronization is working:
        - run on client command 'gpupdate /force' to create scheduled task $GPOname
        - run that sched. task and check the result in C:\Windows\Temp\$GPOname.ps1.log
"@
    } else {
        "- check this console output, to get better idea what was done"
    }
    #endregion finalize installation

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    }
    else {
        ""
    }

    if ($testInstallation) {
        @"
SUMMARY INFORMATION ABOUT THIS !TEST! INSTALLATION:
 - central repository share is at $repositoryShareLocPath (locally at $repositoryShareLocPath) 
    - it is used by clients to synchronize their repository data
 - (cloud) repository is hosted locally at $remoteRepository
    - simulates for example GitHub private repository
 - (cloud) repository is locally cloned to $userRepository
    - here you makes changes (creates new functions, modules, ...) and commit them to (cloud) repository
 - scheduled tasks:
    - Repo_sync - pulls data from (cloud) GIT repository, process them and synchronize result to $repositoryShare
        - processing is done in C:\Windows\Scripts\Repo_sync
        - log file in C:\Windows\Temp\Repo_sync.ps1.log
    - PS_env_set_up - synchronizes local content from $repositoryShare i.e. it is used to get repository data to clients
        - log file in C:\Windows\Temp\PS_env_set_up.ps1.log
"@
        _pressKeyToContinue
        Clear-Host
    }

    Write-Host "GOOD TO KNOW" -ForegroundColor green
    @"
- Do NOT place your GIT repository inside Dropbox, Onedrive or other similar synchronization tool, it would cause problems!
- To understand, what is purpose of this repository content check https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/3.%20SIMPLIFIED%20EXPLANATION%20OF%20HOW%20IT%20WORKS.md
- For immediate refresh of clients data (and console itself) use function Refresh-Console
    - NOTE: available only on computers defined in Variables module in variable `$computerWithProfile
- For examples check https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md
- For brief video introduction check https://youtu.be/-xSJXbmOgyk and other videos at https://youtube.com/playlist?list=PLcNLAABGhY_GqrWfOZGjpgFv3fiaL0ciM
- To master Modules deployment check \modules\modulesConfig.ps1
- To master Custom section features check \custom\customConfig.ps1
- To see what is happening in the background check logs
    - In VSC Output terminal (CTRL + SHIFT + U, there switch output to GIT) (pre-commit.ps1 checks)
    - C:\Windows\Temp\Repo_sync.ps1.log on MGM server (synchronization from GIT repository to share)
    - C:\Windows\Temp\PS_env_set_up.ps1.log on client (synchronization from share to client)

ENJOY :)

"@

    # start VSC and open there GIT repository
    $codeCmdPath = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
    if (Test-Path $codeCmdPath) {
        Start-Sleep 10
        "- Opening your repository in VSC"
        & $codeCmdPath "$userRepository"
    }
}
catch {
    $e = $_.Exception
    $line = $_.InvocationInfo.ScriptLineNumber
    Write-Host "$e (file: $PSCommandPath line: $line)" -ForegroundColor Red
    break
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue

    try {
        Remove-PSSession -Session $repositoryHostSession
        Remove-PSSession -Session $MGMServerSession
    }
    catch {}
}