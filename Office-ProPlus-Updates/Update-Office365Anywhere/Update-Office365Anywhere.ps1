﻿[CmdletBinding()]
Param(
    [Parameter()]
    [bool] $WaitForUpdateToFinish = $true,

    [Parameter()]
    [bool] $EnableUpdateAnywhere = $true,

    [Parameter()]
    [bool] $ForceAppShutdown = $false,
    
    [Parameter()]
    [bool] $UpdatePromptUser = $false,

    [Parameter()]
    [bool] $DisplayLevel = $false,

    [Parameter()]
    [string] $LogPath = $null,

    [Parameter()]
    [string] $LogName = $null

)

Function Write-Log {
 
    PARAM
	(
         [String]$Message,
         [String]$Path = $Global:UpdateAnywhereLogPath,
         [String]$LogName = $Global:UpdateAnywhereLogFileName,
         [int]$severity,
         [string]$component
	)
 
    try {
        $Path = $Global:UpdateAnywhereLogPath
        $LogName = $Global:UpdateAnywhereLogFileName
        if([String]::IsNullOrWhiteSpace($Path)){
            # Get Windows Folder Path
            $windowsDirectory = [Environment]::GetFolderPath("Windows")

            # Build log folder
            $Path = "$windowsDirectory\CCM\logs"
        }

        if([String]::IsNullOrWhiteSpace($LogName)){
             # Set log file name
            $LogName = "Office365UpdateAnywhere.log"
        }
        # Build log path
        $LogFilePath = Join-Path $Path $LogName

        # Create log file
        If (!($(Test-Path $LogFilePath -PathType Leaf)))
        {
            $null = New-Item -Path $LogFilePath -ItemType File -ErrorAction SilentlyContinue
        }

	    $TimeZoneBias = Get-WmiObject -Query "Select Bias from Win32_TimeZone"
        $Date= Get-Date -Format "HH:mm:ss.fff"
        $Date2= Get-Date -Format "MM-dd-yyyy"
        $type=1
 
        if ($LogFilePath) {
           "<![LOG[$Message]LOG]!><time=$([char]34)$date$($TimeZoneBias.bias)$([char]34) date=$([char]34)$date2$([char]34) component=$([char]34)$component$([char]34) context=$([char]34)$([char]34) type=$([char]34)$severity$([char]34) thread=$([char]34)$([char]34) file=$([char]34)$([char]34)>"| Out-File -FilePath $LogFilePath -Append -NoClobber -Encoding default
        }
    } catch {

    }
}

Function Set-Reg {
	PARAM
	(
        [String]$hive,
        [String]$keyPath,
	    [String]$valueName,
	    [String]$value,
        [String]$Type
    )

    Try
    {
        $null = New-ItemProperty -Path "$($hive):\$($keyPath)" -Name "$($valueName)" -Value "$($value)" -PropertyType $Type -Force -ErrorAction Stop
    }
    Catch
    {
        Write-Log -Message $_.Exception.Message -severity 3 -component $LogFileName
    }
}

Function StartProcess {
	Param
	(
		[String]$execFilePath,
        [String]$execParams
	)

    Try
    {
        $execStatement = [System.Diagnostics.Process]::Start( $execFilePath, $execParams ) 
        $execStatement.WaitForExit()
    }
    Catch
    {
        Write-Log -Message $_.Exception.Message -severity 1 -component "Office 365 Update Anywhere"
    }
}

Function Get-OfficeCDNUrl() {
    $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
    if (!($CDNBaseUrl)) {
       $CDNBaseUrl = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\Configuration -Name CDNBaseUrl -ErrorAction SilentlyContinue).CDNBaseUrl
    }
    if (!($CDNBaseUrl)) {
        Push-Location
        $path15 = 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun\ProductReleaseIDs\Active\stream'
        $path16 = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs\Active\stream'
        if (Test-Path -Path $path16) { Set-Location $path16 }
        if (Test-Path -Path $path15) { Set-Location $path15 }

        $items = Get-Item . | Select-Object -ExpandProperty property
        $properties = $items | ForEach-Object {
           New-Object psobject -Property @{"property"=$_; "Value" = (Get-ItemProperty -Path . -Name $_).$_}
        }

        $value = $properties | Select Value
        $firstItem = $value[0]
        [string] $cdnPath = $firstItem.Value

        $CDNBaseUrl = Select-String -InputObject $cdnPath -Pattern "http://officecdn.microsoft.com/.*/.{8}-.{4}-.{4}-.{4}-.{12}" -AllMatches | % { $_.Matches } | % { $_.Value }
        Pop-Location
    }
    return $CDNBaseUrl
}

