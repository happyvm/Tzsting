@{
    # ----------------------------------------------------------
    # Sorties
    # ----------------------------------------------------------

    # Dossier de destination des CSV produits par le script.
    OutputFolder        = "."

    # Chemin d'un fichier de log. Laisser vide pour la console uniquement.
    LogFile             = ""

    # Délimiteur CSV (lecture de l'entrée et écriture des sorties).
    CsvDelimiter        = ";"

    # ----------------------------------------------------------
    # vSphere
    # ----------------------------------------------------------

    # Nom de la catégorie de tag vSphere (cardinalité Single, type VirtualMachine).
    TagCategoryName     = "MigrationLot"

    # Nom de l'attribut personnalisé vCenter à lire sur chaque VM.
    CustomAttributeName = "NB_last_backup"

    # Délai (secondes) accordé à VMware Tools pour répondre lors des guest operations.
    ToolsWaitSecs       = 20

    # ----------------------------------------------------------
    # Comportement
    # ----------------------------------------------------------

    # Seuil en jours : si l'uptime dépasse cette valeur, UptimeOverThreshold = $true.
    UptimeThresholdDays = 45

    # ----------------------------------------------------------
    # Credentials Windows (essayés dans l'ordre ; Enabled = $false pour désactiver)
    # Les mots de passe ne sont jamais stockés ici : ils sont demandés à l'exécution.
    # ----------------------------------------------------------

    WindowsCredentials  = @(
        @{ Label = "WIN-LOCAL-ADMIN-01"; UserName = ".\Administrateur"; Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-02"; UserName = ".\Administrator";  Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-03"; UserName = ".\admin";          Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-04"; UserName = ".\adminlocal";     Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-05"; UserName = ".\adm-local";      Enabled = $true  }
    )

    # ----------------------------------------------------------
    # Credential Linux
    # ----------------------------------------------------------

    LinuxCredential     = @{ Label = "LINUX-ADMIN-01"; UserName = "root"; Enabled = $true }
}
