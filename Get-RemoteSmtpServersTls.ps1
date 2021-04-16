<#
    .SYNOPSIS
    Fetch all remote SMTP servers from Exchange receive connector logs, establishing a TLS connection
   
    Thomas Stensitzki, Torsten Schlopsnies

    THIS CODE IS MADE AVAILABLE AS IS, WITHOUT WARRANTY OF ANY KIND. THE ENTIRE 
    RISK OF THE USE OR THE RESULTS FROM THE USE OF THIS CODE REMAINS WITH THE USER.
	
    Version 1.1, 2021-06-21

    Ideas, comments and suggestions to support@granikos.eu 
 
    .LINK  
    http://scripts.granikos.eu

    .DESCRIPTION
    This scripts fetches remote SMTP servers by searching the Exchange receive connector logs for successful TLS connections.
    Fetched servers can be exported to a single CSV file for all receive connectors across Exchange Servers or
    exported to a separate CSV file per Exchange Server.
    You can use this script to identify remote servers connecting using TLS 1.0 or TLS 1.1.

	
    .NOTES 
    Requirements 
    - Exchange Server 2013+

    Revision History 
    -------------------------------------------------------------------------------- 
    1.0     Initial community release
    1.1     Redesigned the search. Script acts now faster.
	
    .PARAMETER Servers
    List of Exchange servers, modern and legacy Exchange servers cannot be mixed

    .PARAMETER Backend
    Search backend transport (aka hub transport) log files, instead of frontend transport, which is the default

    .PARAMETER ToCsvPerServer
    Export search results to a separate CSV file per servers

    .PARAMETER AddDays
    File selection filter, -5 will select log files changed during the last five days. Default: -10

    .PARAMETER ResolveNames
    Resolve the ip addresses to names (if possible)

    .EXAMPLE
    .\Get-RemoteSmtpServersTLS.ps1 -Servers SRV01,SRV02 -AddDays -4 -ToCsvPerServer -ResolveNames
   
#>


[CmdletBinding()]
param(
  $Servers = @('localhost'),
  [switch]$Backend,
  [switch]$ToCsvPerServer,
  [int]$AddDays = -10,
  [switch]$ResolveNames
)

$CsvFileName = ('RemoteSMTPServersTls-%SERVER%-%ROLE%-%TLS%-{0}.csv' -f ((Get-Date).ToString('s').Replace(':','-')))

# ToDo: Update to Get-TransportServer/Get-TransportService 
# Currently pretty static
$BackendPath = '\\%SERVER%\d$\Program Files\Microsoft\Exchange Server\V15\TransportRoles\Logs\Hub\ProtocolLog\SmtpReceive'
$FrontendPath = '\\%SERVER%\d$\Program Files\Microsoft\Exchange Server\V15\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive'

# The TLS version to search
$TlsProtocols = @('TLS1_2','TLS1_1','TLS1_0')

# The SMTP receive log search pattern
$Pattern = '(.)*SP_PROT_%TLS%(.)*succeeded'
$PreStagePattern = [System.Text.RegularExpressions.Regex]('(.)*SP_PROT_TLS(.)*succeeded')