Function Get-OfficeCTRRegPath() {
    $path15 = 'SOFTWARE\Microsoft\Office\15.0\ClickToRun'
    $path16 = 'SOFTWARE\Microsoft\Office\ClickToRun'
    if (Test-Path "HKLM:\$path16") {
        return $path16
    }
    else {
        if (Test-Path "HKLM:\$path15") {
            return $path15
        }
    }
}

Function Test-UpdateSource() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $UpdateSource = $NULL
    )

  	$uri = [System.Uri]$UpdateSource

    [bool]$sourceIsAlive = $false

    if($uri.Host){
	    $sourceIsAlive = Test-Connection -Count 1 -computername $uri.Host -Quiet
    }else{
        $sourceIsAlive = Test-Path $uri.LocalPath -ErrorAction SilentlyContinue
    }

    if ($sourceIsAlive) {
        $sourceIsAlive = Validate-UpdateSource -UpdateSource $UpdateSource
    }

    return $sourceIsAlive
}

Function Validate-UpdateSource() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $UpdateSource = $NULL
    )

    [bool]$validUpdateSource = $false
    [string]$cabPath = ""

    if ($UpdateSource) {
        $mainRegPath = Get-OfficeCTRRegPath
        $configRegPath = $mainRegPath + "\Configuration"
        $currentplatform = (Get-ItemProperty HKLM:\$configRegPath -Name Platform -ErrorAction SilentlyContinue).Platform
        $updateToVersion = (Get-ItemProperty HKLM:\$configRegPath -Name UpdateToVersion -ErrorAction SilentlyContinue).UpdateToVersion

        if ($updateToVersion) {
            if ($currentplatform.ToLower() -eq "x86") {
               $cabPath = $UpdateSource + "\Office\Data\v32_" + $updateToVersion + ".cab"
            }
            if ($currentplatform.ToLower() -eq "x64") {
               $cabPath = $UpdateSource + "\Office\Data\v64_" + $updateToVersion + ".cab"
            }
        } 
        
        if($UpdateSource.ToLower().StartsWith("http")){        
            if ($currentplatform.ToLower() -eq "x86") {
               $cabPath = $UpdateSource + "\Office\Data\v32.cab"
            }
            else {
               $cabPath = $UpdateSource + "\Office\Data\v64.cab"
            }            
        }
        else{
            if ($currentplatform.ToLower() -eq "x86") {
               $cabPath = $UpdateSource + "\Office\Data\v32.cab"
            }
            else {
               $cabPath = $UpdateSource + "\Office\Data\v64.cab"
            }
        }

        if ($cabPath.ToLower().StartsWith("http")) {
           $cabPath = $cabPath.Replace("\", "/")
           $validUpdateSource = Test-URL -url $cabPath
        } else {
           $validUpdateSource = Test-Path -Path $cabPath
        }
        
        if (!$validUpdateSource) {
           Write-Host "Invalid UpdateSource. File Not Found: $cabPath"
        }
    }

    return $validUpdateSource
}

