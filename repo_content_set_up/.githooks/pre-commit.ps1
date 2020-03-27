﻿<#
script is automatically run when new commit is created (because it is bound to git pre-commit hook)
check:
    if git pull is needed
    syntax, file format, name convention, fulfill of best practices, problematic character
    encoding of text files
    etc
notify user about:
    deleted functions if used somewhere
    modified function parameter if function is used somewhere
    deleted/modified variables from Variables module if used somewhere
#>

$ErrorActionPreference = "stop"

# Write-Host is used to display output in GIT console

function _ErrorAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    Write-Host $message
    $null = [System.Windows.Forms.MessageBox]::Show($this, $message, 'ERROR', 'ok', 'Error')
    exit 1
}

function _WarningAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    $message = $message + "`n`nAre you sure you want to continue in commit?"

    Write-Host $message

    $msgBoxInput = [System.Windows.Forms.MessageBox]::Show($this, $message, 'Continue?', 'YesNo', 'Warning')
    switch ($msgBoxInput) {
        'No' {
            throw "##_user_cancelled_##"
        }
    }
}

function _GetFileEncoding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String] $path
        ,
        [Parameter(Mandatory = $False)]
        [System.Text.Encoding] $defaultEncoding = [System.Text.Encoding]::ASCII
    )

    process {
        [Byte[]]$bom = Get-Content -Encoding Byte -ReadCount 4 -TotalCount 4 -Path $path

        $encodingFound = $false

        if ($bom) {
            foreach ($encoding in [System.Text.Encoding]::GetEncodings().GetEncoding()) {
                $preamble = $encoding.GetPreamble()

                if ($preamble) {
                    # contains BOM
                    foreach ($i in 0..($preamble.Length - 1)) {
                        if ($preamble[$i] -ne $bom[$i]) {
                            break
                        } elseif ($i -eq ($preamble.Length - 1)) {
                            $encodingFound = $encoding
                        }
                    }
                }
            }
        }

        if (!$encodingFound) {
            $encodingFound = $defaultEncoding
        }

        $encodingFound
    }
}

function _startProcess {
    [CmdletBinding()]
    param (
        [string] $filePath,
        [string] $argumentList,
        [string] $workingDirectory = (Get-Location)
    )

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.WorkingDirectory = $workingDirectory
    $p.StartInfo.FileName = $filePath
    $p.StartInfo.Arguments = $argumentList
    [void]$p.Start()
    # $p.WaitForExit() # commented because it wait forever when git show HEAD:$file return something
    $p.StandardOutput.ReadToEnd()
    $p.StandardError.ReadToEnd()
}

