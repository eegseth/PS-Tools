Function Configure-PowelSMGDB{
<#
  .Synopsis
  Attempts to configure an clean oracle database with standard config system for Powel software
  .Description
  The Configure-PowelSMGDB script automates setting up a clean database with a default working config system.
  The following is automated in this script:
    -Creates working directories
    -Creates and runs (if needed) a modified version of the following SQL scripts that requires no input from user:
        -"Create_shema_owner.sql"
        -"AsSysDba.sql"
        -"Create_tablespaces_not_OMF.sql"
    -Checks the DB timezone and corrects it, if it differs from input
    -Runs DB-Oppgrad -O a
    -Runs DB-Oppgrad -C loadI
    -Drops default configsystem and imports modified configsystem
    -Injects customer info etc. from input into config system
    -Runs "init_inflow_once.sql" script, to set up inflow model
    -Runs "DB-Oppgrad -O a" again, to set up what was not possible without the config system (mesh model etc.)
    -Creates a configsystem reader user based on data from registry (If no user/pw is set in registry, it creates one and writes it to reg)
    -Check logs for errors
    -If something non-critical went wrong, dumps it to powel\work\error.log

     
  .InPuts MANDATORY
  [string]CustomerName             (E.g. Powel)
  [string]ICC_SCHEMA_VERSION       (E.g. 11.3)
  [string]LOCAL                    (dbname as defined in tnsnames.ora)
  [string]DB_SYSTEM_PASSWD         (DB SYSTEM password)
  [string]DB_SYS_PASSWD            (DB SYS password
  [string]ICC_DBUSER               (Desired username)
  [string]ICC_DBPASSWD             (Desired password)
  [string]TNS_ADMIN                (Path to folder where tnsnames.ora resides)
  [String]$ConfigsystemDBFilesPath (Path to folder where modified config system db dump files resides)

  .InPuts OPTIONAL
  [string]ICC_LANGUAGE             (norsk)
  [string]NLS_LANG                 (norwegian_norway.WE8MSWIN1252)
  [string]FilePathRoot             (C:\Powel)
  [string]DB_TIMEZONE              (+01:00) <-- If changing it to something different, keep it in this format!
  [string]NoOMFDataDirectory       (/data/DataFiles)  Data directory for non-OMF databases
  [string]NoOMFIndexDirectory      (/data/IndexFiles) Index directory for non-OMF databases


  .OutPuts
  None

  .Notes
  NAME: Configure-PowelSMGDB
  AUTHOR: Endre Egseth (endre.egseth@powel.no)
  TODO: Check logfiles for errors in a better way/look for more errors
  TODO:
#>

[CmdletBinding()]
    Param(
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$CustomerName,
        [ValidatePattern(“^\d{1,2}.\d{1,2}$”)][Parameter(Mandatory=$True)][String]$ICC_SCHEMA_VERSION,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$LOCAL,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$DB_SYSTEM_PASSWD,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$DB_SYS_PASSWD,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$ICC_DBUSER,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$ICC_DBPASSWD,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$True)][String]$ConfigsystemDBFilesPath,
        [ValidateNotNullOrEmpty()][ValidateScript({Test-Path "$_\tnsnames.ora"})][Parameter(Mandatory=$True)][String]$TNS_ADMIN,
        [Parameter(Mandatory=$False)][String]$ICC_LANGUAGE = "norsk", #english
        [ValidatePattern(“^\w*.\w*$”)][Parameter(Mandatory=$False)][String]$NLS_LANG = "norwegian_norway.WE8MSWIN1252", #american_america.WE8MSWIN1252
        [ValidateScript({Test-Path $_})][Parameter(Mandatory=$False)][String]$FilePathRoot = "C:\Powel",
        [ValidatePattern(“^[+-]\d{2}:\d{2}$”)][Parameter(Mandatory=$False)][String]$DB_TIMEZONE = "+01:00",
        [Parameter(Mandatory=$False)][String]$NoOMFDataDirectory,
        [Parameter(Mandatory=$False)][String]$NoOMFIndexDirectory
    )


