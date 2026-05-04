#Requires -Version 5.1
# Author: J. Chase
# Date: 2026-04-01
<#
.SYNOPSIS
    Network Diagnostic Tool - LinkSprinter-style checks
.DESCRIPTION
    Checks link speed, DHCP, DNS, gateway, and internet connectivity.
    Saves a clean plain-text log to the Desktop. Does not require Administrator.
.PARAMETER PingTarget
    Internet host to ping. Must be a valid IP or hostname. Default: 8.8.8.8
.PARAMETER DNSTestHost
    Hostname to resolve for DNS check. Must be a valid hostname. Default: google.com
#>

param(
    [string]$PingTarget  = "8.8.8.8",
    [string]$DNSTestHost = "google.com"
)

# ---------------------------------------------
#  INPUT VALIDATION
# ---------------------------------------------

if ($PingTarget -notmatch '^[a-zA-Z0-9.\-]+$') {
    Write-Error "Invalid -PingTarget value: '$PingTarget'. Use a valid IP address or hostname."
    exit 1
}

if ($DNSTestHost -notmatch '^[a-zA-Z0-9.\-]+$') {
    Write-Error "Invalid -DNSTestHost value: '$DNSTestHost'. Use a valid hostname."
    exit 1
}

# ---------------------------------------------
#  OUTPUT BUFFER
#  Collect all output into $lines so we can
#  write both console and a clean file at once
# ---------------------------------------------

$lines = [System.Collections.Generic.List[string]]::new()

function Write-Section ([string]$Title) {
    $line = "---  $Title  " + ("-" * [math]::Max(0, 44 - $Title.Length))
    $lines.Add("")
    $lines.Add($line)
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
}

function Write-Row ([string]$Label, [string]$Value, [string]$Status = "info") {
    $color = switch ($Status) {
        "pass"  { "Green"  }
        "fail"  { "Red"    }
        "warn"  { "Yellow" }
        default { "Gray"   }
    }
    $formatted = "  {0,-26}{1}" -f "${Label}:", $Value
    $lines.Add($formatted)
    Write-Host ("  {0,-26}" -f "${Label}:") -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $color
}

function Write-Blank {
    $lines.Add("")
    Write-Host ""
}

function Coalesce ([string]$Value, [string]$Default) {
    if ($Value) { $Value } else { $Default }
}

function Format-Ms ([double]$ms) {
    if ($ms -eq 0) { "<1ms" } else { "${ms}ms" }
}

# ---------------------------------------------
#  HEADER
# ---------------------------------------------

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$header    = "  NETWORK DIAGNOSTIC  |  $timestamp  |  $env:COMPUTERNAME"
$lines.Add($header)
Write-Host ""
Write-Host $header -ForegroundColor White

# ---------------------------------------------
#  1. ADAPTER & LINK
# ---------------------------------------------

Write-Section "ADAPTER & LINK"

$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and
    $_.PhysicalMediaType -ne 'Unspecified' -and
    $_.InterfaceDescription -notmatch 'Virtual|Loopback|Bluetooth|WAN|TAP|VPN'
} | Sort-Object LinkSpeed -Descending | Select-Object -First 1

