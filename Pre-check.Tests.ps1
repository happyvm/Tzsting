$script:ast = $null

function global:Get-TestRepoRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path -LiteralPath $PSScriptRoot).Path
    }

    if ($PSCommandPath) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent $PSCommandPath)).Path
    }

    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
    }

    return (Get-Location).Path
}

function global:Get-TestScriptPath {
    $repoRoot = Get-TestRepoRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'Unable to determine repository root for Pre-check.Tests.ps1'
    }

    return (Join-Path $repoRoot 'Pre-check.ps1')
}

function global:Import-FunctionFromScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $scriptPath = Get-TestScriptPath

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Script file not found: $scriptPath"
    }

    if (-not $script:ast) {
        $parseErrors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)

        if ($parseErrors) {
            $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
            throw "Unable to parse ${scriptPath}: $messages"
        }
    }

    $funcAst = $script:ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)

    if (-not $funcAst) {
        throw "Function '$Name' not found in $scriptPath"
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
}

Describe 'Pre-check.ps1 - quality gates' {
    It 'is syntactically valid PowerShell' {
        $scriptPath = Get-TestScriptPath
        Test-Path -LiteralPath $scriptPath | Should -BeTrue

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null

        $errors | Should -BeNullOrEmpty
    }

    It 'passes ScriptAnalyzer error+warning+information rules when module and command are available' {
        $analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer
        $analyzerCommand = Get-Command -Name Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue

        if (-not $analyzerModule -or -not $analyzerCommand) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer module/command is not available on this host.'
            return
        }

        $issues = Invoke-ScriptAnalyzer -Path (Get-TestRepoRoot) -Recurse -Severity Error, Warning, Information
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
        $index = @{ 'SRV-APP-01' = @($fakeView) }
        $result = Resolve-VMView -VmIndex $index -VMName 'SRV-APP-01'
        $result.Error | Should -BeNullOrEmpty
        $result.View  | Should -Be $fakeView
    }

    It 'returns an error when multiple VMs share the same name' {
        $view1 = [pscustomobject]@{ Name = 'SRV-DUP' }
        $view2 = [pscustomobject]@{ Name = 'SRV-DUP' }
        $index = @{ 'SRV-DUP' = @($view1, $view2) }
        $result = Resolve-VMView -VmIndex $index -VMName 'SRV-DUP'
        $result.View  | Should -BeNullOrEmpty
        $result.Error | Should -BeLike '*Ambiguous*'
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
        Mock -CommandName 'Invoke-VMScript' -MockWith {
            [pscustomobject]@{ ScriptOutput = "  hello`r  " }
        }

        $cred = [System.Management.Automation.PSCredential]::new(
            'user',
            [System.Security.SecureString]::new()
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
        Mock -CommandName 'Invoke-VMScript' -MockWith { throw 'Connection refused' }

        $cred = [System.Management.Automation.PSCredential]::new(
            'user',
            [System.Security.SecureString]::new()
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

        function Get-FakeCredential {
            param([string]$Label, [string]$User)
            $sec = [System.Security.SecureString]::new()
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
            -AuthCandidates @()

        $result.Success | Should -BeFalse
        $result.Error   | Should -Not -BeNullOrEmpty
    }

    It 'returns success with the first candidate when it works' {
        Mock Invoke-GuestScriptSafe {
            [pscustomobject]@{ Success = $true; Output = 'ok'; Error = $null }
        }

        $candidates = @(Get-FakeCredential 'ADMIN-01' '.\Administrator')

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -AuthCandidates $candidates

        $result.Success         | Should -BeTrue
        $result.CredentialLabel | Should -Be 'ADMIN-01'
    }

    It 'falls back to a second candidate when the first fails' {
        $script:guestCallCount = 0
        Mock Invoke-GuestScriptSafe {
            $script:guestCallCount++
            if ($script:guestCallCount -eq 1) {
                return [pscustomobject]@{ Success = $false; Output = $null; Error = 'fail' }
            }
            return [pscustomobject]@{ Success = $true; Output = 'ok'; Error = $null }
        }

        $candidates = @(
            (Get-FakeCredential 'ADMIN-01' '.\Administrator'),
            (Get-FakeCredential 'ADMIN-02' '.\Administrateur')
        )

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -AuthCandidates $candidates

        $result.Success         | Should -BeTrue
        $result.CredentialLabel | Should -Be 'ADMIN-02'
        $script:guestCallCount  | Should -Be 2
    }

    It 'returns failure when all candidates fail' {
        Mock Invoke-GuestScriptSafe {
            [pscustomobject]@{ Success = $false; Output = $null; Error = 'Auth failed' }
        }

        $candidates = @(
            (Get-FakeCredential 'ADMIN-01' '.\Administrator'),
            (Get-FakeCredential 'ADMIN-02' '.\Administrateur')
        )

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -AuthCandidates $candidates

        $result.Success | Should -BeFalse
        $result.Error   | Should -BeLike '*ADMIN-01*'
        $result.Error   | Should -BeLike '*ADMIN-02*'
    }

    It 'tries the preferred credential first' {
        Mock Invoke-GuestScriptSafe {
            return [pscustomobject]@{ Success = $false; Output = $null; Error = 'Auth failed' }
        }

        $candidates = @(
            (Get-FakeCredential 'ADMIN-01' '.\Administrator'),
            (Get-FakeCredential 'ADMIN-02' '.\Administrateur')
        )

        $result = Invoke-WindowsGuestScriptWithCredentialFallback `
            -VMObject ([pscustomobject]@{}) `
            -ScriptText 'dir' `
            -ScriptType Bat `
            -AuthCandidates $candidates `
            -PreferredAuthLabel 'ADMIN-02'

        # When ADMIN-02 is preferred it is tried first, so its label appears
        # first in the combined error string built by the function.
        $result.Error.IndexOf('ADMIN-02') | Should -BeLessThan ($result.Error.IndexOf('ADMIN-01'))
    }
}
