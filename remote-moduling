function New-ModulePSSession
{
  <#
  .SYNOPSIS
    Create a PS session and load the desired module in it, so we can use all of the goodies from it in the remote session
  .EXAMPLE
    New-ModulePSSession -Computername server01 -ModulePath 'C:\Temp\MyModule.psm1'
    New-ModulePSSession -Computername server01 -ModulePath 'C:\Temp\MyModule.psm1' -SessionName mysession01 -Credential (get-credential)
  #>
  [CmdletBinding()]
  Param (
    [Parameter(Mandatory=$true,Position=1,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][ValidateNotNullorEmpty()][String]$ComputerName,
    [Parameter(Mandatory=$true,Position=2,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][ValidateNotNullorEmpty()][System.IO.FileInfo]$ModulePath,
    [Parameter(Mandatory=$false,Position=3)][String]$SessionName,
    [Parameter(Mandatory=$false,Position=4)][PSCredential]$Credential
  )
  
  If(!$SessionName)
  {
    $SessionName = ('{0}-remoteModuleSession' -f $ComputerName)
  }

  #Create a pssession towards the remote computer
  try{
    if($Credential)
    {
      $Session = new-pssession -name $SessionName -ComputerName $ComputerName -Credential $Credential -errorvariable failedtoSession -ErrorAction Stop
    }
    else
    {
      $Session = new-pssession -name $SessionName -ComputerName $ComputerName -errorvariable failedtoSession -ErrorAction Stop
    }
    if ($failedtoSession)
    {
      Write-Error ('Failed to establish a session to {0} from {1}' -f $Server.Name, $env:COMPUTERNAME)
      Return $false
    }
    
    Write-Verbose ('Session {0} generated' -f $Session.Name) -Source ${CmdletName}
    
  }
  catch
  {
    Write-Error ('Unable to remotely connect to server. Please enable ps remoting on {0}' -f $Server.Name)
    Return $false
  }

  #Make the module available for use in the remote session
  try
  {
    Write-Verbose ('Loading module {0} into session {1}' -f $ModulePath, $Session.Name)
    $rawModule = get-content $ModulePath -Raw -ErrorAction Stop
    $moduleScript = [scriptblock]::Create($rawModule)
    Invoke-Command -Session $Session -ScriptBlock $moduleScript -ErrorAction Stop | out-null
  }
  catch
  {
    Write-Error ('Unable to load module into the remote session {0}' -f $Server.Name)
    Disconnect-PSSession $Session -ErrorAction SilentlyContinue | out-null
    Remove-PSSession $Session -ErrorAction SilentlyContinue | out-null
    Return $false
  }
  Return $Session
}
