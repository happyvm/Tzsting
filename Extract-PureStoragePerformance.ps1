<#
.SYNOPSIS
    Extrait les métriques IOPS, latence et bande passante (read/write) depuis des baies Pure Storage.

.DESCRIPTION
    Le script interroge l'API REST 2.x via le module PureStoragePowerShellSDK2 et exporte
    un CSV consolidé par baie avec:
      - IOPS read/write/total
      - Bande passante read/write/total (B/s + MiB/s)
      - Latence read/write (ms)

    Les valeurs sont collectées sur une fenêtre temporelle configurable et exportées
    avec les trois agrégations (min, average, max) en colonnes distinctes par baie.

.PARAMETER Arrays
    Liste des baies à interroger.

.PARAMETER Credential
    Identifiant API Pure Storage (lecture).

.PARAMETER ConfigFile
    Fichier .psd1 de configuration.

.PARAMETER ResolutionMs
    Résolution en millisecondes des points de performance (ex: 30000 = 30s).

.PARAMETER WindowMinutes
    Fenêtre temporelle en minutes à extraire depuis maintenant.

.PARAMETER OutputCsv
    Fichier CSV de sortie.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Script interactif: affichage console intentionnel')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Mot de passe en clair supporté dans config locale uniquement')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Script de collecte ponctuel: ShouldProcess non pertinent')]
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Arrays = @(),

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config-pure.psd1'),

    [Parameter()]
    [int]$ResolutionMs = 30000,

    [Parameter()]
    [int]$WindowMinutes = 60,

    [Parameter()]
    [string]$OutputCsv = '.\pure-performance.csv',

    [Parameter()]
    [switch]$IgnoreCertificateErrors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $ConfigFile) {
    $cfg = Import-PowerShellDataFile -LiteralPath $ConfigFile

    if (-not $PSBoundParameters.ContainsKey('Arrays') -and $cfg.ContainsKey('Arrays')) { $Arrays = @($cfg.Arrays | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    if (-not $PSBoundParameters.ContainsKey('ResolutionMs')) {
        if ($cfg.ContainsKey('PerformanceResolutionMs')) { $ResolutionMs = [int]$cfg.PerformanceResolutionMs }
        elseif ($cfg.ContainsKey('ResolutionMs')) { $ResolutionMs = [int]$cfg.ResolutionMs }
    }
    if (-not $PSBoundParameters.ContainsKey('WindowMinutes')) {
        if ($cfg.ContainsKey('PerformanceWindowMinutes')) { $WindowMinutes = [int]$cfg.PerformanceWindowMinutes }
        elseif ($cfg.ContainsKey('WindowMinutes')) { $WindowMinutes = [int]$cfg.WindowMinutes }
    }
    if (-not $PSBoundParameters.ContainsKey('OutputCsv')) {
        if ($cfg.ContainsKey('PerformanceOutputCsv')) { $OutputCsv = [string]$cfg.PerformanceOutputCsv }
    }
    if (-not $PSBoundParameters.ContainsKey('IgnoreCertificateErrors') -and $cfg.ContainsKey('IgnoreCertificateErrors')) {
        if ([bool]$cfg.IgnoreCertificateErrors) { $IgnoreCertificateErrors = $true }
    }

    $arrayCredentialMap = @{}
    if ($cfg.ContainsKey('ArrayCredentials')) {
        foreach ($entry in $cfg.ArrayCredentials) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Array) -or [string]::IsNullOrWhiteSpace([string]$entry.UserName)) { continue }
            $plain = [string]$entry.Password
            $secure = if ([string]::IsNullOrWhiteSpace($plain)) { $null } else { ConvertTo-SecureString $plain -AsPlainText -Force }
            $arrayCredentialMap[[string]$entry.Array] = [PSCustomObject]@{
                UserName = [string]$entry.UserName
                Password = $secure
            }
        }
    }

    if ((-not $PSBoundParameters.ContainsKey('Arrays')) -and (($null -eq $Arrays) -or $Arrays.Count -eq 0) -and $arrayCredentialMap.Count -gt 0) {
        $Arrays = @($arrayCredentialMap.Keys | Sort-Object)
    }
}
else {
    $arrayCredentialMap = @{}
}

if (-not $Arrays -or $Arrays.Count -eq 0) {
    throw "Aucune baie fournie. Définissez -Arrays ou ajoutez la clé 'Arrays' dans le fichier de configuration ($ConfigFile)."
}

if ($ResolutionMs -le 0) { throw "ResolutionMs doit être un entier positif (valeur reçue: $ResolutionMs)." }
if ($WindowMinutes -le 0) { throw "WindowMinutes doit être un entier positif (valeur reçue: $WindowMinutes)." }

if (-not $Credential -and $arrayCredentialMap.Count -eq 0) {
    $Credential = Get-Credential -Message 'Compte API Pure Storage (lecture)'
}

Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
$script:PureModuleSessionCmdlets = @{ Connect = 'Connect-Pfa2Array'; Disconnect = 'Disconnect-Pfa2Array' }

