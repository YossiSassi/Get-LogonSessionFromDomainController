<# 
### Get Logon Sessions from Domain Controllers ###
Provides a quick overview of which accounts recently communicated directly with any DC in an Active Directory domain, via any Authentication protocol or service.
While not totally accurate, since there's an idle time for the connections, this can provide a real-time snapshot of recently active accounts (recently performed access via SMB, WinRM, RPC etc.)

By default, queries all Domain Controllers for logon sessions, displaying all authentication packages & logon types.

If parameter SamAccountName is specified, highlights sessions (if any) for this specific account, user or computer (SamAccountName$).

Requires permissions for running PSRemoting on Domain Controllers (klist.exe only)

Comments: 1nTh35h311 (yossis@protonmail.com)
v1.0.1 - Added check for failed jobs + error reason
v1.0 - Initial script
#>

[cmdletbinding()]
param (
    [ValidateSet("CONSOLE ONLY","CONSOLE+CSV","CONSOLE+GRID","CONSOLE+CSV+GRID")]
    [string]$Output = "CONSOLE ONLY",
    [string]$SamAccountName = [System.String]::Empty
)

# Set function to ping DCs for WinRM
function Invoke-PortPing {
[cmdletbinding()]
param(
    [string]$ComputerName,
    [int]$Port,
    [int]$Timeout
)
((New-Object System.Net.Sockets.TcpClient).ConnectAsync($ComputerName,$Port)).Wait($Timeout)
}

## Get DCs & check connectivity
$DCs = (([adsisearcher]'(&(objectCategory=computer)(userAccountControl:1.2.840.113556.1.4.803:=8192))').FindAll() | select -ExpandProperty properties).dnshostname

# Check connectivity through port ping to WinRM
[int]$Port = 5985;
[int]$Timeout = 200; # set timeout in milliseconds. normally less than 100ms should be fine, taking extra response time here.
[int]$i = 1;
[int]$DCCount = ($DCs | Measure-Object).Count
$DCsPostPing = New-Object System.Collections.ArrayList;

$DCs | ForEach-Object {
        $Computer = $_;
        Write-Progress -Activity "Testing for WinRM connectivity. Please wait..." -status "host $i of $DCCount" -percentComplete ($i / $DCCount*100);
        
        if ((Invoke-PortPing -ComputerName $Computer -Port $port -Timeout $timeout -ErrorAction silentlycontinue) -eq "True") {$null = $DCsPostPing.Add($Computer)}
        $i++;
    }
    
Write-Output "`n`n[x] $($DCsPostPing.Count) Domain Controller(s) out of $DCCount responded to connectivity check:`n$DCsPostPing`n";

## Run Jobs 
# Define klist template
$KlistSessionTemplate = @'
Current LogonId is 0:0xf00ac
[0] Session 0 0:{LogonID*:0x28c6ed} {Account:ADATUM\LON-DC1$} {AuthNPackage:Kerberos}:{LogonType:Network}
[1] Session 0 0:{LogonID*:0x1e6a85} {Account:ADATUM\Cai} {AuthNPackage:Kerberos}:{LogonType:Network}
[15] Session 0 0:{LogonID*:0x224e4} {Account:NT AUTHORITY\ANONYMOUS LOGON} {AuthNPackage:NTLM}:{LogonType:Network}
'@

# Clear previous jobs, if any
Get-Job | Remove-Job # -Force

# Run job(s)
$null = Invoke-Command -ComputerName $DCsPostPing -JobName KlistDCs -ScriptBlock {
        $KlistData = klist sessions | ConvertFrom-String -TemplateContent $using:KlistSessionTemplate;
        #$KlistData | foreach {Add-Member -InputObject $_ -MemberType NoteProperty -Name DC -Value $env:COMPUTERNAME -Force}
        return $KlistData
    } -AsJob

# wait for remote winRM jobs to terminate
$null = Get-Job -Name KlistDCs | Wait-Job

# Check if failed jobs exits, and show the error reason
$FailedJobs = Get-Job -Name KlistDCs -IncludeChildJob | Where-Object {$_.state -eq "failed" -and $_.PSJobTypeName -ne "RemoteJob"}

