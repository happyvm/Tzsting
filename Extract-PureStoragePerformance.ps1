<#
.SYNOPSIS
    Extrait les métriques IOPS, latence et bande passante (read/write) depuis des baies Pure Storage.

.DESCRIPTION
    Le script interroge l'API REST 2.x via le module PureStoragePowerShellSDK2 et exporte
    un CSV consolidé par baie avec:
      - IOPS read/write/total
      - Bande passante read/write/total (B/s + MiB/s)
      - Latence read/write/total (ms)

    Les valeurs sont collectées sur une fenêtre temporelle configurable et agrégées
    (moyenne, max ou min) par baie.

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

.PARAMETER Aggregation
    Type d'agrégation: average, max, min.

.PARAMETER OutputCsv
    Fichier CSV de sortie.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Script interactif: affichage console intentionnel')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Mot de passe en clair supporté dans config locale uniquement')]
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Arrays = @(),

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config-pure-performance.psd1'),

    [Parameter()]
    [int]$ResolutionMs = 30000,

    [Parameter()]
    [int]$WindowMinutes = 60,

    [Parameter()]
    [ValidateSet('average', 'max', 'min')]
    [string]$Aggregation = 'average',

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
    if (-not $PSBoundParameters.ContainsKey('ResolutionMs') -and $cfg.ContainsKey('ResolutionMs')) { $ResolutionMs = [int]$cfg.ResolutionMs }
    if (-not $PSBoundParameters.ContainsKey('WindowMinutes') -and $cfg.ContainsKey('WindowMinutes')) { $WindowMinutes = [int]$cfg.WindowMinutes }
    if (-not $PSBoundParameters.ContainsKey('Aggregation') -and $cfg.ContainsKey('Aggregation')) { $Aggregation = [string]$cfg.Aggregation }
    if (-not $PSBoundParameters.ContainsKey('OutputCsv') -and $cfg.ContainsKey('OutputCsv')) { $OutputCsv = [string]$cfg.OutputCsv }
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

        $perf = Get-Pfa2ArrayPerformance -Array $session.Session -StartTime $startTime -EndTime $endTime -Resolution $ResolutionMs -Type $Aggregation
        if (-not $perf) {
            Write-Warning "Aucune donnée performance pour '$array'."
            continue
        }

        foreach ($point in @($perf)) {
            $readIops = [double]$point.ReadsPerSec
            $writeIops = [double]$point.WritesPerSec
            $readBps = [double]$point.InputPerSec
            $writeBps = [double]$point.OutputPerSec
            $readLatUs = [double]$point.UsecPerReadOp
            $writeLatUs = [double]$point.UsecPerWriteOp

            $row = [PSCustomObject]@{
                Array                  = $array
                Timestamp               = $point.Time
                Aggregation             = $Aggregation
                WindowMinutes           = $WindowMinutes
                ResolutionMs            = $ResolutionMs
                ReadIOPS                = [Math]::Round($readIops, 2)
                WriteIOPS               = [Math]::Round($writeIops, 2)
                TotalIOPS               = [Math]::Round(($readIops + $writeIops), 2)
                ReadBandwidthBps        = [Math]::Round($readBps, 2)
                WriteBandwidthBps       = [Math]::Round($writeBps, 2)
                TotalBandwidthBps       = [Math]::Round(($readBps + $writeBps), 2)
                ReadBandwidthMiBps      = Convert-BytesToMiB -BytesPerSec $readBps
                WriteBandwidthMiBps     = Convert-BytesToMiB -BytesPerSec $writeBps
                TotalBandwidthMiBps     = Convert-BytesToMiB -BytesPerSec ($readBps + $writeBps)
                ReadLatencyMs           = [Math]::Round(($readLatUs / 1000), 3)
                WriteLatencyMs          = [Math]::Round(($writeLatUs / 1000), 3)
                TotalLatencyMs          = [Math]::Round(((($readLatUs + $writeLatUs) / 2) / 1000), 3)
            }
            $allRows.Add($row) | Out-Null
        }
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

$allRows | Sort-Object Array, Timestamp | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host "CSV exporté: $OutputCsv ($($allRows.Count) lignes)" -ForegroundColor Green
