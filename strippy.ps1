<#
.SYNOPSIS
    Tool for sanitising utf8 encoded files based on configured "indicators"

.DESCRIPTION
    Use this tool to automate the replacement of sensitive data in text files with generic strings.
    While intended for use with log files this tool will work with text filesa as a whole.

    In order to use this tool effectively you will need to be proficient with regex. 
    Regex is used to filter out sensitive pieces of data from log files and replace it with a place holder.

    To start creating your own sensitive data indicators you will need to use a config file that can be generated by using the -MakeConfig flag.
    Add regex strings to it, ensuring that the part of the string you want to replace is the first group in the regex. 
    That group will then be replaced with a generic string of your choice.
    An example for IP addresses is included in the generated config file.

    Make use of the tool by reading the examples from: get-help .\strippy.ps1 -examples
    
    If you haven't already then you'll need to change your execution policy to run this tool. 
    You can do this temporarily by using the following:
        powershell [-noexit] -executionpolicy Unrestricted -File .\strippy.ps1 <args>
    Or permanently by opening Powershell and running the following:
        Set-ExecutionPolicy Unrestricted https://ss64.com/ps/set-executionpolicy.html

.EXAMPLE
    C:\PS> .\strippy.ps1 .\logs

    This is the typical usecase and will sanitise only the files directly in .\logs using a default config file.
    Output files will be in the .\logs.sanitised folder and the keylist created for the logs will be found directory you the script.

.EXAMPLE
    C:\PS> .\strippy.ps1 .\logs\server.1.log

    In this case only one file has been specified for sanitisation. The output in this case would be to .\logs\server.1.sanitised.log file and a keylist file .\KeyList.txt

.EXAMPLE
    C:\PS> .\strippy.ps1 ..\otherlogs\servers\oldlog.log -KeyFile .\KeyList.txt

    This would process the oldlog.log file like any other file, but will load in the keys already found from a key list file. This means you can process files at different times but still have their keys matchup. Once done, this usecase will output a keylist that contains all the keys from KeyList.txt and any new keys found in the oldlog.log file.

.EXAMPLE
    C:\PS> .\strippy.ps1 .\logs -Recurse

    If you need to sanitise an entire file tree, then use the -Recurse flag to iterate through each file in a folder and it's subfolders.

.EXAMPLE
    C:\PS> .\strippy.ps1 "C:\Program Files\Dynatrace\CAS\Server\logs" -Recurse -Silent -out "C:\sanitised-$(get-date -UFormat %s)"

    This example shows how you might integrate strippy in an automation scheme. The -Silent flag stops output to stdout, preventing the need for a stdout redirect. The -out flag allows redirection of the sanitised files to a custom folder.

.NOTES
    Author: Michael Ball
    Version: 170710
    Compatability: Powershell 3+

.LINK
    https://github.com/cavejay/Strippy
#>

# Todo
# Dealing with selections of files a la "server.*.log" or similar
# Make -Silent print output to a file? 
# Have option for diagnotics file or similar that shows how many times each rule was hit
# Print/Sanitising sometimes breaks?
# Keys found at the end of lines contain a '...' - not all the time though?
# Publish to dxs wiki
# Support .zips as well.
# Have a blacklist of regexs.
# Nicer gui for above showing how far through each process/file is.
# Switch used to create a single file strippy. ie, edit the script's code with the config rules etc.
# Update the config file to use a nicer ini alternative. (Branch for this now)
# More intellient capitalisation resolution.
# catch all for empty tokens
# Move from jobs to runspaces?

<# Maintenance Todo list
    - Time global sanitise against running all the rules against each and every line in the files.    
    - use powershell options for directory and file edits
#>

