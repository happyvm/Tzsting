<#!
.SYNOPSIS
    Liste les volumes Pure Storage présentés à des serveurs physiques (en excluant ESX/Hyper-V).

.DESCRIPTION
    Le script se connecte à plusieurs baies Pure Storage FlashArray via l'API REST 2.x,
    récupère les informations de baie (modèle, réduction de données, capacité raw),
    puis les volumes et leurs connexions hôte/hostgroup.

    Il filtre les hôtes qui ressemblent à des hyperviseurs (ESX, VMware, Hyper-V)
    pour ne conserver que les serveurs physiques.

    Résultat:
      - affichage console d'un résumé par baie
      - export CSV consolidé des volumes physiques

.PARAMETER Arrays
    Liste des FQDN/IP des baies Pure Storage.

.PARAMETER Credential
    Identifiant Pure Storage avec droits de lecture API.

.PARAMETER ApiVersion
    Version d'API REST Pure (par défaut: 2.38).

.PARAMETER ExcludeHostRegex
    Expression régulière utilisée pour exclure les hyperviseurs.

.PARAMETER OutputCsv
    Chemin de sortie CSV.

.EXAMPLE
    $arrays = @('fa-prod-01.company.local','fa-prod-02.company.local')
    .\List-PureStoragePhysicalVolumes.ps1 -Arrays $arrays -OutputCsv .\pure-physical-volumes.csv
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Arrays = @(),

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config-pure.psd1'),

    [Parameter()]
    [string]$ApiVersion = '2.38',

    [Parameter()]
    [string]$ExcludeHostRegex = '(?i)(^|[-_.])(esx\d*|esxi\d*|vmware|hyper-?v|hv\d+)([-_.]|$)',

    [Parameter()]
    [string]$OutputCsv = '.\pure-physical-volumes.csv',

    [Parameter()]
    [switch]$IgnoreCertificateErrors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


