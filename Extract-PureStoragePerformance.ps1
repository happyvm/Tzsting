<#
.SYNOPSIS
    Extrait les métriques IOPS, latence et bande passante (read/write) depuis des baies Pure Storage.

.DESCRIPTION
    Le script interroge l'API REST 2.x via le module PureStoragePowerShellSDK2 et exporte
    un CSV consolidé par baie avec:
      - IOPS read/write/total
      - Bande passante read/write/total (B/s + MiB/s)
      - Latence read/write/total (ms)

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

        # Pure Storage: OutputPerSec = lecture hôte (sortant de la baie), InputPerSec = écriture hôte (entrant)
        $riVals  = @($points | ForEach-Object { [double]$_.ReadsPerSec })
        $wiVals  = @($points | ForEach-Object { [double]$_.WritesPerSec })
        $rbVals  = @($points | ForEach-Object { [double]$_.OutputPerSec })
        $wbVals  = @($points | ForEach-Object { [double]$_.InputPerSec })
        $rlVals  = @($points | ForEach-Object { [double]$_.UsecPerReadOp })
        $wlVals  = @($points | ForEach-Object { [double]$_.UsecPerWriteOp })

        $c = @{}
        foreach ($type in @('min', 'average', 'max')) {
            $ri = switch ($type) { 'average' { ($riVals | Measure-Object -Average).Average } 'max' { ($riVals | Measure-Object -Maximum).Maximum } 'min' { ($riVals | Measure-Object -Minimum).Minimum } }
            $wi = switch ($type) { 'average' { ($wiVals | Measure-Object -Average).Average } 'max' { ($wiVals | Measure-Object -Maximum).Maximum } 'min' { ($wiVals | Measure-Object -Minimum).Minimum } }
            $rb = switch ($type) { 'average' { ($rbVals | Measure-Object -Average).Average } 'max' { ($rbVals | Measure-Object -Maximum).Maximum } 'min' { ($rbVals | Measure-Object -Minimum).Minimum } }
            $wb = switch ($type) { 'average' { ($wbVals | Measure-Object -Average).Average } 'max' { ($wbVals | Measure-Object -Maximum).Maximum } 'min' { ($wbVals | Measure-Object -Minimum).Minimum } }
            $rl = switch ($type) { 'average' { ($rlVals | Measure-Object -Average).Average } 'max' { ($rlVals | Measure-Object -Maximum).Maximum } 'min' { ($rlVals | Measure-Object -Minimum).Minimum } }
            $wl = switch ($type) { 'average' { ($wlVals | Measure-Object -Average).Average } 'max' { ($wlVals | Measure-Object -Maximum).Maximum } 'min' { ($wlVals | Measure-Object -Minimum).Minimum } }
            $c[$type] = @{
                ReadIOPS            = [Math]::Round($ri, 2)
                WriteIOPS           = [Math]::Round($wi, 2)
                TotalIOPS           = [Math]::Round($ri + $wi, 2)
                ReadBandwidthMiBps  = Convert-BytesToMiB -BytesPerSec $rb
                WriteBandwidthMiBps = Convert-BytesToMiB -BytesPerSec $wb
                TotalBandwidthMiBps = Convert-BytesToMiB -BytesPerSec ($rb + $wb)
                ReadLatencyMs       = [Math]::Round($rl / 1000, 3)
                WriteLatencyMs      = [Math]::Round($wl / 1000, 3)
                TotalLatencyMs      = [Math]::Round(($rl + $wl) / 2 / 1000, 3)
            }
        }

        $row = [PSCustomObject]@{
            Array                       = $array
            WindowMinutes               = $WindowMinutes
            ResolutionMs                = $ResolutionMs
            SampleCount                 = $points.Count
            ReadIOPS_Min                = $c['min'].ReadIOPS
            ReadIOPS_Avg                = $c['average'].ReadIOPS
            ReadIOPS_Max                = $c['max'].ReadIOPS
            WriteIOPS_Min               = $c['min'].WriteIOPS
            WriteIOPS_Avg               = $c['average'].WriteIOPS
            WriteIOPS_Max               = $c['max'].WriteIOPS
            TotalIOPS_Min               = $c['min'].TotalIOPS
            TotalIOPS_Avg               = $c['average'].TotalIOPS
            TotalIOPS_Max               = $c['max'].TotalIOPS
            ReadBandwidthMiBps_Min      = $c['min'].ReadBandwidthMiBps
            ReadBandwidthMiBps_Avg      = $c['average'].ReadBandwidthMiBps
            ReadBandwidthMiBps_Max      = $c['max'].ReadBandwidthMiBps
            WriteBandwidthMiBps_Min     = $c['min'].WriteBandwidthMiBps
            WriteBandwidthMiBps_Avg     = $c['average'].WriteBandwidthMiBps
            WriteBandwidthMiBps_Max     = $c['max'].WriteBandwidthMiBps
            TotalBandwidthMiBps_Min     = $c['min'].TotalBandwidthMiBps
            TotalBandwidthMiBps_Avg     = $c['average'].TotalBandwidthMiBps
            TotalBandwidthMiBps_Max     = $c['max'].TotalBandwidthMiBps
            ReadLatencyMs_Min           = $c['min'].ReadLatencyMs
            ReadLatencyMs_Avg           = $c['average'].ReadLatencyMs
            ReadLatencyMs_Max           = $c['max'].ReadLatencyMs
            WriteLatencyMs_Min          = $c['min'].WriteLatencyMs
            WriteLatencyMs_Avg          = $c['average'].WriteLatencyMs
            WriteLatencyMs_Max          = $c['max'].WriteLatencyMs
            TotalLatencyMs_Min          = $c['min'].TotalLatencyMs
            TotalLatencyMs_Avg          = $c['average'].TotalLatencyMs
            TotalLatencyMs_Max          = $c['max'].TotalLatencyMs
        }
        $allRows.Add($row) | Out-Null
    }
    catch {
        Write-Error "Erreur sur '$array': $($_.Exception.Message)"
    }
    finally {
        if ($session) { Close-PureApiSession -Session $session }
    }
}

if ($allRows.Count -eq 0) {
    throw 'Aucune ligne à exporter.'
}

$allRows | Sort-Object Array | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host "CSV exporté: $OutputCsv ($($allRows.Count) lignes)" -ForegroundColor Green
