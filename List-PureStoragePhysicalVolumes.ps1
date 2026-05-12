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

.PARAMETER ExcludeHostRegex
    Expression régulière utilisée pour exclure les hyperviseurs.

.PARAMETER OutputCsv
    Chemin de sortie CSV.

.EXAMPLE
    $arrays = @('fa-prod-01.company.local','fa-prod-02.company.local')
    .\List-PureStoragePhysicalVolumes.ps1 -Arrays $arrays -OutputCsv .\pure-physical-volumes.csv
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Script interactif: Write-Host intentionnel pour affichage couleur en console')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Mot de passe en clair supporté dans config locale uniquement')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Fonctions internes non exportées')]
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Arrays = @(),

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config-pure.psd1'),

    [Parameter()]
    [string]$ExcludeHostRegex = '(?i)(^|[-_.])(esx\d*|esxi\d*|vmware|hyper-?v|hv\d+|nbu-mediaserver)([-_.]|$)',

    [Parameter()]
    [string]$OutputCsv = '.\pure-physical-volumes.csv',

    [Parameter()]
    [switch]$IgnoreCertificateErrors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


if (Test-Path -LiteralPath $ConfigFile) {
    $cfg = Import-PowerShellDataFile -LiteralPath $ConfigFile

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
            if ($null -eq $current) { $found = $false; break }
            $prop = $current.PSObject.Properties.Match($part) | Select-Object -First 1
            if (-not $prop) { $found = $false; break }
            $current = $prop.Value
        }
        if ($found -and $null -ne $current -and "$current" -ne '') {
            return $current
        }
    }

    return $Default
}