[CmdletBinding()]
param (
    # The File or Folder you wish to sanitise
    [string] $File, 
     # The tool will run silently, without printing to the terminal and exit with an error if it needed user input
    [switch] $Silent,
    # Looks for log files throughout a directory tree rather than only in the first level
    [Switch] $Recurse = $false, 
    # Destructively sanitises the file. There is no warning for this switch. If you use it, it's happened.
    # [switch] $InPlace, 
    # Creates a barebones strippyConfig.json file for the user to fill edit
    [switch] $MakeConfig, 
    # A shortcut for -AlternateKeyListOutput
    [string] $keyout, 
    # Specifies an alternate name and path for the keylist file
    [string] $AlternateKeyListOutput = $keyout,
    # A shortcut for -AlternateOutputFolder 
    [String] $out, 
    # Specifies an alternate path or file for the sanitised file
    [String] $AlternateOutputFolder = $out, 
    # Specifies a previously generated keylist file to import keys from for this sanitisation
    # [String] $KeyFile, 
    # Specifies a config file to use rather than the default local file or no file at all.
    [String] $Config
)

# Special Variables: (Not overwritten by config files)
# If this script is self contained then all config is specified in the script itself and config files are not necessary or requested for. 
# This cuts down the amount of files necessary to move between computers and makes it easier to give to someone and say "run this"
$SelfContained = $false

## Variables: (Over written by any config file)
$IgnoredStrings = @('/0:0:0:0:0:0:0:0','0.0.0.0','127.0.0.1','name','applications')
$SanitisedFileFirstline = "This file was Sanitised at $( $(Get-Date).toString() ).`n==`n`n"
$KeyListFirstline = "This keylist was created at $( $(Get-Date).toString() ).`n"

######################################################################
# Important Pre-script things like usage, setup and commands that change the flow of the tool

# General config 
$PWD = Get-Location

# Flags
# usernames, hostnames, ip addresses ## DSN is different!
$flags = New-Object System.Collections.ArrayList
$defaultFlags = New-Object System.Collections.ArrayList
$defaultFlags.AddRange(@(
    [System.Tuple]::Create("((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5]))[^\d]", 'Address'),
    [System.Tuple]::Create("\\\\([\w\-.]*?)\\", "Hostname")

        # Format: (regex, Label to Replace)
        # 'db users' JDBC_USER: <user>
    ))

# Output Settings
$oldInfoPref = $InformationPreference
if ($Silent) { $InformationPreference = "ContinueSilently" } else { $InformationPreference = "Continue" }

if ( $Verbose -and -not $Silent) {
    $oldVerbosityPref = $VerbosePreference
    $oldDebugPref = $DebugPreference
    $VerbosePreference = 'Continue'
    $DebugPreference = 'Continue'
}

# Check if we're _just_ creating a default config file
if ( $MakeConfig ) {
    $confloc = "$( Get-Location )\strippyConfig.json"
    $defaultConfig = '{
    "_Comment": "These are the defaults. You should alter them. Please go do",
    "_version": 0.1,
    "UseMe": %useme%,
    "IgnoredStrings": [%ignoredstrings%],
    "SanitisedFileFirstLine": "%logfirstline%",
    "KeyListFirstline": "%keyfirstline%",

    "KeyFile": "",
    "indicators": [
        %indicators%
    ]
}
'
    if ( $SelfContained ) {
        Write-Verbose "In single file mode. Exporting most of the config from file"
        # In here we export all the variables we've set above and such.
        $defaultConfig = $defaultConfig -replace '%useme%', "false"
        $defaultConfig = $defaultConfig -replace '%ignoredstrings%', "`"$($IgnoredStrings -join '", "')`""
        $defaultConfig = $defaultConfig -replace '%logfirstline%', ""
        $defaultConfig = $defaultConfig -replace '%keyfirstline%', ""
        $t_ = $flags | Foreach-Object {"[`"$($_.Item1)`", `"$($_.Item2)`"]"}
        $defaultConfig = $defaultConfig -replace '%indicators%', $($t_ -join ', ')
    } else {
        # Fill areas of the default config
        $defaultConfig = $defaultConfig -replace '%useme%', "true"
        $defaultConfig = $defaultConfig -replace '%ignoredstrings%', "`"/0:0:0:0:0:0:0:0`", `"0.0.0.0`", `"127.0.0.1`", `"name`", `"applications`""
        $defaultConfig = $defaultConfig -replace '%logfirstline%', "This file was Sanitised at %date%``n==``n``n"
        $defaultConfig = $defaultConfig -replace '%keyfirstline%', "This keylist was created at %date%.``n"
        $defaultConfig = $defaultConfig -replace '%indicators%', "[`"Some Regex String here`", `"Replacement here`"], 
        [`"((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5]))[^\d]`", `"Address`"],
        [`"\\\\([\w\-.]*?)\\`", `"Hostname`"]"
    }


    # Check to make sure we're not overwriting someone's config file
    if ( Test-Path $( $confloc ) ) {
        Write-Information "A config file already exists. Would you like to overwrite it with the default?"
        $ans = Read-Host "y/n> (n) "
        if ( $ans -ne 'y' ) {
            Write-Information "Didn't overwrite the current config file"
            exit 0
        } else {
            Write-Information "You overwrote a config file that contained the following. Use this to recreate the file if you stuffed up:"
            Write-Information "$([IO.file]::ReadAllText($confloc))"
        }
    }

    $defaultConfig | Out-File -Encoding ascii $confloc
    Write-Information "Generated config file: $confloc"
    exit 0
}