#Set up functions
Function Connect-OracleDatabase{
  <#
  .Synopsis
  Attempts to return an active Oracle database connection
  .Description
  The Connect-OracleDatabase function logs on to the specified database using
  supplied username and password.
  .InPuts
  [string]username
  [string]password
  [string]database TNS name
  .OutPuts
  [object] database connection
  .Notes
  NAME: Connect-OracleDatabase
  AUTHOR: Øivind Hoel (oho@powel.no) (Modified by Endre Egseth)
  TODO: Get configuration information, use that if present.
  TODO:
  #>
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory=$True)]$username,
    [Parameter(Mandatory=$True)]$password,
    [Parameter(Mandatory=$True)]$database
  )
  Write-Verbose "Connect-OracleDatabase:"

  Write-Verbose ("`t Logging on to {0} as {1}" -f $database, $username)
  
  $connectString = "User Id=$username;Password=$password;Data Source=$database"

  try {
    $oracleConnection = new-object Oracle.ManagedDataAccess.Client.OracleConnection($connectString) -ea Stop
  }
  catch {
    # issue with connecting using these credentials
    write-error "Error encountered attempting to log on:`n"
    break
    #return $false
  }
  return $oracleConnection
}
Function Query-OracleDatabase {
    #Queries an existing oracle database connection and returns the result. If -Kill is passed, the connection is teared down
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]$command,
        [Parameter(Mandatory=$true)]$dbconn,
        [Parameter(Mandatory=$true)][boolean]$kill
    )
    Write-Verbose "Querying DB connection"
    Try{
        $dbconn.open()
        $cmd = new-object Oracle.ManagedDataAccess.Client.OracleCommand($command,$dbconn)
        $reader = $cmd.ExecuteReader()
        While ($reader.Read()){
            Try{
                $dbresult += $reader.GetString(0)
            }Catch{
                Return $null
            }
        }
    
        $cmd.Dispose()
        $cmd = $null; $reader = $null
        If($kill){ #Kill the connection
            $dbconn.close()
        }

        If($dbresult){ #If there is results from the query, return it
            Return $dbresult
        }Else{
            Return $null
        }

    }Catch{
        Return $null
    }
}
Function Check-Log{
  #Checks logfile for errors etc.
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$True)]$logpath
  )
  Write-Verbose "Parsing logfile"
  Try{
    $LogContent = Get-Content $logpath -ea Stop
    $res = @()
  }
  Catch{
    Return "Could not retrieve log file for DB-Oppgrad... Please check logfiles manually!"
  }

  Write-Verbose "Looking for mesh errors"
  If($LogContent -like "*mesh_adm.upgrade_model failed*"){
    $res += "mesh_adm.upgrade_model failed - Please check logfiles for more information (DB-Oppgrad -O a)"
  }

  Write-Verbose "Looking for general errors"
  if($LogContent -like "*E R R O R*"){
    $res += "logfile contains 'E R R O R' - Please check logfiles for more information (DB-Oppgrad -O a)"
  }

  Write-Verbose "Check if success statements is missing"
  if(!($LogContent -like "*All objects are VALID*")){
    $res += "logfile does not contain 'All objects are VALID' - Please check logfiles for more information (DB-Oppgrad -O a)"
  }

  Return $res
}
Function Get-OraTnsAdminEntries{
    #Pulls data from tnsnames.ora
    #Copied from:
    #https://sqljana.wordpress.com/2015/08/20/parsing-out-oracle-tnsnames-ora-using-powershell/
    Param
    (
        [System.IO.FileInfo] $File
    )
    
    Begin {}

    Process
    {
        [object[]] $tnsEntries = @()        
 
        If ($_)
        {
            $File = [System.IO.FileInfo] $_
        }
        If (!$File)
        {
            Write-Error "Parameter -File  is required."
            break
        }
        If (!$File.Exists)
        {
            Write-Error "'$File.FullName' does not exist."
            break
        }
         
        [string] $data = gc $File.FullName | ? {!$_.StartsWith('#')}
         
        $lines = $data.Replace("`n","").Replace(" ","").Replace("`t","").Replace(")))(","))(").Replace(")))",")))`n").Replace("=(","=;").Replace("(","").Replace(")",";").Replace(";;",";").Replace(";;",";").Split("`n")
 
 
        #At this point each line should look like this
        #----------------------------------------------------------------
        #$Service,$Service.WORLD=;DESCRIPTION=;ADDRESS=;PROTOCOL=$Protocol;Host=$Hostname;Port=$Port;CONNECT_DATA=;SERVICE_NAME=$Service;
 
        Foreach ($line in $lines)
        {
            If ($line.Trim().Length -gt 0)
            {
                #Replace ";" with "`n" so that each can become a name=value pair in a hash-table
                $lineBreakup = ConvertFrom-StringData -StringData $line.Replace(";","`n")
 
                #At this point $linebreakup would look like this
                #----------------------------------------------------------------
                <# Name Value ---- ----- ADDRESS Port $Port CONNECT_DATA $Service,$Service.WORLD PROTOCOL $Protocol DESCRIPTION Host $Hostname SERVICE_NAME $Service #>
 
                $entryName = $line.Split("=")[0]       #Everything to the left of the first "=" in "$Service,$Service.WORLD=;DESCRIPTION=;ADDRESS=;PROTOCOL=$Protocol;Host=$Hostname;Port=$Port;CONNECT_DATA=;SERVICE_NAME=$Service;"
 
                $tnsEntry = New-Object System.Object 
                $tnsEntry | Add-Member -type NoteProperty -name Name     -value $entryName
                $tnsEntry | Add-Member -type NoteProperty -name SimpleName -value ($entryName.Split(",")[0].Trim().Split(".")[0].Trim())  #Pick "MyDB" from "MyDB, MyDB.World" or "MyDB.World, MyDB"
                $tnsEntry | Add-Member -type NoteProperty -name Protocol -value $lineBreakup["PROTOCOL"]
                $tnsEntry | Add-Member -type NoteProperty -name Host     -value $lineBreakup["Host"]
                $tnsEntry | Add-Member -type NoteProperty -name Port     -value $lineBreakup["Port"]
                $tnsEntry | Add-Member -type NoteProperty -name Service  -value $(if ($lineBreakup["SERVICE_NAME"] -eq $null) {$lineBreakup["SID"]} else {$lineBreakup["SERVICE_NAME"]})  #One of the two will have the value. Pick the one that does!
 
                #Make sure we ignore entries created due to empty lines or mal-formed structure
                If ($tnsEntry.Service.Trim().Length -gt 0)
                {
                    $tnsEntries += $tnsEntry
                }
                Else
                {
                    #Make sure people notice problem entries!
                    if ($line.Trim().Length -gt 0)
                    {
                        Write-Warning "Ignoring empty/mal-formed entry: [{0}]" -f $line
                    }
                }
            }
        }
 
        $tnsEntries
    }
     
    End {}
}
Function Check-isAdmin{
    #Checks if the script is run as administrator
    Write-Verbose "Checking if script is run as admin"
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
        [Security.Principal.WindowsBuiltInRole] “Administrator”)){
        Write-Error “You do not have Administrator rights to run this script!”
        Break
    }
}
Function Check-OracleClient{
    #Checks if Oracle client is installed
    $regpath = @(
        'HKLM:\Software\ORACLE\*'
        'HKLM:\Software\Wow6432Node\ORACLE\*'
    )
    Write-Verbose "Looking for oracle client registry keys in $regpath"
    $orares = Get-ItemProperty $regpath | select ORACLE_HOME, NLS_LANG
    If(!$orares){
        Write-Error “Oracle client is not installed, exiting!"
        Break
    }
}
Function Write-Out{
    #Prints a nicely formatted info-message
    [CmdletBinding()]
    Param(
    [Parameter(Mandatory=$true, Position=1)]$text
    )
    $out = @()
    For($i=0;($text.Length+2) -gt $i;$i++){
        $items += "#"
    }
    $out += $items
    $out += "#$text"
    $out += "$items"

    Write-Output $out
}


