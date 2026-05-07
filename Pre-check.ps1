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
    - Indique si l'uptime est supérieur à 45 jours
    - Pour Windows 2003 / 2008 / 2008 R2 :
        - exécute ipconfig /all
        - stocke le résultat dans C:\temp dans la VM
    - Essaie jusqu'à 5 credentials Windows locaux
    - Exporte le label du credential Windows qui a fonctionné

.INPUT CSV
    vmname;tag
    SRV-APP-001;LOT-01
    SRV-DB-001;LOT-01
    SRV-LIN-001;LOT-02

.OUTPUT
    migration_lot_detail.csv
    migration_lot_summary.csv
    migration_lot_errors.csv
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VCenter,

    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$OutputFolder = ".",

    [string]$TagCategoryName = "MigrationLot",

    [string]$CustomAttributeName = "NB_last_backup",

    [int]$ToolsWaitSecs = 20,

    [switch]$SkipGuestOperations
)

# ============================================================
# Configuration des comptes invités VMware Tools
# Les labels servent uniquement au reporting.
# Les mots de passe ne sont jamais exportés.
# Adapte les UserName à ton contexte.
# ============================================================

$WindowsCredentialDefinitions = @(
    [PSCustomObject]@{
        Label    = "WIN-LOCAL-ADMIN-01"
        UserName = ".\Administrateur"
        Enabled  = $true
    },
    [PSCustomObject]@{
        Label    = "WIN-LOCAL-ADMIN-02"
        UserName = ".\Administrator"
        Enabled  = $true
    },
    [PSCustomObject]@{
        Label    = "WIN-LOCAL-ADMIN-03"
        UserName = ".\admin"
        Enabled  = $true
    },
    [PSCustomObject]@{
        Label    = "WIN-LOCAL-ADMIN-04"
        UserName = ".\adminlocal"
        Enabled  = $true
    },
    [PSCustomObject]@{
        Label    = "WIN-LOCAL-ADMIN-05"
        UserName = ".\adm-local"
        Enabled  = $true
    }
)

$LinuxCredentialDefinition = [PSCustomObject]@{
    Label    = "LINUX-ADMIN-01"
    UserName = "root"
    Enabled  = $true
}