if (Test-Path -LiteralPath $ConfigFile) {
    $cfg = Import-PowerShellDataFile -LiteralPath $ConfigFile

    if (-not $PSBoundParameters.ContainsKey('ApiVersion') -and $cfg.ContainsKey('ApiVersion')) { $ApiVersion = [string]$cfg.ApiVersion }
    if (-not $PSBoundParameters.ContainsKey('Arrays') -and $cfg.ContainsKey('Arrays')) { $Arrays = @($cfg.Arrays | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    if (-not $PSBoundParameters.ContainsKey('ExcludeHostRegex') -and $cfg.ContainsKey('ExcludeHostRegex')) { $ExcludeHostRegex = [string]$cfg.ExcludeHostRegex }
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
        Write-Verbose "Aucune clé 'Arrays' configurée: utilisation des baies définies dans 'ArrayCredentials'."
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
$script:PureModuleSessionCmdlets = @{
    Connect    = 'Connect-Pfa2Array'
    Disconnect = 'Disconnect-Pfa2Array'
    Invoke     = 'Invoke-Pfa2RestMethod'
}
Write-Host "Module PureStoragePowerShellSDK2 chargé." -ForegroundColor Green

function Get-ObjValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [object]$Default = $null
    )

    foreach ($name in $Names) {
        $parts = $name -split '\.'
        $current = $Object
        $found = $true
        foreach ($part in $parts) {
            if ($null -eq $current -or -not $current.PSObject.Properties[$part]) { $found = $false; break }
            $current = $current.$part
        }
        if ($found -and $null -ne $current -and "$current" -ne '') {
            return $current
        }
    }

    return $Default
}

function Get-ReplicationType {
    param([Parameter(Mandatory = $true)][object]$Volume)

    $syncIndicators = @(
        (Get-ObjValue -Object $Volume -Names @('sync_replication', 'is_sync_replicated') -Default $false),
        (Get-ObjValue -Object $Volume -Names @('pod') -Default $null),
        (Get-ObjValue -Object $Volume -Names @('active_cluster') -Default $false)
    )

    $asyncIndicators = @(
        (Get-ObjValue -Object $Volume -Names @('async_replication', 'is_async_replicated') -Default $false),
        (Get-ObjValue -Object $Volume -Names @('protection_group') -Default $null)
    )

    $isSync = $false
    foreach ($i in $syncIndicators) {
        if ($i -is [bool] -and $i) { $isSync = $true; break }
        if ($i -and "$i" -ne '') { $isSync = $true; break }
    }

    $isAsync = $false
    foreach ($i in $asyncIndicators) {
        if ($i -is [bool] -and $i) { $isAsync = $true; break }
        if ($i -and "$i" -ne '') { $isAsync = $true; break }
    }

    if ($isSync) { return 'actif/actif' }
    if ($isAsync) { return 'asynchrone' }
    return 'non répliqué'
}

function New-PureApiSession {
    param([string]$Array,[PSCredential]$Credential)

    $connectCommand = Get-Command -Name $script:PureModuleSessionCmdlets.Connect -ErrorAction Stop
    $connectParams = @{ Credential = $Credential }

    if ($connectCommand.Parameters.ContainsKey('EndPoint')) {
        $connectParams['EndPoint'] = $Array
    }
    elseif ($connectCommand.Parameters.ContainsKey('Array')) {
        $connectParams['Array'] = $Array
    }
    elseif ($connectCommand.Parameters.ContainsKey('Fqdn')) {
        $connectParams['Fqdn'] = $Array
    }
    elseif ($connectCommand.Parameters.ContainsKey('ComputerName')) {
        $connectParams['ComputerName'] = $Array
    }
    else {
        throw "Impossible de déterminer le paramètre d'adresse pour $($script:PureModuleSessionCmdlets.Connect). Paramètres détectés: $($connectCommand.Parameters.Keys -join ', ')."
    }

    if ($IgnoreCertificateErrors) {
        if ($connectCommand.Parameters.ContainsKey('IgnoreCertificateError')) {
            $connectParams['IgnoreCertificateError'] = $true
        }
        elseif ($connectCommand.Parameters.ContainsKey('IgnoreCertificateErrors')) {
            $connectParams['IgnoreCertificateErrors'] = $true
        }
        elseif ($connectCommand.Parameters.ContainsKey('SkipCertificateCheck')) {
            $connectParams['SkipCertificateCheck'] = $true
        }
        elseif ($connectCommand.Parameters.ContainsKey('SkipCertificateValidation')) {
            $connectParams['SkipCertificateValidation'] = $true
        }
        else {
            Write-Warning "Le cmdlet $($script:PureModuleSessionCmdlets.Connect) ne supporte pas les options d'ignore certificat connues."
        }
    }

    $session = & $script:PureModuleSessionCmdlets.Connect @connectParams
    if (-not $session) { throw "Connexion SDK impossible sur la baie '$Array'." }
    return @{ Mode = 'Module'; Session = $session }
}

function Invoke-PureApiWithSession {
    param(
        [Parameter(Mandatory = $true)][string]$Array,
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][object]$Body
    )

    $invokeParams = @{ Array = $Session.Session; Method = $Method; Path = $Path }
    if ($Body) { $invokeParams.Body = $Body }
    return (& $script:PureModuleSessionCmdlets.Invoke @invokeParams)
}

function Close-PureApiSession {
    param([string]$Array,[hashtable]$Session)

    try {
        & $script:PureModuleSessionCmdlets.Disconnect -Array $Session.Session | Out-Null
    }
    catch { Write-Warning "Déconnexion API échouée pour '$Array': $($_.Exception.Message)" }
}


function Get-ArrayCredential {
    param([string]$Array,[PSCredential]$DefaultCredential)

    if ($arrayCredentialMap.ContainsKey($Array)) {
        $entry = $arrayCredentialMap[$Array]
        if ($entry.Password) {
            return [PSCredential]::new($entry.UserName, $entry.Password)
        }

        $prompt = "Mot de passe pour l'utilisateur '$($entry.UserName)' sur la baie '$Array'"
        $secure = Read-Host -AsSecureString -Prompt $prompt
        return [PSCredential]::new($entry.UserName, $secure)
    }

    if ($null -eq $DefaultCredential) {
        throw "Aucun identifiant disponible pour la baie '$Array' (ni Credential global, ni entrée ArrayCredentials)."
    }

    return $DefaultCredential
}

$allRows = New-Object System.Collections.Generic.List[object]