#Define variables
$Root = $FilePathRoot
If($Root[-1] -like "\"){$Root=$Root.Substring(0,$Root.Length-1)}
$Work = "$Root\Work"
$ConfigSystem = $ConfigsystemDBFilesPath
$env:ICC_SCHEMA_VERSION= $ICC_SCHEMA_VERSION
$env:LOCAL = $LOCAL
$env:ICC_LANGUAGE = $ICC_LANGUAGE
$env:NLS_LANG= $NLS_LANG 
$env:ICC_DBUSER = $ICC_DBUSER
$env:ICC_DBPASSWD = $ICC_DBPASSWD
$env:ICC_HOME = "$Root\icc"
$env:ICC_SCHEMA_PATH = "$env:ICC_HOME\install\db"
$env:ICC_TMP = "."
$env:TWO_TASK = $LOCAL
$env:TNS_ADMIN = $TNS_ADMIN
$env:ICC_DBMS = "Oracle"
$env:ICC_LANGPATH="$env:ICC_HOME\gui"
$dbserver = Get-OraTnsAdminEntries -File "$env:TNS_ADMIN\tnsnames.ora" | ? Name -like $env:LOCAL | Select Host, Port
$errors = @()

#Load prerequisites
Write-out "Loading prerequisites"
Write-verbose "Loading Oracle.ManagedDataAccess.dll"
Try{
    Add-Type -Path "$env:ICC_HOME\Bin\Oracle.ManagedDataAccess.dll" -ea Stop
    Write-Verbose "Loaded $env:ICC_HOME\Bin\Oracle.ManagedDataAccess.dll"
}Catch{
    Write-Error "Could not load Oracle.ManagedDataAccess.dll. Aborting! (Expected to find it under $env:ICC_HOME\Bin\)"
    Break
}
Write-Output "OK`n"


#Check userrights, input, DBconnection & DB-dump files
Write-out "Verifying userrights, input & connection"

Check-isAdmin
Check-OracleClient

Write-Verbose "Verifying connection to database"
If(!(Test-NetConnection $dbserver.Host -port $dbserver.Port -InformationLevel Quiet)){
    Write-Error "Could not contact database: $dbserver.Host on port: $dbserver.Port, aborting!"
    Break
}

Write-Verbose "Checking OMF status"
Try{#If parameters db_create_online_log_dest_n & db_create_file_dest is set, OMF is in use
    $sql = "select value from v`$parameter where name like 'db_create_online_log_dest_1'"
    $databaseConnection = Connect-OracleDatabase -username "system" -password $DB_SYSTEM_PASSWD -database $env:LOCAL -ea Stop
    $omflogstatus = Query-OracleDatabase -command $sql -dbconn $databaseConnection -kill $true -ea Stop

    $databaseConnection = Connect-OracleDatabase -username "system" -password $DB_SYSTEM_PASSWD -database $env:LOCAL -ea Stop
    $sql = "select value from v`$parameter where name like 'db_create_file_dest'"
    $omffilestatus = Query-OracleDatabase -command $sql -dbconn $databaseConnection -kill $true -ea Stop
}Catch{
    Write-Error "Failed to check database OMF usage, aborting!"
    Break
}

If((!$omffilestatus) -or (!$omflogstatus)){ #If OMF parameters is not set in DB
    Write-Verbose "DB is not using OMF"
    If(!($NoOMFDataDirectory -and $NoOMFIndexDirectory)){ #If OMF script input is not set
        Write-Error "Seems like the DB is not using OMF. You have to supply both -NoOMFIndexDirectory AND -NoOMFDataDirectory, if DB is not using OMF files!"
        Break
    }
}

Write-Verbose "Checking config system database dump files" #Checks the current working directory ($PWD)
Write-Verbose "Locating cfgparam.dmp, cfggroup.dmp, cfggroupmembers.dmp, cfggroupparams.dmp & cfggroupmember.dmp"
If(!(test-path "$ConfigSystem\cfgparam.dmp") -or !(test-path "$ConfigSystem\cfggroup.dmp") -or !(test-path "$ConfigSystem\cfggroupmembers.dmp") -or !(test-path "$ConfigSystem\cfggroupparams.dmp") -or !(test-path "$ConfigSystem\cfggroupmember.dmp")){
    Write-Error "Could not find config system database dump files in $ConfigSystem, aborting!"
    Break
}
Write-Output "OK`n"


#Create working directories
Write-Out "Creating working directories"
Try{
    If(!(Test-Path "$Root\Work")){
        Write-Verbose "$Root\Work"
        New-Item -ItemType Directory -Path $Root -Name "Work" -ea Stop | Out-Null
    }
    If(!(Test-Path "$Root\Work\$env:ICC_SCHEMA_VERSION")){
        Write-Verbose "$Root\Work\$env:ICC_SCHEMA_VERSION"
        New-Item -ItemType Directory -Path $Work -Name $env:ICC_SCHEMA_VERSION -ea Stop | out-null
    }
    CD "$Work\$env:ICC_SCHEMA_VERSION" -ea Stop | out-null
}Catch{
    Write-Error "Failed to create working directories, aborting!"
    Break
}
Write-Output "OK`n"


#Create a copy of create_schema_owner.sql & assysdba.sql, modify them with supplied info, so there is no need for user input, and appends "quit;" at the end, so they will exit when done, and this script will resume
Write-Out "Modifying sql scripts"

Write-Verbose "Modifying create_schema_owner.sql"
$replacement = @(
    ("^connect system/&&SYSTEM_PASSWORD.","--"),
    ("^prompt","--"),
    ("^accept SCHEMA_OWNER prompt 'Enter new SmG/MDMS Schema owner name : '","define SCHEMA_OWNER=$env:ICC_DBUSER"),
    ("^accept SYSTEM_PASSWORD prompt 'Enter password for Oracle SYSTEM account : '  hide","--"),
    ("^accept SCHEMA_OWNER prompt","--")
)

$schemasql = gc "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_schema_owner.sql" -ea Stop
Write-Verbose "Removing prompts, and replacing it with static variables in create_schema_owner.sql"
foreach($replace in $replacement){
    $schemasql = $schemasql -Replace $replace[0],$replace[1] 
}

$schemasql+="quit;"
Try{
    $schemasql | out-file "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_schema_owner-temp.sql" -Encoding ascii -ea Stop
}Catch{
    Write-Error "Failed to create a modified version of create_schema_owner.sql, aborting!"
    Break
}

Write-Verbose "Modifying assysdba.sql"
Try{
    (gc "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\assysdba.sql" -ea Stop) | out-file "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\assysdba-temp.sql" -Encoding utf8 -ea Stop
    "quit;" | out-file "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\assysdba-temp.sql" -Append -Encoding utf8 -ea Stop
}Catch{
    Write-Error "Failed to create a modified version of assysdba.sql, aborting!"
    Break
}

#Modify create_tablespaces_not_OMF.sql IF NoOMFPath input variable is set (For DB's that does not use oracle managed files)
If($NoOMFDataDirectory -and $NoOMFIndexDirectory){
    Write-Verbose "Modifying create_tablespaces_not_OMF.sql"
    Try{
        Add-Content -Path "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_tablespaces_not_OMF-temp.sql" -Value "define INDEX_DIRECTORY='$NoOMFIndexDirectory';" -Force -ea Stop
        Add-Content -Path "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_tablespaces_not_OMF-temp.sql" -Value "define DATA_DIRECTORY='$NoOMFDataDirectory';" -Force -ea Stop
        Write-Verbose "Removing promts and inserting static variables for non-OMF directory based on input $NoOMFDataDirectory , $NoOMFIndexDirectory from create_tablespaces_not_omf.sql"
        (gc "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_tablespaces_not_OMF.sql" -ea Stop) -Replace "^accept DATA_DIRECTORY prompt","--" -replace "^accept INDEX_DIRECTORY prompt","--"| Out-File "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_tablespaces_not_OMF-temp.sql" -Append -Encoding UTF8 -Force -ea Stop
    }Catch{
        Write-Error "Failed to create a modified version of create_tablespaces_not_OMF.sql, aborting!"
        Break
    }
}
Write-Output "OK`n"


#Run the modified SQL scripts (create_tablespaces_not_OMF.sql is called from create_schema_owner-temp.sql if needed)
Write-Out "Running modified sql scripts"
Try{
    Write-Verbose "Running modified create_schema_owner.sql"
    Start-Process cmd.exe -ArgumentList "/C sqlplus system/$DB_SYSTEM_PASSWD@$env:LOCAL @$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_schema_owner-temp" -Wait -ea Stop -Verb runAs
    Write-Verbose "Running modified assysdba.sql"
    Start-Process cmd.exe -ArgumentList "/C sqlplus sys/$DB_SYS_PASSWD@$env:LOCAL as sysdba @$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\assysdba-temp" -Wait -ea Stop -Verb runAs
}Catch{
    Write-Error "Failed to run modified SQL scripts, aborting!"
    Break
}
Write-Output "OK`n"


#Clean up the modified scripts
Write-Out "Removing up modified sql scripts"
Remove-Item "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_schema_owner-temp.sql" -Force -ea SilentlyContinue
Remove-Item "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\assysdba-temp.sql" -Force -ea SilentlyContinue
Remove-Item "$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\admin\create_tablespaces_not_OMF-temp.sql" -Force -ea SilentlyContinue
Write-Output "OK`n"


#Check the DB Timezone, and correct it if it is different from supplied timezone
Write-Out "Checking DB Timezone"
Try{
    $sql = "select DBTIMEZONE from dual"
    $databaseConnection = Connect-OracleDatabase -username $env:ICC_DBUSER -password $env:ICC_DBPASSWD -database $env:LOCAL -ea Stop
    $dbresult = Query-OracleDatabase -command $sql -dbconn $databaseConnection -kill $true -ea Stop
}Catch{
    $err = "Failed to retrieve DB TIMEZONE from database! Please check the db timezone manually and if needed, correct it!"
    Write-Warning $err
    $errobj = New-Object System.Object
    $errobj | Add-Member -Type NoteProperty -Name Source -Value "Timezone"
    $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
    $errors += $errobj
}    

If ($dbresult -notlike $db_timezone){ #Not a match between input and current db setting
    write-warning "DB timezone ($dbresult) differs from supplied timezone ($db_timezone)"
    Write-warning "Changing DB timezone..."
    
    Try{
        $sql = "alter database set time_zone='$db_timezone'" #Change db setting to input
        $databaseConnection = Connect-OracleDatabase -username "system" -password $db_system_passwd -database $env:LOCAL -ea Stop
        Query-OracleDatabase -command $sql -dbconn $databaseConnection -kill $true -ea Stop | out-null
    }Catch{
        Write-Warning "Failed to set DB TIMEZONE to $db_timezone, please do it manually with the following sql command, when the script is finished, and then restart the database!"
        Write-Warning "alter database set time_zone='$db_timezone'"
        $errobj = New-Object System.Object
        $errobj | Add-Member -Type NoteProperty -Name Source -Value "Timezone"
        $errobj | Add-Member -Type NoteProperty -Name Error -Value "Failed to set the correct timezone in database"
        $errors += $errobj
    }

    Try{
        Write-Verbose "Trying to restart database service OracleService$env:LOCAL on $dbserver.Host" #Try to restart the db service on the db server (only works if the db server is running windows)
        Invoke-Command -ComputerName $dbserver.Host -ScriptBlock {Restart-Service -Name "OracleService$args"} -ArgumentList $env:LOCAL -ea Stop
    }Catch{
        Write-Warning "Failed to restart the database service OracleService$env:LOCAL on $dbserver. Please restart it manually when the script is finished!"
        $errobj = New-Object System.Object
        $errobj | Add-Member -Type NoteProperty -Name Source -Value "Timezone"
        $errobj | Add-Member -Type NoteProperty -Name Error -Value "Failed to database service, please do it manually"
        $errors += $errobj
    }
}
Write-Output "OK`n"


#Run DB-Oppgrad -O a  & DB-Oppgrad -C loadI
Write-Out "Running ID-DBOppgrad"
Try{
    Write-Verbose "Running ID-DBOppgrad -O a"
    Start-Process cmd.exe -ArgumentList "/C ID-DBOppgrad -O a" -Wait -ea Stop -Verb runAs
    Write-Verbose "Running ID-DBOppgrad -C loadI"
    Start-Process cmd.exe -ArgumentList "/C ID-DBOppgrad -C loadI" -Wait -ea Stop -Verb runAs
}Catch{   
    Write-Error "Something failed during DB-Oppgrad, plase review logs in $Work, aborting!"
    Break
}
Write-Output "OK`n"


#Remove default config system
Write-Out "Removing default config system"
$sql = @()
$sql += "truncate table CFGGROUPPARAMS;"
$sql += "truncate table CFGGROUPMEMBERS;"
$sql += "delete from CFGGROUPMEMBER;"
$sql += "delete from CFGGROUP;"
$sql += "delete from cfgparam;"
$sql += "commit;"
$sql += "quit;"
$sql | Set-Content "$Work\rem-old.sql"

Try{
    Start-Process cmd.exe -ArgumentList "/C sqlplus $env:ICC_DBUSER/$env:ICC_DBPASSWD@$env:LOCAL @$WORK\rem-old.sql" -Wait -ea Stop -Verb runAs
    remove-item -Path "$work\rem-old.sql" -Force -ea SilentlyContinue
}Catch{
    $err = "Failed to remove old config system!"
    Write-Warning $err
    $errobj = New-Object System.Object
    $errobj | Add-Member -Type NoteProperty -Name Source -Value "ConfigurationSystem"
    $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
    $errors += $errobj
    $skip = $true
}

#Import modified basic config system
Write-Out "Importing modified config system"
$configdumps = @()
$configdumps += "cfgparam.dmp"
$configdumps += "cfggroup.dmp"
$configdumps += "cfggroupparams.dmp"
$configdumps += "cfggroupmember.dmp"
$configdumps += "cfggroupmembers.dmp"

Try{
    Foreach ($dump in $configdumps){
        Write-Verbose "Importing $dump"
        Start-Process cmd.exe -ArgumentList "/C Imp $env:ICC_DBUSER/$env:ICC_DBPASSWD@$env:LOCAL fromuser=smg_dalane touser=$env:ICC_DBUSER ignore=y statistics=none grants=none file=$ConfigSystem\$dump" -Wait -ea Stop -Verb runAs
    }
}Catch{
    Write-Error "Failed to import new config system ($dump), aborting!"
    Break
}
Write-Output "OK`n"


#Set customer information in imported config system
Write-Out "Inserting supplied customer information into config system"
$sql = @()
$sql += "update cfggroup set description = 'Special variables for $customername, valid for all users' where CFGGROUP_KEY=54;" #Sets customername in description of the default group for the customer
$sql += "update cfggroup set name = '$customername DEFAULT' where CFGGROUP_KEY=54;" #Sets customername in the name of the default group for the customer
$sql += "update cfggroupparams set CVAL = 'Alarm from SMG DB $customername' where CFGPARAM_KEY=552 AND CFGGROUP_KEY=203;" #Sets customername in the subject field in mails (default is SMGDemo) in the configuration system M_Auto group
$sql += "update cfggroupparams set CVAL = '$env:ICC_DBUSER' where CFGPARAM_KEY=52 AND CFGGROUP_KEY=203;" #Sets ICC_DBUSER in the configsystem M_Auto group
$sql += "update cfggroupparams set CVAL = '$env:ICC_DBPASSWD' where CFGPARAM_KEY=53 AND CFGGROUP_KEY=203;" #Sets ICC_DBPASSWD in the configsystem M_Auto group
$sql += "update cfggroupparams set CVAL = '$env:LOCAL' where CFGPARAM_KEY=50 AND CFGGROUP_KEY=54;" #Sets LOCAL in the configsystem customer default group
$sql += "update cfggroupparams set CVAL = '$Root\IccData' where CFGPARAM_KEY=20 AND CFGGROUP_KEY=3;" #Sets HOME in the configsystem POWEL DEFAULT group
$sql += "update cfggroupparams set CVAL = '$Root\Icc' where CFGPARAM_KEY=19 AND CFGGROUP_KEY=3;" #Sets ICC_HOME in the configsystem POWEL DEFAULT group
$sql += "commit;"
$sql += "quit;"
$sql | Set-Content "$Work\set-new.sql"

Try{
    Start-Process cmd.exe -ArgumentList "/C sqlplus $env:ICC_DBUSER/$env:ICC_DBPASSWD@$env:LOCAL @$WORK\set-new.sql" -Wait -ea Stop -Verb runAs
    remove-item -Path "$work\set-new.sql" -Force -ea SilentlyContinue
}Catch{
    $err = "Failed to insert customer info in config system!"
    Write-Warning $err
    $skip = $true
    $errobj = New-Object System.Object
    $errobj | Add-Member -Type NoteProperty -Name Source -Value "ConfigurationSystem"
    $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
    $errors += $errobj
}


#Run Inflow model script, to set up infow models in DB
Write-Out "Setting up inflow models in DB"
Try{
    Write-Verbose "Running init_inflow_once.sql"
    Start-Process cmd.exe -ArgumentList "/C sqlplus $env:ICC_DBUSER/$env:ICC_DBPASSWD@$env:LOCAL @$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\misc\init_inflow_once" -Wait -ea Stop -Verb runAs | out-null
}Catch{
    $err = "Failed to load Inflow models, please run the following script from sqlplus as schema owner manually: $env:ICC_DBUSER\<password> @$env:ICC_SCHEMA_PATH\$env:ICC_SCHEMA_VERSION\Oracle\misc\init_inflow_once.sql"
    Write-Warning $err
    $errobj = New-Object System.Object
    $errobj | Add-Member -Type NoteProperty -Name Source -Value "Inflow"
    $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
    $errors += $errobj
}
Write-Output "OK`n"


#Run "DB-Oppgrad -O a" again, to set up what was not possible without the config system/inflow
Write-Out "Running ID-DBOppgrad once again to fix missing parts"
Try{
    Write-Verbose "Running ID-DBOppgrad -O a"
    Start-Process cmd.exe -ArgumentList "/C ID-DBOppgrad -O a" -Wait -ea Stop -Verb runAs
}Catch{
    $err = "Failed to run 'ID-DBOppgrad -O a', please do it manually after the script has completed!"
    Write-Warning $err
    $errobj = New-Object System.Object
    $errobj | Add-Member -Type NoteProperty -Name Source -Value "ID-DBOppgrad"
    $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
    $errors += $errobj
}
Write-Output "OK`n"


#Create configuration system reader user
Write-Out "Create configuration system reader user"

$regpath = "HKLM:\SOFTWARE\WOW6432Node\Powel"
$cfgreader = (Get-ItemProperty -Path $regpath -Name "ICC_CFGUSER" -ea SilentlyContinue).ICC_CFGUSER #Try to get config reader username from registry
$cfgpasswd = (Get-ItemProperty -Path $regpath -Name "ICC_CFGPASSWD" -ea SilentlyContinue).ICC_CFGPASSWD #Try to get config reader password from registry
$cfgserver = (Get-ItemProperty -Path $regpath -Name "ICC_CFGSERVER" -ea SilentlyContinue).ICC_CFGSERVER #Try to get config database name from registry

If(!$cfgreader){
    $cfgreader = "cfg_$env:ICC_DBUSER" #Create a new username
    Write-Verbose "No user defined in registry, creating user $cfgreader"

    #Creating registry key with username
    If(!(Test-Path $regpath)){
        New-Item -Path $regpath -Force | Out-Null
    }
    New-ItemProperty -Path $regpath -Name "ICC_CFGUSER" -Value $cfgreader -PropertyType String -Force | Out-Null
}
If(!$cfgpasswd){
    Write-Verbose "No user passwod defined in registry, creating."
    $cfgpasswd = "cfg_$env:ICC_DBUSER"#Create a new password

    #Creating registry key with password
    If(!(Test-Path $regpath)){
        New-Item -Path $regpath -Force | Out-Null
    }
    New-ItemProperty -Path $regpath -Name "ICC_CFGPASSWD" -Value $cfgpasswd -PropertyType String -Force | Out-Null
}
If(!$cfgserver){
    Write-Verbose "No configdatabase name defined in registry, creating $env:LOCAL"

    #Creating registry key with database name
    If(!(Test-Path $regpath)){
        New-Item -Path $regpath -Force | Out-Null
    }
    New-ItemProperty -Path $regpath -Name "ICC_CFGSERVER" -Value $env:LOCAL -PropertyType String -Force | Out-Null
}

Write-Verbose "Cfg reader username: $cfgreader"

#Set required db rights to cfg db user
Write-Verbose "Setting userrights to configsystem user in db"
$tablespace = $env:ICC_DBUSER+"_DATA_M"
$pddb = $env:ICC_DBUSER+".PD_DBOPTION"
$UT40 = $env:ICC_DBUSER+"UT40"
$skip = $false

$script = @()
$script += "create user $cfgreader identified by $cfgpasswd;" 
$script += "alter user $cfgreader default tablespace $tablespace;"
$script += "grant CONNECT to $cfgreader;"
$script += "grant $UT40 to $cfgreader;"
$script += "grant EXECUTE on $pddb to $cfgreader;"
$script += "grant CREATE SESSION to $cfgreader;"
$script += "commit;"
$script += "quit;"
$script | Set-Content "$Work\cfgreaderrights.sql"

Try{
    Start-Process cmd.exe -ArgumentList "/C sqlplus system/$DB_SYSTEM_PASSWD@$env:LOCAL @$WORK\cfgreaderrights.sql" -Wait -ea Stop -Verb runAs | out-null
    remove-item -Path "$work\cfgreaderrights.sql" -Force -ea SilentlyContinue
}Catch{
    $err = "Failed to create Config reader user, please do it manually when the script has finished!"
    Write-Warning $err
    $errobj = New-Object System.Object
    $errobj | Add-Member -Type NoteProperty -Name Source -Value "CFG Reader"
    $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
    $errors += $errobj
    $skip = $true
}

If(!$skip){ #Skipping if no user was created in DB
    $sql = "select USER_ID from ALL_USERS where upper(USERNAME) like upper('$cfgreader')"
    Write-Verbose "Pulling user-id for config user from db"
    Try{
        $usrid = Query-OracleDatabase -command $sql -dbconn $databaseConnection -kill $false -ea Stop
    }Catch{
        $err = "Failed to get config reader user information, please create the config system reader account manually!"
        Write-Warning $err
        $errobj = New-Object System.Object
        $errobj | Add-Member -Type NoteProperty -Name Source -Value "CFG Reader"
        $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
        $errors += $errobj
        $skip = $True
    }

    If((!$skip) -and $usrid){ #Skipping if we was not able to get the USERID from the DB
        $sql = "insert into users (USER_KEY, DBUSR_ID, OPUSR_ID, CODE, NAME, ENABLED, DB_OWNER, USTP_KEY, AUDIT_ON, AUTHENTICATION_TYPE, TO_BE_REMOVED) VALUES (3, $usrid, 0, '$cfgreader', 'Config reader user', 1, 0, 40, 0, 'PASSWORD', 0)"
        Write-Verbose "Inserting config user into Powel user table"
        Try{
            $dbresult = Query-OracleDatabase -command $sql -dbconn $databaseConnection -kill $false -ea Stop
        }Catch{
            $err = "Failed to set config reader user information, please create the config system reader account manually!"
            Write-Warning $err
            $errobj = New-Object System.Object
            $errobj | Add-Member -Type NoteProperty -Name Source -Value "CFG Reader"
            $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
            $errors += $errobj
            $skip = $True
        }
    }

    If(!$skip){ #Skipping if we failed to add the oracle user to the Powel users table
        Write-Verbose "Creating logontrigger for $cfgreader, to access schema $env:ICC_DBUSER"
        Try{
            $script = @()
            $script += "CREATE OR REPLACE TRIGGER $cfgreader.tr_event_after_logon after logon on $cfgreader.schema"
            $script += "BEGIN"
            $script += "EXECUTE IMMEDIATE 'ALTER SESSION SET CURRENT_SCHEMA=$env:ICC_DBUSER';"
            $script += "END;"
            $script += "/"
            $script += "quit;"
            $script | Set-Content "$Work\cfgreader.sql"

            Start-Process cmd.exe -ArgumentList "/C sqlplus system/$DB_SYSTEM_PASSWD@$env:LOCAL @$WORK\cfgreader.sql" -Wait -ea Stop -Verb runAs | out-null
            remove-item -Path "$work\cfgreader.sql" -Force -ea SilentlyContinue
        }Catch{
            $err = "Failed to set config reader user information, please create the config system reader account manually!"
            Write-Warning $err
            $errobj = New-Object System.Object
            $errobj | Add-Member -Type NoteProperty -Name Source -Value "CFG Reader"
            $errobj | Add-Member -Type NoteProperty -Name Error -Value $err
            $errors += $errobj
        }
    }
}
$databaseConnection.Close()
Write-Output "OK`n"


#Check log after last DB-Oppgrad -O a
Write-Out "Verifying logs"
Try{
    $logcheck = (gci "$work\$env:ICC_SCHEMA_VERSION\log_post_upgrade_$env:ICC_DBUSER*.lst" | Sort LastWriteTime | select -Last 1).FullName | Check-Log
}Catch{
    Write-Error "Failed to read logs, something went wrong during setup. (ID-DBOppgrad -O a  most likely)"
    Break
}
If($logcheck){
    Write-Warning $logcheck`n
}Else{
    Write-Output "OK`n"
}


#Finish up...
Write-Warning "Configuration completed! You should manually check the system to verify wether it's good to go or not!"
if($errors){
    Write-Warning "The following went wrong during setup (It has been stored in $work\Errors.log)"
    Write-Warning $errors
    $errors | out-file "$work\Errors.log" -Force
}

}