# Usage
if ( $File -eq "" ) {
    Get-Help $(join-path $(Get-Location) $MyInvocation.MyCommand.Name)
    exit 0
}

# Check we're dealing with an actual file
if ( -not (Test-Path $File) ) {
    Write-Error "$File does not exist"
    exit -1
}

#######################################################################################33
# Function definitions

function eval-config-string ([string] $str) {
    $out = "$str"
    if (($str[0..4] -join '') -eq "eval:") {
        Write-Verbose "config string |$str| needs to be eval'd"
        $out = $ExecutionContext.InvokeCommand.ExpandString(($str -split "eval:")[1])
        Write-Verbose "Eval'd to: $out"
    } else {
        Write-Verbose "Config string |$str| was not eval'd"
    }
    return $out
}

function output-keylist ($finalKeyList, $listOfSanitisedFiles) {
    $kf = join-path $PWD "KeyList.txt"
    
    # We have Keys?
    if ( $finalKeyList.Keys.Count -ne 0) {
        # Do we need to put them somewhere else?
        if ( $AlternateKeyListOutput ) {
            Set-Location $PWD
            New-Item -Force "$AlternateKeyListOutput" | Out-Null
            $kf = $( Get-Item "$AlternateKeyListOutput" ).FullName
        }

        Write-Information "`nExporting KeyList to $kf"
        $KeyOutfile = (eval-config-string $KeyListFirstline) + $( $finalKeyList | Out-String )
        $KeyOutfile += "List of files using this Key:`n$( $listOfSanitisedFiles | Out-String)"
        $KeyOutfile | Out-File -Encoding ascii $kf
    } else {
        Write-Information "No Keys were found to show or output. There will be no key file"
    }
}

# This should be run before the script is closed
function Clean-Up () {
    # output-keylist # This should no longer be needed.

    ## Cleanup
    $VerbosePreference = $oldVerbosityPref
    $DebugPreference = $oldDebugPref
    $InformationPreference = $oldInfoPref
    Set-Location $PWD
    exit
}

## Process Config file 
function proc-config-file ( $cf ) {
    Write-Verbose "Added '\'s where necessary"
    # add another backslash whereever necessary
    $cf = $cf -replace '\\', '\\'

    Write-Verbose "Swapping out date aliases"
    $cf = $cf -replace '%date%', $( $(Get-Date).ToString() )

    Write-Verbose "Attemping JSON -> PSObject transform"
    # turn into PS object
    try {
        $c = ConvertFrom-Json $cf -ErrorAction Stop
    } catch {
        Write-Error "Config file error:`n$_"
        exit 0
    }

    Write-Verbose "Applying Config to script"
    # Split up and assign all the pieces to their variables
    $script:KeyListFirstline = $c.KeyListFirstLine
    $script:KeyFile = $c.KeyFile
    $script:SanitisedFileFirstline = $c.SanitisedFileFirstline
    $script:IgnoredStrings = $c.IgnoredStrings
    foreach ($indicator in $c.indicators) {
        $script:flags.Add(
            [System.Tuple]::Create($indicator[0], $indicator[1])
        ) | Out-Null
    }
}

