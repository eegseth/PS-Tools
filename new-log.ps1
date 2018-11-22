Function Write-Log
{
  <#
  .SYNOPSIS
    Write messages to a log file in CMTrace.exe compatible format.
  .EXAMPLE
    Write-Log -Message "Installing patch MS15-031" -Source 'Add-Patch'
  #>
    [CmdletBinding()]
    Param (
      [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][AllowEmptyCollection()][string[]]$Message,
      [Parameter(Mandatory=$false,Position=1)][ValidateRange(1,3)][int16]$Severity = 1,
      [Parameter(Mandatory=$false,Position=2)][ValidateNotNull()][string]$Source = '',
      [Parameter(Mandatory=$false,Position=3)][ValidateNotNullorEmpty()][string]$ScriptSection = 'Upgrade',
      [Parameter(Mandatory=$false,Position=4)][ValidateNotNullorEmpty()][string]$LogFileDirectory = $env:LOGFILEDIR,
      [Parameter(Mandatory=$false,Position=5)][ValidateNotNullorEmpty()][string]$LogFileName = $env:LOGFILENAME,
      [Parameter(Mandatory=$false,Position=6)][switch]$PassThru = $false,
      [Parameter(Mandatory=$false,Position=7)][hashtable]$CmdletBoundParameters,
      [Parameter(Mandatory=$false,Position=8)][Boolean]$NoLog = $true
    )
    
    Begin {

      if($env:LOG)
      {
        $NoLog=$false
      }

      if(!$NoLog)
      {
        ## Get the name of this function
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        
        ## Logging Variables
        #  Log file date/time
        [string]$LogTime = (Get-Date -Format 'HH:mm:ss.fff').ToString()
        [string]$LogDate = (Get-Date -Format 'yyyy-MM-dd').ToString()
        #  Check if the script section is defined
        [boolean]$ScriptSectionDefined = [boolean](-not [string]::IsNullOrEmpty($ScriptSection))
        #  Get the file name of the source script
        Try {
          If ($script:MyInvocation.Value.ScriptName) {
            [string]$ScriptSource = Split-Path -Path $script:MyInvocation.Value.ScriptName -Leaf -ErrorAction 'Stop'
          }
          Else {
            [string]$ScriptSource = Split-Path -Path $script:MyInvocation.MyCommand.Definition -Leaf -ErrorAction 'Stop'
          }
        }
        Catch {
          $ScriptSource = ''
        }
              
        ## Create the directory where the log file will be saved
        If (-not (Test-Path -LiteralPath $LogFileDirectory -PathType 'Container')) {
          Try {
            $null = New-Item -Path $LogFileDirectory -Type 'Directory' -Force -ErrorAction 'Stop'
          }
          Catch {
            #  If error creating directory, write message to console
            If (-not $ContinueOnError) {
              Write-Warning "[$LogDate $LogTime] [${CmdletName}] $ScriptSection :: Failed to create the log directory [$LogFileDirectory]."
            }
            Return
          }
        }
        
        ## Assemble the fully qualified path to the log file
        [string]$LogFilePath = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName
      }
    }
    Process
    { 
      ForEach ($Msg in $Message)
      {
        ## If the message is not $null or empty, create the log entry
        [string]$LegacyTextLogLine = ''
        If ($Msg) {

          [string]$LegacyMsg = "[$LogDate $LogTime]"
          If ($ScriptSectionDefined) { [string]$LegacyMsg += " [$ScriptSection]" }
          If ($Source) {
            Switch ($Severity) {
              3 { [string]$LegacyTextLogLine = ('{0} [{1}] [Error] :: {2} `n{3}' -f $LegacyMsg, $Source, $Msg, (resolve-error)) }
              2 { [string]$LegacyTextLogLine = ('{0} [{1}] [Warning] :: {2}' -f $LegacyMsg, $Source, $Msg) }
              1 { [string]$LegacyTextLogLine = ('{0} [{1}] [Info] :: {2}' -f $LegacyMsg, $Source, $Msg) }
            }
          }
          Else {
            Switch ($Severity) {
              3 { [string]$LegacyTextLogLine = ('{0} [Error] :: {1} `n{2}' -f $LegacyMsg, $Msg, (resolve-error)) }
              2 { [string]$LegacyTextLogLine = ('{0} [Warning] :: {2}' -f $LegacyMsg, $Source, $Msg) }
              1 { [string]$LegacyTextLogLine = ('{0} [Info] :: {2}' -f $LegacyMsg, $Source, $Msg) }
            }
          }
        }
        
        if($CmdletBoundParameters)
        {
          [string]$CmdletBoundParameters = $CmdletBoundParameters | Format-Table -Property @{ Label = 'Parameter'; Expression = { "[-$($_.Key)]" } }, @{ Label = 'Value'; Expression = { $_.Value }; Alignment = 'Left' } -AutoSize -Wrap | Out-String
          [string]$LogLine = $LegacyTextLogLine +"`n$CmdletBoundParameters"
        }
        else
        {
          [string]$LogLine = $LegacyTextLogLine
        }
        
        if(!$NoLog)
        {    
        ## Write the log entry to the log file
          Try {
            $LogLine | Out-File -FilePath $LogFilePath -Append -NoClobber -Force -Encoding 'UTF8' -ErrorAction 'Stop'
          }
          Catch {
            If (-not $ContinueOnError) {
              Write-Warning "[$LogDate $LogTime] [$ScriptSection] [${CmdletName}] :: Failed to write message [$Msg] to the log file [$LogFilePath]."
            }
          }
        }
        else
        {
          Write-Output $LogLine
        }
      }
    }
    End {
        
    }
}