Function Update-Office365Anywhere() {
<#
.Synopsis
This function is designed to provide way for Office Click-To-Run clients to have the ability to update themselves from a managed network source
or from the Internet depending on the availability of the primary update source.

.DESCRIPTION
This function is designed to provide way for Office Click-To-Run clients to have the ability to update themselves from a managed network source
or from the Internet depending on the availability of the primary update source.  The idea behind this is if users have laptops and are mobile 
they may not recieve updates if they are not able to be in the office on regular basis.  This functionality is available with this function but it's 
use can be controller by the parameter -EnableUpdateAnywhere.  This function also provides a way to initiate an update and the script will wait
for the update to complete before exiting. Natively starting an update executable does not wait for the process to complete before exiting and
in certain scenarios it may be useful to have the update process wait for the update to complete.

.NOTES   
Name: Update-Office365Anywhere
Version: 1.1.0
DateCreated: 2015-08-28
DateUpdated: 2015-09-03

.LINK
https://github.com/OfficeDev/Office-IT-Pro-Deployment-Scripts

.PARAMETER WaitForUpdateToFinish
If this parameter is set to $true then the function will monitor the Office update and will not exit until the update process has stopped.
If this parameter is set to $false then the script will exit right after the update process has been started.  By default this parameter is set
to $true

.PARAMETER EnableUpdateAnywhere
This parameter controls whether the UpdateAnywhere functionality is used or not. When enabled the update process will check the availbility
of the update source set for the client.  If that update source is not available then it will update the client from the Microsoft Office CDN.
When set to $false the function will only use the Update source configured on the client. By default it is set to $true.

.PARAMETER ForceAppShutdown
This specifies whether the user will be given the option to cancel out of the update. However, if this variable is set to True, then the applications will be shut down immediately and the update will proceed.

.PARAMETER UpdatePromptUser
This specifies whether or not the user will see this dialog before automatically applying the updates:

.PARAMETER DisplayLevel
This specifies whether the user will see a user interface during the update. Setting this to false will hide all update UI (including error UI that is encountered during the update scenario).

.PARAMETER UpdateToVersion
This specifies the version to which Office needs to be updated to.  This can used to install a newer or an older version than what is presently installed.

.EXAMPLE
Update-Office365Anywhere 

Description:
Will generate the Office Deployment Tool (ODT) configuration XML based on the local computer

#>

    [CmdletBinding()]
    Param(
        [Parameter()]
        [bool] $WaitForUpdateToFinish = $true,

        [Parameter()]
        [bool] $EnableUpdateAnywhere = $true,

        [Parameter()]
        [bool] $ForceAppShutdown = $false,

        [Parameter()]
        [bool] $UpdatePromptUser = $false,

        [Parameter()]
        [bool] $DisplayLevel = $false,

        [Parameter()]
        [string] $UpdateToVersion = $NULL,

        [Parameter()]
        [string] $LogPath = $NULL,

        [Parameter()]
        [string] $LogName = $NULL
        
    )

    Process {
        try {
            $Global:UpdateAnywhereLogPath = $LogPath;
            $Global:UpdateAnywhereLogFileName = $LogName;

            $mainRegPath = Get-OfficeCTRRegPath
            $configRegPath = $mainRegPath + "\Configuration"

            $currentUpdateSource = (Get-ItemProperty HKLM:\$configRegPath -Name UpdateUrl -ErrorAction SilentlyContinue).UpdateUrl
            $saveUpdateSource = (Get-ItemProperty HKLM:\$configRegPath -Name SaveUpdateUrl -ErrorAction SilentlyContinue).SaveUpdateUrl
            $clientFolder = (Get-ItemProperty HKLM:\$configRegPath -Name ClientFolder -ErrorAction SilentlyContinue).ClientFolder

            $officeUpdateCDN = Get-OfficeCDNUrl

            $officeCDN = "http://officecdn.microsoft.com"
            $oc2rcFilePath = Join-Path $clientFolder "\OfficeC2RClient.exe"

            $oc2rcParams = "/update user"
            if ($ForceAppShutdown) {
              $oc2rcParams += " forceappshutdown=true"
            } else {
              $oc2rcParams += " forceappshutdown=false"
            }

            if ($UpdatePromptUser) {
              $oc2rcParams += " updatepromptuser=true"
            } else {
              $oc2rcParams += " updatepromptuser=false"
            }

            if ($DisplayLevel) {
              $oc2rcParams += " displaylevel=true"
            } else {
              $oc2rcParams += " displaylevel=false"
            }

            if ($UpdateToVersion) {
              $oc2rcParams += " updatetoversion=$UpdateToVersion"
            }

    
            $UpdateSource = "http"
            if ($currentUpdateSource) {
              If ($currentUpdateSource.StartsWith("\\",1)) {
                 $UpdateSource = "UNC"
              }
            }

             if ($EnableUpdateAnywhere) {

                if ($currentUpdateSource) {
                    [bool]$isAlive = $false
                    if ($currentUpdateSource.ToLower() -eq $officeUpdateCDN.ToLower() -and ($saveUpdateSource)) {
                        if ($currentUpdateSource -ne $saveUpdateSource) {
                            $channelUpdateSource = Change-UpdatePathToChannel -UpdatePath $saveUpdateSource

                            if ($channelUpdateSource -ne $saveUpdateSource) {
                                $saveUpdateSource = $channelUpdateSource
                            }

	                        $isAlive = Test-UpdateSource -UpdateSource $saveUpdateSource
                            if ($isAlive) {
                               Write-Log -Message "Restoring Saved Update Source $saveUpdateSource" -severity 1 -component "Office 365 Update Anywhere"
                               Set-Reg -Hive "HKLM" -keyPath $configRegPath -ValueName "UpdateUrl" -Value $saveUpdateSource -Type String
                            }
                        }
                    }
                }

                if (!($currentUpdateSource)) {
                   if ($officeUpdateCDN) {
                       Write-Log -Message "No Update source is set so defaulting to Office CDN" -severity 1 -component "Office 365 Update Anywhere"
                       Set-Reg -Hive "HKLM" -keyPath $configRegPath -ValueName "UpdateUrl" -Value $officeUpdateCDN -Type String
                       $currentUpdateSource = $officeUpdateCDN
                   }
                }

                if (!$isAlive) {
                    $channelUpdateSource = Change-UpdatePathToChannel -UpdatePath $currentUpdateSource

                    if ($channelUpdateSource -ne $currentUpdateSource) {
                        $currentUpdateSource = $channelUpdateSource
                    }

                    $isAlive = Test-UpdateSource -UpdateSource $currentUpdateSource
                    if (!($isAlive)) {
                        if ($currentUpdateSource.ToLower() -ne $officeUpdateCDN.ToLower()) {
                          Set-Reg -Hive "HKLM" -keyPath $configRegPath -ValueName "SaveUpdateUrl" -Value $currentUpdateSource -Type String
                        }

                        Write-Host "Unable to use $currentUpdateSource. Will now use $officeUpdateCDN"
                        Write-Log -Message "Unable to use $currentUpdateSource. Will now use $officeUpdateCDN" -severity 1 -component "Office 365 Update Anywhere"
                        Set-Reg -Hive "HKLM" -keyPath $configRegPath -ValueName "UpdateUrl" -Value $officeUpdateCDN -Type String

                        $isAlive = Test-UpdateSource -UpdateSource $officeUpdateCDN
                    }
                }

            } else {
                if($currentUpdateSource -ne $null){
                    $channelUpdateSource = Change-UpdatePathToChannel -UpdatePath $currentUpdateSource

                    if ($channelUpdateSource -ne $currentUpdateSource) {
                        $currentUpdateSource= $channelUpdateSource
                    }

                    $isAlive = Test-UpdateSource -UpdateSource $currentUpdateSource

                }else{
                    $isAlive = Test-UpdateSource -UpdateSource $officeUpdateCDN
                    $currentUpdateSource = $officeUpdateCDN;
                }
            }

           if ($isAlive) {
               $currentUpdateSource = (Get-ItemProperty HKLM:\$configRegPath -Name UpdateUrl -ErrorAction SilentlyContinue).UpdateUrl
               if($currentUpdateSource.ToLower().StartsWith("http")){
                   $channelUpdateSource = $currentUpdateSource
               }
               else{
                   $channelUpdateSource = Change-UpdatePathToChannel -UpdatePath $currentUpdateSource
               }

               if ($channelUpdateSource -ne $currentUpdateSource) {
                   Set-Reg -Hive "HKLM" -keyPath $configRegPath -ValueName "UpdateUrl" -Value $channelUpdateSource -Type String
                   $channelUpdateSource = $channelUpdateSource
               }

               Write-Host "Starting Update process"
               Write-Host "Update Source: $currentUpdateSource" 
               Write-Log -Message "Will now execute $oc2rcFilePath $oc2rcParams with UpdateSource:$currentUpdateSource" -severity 1 -component "Office 365 Update Anywhere"
               StartProcess -execFilePath $oc2rcFilePath -execParams $oc2rcParams

               if ($WaitForUpdateToFinish) {
                    Wait-ForOfficeCTRUpadate
               }

           } else {
               $currentUpdateSource = (Get-ItemProperty HKLM:\$configRegPath -Name UpdateUrl -ErrorAction SilentlyContinue).UpdateUrl
               Write-Host "Update Source '$currentUpdateSource' Unavailable"
               Write-Log -Message "Update Source '$currentUpdateSource' Unavailable" -severity 1 -component "Office 365 Update Anywhere"
           }

       } catch {
           Write-Log -Message $_.Exception.Message -severity 1 -component $LogFileName
           throw;
       }
    }
}