function Get-ReplicationType {
    param(
        [Parameter(Mandatory = $true)][object]$Volume,
        [Parameter()][hashtable]$PodTypeMap = @{}
    )

    # Méthode principale: le pod indique le type de réplication.
    # ActiveCluster (actif/actif) = pod étendu sur 2+ baies (arrays.Count > 1).
    # ActiveDR (asynchrone)       = pod local avec un pod-replica-link.
    # Pod local sans lien         = non répliqué.
    $podName = [string](Get-ObjValue -Object $Volume -Names @('pod.name', 'Pod.Name') -Default '')
    if ($podName) {
        if ($PodTypeMap.ContainsKey($podName)) {
            return $PodTypeMap[$podName]
        }
        # Pod présent mais Get-Pfa2Pod indisponible
        return 'asynchrone'
    }

    # Fallback: flags directs sur le volume (peut exister dans certaines versions d'API)
    $syncValues = @(
        (Get-ObjValue -Object $Volume -Names @('sync_replication', 'SyncReplication', 'is_sync_replicated', 'IsSyncReplicated') -Default $false),
        (Get-ObjValue -Object $Volume -Names @('active_cluster', 'ActiveCluster') -Default $false)
    )
    foreach ($v in $syncValues) {
        if (($v -is [bool] -and $v) -or ($v -and "$v" -ne '')) { return 'actif/actif' }
    }

    $asyncValues = @(
        (Get-ObjValue -Object $Volume -Names @('async_replication', 'AsyncReplication', 'is_async_replicated', 'IsAsyncReplicated') -Default $false),
        (Get-ObjValue -Object $Volume -Names @('protection_group', 'ProtectionGroup') -Default $null)
    )
    foreach ($v in $asyncValues) {
        if (($v -is [bool] -and $v) -or ($v -and "$v" -ne '')) { return 'asynchrone' }
    }

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
    return @{ Session = $session }
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

        $flashArray = $session.Session
        $arrayInfo = @(Get-Pfa2Array -Array $flashArray)[0]
        $arraySpace = if (Get-Command 'Get-Pfa2ArraySpace' -ErrorAction SilentlyContinue) {
            @(Get-Pfa2ArraySpace -Array $flashArray)[0]
        } else { $arrayInfo }

        $model = [string](Get-ObjValue -Object $arrayInfo -Names @('model', 'product_model', 'ProductModel') -Default 'N/A')

        # Get-Pfa2Array retourne un nom de famille générique (ex: M_SERIES).
        # Le modèle complet (ex: FA-X70R3) est porté par les contrôleurs (CT0/CT1,
        # type=controller) dans Get-Pfa2Hardware. Fallback: premier composant avec model non vide.
        $hasFullModel = $model -match '(?i)R\d+'
        if (-not $hasFullModel -and (Get-Command 'Get-Pfa2Hardware' -ErrorAction SilentlyContinue)) {
            $hwModel = ''
            foreach ($hw in @(Get-Pfa2Hardware -Array $flashArray)) {
                $typeProp  = $hw.PSObject.Properties['Type']
                $modelProp = $hw.PSObject.Properties['Model']
                if (-not $typeProp)  { $typeProp  = $hw.PSObject.Properties['type']  }
                if (-not $modelProp) { $modelProp = $hw.PSObject.Properties['model'] }
                $hwType = if ($typeProp)  { [string]$typeProp.Value  } else { '' }
                $hwVal  = if ($modelProp) { [string]$modelProp.Value } else { '' }
                if ($hwType -match '(?i)^controller$' -and $hwVal -ne '') { $hwModel = $hwVal; break }
            }
            $model = if ($hwModel) { $hwModel } else { 'N/A' }
        }

        $dataReduction = [double](Get-ObjValue -Object $arraySpace -Names @(
            'data_reduction', 'DataReduction',
            'total_reduction', 'TotalReduction',
            'space.data_reduction', 'Space.DataReduction'
        ) -Default 0)
        $rawBytes = [double](Get-ObjValue -Object $arraySpace -Names @(
            'capacity', 'total_capacity', 'TotalCapacity',
            'space.capacity', 'Space.Capacity'
        ) -Default 0)
        $rawTiB = [Math]::Round(($rawBytes / 1TB), 2)

        $usedBytes = [double](Get-ObjValue -Object $arraySpace -Names @(
            'space.total_physical', 'Space.TotalPhysical',
            'total_physical', 'TotalPhysical',
            'space.used', 'Space.Used'
        ) -Default 0)
        $arrayUsedTiB = [Math]::Round(($usedBytes / 1TB), 2)

        Write-Host ("Modèle: {0} | Ratio dédup+compression: {1}x | Capacité raw: {2} TiB | Utilisé: {3} TiB" -f $model, ([Math]::Round($dataReduction, 2)), $rawTiB, $arrayUsedTiB) -ForegroundColor Gray

        $volumes = @(Get-Pfa2Volume -Array $flashArray -Limit 10000)
        $connections = @(Get-Pfa2Connection -Array $flashArray -Limit 10000)

        # Map podName → type de réplication ('actif/actif' | 'asynchrone' | 'non répliqué')
        # ActiveCluster : pod étendu sur 2+ baies (arrays.Count > 1)
        # ActiveDR      : pod local avec un pod-replica-link
        $podTypeMap = @{}
        if (Get-Command 'Get-Pfa2Pod' -ErrorAction SilentlyContinue) {
            foreach ($pod in @(Get-Pfa2Pod -Array $flashArray -Limit 1000)) {
                $podName = [string]$pod.Name
                $arrProp = $pod.PSObject.Properties.Match('arrays') | Select-Object -First 1
                $arrCount = if ($arrProp -and $null -ne $arrProp.Value) { @($arrProp.Value).Count } else { 1 }
                $podTypeMap[$podName] = if ($arrCount -gt 1) { 'actif/actif' } else { 'non répliqué' }
            }
            Write-Verbose "Pods: $($podTypeMap.Count) | ActiveCluster: $(@($podTypeMap.Values | Where-Object {$_ -eq 'actif/actif'}).Count)"
        } else {
            Write-Warning "Get-Pfa2Pod indisponible: type de réplication pod indéterminable."
        }

        if (Get-Command 'Get-Pfa2PodReplicaLink' -ErrorAction SilentlyContinue) {
            foreach ($link in @(Get-Pfa2PodReplicaLink -Array $flashArray -Limit 1000)) {
                $linkPod = [string](Get-ObjValue -Object $link -Names @('local_pod.name', 'LocalPod.Name') -Default '')
                if ($linkPod -and $podTypeMap.ContainsKey($linkPod) -and $podTypeMap[$linkPod] -ne 'actif/actif') {
                    $podTypeMap[$linkPod] = 'asynchrone'
                }
            }
            Write-Verbose "Pods ActiveDR (replica-link): $(@($podTypeMap.Values | Where-Object {$_ -eq 'asynchrone'}).Count)"
        }

        if ($volumes.Count -eq 0) {
            Write-Host "Aucun volume trouvé." -ForegroundColor Yellow
            continue
        }

        $volumesByName = @{}
        foreach ($vol in $volumes) { $volumesByName[[string]$vol.Name] = $vol }

        $physicalConnections = $connections | Where-Object {
            $connHostName = [string](Get-ObjValue -Object $_ -Names @('host.name') -Default '')
            $connHostGroup = [string](Get-ObjValue -Object $_ -Names @('HostGroup.Name', 'host_group.name') -Default '')
            -not ($connHostName -match $ExcludeHostRegex) -and -not ($connHostGroup -match $ExcludeHostRegex)
        }

        foreach ($conn in $physicalConnections) {
            $volName = [string](Get-ObjValue -Object $conn -Names @('volume.name') -Default '')
            if (-not $volumesByName.ContainsKey($volName)) { continue }

            $vol = $volumesByName[$volName]
            $sizeGiB = [Math]::Round(([double](Get-ObjValue -Object $vol -Names @('provisioned', 'space.total', 'size') -Default 0) / 1GB), 2)
            $volReduction = [Math]::Round([double](Get-ObjValue -Object $vol -Names @('space.data_reduction', 'Space.DataReduction', 'data_reduction', 'DataReduction', 'space.total_reduction', 'Space.TotalReduction') -Default 0), 2)
            $usedGiB = [Math]::Round(([double](Get-ObjValue -Object $vol -Names @('space.virtual', 'Space.Virtual', 'virtual') -Default 0) / 1GB), 2)

            $allRows.Add([PSCustomObject]@{
                Array              = $array
                ArrayModel         = $model
                ArrayReduction     = [Math]::Round($dataReduction, 2)
                ArrayRawTiB        = $rawTiB
                ArrayUsedTiB       = $arrayUsedTiB
                Volume             = [string]$vol.Name
                VolumeGiB          = $sizeGiB
                VolumeUsedGiB      = $usedGiB
                VolumeReduction    = $volReduction
                Serial             = [string]$vol.Serial
                Host               = [string](Get-ObjValue -Object $conn -Names @('host.name') -Default '')
                HostGroup          = [string](Get-ObjValue -Object $conn -Names @('HostGroup.Name', 'host_group.name') -Default '')
                Protocol           = [string](Get-ObjValue -Object $conn -Names @('ProtocolEndpointType', 'protocol_endpoint_type') -Default '')
                Lun                = [string](Get-ObjValue -Object $conn -Names @('lun') -Default '')
                ReplicationType    = Get-ReplicationType -Volume $vol -PodTypeMap $podTypeMap
            })
        }

        $currentArrayRows = @($allRows | Where-Object { $_.Array -eq $array })
        if ($currentArrayRows.Count -eq 0) {
            Write-Host "Aucun volume mappé à un serveur physique après filtrage ESX/Hyper-V." -ForegroundColor Yellow
        }
        else {
            $currentArrayRows |
                Sort-Object Host, Volume |
                Format-Table Array, Host, HostGroup, Volume, VolumeGiB, VolumeUsedGiB,
                    @{L='Réduction';E={if($_.VolumeReduction -gt 0){"$($_.VolumeReduction)x"}else{'N/A'}}},
                    ReplicationType, Lun -AutoSize
        }
    }
    catch {
        Write-Error "Erreur sur la baie '$array': $($_.Exception.Message)"
    }
    finally {
        if ($session) { Close-PureApiSession -Array $array -Session $session }
    }
}