Function Resolve-Error 
{
  <#
  .SYNOPSIS
    Enumerate error record details.
  .EXAMPLE
    Resolve-Error
  #>
  [CmdletBinding()]
  Param (
    [Parameter(Mandatory=$false,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
    [AllowEmptyCollection()]
    [array]$ErrorRecord,
    [Parameter(Mandatory=$false,Position=1)]
    [ValidateNotNullorEmpty()]
    [string[]]$Property = ('Message','InnerException','FullyQualifiedErrorId','ScriptStackTrace','PositionMessage'),
    [Parameter(Mandatory=$false,Position=2)]
    [switch]$GetErrorRecord = $true,
    [Parameter(Mandatory=$false,Position=3)]
    [switch]$GetErrorInvocation = $true,
    [Parameter(Mandatory=$false,Position=4)]
    [switch]$GetErrorException = $true,
    [Parameter(Mandatory=$false,Position=5)]
    [switch]$GetErrorInnerException = $true
  )
  
  Begin {
    ## If function was called without specifying an error record, then choose the latest error that occurred
    If (-not $ErrorRecord) {
      If ($global:Error.Count -eq 0) {
        #Write-Warning -Message "The `$Error collection is empty"
        Return
      }
      Else {
        [array]$ErrorRecord = $global:Error[0]
      }
    }
    
    ## Allows selecting and filtering the properties on the error object if they exist
    [scriptblock]$SelectProperty = {
      Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        $InputObject,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [string[]]$Property
      )
      
      [string[]]$ObjectProperty = $InputObject | Get-Member -MemberType '*Property' | Select-Object -ExpandProperty 'Name'
      ForEach ($Prop in $Property) {
        If ($Prop -eq '*') {
          [string[]]$PropertySelection = $ObjectProperty
          Break
        }
        ElseIf ($ObjectProperty -contains $Prop) {
          [string[]]$PropertySelection += $Prop
        }
      }
      Write-Output -InputObject $PropertySelection
    }
    
    #  Initialize variables to avoid error if 'Set-StrictMode' is set
    $LogErrorRecordMsg = $null
    $LogErrorInvocationMsg = $null
    $LogErrorExceptionMsg = $null
    $LogErrorMessageTmp = $null
    $LogInnerMessage = $null
  }
  Process {
    If (-not $ErrorRecord) { Return }
    ForEach ($ErrRecord in $ErrorRecord) {
      ## Capture Error Record
      If ($GetErrorRecord) {
        [string[]]$SelectedProperties = & $SelectProperty -InputObject $ErrRecord -Property $Property
        $LogErrorRecordMsg = $ErrRecord | Select-Object -Property $SelectedProperties
      }
      
      ## Error Invocation Information
      If ($GetErrorInvocation) {
        If ($ErrRecord.InvocationInfo) {
          [string[]]$SelectedProperties = & $SelectProperty -InputObject $ErrRecord.InvocationInfo -Property $Property
          $LogErrorInvocationMsg = $ErrRecord.InvocationInfo | Select-Object -Property $SelectedProperties
        }
      }
      
      ## Capture Error Exception
      If ($GetErrorException) {
        If ($ErrRecord.Exception) {
          [string[]]$SelectedProperties = & $SelectProperty -InputObject $ErrRecord.Exception -Property $Property
          $LogErrorExceptionMsg = $ErrRecord.Exception | Select-Object -Property $SelectedProperties
        }
      }
      
      ## Display properties in the correct order
      If ($Property -eq '*') {
        #  If all properties were chosen for display, then arrange them in the order the error object displays them by default.
        If ($LogErrorRecordMsg) { [array]$LogErrorMessageTmp += $LogErrorRecordMsg }
        If ($LogErrorInvocationMsg) { [array]$LogErrorMessageTmp += $LogErrorInvocationMsg }
        If ($LogErrorExceptionMsg) { [array]$LogErrorMessageTmp += $LogErrorExceptionMsg }
      }
      Else {
        #  Display selected properties in our custom order
        If ($LogErrorExceptionMsg) { [array]$LogErrorMessageTmp += $LogErrorExceptionMsg }
        If ($LogErrorRecordMsg) { [array]$LogErrorMessageTmp += $LogErrorRecordMsg }
        If ($LogErrorInvocationMsg) { [array]$LogErrorMessageTmp += $LogErrorInvocationMsg }
      }
      
      If ($LogErrorMessageTmp) {
        $LogErrorMessage = 'Error Record:'
        $LogErrorMessage += "`n-------------"
        $LogErrorMsg = $LogErrorMessageTmp | Format-List | Out-String
        $LogErrorMessage += $LogErrorMsg
      }
      
      ## Capture Error Inner Exception(s)
      If ($GetErrorInnerException) {
        If ($ErrRecord.Exception -and $ErrRecord.Exception.InnerException) {
          $LogInnerMessage = 'Error Inner Exception(s):'
          $LogInnerMessage += "`n-------------------------"
          
          $ErrorInnerException = $ErrRecord.Exception.InnerException
          $Count = 0
          
          While ($ErrorInnerException) {
            [string]$InnerExceptionSeperator = '~' * 40
            
            [string[]]$SelectedProperties = & $SelectProperty -InputObject $ErrorInnerException -Property $Property
            $LogErrorInnerExceptionMsg = $ErrorInnerException | Select-Object -Property $SelectedProperties | Format-List | Out-String
            
            If ($Count -gt 0) { $LogInnerMessage += $InnerExceptionSeperator }
            $LogInnerMessage += $LogErrorInnerExceptionMsg
            
            $Count++
            $ErrorInnerException = $ErrorInnerException.InnerException
          }
        }
      }
      
      If ($LogErrorMessage) { $Output = $LogErrorMessage }
      If ($LogInnerMessage) { $Output += $LogInnerMessage }
      
      Write-Output -InputObject $Output
      
      If (Test-Path -LiteralPath 'variable:Output') { Clear-Variable -Name 'Output' }
      If (Test-Path -LiteralPath 'variable:LogErrorMessage') { Clear-Variable -Name 'LogErrorMessage' }
      If (Test-Path -LiteralPath 'variable:LogInnerMessage') { Clear-Variable -Name 'LogInnerMessage' }
      If (Test-Path -LiteralPath 'variable:LogErrorMessageTmp') { Clear-Variable -Name 'LogErrorMessageTmp' }
    }
  }
  End {
  }
}


[string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
Write-Log -Message 'Function invoked, parameters: ' -Source ${CmdletName} -CmdletBoundParameters $PSBoundParameters
Write-Log -Message ('Error in execution at {0}' -f $Server) -Source $CmdletName -Severity 1 -ScriptSection 'Prerequisites'
