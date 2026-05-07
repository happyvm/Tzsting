BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Pre-check.ps1'
}

Describe 'Pre-check.ps1 - quality gates' {
    It 'is syntactically valid PowerShell' {
        $null = $null
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null

        $errors | Should -BeNullOrEmpty
    }

    It 'passes ScriptAnalyzer error rules when module is available' {
        $analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer

        if (-not $analyzer) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module not installed on this host.'
            return
        }

        $issues = Invoke-ScriptAnalyzer -Path $scriptPath -Severity Error
        $issues | Should -BeNullOrEmpty
    }
}