Function formatTimeItem() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string] $TimeItem = ""
    )

    [string]$returnItem = $TimeItem
    if ($TimeItem.Length -eq 1) {
       $returnItem = "0" + $TimeItem
    }
    return $returnItem
}

Function getOperationTime() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [DateTime] $OperationStart
    )

    $operationTime = ""

    $dateDiff = NEW-TIMESPAN –Start $OperationStart –End (GET-DATE)
    $strHours = formatTimeItem -TimeItem $dateDiff.Hours.ToString() 
    $strMinutes = formatTimeItem -TimeItem $dateDiff.Minutes.ToString() 
    $strSeconds = formatTimeItem -TimeItem $dateDiff.Seconds.ToString() 

    if ($dateDiff.Days -gt 0) {
        $operationTime += "Days: " + $dateDiff.Days.ToString() + ":"  + $strHours + ":" + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Hours -gt 0 -and $dateDiff.Days -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Hours: " + $strHours + ":" + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Minutes -gt 0 -and $dateDiff.Days -eq 0 -and $dateDiff.Hours -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Minutes: " + $strMinutes + ":" + $strSeconds
    }
    if ($dateDiff.Seconds -gt 0 -and $dateDiff.Days -eq 0 -and $dateDiff.Hours -eq 0 -and $dateDiff.Minutes -eq 0) {
        if ($operationTime.Length -gt 0) { $operationTime += " " }
        $operationTime += "Seconds: " + $strSeconds
    }

    return $operationTime
}