$linkMbps = 0
if (-not $adapter) {
    Write-Row "Adapter" "No active adapter found" "fail"
    # Flush output and exit early, nothing else will work without an adapter
    $desktopBase = [Environment]::GetFolderPath('Desktop')
    if (-not $desktopBase -or -not (Test-Path $desktopBase)) {
        $desktopBase = $env:TEMP
        Write-Host "  Warning: Desktop not found, log saved to TEMP instead." -ForegroundColor Yellow
    }
    $LogPath = "$desktopBase\NetworkDiag_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $lines | Set-Content -Path $LogPath -Encoding UTF8
    Write-Host ""
    Write-Host "  Log saved to: $LogPath" -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit
} else {
    # LinkSpeed can be a pre-formatted string ("1 Gbps") or raw bits integer depending on driver
    $rawSpeed = $adapter.LinkSpeed
    if ($rawSpeed -is [string]) {
        if      ($rawSpeed -match '(\d+(\.\d+)?)\s*Gbps') { $linkMbps = [int]([double]$Matches[1] * 1000) }
        elseif  ($rawSpeed -match '(\d+(\.\d+)?)\s*Mbps') { $linkMbps = [int][double]$Matches[1] }
        elseif  ($rawSpeed -match '(\d+(\.\d+)?)\s*Kbps') { $linkMbps = [int]([double]$Matches[1] / 1000) }
        else    { $linkMbps = 0 }
    } else {
        $linkMbps = [math]::Round($rawSpeed / 1MB, 0)
    }
    $linkDisplay = if ($linkMbps -ge 1000) { "$([math]::Round($linkMbps/1000))Gbps" } else { "${linkMbps}Mbps" }
    $linkStatus  = if ($linkMbps -ge 1000) { "pass" } elseif ($linkMbps -ge 100) { "warn" } else { "fail" }
    $duplex      = try {
        (Get-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "*Duplex*" -ErrorAction Stop).DisplayValue
    } catch { "Unknown" }

    Write-Row "Adapter"     $adapter.Name
    Write-Row "Description" $adapter.InterfaceDescription
    Write-Row "MAC"         $adapter.MacAddress
    Write-Row "Link Speed"  $linkDisplay $linkStatus
    Write-Row "Duplex"      $duplex
}

# ---------------------------------------------
#  2. DHCP & IP
# ---------------------------------------------

Write-Section "DHCP & IP"

$gateway  = $null
$dhcp     = $null
$isAPIPA  = $false
$ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex

if ($ipConfig) {
    $ipAddr     = @($ipConfig.IPv4Address.IPAddress)[0]
    $prefix     = @($ipConfig.IPv4Address.PrefixLength)[0]
    $gateway    = $ipConfig.IPv4DefaultGateway.NextHop
    $dnsServers = ($ipConfig.DNSServer | Where-Object { $_.AddressFamily -eq 2 <# IPv4 #> }).ServerAddresses -join ", "
    $dhcp       = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).Dhcp

    # APIPA check - 169.254.x.x means DHCP failed and Windows self-assigned
    $isAPIPA = $ipAddr -like "169.254.*"
    $hasIP   = ($null -ne $ipAddr) -and (-not $isAPIPA)
    $ipDisplay = if ($isAPIPA) { "$ipAddr / $prefix (APIPA - DHCP may have failed)" } else { "$ipAddr / $prefix" }
    $ipStatus  = if ($hasIP) { "pass" } else { "fail" }

    $raw        = & "$env:SystemRoot\System32\ipconfig.exe" /all | Out-String
    $dhcpServer = if ($raw -match "DHCP Server[^\:]+:\s+(\d+\.\d+\.\d+\.\d+)") { $Matches[1] } else { "N/A" }
    $leaseGot   = if ($raw -match "Lease Obtained[^\:]+:\s+(.+)")               { $Matches[1].Trim() } else { "N/A" }
    $leaseExp   = if ($raw -match "Lease Expires[^\:]+:\s+(.+)")                { $Matches[1].Trim() } else { "N/A" }

    Write-Row "IP Address"     $ipDisplay $ipStatus
    Write-Row "DHCP"           $dhcp $(if ($dhcp -eq 'Enabled') { "pass" } else { "warn" })
    Write-Row "DHCP Server"    $dhcpServer
    Write-Row "Lease Obtained" $leaseGot
    Write-Row "Lease Expires"  $leaseExp
    Write-Row "Gateway"        (Coalesce $gateway "None")
    Write-Row "DNS Servers"    (Coalesce $dnsServers "None")
} else {
    Write-Row "IP Config" "Could not retrieve" "fail"
}

# ---------------------------------------------
#  3. GATEWAY
# ---------------------------------------------

Write-Section "GATEWAY"

$gwLost        = 4
$sent          = 4
$gwReachableL2 = $false
$gatewayMAC     = $null
$gwTimes       = @()

if ($gateway) {
    # ARP lookup first, tells us if gateway is reachable at Layer 2
    # regardless of whether it responds to ICMP
    try {
        $neighbor = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -eq $gateway } |
                    Select-Object -First 1
        if ($neighbor.LinkLayerAddress) {
            $gatewayMAC     = $neighbor.LinkLayerAddress
            $gwReachableL2 = $true
        }
    } catch {
        # Fall back to arp -a (no elevation needed)
        $arpOut    = & "$env:SystemRoot\System32\arp.exe" -a | Out-String
        $escapedGW = [regex]::Escape($gateway)
        if ($arpOut -match "${escapedGW}\s+([\w\-]{17})") {
            $gatewayMAC     = $Matches[1]
            $gwReachableL2 = $true
        }
    }

    # ICMP ping
    $pinger  = New-Object System.Net.NetworkInformation.Ping
    $gwTimes = @()
    foreach ($i in 1..$sent) {
        try {
            $reply = $pinger.Send([string]$gateway, 1000)
            if ($reply.Status -eq "Success") { $gwTimes += $reply.RoundtripTime }
        } catch { }
    }
    $pinger.Dispose()
    $gwLost = $sent - $gwTimes.Count

    Write-Row "Target" $gateway

    if ($gwTimes.Count -gt 0) {
        $gwAvg           = [math]::Round(($gwTimes | Measure-Object -Average).Average, 1)
        $gwMin           = ($gwTimes | Measure-Object -Minimum).Minimum
        $gwMax           = ($gwTimes | Measure-Object -Maximum).Maximum
        $gwLostPct       = [math]::Round(($gwLost / $sent) * 100)
        $gwLatencyStatus = if ($gwLost -gt 1) { "fail" } elseif ($gwAvg -lt 10) { "pass" } elseif ($gwAvg -lt 20) { "warn" } else { "fail" }
        Write-Row "ICMP Ping"    "Success" "pass"
        Write-Row "Packets Lost" "$gwLost / $sent ($gwLostPct% lost)" $(if ($gwLost -eq 0) { "pass" } elseif ($gwLost -le 1) { "warn" } else { "fail" })
        Write-Row "Avg Latency"  (Format-Ms $gwAvg) $gwLatencyStatus
        Write-Row "Min / Max"    "$(Format-Ms $gwMin) / $(Format-Ms $gwMax)"
    } else {
        # ICMP failed, use ARP result to distinguish filtered vs down
        if ($gwReachableL2) {
            Write-Row "ICMP Ping" "No response - filtered (gateway reachable via ARP)" "warn"
        } else {
            Write-Row "ICMP Ping" "No response - gateway may be down (no ARP entry)" "fail"
        }
    }

    if ($gatewayMAC) {
        Write-Row "Gateway MAC (ARP)" $gatewayMAC
    } else {
        Write-Row "Gateway MAC (ARP)" "not found" "warn"
    }

} else {
    Write-Row "Gateway" "Not detected, skipping gateway checks" "warn"
}

# ---------------------------------------------
#  4. INTERNET
# ---------------------------------------------

Write-Section "INTERNET ($PingTarget)"

$intLost    = 4
$intTimes   = @()
$internetOk = $false

$pinger = New-Object System.Net.NetworkInformation.Ping
foreach ($i in 1..$sent) {
    try {
        $reply = $pinger.Send($PingTarget, 2000)
        if ($reply.Status -eq "Success") { $intTimes += $reply.RoundtripTime }
    } catch { }
}
$pinger.Dispose()
$intLost = $sent - $intTimes.Count