# Appairage des volumes répliqués par numéro de série
$serialMap = @{}
foreach ($row in $allRows) {
    if ([string]::IsNullOrWhiteSpace($row.Serial)) { continue }
    if (-not $serialMap.ContainsKey($row.Serial)) {
        $serialMap[$row.Serial] = [System.Collections.Generic.List[object]]::new()
    }
    $serialMap[$row.Serial].Add($row)
}

foreach ($row in $allRows) {
    $partners = @()
    if (-not [string]::IsNullOrWhiteSpace($row.Serial) -and $serialMap.ContainsKey($row.Serial)) {
        $partners = @(
            $serialMap[$row.Serial] |
            Where-Object { $_.Array -ne $row.Array } |
            ForEach-Object { "$($_.Array)/$($_.Volume)" } |
            Select-Object -Unique
        )
    }
    $row | Add-Member -NotePropertyName 'PairedWith' -NotePropertyValue ($partners -join '; ') -Force
}

$pairedSerials = @($serialMap.Keys | Where-Object {
    @($serialMap[$_] | Select-Object -ExpandProperty Array | Select-Object -Unique).Count -gt 1
})

if ($pairedSerials.Count -gt 0) {
    Write-Host ("`n=== Volumes répliqués détectés - {0} groupe(s) ===" -f $pairedSerials.Count) -ForegroundColor Cyan
    foreach ($serial in ($pairedSerials | Sort-Object)) {
        $rows = $serialMap[$serial]
        $volName = ($rows | Select-Object -ExpandProperty Volume -First 1)
        Write-Host ("`nVolume : {0}  |  Série : {1}" -f $volName, $serial) -ForegroundColor Yellow
        $rows | Sort-Object Array |
            Format-Table @{L='Baie';E={$_.Array}},
                         @{L='Hôte';E={$_.Host}},
                         @{L='HostGroup';E={$_.HostGroup}},
                         @{L='Taille (GiB)';E={$_.VolumeGiB}},
                         @{L='Réplication';E={$_.ReplicationType}} -AutoSize
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