foreach ($array in $Arrays) {
    Write-Host "`n=== Baie: $array ===" -ForegroundColor Cyan
    $session = $null

    try {
        $arrayCredential = Get-ArrayCredential -Array $array -DefaultCredential $Credential
        $session = New-PureApiSession -Array $array -Credential $arrayCredential

        $arrayInfoResponse = Invoke-PureApiWithSession -Array $array -Method 'GET' -Path 'arrays' -Session $session
        $arraySpaceResponse = Invoke-PureApiWithSession -Array $array -Method 'GET' -Path 'arrays/space' -Session $session
        $volumesResponse = Invoke-PureApiWithSession -Array $array -Method 'GET' -Path 'volumes?limit=10000' -Session $session
        $connectionsResponse = Invoke-PureApiWithSession -Array $array -Method 'GET' -Path 'connections?limit=10000' -Session $session

        $arrayInfo = @($arrayInfoResponse.items)[0]
        $arraySpace = @($arraySpaceResponse.items)[0]

        $model = [string](Get-ObjValue -Object $arrayInfo -Names @('model') -Default 'N/A')
        $dataReduction = [double](Get-ObjValue -Object $arraySpace -Names @('data_reduction', 'total_reduction') -Default 0)
        $rawBytes = [double](Get-ObjValue -Object $arraySpace -Names @('capacity', 'total_capacity', 'space.total_physical') -Default 0)
        $rawTiB = [Math]::Round(($rawBytes / 1TB), 2)

        Write-Host ("Modèle: {0} | Ratio dédup+compression: {1}x | Capacité raw: {2} TiB" -f $model, ([Math]::Round($dataReduction, 2)), $rawTiB) -ForegroundColor Gray

        $volumes = @($volumesResponse.items)
        $connections = @($connectionsResponse.items)

        if ($volumes.Count -eq 0) {
            Write-Host "Aucun volume trouvé." -ForegroundColor Yellow
            continue
        }

        $volumesByName = @{}
        foreach ($vol in $volumes) { $volumesByName[$vol.name] = $vol }

        $physicalConnections = $connections | Where-Object {
            $connHostName = [string]$_.host.name
            $connHostGroup = [string]$_.host_group.name
            -not ($connHostName -match $ExcludeHostRegex) -and -not ($connHostGroup -match $ExcludeHostRegex)
        }

        foreach ($conn in $physicalConnections) {
            $volName = [string]$conn.volume.name
            if (-not $volumesByName.ContainsKey($volName)) { continue }

            $vol = $volumesByName[$volName]
            $sizeGiB = [Math]::Round(([double](Get-ObjValue -Object $vol -Names @('provisioned', 'space.total', 'size') -Default 0) / 1GB), 2)

            $allRows.Add([PSCustomObject]@{
                Array              = $array
                ArrayModel         = $model
                ArrayReduction     = [Math]::Round($dataReduction, 2)
                ArrayRawTiB        = $rawTiB
                Volume             = $vol.name
                VolumeGiB          = $sizeGiB
                Serial             = $vol.serial
                Host               = [string]$conn.host.name
                HostGroup          = [string]$conn.host_group.name
                Protocol           = [string]$conn.protocol_endpoint_type
                Lun                = [string]$conn.lun
                ReplicationType    = Get-ReplicationType -Volume $vol
            })
        }

        $currentArrayRows = $allRows | Where-Object { $_.Array -eq $array }
        if ($currentArrayRows.Count -eq 0) {
            Write-Host "Aucun volume mappé à un serveur physique après filtrage ESX/Hyper-V." -ForegroundColor Yellow
        }
        else {
            $currentArrayRows |
                Sort-Object Host, Volume |
                Format-Table Array, Host, HostGroup, Volume, VolumeGiB, ReplicationType, Lun -AutoSize
        }
    }
    catch {
        Write-Error "Erreur sur la baie '$array': $($_.Exception.Message)"
    }
    finally {
        if ($session) { Close-PureApiSession -Array $array -Session $session }
    }
}

if ($allRows.Count -gt 0) {
    $allRows | Sort-Object Array, Host, Volume | Export-Csv -Path $OutputCsv -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host "`nExport terminé: $OutputCsv" -ForegroundColor Green
    Write-Host "Entrées exportées: $($allRows.Count)" -ForegroundColor Green
}
else {
    Write-Warning 'Aucune entrée à exporter.'
}