## Process a KeyFile
# function proc-keyfile ( $kf ) {
#     $kfLines = [IO.file]::ReadAllLines($kf)

#     # Find length of keylist
#     $startOfFileList = $kfLines.IndexOf("List of files using this Key:")+1
#     $endOfKeyList = $startOfFileList - 4

#     if ( $startOfFileList -eq 0 ) {
#         write-when-normal '' 
#         Write-Error "Invalid format for KeyFile ($KeyFile)`nCan't find list of output files"
#         exit -1
#     }

#     $dataLines = $kfLines[4..$endOfKeyList]
#     foreach ($d in $dataLines) {
#         $d = $d -replace '\s+', ' ' -split "\s"
#         if ( $d.Length -ne 3) {
#             write-when-normal '' 
#             Write-Error "Invalid format for KeyFile ($KeyFile)`nKey and Value lines are invalid"
#             exit -1
#         }

#         write-when-normal -NoNewline '.'
#         Write-Verbose "Found Key: $($d[0]) & Value: $($d[1])"
#         $k = $d[0]; $v = $d[1]

#         if ( $k -eq "" -or $v -eq "") {
#             write-when-normal '' 
#             Write-Error "Invalid format for KeyFile ($KeyFile)`nKeys and Values cannot be empty"
#             exit -1
#         }

#         $key[$k] = $v
#     }
#     write-when-normal '.'

#     foreach ($d in $kfLines[$startOfFileList..$( $kfLines.Length - 2 )]) {
#         $script:listOfSanitisedFiles += $d;
#     }
# }

function Get-FileEncoding {
    # This function is only included here to preserve this as a single file.
    # Original Source: http://blog.vertigion.com/post/110022387292/powershell-get-fileencoding
    [CmdletBinding()]
    param (
        [Alias("PSPath")]
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]$Path,

        [Parameter(Mandatory = $False)]
        [System.Text.Encoding]$DefaultEncoding = [System.Text.Encoding]::ASCII
    )
    process {
        [Byte[]]$bom = Get-Content -Encoding Byte -ReadCount 4 -TotalCount 4 -Path $Path
        $encoding_found = $false
        foreach ($encoding in [System.Text.Encoding]::GetEncodings().GetEncoding()) {
            $preamble = $encoding.GetPreamble()
            if ($preamble) {
                foreach ($i in 0..$preamble.Length) {
                    if ($preamble[$i] -ne $bom[$i]) {
                        break
                    } elseif ($i -eq $preable.Length) {
                        $encoding_found = $encoding
                    }
                }
            }
        }
        if (!$encoding_found) {
            $encoding_found = $DefaultEncoding
        }
        $encoding_found
    }
}

function Get-MimeType() {
    # From https://gallery.technet.microsoft.com/scriptcenter/PowerShell-Function-to-6429566c#content
    param([parameter(Mandatory=$true, ValueFromPipeline=$true)][ValidateNotNullorEmpty()][System.IO.FileInfo]$CheckFile) 
    begin { 
        Add-Type -AssemblyName "System.Web"         
        [System.IO.FileInfo]$check_file = $CheckFile 
        [string]$mime_type = $null 
    } 
    process { 
        if (test-path $check_file) {  
            $mime_type = [System.Web.MimeMapping]::GetMimeMapping($check_file.FullName)  
        }
        else { 
            $mime_type = "false" 
        } 
    } 
    end { return $mime_type } 
}

