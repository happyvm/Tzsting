<#
.SYNOPSIS
    Script de lotissement de migration VMware.

.DESCRIPTION
    - Lit un CSV d'entrée contenant : vmname;tag
    - tag = lot de migration
    - Crée/pose un tag vSphere en catégorie Single
    - Calcule par lot :
        - nombre de VM
        - vCPU configurés
        - RAM configurée
        - stockage réellement consommé datastore
    - Récupère l'attribut personnalisé NB_last_backup
    - Récupère l'uptime en jours via VMware Tools :
        - Linux
        - Windows 2008 et supérieur
    - Indique si l'uptime est supérieur à $UptimeThresholdDays jours
    - Pour Windows 2003 / 2008 / 2008 R2 :
        - exécute ipconfig /all
        - stocke le résultat dans C:\temp dans la VM
    - Essaie jusqu'à 5 credentials Windows locaux
    - Exporte le label du credential Windows qui a fonctionné

    La configuration (valeurs par défaut, usernames des comptes invités) est lue depuis
    config-precheck.psd1 situé dans le même dossier que le script. Les paramètres passés
    explicitement en ligne de commande ont toujours priorité sur le fichier de configuration.

.INPUT CSV
    vmname;tag
    SRV-APP-001;LOT-01
    SRV-DB-001;LOT-01
    SRV-LIN-001;LOT-02

.OUTPUT
    migration_lot_detail.csv
    migration_lot_summary.csv
    migration_lot_errors.csv

.PARAMETER LogFile
    Chemin vers un fichier de log. Si vide (défaut), la sortie va uniquement sur la console.

.PARAMETER UptimeThresholdDays
    Seuil d'uptime en jours au-delà duquel UptimeOverThreshold est vrai (défaut : 45).

.PARAMETER CsvDelimiter
    Délimiteur CSV pour la lecture du fichier d'entrée et l'écriture des fichiers de sortie (défaut : ;).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VCenter,

    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$OutputFolder = ".",

    [string]$TagCategoryName = "MigrationLot",

    [string]$CustomAttributeName = "NB_last_backup",

    [int]$ToolsWaitSecs = 20,

    [switch]$SkipGuestOperations,

    # Chemin vers un fichier de log (facultatif). Si vide, la sortie va uniquement sur la console.
    [string]$LogFile = "",

    # Seuil d'uptime en jours au-delà duquel une VM est signalée (UptimeOverThreshold).
    [int]$UptimeThresholdDays = 45,

    # Délimiteur utilisé pour la lecture du CSV d'entrée et l'écriture des CSV de sortie.
    [string]$CsvDelimiter = ";"
)

# ============================================================
# Chargement de config-precheck.psd1
# Les paramètres CLI explicites ont priorité sur le fichier.
# Les mots de passe ne sont jamais stockés dans le fichier de config.
# ============================================================

$script:ConfigFilePath = Join-Path $PSScriptRoot "config-precheck.psd1"

if (-not (Test-Path -LiteralPath $script:ConfigFilePath)) {
    throw "Fichier de configuration introuvable : $script:ConfigFilePath"
}

$cfg = Import-PowerShellDataFile -LiteralPath $script:ConfigFilePath

if (-not $PSBoundParameters.ContainsKey('OutputFolder'))        { $OutputFolder        = [string]$cfg.OutputFolder }
if (-not $PSBoundParameters.ContainsKey('TagCategoryName'))     { $TagCategoryName     = [string]$cfg.TagCategoryName }
if (-not $PSBoundParameters.ContainsKey('CustomAttributeName')) { $CustomAttributeName = [string]$cfg.CustomAttributeName }
if (-not $PSBoundParameters.ContainsKey('ToolsWaitSecs'))       { $ToolsWaitSecs       = [int]$cfg.ToolsWaitSecs }
if (-not $PSBoundParameters.ContainsKey('LogFile'))             { $LogFile             = [string]$cfg.LogFile }
if (-not $PSBoundParameters.ContainsKey('UptimeThresholdDays')) { $UptimeThresholdDays = [int]$cfg.UptimeThresholdDays }
if (-not $PSBoundParameters.ContainsKey('CsvDelimiter'))        { $CsvDelimiter        = [string]$cfg.CsvDelimiter }

# Credentials Windows — usernames et labels uniquement, mots de passe demandés à l'exécution.
$WindowsCredentialDefinitions = @(
    foreach ($entry in $cfg.WindowsCredentials) {
        [PSCustomObject]@{
            Label    = [string]$entry.Label
            UserName = [string]$entry.UserName
            Enabled  = [bool]$entry.Enabled
        }
    }
)

# Credential Linux
$LinuxCredentialDefinition = [PSCustomObject]@{
    Label    = [string]$cfg.LinuxCredential.Label
    UserName = [string]$cfg.LinuxCredential.UserName
    Enabled  = [bool]$cfg.LinuxCredential.Enabled
}

