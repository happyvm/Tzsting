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

    It 'returns null for whitespace-only text' {
        Get-WindowsYearFromText -Text '   ' | Should -Be $null
    }

    It 'detects known Windows versions' {
        Get-WindowsYearFromText -Text 'Windows Server 2008 R2' | Should -Be 2008
        Get-WindowsYearFromText -Text 'Windows Server 2019 Datacenter' | Should -Be 2019
        Get-WindowsYearFromText -Text 'Windows Server 2025' | Should -Be 2025
    }

    It 'detects all supported year variants' {
        Get-WindowsYearFromText -Text 'Windows Server 2003' | Should -Be 2003
        Get-WindowsYearFromText -Text 'Windows Server 2012 R2' | Should -Be 2012
        Get-WindowsYearFromText -Text 'Windows Server 2016 Standard' | Should -Be 2016
        Get-WindowsYearFromText -Text 'Windows Server 2022 Datacenter' | Should -Be 2022
    }

    It 'returns null for unsupported versions' {
        Get-WindowsYearFromText -Text 'Windows NT 4.0' | Should -Be $null
        Get-WindowsYearFromText -Text 'Windows XP Professional' | Should -Be $null
    }
}

Describe 'Get-GuestFamily' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Get-GuestFamily'
    }

    It 'detects Windows guests' {
        Get-GuestFamily -GuestFullName 'Microsoft Windows Server 2016' -GuestId 'windows9Server64Guest' | Should -Be 'Windows'
    }

    It 'detects Windows case-insensitively' {
        Get-GuestFamily -GuestFullName 'WINDOWS Server 2019' -GuestId '' | Should -Be 'Windows'
        Get-GuestFamily -GuestFullName '' -GuestId 'Windows10_64Guest' | Should -Be 'Windows'
    }

    It 'detects Linux guests from common distros' {
        Get-GuestFamily -GuestFullName 'Ubuntu Linux (64-bit)' -GuestId 'ubuntu64Guest' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'Unknown' -GuestId 'rhel8_64Guest' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'CentOS 7 (64-bit)' -GuestId 'centos7_64Guest' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'Debian GNU/Linux 11' -GuestId 'debian11_64Guest' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'Red Hat Enterprise Linux 8' -GuestId '' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'Rocky Linux 9' -GuestId '' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'AlmaLinux 8' -GuestId '' | Should -Be 'Linux'
        Get-GuestFamily -GuestFullName 'Oracle Linux 7' -GuestId '' | Should -Be 'Linux'
    }

    It 'returns Unknown when no match is found' {
        Get-GuestFamily -GuestFullName 'FreeBSD' -GuestId 'otherGuest64' | Should -Be 'Unknown'
        Get-GuestFamily -GuestFullName '' -GuestId '' | Should -Be 'Unknown'
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

    It 'returns false when both statuses are empty' {
        $vmView = [pscustomobject]@{
            Guest = [pscustomobject]@{
                ToolsRunningStatus = ''
                ToolsStatus        = ''
            }
        }

        Test-VMwareToolsRunning -VMView $vmView | Should -BeFalse
    }
}

Describe 'Resolve-VMView' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Resolve-VMView'
    }

    It 'returns an error when the VM is not in the index' {
        $index = @{}
        $result = Resolve-VMView -VmIndex $index -VMName 'SRV-MISSING'
        $result.View  | Should -BeNullOrEmpty
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'returns the view when exactly one match exists' {
        $fakeView = [pscustomobject]@{ Name = 'SRV-APP-01' }
        $index = @{ 'SRV-APP-01' = [System.Collections.Generic.List[object]]@($fakeView) }
        $result = Resolve-VMView -VmIndex $index -VMName 'SRV-APP-01'
        $result.Error | Should -BeNullOrEmpty
        $result.View  | Should -Be $fakeView
    }

    It 'returns an error when multiple VMs share the same name' {
        $view1 = [pscustomobject]@{ Name = 'SRV-DUP' }
        $view2 = [pscustomobject]@{ Name = 'SRV-DUP' }
        $index = @{ 'SRV-DUP' = [System.Collections.Generic.List[object]]@($view1, $view2) }
        $result = Resolve-VMView -VmIndex $index -VMName 'SRV-DUP'
        $result.View  | Should -BeNullOrEmpty
        $result.Error | Should -BeLike '*ambigu*'
    }
}

