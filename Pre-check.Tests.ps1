BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Pre-check.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    function Import-FunctionFromScript {
        param(
            [Parameter(Mandatory = $true)][string]$Name
        )

        $funcAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)

        if (-not $funcAst) {
            throw "Function '$Name' not found in $scriptPath"
        }

        . ([scriptblock]::Create($funcAst.Extent.Text))
    }
}

Describe 'Pre-check.ps1 - quality gates' {
    It 'is syntactically valid PowerShell' {
        $null = $null
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null

        $errors | Should -BeNullOrEmpty
    }

    It 'passes ScriptAnalyzer warning+error rules when module is available' {
        $analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer

        if (-not $analyzer) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module not installed on this host.'
            return
        }

        $issues = Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning, Error
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
