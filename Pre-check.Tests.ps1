$script:repoRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:scriptPath = Join-Path $script:repoRoot 'Pre-check.ps1'
$script:ast = $null

function Import-FunctionFromScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $script:scriptPath)) {
        throw "Script file not found: $script:scriptPath"
    }

    if (-not $script:ast) {
        $parseErrors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$parseErrors)

        if ($parseErrors) {
            $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
            throw "Unable to parse $script:scriptPath: $messages"
        }
    }

    $funcAst = $script:ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)

    if (-not $funcAst) {
        throw "Function '$Name' not found in $script:scriptPath"
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
}

Describe 'Pre-check.ps1 - quality gates' {
    It 'is syntactically valid PowerShell' {
        Test-Path -LiteralPath $script:scriptPath | Should -BeTrue

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$tokens, [ref]$errors) | Out-Null

        $errors | Should -BeNullOrEmpty
    }

    It 'passes ScriptAnalyzer error+warning+information rules when module and command are available' {
        $analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer
        $analyzerCommand = Get-Command -Name Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue

        if (-not $analyzerModule -or -not $analyzerCommand) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module/command is not available on this host.'
            return
        }

        $issues = Invoke-ScriptAnalyzer -Path $script:repoRoot -Recurse -Severity Error, Warning, Information
        $issues | Should -BeNullOrEmpty
    }
}

Describe 'Get-WindowsYearFromText' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Get-WindowsYearFromText'
    }

    It 'returns null for empty values' {
        Get-WindowsYearFromText -Text '' | Should -Be $null
        Get-WindowsYearFromText -Text $null | Should -Be $null
    }

    It 'detects known Windows versions' {
        Get-WindowsYearFromText -Text 'Windows Server 2008 R2' | Should -Be 2008
        Get-WindowsYearFromText -Text 'Windows Server 2019 Datacenter' | Should -Be 2019
        Get-WindowsYearFromText -Text 'Windows Server 2025' | Should -Be 2025
    }

    It 'returns null for unsupported versions' {
        Get-WindowsYearFromText -Text 'Windows NT 4.0' | Should -Be $null
    }
}

Describe 'Get-GuestFamily' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Get-GuestFamily'
    }

    It 'detects Windows guests' {
        Get-GuestFamily -GuestFullName 'Microsoft Windows Server 2016' -GuestId 'windows9Server64Guest' | Should -Be 'Windows'
    }

    It 'detects Linux guests' {
        Get-GuestFamily -GuestFullName 'Ubuntu Linux (64-bit)' -GuestId 'ubuntu64Guest' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'Unknown' -GuestId 'rhel8_64Guest' | Should -Be 'Linux'
    }

    It 'returns Unknown when no match is found' {
        Get-GuestFamily -GuestFullName 'FreeBSD' -GuestId 'otherGuest64' | Should -Be 'Unknown'
    }
}

Describe 'Test-VMwareToolsRunning' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Test-VMwareToolsRunning'
    }

    It 'returns true when ToolsRunningStatus is guestToolsRunning' {
        $vmView = [pscustomobject]@{
            Guest = [pscustomobject]@{
                ToolsRunningStatus = 'guestToolsRunning'
                ToolsStatus        = 'toolsNotRunning'
            }
        }

        Test-VMwareToolsRunning -VMView $vmView | Should -BeTrue
    }

    It 'returns true when legacy ToolsStatus is toolsOk' {
        $vmView = [pscustomobject]@{
            Guest = [pscustomobject]@{
                ToolsRunningStatus = 'guestToolsNotRunning'
                ToolsStatus        = 'toolsOk'
            }
        }

        Test-VMwareToolsRunning -VMView $vmView | Should -BeTrue
    }

    It 'returns false when neither status is valid' {
        $vmView = [pscustomobject]@{
            Guest = [pscustomobject]@{
                ToolsRunningStatus = 'guestToolsNotRunning'
                ToolsStatus        = 'toolsNotInstalled'
            }
        }

        Test-VMwareToolsRunning -VMView $vmView | Should -BeFalse
    }
}