# Group all the functions that we'll need to run in Jobs as a scriptblock
$JobFunctions = {

    # Generates a keyname without doubles
    $nameCounts = @{}
    function Gen-Key-Name ( $keys, $token ) {
        $possiblename = ''
        do {
            Write-Debug $token.Item2
            if ( -not $nameCounts.ContainsKey($token.Item2) ) {
                $nameCounts[$token.Item2] = 0
            }
    
            $nameCounts[$token.Item2]++
            $possiblename = "$( $token.Item2 )$( $nameCounts[$token.Item2] )"
            Write-Verbose "PossibleName is $possiblename does it exist? :: '$( $keys[$possiblename] )'"
        } while ( $keys[$possiblename] -ne $null )
        return $possiblename
    }

    function Save-File ( [string] $file, [string] $content ) {        
        # if ( -not $InPlace ) {
            # Create output file's name
            $filenameParts = $file -split '\.'
            $filenameOUT = $filenameParts[0..$( $filenameParts.Length-2 )] -join '.'
            $filenameOUT += '.sanitised.' + $filenameParts[ $( $filenameParts.Length-1 ) ]
        # }
    
        # Save file as .santised.extension
        if (test-path $filenameOUT) {} else {
            New-Item -Force $filenameOUT | Out-Null
        }
        $content | Out-File -force -Encoding ASCII $filenameOUT
        
        # Return name of sanitised file for use by the keylist
        return "$( $(Get-Date).toString() ) - $filenameOUT"
    }
    
    ## Sanitises a file and stores sanitised data in a key
    function Sanitise ( [string] $SanitisedFileFirstLine, $finalKeyList, [string] $content, [string] $filename) {
        # Process file for items found using tokens in descending order of length. 
        # This will prevent smaller things ruining the text that longer keys would have replaced and leaving half sanitised tokens
        # $finalKeyList = @($finalKeyList)
        Write-Verbose "Sanitising file: $filename"
        $count = 0
        foreach ( $key in $( $finalKeyList.GetEnumerator() | Sort-Object { $_.Value.Length } -Descending )) {
            Write-Debug "   Substituting $($key.value) -> $($key.key)"
            Write-Progress -Activity "Sanitising $filename" -Status "Removing $($key.value)" -Completed -PercentComplete (($count++/$finalKeyList.count)*100)
            $content = $content -replace [regex]::Escape($key.value), $key.key
        }
        Write-Progress -Activity "Sanitising $filename" -Status "Removing $($key.value)" -Completed -PercentComplete 100
    
        # Add first line to show sanitation
        $content = $ExecutionContext.InvokeCommand.ExpandString(($SanitisedFileFirstLine -split "eval:")[1]) + $content
        return $content
    }
    
    ## Build the key table for all the files
    function Find-Keys ( [string] $fp, $flags, $IgnoredStrings ) {
        Write-Verbose "Finding Keys in $fp"
        # dictionary to populate
        $Keys = @{}
        # Open file
        $f = [IO.file]::ReadAllText( $fp )
        
        # Process file for tokens
        $count = 1
        foreach ( $token in $flags ) {
            Write-Progress -Activity "Scouting $fp" -Status "$($token.Item1)" -Completed -PercentComplete (($count++/$flags.Count)*100)
            $pattern = $token.Item1
            Write-Verbose "Using '$pattern' to find matches"
            $matches = [regex]::matches($f, $pattern)
            
            # Grab the value for each match, if it doesn't have a key make one
            foreach ( $m in $matches ) {
                $mval = $m.groups[1].value
                Write-Verbose "Matched: $mval"
    
                # Do we have a key already?
                if ( $Keys.ContainsValue( $mval ) ) {
                    $k =  $Keys.GetEnumerator() | Where-Object { $_.Value -eq $mval }
                    Write-Verbose "Recognised as: $($k.key)"
                
                # Check the $IgnoredStrings list
                } elseif ( $IgnoredStrings.Contains($mval) ) {
                    Write-Verbose "Found ignored string: $mval"
    
                # Create a key and assign it to the match
                } else { 
                    Write-Verbose "Found new token! $( $mval )"
                    $newkey = gen-key-name $Keys $token
                    $Keys[$newkey] = $mval
                    Write-Verbose "Made new alias: $newkey"
                    Write-Verbose "Made new key entry: $( $mval ) -> $newkey"
                }
            }
        }
        # Set the bar to full for manage-job
        Write-Progress -Activity "Scouting $fp" -Completed -PercentComplete 100
    
        Write-Verbose "Keys: $keys"
        return $keys
    }
}

