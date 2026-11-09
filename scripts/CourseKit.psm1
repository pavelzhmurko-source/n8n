Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ComposeFile = Join-Path $script:ProjectRoot 'compose.yaml'
$script:ProjectName = 'n8n-course-kit'
$script:WebhookPath = '/webhook/telegram-course'
$script:TelegramApiBase = 'https://api.telegram.org'
$script:N8nImage = 'n8nio/n8n:3.1.0@sha256:6e9f220e9cf0d2f17d3c2371c8d8a6fe6720f99b82a9672afb96bf068cfd04a5'
$script:DataVolume = 'n8n-course-kit_n8n_data'

function Get-CourseKitHome {
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is unavailable. Course Kit must run in a Windows user session.'
    }
    return Join-Path $env:LOCALAPPDATA 'N8nCourseKit'
}

function Get-CourseKitPaths {
    $homePath = Get-CourseKitHome
    [pscustomobject]@{
        Home = $homePath
        Settings = Join-Path $homePath 'settings.json'
        Secrets = Join-Path $homePath 'secrets.dpapi.json'
        State = Join-Path $homePath 'state.json'
        Runtime = Join-Path $homePath 'runtime'
        Import = Join-Path (Join-Path $homePath 'runtime') 'import'
        Nginx = Join-Path (Join-Path $homePath 'runtime') 'coursekit.conf'
        EncryptionKey = Join-Path (Join-Path $homePath 'runtime') 'n8n_encryption_key'
        RunnerToken = Join-Path (Join-Path $homePath 'runtime') 'runner_auth_token'
        Workflow = Join-Path (Join-Path (Join-Path $homePath 'runtime') 'import') 'workflow.json'
        Credential = Join-Path (Join-Path (Join-Path $homePath 'runtime') 'import') 'credentials.json'
    }
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $type = [System.Security.AccessControl.AccessControlType]::Allow
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $rights, $inheritance, $propagation, $type)
        $security.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $security
    } catch {
        throw "Не вдалося обмежити доступ до локальних секретів: $($_.Exception.Message)"
    }
}

function Get-CourseFileHash {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Protect-CourseText {
    param([Parameter(Mandatory)][string]$Text)
    Add-Type -AssemblyName System.Security
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Text)
    try {
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $plain, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protected)
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
}

function Unprotect-CourseText {
    param([Parameter(Mandatory)][string]$ProtectedText)
    Add-Type -AssemblyName System.Security
    $protected = [Convert]::FromBase64String($ProtectedText)
    $plain = $null
    try {
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } finally {
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        [Array]::Clear($protected, 0, $protected.Length)
    }
}

