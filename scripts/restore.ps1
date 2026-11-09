[CmdletBinding()]
param([string]$BackupPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CourseKit.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Оберіть резервну копію n8n Course Kit'
    $dialog.Filter = 'Course Kit backup (*.zip)|*.zip'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $BackupPath = $dialog.FileName
}

$answer = [System.Windows.Forms.MessageBox]::Show(
    'Поточні контейнери пакета буде зупинено, а дані n8n замінено резервною копією. Перед заміною пакет створить страхову копію. Продовжити?',
    'Підтвердження відновлення', 'YesNo', 'Warning'
)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

try {
    $result = Restore-CourseKitBackup -BackupPath $BackupPath -ConfirmRestore
    $message = 'Відновлення завершено. Запустіть пакет через start.cmd.'
    if ($result.SafetyBackupPath) { $message += "`r`nСтрахова копія: $($result.SafetyBackupPath)" }
    [System.Windows.Forms.MessageBox]::Show($message, 'n8n Course Kit', 'OK', 'Information') | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Не вдалося відновити', 'OK', 'Error') | Out-Null
    exit 1
}