# ============================================================
# Fonctions
# ============================================================

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
        [object[]]$CredentialCandidates,

        [string]$PreferredCredentialLabel,

        [int]$ToolsWaitSecs = 20
    )

    if (-not $CredentialCandidates -or $CredentialCandidates.Count -eq 0) {
        return [PSCustomObject]@{
            Success         = $false
            Output          = $null
            Error           = "Aucun credential Windows candidat fourni."
            CredentialLabel = $null
            CredentialUser  = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredCredentialLabel)) {
        $preferred = @($CredentialCandidates | Where-Object { $_.Label -eq $PreferredCredentialLabel })
        $others    = @($CredentialCandidates | Where-Object { $_.Label -ne $PreferredCredentialLabel })
        $orderedCandidates = @($preferred + $others)
    }
    else {
        $orderedCandidates = @($CredentialCandidates)
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

function Get-OrCreate-LotTag {
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

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

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

$CsvDelimiter = ';'

Write-Host ("[STEP] Start reading CSV: {0}" -f $InputCsv)
$rawRows = @(Import-Csv -Path $InputCsv -Delimiter $CsvDelimiter)
Write-Host ("[STEP] End reading CSV - {0} line(s) loaded" -f $rawRows.Count)

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

$vmInMultipleLots = $inputRows |
    Group-Object VMName |
    Where-Object {
        @($_.Group.Lot | Sort-Object -Unique).Count -gt 1
    }

if ($vmInMultipleLots.Count -gt 0) {
    $badVMs = ($vmInMultipleLots | Select-Object -ExpandProperty Name) -join ", "
    throw "Erreur de lotissement : certaines VM sont présentes dans plusieurs lots : $badVMs"
}

# ============================================================
# Connexion vCenter
# ============================================================

$vcenterCredential = Get-Credential -Message "Compte vCenter"
Connect-VIServer -Server $VCenter -Credential $vcenterCredential | Out-Null

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
        Write-Warning "Attribut personnalisé '$CustomAttributeName' introuvable. La colonne sera vide."
    }

    # ========================================================
    # Chargement des VM vCenter
    # ========================================================

    $allVmViews = Get-View -ViewType VirtualMachine -Property `
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
            $vmIndex[$vmView.Name] = @()
        }

        $vmIndex[$vmView.Name] += $vmView
    }

    # ========================================================
    # Tagging en début de traitement
    # ========================================================

    Write-Host "[STEP] Start tagging"

    $script:tagCache = @{}
    $tagStatusByVmLot = @{}
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

        Write-Host ("Tagging {0}/{1}: {2} (lot {3})" -f $tagCounter, $tagTotal, $vmName, $lotName)

        if (-not $vmIndex.ContainsKey($vmName)) {
            $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = "VM introuvable dans vCenter" })
            continue
        }

        $matches = @($vmIndex[$vmName])
        if ($matches.Count -gt 1) {
            $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = "Nom de VM ambigu : plusieurs VM portent ce nom dans vCenter" })
            continue
        }

        try {
            $vmObject = Get-VIObjectByVIView -VIView $matches[0] -ErrorAction Stop
            $lotTag = Get-OrCreate-LotTag -LotName $lotName -Category $tagCategory
            $currentAssignments = @(Get-TagAssignment -Entity $vmObject -Category $tagCategory -ErrorAction SilentlyContinue)
            $assignmentsToRemove = @($currentAssignments | Where-Object { $_.Tag.Name -ne $lotName })
            if ($assignmentsToRemove.Count -gt 0) { $assignmentsToRemove | Remove-TagAssignment -Confirm:$false | Out-Null }
            $alreadyAssigned = @(Get-TagAssignment -Entity $vmObject -Category $tagCategory -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Name -eq $lotName })

            if ($alreadyAssigned.Count -eq 0) {
                New-TagAssignment -Tag $lotTag -Entity $vmObject -ErrorAction Stop | Out-Null
                $tagStatusByVmLot[$rowKey] = "Assigned"
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

    Write-Host "[STEP] End tagging"

    # ========================================================
    # Détermination des credentials nécessaires
    # ========================================================

    $needWindowsCredentials = $false
    $needLinuxCredential = $false

    if (-not $SkipGuestOperations) {
        foreach ($row in $inputRows) {
            if (-not $vmIndex.ContainsKey($row.VMName)) {
                continue
            }

            $matches = @($vmIndex[$row.VMName])

            if ($matches.Count -ne 1) {
                continue
            }

            $vmView = $matches[0]

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

    $windowsGuestCredentials = @()
    $linuxGuestCredential = $null

    $preferredWindowsCredentialLabel = $null

    Write-Host "[STEP] Start check password"
    if (-not $SkipGuestOperations -and $needWindowsCredentials) {
        foreach ($definition in ($WindowsCredentialDefinitions | Where-Object { $_.Enabled -eq $true })) {
            $credential = Get-Credential `
                -UserName $definition.UserName `
                -Message "Mot de passe du compte Windows [$($definition.Label)] - $($definition.UserName)"

            $windowsGuestCredentials += [PSCustomObject]@{
                Label      = $definition.Label
                UserName   = $credential.UserName
                Credential = $credential
            }
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

    Write-Host "[STEP] End check password"

    # ========================================================
    # Traitement
    # ========================================================

    $vmCounter = 0
    $vmTotal = $inputRows.Count

    foreach ($row in $inputRows) {
        $vmCounter++
        $vmName = $row.VMName
        $lotName = $row.Lot

        Write-Host ("Traitement de la machine {0}/{1} : {2} (lot {3})" -f $vmCounter, $vmTotal, $vmName, $lotName)

        if (-not $vmIndex.ContainsKey($vmName)) {
            $errorRows.Add([PSCustomObject]@{
                VMName = $vmName
                Lot    = $lotName
                Error  = "VM introuvable dans vCenter"
            })
            continue
        }

        $matches = @($vmIndex[$vmName])

        if ($matches.Count -gt 1) {
            $errorRows.Add([PSCustomObject]@{
                VMName = $vmName
                Lot    = $lotName
                Error  = "Nom de VM ambigu : plusieurs VM portent ce nom dans vCenter"
            })
            continue
        }

        $vmView = $matches[0]
        $vmObject = Get-VIObjectByVIView -VIView $vmView -ErrorAction Stop
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
        $uptimeOver45Days = $false
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
                        $linuxCredentialLabelUsed = "nopassword"
                    }
                    else {
                        $linuxScript = @'
cat /proc/uptime | awk '{print $1}'
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
                                $uptimeOver45Days = [bool]($uptimeDays -gt 45)
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
                            $linuxCredentialLabelUsed = "nopassword"
                        }
                    }
                }

                # ------------------------------
                # Windows
                # ------------------------------
                if ($guestFamily -eq "Windows") {
                    $isWindows2003 = ($windowsYear -eq 2003)
                    $isWindows2008 = ($windowsYear -eq 2008)

                    $isWindows2008OrHigher = (
                        ($windowsYear -ne $null -and $windowsYear -ge 2008) -or
                        ($windowsYear -eq $null -and $guestFullName -notmatch "2003")
                    )

                    if (-not $windowsGuestCredentials -or $windowsGuestCredentials.Count -eq 0) {
                        $windowsCredentialLabelUsed = "nopassword"
                    }

                    # Windows 2008+ : uptime en jours
                    if ($isWindows2008OrHigher) {
                        $windowsUptimeScript = @'
wmic os get LastBootUpTime /value
'@

                        $uptimeResult = Invoke-WindowsGuestScriptWithCredentialFallback `
                            -VMObject $vmObject `
                            -ScriptText $windowsUptimeScript `
                            -ScriptType Bat `
                            -CredentialCandidates $windowsGuestCredentials `
                            -PreferredCredentialLabel $preferredWindowsCredentialLabel `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($uptimeResult.Success) {
                            $windowsCredentialLabelUsed = $uptimeResult.CredentialLabel
                            $windowsCredentialUserUsed  = $uptimeResult.CredentialUser
                            $preferredWindowsCredentialLabel = $uptimeResult.CredentialLabel

                            $uptimeDays = Get-UptimeDaysFromWmicOutput -WmicOutput $uptimeResult.Output

                            if ($null -ne $uptimeDays) {
                                $uptimeDays = [math]::Round([double]$uptimeDays, 2)
                                $uptimeOver45Days = [bool]($uptimeDays -gt 45)
                                $uptimeStatus = "OK"
                            }
                            else {
                                $uptimeStatus = "ParseError"
                                $guestOperationError = "Impossible de parser LastBootUpTime depuis WMIC."
                            }
                        }
                        else {
                            $uptimeStatus = "Error"
                            $guestOperationError = $uptimeResult.Error
                            $windowsCredentialLabelUsed = "nopassword"
                            $windowsCredentialAttemptErrors = $uptimeResult.Error
                        }
                    }
                    else {
                        $uptimeStatus = "SkippedWindowsBefore2008"
                    }

                    # Windows 2003 / 2008 / 2008 R2 : ipconfig /all dans C:\temp
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
                            -CredentialCandidates $windowsGuestCredentials `
                            -PreferredCredentialLabel $preferredWindowsCredentialLabel `
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
                            $windowsCredentialLabelUsed = "nopassword"

                            if ([string]::IsNullOrWhiteSpace($windowsCredentialAttemptErrors)) {
                                $windowsCredentialAttemptErrors = $ipconfigResult.Error
                            }
                            else {
                                $windowsCredentialAttemptErrors = $windowsCredentialAttemptErrors + " || " + $ipconfigResult.Error
                            }
                        }
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
            UptimeOver45Days              = $uptimeOver45Days

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
                VMWithUptimeErrorOrSkipped  = @($group | Where-Object { $_.UptimeStatus -ne "OK" }).Count
                VMWithUptimeOver45Days      = @($group | Where-Object { $_.UptimeOver45Days -eq $true }).Count
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

    if ($errorRows.Count -gt 0) {
        $errorRows |
            Export-Csv -Path $errorCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter
    }

    Write-Host ""
    Write-Host "Export détail des VM    : $detailCsv"
    Write-Host "Export synthèse par lot : $summaryCsv"

    if ($errorRows.Count -gt 0) {
        Write-Warning "Des erreurs structurelles ont été détectées : $errorCsv"
    }

    Write-Host ""
    $summaryRows | Format-Table -AutoSize
}
finally {
    Disconnect-VIServer -Server $VCenter -Confirm:$false | Out-Null
}