function New-CourseToken {
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-TelegramTokenFormat {
    param([Parameter(Mandatory)][string]$Token)
    return $Token -match '^\d{6,12}:[A-Za-z0-9_-]{30,}$'
}

function Save-CourseKitSettings {
    [CmdletBinding()]
    param(
        [string]$TelegramToken,
        [Parameter(Mandatory)][string]$AllowedUserId,
        [ValidateRange(1024, 65535)][int]$N8nPort = 5678
    )
    if ($AllowedUserId -notmatch '^[1-9]\d{0,19}$') {
        throw 'Telegram user ID має складатися з 1–20 цифр і бути додатним.'
    }

    $paths = Get-CourseKitPaths
    [System.IO.Directory]::CreateDirectory($paths.Home) | Out-Null
    Set-PrivateDirectoryAcl -Path $paths.Home

    $existing = $null
    if (Test-Path -LiteralPath $paths.Secrets) {
        $existing = Get-Content -LiteralPath $paths.Secrets -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ([string]::IsNullOrWhiteSpace($TelegramToken)) {
        if (-not $existing) { throw 'Введіть токен Telegram-бота для першого налаштування.' }
        $protectedTelegramToken = $existing.telegramToken
    } else {
        if (-not (Test-TelegramTokenFormat -Token $TelegramToken)) {
            throw 'Формат токена Telegram не схожий на токен від BotFather.'
        }
        $protectedTelegramToken = Protect-CourseText -Text $TelegramToken
    }

    $encryptionKey = if ($existing) { $existing.encryptionKey } else { Protect-CourseText -Text (New-CourseToken -Bytes 48) }
    $webhookSecret = if ($existing) { $existing.webhookSecret } else { Protect-CourseText -Text (New-CourseToken -Bytes 32) }
    $runnerAuthToken = if ($existing -and $existing.PSObject.Properties['runnerAuthToken']) { $existing.runnerAuthToken } else { Protect-CourseText -Text (New-CourseToken -Bytes 32) }

    $settings = [ordered]@{
        schemaVersion = 1
        allowedUserIds = @([string]$AllowedUserId)
        n8nPort = $N8nPort
        tunnelProvider = 'cloudflared'
    }
    $secrets = [ordered]@{
        schemaVersion = 1
        telegramToken = $protectedTelegramToken
        encryptionKey = $encryptionKey
        webhookSecret = $webhookSecret
        runnerAuthToken = $runnerAuthToken
    }
    Write-Utf8File -Path $paths.Settings -Content ($settings | ConvertTo-Json -Depth 5)
    Write-Utf8File -Path $paths.Secrets -Content ($secrets | ConvertTo-Json -Depth 5)
    return Get-CourseKitSettingsSummary
}

function Get-CourseKitSettingsSummary {
    $paths = Get-CourseKitPaths
    if (-not (Test-Path -LiteralPath $paths.Settings) -or -not (Test-Path -LiteralPath $paths.Secrets)) {
        return [pscustomobject]@{ Configured = $false; AllowedUserId = ''; N8nPort = 5678; TokenSaved = $false }
    }
    $settings = Get-Content -LiteralPath $paths.Settings -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{
        Configured = $true
        AllowedUserId = [string]$settings.allowedUserIds[0]
        N8nPort = [int]$settings.n8nPort
        TokenSaved = $true
    }
}

function Get-CourseKitConfiguration {
    $paths = Get-CourseKitPaths
    if (-not (Test-Path -LiteralPath $paths.Settings) -or -not (Test-Path -LiteralPath $paths.Secrets)) {
        throw 'Спочатку збережіть токен бота та Telegram user ID.'
    }
    $settings = Get-Content -LiteralPath $paths.Settings -Raw -Encoding UTF8 | ConvertFrom-Json
    $protected = Get-Content -LiteralPath $paths.Secrets -Raw -Encoding UTF8 | ConvertFrom-Json
    [pscustomobject]@{
        Settings = $settings
        TelegramToken = Unprotect-CourseText -ProtectedText $protected.telegramToken
        EncryptionKey = Unprotect-CourseText -ProtectedText $protected.encryptionKey
        WebhookSecret = Unprotect-CourseText -ProtectedText $protected.webhookSecret
        RunnerAuthToken = Unprotect-CourseText -ProtectedText $protected.runnerAuthToken
        Paths = $paths
    }
}

function Write-CourseLog {
    param([Parameter(Mandatory)][string]$Message)
    Write-Output ([pscustomobject]@{ Kind = 'Log'; Message = $Message })
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-CourseProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 360
    )
    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' '
    $process = New-Object System.Diagnostics.Process
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $argumentLine
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardOutputEncoding = $utf8
        $startInfo.StandardErrorEncoding = $utf8
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Не вдалося запустити $FilePath."
        }
        # Read both streams concurrently so a verbose Docker command cannot
        # fill one pipe and deadlock while the other pipe is being read.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            $process.WaitForExit()
            $timeoutStdOut = $stdoutTask.GetAwaiter().GetResult()
            $timeoutStdErr = $stderrTask.GetAwaiter().GetResult()
            $timeoutDetail = ($timeoutStdErr + "`n" + $timeoutStdOut).Trim()
            if ($timeoutDetail.Length -gt 1200) {
                $timeoutDetail = $timeoutDetail.Substring($timeoutDetail.Length - 1200)
            }
            $timeoutMessage = "$FilePath не завершився за $TimeoutSeconds секунд."
            if ($timeoutDetail) { $timeoutMessage += " Останній вивід: $timeoutDetail" }
            throw $timeoutMessage
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = [int]$process.ExitCode
        if ($exitCode -ne 0) {
            $detail = ($stderr + "`n" + $stdout).Trim()
            if ($detail.Length -gt 1200) { $detail = $detail.Substring($detail.Length - 1200) }
            throw "$FilePath завершився з кодом ${exitCode}: $detail"
        }
        return [pscustomobject]@{ StdOut = $stdout; StdErr = $stderr; ExitCode = $exitCode }
    } finally {
        $process.Dispose()
    }
}

function Set-CourseComposeEnvironment {
    param([Parameter(Mandatory)]$Configuration, [string]$WebhookUrl)
    $env:COURSEKIT_N8N_PORT = [string]$Configuration.Settings.n8nPort
    $env:COURSEKIT_NGINX_CONFIG = $Configuration.Paths.Nginx
    $env:COURSEKIT_ENCRYPTION_KEY_FILE = $Configuration.Paths.EncryptionKey
    $env:COURSEKIT_RUNNER_TOKEN_FILE = $Configuration.Paths.RunnerToken
    $env:COURSEKIT_IMPORT_DIR = $Configuration.Paths.Import
    $env:COURSEKIT_WEBHOOK_URL = if ($WebhookUrl) { $WebhookUrl.TrimEnd('/') + '/' } else { "http://127.0.0.1:$($Configuration.Settings.n8nPort)/" }
}

function Invoke-CourseCompose {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 360)
    $dockerArguments = @('compose', '--project-name', $script:ProjectName, '-f', $script:ComposeFile) + $Arguments
    return Invoke-CourseProcess -FilePath 'docker.exe' -Arguments $dockerArguments -TimeoutSeconds $TimeoutSeconds
}