function Write-RemoteServers {
  [CmdletBinding()]
  param(
    [string]$FilePath = '',
    [hashtable]$ResultsToExport
    
  )
    $RemoteServersOutput = New-Object System.Collections.Generic.List[System.Object]
    # Looping though the hashtable(s)
    foreach($Server in $ResultsToExport.Keys) {
      foreach($Tls in $TlsProtocols) {
        $RemoteServersOutput.Clear()
        if ($ResultsToExport.$Server.$Tls.Count -ge 1) {
          for($i=0; $i -lt $ResultsToExport.$Server.$Tls.Count; $i++) {
            if ($ResolveNames) {
              # Resolving the ip
              $ErrorActionPreference = "SilentlyContinue"
              $HostName = [System.Net.Dns]::GetHostByAddress($ResultsToExport.$Server.$Tls[$i])
              if ($HostName) {
                $RemoteServersOutput.Add((New-Object -TypeName "psobject" -Property @{"IP Address"="$($ResultsToExport.$Server.$Tls[$i])";"Remote server"="$($HostName.HostName)"}))
              }
              else
              {
                $RemoteServersOutput.Add((New-Object -TypeName "psobject" -Property @{"IP Address"="$($ResultsToExport.$Server.$Tls[$i])";"Remote server"=""}))    
              }
              $HostName = $null
            }            
          }
          if($ToCsvPerServer) {
            # save remote servers list as csv
            $CSV = $FilePath.Replace('%TLS%',$Tls)
            if (-not (Test-Path -Path $FilePath)) {
              $null = $RemoteServersOutput | Export-Csv -Path $CSV -Encoding UTF8 -NoTypeInformation -Force -Confirm:$false -NoClobber
              Write-Verbose -Message ('Remote server list written to: {0}' -f $FilePath)
            }
          }
          Write-Host "Server: $($Server)"
          Write-Host "Protocoll: $($Tls)"
          Write-Host "Remote servers:"
          $RemoteServersOutput
        }
      }
    }
}

## MAIN ###########################################
$LogPath = $FrontendPath

# Adjust CSV file name to reflect either HUB or FRONTEND transport
if($Backend) {
  $LogPath = $BackendPath
  $CsvFileName = $CsvFileName.Replace('%ROLE%','HUB')
}
else {
  $CsvFileName = $CsvFileName.Replace('%ROLE%','FE')
}

Write-Verbose -Message ('CsvFileName: {0}' -f ($CsvFileName))

# Fetch each Exchange Server server 
foreach($Server in $Servers) {
  
  $Server = $Server.ToUpper()

  # Lists and Hashtables
  $PreStageResult = New-Object System.Collections.Generic.List[string]
  $Results = @{}
  $Results["$($Server)"] = @{}

  $Path = $LogPath.Replace('%SERVER%', $Server)

  Write-Verbose -Message ('Working on Server {0} | {1}' -f $Server, $Path)

  # fetching log files requires an account w/ administrative access to the target server
  $LogFiles = Get-ChildItem -Path $Path -File | Where-Object {$_.LastWriteTime -gt (Get-Date).AddDays($AddDays)}
  

  $LogFileCount = ($LogFiles | Measure-Object).Count
  $FileCount = 1
  foreach($File in $LogFiles) {
    # looping through the file and store matched line into the generic list. We will use the list afterwards to check against the protocol
    # pattern.
    # We use .NET regex here
    if (Test-Path -Path $File.FullName) {
      try {
        $PreStagedFile = [System.IO.StreamReader]($File.FullName)
        while ($PreStagedFile.EndOfStream -eq $false) {
          $line = $PreStagedFile.ReadLine()
          $match = $PreStagePattern.Match($line)
          if ($match.Success -eq $true) {
            $PreStageResult.Add($line)
          }
        }
      }
      catch {
        Write-Verbose "File $($File.Fullname) couldn't be read. Maybe the file is open by another process."
      }
      $PreStagedFile.Dispose()
    }

    foreach($Tls in $TlsProtocols) {
      Write-Progress -Activity ('{3} | {4} | File [{0}/{1}] : {2}' -f $FileCount, $LogFileCount, $File.Name, $Server, $Tls) -PercentComplete(($FileCount/$LogFileCount)*100)
      # Nested generic list inside of a hash table
      $Results["$($Server)"]["$($Tls)"] = New-Object System.Collections.Generic.List[string]

      $SearchPattern = [System.Text.RegularExpressions.Regex]("$($Pattern.Replace('%TLS%', $Tls))")
      foreach($line in $PreStageResult) {
        $match = $SearchPattern.Match($line)
        if ($match.Success -eq $true) {
          $HostIP = (($line).Split(',')[5]).Split(':')[0]
          if (-not ($Results["$($Server)"]["$($Tls)"].Contains($HostIP))) {
            $Results["$($Server)"]["$($Tls)"].Add($HostIP)
          }
        }
      }
    }
    $FileCount++
  }

  $CsvFile = $CsvFileName.Replace('%SERVER%',$Server)
  Write-RemoteServers -FilePath $CsvFile -ResultsToExport $Results
}