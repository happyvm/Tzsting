@{
    # Liste des baies Pure Storage à interroger par défaut.
    # Optionnel si ArrayCredentials est renseigné: la liste des baies sera déduite automatiquement.
    Arrays = @(
        'fa-prod-01.company.local'
        'fa-prod-02.company.local'
    )

    # Ignore les erreurs de certificat TLS (certificats auto-signés, expirés, etc.).
    IgnoreCertificateErrors = $true

    # Regex appliquée au nom d'hôte ET au nom de hostgroup pour exclure les non-physiques.
    # Couvre: hyperviseurs ESX/VMware/Hyper-V, serveurs de backup NBU media server.
    ExcludeHostRegex = '(?i)(^|[-_.])(esx\d*|esxi\d*|vmware|hyper-?v|hv\d+|nbu-mediaserver)([-_.]|$)'

    # Fichier CSV de sortie.
    OutputCsv = '.\pure-physical-volumes.csv'

    # Comptes par baie (login propre à chaque baie).
    # Password est optionnel: si vide, un prompt est affiché pour la baie.
    ArrayCredentials = @(
        @{ Array = 'fa-prod-01.company.local'; UserName = 'pureuser1'; Password = '' }
        @{ Array = 'fa-prod-02.company.local'; UserName = 'pureuser2'; Password = '' }
    )
}
