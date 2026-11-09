[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'CourseKit.psm1') -Force

try {
    $result = Backup-CourseKit
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Резервну копію створено:`r`n$($result.BackupPath)",
        'n8n Course Kit', 'OK', 'Information'
    ) | Out-Null
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Резервне копіювання', 'OK', 'Error') | Out-Null
    exit 1
}
