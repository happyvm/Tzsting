@{
    Arrays = @(
        'fa-prod-01.company.local'
        'fa-prod-02.company.local'
    )

    IgnoreCertificateErrors = $true

    # Résolution des points en millisecondes (30s par défaut)
    ResolutionMs = 30000

    # Fenêtre d'extraction en minutes
    WindowMinutes = 60

    # Agrégation de la série temporelle: average, max, min
    Aggregation = 'average'

    OutputCsv = '.\pure-performance.csv'

    ArrayCredentials = @(
        @{ Array = 'fa-prod-01.company.local'; UserName = 'pureuser1'; Password = '' }
        @{ Array = 'fa-prod-02.company.local'; UserName = 'pureuser2'; Password = '' }
    )
}