Describe 'Get-UptimeDaysFromWmicOutput' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Get-UptimeDaysFromWmicOutput'
    }

    It 'returns null for null or empty input' {
        Get-UptimeDaysFromWmicOutput -WmicOutput $null | Should -Be $null
        Get-UptimeDaysFromWmicOutput -WmicOutput ''   | Should -Be $null
        Get-UptimeDaysFromWmicOutput -WmicOutput '   ' | Should -Be $null
    }

    It 'returns null when the output contains no LastBootUpTime pattern' {
        Get-UptimeDaysFromWmicOutput -WmicOutput 'No data here' | Should -Be $null
    }

    It 'calculates uptime correctly from a valid WMIC timestamp' {
        $bootTime = (Get-Date).AddDays(-10).ToString('yyyyMMddHHmmss')
        $result = Get-UptimeDaysFromWmicOutput -WmicOutput "LastBootUpTime=$bootTime"
        $result | Should -Not -Be $null
        $result | Should -BeGreaterThan 9
        $result | Should -BeLessThan 11
    }

    It 'returns null when the timestamp cannot be parsed as a date' {
        Get-UptimeDaysFromWmicOutput -WmicOutput 'LastBootUpTime=99999999999999' | Should -Be $null
    }
}

Describe 'Invoke-GuestScriptSafe' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Invoke-GuestScriptSafe'
    }

    It 'returns Success=true and trimmed output on success' {
        Mock Invoke-VMScript {
            [pscustomobject]@{ ScriptOutput = "  hello`r  " }
        }

        $cred = [System.Management.Automation.PSCredential]::new(
            'user',
            (ConvertTo-SecureString 'pass' -AsPlainText -Force)
        )

        $result = Invoke-GuestScriptSafe `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'echo hello' `
            -ScriptType Bash `
            -GuestCredential $cred

        $result.Success | Should -BeTrue
        $result.Output  | Should -Be 'hello'
        $result.Error   | Should -BeNullOrEmpty
    }

    It 'returns Success=false and the exception message on failure' {
        Mock Invoke-VMScript { throw 'Connection refused' }

        $cred = [System.Management.Automation.PSCredential]::new(
            'user',
            (ConvertTo-SecureString 'pass' -AsPlainText -Force)
        )

        $result = Invoke-GuestScriptSafe `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'echo hello' `
            -ScriptType Bash `
            -GuestCredential $cred

        $result.Success | Should -BeFalse
        $result.Output  | Should -BeNullOrEmpty
        $result.Error   | Should -BeLike '*Connection refused*'
    }
}

Describe 'Invoke-WindowsGuestScriptWithCredentialFallback' {
    BeforeAll {
        Import-FunctionFromScript -Name 'Invoke-GuestScriptSafe'
        Import-FunctionFromScript -Name 'Invoke-WindowsGuestScriptWithCredentialFallback'

        function New-FakeCred {
            param([string]$Label, [string]$User)
            $sec = ConvertTo-SecureString 'x' -AsPlainText -Force
            [pscustomobject]@{
                Label      = $Label
                UserName   = $User
                Credential = [System.Management.Automation.PSCredential]::new($User, $sec)
            }
        }
    }

    It 'returns failure immediately when no candidates are provided' {
        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -CredentialCandidates @()

        $result.Success | Should -BeFalse
        $result.Error   | Should -Not -BeNullOrEmpty
    }

    It 'returns success with the first candidate when it works' {
        Mock Invoke-VMScript { [pscustomobject]@{ ScriptOutput = 'ok' } }

        $candidates = @(New-FakeCred 'ADMIN-01' '.\Administrator')

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -CredentialCandidates $candidates

        $result.Success         | Should -BeTrue
        $result.CredentialLabel | Should -Be 'ADMIN-01'
    }

    It 'falls back to a second candidate when the first fails' {
        $script:fallbackCallCount = 0
        Mock Invoke-VMScript {
            $script:fallbackCallCount++
            if ($script:fallbackCallCount -eq 1) { throw 'Auth failed' }
            [pscustomobject]@{ ScriptOutput = 'ok' }
        }

        $candidates = @(
            (New-FakeCred 'ADMIN-01' '.\Administrator'),
            (New-FakeCred 'ADMIN-02' '.\Administrateur')
        )

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -CredentialCandidates $candidates

        $result.Success         | Should -BeTrue
        $result.CredentialLabel | Should -Be 'ADMIN-02'
    }

    It 'returns failure when all candidates fail' {
        Mock Invoke-VMScript { throw 'Auth failed' }

        $candidates = @(
            (New-FakeCred 'ADMIN-01' '.\Administrator'),
            (New-FakeCred 'ADMIN-02' '.\Administrateur')
        )

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -CredentialCandidates $candidates

        $result.Success | Should -BeFalse
        $result.Error   | Should -BeLike '*ADMIN-01*'
        $result.Error   | Should -BeLike '*ADMIN-02*'
    }

    It 'tries the preferred credential first' {
        $script:preferredTriedFirst = $false
        Mock Invoke-VMScript {
            # Only the Administrateur (ADMIN-02) call should be first
            $script:preferredTriedFirst = ($GuestCredential.UserName -eq '.\Administrateur')
            throw 'Auth failed'
        }

        $candidates = @(
            (New-FakeCred 'ADMIN-01' '.\Administrator'),
            (New-FakeCred 'ADMIN-02' '.\Administrateur')
        )

        Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -CredentialCandidates $candidates `
            -PreferredCredentialLabel 'ADMIN-02' | Out-Null

        $script:preferredTriedFirst | Should -BeTrue
    }
}