# Takes a file and outputs it's the keys
function Scout-Stripper ($files, $flags) {
    Write-Verbose "Started scout stripper"
    ForEach ($file in $files) {
        $name = "Finding Keys in $($(get-item $file).Name)"
        Start-Job -Name $name -InitializationScript $JobFunctions -ScriptBlock {
            PARAM($file, $flags, $IgnoredStrings, $vPref)
            $VerbosePreference = $vPref

            Find-Keys $file $flags $IgnoredStrings
            Write-Verbose "Found all the keys in $file"
        } -ArgumentList $file,$flags,$IgnoredStrings,$VerbosePreference | Out-Null
        Write-Verbose "Made a background job for scouting of $file"
    }
    manage-job
    Write-Verbose "Key finding jobs are finished"

    # Collect the output from each of the jobs
    $jobs = Get-Job -State Completed
    $keylists = @()
    ForEach ($job in $jobs) {
        $kl = Receive-Job -Keep -Job $job
        $keylists += $kl
    }
    Write-Debug "retrieved the following from completed jobs:`n$($keylists | Out-String)"
    
    # Clean up the jobs
    Get-Job | Remove-Job | Out-Null
    Write-Verbose "cleaned up scouting jobs"

    return $keylists
}

function Sanitising-Stripper ($finalKeyList, $files) {

    # Sanitise each of the files with the final keylist and output them with Save-file
    ForEach ($file in $files) {
        $name = "Sanitising $($(get-item $file).Name)"
        Start-Job -Name $name -InitializationScript $JobFunctions -ScriptBlock {
            PARAM($file, $finalKeyList, $firstline, $vPref)
            $VerbosePreference = $vPref
            $DebugPreference = $vPref

            $content = [IO.file]::ReadAllText($file)
            Write-Verbose "Loaded in content of $file"

            $sanitisedOutput = Sanitise $firstline $finalKeyList $content $file
            write-verbose "Sanitised content of $file"

            $exportedFileName = Save-File $file $sanitisedOutput
            Write-Verbose "Exported $file to $exportedFileName"

            $exportedFileName
        } -ArgumentList $file,$finalKeyList,$SanitisedFileFirstline,$VerbosePreference | Out-Null
        Write-Verbose "Made a background job for sanitising of $file"
    }
    manage-job
    write-verbose "Sanitising jobs are finished. Files should be exported"

    # Collect the names of all the sanitised files
    $jobs = Get-Job -State Completed
    $sanitisedFilenames = @()
    ForEach ($job in $jobs) {
        $fn = Receive-Job -Keep -Job $job
        $sanitisedFilenames += $fn
    }
    Write-Verbose "Sanitised file names are:`n$sanitisedFilenames"

    # Clean up the jobs
    Get-Job | Remove-Job | Out-Null
    
    return $sanitisedFilenames
}

function Merging-Stripper ([Array] $keylists) {
    . $JobFunctions # Make the gen-key-name function available

    # If we only proc'd one file then return that
    if ($keylists.Count -eq 1) {
        return $keylists[0]
    }
    
    $output = @{}
    $totalKeys = $keylists | ForEach-Object { $result = 0 } { $result += $_.Count } { $result }
    $currentKey = 0
    ForEach ($keylist in $keylists) {
        ForEach ($Key in $keylist.Keys) {
            Write-Progress -Activity "Merging Keylists" -PercentComplete ($currentKey++/$totalKeys)*100
            if ($output.values -notcontains $keylist.$Key) {
                $newname = Gen-Key-Name $output $([System.Tuple]::Create("", $($key -split "\d*$")[0]))
                $output.$newname = $keylist.$key
            }
        }
    }
    Write-Progress -Activity "Merging Keylists" -PercentComplete 100 -Completed

    return $output
}