# ============================================================
# Fonctions
# ============================================================

function Write-ExecutionLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $ts   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts][$Level] $Message"

    switch ($Level) {
        "WARN"  { Write-Warning $line }
        "ERROR" { Write-Error $line }
        default { Write-Information $line -InformationAction Continue }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        $line | Out-File -FilePath $script:LogPath -Append -Encoding UTF8
    }
}

function Resolve-VMView {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$VmIndex,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    if (-not $VmIndex.ContainsKey($VMName)) {
        return [PSCustomObject]@{ View = $null; Error = "VM introuvable dans vCenter" }
    }

    $vmMatches = @($VmIndex[$VMName])

    if ($vmMatches.Count -gt 1) {
        return [PSCustomObject]@{ View = $null; Error = "Nom de VM ambigu : plusieurs VM portent ce nom dans vCenter" }
    }

    return [PSCustomObject]@{ View = $vmMatches[0]; Error = $null }
}

function Get-WindowsYearFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    switch -Regex ($Text) {
        "2003" { return 2003 }
        "2008" { return 2008 }
        "2012" { return 2012 }
        "2016" { return 2016 }
        "2019" { return 2019 }
        "2022" { return 2022 }
        "2025" { return 2025 }
        default { return $null }
    }
}

function Get-GuestFamily {
    param(
        [string]$GuestFullName,
        [string]$GuestId
    )

    $text = "$GuestFullName $GuestId"

    if ($text -match "(?i)\bwindows?\b") {
        return "Windows"
    }

    if ($text -match "(?i)linux|ubuntu|debian|centos|red hat|rhel|suse|oracle linux|rocky|alma") {
        return "Linux"
    }

    return "Unknown"
}

function Test-VMwareToolsRunning {
    param(
        $VMView
    )

    $runningStatus = [string]$VMView.Guest.ToolsRunningStatus
    $legacyStatus  = [string]$VMView.Guest.ToolsStatus

    return (
        $runningStatus -eq "guestToolsRunning" -or
        $legacyStatus -eq "toolsOk"
    )
}

function Invoke-GuestScriptSafe {
    param(
        [Parameter(Mandatory = $true)]
        $VMObject,

        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PowerShell", "Bat", "Bash")]
        [string]$ScriptType,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$GuestCredential,

        [int]$ToolsWaitSecs = 20
    )

    try {
        $result = Invoke-VMScript `
            -VM $VMObject `
            -ScriptText $ScriptText `
            -ScriptType $ScriptType `
            -GuestCredential $GuestCredential `
            -ToolsWaitSecs $ToolsWaitSecs `
            -ErrorAction Stop

        return [PSCustomObject]@{
            Success = $true
            Output  = ($result.ScriptOutput -replace "`r", "").Trim()
            Error   = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            Output  = $null
            Error   = $_.Exception.Message
        }
    }
}