if ($FailedJobs) {
        $FailedJobs | ForEach-Object {Write-Warning "$($_.JobStateInfo.Reason.Message)"}
    }

# Get completed jobs
$CompletedChildJobs = Get-Job -Name KlistDCs -IncludeChildJob | Where-Object {$_.name -ne "KlistDCs" -and $_.State -eq "completed"}

# Check any job(s) completed successfully
if (!$CompletedChildJobs) {
    Write-Host "[!] No jobs completed successfully " -NoNewline; Write-Host "(Do you have PSRemoting permissions to DCs?)" -ForegroundColor Yellow -NoNewline; Write-Host ", or no logon sessions found. Quiting.";
    break
}

# Get sessions data
$LogonSessions = $CompletedChildJobs | Receive-Job -Keep;

# Check if SamAccountName parameter was specified
if ($SamAccountName -ne [System.String]::Empty)
    {
        $SpecificAccountSessions = $LogonSessions | Where-Object account -like "*$SamAccountName";
        if ($SpecificAccountSessions)
            {
                Write-Output "`n[x] Sessions found for Account: $($SamAccountName.ToUpper()) -`n";
                $SpecificAccountSessions | Format-Table LogonID, Account, AuthNPackage, @{n='DC';e={$_.PSComputerName}} -AutoSize
            }
        else
            {
                Write-Host "`n[!] No Sessions found for Account: $($SamAccountName.ToUpper()).`n" -ForegroundColor Yellow
            }
    }

# Get some sessions' statistics
$SessionNetwork = $LogonSessions | Where-Object logontype -eq "Network";
$SessionKerberos = $LogonSessions | Where-Object authNPackage -eq "Kerberos";
$SessionNTLMnegotiate = $LogonSessions | Where-Object authNPackage -ne "Kerberos";
$SessionInteractive = $LogonSessions | Where-Object {$_.LogonType -Like "*interactive*" -and $_.Account -NotLike "*DWM-*"}
$UniqueDomainAccounts = $LogonSessions | Where-Object Account -Like "$ENV:USERDOMAIN\*" | Select-Object Account -Unique

# show statistics and session data
Write-Output "[x] Found $(($LogonSessions | Measure-Object).Count) Logon Sessions, including:`n$(($SessionNetwork | Measure-Object).Count) Remote Sessions connected to DC`n$(($SessionKerberos | Measure-Object).Count) Kerberos Sessions`n$(($SessionNTLMnegotiate | Measure-Object).Count) NTLM\negotiate Sessions`n$(($SessionInteractive | Measure-Object).Count) Interactive Sessions on DCs (Excluding DWM)`n$(($UniqueDomainAccounts | Measure-Object).Count) Domain Accounts (Unique count)";

# Output to CSV or grid, or both, if specified
if ($Output -like "*CSV*")
    {
        $CSVFileName = "$($(Get-Location).Path)\LogonSessionsFromDCs_$($ENV:USERDOMAIN)_$(Get-Date -Format ddMMyyyyHHmmss).csv";
        $LogonSessions | select LogonID, Account, AuthNPackage, @{n='DC';e={$_.PSComputerName}} | Export-Csv $CSVFileName -NoTypeInformation -Force;
        if ($?)
            {
                Write-Host "`nLogon Sessions saved to $CSVFileName.`n" -ForegroundColor Green
            }
        else
            {
                Write-Output "[!] An error occured when saving LogonSessions to CSV.`n$($Error[0])"
            }
        }

if ($Output -like "*Grid*") 
    {
        $LogonSessions | select LogonID, Account, AuthNPackage, @{n='DC';e={$_.PSComputerName}} | Out-GridView -Title "Logon Session(s) from Domain Controllers"
    }
    
# Wrap up
Get-Job -Name KlistDCs | Remove-Job

# Display logon sessions data, or quit
Write-Output "`n[!] Press CTRL+C to quit, OR - To List All Sessions Data - ";
pause;

# List all sessions data, if ENTER was pressed
$LogonSessions | Format-Table LogonID, Account, AuthNPackage, @{n='DC';e={$_.PSComputerName}} -AutoSize