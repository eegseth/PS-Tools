<#
    .SYNOPSIS
    Checks GPReport.xml files from GPO export, and pulls gpo name and path

    .DESCRIPTION
    Checks GPO path
    Pulls XML tag gpo.name
    Adds gpo name and path to an array and outputs it

    .EXAMPLE
    .\Get-GPOInfo.ps1 -GPOPath "C:\GPOExp"

    Input parameters mandatory:
    -GPOPath                    path to  gpo export/backup folder
#>


[CmdLetBinding()]
Param (
    [ValidateNotNullOrEmpty()]
    [ValidateScript({Test-Path $_)]
    [Parameter(
    Mandatory=$True,
    HelpMessage="Specify path to GPO export folder",
    Position=1
    )]
    [String]$GPOPath
)

If($GPOPath[-1] -like "\"){
    $GPOPath = $GPOPath.Substring(0,$GPOPath.Length-1)
}

$Result = @()
$GPOs = GCI $GPOPath -Filter "{*" -Directory

ForEach($GPO in $GPOPath){
$Path = $GPOPath + "\$gpo\gpreport.xml"
[XML]$GPReport = Get-Content $Path
$GPOObj = New-Object System.Object
$GPOObj | Add-Member -Type NoteProperty -Name GPOName -Value $GPReport.GPO.Name
$GPOObj | Add-Member -Type NoteProperty -Name GPOPath -Value ($GPOPath + "\$GPO")
$Result += $GPOObj
}

Return $Result