Function Wait-ForOfficeCTRUpadate() {
    [CmdletBinding()]
    Param(
        [Parameter()]
        [int] $TimeOutInMinutes = 120
    )

    begin {
        $HKLM = [UInt32] "0x80000002"
        $HKCR = [UInt32] "0x80000000"
    }

    process {
       Write-Host "Waiting for Update process to Complete..."

       [datetime]$operationStart = Get-Date
       [datetime]$totalOperationStart = Get-Date

       Start-Sleep -Seconds 10

       $mainRegPath = Get-OfficeCTRRegPath
       $scenarioPath = $mainRegPath + "\scenario"

       $regProv = Get-Wmiobject -list "StdRegProv" -namespace root\default -ErrorAction Stop

       [DateTime]$startTime = Get-Date

       [string]$executingScenario = ""
       $failure = $false
       $cancelled = $false
       $updateRunning=$false
       [string[]]$trackProgress = @()
       [string[]]$trackComplete = @()
       [int]$noScenarioCount = 0

       do {
           $allComplete = $true
           $executingScenario = $regProv.GetStringValue($HKLM, $mainRegPath, "ExecutingScenario").sValue
           
           $scenarioKeys = $regProv.EnumKey($HKLM, $scenarioPath)
           foreach ($scenarioKey in $scenarioKeys.sNames) {
              if (!($executingScenario)) { continue }
              if ($scenarioKey.ToLower() -eq $executingScenario.ToLower()) {
                $taskKeyPath = Join-Path $scenarioPath "$scenarioKey\TasksState"
                $taskValues = $regProv.EnumValues($HKLM, $taskKeyPath).sNames

                foreach ($taskValue in $taskValues) {
                    [string]$status = $regProv.GetStringValue($HKLM, $taskKeyPath, $taskValue).sValue
                    $operation = $taskValue.Split(':')[0]
                    $keyValue = $taskValue
                   
                    if ($status.ToUpper() -eq "TASKSTATE_FAILED") {
                        $failure = $true
                    }

                    if ($status.ToUpper() -eq "TASKSTATE_CANCELLED") {
                        $cancelled = $true
                    }

                    if (($status.ToUpper() -eq "TASKSTATE_COMPLETED") -or`
                        ($status.ToUpper() -eq "TASKSTATE_CANCELLED") -or`
                        ($status.ToUpper() -eq "TASKSTATE_FAILED")) {
                        if (($trackProgress -contains $keyValue) -and !($trackComplete -contains $keyValue)) {
                            $displayValue = $operation + "`t" + $status + "`t" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                            #Write-Host $displayValue
                            $trackComplete += $keyValue 

                            $statusName = $status.Split('_')[1];

                            if (($operation.ToUpper().IndexOf("DOWNLOAD") -gt -1) -or `
                                ($operation.ToUpper().IndexOf("APPLY") -gt -1)) {

                                $operationTime = getOperationTime -OperationStart $operationStart

                                $displayText = $statusName + "`t" + $operationTime

                                Write-Host $displayText
                            }
                        }
                    } else {
                        $allComplete = $false
                        $updateRunning=$true


                        if (!($trackProgress -contains $keyValue)) {
                             $trackProgress += $keyValue 
                             $displayValue = $operation + "`t" + $status + "`t" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

                             $operationStart = Get-Date

                             if ($operation.ToUpper().IndexOf("DOWNLOAD") -gt -1) {
                                Write-Host "Downloading Update: " -NoNewline
                             }

                             if ($operation.ToUpper().IndexOf("APPLY") -gt -1) {
                                Write-Host "Applying Update: " -NoNewline
                             }

                             if ($operation.ToUpper().IndexOf("FINALIZE") -gt -1) {
                                Write-Host "Finalizing Update: " -NoNewline
                             }

                             #Write-Host $displayValue
                        }
                    }
                }
              }
           }

           if ($allComplete) {
              break;
           }

           if ($startTime -lt (Get-Date).AddHours(-$TimeOutInMinutes)) {
              throw "Waiting for Update Timed-Out"
              break;
           }

           Start-Sleep -Seconds 5
       } while($true -eq $true) 

       $operationTime = getOperationTime -OperationStart $operationStart

       $displayValue = ""
       if ($cancelled) {
         $displayValue = "CANCELLED`t" + $operationTime
       } else {
         if ($failure) {
            $displayValue = "FAILED`t" + $operationTime
         } else {
            $displayValue = "COMPLETED`t" + $operationTime
         }
       }

       Write-Host $displayValue

       $totalOperationTime = getOperationTime -OperationStart $totalOperationStart

       if ($updateRunning) {
          if ($failure) {
            Write-Host "Update Failed"
          } else {
            Write-Host "Update Completed - Total Time: $totalOperationTime"
          }
       } else {
          Write-Host "Update Not Running"
       } 
    }
}