function Test-CourseDockerVolume {
    param([Parameter(Mandatory)][string]$Name)
    try {
        Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'inspect', $Name) -TimeoutSeconds 30 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-CourseVolumeArchive {
    param(
        [Parameter(Mandatory)][string]$Volume,
        [Parameter(Mandatory)][string]$Directory
    )
    Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @(
        'run', '--rm', '--user', '0:0', '--entrypoint', '/bin/sh',
        '-v', "${Volume}:/source:ro", '-v', "${Directory}:/backup",
        $script:N8nImage, '-c', 'cd /source && tar -czf /backup/n8n-data.tar.gz .'
    ) -TimeoutSeconds 420 | Out-Null
}

function Expand-CourseVolumeArchive {
    param(
        [Parameter(Mandatory)][string]$Volume,
        [Parameter(Mandatory)][string]$Directory
    )
    Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @(
        'run', '--rm', '--user', '0:0', '--entrypoint', '/bin/sh',
        '-v', "${Volume}:/target", '-v', "${Directory}:/backup:ro",
        $script:N8nImage, '-c', 'cd /target && tar -xzf /backup/n8n-data.tar.gz'
    ) -TimeoutSeconds 420 | Out-Null
}

function Copy-CourseDockerVolume {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @(
        'run', '--rm', '--user', '0:0', '--entrypoint', '/bin/sh',
        '-v', "${Source}:/source:ro", '-v', "${Target}:/target",
        $script:N8nImage, '-c', 'cd /source && tar -cf - . | tar -xf - -C /target'
    ) -TimeoutSeconds 420 | Out-Null
}

function Test-CourseVolumeDatabase {
    param([Parameter(Mandatory)][string]$Volume)
    Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @(
        'run', '--rm', '--user', '0:0', '--entrypoint', '/bin/sh', '-v', "${Volume}:/data:ro",
        $script:N8nImage, '-c', 'test -s /data/database.sqlite'
    ) -TimeoutSeconds 120 | Out-Null
}

function Get-CourseProjectContainerIds {
    param([switch]$RunningOnly)
    $arguments = if ($RunningOnly) { @('ps', '-q') } else { @('ps', '-aq') }
    $arguments += @('--filter', "label=com.docker.compose.project=$script:ProjectName")
    $result = Invoke-CourseProcess -FilePath 'docker.exe' -Arguments $arguments -TimeoutSeconds 30
    return @($result.StdOut -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
}

function New-CourseRuntimeFiles {
    param([Parameter(Mandatory)]$Configuration)
    $paths = $Configuration.Paths
    [System.IO.Directory]::CreateDirectory($paths.Runtime) | Out-Null
    [System.IO.Directory]::CreateDirectory($paths.Import) | Out-Null
    Set-PrivateDirectoryAcl -Path $paths.Runtime

    $nginxTemplate = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'config/nginx/coursekit.conf.template') -Raw -Encoding UTF8
    if ($Configuration.WebhookSecret -notmatch '^[A-Za-z0-9_-]{1,256}$') {
        throw 'Локальний webhook secret має неочікуваний формат.'
    }
    Write-Utf8File -Path $paths.Nginx -Content $nginxTemplate.Replace('__WEBHOOK_SECRET__', $Configuration.WebhookSecret)
    Write-Utf8File -Path $paths.EncryptionKey -Content $Configuration.EncryptionKey
    Write-Utf8File -Path $paths.RunnerToken -Content $Configuration.RunnerAuthToken

    $guard = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'workflow/guard.js') -Raw -Encoding UTF8
    $allowedJson = ConvertTo-Json -InputObject @($Configuration.Settings.allowedUserIds | ForEach-Object { [string]$_ }) -Compress
    $guard = $guard.Replace('__ALLOWED_USER_IDS_JSON__', $allowedJson)
    $templatePath = Join-Path $script:ProjectRoot 'workflow/telegram-echo.template.json'
    $workflows = @(Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    $guardNode = $workflows[0].nodes | Where-Object { $_.name -eq 'Validate and deduplicate' }
    if (-not $guardNode) { throw 'Workflow template does not contain the guard node.' }
    $guardNode.parameters.jsCode = $guard
    Write-Utf8File -Path $paths.Workflow -Content (ConvertTo-Json -InputObject $workflows -Depth 100)

}

function Write-CourseCredentialFile {
    param([Parameter(Mandatory)]$Configuration)
    $credential = [ordered]@{
        id = 'telegram-course-bot'
        name = 'Telegram Course Bot'
        type = 'telegramApi'
        data = [ordered]@{ accessToken = $Configuration.TelegramToken }
    }
    Write-Utf8File -Path $Configuration.Paths.Credential -Content (ConvertTo-Json -InputObject @($credential) -Depth 10)
}

function Wait-CourseHttp {
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSeconds = 240)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 4
            if ($response.StatusCode -eq 200) { return }
        } catch { Start-Sleep -Milliseconds 700 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Сервіс не став готовим за $TimeoutSeconds секунд: $Url"
}

function Wait-CourseWebhookRegistered {
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 240)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $probe = @{
        update_id = 2147483000
        message = @{ chat = @{ id = 0; type = 'private' }; from = @{ id = 0 }; text = 'readiness-probe' }
    } | ConvertTo-Json -Depth 5
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post `
                -Uri "http://127.0.0.1:$Port$script:WebhookPath" `
                -ContentType 'application/json' -Body $probe -TimeoutSec 5
            if ($response.StatusCode -eq 200) { return }
        } catch { Start-Sleep -Milliseconds 700 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'n8n запущений, але production webhook не зареєструвався вчасно.'
}