function manage-job () {
    # Report the progress While there are still jobs running
    While ($(Get-Job -State "Running").count -gt 0) {
        # For each job started and each child of those jobs
        ForEach ($Job in Get-Job) {
            ForEach ($Child in $Job.ChildJobs){
                ## Get the latest progress object of the job
                $Progress = $Child.Progress[$Child.Progress.Count - 1]
                
                ## If there is a progress object returned write progress
                If ($Progress.Activity -ne $Null){
                    Write-Progress -Activity $Job.Name -Status $Progress.StatusDescription -PercentComplete $Progress.PercentComplete -ID $Job.ID
                }
                
                ## If this child is complete then stop writing progress
                If ($Progress.PercentComplete -eq 100){
                    Write-Progress  -Activity $Job.Name -Status $Progress.StatusDescription  -PercentComplete $Progress.PercentComplete  -ID $Job.ID  -Complete
                    ## Clear all progress entries so we don't process it again
                    $Child.Progress.Clear()
                }
            }
        }

        ## Setting for loop processing speed
        Start-Sleep -Milliseconds 200
    }

    ForEach ($Job in Get-Job) {
        ForEach ($Child in $Job.ChildJobs) {
            Write-Progress -Activity $Job.Name -ID $Job.ID  -Complete
        }
    }       
}

function Head-Stripper ($files) {
    # There shouldn't be any other background jobs, but kill them anyway.
    Write-Debug "Current jobs running are: $(get-job *)"
    Get-Job | Stop-Job
    Get-job | Remove-Job
    Write-Debug "removed all background jobs"

    # Use Scout stripper to start looking for the keys in each file
    $keylists = Scout-Stripper $files $flags
    Write-verbose "finished finding keys"

    # Merge all of the keylists into a single dictionary.
    $finalKeyList = Merging-Stripper $keylists
    Write-Verbose "Finished merging keylists"

    # Sanitise the files
    $sanitisedFilenames = Sanitising-Stripper $finalKeyList $files
    Write-verbose "Finished sanitising and exporting files"

    return $finalKeyList, $sanitisedFilenames
}

####################################################################################################
# Start Actual Execution

# Handle config loading
$configUsed = $false
if ( $Config ) {
    try {
        $tmp = Get-Item $Config
        $configText = [IO.file]::ReadAllText($tmp.FullName)
    } catch {
        Write-Error "Error: Could not load from Specified config file: $Config"
        exit -1
    }
    Write-Verbose "Processing specified Config file"
    proc-config-file $configText
    $configUsed = $true
    Write-Verbose "Finished Processing Config file"
}

# If we didn't get told what config to use check locally for a 'UseMe' config file
if (-not $configUsed -and -not $SelfContained) {
    try {
        $tmp_f = "$( Get-location )\strippyConfig.json"
        $configText = [IO.file]::ReadAllText($tmp_f)
        $tmp_r = $true # Why is this here???

        # Check it has the UseMe field set to true before continuing
        if ( $tmp_r -and $configText -match '"UseMe"\s*?:\s*?true\s*?,') { # should probs test this
            Write-Verbose "Found local default config file to use, importing it's settings"
            proc-config-file $configText
            $configUsed = $true
        } else {
            Write-Verbose "Ignored local config file due to false or missing UseMe value."
        }

    } catch {
        write-verbose "Could not find a local config file"
    }
}

# If we still don't have a config then we need user input
if (-not $configUsed -and -not $SelfContained) {
    # If we were running silent mode then we should end specific error code There
    if ( $Silent ) {
        Write-Error "Unable to find config file"
        exit -9
    }

    $ans = Read-Host "Unable to find a strippyConfig.json file to extend the list of indicators used to find sensitive data.
Continuing now will only sanitise IP addresses and Windows UNC paths
Would you like to continue with only these? 
y/n> (y) "
    if ( $ans -eq 'n' ) {
        Write-Information "Use the -MakeConfig argument to create a strippyConfig.json file and start added indicators"
        exit 0;
    } else {
        # Use default flags mentioned in the thingy
        $script:flags = $defaultFlags
    }
}