function Get-ArrayCredential {
    param([string]$Array,[PSCredential]$DefaultCredential)

    if ($arrayCredentialMap.ContainsKey($Array)) {
        $entry = $arrayCredentialMap[$Array]
        if ($entry.Password) { return [PSCredential]::new($entry.UserName, $entry.Password) }
        $secure = Read-Host -AsSecureString -Prompt "Mot de passe pour '$($entry.UserName)' sur '$Array'"
        return [PSCredential]::new($entry.UserName, $secure)
    }

    if ($null -eq $DefaultCredential) { throw "Aucun identifiant disponible pour '$Array'." }
    return $DefaultCredential
}

function New-PureApiSession {
    param([string]$Array,[PSCredential]$Credential)

    $connectCommand = Get-Command -Name $script:PureModuleSessionCmdlets.Connect -ErrorAction Stop
    $connectParams = @{ Credential = $Credential }

    foreach ($candidate in 'EndPoint','Array','Fqdn','ComputerName') {
        if ($connectCommand.Parameters.ContainsKey($candidate)) { $connectParams[$candidate] = $Array; break }
    }

    if ($IgnoreCertificateErrors) {
        foreach ($candidate in 'IgnoreCertificateError','IgnoreCertificateErrors','SkipCertificateCheck','SkipCertificateValidation') {
            if ($connectCommand.Parameters.ContainsKey($candidate)) { $connectParams[$candidate] = $true; break }
        }
    }

    $session = & $script:PureModuleSessionCmdlets.Connect @connectParams
    if (-not $session) { throw "Connexion SDK impossible sur la baie '$Array'." }
    return @{ Session = $session }
}

function Close-PureApiSession {
    param([hashtable]$Session)
    if ($null -ne $Session) { & $script:PureModuleSessionCmdlets.Disconnect -Array $Session.Session | Out-Null }
}

function Convert-BytesToMiB { param([double]$BytesPerSec) [Math]::Round(($BytesPerSec / 1MB), 2) }

function Resolve-PropName {
    param([object]$Sample, [string[]]$Candidates)
    foreach ($name in $Candidates) {
        $p = $Sample.PSObject.Properties.Match($name)
        if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $name }
    }
    return $null
}

$allRows = New-Object System.Collections.Generic.List[object]
$endTime = Get-Date
$startTime = $endTime.AddMinutes(-1 * $WindowMinutes)