function Invoke-WindowsGuestScriptWithCredentialFallback {
    param(
        [Parameter(Mandatory = $true)]
        $VMObject,

        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PowerShell", "Bat")]
        [string]$ScriptType,

        [Parameter(Mandatory = $true)]
        [object[]]$AuthCandidates,

        [string]$PreferredAuthLabel,

        [int]$ToolsWaitSecs = 20
    )

    if (-not $AuthCandidates -or $AuthCandidates.Count -eq 0) {
        return [PSCustomObject]@{
            Success         = $false
            Output          = $null
            Error           = "Aucun credential Windows candidat fourni."
            CredentialLabel = $null
            CredentialUser  = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredAuthLabel)) {
        $ordered = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $AuthCandidates) {
            if ($c.Label -eq $PreferredAuthLabel) { $ordered.Insert(0, $c) } else { $ordered.Add($c) }
        }
        $orderedCandidates = $ordered
    }
    else {
        $orderedCandidates = $AuthCandidates
    }

    $attemptErrors = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in $orderedCandidates) {
        $result = Invoke-GuestScriptSafe `
            -VMObject $VMObject `
            -ScriptText $ScriptText `
            -ScriptType $ScriptType `
            -GuestCredential $candidate.Credential `
            -ToolsWaitSecs $ToolsWaitSecs

        if ($result.Success) {
            return [PSCustomObject]@{
                Success         = $true
                Output          = $result.Output
                Error           = $null
                CredentialLabel = $candidate.Label
                CredentialUser  = $candidate.UserName
            }
        }

        $attemptErrors.Add("$($candidate.Label) / $($candidate.UserName) : $($result.Error)")
    }

    return [PSCustomObject]@{
        Success         = $false
        Output          = $null
        Error           = ($attemptErrors -join " || ")
        CredentialLabel = $null
        CredentialUser  = $null
    }
}

function Get-UptimeDaysFromWmicOutput {
    param(
        [string]$WmicOutput
    )

    if ([string]::IsNullOrWhiteSpace($WmicOutput)) {
        return $null
    }

    if ($WmicOutput -match "LastBootUpTime=([0-9]{14})") {
        $datePart = $Matches[1]

        try {
            $bootTime = [datetime]::ParseExact(
                $datePart,
                "yyyyMMddHHmmss",
                [System.Globalization.CultureInfo]::InvariantCulture
            )

            return [math]::Round(((Get-Date) - $bootTime).TotalDays, 2)
        }
        catch {
            return $null
        }
    }

    return $null
}

function Resolve-LotTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LotName,

        [Parameter(Mandatory = $true)]
        $Category
    )

    if ($script:tagCache.ContainsKey($LotName)) {
        return $script:tagCache[$LotName]
    }

    $tagObject = Get-Tag -Name $LotName -Category $Category -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $tagObject) {
        $tagObject = New-Tag -Name $LotName -Category $Category -ErrorAction Stop
    }

    $script:tagCache[$LotName] = $tagObject
    return $tagObject
}

# ============================================================
# Préparation
# ============================================================

$script:LogPath = $LogFile

if (-not (Test-Path $InputCsv)) {
    throw "CSV introuvable : $InputCsv"
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$detailCsv  = Join-Path $OutputFolder "migration_lot_detail.csv"
$summaryCsv = Join-Path $OutputFolder "migration_lot_summary.csv"
$errorCsv   = Join-Path $OutputFolder "migration_lot_errors.csv"

foreach ($file in @($detailCsv, $summaryCsv, $errorCsv)) {
    if (Test-Path $file) {
        Remove-Item -Path $file -Force
    }
}

Write-ExecutionLog ("Lecture du CSV : {0}" -f $InputCsv)
$rawRows = @(Import-Csv -Path $InputCsv -Delimiter $CsvDelimiter)
Write-ExecutionLog ("{0} ligne(s) chargée(s)" -f $rawRows.Count)

if (-not $rawRows -or $rawRows.Count -eq 0) {
    throw "Le CSV est vide."
}

$columns = @($rawRows[0].PSObject.Properties.Name)
$normalizedColumnMap = @{}

foreach ($column in $columns) {
    $normalized = ([string]$column).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $normalizedColumnMap.ContainsKey($normalized)) {
        $normalizedColumnMap[$normalized] = $column
    }
}

if (-not $normalizedColumnMap.ContainsKey("vmname") -or -not $normalizedColumnMap.ContainsKey("tag")) {
    $detectedColumns = ($columns -join ", ")
    throw "Le CSV doit contenir les colonnes suivantes : vmname, tag. Colonnes détectées : $detectedColumns"
}

$vmNameColumn = $normalizedColumnMap["vmname"]
$tagColumn = $normalizedColumnMap["tag"]

$inputRows = @(
    foreach ($row in $rawRows) {
        $vmName = ([string]$row.$vmNameColumn).Trim()
        $lot    = ([string]$row.$tagColumn).Trim()

        if (-not [string]::IsNullOrWhiteSpace($vmName) -and -not [string]::IsNullOrWhiteSpace($lot)) {
            [PSCustomObject]@{
                VMName = $vmName
                Lot    = $lot
            }
        }
    }
)

$inputRows = @($inputRows | Sort-Object VMName, Lot -Unique)

if (-not $inputRows -or $inputRows.Count -eq 0) {
    throw "Aucune ligne exploitable dans le CSV."
}

$vmInMultipleLots = @(
    $inputRows |
        Group-Object VMName |
        Where-Object {
            @($_.Group.Lot | Sort-Object -Unique).Count -gt 1
        }
)

if ($vmInMultipleLots.Count -gt 0) {
    $badVMs = ($vmInMultipleLots | Select-Object -ExpandProperty Name) -join ", "
    throw "Erreur de lotissement : certaines VM sont présentes dans plusieurs lots : $badVMs"
}

# ============================================================
# Connexion vCenter
# ============================================================

Write-ExecutionLog "AVERTISSEMENT : La validation des certificats SSL vCenter est désactivée pour cette session (InvalidCertificateAction = Ignore, Scope Session)." -Level WARN
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

$vcenterCredential = Get-Credential -Message "Compte vCenter"

try {
    Connect-VIServer -Server $VCenter -Credential $vcenterCredential -ErrorAction Stop | Out-Null
}
catch {
    throw "Impossible de se connecter à $VCenter : $_"
}

try {
    # ========================================================
    # Catégorie de tag Single
    # ========================================================

    $tagCategory = Get-TagCategory -Name $TagCategoryName -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $tagCategory) {
        $tagCategory = New-TagCategory `
            -Name $TagCategoryName `
            -Cardinality Single `
            -EntityType VirtualMachine `
            -ErrorAction Stop
    }
    else {
        if ($tagCategory.Cardinality -ne "Single") {
            throw "La catégorie '$TagCategoryName' existe déjà mais n'est pas en cardinalité Single."
        }

        $entityTypes = @($tagCategory.EntityType | ForEach-Object { [string]$_ })

        if ($entityTypes.Count -gt 0 -and $entityTypes -notcontains "VirtualMachine") {
            throw "La catégorie '$TagCategoryName' existe déjà mais n'est pas applicable aux VirtualMachine."
        }
    }

    # ========================================================
    # Attribut personnalisé NB_last_backup
    # ========================================================

    $serviceInstance = Get-View ServiceInstance
    $customFieldsManager = Get-View $serviceInstance.Content.CustomFieldsManager

    $backupField = $customFieldsManager.Field |
        Where-Object {
            $_.Name -eq $CustomAttributeName -and
            ($_.ManagedObjectType -eq $null -or $_.ManagedObjectType -eq "VirtualMachine")
        } |
        Select-Object -First 1

    if (-not $backupField) {
        Write-ExecutionLog "Attribut personnalisé '$CustomAttributeName' introuvable. La colonne sera vide." -Level WARN
    }

    # ========================================================
    # Chargement des VM vCenter
    # ========================================================

    # Filtre serveur par nom pour éviter de charger toutes les VM de vCenter.
    # Get-View filtre en "contains", le $vmIndex garantit la résolution exacte.
    $namePattern = ($inputRows.VMName | ForEach-Object { [regex]::Escape($_) }) -join '|'

    $allVmViews = Get-View -ViewType VirtualMachine `
        -Filter @{ "Name" = $namePattern } `
        -Property `
            Name,
            Runtime.PowerState,
            Summary.Config,
            Summary.Storage,
            Config.GuestFullName,
            Config.GuestId,
            Guest.GuestFullName,
            Guest.GuestId,
            Guest.ToolsStatus,
            Guest.ToolsRunningStatus,
            CustomValue

    $vmIndex = @{}

    foreach ($vmView in $allVmViews) {
        if (-not $vmIndex.ContainsKey($vmView.Name)) {
            $vmIndex[$vmView.Name] = [System.Collections.Generic.List[object]]::new()
        }

        $vmIndex[$vmView.Name].Add($vmView)
    }

    # ========================================================
    # Tagging en début de traitement
    # ========================================================

    Write-ExecutionLog "Début du tagging"

    $script:tagCache = @{}
    $tagStatusByVmLot = @{}
    $vmObjectCache = @{}
    $detailRows = New-Object System.Collections.Generic.List[object]
    $errorRows  = New-Object System.Collections.Generic.List[object]

    $tagCounter = 0
    $tagTotal = $inputRows.Count

    foreach ($row in $inputRows) {
        $tagCounter++
        $vmName = $row.VMName
        $lotName = $row.Lot
        $rowKey = "$vmName||$lotName"
        $tagStatusByVmLot[$rowKey] = "NotProcessed"

        Write-Progress -Activity "Tagging des VM" `
            -Status ("VM {0}/{1} : {2} (lot {3})" -f $tagCounter, $tagTotal, $vmName, $lotName) `
            -PercentComplete (($tagCounter / $tagTotal) * 100)

        Write-Verbose ("Tagging {0}/{1}: {2} (lot {3})" -f $tagCounter, $tagTotal, $vmName, $lotName)

        $resolved = Resolve-VMView -VmIndex $vmIndex -VMName $vmName

        if ($resolved.Error) {
            continue
        }

        try {
            $vmObject = Get-VIObjectByVIView -VIView $resolved.View -ErrorAction Stop
            $vmObjectCache[$vmName] = $vmObject
            $lotTag = Resolve-LotTag -LotName $lotName -Category $tagCategory
            $currentAssignments = @(Get-TagAssignment -Entity $vmObject -Category $tagCategory -ErrorAction SilentlyContinue)
            $assignmentsToRemove = @($currentAssignments | Where-Object { $_.Tag.Name -ne $lotName })
            if ($assignmentsToRemove.Count -gt 0 -and $PSCmdlet.ShouldProcess($vmName, "Supprimer le tag existant '$($assignmentsToRemove[0].Tag.Name)'")) {
                $assignmentsToRemove | Remove-TagAssignment -Confirm:$false | Out-Null
            }
            $alreadyAssigned = @(Get-TagAssignment -Entity $vmObject -Category $tagCategory -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Name -eq $lotName })

            if ($alreadyAssigned.Count -eq 0) {
                if ($PSCmdlet.ShouldProcess($vmName, "Assigner le tag '$lotName'")) {
                    New-TagAssignment -Tag $lotTag -Entity $vmObject -ErrorAction Stop | Out-Null
                    $tagStatusByVmLot[$rowKey] = "Assigned"
                }
                else {
                    $tagStatusByVmLot[$rowKey] = "WhatIf"
                }
            }
            else {
                $tagStatusByVmLot[$rowKey] = "AlreadyAssigned"
            }
        }
        catch {
            $tagStatusByVmLot[$rowKey] = "TagError"
            $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = $_.Exception.Message })
        }
    }

    Write-Progress -Activity "Tagging des VM" -Completed
    Write-ExecutionLog "Fin du tagging"

    # ========================================================
    # Détermination des credentials nécessaires
    # ========================================================

    $needWindowsCredentials = $false
    $needLinuxCredential = $false

    if (-not $SkipGuestOperations) {
        foreach ($row in $inputRows) {
            $resolved = Resolve-VMView -VmIndex $vmIndex -VMName $row.VMName

            if ($resolved.Error) {
                continue
            }

            $vmView = $resolved.View

            if ($vmView.Runtime.PowerState -ne "poweredOn") {
                continue
            }

            if (-not (Test-VMwareToolsRunning -VMView $vmView)) {
                continue
            }

            $guestFullName = $vmView.Guest.GuestFullName
            if ([string]::IsNullOrWhiteSpace($guestFullName)) {
                $guestFullName = $vmView.Config.GuestFullName
            }

            $guestId = $vmView.Guest.GuestId
            if ([string]::IsNullOrWhiteSpace($guestId)) {
                $guestId = $vmView.Config.GuestId
            }

            $guestFamily = Get-GuestFamily -GuestFullName $guestFullName -GuestId $guestId

            if ($guestFamily -eq "Windows") {
                $needWindowsCredentials = $true
            }

            if ($guestFamily -eq "Linux") {
                $needLinuxCredential = $true
            }
        }
    }

    $windowsGuestCredentials = [System.Collections.Generic.List[object]]::new()
    $linuxGuestCredential = $null

    $preferredWindowsCredentialLabel = $null

    Write-ExecutionLog "Début saisie des mots de passe"
    if (-not $SkipGuestOperations -and $needWindowsCredentials) {
        foreach ($definition in ($WindowsCredentialDefinitions | Where-Object { $_.Enabled -eq $true })) {
            $credential = Get-Credential `
                -UserName $definition.UserName `
                -Message "Mot de passe du compte Windows [$($definition.Label)] - $($definition.UserName)"

            $windowsGuestCredentials.Add([PSCustomObject]@{
                Label      = $definition.Label
                UserName   = $credential.UserName
                Credential = $credential
            })
        }
    }

    if (-not $SkipGuestOperations -and $needLinuxCredential -and $LinuxCredentialDefinition.Enabled -eq $true) {
        $credential = Get-Credential `
            -UserName $LinuxCredentialDefinition.UserName `
            -Message "Mot de passe du compte Linux [$($LinuxCredentialDefinition.Label)] - $($LinuxCredentialDefinition.UserName)"

        $linuxGuestCredential = [PSCustomObject]@{
            Label      = $LinuxCredentialDefinition.Label
            UserName   = $credential.UserName
            Credential = $credential
        }
    }

    Write-ExecutionLog "Fin saisie des mots de passe"

    # ========================================================
    # Traitement
    # ========================================================

    $vmCounter = 0
    $vmTotal = $inputRows.Count

    foreach ($row in $inputRows) {
        $vmCounter++
        $vmName = $row.VMName
        $lotName = $row.Lot

        Write-Progress -Activity "Traitement des VM" `
            -Status ("VM {0}/{1} : {2} (lot {3})" -f $vmCounter, $vmTotal, $vmName, $lotName) `
            -PercentComplete (($vmCounter / $vmTotal) * 100)

        Write-ExecutionLog ("Traitement de la machine {0}/{1} : {2} (lot {3})" -f $vmCounter, $vmTotal, $vmName, $lotName)

        $resolved = Resolve-VMView -VmIndex $vmIndex -VMName $vmName

        if ($resolved.Error) {
            $errorRows.Add([PSCustomObject]@{
                VMName = $vmName
                Lot    = $lotName
                Error  = $resolved.Error
            })
            continue
        }

        $vmView = $resolved.View

        if ($vmObjectCache.ContainsKey($vmName)) {
            $vmObject = $vmObjectCache[$vmName]
        }
        else {
            try {
                $vmObject = Get-VIObjectByVIView -VIView $vmView -ErrorAction Stop
                $vmObjectCache[$vmName] = $vmObject
            }
            catch {
                Write-ExecutionLog "Impossible de résoudre l'objet VIView pour $vmName : $_" -Level ERROR
                $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = "VIView resolution failed: $_" })
                continue
            }
        }

        $rowKey = "$vmName||$lotName"
        $tagStatus = if ($tagStatusByVmLot.ContainsKey($rowKey)) { $tagStatusByVmLot[$rowKey] } else { "NotProcessed" }

        # ----------------------------------------------------
        # NB_last_backup
        # ----------------------------------------------------

        $lastBackup = $null

        if ($backupField -and $vmView.CustomValue) {
            $customValue = $vmView.CustomValue |
                Where-Object { $_.Key -eq $backupField.Key } |
                Select-Object -First 1

            if ($customValue) {
                $lastBackup = $customValue.Value
            }
        }

        # ----------------------------------------------------
        # Capacité configurée / consommée datastore
        # ----------------------------------------------------

        $vCpuConfigured = [int]$vmView.Summary.Config.NumCpu
        $ramConfiguredGB = [math]::Round(($vmView.Summary.Config.MemorySizeMB / 1024), 2)

        $storageUsedGB = 0
        if ($vmView.Summary.Storage -and $null -ne $vmView.Summary.Storage.Committed) {
            $storageUsedGB = [math]::Round(($vmView.Summary.Storage.Committed / 1GB), 2)
        }

        # ----------------------------------------------------
        # Détection OS
        # ----------------------------------------------------

        $guestFullName = $vmView.Guest.GuestFullName
        if ([string]::IsNullOrWhiteSpace($guestFullName)) {
            $guestFullName = $vmView.Config.GuestFullName
        }

        $guestId = $vmView.Guest.GuestId
        if ([string]::IsNullOrWhiteSpace($guestId)) {
            $guestId = $vmView.Config.GuestId
        }

        $guestFamily = Get-GuestFamily -GuestFullName $guestFullName -GuestId $guestId
        $windowsYear = $null

        if ($guestFamily -eq "Windows") {
            $windowsYear = Get-WindowsYearFromText -Text "$guestFullName $guestId"
        }

        $toolsRunning = Test-VMwareToolsRunning -VMView $vmView

        # ----------------------------------------------------
        # Variables guest operations
        # ----------------------------------------------------

        $uptimeStatus = "Skipped"
        $uptimeDays = $null
        $uptimeOverThreshold = $false
        $guestOperationError = $null

        $ipconfigStatus = "Skipped"
        $ipconfigPath = $null
        $ipconfigError = $null

        $windowsCredentialLabelUsed = $null
        $windowsCredentialUserUsed = $null
        $windowsCredentialAttemptErrors = $null

        $linuxCredentialLabelUsed = $null
        $linuxCredentialUserUsed = $null

        # ----------------------------------------------------
        # VMware Tools guest operations
        # ----------------------------------------------------

        if (-not $SkipGuestOperations) {
            if ($vmView.Runtime.PowerState -ne "poweredOn") {
                $uptimeStatus = "SkippedPoweredOff"
                $ipconfigStatus = "SkippedPoweredOff"
            }
            elseif (-not $toolsRunning) {
                $uptimeStatus = "SkippedToolsNotRunning"
                $ipconfigStatus = "SkippedToolsNotRunning"
            }
            else {
                # ------------------------------
                # Linux : uptime en jours
                # ------------------------------
                if ($guestFamily -eq "Linux") {
                    if ($null -eq $linuxGuestCredential) {
                        $uptimeStatus = "Error"
                        $guestOperationError = "Aucun credential Linux configuré ou saisi."
                        $linuxCredentialLabelUsed = "NoCredentialConfigured"
                    }
                    else {
                        $linuxScript = @'
awk '{print $1}' /proc/uptime
'@

                        $uptimeResult = Invoke-GuestScriptSafe `
                            -VMObject $vmObject `
                            -ScriptText $linuxScript `
                            -ScriptType Bash `
                            -GuestCredential $linuxGuestCredential.Credential `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($uptimeResult.Success) {
                            $rawSeconds = ($uptimeResult.Output -replace ",", ".").Trim()
                            $parsedSeconds = 0.0

                            if ([double]::TryParse(
                                $rawSeconds,
                                [System.Globalization.NumberStyles]::Float,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [ref]$parsedSeconds
                            )) {
                                $uptimeDays = [math]::Round(($parsedSeconds / 86400), 2)
                                $uptimeOverThreshold = [bool]($uptimeDays -gt $UptimeThresholdDays)
                                $uptimeStatus = "OK"

                                $linuxCredentialLabelUsed = $linuxGuestCredential.Label
                                $linuxCredentialUserUsed = $linuxGuestCredential.UserName
                            }
                            else {
                                $uptimeStatus = "ParseError"
                                $guestOperationError = "Impossible de parser l'uptime Linux : $($uptimeResult.Output)"
                            }
                        }
                        else {
                            $uptimeStatus = "Error"
                            $guestOperationError = $uptimeResult.Error
                            $linuxCredentialLabelUsed = "CredentialError"
                        }
                    }

                    $ipconfigStatus = "NotApplicable"
                }

                # ------------------------------
                # Windows
                # ------------------------------
                if ($guestFamily -eq "Windows") {
                    $isWindows2003 = ($windowsYear -eq 2003)
                    $isWindows2008 = ($windowsYear -eq 2008)

                    if (-not $windowsGuestCredentials -or $windowsGuestCredentials.Count -eq 0) {
                        $windowsCredentialLabelUsed = "NoCredentialConfigured"
                    }

                    # Windows 2008 : uptime via wmic (CIM/PowerShell non disponibles)
                    # Windows 2012+ : uptime via CIM PowerShell (wmic déprécié depuis 2012)
                    if ($null -ne $windowsYear -and $windowsYear -ge 2008) {
                        if ($windowsYear -ge 2012) {
                            $windowsUptimeScript = @'
$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Output ("LastBootUpTime={0}" -f $os.LastBootUpTime.ToString("yyyyMMddHHmmss"))
'@
                            $uptimeScriptType = "PowerShell"
                        }
                        else {
                            $windowsUptimeScript = @'
wmic os get LastBootUpTime /value
'@
                            $uptimeScriptType = "Bat"
                        }

                        $uptimeResult = Invoke-WindowsGuestScriptWithCredentialFallback `
                            -VMObject $vmObject `
                            -ScriptText $windowsUptimeScript `
                            -ScriptType $uptimeScriptType `
                            -AuthCandidates $windowsGuestCredentials `
                            -PreferredAuthLabel $preferredWindowsCredentialLabel `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($uptimeResult.Success) {
                            $windowsCredentialLabelUsed = $uptimeResult.CredentialLabel
                            $windowsCredentialUserUsed  = $uptimeResult.CredentialUser
                            $preferredWindowsCredentialLabel = $uptimeResult.CredentialLabel

                            $uptimeDays = Get-UptimeDaysFromWmicOutput -WmicOutput $uptimeResult.Output

                            if ($null -ne $uptimeDays) {
                                $uptimeDays = [math]::Round([double]$uptimeDays, 2)
                                $uptimeOverThreshold = [bool]($uptimeDays -gt $UptimeThresholdDays)
                                $uptimeStatus = "OK"
                            }
                            else {
                                $uptimeStatus = "ParseError"
                                $guestOperationError = "Impossible de parser LastBootUpTime depuis la sortie guest."
                            }
                        }
                        else {
                            $uptimeStatus = "Error"
                            $guestOperationError = $uptimeResult.Error
                            $windowsCredentialLabelUsed = "CredentialError"
                            $windowsCredentialAttemptErrors = $uptimeResult.Error
                        }
                    }
                    elseif ($null -eq $windowsYear) {
                        $uptimeStatus = "SkippedUnknownWindowsVersion"
                    }
                    else {
                        $uptimeStatus = "SkippedWindowsBefore2008"
                    }

                    # Windows 2003 / 2008 / 2008 R2 : ipconfig /all dans C:\temp
                    # Versions plus récentes : ipconfig non applicable
                    if ($isWindows2003 -or $isWindows2008) {
                        $safeVmFileName = ($vmName -replace '[\\/:*?"<>| ]', '_')
                        $ipconfigPathCandidate = "C:\temp\ipconfig_all_$safeVmFileName.txt"

                        $ipconfigScript = @"
if not exist C:\temp mkdir C:\temp
ipconfig /all > "$ipconfigPathCandidate"
"@

                        $ipconfigResult = Invoke-WindowsGuestScriptWithCredentialFallback `
                            -VMObject $vmObject `
                            -ScriptText $ipconfigScript `
                            -ScriptType Bat `
                            -AuthCandidates $windowsGuestCredentials `
                            -PreferredAuthLabel $preferredWindowsCredentialLabel `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($ipconfigResult.Success) {
                            $windowsCredentialLabelUsed = $ipconfigResult.CredentialLabel
                            $windowsCredentialUserUsed  = $ipconfigResult.CredentialUser
                            $preferredWindowsCredentialLabel = $ipconfigResult.CredentialLabel
                            $ipconfigPath = $ipconfigPathCandidate
                            $ipconfigStatus = "OK"
                        }
                        else {
                            $ipconfigStatus = "Error"
                            $ipconfigError = $ipconfigResult.Error
                            $windowsCredentialLabelUsed = "CredentialError"

                            if ([string]::IsNullOrWhiteSpace($windowsCredentialAttemptErrors)) {
                                $windowsCredentialAttemptErrors = $ipconfigResult.Error
                            }
                            else {
                                $windowsCredentialAttemptErrors = $windowsCredentialAttemptErrors + " || " + $ipconfigResult.Error
                            }
                        }
                    }
                    else {
                        $ipconfigStatus = "NotApplicable"
                    }
                }
            }
        }

        # ----------------------------------------------------
        # Export détail VM
        # ----------------------------------------------------

        $detailRows.Add([PSCustomObject]@{
            Lot                           = $lotName
            VMName                        = $vmName
            PowerState                    = $vmView.Runtime.PowerState

            GuestFamily                   = $guestFamily
            WindowsYearDetected           = $windowsYear
            VMwareToolsRunning            = $toolsRunning

            vCPUConfigured                = $vCpuConfigured
            RAMConfiguredGB               = $ramConfiguredGB
            StorageUsedDatastoreGB        = $storageUsedGB
            NB_last_backup                = $lastBackup

            UptimeStatus                  = $uptimeStatus
            UptimeDays                    = if ($null -ne $uptimeDays) { [math]::Round([double]$uptimeDays, 2) } else { $null }
            UptimeOverThreshold              = $uptimeOverThreshold

            IpconfigStatus                = $ipconfigStatus
            IpconfigPath                  = $ipconfigPath
            IpconfigError                 = $ipconfigError

            WindowsCredentialLabelUsed    = $windowsCredentialLabelUsed
            WindowsCredentialUserUsed     = $windowsCredentialUserUsed
            WindowsCredentialAttemptErrors = $windowsCredentialAttemptErrors

            LinuxCredentialLabelUsed      = $linuxCredentialLabelUsed
            LinuxCredentialUserUsed       = $linuxCredentialUserUsed

            GuestOperationError           = $guestOperationError
            TagStatus                     = $tagStatus
        })
    }

    Write-Progress -Activity "Traitement des VM" -Completed

    # ========================================================
    # Synthèse par lot
    # ========================================================

    $summaryRows = $detailRows |
        Group-Object Lot |
        ForEach-Object {
            $group = $_.Group

            [PSCustomObject]@{
                Lot                         = $_.Name
                VMCount                     = $group.Count
                PoweredOnVM                 = @($group | Where-Object { $_.PowerState -eq "poweredOn" }).Count
                PoweredOffVM                = @($group | Where-Object { $_.PowerState -eq "poweredOff" }).Count
                vCPUConfiguredTotal         = [int](($group | Measure-Object -Property vCPUConfigured -Sum).Sum)
                RAMConfiguredTotalGB        = [math]::Round((($group | Measure-Object -Property RAMConfiguredGB -Sum).Sum), 2)
                StorageUsedTotalGB          = [math]::Round((($group | Measure-Object -Property StorageUsedDatastoreGB -Sum).Sum), 2)
                VMWithoutLastBackup         = @($group | Where-Object { [string]::IsNullOrWhiteSpace($_.NB_last_backup) }).Count
                VMWithUptimeOK              = @($group | Where-Object { $_.UptimeStatus -eq "OK" }).Count
                VMWithUptimeError           = @($group | Where-Object { $_.UptimeStatus -in @("Error", "ParseError") }).Count
                VMWithUptimeSkipped         = @($group | Where-Object { $_.UptimeStatus -like "Skipped*" -or $_.UptimeStatus -eq "NotApplicable" }).Count
                VMWithUptimeOverThreshold   = @($group | Where-Object { $_.UptimeOverThreshold -eq $true }).Count
                VMWithIpconfigOK            = @($group | Where-Object { $_.IpconfigStatus -eq "OK" }).Count
                VMWithIpconfigError         = @($group | Where-Object { $_.IpconfigStatus -eq "Error" }).Count
                VMWithTagError              = @($group | Where-Object { $_.TagStatus -eq "TagError" }).Count
            }
        } |
        Sort-Object Lot

    # ========================================================
    # Exports CSV
    # ========================================================

    $detailRows |
        Sort-Object Lot, VMName |
        Export-Csv -Path $detailCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter

    $summaryRows |
        Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter

    # Toujours exporter le fichier d'erreurs (au minimum avec l'en-tête)
    $errorRows |
        Export-Csv -Path $errorCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter

    Write-Information "" -InformationAction Continue
    Write-ExecutionLog ("Export détail des VM    : {0}" -f $detailCsv)
    Write-ExecutionLog ("Export synthèse par lot : {0}" -f $summaryCsv)
    Write-ExecutionLog ("Export erreurs          : {0}" -f $errorCsv)

    $overThreshold = @($detailRows | Where-Object { $_.UptimeOverThreshold -eq $true }).Count
    Write-Information "" -InformationAction Continue
    Write-ExecutionLog "--- Résumé d'exécution ---"
    Write-ExecutionLog ("VMs traitées : {0} | Erreurs structurelles : {1} | Uptime > {2} jours : {3}" -f $detailRows.Count, $errorRows.Count, $UptimeThresholdDays, $overThreshold)

    if ($errorRows.Count -gt 0) {
        Write-ExecutionLog ("ATTENTION : {0} erreur(s) structurelle(s) détectée(s) — consulter {1}" -f $errorRows.Count, $errorCsv) -Level WARN
    }

    Write-Information "" -InformationAction Continue
    $summaryRows | Format-Table -AutoSize
}
finally {
    Disconnect-VIServer -Server $VCenter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