function Wait-CourseTaskRunner {
    param([int]$TimeoutSeconds = 180)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $logs = Invoke-CourseCompose -Arguments @('logs', '--no-color', '--tail', '200', 'n8n') -TimeoutSeconds 30
        if (($logs.StdOut + "`n" + $logs.StdErr) -match 'Registered runner') { return }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Зовнішній task runner не підключився до n8n вчасно.'
}

function Test-CourseTcpPortAvailable {
    param([Parameter(Mandatory)][int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        try { $listener.Stop() } catch { }
    }
}

function Invoke-CourseTelegram {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Body = @{}
    )
    $uri = "$script:TelegramApiBase/bot$Token/$Method"
    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 20
        if (-not $response.ok) { throw "Telegram API returned ok=false for $Method." }
        return $response.result
    } catch {
        $safeMessage = $_.Exception.Message.Replace($Token, '***')
        throw "Telegram API ($Method): $safeMessage"
    }
}

function Find-CourseTelegramUserId {
    [CmdletBinding()]
    param([string]$TelegramToken)
    if ([string]::IsNullOrWhiteSpace($TelegramToken)) {
        $TelegramToken = (Get-CourseKitConfiguration).TelegramToken
    }
    if (-not (Test-TelegramTokenFormat -Token $TelegramToken)) {
        throw 'Спочатку введіть правильний токен бота.'
    }
    $hook = Invoke-CourseTelegram -Token $TelegramToken -Method 'getWebhookInfo'
    if ($hook.url) {
        throw 'У бота вже активний webhook. User ID не шукається через getUpdates, щоб не змінювати наявну доставку.'
    }
    $updates = @(Invoke-CourseTelegram -Token $TelegramToken -Method 'getUpdates' -Body @{
        timeout = '0'
        limit = '100'
        allowed_updates = '["message"]'
    })
    $candidate = $updates | Where-Object { $_.message.chat.type -eq 'private' -and $_.message.from.id } | Select-Object -Last 1
    if (-not $candidate) {
        throw 'Спочатку надішліть цьому боту будь-яке приватне повідомлення, а потім натисніть кнопку ще раз.'
    }
    return [string]$candidate.message.from.id
}

function Get-CourseOwnerSetupRequired {
    param([Parameter(Mandatory)][int]$Port)
    $settings = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$Port/rest/settings" -TimeoutSec 10
    return [bool]$settings.data.userManagement.showSetupOnFirstLoad
}