if ($intTimes.Count -gt 0) {
    $intAvg        = [math]::Round(($intTimes | Measure-Object -Average).Average, 1)
    $intMin        = ($intTimes | Measure-Object -Minimum).Minimum
    $intMax        = ($intTimes | Measure-Object -Maximum).Maximum
    $intLostPct    = [math]::Round(($intLost / $sent) * 100)
    $latencyStatus = if ($intLost -gt 1) { "fail" } elseif ($intAvg -lt 50) { "pass" } elseif ($intAvg -lt 100) { "warn" } else { "fail" }
    $internetOk    = $true
    Write-Row "ICMP Ping"    "Success" "pass"
    Write-Row "Packets Lost" "$intLost / $sent ($intLostPct% lost)" $(if ($intLost -eq 0) { "pass" } elseif ($intLost -le 1) { "warn" } else { "fail" })
    Write-Row "Avg Latency"  (Format-Ms $intAvg) $latencyStatus
    Write-Row "Min / Max"    "$(Format-Ms $intMin) / $(Format-Ms $intMax)"
} else {
    # ICMP failed, try TCP port 443 as fallback before declaring no internet
    Write-Row "ICMP Ping" "No response, trying TCP fallback..." "warn"
    $tcp = Test-NetConnection -ComputerName $PingTarget -Port 443 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        $internetOk = $true
        Write-Row "TCP 443 Fallback" "Success, ICMP blocked but internet reachable" "warn"
    } else {
        Write-Row "TCP 443 Fallback" "Failed, internet appears unreachable" "fail"
    }
}

# ---------------------------------------------
#  5. DNS
# ---------------------------------------------

Write-Section "DNS"

$dnsOk = $false
try {
    # [System.Net.Dns] is more compatible across PS 5.1 builds than Resolve-DnsName
    $resolvedIPs = [System.Net.Dns]::GetHostAddresses($DNSTestHost) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' }
    if ($resolvedIPs) {
        $dnsOk      = $true
        $dnsDisplay = ($resolvedIPs | ForEach-Object { $_.IPAddressToString }) -join ", "
        Write-Row "Test Host"    $DNSTestHost
        Write-Row "Resolved IPs" $dnsDisplay "pass"
    } else {
        Write-Row "DNS Resolution" "No A records returned for $DNSTestHost" "fail"
    }
} catch {
    Write-Row "DNS Resolution" "FAILED for $DNSTestHost" "fail"
}

# ---------------------------------------------
#  SUMMARY
# ---------------------------------------------

Write-Section "SUMMARY"
Write-Blank

$gwPingPass = ($gwTimes.Count -gt 0 -and $gwLost -eq 0)
$gwCommPass = ($gwPingPass -or $gwReachableL2)

$checks = @(
    @{ label = "Link Speed"   ; pass = ($linkMbps -ge 100) }
    @{ label = "IP / DHCP"    ; pass = ($null -ne $ipAddr -and -not $isAPIPA) }
    @{ label = "Gateway Comm" ; pass = $gwCommPass }
    @{ label = "Internet"     ; pass = $internetOk }
    @{ label = "DNS"          ; pass = $dnsOk }
)

foreach ($c in $checks) {
    $sym   = if ($c.pass) { "[PASS]" } else { "[FAIL]" }
    $color = if ($c.pass) { "Green"  } else { "Red"    }
    $line  = "  $($sym.PadRight(8)) $($c.label)"
    $lines.Add($line)
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------
#  WRITE LOG FILE
#  Build manually instead of using transcript
#  so the file is clean with no PS header noise
# ---------------------------------------------

Write-Blank

$desktopBase = [Environment]::GetFolderPath('Desktop')
if (-not $desktopBase -or -not (Test-Path $desktopBase)) {
    $desktopBase = $env:TEMP
    Write-Host "  Warning: Desktop not found, log saved to TEMP instead." -ForegroundColor Yellow
}
$LogPath = "$desktopBase\NetworkDiag_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

try {
    $lines | Set-Content -Path $LogPath -Encoding UTF8
    Write-Host "  Log saved to: $LogPath" -ForegroundColor DarkGray
} catch {
    Write-Host "  Could not save log: $_" -ForegroundColor Red
}

Write-Host ""
Read-Host "  Press Enter to close"
