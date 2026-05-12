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

.PARAMETER UsePureStorageModule
    Utilise le module PowerShell Pure Storage par défaut (repli REST auto si indisponible).

.EXAMPLE
    $arrays = @('fa-prod-01.company.local','fa-prod-02.company.local')
    .\List-PureStoragePhysicalVolumes.ps1 -Arrays $arrays -OutputCsv .\pure-physical-volumes.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arrays,

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ApiVersion = '2.38',

    [Parameter()]
    [string]$ExcludeHostRegex = '(?i)(^|[-_.])(esx\d*|esxi\d*|vmware|hyper-?v|hv\d+)([-_.]|$)',

    [Parameter()]
    [string]$OutputCsv = '.\pure-physical-volumes.csv',

    [Parameter()]
    [switch]$UsePureStorageModule = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Credential) {
    $Credential = Get-Credential -Message 'Compte API Pure Storage (lecture)'
}

$script:PureModuleAvailable = $false
$script:PureModuleSessionCmdlets = @{}

if ($UsePureStorageModule) {
    $module = Get-Module -ListAvailable -Name 'PureStoragePowerShellSDK2','PureStoragePowerShellSDK'
    if ($module) {
        Import-Module $module[0].Name -ErrorAction Stop
        $script:PureModuleAvailable = $true

        $connectCmd = Get-Command -Name 'Connect-Pfa2Array','Connect-PfaArray' -ErrorAction SilentlyContinue | Select-Object -First 1
        $disconnectCmd = Get-Command -Name 'Disconnect-Pfa2Array','Disconnect-PfaArray' -ErrorAction SilentlyContinue | Select-Object -First 1
        $invokeCmd = Get-Command -Name 'Invoke-Pfa2RestMethod','Invoke-PfaRestMethod' -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($connectCmd -and $disconnectCmd -and $invokeCmd) {
            $script:PureModuleSessionCmdlets = @{
                Connect    = $connectCmd.Name
                Disconnect = $disconnectCmd.Name
                Invoke     = $invokeCmd.Name
            }
            Write-Host "Module Pure Storage détecté: $($module[0].Name). Utilisation du SDK fabricant." -ForegroundColor Green
        }
        else {
            Write-Warning "Le module Pure Storage est présent mais certains cmdlets sont introuvables. Repli sur API REST native."
            $script:PureModuleAvailable = $false
        }
    }
    else {
        Write-Warning "Module Pure Storage non trouvé (PureStoragePowerShellSDK2/PureStoragePowerShellSDK). Repli sur API REST native."
    }
}

function Get-ObjValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [object]$Default = $null
    )

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties[$name]) {
            $value = $Object.$name
            if ($null -ne $value -and "$value" -ne '') {
                return $value
            }
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

function Invoke-PureApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Array,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [object]$Body
    )

    $uri = "https://$Array/api/$ApiVersion/$Path"
    $params = @{ Uri = $uri; Method = $Method; Headers = $Headers; ContentType = 'application/json' }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 6) }
    Invoke-RestMethod @params
}

function New-PureApiSession {
    param([string]$Array,[PSCredential]$Credential)

    if ($script:PureModuleAvailable) {
        $session = & $script:PureModuleSessionCmdlets.Connect -EndPoint $Array -Credential $Credential -IgnoreCertificateError
        if (-not $session) { throw "Connexion SDK impossible sur la baie '$Array'." }
        return @{ Mode = 'Module'; Session = $session }
    }

    $tokenResponse = Invoke-PureApi -Array $Array -Method 'POST' -Path 'login' -Body @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
    if (-not $tokenResponse.token) { throw "Impossible de récupérer le token API sur la baie '$Array'." }
    return @{ Mode = 'Rest'; Headers = @{ Authorization = "Bearer $($tokenResponse.token)" } }
}

function Invoke-PureApiWithSession {
    param(
        [Parameter(Mandatory = $true)][string]$Array,
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][object]$Body
    )

    if ($Session.Mode -eq 'Module') {
        $invokeParams = @{ Array = $Session.Session; Method = $Method; Path = $Path }
        if ($Body) { $invokeParams.Body = $Body }
        return (& $script:PureModuleSessionCmdlets.Invoke @invokeParams)
    }

    return Invoke-PureApi -Array $Array -Method $Method -Path $Path -Headers $Session.Headers -Body $Body
}

function Close-PureApiSession {
    param([string]$Array,[hashtable]$Session)

    try {
        if ($Session.Mode -eq 'Module') {
            & $script:PureModuleSessionCmdlets.Disconnect -Array $Session.Session | Out-Null
        }
        else {
            Invoke-PureApi -Array $Array -Method 'DELETE' -Path 'logout' -Headers $Session.Headers | Out-Null
        }
    }
    catch { Write-Warning "Déconnexion API échouée pour '$Array': $($_.Exception.Message)" }
}

$allRows = New-Object System.Collections.Generic.List[object]

foreach ($array in $Arrays) {
    Write-Host "\n=== Baie: $array ===" -ForegroundColor Cyan
    $session = $null

    try {
        $session = New-PureApiSession -Array $array -Credential $Credential

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
            $host = [string]$_.host.name
            $hostGroup = [string]$_.host_group.name
            -not ($host -match $ExcludeHostRegex) -and -not ($hostGroup -match $ExcludeHostRegex)
        }

        foreach ($conn in $physicalConnections) {
            $volName = [string]$conn.volume.name
            if (-not $volumesByName.ContainsKey($volName)) { continue }

            $vol = $volumesByName[$volName]
            $sizeGiB = [Math]::Round(([double](Get-ObjValue -Object $vol -Names @('space.total') -Default 0) / 1GB), 2)
            if ($sizeGiB -eq 0 -and $vol.PSObject.Properties['space'] -and $vol.space.total) {
                $sizeGiB = [Math]::Round(([double]$vol.space.total / 1GB), 2)
            }

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
    Write-Host "\nExport terminé: $OutputCsv" -ForegroundColor Green
    Write-Host "Entrées exportées: $($allRows.Count)" -ForegroundColor Green
}
else {
    Write-Warning 'Aucune entrée à exporter.'
}