foreach ($array in $Arrays) {
    Write-Host "`n=== Baie: $array ===" -ForegroundColor Cyan
    $session = $null
    try {
        $arrayCredential = Get-ArrayCredential -Array $array -DefaultCredential $Credential
        $session = New-PureApiSession -Array $array -Credential $arrayCredential

        $perfData = Get-Pfa2ArrayPerformance -Array $session.Session -StartTime $startTime -EndTime $endTime -Resolution $ResolutionMs
        $points = @($perfData)
        if ($points.Count -eq 0) {
            Write-Warning "Aucune donnée performance pour '$array'."
            continue
        }

        Write-Verbose "Propriétés SDK disponibles: $($points[0].PSObject.Properties.Name -join ', ')"

        $propRI = Resolve-PropName $points[0] 'ReadsPerSec','reads_per_sec','ReadIops'
        $propWI = Resolve-PropName $points[0] 'WritesPerSec','writes_per_sec','WriteIops'
        $propRB = Resolve-PropName $points[0] 'ReadBytesPerSec','read_bytes_per_sec','OutputPerSec','output_per_sec'
        $propWB = Resolve-PropName $points[0] 'WriteBytesPerSec','write_bytes_per_sec','InputPerSec','input_per_sec'
        $propRL = Resolve-PropName $points[0] 'UsecPerReadOp','usec_per_read_op','ReadLatencyUsec'
        $propWL = Resolve-PropName $points[0] 'UsecPerWriteOp','usec_per_write_op','WriteLatencyUsec'

        $n    = $points.Count
        $INF  = [double]::MaxValue
        $sums = @{ ri=0.0; wi=0.0; rb=0.0; wb=0.0; rl=0.0; wl=0.0; ti=0.0; tb=0.0 }
        $mins = @{ ri=$INF; wi=$INF; rb=$INF; wb=$INF; rl=$INF; wl=$INF; ti=$INF; tb=$INF }
        $maxs = @{ ri=0.0; wi=0.0; rb=0.0; wb=0.0; rl=0.0; wl=0.0; ti=0.0; tb=0.0 }

        foreach ($pt in $points) {
            $ri = if ($null -ne $propRI) { [double]$pt.$propRI } else { 0.0 }
            $wi = if ($null -ne $propWI) { [double]$pt.$propWI } else { 0.0 }
            $rb = if ($null -ne $propRB) { [double]$pt.$propRB } else { 0.0 }
            $wb = if ($null -ne $propWB) { [double]$pt.$propWB } else { 0.0 }
            $rl = if ($null -ne $propRL) { [double]$pt.$propRL } else { 0.0 }
            $wl = if ($null -ne $propWL) { [double]$pt.$propWL } else { 0.0 }
            $ti = $ri + $wi
            $tb = $rb + $wb
            $sums.ri += $ri; $sums.wi += $wi; $sums.rb += $rb; $sums.wb += $wb
            $sums.rl += $rl; $sums.wl += $wl; $sums.ti += $ti; $sums.tb += $tb
            if ($ri -lt $mins.ri) { $mins.ri = $ri }; if ($ri -gt $maxs.ri) { $maxs.ri = $ri }
            if ($wi -lt $mins.wi) { $mins.wi = $wi }; if ($wi -gt $maxs.wi) { $maxs.wi = $wi }
            if ($rb -lt $mins.rb) { $mins.rb = $rb }; if ($rb -gt $maxs.rb) { $maxs.rb = $rb }
            if ($wb -lt $mins.wb) { $mins.wb = $wb }; if ($wb -gt $maxs.wb) { $maxs.wb = $wb }
            if ($rl -lt $mins.rl) { $mins.rl = $rl }; if ($rl -gt $maxs.rl) { $maxs.rl = $rl }
            if ($wl -lt $mins.wl) { $mins.wl = $wl }; if ($wl -gt $maxs.wl) { $maxs.wl = $wl }
            if ($ti -lt $mins.ti) { $mins.ti = $ti }; if ($ti -gt $maxs.ti) { $maxs.ti = $ti }
            if ($tb -lt $mins.tb) { $mins.tb = $tb }; if ($tb -gt $maxs.tb) { $maxs.tb = $tb }
        }

        $avg = @{}
        foreach ($k in $sums.Keys) { $avg[$k] = $sums[$k] / $n }

        $row = [PSCustomObject]@{
            Array                   = $array
            WindowMinutes           = $WindowMinutes
            ResolutionMs            = $ResolutionMs
            SampleCount             = $n
            ReadIOPS_Min            = [Math]::Round($mins.ri, 2)
            ReadIOPS_Avg            = [Math]::Round($avg.ri, 2)
            ReadIOPS_Max            = [Math]::Round($maxs.ri, 2)
            WriteIOPS_Min           = [Math]::Round($mins.wi, 2)
            WriteIOPS_Avg           = [Math]::Round($avg.wi, 2)
            WriteIOPS_Max           = [Math]::Round($maxs.wi, 2)
            TotalIOPS_Min           = [Math]::Round($mins.ti, 2)
            TotalIOPS_Avg           = [Math]::Round($avg.ti, 2)
            TotalIOPS_Max           = [Math]::Round($maxs.ti, 2)
            ReadBandwidthMiBps_Min  = Convert-BytesToMiB $mins.rb
            ReadBandwidthMiBps_Avg  = Convert-BytesToMiB $avg.rb
            ReadBandwidthMiBps_Max  = Convert-BytesToMiB $maxs.rb
            WriteBandwidthMiBps_Min = Convert-BytesToMiB $mins.wb
            WriteBandwidthMiBps_Avg = Convert-BytesToMiB $avg.wb
            WriteBandwidthMiBps_Max = Convert-BytesToMiB $maxs.wb
            TotalBandwidthMiBps_Min = Convert-BytesToMiB $mins.tb
            TotalBandwidthMiBps_Avg = Convert-BytesToMiB $avg.tb
            TotalBandwidthMiBps_Max = Convert-BytesToMiB $maxs.tb
            ReadLatencyMs_Min       = [Math]::Round($mins.rl / 1000, 3)
            ReadLatencyMs_Avg       = [Math]::Round($avg.rl / 1000, 3)
            ReadLatencyMs_Max       = [Math]::Round($maxs.rl / 1000, 3)
            WriteLatencyMs_Min      = [Math]::Round($mins.wl / 1000, 3)
            WriteLatencyMs_Avg      = [Math]::Round($avg.wl / 1000, 3)
            WriteLatencyMs_Max      = [Math]::Round($maxs.wl / 1000, 3)
            DeltaIOPS_Avg           = [Math]::Round($avg.ri - $avg.wi, 2)
            DeltaBandwidthMiBps_Avg = [Math]::Round((Convert-BytesToMiB $avg.rb) - (Convert-BytesToMiB $avg.wb), 2)
            DeltaLatencyMs_Avg      = [Math]::Round(($avg.rl - $avg.wl) / 1000, 3)
        }
        [void]$allRows.Add($row)
    }
    catch {
        Write-Warning "Erreur sur '$array': $($_.Exception.Message)"
    }
    finally {
        if ($session) { Close-PureApiSession -Session $session }
    }
}

if ($allRows.Count -eq 0) {
    throw 'Aucune ligne à exporter.'
}

$outputDir = Split-Path -Parent $OutputCsv
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    throw "Le répertoire de sortie n'existe pas: $outputDir"
}

$allRows | Sort-Object Array | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host "CSV exporté: $OutputCsv ($($allRows.Count) lignes)" -ForegroundColor Green
