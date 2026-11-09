[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $projectRoot 'scripts\CourseKit.psm1'
Import-Module $modulePath -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'n8n Course Kit'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(760, 610)
$form.MinimumSize = New-Object System.Drawing.Size(700, 560)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Локальний n8n + Telegram'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 16)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Секрети зберігаються локально для вашого користувача Windows.'
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(22, 52)
$form.Controls.Add($subtitle)

$tokenLabel = New-Object System.Windows.Forms.Label
$tokenLabel.Text = 'Токен бота від BotFather'
$tokenLabel.AutoSize = $true
$tokenLabel.Location = New-Object System.Drawing.Point(22, 91)
$form.Controls.Add($tokenLabel)

$tokenBox = New-Object System.Windows.Forms.TextBox
$tokenBox.Location = New-Object System.Drawing.Point(25, 116)
$tokenBox.Size = New-Object System.Drawing.Size(485, 28)
$tokenBox.UseSystemPasswordChar = $true
$form.Controls.Add($tokenBox)

$userLabel = New-Object System.Windows.Forms.Label
$userLabel.Text = 'Ваш Telegram user ID'
$userLabel.AutoSize = $true
$userLabel.Location = New-Object System.Drawing.Point(22, 155)
$form.Controls.Add($userLabel)

$userBox = New-Object System.Windows.Forms.TextBox
$userBox.Location = New-Object System.Drawing.Point(25, 180)
$userBox.Size = New-Object System.Drawing.Size(250, 28)
$form.Controls.Add($userBox)

$findIdButton = New-Object System.Windows.Forms.Button
$findIdButton.Text = 'Знайти ID після повідомлення боту'
$findIdButton.Location = New-Object System.Drawing.Point(290, 178)
$findIdButton.Size = New-Object System.Drawing.Size(260, 32)
$form.Controls.Add($findIdButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Зберегти налаштування'
$saveButton.Location = New-Object System.Drawing.Point(530, 114)
$saveButton.Size = New-Object System.Drawing.Size(190, 34)
$form.Controls.Add($saveButton)

$savedLabel = New-Object System.Windows.Forms.Label
$savedLabel.AutoSize = $true
$savedLabel.ForeColor = [System.Drawing.Color]::ForestGreen
$savedLabel.Location = New-Object System.Drawing.Point(530, 160)
$form.Controls.Add($savedLabel)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = 'Запустити'
$startButton.Location = New-Object System.Drawing.Point(25, 228)
$startButton.Size = New-Object System.Drawing.Size(145, 40)
$form.Controls.Add($startButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = 'Зупинити'
$stopButton.Location = New-Object System.Drawing.Point(183, 228)
$stopButton.Size = New-Object System.Drawing.Size(145, 40)
$form.Controls.Add($stopButton)

$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = 'Відкрити n8n'
$openButton.Location = New-Object System.Drawing.Point(341, 228)
$openButton.Size = New-Object System.Drawing.Size(145, 40)
$form.Controls.Add($openButton)

$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = 'Перевірити'
$checkButton.Location = New-Object System.Drawing.Point(499, 228)
$checkButton.Size = New-Object System.Drawing.Size(145, 40)
$form.Controls.Add($checkButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Стан: очікування'
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(22, 290)
$form.Controls.Add($statusLabel)

$publicLabel = New-Object System.Windows.Forms.Label
$publicLabel.Text = 'Публічна адреса: —'
$publicLabel.AutoEllipsis = $true
$publicLabel.Location = New-Object System.Drawing.Point(22, 319)
$publicLabel.Size = New-Object System.Drawing.Size(690, 25)
$form.Controls.Add($publicLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(25, 353)
$logBox.Size = New-Object System.Drawing.Size(695, 185)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($logBox)

$script:currentJob = $null
$script:operationName = ''
$script:lastLocalUrl = ''

function Add-LogLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $logBox.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $Text))
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Set-ControlsBusy {
    param([bool]$Busy)
    $startButton.Enabled = -not $Busy
    $stopButton.Enabled = -not $Busy
    $checkButton.Enabled = -not $Busy
    $saveButton.Enabled = -not $Busy
    $openButton.Enabled = -not $Busy
    $tokenBox.Enabled = -not $Busy
    $userBox.Enabled = -not $Busy
    $findIdButton.Enabled = -not $Busy
}

function Refresh-SavedSettings {
    $summary = Get-CourseKitSettingsSummary
    if ($summary.Configured) {
        $userBox.Text = $summary.AllowedUserId
        $savedLabel.Text = 'Токен збережено'
        $script:lastLocalUrl = "http://127.0.0.1:$($summary.N8nPort)/"
    } else {
        $savedLabel.Text = 'Потрібне перше налаштування'
        $savedLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}

function Start-CourseOperation {
    param([Parameter(Mandatory)][string]$FunctionName, [Parameter(Mandatory)][string]$DisplayName)
    if ($script:currentJob) { return }
    Set-ControlsBusy -Busy $true
    $statusLabel.Text = "Стан: $DisplayName…"
    Add-LogLine "$DisplayName…"
    $script:operationName = $DisplayName
    $script:currentJob = Start-Job -ScriptBlock {
        param($ModulePath, $FunctionName)
        Import-Module $ModulePath -Force
        & $FunctionName
    } -ArgumentList $modulePath, $FunctionName
    $jobTimer.Start()
}

function Handle-JobOutput {
    param($Items)
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if ($item.Kind -eq 'Log') {
            Add-LogLine ([string]$item.Message)
        } elseif ($item.Kind -eq 'Result') {
            if ($item.LocalUrl) { $script:lastLocalUrl = [string]$item.LocalUrl }
            if ($item.PublicUrl) { $publicLabel.Text = "Публічна адреса: $($item.PublicUrl)" }
            switch ([string]$item.State) {
                'Ready' { $statusLabel.Text = 'Стан: готово'; $statusLabel.ForeColor = [System.Drawing.Color]::ForestGreen }
                'Stopped' { $statusLabel.Text = 'Стан: зупинено'; $statusLabel.ForeColor = [System.Drawing.Color]::DimGray; $publicLabel.Text = 'Публічна адреса: —' }
                'NeedsOwnerSetup' {
                    $statusLabel.Text = 'Стан: завершіть перше налаштування n8n'
                    $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
                    Add-LogLine 'У браузері створіть локального власника n8n, потім знову натисніть «Запустити».'
                    Start-Process $item.LocalUrl
                }
            }
        } else {
            Add-LogLine ([string]$item)
        }
    }
}

$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 400
$jobTimer.Add_Tick({
    if (-not $script:currentJob) { return }
    $newOutput = Receive-Job -Job $script:currentJob -ErrorAction SilentlyContinue
    Handle-JobOutput -Items $newOutput
    if ($script:currentJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $jobTimer.Stop()
        $remaining = Receive-Job -Job $script:currentJob -ErrorAction SilentlyContinue
        Handle-JobOutput -Items $remaining
        if ($script:currentJob.State -eq 'Failed') {
            $reason = $script:currentJob.ChildJobs[0].JobStateInfo.Reason
            $message = if ($reason) { $reason.Message } else { 'Невідома помилка операції.' }
            Add-LogLine "ПОМИЛКА: $message"
            $statusLabel.Text = 'Стан: помилка'
            $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        }
        Remove-Job -Job $script:currentJob -Force
        $script:currentJob = $null
        Set-ControlsBusy -Busy $false
    }
})

$saveButton.Add_Click({
    try {
        Save-CourseKitSettings -TelegramToken $tokenBox.Text.Trim() -AllowedUserId $userBox.Text.Trim() | Out-Null
        $tokenBox.Clear()
        $savedLabel.ForeColor = [System.Drawing.Color]::ForestGreen
        Refresh-SavedSettings
        Add-LogLine 'Локальні налаштування збережено через Windows DPAPI.'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Не вдалося зберегти', 'OK', 'Error') | Out-Null
    }
})

$findIdButton.Add_Click({
    try {
        $form.UseWaitCursor = $true
        $foundId = Find-CourseTelegramUserId -TelegramToken $tokenBox.Text.Trim()
        $userBox.Text = $foundId
        Add-LogLine "Telegram user ID знайдено: $foundId"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Пошук Telegram user ID', 'OK', 'Information') | Out-Null
    } finally {
        $form.UseWaitCursor = $false
    }
})

$startButton.Add_Click({
    try {
        if (-not (Get-CourseKitSettingsSummary).Configured) { throw 'Спочатку збережіть токен і Telegram user ID.' }
        Start-CourseOperation -FunctionName 'Start-CourseKit' -DisplayName 'Запуск системи'
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Запуск', 'OK', 'Warning') | Out-Null }
})

$stopButton.Add_Click({
    try {
        if (-not (Get-CourseKitSettingsSummary).Configured) { throw 'Налаштування пакета ще не створені.' }
        Start-CourseOperation -FunctionName 'Stop-CourseKit' -DisplayName 'Зупинка системи'
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Зупинка', 'OK', 'Warning') | Out-Null }
})

$checkButton.Add_Click({
    try {
        if (-not (Get-CourseKitSettingsSummary).Configured) { throw 'Налаштування пакета ще не створені.' }
        Start-CourseOperation -FunctionName 'Test-CourseKit' -DisplayName 'Перевірка системи'
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Перевірка', 'OK', 'Warning') | Out-Null }
})

$openButton.Add_Click({
    if ($script:lastLocalUrl) { Start-Process $script:lastLocalUrl }
    else { [System.Windows.Forms.MessageBox]::Show('Спочатку збережіть налаштування.', 'n8n', 'OK', 'Information') | Out-Null }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:currentJob) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show('Дочекайтеся завершення поточної операції.', 'Операція триває', 'OK', 'Information') | Out-Null
    }
})

Refresh-SavedSettings
Add-LogLine 'Версія пакета: 0.2.4.'
Add-LogLine 'Вікно готове. Для першого запуску збережіть токен і свій Telegram user ID.'
[void]$form.ShowDialog()