# if ( $KeyFile ) {
#     # Check the keyfile is legit before we start.
#     Write-Verbose "Checking the KeyFile"
#     if ( Test-Path $KeyFile ) {
#         $kf = Get-Item $KeyFile
#         write-verbose "Key File exists and is: '$kf'"
#     } else {
#         Write-Error "Error: $KeyFile could not be found"
#         exit -1
#     }

#     if ( $kf.Mode -eq 'd-----' ) {
#         Write-Error "Error: $KeyFile cannot be a directory"
#         Write-Verbose $kf.Mode
#         exit -1
#     } elseif ( $kf.Extension -ne '.txt') {
#         Write-Error "Error: $KeyFile must be a .txt"
#         Write-Verbose "Key file was a '$( $kf.Extension )'"
#         exit -1
#     }
#     # Assume it's a valid format for now and check in the proc-keyfile function

#     Write-Information "Importing Keys from $KeyFile"
#     proc-keyfile $kf.FullName # we need the fullname to load the file in
#     Write-Information "Finished Importing Keys from keyfile:"
#     if (-not $Silent) {$key}
# }

Write-Verbose "Attempting to Santise $File"
$File = $(Get-Item $File).FullName

## Build the list of files to work on
$filesToProcess = @()
$OutputFolder = $File | Split-Path # Default for a file

# is it a directory?
$isDir = $( get-item $File ).Mode -eq 'd-----'
if ( $isDir ) {
    Write-Verbose "$File is a folder"

    # Get all the files
    if ($Recurse) {
        Write-Verbose "Recursive mode means we get all the files"
        $files = Get-ChildItem $File -Recurse -File
    } else {
        Write-Verbose "Normal mode means we only get the files at the top directory"
        $files = Get-ChildItem $File -File
    }

    # Filter out files that have been marked as sanitised or look suspiscious based on the get-filencoding or get-mimetype functions
    $files = $files | Where-Object { 
        # ( $_.Extension -eq '.txt' -or $_.Extension -eq '.log' ) -and 
        ( @('us-ascii', 'utf-8') -contains ( Get-FileEncoding $_.FullName ).BodyName ) -and -not
        ( $(Get-MimeType -CheckFile $_.FullName) -match "image") -and -not
        ( $_.name -like '*.sanitised.*')
    } | ForEach-Object {$_.FullName}

    # If we didn't find any files clean up and exit
    if ( $files.Length -eq 0 ) {
        Write-Error "Could not find any appropriate files to sanitise in $File"
        Clean-Up
    }

    # Declare which files we'd like to process
    $filesToProcess = $files

    # Calc the output folder

    $f = join-path $(Get-Item $File).Parent.FullName "$($(Get-Item $File).Name).sanitised"
    $OutputFolder = $(Get-Item "$f").FullName

# We also want to support archives by treating them as folders we just have to unpack first
} elseif ( $( get-item $File ).Extension -eq '.zip') {
    Write-Information "Archives are not supported yet"
    # unpack
    # run something similar to the folder code above
    # add files that we want to process to $filestoprocess
    # set a flag or similar to handle the repacking of the files into a .zip

# It's not a folder, so go for it
} else {
    Write-Verbose "$File is a file"
    
    # Add the file to process to the list
    $filesToProcess += $(get-item $File).FullName
}

# Redirect the output folder if necessary
if ($AlternateOutputFolder) {
    New-Item -ItemType directory -Path $AlternateOutputFolder -Force | Out-Null # Make the new dir        
    $OutputFolder = $(Get-item $AlternateOutputFolder).FullName
    Write-Information "Using Alternate Folder for output: $OutputFolder"
}

# give the head stripper all the information we've just gathered about the task
$finalKeyList, $listOfSanitisedFiles = Head-Stripper $filesToProcess

# Found the Keys, lets output the keylist
output-keylist $finalKeyList $listOfSanitisedFiles


Write-Information "`n==========================================================================`nProcessed Keys:"
if (-not $Silent) {$finalKeyList}

Clean-Up