function Test-URL {
   param( 
      [string]$url = $NULL
   )

   [bool]$validUrl = $false
   try {
     $req = [System.Net.HttpWebRequest]::Create($url);
     $res = $req.GetResponse()

     if($res.StatusCode -eq "OK") {
        $validUrl = $true
     }
     $res.Close(); 
   } catch {
      Write-Host "Invalid UpdateSource. File Not Found: $url" -ForegroundColor Red
      $validUrl = $false
      throw;
   }

   return $validUrl
}

function Change-UpdatePathToChannel {
   [CmdletBinding()]
   param( 
     [Parameter()]
     [string] $UpdatePath
   )

   $newUpdatePath = $UpdatePath

   $detectedChannel = Detect-Channel

   $branchName = $detectedChannel.branch

   $branchShortName = "DC"
   if ($branchName.ToLower() -eq "current") {
      $branchShortName = "CC"
   }
   if ($branchName.ToLower() -eq "firstreleasecurrent") {
      $branchShortName = "FRCC"
   }
   if ($branchName.ToLower() -eq "firstreleasedeferred") {
      $branchShortName = "FRDC"
   }
   if ($branchName.ToLower() -eq "deferred") {
      $branchShortName = "DC"
   }

   $channelNames = @("FRCC", "CC", "FRDC", "DC")

   $madeChange = $false
   foreach ($channelName in $channelNames) {
      if ($UpdatePath.ToUpper().EndsWith("\$channelName")) {
         $newUpdatePath = $newUpdatePath -replace "\\$channelName", "\$branchShortName"
         $madeChange = $true
      } 
      if ($UpdatePath.ToUpper().Contains("\$channelName\")) {
         $newUpdatePath = $newUpdatePath -replace "\\$channelName\\", "\$branchShortName\"
         $madeChange = $true
      } 
      if ($UpdatePath.ToUpper().EndsWith("/$channelName")) {
         $newUpdatePath = $newUpdatePath -replace "\/$channelName", "/$branchShortName"
         $madeChange = $true
      }
      if ($UpdatePath.ToUpper().Contains("/$channelName/")) {
         $newUpdatePath = $newUpdatePath -replace "\/$channelName\/", "/$branchShortName/"
         $madeChange = $true
      }
   }

   if (!($madeChange)) {
      if ($newUpdatePath.Contains("/")) {
         if ($newUpdatePath.EndsWith("/")) {
           $newUpdatePath += "$branchShortName"
         } else {
           $newUpdatePath += "/$branchShortName"
         }
      }
      if ($newUpdatePath.Contains("\")) {
         if ($newUpdatePath.EndsWith("\")) {
           $newUpdatePath += "$branchShortName"
         } else {
           $newUpdatePath += "\$branchShortName"
         }
      }
   }

   try {
     $pathAlive = Test-UpdateSource -UpdateSource $newUpdatePath
   } catch {
     $pathAlive = $false
   }
   
   if ($pathAlive) {
     return $newUpdatePath
   } else {
     return $UpdatePath
   }
}

function Detect-Channel {
   param( 

   )

   Process {
      $currentBaseUrl = Get-OfficeCDNUrl
      $channelXml = Get-ChannelXml

      $currentChannel = $channelXml.UpdateFiles.baseURL | Where {$_.URL -eq $currentBaseUrl -and $_.branch -notcontains 'Business' }
      return $currentChannel
   }

}

function Get-ChannelXml {
   [CmdletBinding()]
   param( 
      
   )

   process {
       $cabPath = "$PSScriptRoot\ofl.cab"

       if (!(Test-Path -Path $cabPath)) {
           $webclient = New-Object System.Net.WebClient
           $XMLFilePath = "$env:TEMP/ofl.cab"
           $XMLDownloadURL = "http://officecdn.microsoft.com/pr/wsus/ofl.cab"
           $webclient.DownloadFile($XMLDownloadURL,$XMLFilePath)
       }

       $tmpName = "o365client_64bit.xml"
       expand $XMLFilePath $env:TEMP -f:$tmpName | Out-Null
       $tmpName = $env:TEMP + "\o365client_64bit.xml"
       [xml]$channelXml = Get-Content $tmpName

       return $channelXml
   }

}

Update-Office365Anywhere -WaitForUpdateToFinish $WaitForUpdateToFinish -EnableUpdateAnywhere $EnableUpdateAnywhere -ForceAppShutdown $ForceAppShutdown -UpdatePromptUser $UpdatePromptUser -DisplayLevel $DisplayLevel -UpdateToVersion $UpdateToVersion -LogPath $LogPath -LogName $LogName



