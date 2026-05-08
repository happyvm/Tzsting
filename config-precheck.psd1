@{
    # ----------------------------------------------------------
    # vCenter connection
    # ----------------------------------------------------------

    # vCenter server hostname or IP address.
    VCenter             = "vcenter.company.local"

    # ----------------------------------------------------------
    # Input
    # ----------------------------------------------------------

    # Path to the input CSV file (vmname;tag columns required).
    InputCsv            = ".\migration_input.csv"

    # ----------------------------------------------------------
    # Output
    # ----------------------------------------------------------

    # Destination folder for the CSV files produced by the script.
    OutputFolder        = "."

    # Path to a log file. Leave empty to write to the console only.
    LogFile             = ""

    # CSV delimiter used for reading the input file and writing output files.
    CsvDelimiter        = ";"

    # ----------------------------------------------------------
    # vSphere
    # ----------------------------------------------------------

    # Name of the vSphere tag category (Single cardinality, VirtualMachine entity type).
    TagCategoryName     = "MigrationLot"

    # Name of the vCenter custom attribute to read on each VM.
    CustomAttributeName = "NB_last_backup"

    # Timeout in seconds granted to VMware Tools to respond during guest operations.
    ToolsWaitSecs       = 20

    # ----------------------------------------------------------
    # Behaviour
    # ----------------------------------------------------------

    # Uptime threshold in days: if uptime exceeds this value, UptimeOverThreshold = $true.
    UptimeThresholdDays = 45

    # ----------------------------------------------------------
    # Windows credentials (tried in order; set Enabled = $false to skip an entry)
    # Passwords are never stored here: they are prompted at runtime.
    # ----------------------------------------------------------

    WindowsCredentials  = @(
        @{ Label = "WIN-LOCAL-ADMIN-01"; UserName = ".\Administrateur"; Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-02"; UserName = ".\Administrator";  Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-03"; UserName = ".\admin";          Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-04"; UserName = ".\adminlocal";     Enabled = $true  }
        @{ Label = "WIN-LOCAL-ADMIN-05"; UserName = ".\adm-local";      Enabled = $true  }
    )

    # ----------------------------------------------------------
    # Linux credential
    # ----------------------------------------------------------

    LinuxCredential     = @{ Label = "LINUX-ADMIN-01"; UserName = "root"; Enabled = $true }
}
