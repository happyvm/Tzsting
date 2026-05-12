<#!
.SYNOPSIS
    Liste les volumes Pure Storage présentés à des serveurs physiques (en excluant ESX/Hyper-V).

.DESCRIPTION
    Le script se connecte à plusieurs baies Pure Storage FlashArray via l'API REST 2.x,
    récupère les volumes, leurs connexions hôte/hostgroup, puis filtre les hôtes qui
    ressemblent à des hyperviseurs (ESX, VMware, Hyper-V).

    Résultat:
      - export CSV optionnel
      - affichage console groupé par baie

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
    [Parameter(Mandatory = $true)]
    [string[]]$Arrays,

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ApiVersion = '2.38',

    [Parameter()]
    [string]$ExcludeHostRegex = '(?i)(^|[-_.])(esx\d*|esxi\d*|vmware|hyper-?v|hv\d+)([-_.]|$)',

    [Parameter()]
    [string]$OutputCsv = '.\pure-physical-volumes.csv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Credential) {
    $Credential = Get-Credential -Message 'Compte API Pure Storage (lecture)'
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
    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Headers
        ContentType = 'application/json'
    }

    if ($Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 6)
    }

    Invoke-RestMethod @params
}

function New-PureApiSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Array,

        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential
    )

    $tokenResponse = Invoke-PureApi -Array $Array -Method 'POST' -Path 'login' -Body @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    }

    if (-not $tokenResponse.token) {
        throw "Impossible de récupérer le token API sur la baie '$Array'."
    }

    return @{ Authorization = "Bearer $($tokenResponse.token)" }
}

function Close-PureApiSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Array,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    try {
        Invoke-PureApi -Array $Array -Method 'DELETE' -Path 'logout' -Headers $Headers | Out-Null
    }
    catch {
        Write-Warning "Déconnexion API échouée pour '$Array': $($_.Exception.Message)"
    }
}

$allRows = New-Object System.Collections.Generic.List[object]

foreach ($array in $Arrays) {
    Write-Host "\n=== Baie: $array ===" -ForegroundColor Cyan

    $headers = $null
    try {
        $headers = New-PureApiSession -Array $array -Credential $Credential

        $volumesResponse = Invoke-PureApi -Array $array -Method 'GET' -Path 'volumes?limit=10000' -Headers $headers
        $connectionsResponse = Invoke-PureApi -Array $array -Method 'GET' -Path 'connections?limit=10000' -Headers $headers

        $volumes = @($volumesResponse.items)
        $connections = @($connectionsResponse.items)

        if ($volumes.Count -eq 0) {
            Write-Host "Aucun volume trouvé." -ForegroundColor Yellow
            continue
        }

        $volumesByName = @{}
        foreach ($vol in $volumes) {
            $volumesByName[$vol.name] = $vol
        }

        $physicalConnections = $connections | Where-Object {
            $host = [string]$_.host.name
            $hostGroup = [string]$_.host_group.name
            -not ($host -match $ExcludeHostRegex) -and -not ($hostGroup -match $ExcludeHostRegex)
        }

        foreach ($conn in $physicalConnections) {
            $volName = [string]$conn.volume.name
            if (-not $volumesByName.ContainsKey($volName)) {
                continue
            }

            $vol = $volumesByName[$volName]
            $sizeGiB = [Math]::Round(([double]$vol.space.total / 1GB), 2)

            $allRows.Add([PSCustomObject]@{
                Array      = $array
                Volume     = $vol.name
                VolumeGiB  = $sizeGiB
                Serial     = $vol.serial
                Host       = [string]$conn.host.name
                HostGroup  = [string]$conn.host_group.name
                Protocol   = [string]$conn.protocol_endpoint_type
                Lun        = [string]$conn.lun
            })
        }

        $currentArrayRows = $allRows | Where-Object { $_.Array -eq $array }
        if ($currentArrayRows.Count -eq 0) {
            Write-Host "Aucun volume mappé à un serveur physique après filtrage ESX/Hyper-V." -ForegroundColor Yellow
        }
        else {
            $currentArrayRows |
                Sort-Object Host, Volume |
                Format-Table Array, Host, HostGroup, Volume, VolumeGiB, Lun -AutoSize
        }
    }
    catch {
        Write-Error "Erreur sur la baie '$array': $($_.Exception.Message)"
    }
    finally {
        if ($headers) {
            Close-PureApiSession -Array $array -Headers $headers
        }
    }
}

if ($allRows.Count -gt 0) {
    $allRows |
        Sort-Object Array, Host, Volume |
        Export-Csv -Path $OutputCsv -Delimiter ';' -NoTypeInformation -Encoding UTF8

    Write-Host "\nExport terminé: $OutputCsv" -ForegroundColor Green
    Write-Host "Entrées exportées: $($allRows.Count)" -ForegroundColor Green
}
else {
    Write-Warning 'Aucune entrée à exporter.'
}