function Get-CourseTunnelUrl {
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $result = Invoke-CourseCompose -Arguments @('logs', '--no-color', '--tail', '200', 'cloudflared') -TimeoutSeconds 30
        $matches = [regex]::Matches($result.StdOut + "`n" + $result.StdErr, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($matches.Count -gt 0) { return $matches[$matches.Count - 1].Value }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'cloudflared не надав публічну HTTPS-адресу за 120 секунд.'
}

function Save-CourseState {
    param([string]$PublicUrl, [string]$Status)
    $paths = Get-CourseKitPaths
    $state = [ordered]@{ schemaVersion = 1; publicUrl = $PublicUrl; status = $Status; updatedAt = [DateTime]::UtcNow.ToString('o') }
    Write-Utf8File -Path $paths.State -Content ($state | ConvertTo-Json)
}

function Get-CourseState {
    $paths = Get-CourseKitPaths
    if (-not (Test-Path -LiteralPath $paths.State)) { return $null }
    return Get-Content -LiteralPath $paths.State -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Backup-CourseKit {
    [CmdletBinding()]
    param([string]$DestinationDirectory)

    $configuration = Get-CourseKitConfiguration
    if (-not (Test-CourseDockerVolume -Name $script:DataVolume)) {
        throw 'Сховище n8n ще не створене. Спочатку виконайте перший запуск.'
    }
    $docker = Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('version', '--format', '{{.Server.Version}}') -TimeoutSeconds 30
    if ([string]::IsNullOrWhiteSpace($docker.StdOut)) { throw 'Docker Engine не відповів. Відкрийте Docker Desktop.' }
    $composeVersion = Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('compose', 'version', '--short') -TimeoutSeconds 30
    Write-CourseLog ("Docker Engine {0}; Compose {1}." -f $docker.StdOut.Trim(), $composeVersion.StdOut.Trim())

    if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if ([string]::IsNullOrWhiteSpace($documents)) { $documents = $configuration.Paths.Home }
        $DestinationDirectory = Join-Path $documents 'N8nCourseKitBackups'
    }
    [System.IO.Directory]::CreateDirectory($DestinationDirectory) | Out-Null
    Set-PrivateDirectoryAcl -Path $DestinationDirectory

    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("n8n-course-kit-backup-{0}" -f [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
    Set-PrivateDirectoryAcl -Path $temporary
    $runningN8n = @(Get-CourseProjectContainerIds -RunningOnly | Select-Object -First 1)
    try {
        if ($runningN8n.Count -gt 0) {
            Invoke-CourseProcess -FilePath 'docker.exe' -Arguments (@('stop', '--time', '30') + $runningN8n) -TimeoutSeconds 60 | Out-Null
        }
        Invoke-CourseVolumeArchive -Volume $script:DataVolume -Directory $temporary

        Copy-Item -LiteralPath $configuration.Paths.Settings -Destination (Join-Path $temporary 'settings.json')
        Copy-Item -LiteralPath $configuration.Paths.Secrets -Destination (Join-Path $temporary 'secrets.dpapi.json')
        if (Test-Path -LiteralPath $configuration.Paths.State) {
            Copy-Item -LiteralPath $configuration.Paths.State -Destination (Join-Path $temporary 'state.json')
        }
        $files = @('n8n-data.tar.gz', 'settings.json', 'secrets.dpapi.json')
        if (Test-Path -LiteralPath (Join-Path $temporary 'state.json')) { $files += 'state.json' }
        $hashes = [ordered]@{}
        foreach ($file in $files) { $hashes[$file] = Get-CourseFileHash -Path (Join-Path $temporary $file) }
        $manifest = [ordered]@{
            schemaVersion = 1
            createdAt = [DateTime]::UtcNow.ToString('o')
            dataVolume = $script:DataVolume
            protection = 'Windows DPAPI CurrentUser'
            portableToAnotherWindowsUser = $false
            containsPersonalData = $true
            sha256 = $hashes
        }
        Write-Utf8File -Path (Join-Path $temporary 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 5)

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archiveName = 'n8n-course-kit-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        $archivePath = Join-Path $DestinationDirectory $archiveName
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $temporary, $archivePath, [System.IO.Compression.CompressionLevel]::Optimal, $false
        )
        return [pscustomobject]@{ Kind = 'Result'; State = 'BackedUp'; BackupPath = $archivePath }
    } finally {
        if ($runningN8n.Count -gt 0) {
            Invoke-CourseProcess -FilePath 'docker.exe' -Arguments (@('start') + $runningN8n) -TimeoutSeconds 60 | Out-Null
            Wait-CourseHttp -Url ("http://127.0.0.1:{0}/healthz/readiness" -f $configuration.Settings.n8nPort) -TimeoutSeconds 300
        }
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-CourseKitBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [switch]$ConfirmRestore
    )
    if (-not $ConfirmRestore) { throw 'Відновлення потребує явного підтвердження.' }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw 'Файл резервної копії не знайдено.' }

    $paths = Get-CourseKitPaths
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("n8n-course-kit-restore-{0}" -f [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
    Set-PrivateDirectoryAcl -Path $temporary
    $stageVolume = 'coursekit-restore-stage-{0}' -f [Guid]::NewGuid().ToString('N')
    $rollbackVolume = 'coursekit-restore-rollback-{0}' -f [Guid]::NewGuid().ToString('N')
    $stageCreated = $false
    $rollbackCreated = $false
    $targetReplaced = $false
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $allowedEntries = @('manifest.json', 'n8n-data.tar.gz', 'settings.json', 'secrets.dpapi.json', 'state.json')
        $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $BackupPath).Path)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -notin $allowedEntries) { throw "Резервна копія містить неочікуваний файл: $($entry.FullName)" }
                if ([string]::IsNullOrWhiteSpace($entry.Name)) { throw 'Резервна копія містить неочікувану папку.' }
                $destination = Join-Path $temporary $entry.Name
                $inputStream = $entry.Open()
                $outputStream = [System.IO.File]::Create($destination)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
            }
        } finally {
            $archive.Dispose()
        }
        foreach ($required in @('manifest.json', 'n8n-data.tar.gz', 'settings.json', 'secrets.dpapi.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $temporary $required))) { throw "У резервній копії немає $required." }
        }
        $manifest = Get-Content -LiteralPath (Join-Path $temporary 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1) { throw 'Версія резервної копії не підтримується.' }
        foreach ($requiredHash in @('n8n-data.tar.gz', 'settings.json', 'secrets.dpapi.json')) {
            if (-not $manifest.sha256.PSObject.Properties[$requiredHash]) {
                throw "У manifest немає контрольної суми для $requiredHash."
            }
        }
        foreach ($property in $manifest.sha256.PSObject.Properties) {
            $actual = Get-CourseFileHash -Path (Join-Path $temporary $property.Name)
            if ($actual -ne [string]$property.Value) { throw "Контрольна сума не збігається для $($property.Name)." }
        }

        $protected = Get-Content -LiteralPath (Join-Path $temporary 'secrets.dpapi.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Unprotect-CourseText -ProtectedText $protected.telegramToken | Out-Null
        Unprotect-CourseText -ProtectedText $protected.encryptionKey | Out-Null
        Unprotect-CourseText -ProtectedText $protected.webhookSecret | Out-Null
        Unprotect-CourseText -ProtectedText $protected.runnerAuthToken | Out-Null

        $safetyBackup = $null
        if ((Test-Path -LiteralPath $paths.Settings) -and (Test-Path -LiteralPath $paths.Secrets) -and (Test-CourseDockerVolume -Name $script:DataVolume)) {
            $safetyBackup = Backup-CourseKit
        }

        Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'create', $stageVolume) -TimeoutSeconds 30 | Out-Null
        $stageCreated = $true
        Expand-CourseVolumeArchive -Volume $stageVolume -Directory $temporary
        Test-CourseVolumeDatabase -Volume $stageVolume

        $running = Get-CourseProjectContainerIds -RunningOnly
        if ($running.Count -gt 0) {
            Invoke-CourseProcess -FilePath 'docker.exe' -Arguments (@('stop', '--time', '30') + $running) -TimeoutSeconds 90 | Out-Null
        }
        $allContainers = Get-CourseProjectContainerIds
        if ($allContainers.Count -gt 0) {
            Invoke-CourseProcess -FilePath 'docker.exe' -Arguments (@('rm', '-f') + $allContainers) -TimeoutSeconds 90 | Out-Null
        }

        if (Test-CourseDockerVolume -Name $script:DataVolume) {
            Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'create', $rollbackVolume) -TimeoutSeconds 30 | Out-Null
            $rollbackCreated = $true
            Copy-CourseDockerVolume -Source $script:DataVolume -Target $rollbackVolume
            Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'rm', $script:DataVolume) -TimeoutSeconds 30 | Out-Null
        }
        Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'create', $script:DataVolume) -TimeoutSeconds 30 | Out-Null
        $targetReplaced = $true
        Copy-CourseDockerVolume -Source $stageVolume -Target $script:DataVolume
        Test-CourseVolumeDatabase -Volume $script:DataVolume

        [System.IO.Directory]::CreateDirectory($paths.Home) | Out-Null
        Set-PrivateDirectoryAcl -Path $paths.Home
        Copy-Item -LiteralPath (Join-Path $temporary 'settings.json') -Destination $paths.Settings -Force
        Copy-Item -LiteralPath (Join-Path $temporary 'secrets.dpapi.json') -Destination $paths.Secrets -Force
        if (Test-Path -LiteralPath (Join-Path $temporary 'state.json')) {
            Copy-Item -LiteralPath (Join-Path $temporary 'state.json') -Destination $paths.State -Force
        } else {
            Save-CourseState -PublicUrl '' -Status 'Stopped'
        }
        Remove-Item -LiteralPath $paths.Runtime -Recurse -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Kind = 'Result'; State = 'Restored'; BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
            SafetyBackupPath = if ($safetyBackup) { $safetyBackup.BackupPath } else { '' }
        }
    } catch {
        if ($targetReplaced -and $rollbackCreated) {
            try {
                if (Test-CourseDockerVolume -Name $script:DataVolume) {
                    Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'rm', $script:DataVolume) -TimeoutSeconds 30 | Out-Null
                }
                Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'create', $script:DataVolume) -TimeoutSeconds 30 | Out-Null
                Copy-CourseDockerVolume -Source $rollbackVolume -Target $script:DataVolume
            } catch { }
        }
        throw
    } finally {
        if ($stageCreated) {
            try { Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'rm', '-f', $stageVolume) -TimeoutSeconds 30 | Out-Null } catch { }
        }
        if ($rollbackCreated) {
            try { Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('volume', 'rm', '-f', $rollbackVolume) -TimeoutSeconds 30 | Out-Null } catch { }
        }
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-CourseKit {
    [CmdletBinding()]
    param()
    $configuration = Get-CourseKitConfiguration
    $stateBeforeStart = Get-CourseState
    try {
    Write-CourseLog 'Перевіряю Docker Engine…'
    $docker = Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('version', '--format', '{{.Server.Version}}') -TimeoutSeconds 30
    if ([string]::IsNullOrWhiteSpace($docker.StdOut)) { throw 'Docker Engine не відповів. Відкрийте Docker Desktop.' }
    $platform = Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('info', '--format', '{{.OSType}}/{{.Architecture}}') -TimeoutSeconds 30
    if ($platform.StdOut.Trim() -notin @('linux/x86_64', 'linux/amd64')) {
        throw "Потрібен Docker Desktop у режимі Linux/amd64. Зараз: $($platform.StdOut.Trim())."
    }
    $ownN8n = @(Get-CourseProjectContainerIds -RunningOnly | Select-Object -First 1)
    if ($ownN8n.Count -eq 0 -and -not (Test-CourseTcpPortAvailable -Port ([int]$configuration.Settings.n8nPort))) {
        throw "Локальний порт $($configuration.Settings.n8nPort) зайнятий іншою програмою. Звільніть його й повторіть запуск."
    }

    Write-CourseLog 'Перевіряю токен Telegram локальним запитом до Bot API…'
    $bot = Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'getMe'
    Write-CourseLog ("Telegram-бот доступний: @{0}" -f $bot.username)

    New-CourseRuntimeFiles -Configuration $configuration
    Set-CourseComposeEnvironment -Configuration $configuration
    Write-CourseLog 'Запускаю локальний n8n і захисний proxy… Перший запуск завантажує великі Docker-образи й може тривати до 30 хвилин.'
    Invoke-CourseCompose -Arguments @('up', '-d', 'n8n', 'task-runners', 'proxy') -TimeoutSeconds 1800 | Out-Null
    $localUrl = "http://127.0.0.1:$($configuration.Settings.n8nPort)"
    Wait-CourseHttp -Url "$localUrl/healthz/readiness" -TimeoutSeconds 300

    if (Get-CourseOwnerSetupRequired -Port ([int]$configuration.Settings.n8nPort)) {
        Save-CourseState -PublicUrl '' -Status 'NeedsOwnerSetup'
        Write-CourseLog 'Потрібно один раз створити локального власника n8n у браузері.'
        return [pscustomobject]@{ Kind = 'Result'; State = 'NeedsOwnerSetup'; LocalUrl = "$localUrl/"; PublicUrl = '' }
    }

    Write-CourseLog 'Оновлюю credential і перевіряю навчальний workflow офіційним CLI n8n…'
    Invoke-CourseCompose -Arguments @('stop', 'n8n') -TimeoutSeconds 120 | Out-Null
    $workflowAlreadyExists = $false
    $workflowIsPublished = $false
    $workflowExport = Join-Path $configuration.Paths.Import 'existing-workflows.json'
    try {
        Invoke-CourseCompose -Arguments @('run', '--rm', '--no-deps', 'n8n', 'export:workflow', '--all', '--output=/coursekit/import/existing-workflows.json') -TimeoutSeconds 420 | Out-Null
        if (Test-Path -LiteralPath $workflowExport) {
            $existingWorkflows = @(Get-Content -LiteralPath $workflowExport -Raw -Encoding UTF8 | ConvertFrom-Json)
            $existingWorkflow = @($existingWorkflows | Where-Object { $_.id -eq 'telegramCourseMvp' } | Select-Object -First 1)
            $workflowAlreadyExists = $existingWorkflow.Count -gt 0
            if ($workflowAlreadyExists) {
                $workflowIsPublished = [bool]$existingWorkflow[0].active
                $webhookNode = @($existingWorkflow[0].nodes | Where-Object {
                    $_.type -eq 'n8n-nodes-base.webhook' -and $_.parameters.path -eq 'telegram-course'
                })
                if ($webhookNode.Count -ne 1) {
                    throw 'Навчальний workflow змінено так, що пакет не знаходить webhook telegram-course. Поверніть цей шлях у n8n або видаліть workflow для повторного створення.'
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $workflowExport -Force -ErrorAction SilentlyContinue
    }
    try {
        Write-CourseCredentialFile -Configuration $configuration
        Invoke-CourseCompose -Arguments @('run', '--rm', '--no-deps', 'n8n', 'import:credentials', '--input=/coursekit/import/credentials.json') -TimeoutSeconds 420 | Out-Null
    } finally {
        Remove-Item -LiteralPath $configuration.Paths.Credential -Force -ErrorAction SilentlyContinue
    }
    if ($workflowAlreadyExists) {
        Write-CourseLog 'Наявний workflow збережено без перезапису студентських змін.'
    } else {
        Invoke-CourseCompose -Arguments @('run', '--rm', '--no-deps', 'n8n', 'import:workflow', '--input=/coursekit/import/workflow.json') -TimeoutSeconds 420 | Out-Null
    }
    if (-not $workflowIsPublished) {
        Invoke-CourseCompose -Arguments @('run', '--rm', '--no-deps', 'n8n', 'publish:workflow', '--id=telegramCourseMvp') -TimeoutSeconds 420 | Out-Null
    }
    Invoke-CourseCompose -Arguments @('up', '-d', 'n8n', 'task-runners', 'proxy') -TimeoutSeconds 420 | Out-Null
    Wait-CourseHttp -Url "$localUrl/healthz/readiness" -TimeoutSeconds 300
    Wait-CourseWebhookRegistered -Port ([int]$configuration.Settings.n8nPort) -TimeoutSeconds 300

    Write-CourseLog 'Запускаю Cloudflare Quick Tunnel…'
    Invoke-CourseCompose -Arguments @('up', '-d', 'cloudflared') -TimeoutSeconds 180 | Out-Null
    $publicUrl = Get-CourseTunnelUrl
    Write-CourseLog ("Отримано публічну адресу: {0}" -f $publicUrl)

    Set-CourseComposeEnvironment -Configuration $configuration -WebhookUrl $publicUrl
    Invoke-CourseCompose -Arguments @('up', '-d', '--force-recreate', 'n8n') -TimeoutSeconds 420 | Out-Null
    Wait-CourseHttp -Url "$localUrl/healthz/readiness" -TimeoutSeconds 300
    Wait-CourseTaskRunner -TimeoutSeconds 180
    Wait-CourseWebhookRegistered -Port ([int]$configuration.Settings.n8nPort) -TimeoutSeconds 300

    $webhookUrl = $publicUrl.TrimEnd('/') + $script:WebhookPath
    Write-CourseLog 'Реєструю та перевіряю Telegram webhook…'
    $existing = Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'getWebhookInfo'
    $previousState = $stateBeforeStart
    $previousWebhookUrl = if ($previousState -and $previousState.publicUrl) {
        ([string]$previousState.publicUrl).TrimEnd('/') + $script:WebhookPath
    } else { '' }
    if ($existing.url -and $existing.url -ne $webhookUrl -and $existing.url -ne $previousWebhookUrl) {
        throw "Цей бот уже має інший webhook: $($existing.url). Видаліть його свідомо або використайте окремого навчального бота."
    }
    if ($existing.url -eq $previousWebhookUrl -and $existing.url -ne $webhookUrl) {
        Write-CourseLog 'Замінюю попередню адресу tunnel, яка належала цьому пакету.'
    }
    Save-CourseState -PublicUrl $publicUrl -Status 'Starting'
    Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'setWebhook' -Body @{
        url = $webhookUrl
        secret_token = $configuration.WebhookSecret
        allowed_updates = '["message"]'
        drop_pending_updates = 'false'
    } | Out-Null
    $verified = Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'getWebhookInfo'
    if ($verified.url -ne $webhookUrl) { throw 'Telegram не підтвердив очікувану адресу webhook.' }

    Save-CourseState -PublicUrl $publicUrl -Status 'Ready'
    Write-CourseLog 'Система готова. Надішліть боту текстове повідомлення.'
    return [pscustomobject]@{ Kind = 'Result'; State = 'Ready'; LocalUrl = "$localUrl/"; PublicUrl = $publicUrl }
    } catch {
        try {
            $containers = Get-CourseProjectContainerIds
            if ($containers.Count -gt 0) {
                Invoke-CourseProcess -FilePath 'docker.exe' -Arguments (@('rm', '-f') + $containers) -TimeoutSeconds 90 | Out-Null
            }
        } catch { }
        Remove-Item -LiteralPath $configuration.Paths.Runtime -Recurse -Force -ErrorAction SilentlyContinue
        try { Save-CourseState -PublicUrl ([string](Get-CourseState).publicUrl) -Status 'Error' } catch { }
        throw
    }
}

function Stop-CourseKit {
    [CmdletBinding()]
    param()
    $configuration = Get-CourseKitConfiguration
    Set-CourseComposeEnvironment -Configuration $configuration
    $state = Get-CourseState
    if ($state -and $state.publicUrl) {
        Write-CourseLog 'Перевіряю належність Telegram webhook перед видаленням…'
        try {
            $expected = ([string]$state.publicUrl).TrimEnd('/') + $script:WebhookPath
            $current = Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'getWebhookInfo'
            if ($current.url -eq $expected) {
                Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'deleteWebhook' -Body @{ drop_pending_updates = 'false' } | Out-Null
                Write-CourseLog 'Webhook цього пакета видалено без очищення черги подій.'
            } elseif ($current.url) {
                Write-CourseLog 'Telegram має інший webhook; пакет його не змінює.'
            }
        } catch {
            Write-CourseLog 'Telegram зараз недоступний. Локальні компоненти все одно буде зупинено; старий webhook заміниться під час наступного запуску.'
        }
    }
    Write-CourseLog 'Зупиняю лише контейнери навчального пакета…'
    Invoke-CourseCompose -Arguments @('down', '--remove-orphans') -TimeoutSeconds 180 | Out-Null
    if (Test-Path -LiteralPath $configuration.Paths.Runtime) {
        Remove-Item -LiteralPath $configuration.Paths.Runtime -Recurse -Force
    }
    Save-CourseState -PublicUrl '' -Status 'Stopped'
    Write-CourseLog 'Систему зупинено. Дані n8n у Docker volume збережені.'
    return [pscustomobject]@{ Kind = 'Result'; State = 'Stopped'; LocalUrl = ''; PublicUrl = '' }
}

function Test-CourseKit {
    [CmdletBinding()]
    param()
    $configuration = Get-CourseKitConfiguration
    Set-CourseComposeEnvironment -Configuration $configuration
    $docker = Invoke-CourseProcess -FilePath 'docker.exe' -Arguments @('version', '--format', '{{.Server.Version}}') -TimeoutSeconds 30
    Write-CourseLog ("Docker Engine: {0}" -f $docker.StdOut.Trim())
    $localUrl = "http://127.0.0.1:$($configuration.Settings.n8nPort)"
    Wait-CourseHttp -Url "$localUrl/healthz/readiness" -TimeoutSeconds 15
    Write-CourseLog 'n8n: готовий і база мігрована.'
    foreach ($service in @('task-runners', 'proxy', 'cloudflared')) {
        $running = Invoke-CourseCompose -Arguments @('ps', '--status', 'running', '-q', $service) -TimeoutSeconds 30
        if ([string]::IsNullOrWhiteSpace($running.StdOut)) {
            throw "Компонент $service не працює. Натисніть «Запустити» для відновлення."
        }
        Write-CourseLog ("{0}: контейнер працює." -f $service)
    }
    $state = Get-CourseState
    $hook = Invoke-CourseTelegram -Token $configuration.TelegramToken -Method 'getWebhookInfo'
    if (-not $state -or $state.status -ne 'Ready' -or -not $hook.url) {
        throw 'Локальний n8n працює, але Telegram webhook ще не готовий.'
    }
    $expected = ([string]$state.publicUrl).TrimEnd('/') + $script:WebhookPath
    if ($hook.url -ne $expected) { throw 'Telegram webhook не збігається зі станом пакета.' }
    if ($hook.last_error_message) { throw "Telegram повідомляє помилку доставки: $($hook.last_error_message)" }
    Write-CourseLog 'Telegram webhook: адреса підтверджена, активної помилки немає.'
    return [pscustomobject]@{ Kind = 'Result'; State = 'Ready'; LocalUrl = "$localUrl/"; PublicUrl = [string]$state.publicUrl }
}

Export-ModuleMember -Function Save-CourseKitSettings, Get-CourseKitSettingsSummary, Find-CourseTelegramUserId, Start-CourseKit, Stop-CourseKit, Test-CourseKit, Backup-CourseKit, Restore-CourseKitBackup