try {
    # switch to repository root
    Set-Location $PSScriptRoot
    Set-Location ..
    $rootFolder = Get-Location
    $rootFolderName = ((Get-Location) -split "\\")[-1]

    try {
        $repoStatus = git.exe status -uno
        # files to commit
        $filesToCommit = @(git.exe diff --name-only --cached)
        # files to commit (action type included)
        $filesToCommitStatus = @(git.exe status --porcelain)
        # modified but not staged files
        $modifiedNonstagedFile = @(git.exe ls-files -m)
        # get added/modified/renamed files from this commit (but not deleted)
        $filesToCommitNoDEL = $filesToCommit | ForEach-Object {
            $item = $_
            if ($filesToCommitStatus -match ("(A|M|R)\s+[`"]?" + [Regex]::Escape($item))) {
                # transform relative path to absolute + replace unix slashes for backslashes
                Join-Path (Get-Location) $item
            }
        }
        # deleted commited files
        $commitedDeletedFile = @(git.exe diff --name-status --cached --diff-filter=D | ForEach-Object { $_ -replace "^D\s+" })
        # deleted commited ps1 scripts which can contain functions, that could have been used somewhere
        $commitedDeletedPs1 = @($commitedDeletedFile | Where-Object { $_ -match "\.ps1$" } | Where-Object { $_ -match "scripts2module/|scripts2root/profile\.ps1" })
    } catch {
        $err = $_
        if ($err -match "is not recognized as the name of a cmdlet") {
            _ErrorAndExit "Recency of repository can't be checked. Is GIT installed? Error was:`n$err"
        } else {
            _ErrorAndExit $err
        }
    }


    #
    # check that repository contains recent data
    # it's not possible to call git pull automatically because it ends with error 'fatal: cannot lock ref 'HEAD': is at cfd4a815a.. but expected 37936..'
    "- check, that repository contains actual data"
    if ($repoStatus -match "Your branch is behind") {
        _ErrorAndExit "Repository doesn't contain actual data. Pull them (git pull or sync icon in VSC) and try again."
    }


    #
    # check that commited file wasn't modified after adding to commit
    # it makes working with repository data a lot easier (checks, obtaining previsou file version etc)
    "- check, that commited file isn't modified outside staging area"
    if ($modifiedNonstagedFile -and $filesToCommit) {
        $modifiedNonstagedFile | ForEach-Object {
            if ($filesToCommit -contains $_) {
                _ErrorAndExit "It is not allowed to commit file which contains another non staged modifications ($_).`nAdd this file to staging area (+ icon) or remove these modifications."
            }
        }
    }


    #
    # throw error in case that commit deletes important files
    "- exit if commit deletes important files"
    if ($commitedDeletedFile | Where-Object { $_ -match "custom/customConfig\.ps1" }) {
        _ErrorAndExit "You are deleting customConfig, which is needed for Custom section to work. On 99,99% you don't want do this!"
    }

    if ($commitedDeletedFile | Where-Object { $_ -match "scripts2root/PS_env_set_up\.ps1" }) {
        _ErrorAndExit "You are deleting PS_env_set_up, which is needed for deploy of repository content to clients. On 99,99% you don't want do this!"
    }

    if ($commitedDeletedFile | Where-Object { $_ -match "modules/Variables/Variables\.psm1" }) {
        _ErrorAndExit "You are deleting module Variables, which contains important variables like RepoSyncServer, computerWithProfile etc. On 99,99% you don't want do this!"
    }


    #
    # checks that commit doesn't contain module, which is in the same time auto-generated from scripts2module
    # one of them would be replaced in DFS share
    "- check that commit doesn't contain module which is in the same time generated from content of scripts2module"
    if ($module2commit = $filesToCommit -match "^modules/") {
        # save module name
        $module2commit = ($module2commit -split "/")[1]
        # names of modules that are auto-generated
        $generatedModule = Get-ChildItem "scripts2module" -Directory -Name

        if ($conflictedModule = $module2commit | Where-Object { $_ -in $generatedModule }) {
            _ErrorAndExit "It's not possible to commit module ($($conflictedModule -join ', ')), which is in the same time generated from content of scripts2module."
        }
    }


    #
    # checks of variable $customConfig from customConfig.ps1
    # using AST instead of dot sourcing the file to avoid errors in case, that this script runs on non-domain joined computer and $customConfig contains dynamic variable that contains Active Directory data
    #region
    "- check of content of variable `$customConfig in customConfig.ps1"
    if ($filesToCommitNoDEL | Where-Object { $_ -match "custom\\customConfig\.ps1" }) {
        $customConfigScript = Join-Path $rootFolder "Custom\customConfig.ps1"
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($customConfigScript, [ref]$null, [ref]$null)
        $variables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        $configVar = $variables | ? { $_.variablepath.userpath -eq "customConfig" }
        if (!$configVar) {
            _ErrorAndExit "customConfig.ps1 is not defining variable `$customConfig. It has to, at least empty one."
        }

        # save right side of $customConfig ie array of objects
        $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression.elements
        if (!$configValueItem) {
            # on right side is just one item
            $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression
        }

        # check that value contains just psobject types
        if ($configValueItem | ? { $_.type.typename.name -ne "PSCustomObject" }) {
            _ErrorAndExit "In customConfig.ps1 script variable `$customConfig has to contain array of PSCustomObject items, which it hasn't."
        }

        # folders that are set in $customConfig
        $folderNames = @()

        $configValueItem | % {
            $item = $_
            $folderName = ($item.child.keyvaluepairs | ? { $_.item1.value -eq "folderName" }).item2.pipelineelements.extent.text -replace '"' -replace "'"

            # check that folderName don't contains subfolder
            #TODO dodelat podporu, aby to slo
            if ($folderName -match "\\") {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig defines folderName '$folderName'. FolderName can't contain \ in it's name."
            }

            $item.child.keyvaluepairs | % {
                $key = $_.item1.value
                $value = $_.item2.pipelineelements.extent.text -replace '"' -replace "'"

                # check that only valid keys are used
                $validKey = "computerName", "folderName", "customDestinationNTFS", "customSourceNTFS", "customLocalDestination", "customShareDestination", "copyJustContent", "scheduledTask"
                if ($key -and ($nonvalidKey = Compare-Object $key $validKey | ? { $_.sideIndicator -match "<=" } | Select-Object -ExpandProperty inputObject)) {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains unnaproved keys: ($($nonvalidKey -join ', ')). Approved are only: $($validKey -join ', ')"
                }

                # check that folderName, customLocalDestination, customShareDestination contains maximum of one value
                if ($key -in ("folderName", "customLocalDestination", "customShareDestination") -and ($value -split ',').count -ne 1) {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' in key $key more than one values. Values in key are: $($value -join ', ')"
                }

                # check that customShareDestination is in UNC format
                if ($key -match "customShareDestination" -and $value -notmatch "^\\\\") {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig doesn't contain in object that defines '$folderName' in key $key UNC path. Value of key is '$value'"
                }

                # check that customLocalDestination is local path format
                # regular expression is this basic on purpose, to enable use of variables
                if ($key -match "customLocalDestination" -and $value -match "^\\\\") {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig doesn't contain in object that defines '$folderName' in key $key local path. Value of key is '$value'"
                }

                # check that scheduled task defined in scheduledTask key have corresponding XML definition file in root of appropriate Custom folder
                if ($key -match "scheduledTask" -and $value) {
                    ($value -split ",").trim() | % {
                        $taskName = $_

                        $unixPath = 'custom/{0}/{1}.xml' -f ($folderName -replace "\\", "/"), $taskName
                        $alreadyInRepo = _startProcess git "show `"HEAD:$unixPath`""
                        if ($alreadyInRepo -match "^fatal: ") {
                            # XML isn't in GIT
                            $alreadyInRepo = ""
                        }
                        $windowsPath = $unixPath -replace "/", "\"
                        $inActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsPath) }
                        if (!$alreadyInRepo -and !$inActualCommit) {
                            _ErrorAndExit "In customConfig.ps1 object that defines '$folderName' in key $key, defines scheduled task '$taskName', but associated config file $windowsPath is neither in remote GIT repository\Custom\$folderName nor in actual commit (name is case sensitive!). It would cause error on clients."
                        }

                        # check (very basic) that XML really contains scheduled task definition
                        $XMLPath = Join-Path $rootFolder "Custom\$folderName\$taskName.xml"
                        [xml]$xmlDefinition = Get-Content $XMLPath
                        if (!$xmlDefinition.Task.RegistrationInfo.Author) {
                            _ErrorAndExit "In customConfig.ps1 object that defines '$folderName' in key $key, defines scheduled task '$taskName', but associated config file $windowsPath doesn't contain valid data (Author tag is missing). This would cause error on clients, fix it."
                        }

                        # warn if scheduled task name defined in XML file differs from name in CustomConfig
                        # won't work on scheduled task definition created on Windows Server 2012, because it doesn't contain URI tag
                        $taskNameInXML = $xmlDefinition.task.RegistrationInfo.URI -replace "^\\"
                        if ($taskNameInXML -and ($taskName -ne $taskNameInXML)) {
                            _WarningAndExit "In customConfig.ps1 object that defines '$folderName' in key $key, defines scheduled task '$taskName', but associated config file $windowsPath defines task '$taskNameInXML'.`nBeware, that this task will be created with name '$taskName'."
                        }
                    }
                }
            }

            # list of all object keys
            $keys = $item.child.keyvaluepairs.item1.value
            # throw an error in case that mandatory key folderName is missing
            if ($keys -notcontains "folderName") {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig doesn't contain mandatory key folderName at some of objects."
            }

            $folderNames += $folderName

            # warn about potential conflict in NTFS rights that should be set
            if ($keys -contains "computerName" -and $keys -contains "customSourceNTFS") {
                _WarningAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' keys: computerName, customSourceNTFS at the same time. This is safe only in case, when customSourceNTFS contains all computers from computerName (and more)."
            }

            # check that just supported keys are used together
            if ($keys -contains "copyJustContent" -and $keys -contains "computerName" -and $keys -notcontains "customLocalDestination") {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' copyJustContent and computerName, but no customLocalDestination. To destination folder (Scripts) are always copied whole folders."
            }
            if ($keys -contains "copyJustContent" -and $keys -contains "customDestinationNTFS" -and ($keys -contains "customLocalDestination" -or $keys -contains "customShareDestination")) {
                # when copy to default destinationn (Windows\Scripts) copyJustContent is ignored, so rights in customDestinationNTFS will be set
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' customDestinationNTFS, but that's not possible, because copyJustContent is also used and therefore NTFS rights are not configuring."
            }

            # check that value in folderName is existing folder in Custom directory
            # in actual commit or in cloud GIT repository
            $unixFolderPath = 'custom/{0}' -f ($folderName -replace "\\", "/")
            $folderAlreadyInRepo = _startProcess git "show `"HEAD:$unixFolderPath`""
            if ($folderAlreadyInRepo -match "^fatal: ") {
                # folder isn't in cloud GIT
                $folderAlreadyInRepo = ""
            }
            $windowsFolderPath = $unixFolderPath -replace "/", "\"
            $folderInActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsFolderPath) }
            if (!$folderAlreadyInRepo -and !$folderInActualCommit) {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains object that defines '$folderName', but given folder is neither in remote GIT repository\Custom nor in actual commit (name is case sensitive!). It would cause error on clients."
            }
        }

        if ($folderNames -notcontains "Repo_sync") {
            _ErrorAndExit "In customConfig.ps1 script variable `$customConfig has to contain PSCustomObject that defines Repo_sync. It is necesarry for transfer data from MGM server to DFS share works."
        }

        # warn about folders that are defined multiple times
        $ht = @{ }
        $folderNames | % { $ht["$_"] += 1 }
        $duplicatesFolder = $ht.keys | ? { $ht["$_"] -gt 1 } | % { $_ }
        if ($duplicatesFolder) {
            _ErrorAndExit "In customConfig.ps1 script variable `$customConfig defines folderName multiple times '$($duplicatesFolder -join ', ')'."
            #TODO dodelat podporu pro definovani jedne slozky vickrat
            # chyba pokud definuji computerName (prepsaly by se DFS permissn), leda ze bych do repo_sync dodelal merge tech prav ;)
            # chyba pokud definuji u jednoho computerName a druheho customSourceNTFS (prepsaly by se DFS permissn)
            # _WarningAndExit "In customConfig.ps1 script variable `$customConfig definuje vickrat folderName '$($duplicatesFolder -join ', ')'. Budte si 100% jisti, ze nedojde ke konfliktu kvuli prekryvajicim nastavenim.`n`nPokracovat?"
        }
    }
    #endregion



    #
    # checks of variable $modulesConfig from modulesConfig.ps1
    # using AST instead of dot sourcing the file to avoid errors in case, that this script runs on non-domain joined computer and $modulesConfig contains dynamic variable that contains Active Directory data
    #region
    "- check content of variable `$modulesConfig in modulesConfig.ps1"
    if ($filesToCommitNoDEL | Where-Object { $_ -match "modules\\modulesConfig\.ps1" }) {
        $modulesConfigScript = Join-Path $rootFolder "modules\modulesConfig.ps1"
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($modulesConfigScript, [ref]$null, [ref]$null)
        $variables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        $configVar = $variables | ? { $_.variablepath.userpath -eq "modulesConfig" }
        if (!$configVar) {
            _ErrorAndExit "modulesConfig.ps1 doesn't define variable `$modulesConfig."
        }

        # save right side of $modulesConfig ie array of objects
        $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression.elements
        if (!$configValueItem) {
            # on right side is just one item
            $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression
        }

        if ($configValueItem) {
            # check that value contains just psobject types
            if ($configValueItem | ? { $_.type.typename.name -ne "PSCustomObject" }) {
                _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig has to contain array of PSCustomObject items."
            }

            # folders that are set in $modulesConfig
            $folderNames = @()

            $configValueItem | % {
                $item = $_
                $folderName = ($item.child.keyvaluepairs | ? { $_.item1.value -eq "folderName" }).item2.pipelineelements.extent.text -replace '"' -replace "'"

                # check that folderName don't contains subfolder
                if ($folderName -match "\\") {
                    _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig key folderName '$folderName' contains '\', but that's not allowed."
                }

                $item.child.keyvaluepairs | % {
                    $key = $_.item1.value
                    $value = $_.item2.pipelineelements.extent.text -replace '"' -replace "'"

                    # check that only valid keys are used
                    $validKey = "computerName", "folderName"
                    if ($key -and ($nonvalidKey = Compare-Object $key $validKey | ? { $_.sideIndicator -match "<=" } | Select-Object -ExpandProperty inputObject)) {
                        _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig contains unnaproved keys ($($nonvalidKey -join ', ')). Approved are just: $($validKey -join ', ')"
                    }

                    # check that folderName contains maximum of one value
                    if ($key -in ("folderName") -and ($value -split ',').count -ne 1) {
                        _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig contains in object that defines '$folderName' in key $key more than one value. Value of key is $($value -join ', ')"
                    }
                }

                $keys = $item.child.keyvaluepairs.item1.value
                # throw an error in case that mandatory key folderName is missing
                if ($keys -notcontains "folderName") {
                    _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig doesn't contain mandatory key folderName at some object."
                }

                $folderNames += $folderName

                # check that value in folderName is existing folder in Modules or scripts2module directory
                # in actual commit or in cloud GIT repository
                $unixFolderPath = ('modules/{0}' -f ($folderName -replace "\\", "/")), ('scripts2module/{0}' -f ($folderName -replace "\\", "/"))
                $folderAlreadyInRepo = ''
                $folderInActualCommit = ''
                $unixFolderPath | % {
                    if (!$folderAlreadyInRepo) {
                        $folderAlreadyInRepo = _startProcess git "show `"HEAD:$_`""
                        if ($folderAlreadyInRepo -match "^fatal: ") {
                            # folder isn't in cloud GIT
                            $folderAlreadyInRepo = ''
                        }
                    }

                    $windowsFolderPath = $_ -replace "/", "\"
                    if (!$folderInActualCommit) {
                        $folderInActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsFolderPath) }
                    }
                }

                if (!$folderAlreadyInRepo -and !$folderInActualCommit) {
                    _WarningAndExit "In modulesConfig.ps1 script variable `$modulesConfig contains object that defines '$folderName', but given folder is neither in GIT repository\Modules or repository\scripts2module nor in actual commit (name is case sensitive!)."
                }
            }

            # warn about folders that are defined multiple times
            $ht = @{ }
            $folderNames | % { $ht["$_"] += 1 }
            $duplicatesFolder = $ht.keys | ? { $ht["$_"] -gt 1 } | % { $_ }
            if ($duplicatesFolder) {
                _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig defines folderName multiple times '$($duplicatesFolder -join ', ')'."
            }
        } else {
            "   - `$modulesConfig contains nothing"
        }
    }
    #endregion


    #
    # check commited script files encoding
    "- check encoding ..."
    $textFilesToCommit = $filesToCommitNoDEL | Where-Object { $_ -match '\.ps1$|\.psm1$|\.psd1$|\.txt$' }
    if ($textFilesToCommit) {
        # warn about scripts encoded in GIT unsupported encoding
        $textFilesToCommit | ForEach-Object {
            $fileEnc = (_GetFileEncoding $_).bodyName
            if ($fileEnc -notin "US-ASCII", "ASCII", "UTF-8" ) {
                _WarningAndExit "File $_ is encoded in '$fileEnc', so git diff wont work.`nIdeal is to save it using UTF-8 with BOM, or UTF-8."
            }
        }
    }


    #
    # various checks of ps1 and psm1 files
    "- check syntax, problematic characters, FIXME, best practices, format, name , changes in function parameters,..."
    $psFilesToCommit = $filesToCommitNoDEL | Where-Object { $_ -match '\.ps1$|\.psm1$' }
    if ($psFilesToCommit) {
        try {
            $null = Get-Command Invoke-ScriptAnalyzer
        } catch {
            _ErrorAndExit "Module PSScriptAnalyzer isn't available (respective command Invoke-ScriptAnalyzer). It's not possible to check syntax of ps1 scripts."
        }

        $ps1Error = @()
        $ps1CompatWarning = @()

        $psFilesToCommit | ForEach-Object {
            $script = $_

            #
            # check that script doesn't contain non ASCII chars that would break parser (ie EN DASH or EM DASH instead of dash etc)
            # such chars in combination with UTF8 cause various parse errors
            $problematicChar = [char]0x2013, [char]0x2014 # en dash, em dash
            $regex = $problematicChar -join '|'
            $problematicLine = (Get-Content $script) -match $regex
            if ($problematicLine) {
                $problematicLine = $problematicLine.Trim()
                _ErrorAndExit "File $([System.IO.Path]::GetFileName($script)) contains problematic character (en dash instead of dash?).`nOn row:`n`n$($problematicLine -join "`n`n")"
            }

            #
            # check syntax errors and best practices compliance
            Invoke-ScriptAnalyzer $script -Settings .\PSScriptAnalyzerSettings.psd1 -Verbose | % {
                if ($_.RuleName -in "PSUseCompatibleCommands", "PSUseCompatibleSyntax", "PSAvoidUsingComputerNameHardcoded" -and $_.Severity -in "Warning", "Error", "ParseError") {
                    $ps1CompatWarning += $_
                } elseif ($_.Severity -in "Error", "ParseError") {
                    $ps1Error += $_
                }
            }


            #
            # warn if script contains FIXME comment
            # cross sign by its [char] reprezentation so script dont warns about itself
            if ($fixme = Get-Content $script | ? { $_ -match ("\s*" + [char]0x023 + "\s*" + "FIXME\b") }) {
                _WarningAndExit "File $script contains FIXME:`n$($fixme.trim() -join "`n")."
            }

            #
            # check of scripts that are used to generate modules
            if ($script -match "\\$rootFolderName\\scripts2module\\") {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)

                $wrgMessage = "File $script is not in correct format. It has to contain just definition of one function (with the same name). Beside that, script can also contains: Set-Alias, comments or requires statement!"

                #
                # check that just END block exists
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    _ErrorAndExit $wrgMessage
                }

                #
                # check that script doesn't contain code, that would be skipped anyway when module generation occurs
                $ast.EndBlock.Statements | ForEach-Object {
                    if ($_.gettype().name -ne "FunctionDefinitionAst" -and !($_ -match "^\s*Set-Alias .+")) {
                        _ErrorAndExit $wrgMessage
                    }
                }

                # save function that this script defines
                $functionDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        # Class methods have a FunctionDefinitionAst under them as well, but we don't want them.
                        ($PSVersionTable.PSVersion.Major -lt 5 -or
                            $ast.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst])
                    }, $false)

                #
                # check that just one function is defined
                if ($functionDefinition.count -ne 1) {
                    _ErrorAndExit "File $script either doesn't contain any function definition or contain more than one."
                }

                #
                # check that ps1 script is named same as the function it defines
                $fileName = [System.IO.Path]::GetFileNameWithoutExtension($script)
                $functionName = $functionDefinition.name
                if ($fileName -ne $functionName) {
                    _ErrorAndExit "File $script has to be named exactly the same as function that it defines ($functionName)."
                }

                #
                # warn about functions whose parameters were changed in case such function is used somewhere in repository
                $actParameter = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | Where-Object { $_.parent.parent.name -eq $functionName }
                $actParameter = $actParameter.parameters | Select-Object @{n = 'name'; e = { $_.name.variablepath.userpath } }, @{n = 'value'; e = { $_.defaultvalue.extent.text } }, @{ n = 'type'; e = { $_.staticType.name } }
                # AST is used to get all parameters that function had in previous version
                # absolute path to script is converted to relative with unix slashes
                $scriptUnixPath = $script -replace ([regex]::Escape((Get-Location))) -replace "\\", "/" -replace "^/"
                $lastCommitContent = _startProcess git "show HEAD:$scriptUnixPath"
                if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
                    Write-Warning "Previous version of $scriptUnixPath cannot be found (to check modified parameters)."
                } else {
                    $AST = [System.Management.Automation.Language.Parser]::ParseInput(($lastCommitContent -join "`n"), [ref]$null, [ref]$null)
                    $prevParameter = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | Where-Object { $_.parent.parent.name -eq $functionName }
                    $prevParameter = $prevParameter.parameters | Select-Object @{n = 'name'; e = { $_.name.variablepath.userpath } }, @{n = 'value'; e = { $_.defaultvalue.extent.text } }, @{ n = 'type'; e = { $_.staticType.name } }
                }

                if ($actParameter -and $prevParameter -and (Compare-Object $actParameter $prevParameter -Property name, value, type)) {
                    $escFuncName = [regex]::Escape($functionName)
                    # get all files where changed function is mentioned (even in comments)
                    $fileUsed = git.exe grep --ignore-case -l "\b$escFuncName\b"
                    # filter scripts where this function is defined
                    $fileUsed = $fileUsed | Where-Object { $_ -notmatch "/$functionName\.ps1" }

                    if ($fileUsed) {
                        $fileUsed = $fileUsed -replace "/", "\"

                        _WarningAndExit "Function $functionName which has changed parameters is used in following scripts:`n$($fileUsed -join "`n")"
                    }
                }
            }
        }

        if ($ps1Error) {
            # ps1 scripts in commit has errors
            if (!($ps1Error | Where-Object { $_.ruleName -ne "PSAvoidUsingConvertToSecureStringWithPlainText" })) {
                # ps1 scripts contain just errors about using plaintext password
                $ps1Error = $ps1Error | Select-Object -ExpandProperty ScriptName -Unique
                _WarningAndExit "Following scripts are using ConvertTo-SecureString, which is unsafe:`n$($ps1Error -join "`n")"
            } else {
                # ps1 scripts contain severe errors
                $ps1Error = $ps1Error | Select-Object Scriptname, Line, Column, Message | Format-List | Out-String -Width 1200
                _ErrorAndExit "Following serious misdemeanors agains best practices were found:`n$ps1Error`n`nFix and commit again."
            }
        }

        if ($ps1CompatWarning) {
            # ps1 scripts in commit contain commands that are not compatible with Powershell version set in .vscode\PSScriptAnalyzerSettings.psd1
            $ps1CompatWarning = $ps1CompatWarning | Select-Object Scriptname, Line, Column, Message | Format-List | Out-String -Width 1200
            _WarningAndExit "Compatibility issues were found:`n$ps1CompatWarning"
        }
    } # end of ps1 and psm1 checks


    #
    # warn about ps1 script that define function, in case it is used somewhere in repository
    if ($commitedDeletedPs1) {
        $commitedDeletedPs1 = $commitedDeletedPs1 -replace "/", "\"
        $commitedDeletedPs1 | Where-Object { $_ -match "scripts2module\\" } | ForEach-Object {
            $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_)
            #$fileFuncUsed = git grep --ignore-case -l "^\s*[^#]*\b$funcName\b" # v komentari mi nevadi, na viceradkove ale upozorni :( HROZNE POMALE!
            # ziskani vsech souboru, kde je mazana funkce pouzita (ale i v komentarich, proto zobrazim vyzvu a kazdy si musi zkontrolovat sam)
            # get all files where changed function is mentioned (even in comments)
            $escFuncName = [regex]::Escape($funcName)
            $fileFuncUsed = git.exe grep --ignore-case -l "\b$escFuncName\b"
            if ($fileFuncUsed) {
                $fileFuncUsed = $fileFuncUsed -replace "/", "\"

                _WarningAndExit "Deleted function $funcName is used in following scripts:`n$($fileFuncUsed -join "`n")"
            }
        }
        #TODO kontrola funkci v profile.ps1? viz AST sekce https://devblogs.microsoft.com/scripting/learn-how-it-pros-can-use-the-powershell-ast/
    }


    #
    # checks of module Variables
    if ([string]$variablesModule = $filesToCommit -match "Variables\.psm1") {
        "- check module Variables ..."

        #
        # get all variables defined in module using AST
        $varToExclude = 'env:|ErrorActionPreference|WarningPreference|VerbosePreference|^\$_$'
        $variablesModuleUnixPath = $variablesModule
        $variablesModule = Join-Path $rootFolder $variablesModule
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($variablesModule, [ref]$null, [ref]$null)
        $actVariables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        # all defined variables
        $actVariables = $actVariables | Where-Object { $_.parent.left -or $_.parent.type } | Select-Object @{n = "name"; e = { $_.variablepath.userPath } }, @{n = "value"; e = {
                if ($value = $_.parent.right.extent.text) {
                    $value
                } else {
                    # it is typed variable
                    $_.parent.parent.right.extent.text
                }
            }
        }
        # because of later comparison unify newline symbol (CRLF vs LF)
        $actVariables = $actVariables | Select-Object name, @{n = "value"; e = { $_.value.Replace("`r`n", "`n") } }
        if ($varToExclude) {
            $actVariables = $actVariables | Where-Object { $_.name -notmatch $varToExclude }
        }

        # get all variables defined in previous module version using AST
        $lastCommitContent = _startProcess git "show HEAD:$variablesModuleUnixPath"
        if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
            Write-Warning "Previous version of module Variables cannot be found (to check changed variables)."
        } else {
            $AST = [System.Management.Automation.Language.Parser]::ParseInput(($lastCommitContent -join "`n"), [ref]$null, [ref]$null)
            $prevVariables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
            # all defined variables in previous module version
            $prevVariables = $prevVariables | Where-Object { $_.parent.left -or $_.parent.type } | Select-Object @{n = "name"; e = { $_.variablepath.userPath } }, @{n = "value"; e = {
                    if ($value = $_.parent.right.extent.text) {
                        $value
                    } else {
                        # it is typed variable
                        $_.parent.parent.right.extent.text
                    }
                }
            }
            # because of later comparison unify newline symbol (CRLF vs LF)
            $prevVariables = $prevVariables | Select-Object name, @{n = "value"; e = { $_.value.Replace("`r`n", "`n") } }
            if ($varToExclude) {
                $prevVariables = $prevVariables | Where-Object { $_.name -notmatch $varToExclude }
            }
        }


        #
        # check that module doesn't define one variable multiple times
        $duplicateVariable = $actVariables | Group-Object name | Where-Object { $_.count -gt 1 } | Select-Object -ExpandProperty name
        if ($duplicateVariable) {
            _ErrorAndExit "In module Variables are following variables defined more than once: $($duplicateVariable -join ', ')`n`nFix and commit again."
        }


        #
        # warn about deleted variables that are used somewhere in repository
        if ($actVariables -and $prevVariables -and ($removedVariable = $prevVariables.name | Where-Object { $_ -notin $actVariables.name })) {
            $removedVariable | ForEach-Object {
                $varName = "$" + $_
                $escVarName = [regex]::Escape($varName)
                # get all files where deleted variable is mentioned (even in comments)
                $fileUsed = git.exe grep --ignore-case -l "$escVarName\b"
                # filter Variables module itself
                $fileUsed = $fileUsed | Where-Object { $_ -notmatch "/Variables\.psm1" }
                if ($fileUsed) {
                    $fileUsed = $fileUsed -replace "/", "\"

                    _WarningAndExit "Deleted variable $varName is used in following scripts:`n$($fileUsed -join "`n")"
                }
            }
        }


        #
        # warn about modified variables in case they are used somewhere in repository
        # to be able to use Compare-Object, just variables that can be compared are left
        if ($actVariables -and $prevVariables -and ($modifiedVariable = Compare-Object $actVariables ($prevVariables | Where-Object { $_.name -notin $removedVariable } ) -Property value -PassThru | Select-Object -ExpandProperty name -Unique)) {
            $modifiedVariable | ForEach-Object {
                $varName = "$" + $_
                $escVarName = [regex]::Escape($varName)
                # get all files where modified variable is mentioned (even in comments)
                $fileUsed = git.exe grep --ignore-case -l "$escVarName\b"
                # filter module Variable
                $fileUsed = $fileUsed | Where-Object { $_ -notmatch "/Variables\.psm1" }

                if ($fileUsed) {
                    $fileUsed = $fileUsed -replace "/", "\"

                    _WarningAndExit "Modified variable $varName is used in following scripts:`n$($fileUsed -join "`n")"
                }
            }
        }


        #
        # throw an error in case module Variables doesn't contain necessarry command for export of variables
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($variablesModule, [ref]$null, [ref]$null)
        $commands = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.CommandAst ] }, $true)
        if (!($commands.extent.text -match "Export-ModuleMember")) {
            _ErrorAndExit "Module Variables doesn't export any variables using Export-ModuleMember.`n`nFix and commit again."
        }
    } # end of module Variable checks


    #
    # again check that data in repository are recent
    # it is possible that somebody else could pushed new commit when checks were running
    $repoStatus = git.exe status -uno
    if ($repoStatus -match "Your branch is behind") {
        _ErrorAndExit "Repository doesn't contain actual data. Pull them (git pull or sync icon in VSC) and try again."
    }
} catch {
    $err = $_
    # output also to GIT console in VSC
    $err
    if ($err -match "##_user_cancelled_##") {
        # user initiated commit cancellation
        exit 1
    } else {
        _ErrorAndExit "There was an error:`n$err`n`nFix and commit again."
    }
}

"DONE"