<#
.SYNOPSIS
    Собирает все домены из всех list-general.txt и добавляет недостающие в каждый файл.

.DESCRIPTION
    Скрипт рекурсивно находит все файлы list-general.txt в указанном корне (по умолчанию D:\DSfix),
    собирает объединённый набор записей и синхронизирует его во все файлы:
      - записи, которые уже есть в файле, остаются на своих местах (порядок не меняется);
      - недостающие записи добавляются в конец файла;
      - дубликаты внутри одного файла удаляются;
      - комментарии (строки, начинающиеся с #) и пустые строки сохраняются;
      - кодировка (UTF-8 / UTF-8 BOM / UTF-16) и тип перевода строки (CRLF/LF) каждого файла сохраняются.

    Перед изменением каждого файла создаётся резервная копия в папке
    <Корень>\_backup_list-general_<дата-время>\ с сохранением структуры каталогов.

.PARAMETER Root
    Корневая папка для поиска. По умолчанию D:\DSfix.

.PARAMETER DryRun
    Только показать, что будет сделано. Файлы не изменяются.

.PARAMETER NoBackup
    Не создавать резервные копии (не рекомендуется).

.EXAMPLE
    .\merge-list-general.ps1 -DryRun

.EXAMPLE
    .\merge-list-general.ps1

.EXAMPLE
    .\merge-list-general.ps1 -Root 'D:\DSfix' -Verbose
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root = 'C:\Zapret',  #Необходимо изменить на папку, где у вас находится Zapret
    [switch]$DryRun,
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ListFile {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    $bom = 'none'
    $offset = 0
    $readEncoding = New-Object System.Text.UTF8Encoding($false)
    $writeEncoding = New-Object System.Text.UTF8Encoding($false)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bom = 'utf8bom'
        $offset = 3
        $writeEncoding = New-Object System.Text.UTF8Encoding($true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $bom = 'utf16le'
        $offset = 2
        $readEncoding = New-Object System.Text.UnicodeEncoding($false, $false)
        $writeEncoding = New-Object System.Text.UnicodeEncoding($false, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $bom = 'utf16be'
        $offset = 2
        $readEncoding = New-Object System.Text.UnicodeEncoding($true, $false)
        $writeEncoding = New-Object System.Text.UnicodeEncoding($true, $true)
    }

    $text = $readEncoding.GetString($bytes, $offset, $bytes.Length - $offset)

    if ($text -match "`r`n") { $newLine = "`r`n" }
    elseif ($text -match "`n") { $newLine = "`n" }
    elseif ($text -match "`r") { $newLine = "`r" }
    else { $newLine = "`r`n" }

    $trailingNewLine = $text -match '(\r\n|\n|\r)$'
    $lines = @($text -split "\r\n|\n|\r")
    if ($trailingNewLine -and $lines.Count -gt 0) {
        # Последний элемент после split — пустая строка от завершающего перевода строки.
        $lines = @($lines[0..($lines.Count - 2)])
    }

    [PSCustomObject]@{
        Path            = $Path
        Lines           = $lines
        NewLine         = $newLine
        TrailingNewLine = $trailingNewLine
        Bom             = $bom
        Encoding        = $writeEncoding
        OriginalText    = $text
    }
}

function Test-DataLine {
    param([string]$Line)
    $t = $Line.Trim()
    return ($t.Length -gt 0 -and -not $t.StartsWith('#'))
}

# --- Поиск файлов ---------------------------------------------------------

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Папка не найдена: $Root"
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')

$files = @(
    Get-ChildItem -LiteralPath $rootPath -Filter 'list-general.txt' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'list-general.txt' } |
        Sort-Object FullName
)

if ($files.Count -eq 0) {
    Write-Host "Файлы list-general.txt не найдены в $rootPath" -ForegroundColor Yellow
    return
}

Write-Host "Корень: $rootPath"
Write-Host "Найдено файлов list-general.txt: $($files.Count)"
if ($DryRun) {
    Write-Host "Режим: DRY RUN (файлы не изменяются)" -ForegroundColor Yellow
}
Write-Host ''

# --- Чтение и сбор объединённого набора ----------------------------------

$infos = @()
foreach ($file in $files) {
    $infos += Read-ListFile -Path $file.FullName
}

$union = New-Object System.Collections.Generic.List[string]
$unionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$perFileSets = @{}
$perFileDupes = @{}

foreach ($info in $infos) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $dupes = 0
    foreach ($line in $info.Lines) {
        if (-not (Test-DataLine $line)) { continue }
        $t = $line.Trim()
        if ($set.Add($t)) {
            if ($unionSet.Add($t)) { $union.Add($t) | Out-Null }
        }
        else {
            $dupes++
        }
    }
    $perFileSets[$info.Path] = $set
    $perFileDupes[$info.Path] = $dupes
}

Write-Host "Уникальных записей в объединённом наборе: $($union.Count)" -ForegroundColor Cyan
Write-Host ''

# --- Синхронизация файлов ------------------------------------------------

$backupRoot = $null
$results = @()

foreach ($info in $infos) {
    $fileSet = $perFileSets[$info.Path]
    $before = $fileSet.Count
    $dupes = $perFileDupes[$info.Path]
    $added = New-Object System.Collections.Generic.List[string]

    # Пересобираем содержимое: порядок исходных строк сохраняется, дубликаты записей убираются.
    $out = New-Object System.Collections.Generic.List[string]
    $written = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $info.Lines) {
        if (-not (Test-DataLine $line)) {
            $out.Add($line)
            continue
        }
        $t = $line.Trim()
        if ($written.Add($t)) {
            $out.Add($t)
        }
    }

    # Убираем пустые строки в конце, чтобы добавление выглядело аккуратно.
    while ($out.Count -gt 0 -and -not (Test-DataLine $out[$out.Count - 1]) -and $out[$out.Count - 1].Trim().Length -eq 0) {
        $out.RemoveAt($out.Count - 1)
    }

    foreach ($entry in $union) {
        if (-not $fileSet.Contains($entry)) {
            $out.Add($entry)
            $added.Add($entry)
            $fileSet.Add($entry) | Out-Null
        }
    }

    $newText = $out -join $info.NewLine
    if ($info.TrailingNewLine -and $out.Count -gt 0) {
        $newText += $info.NewLine
    }

    $changed = ($newText -cne $info.OriginalText)

    $relPath = $info.Path.Substring($rootPath.Length).TrimStart('\', '/')
    $status = if ($changed) { if ($DryRun) { 'будет изменён' } else { 'изменён' } } else { 'без изменений' }

    Write-Host ("{0}" -f $relPath)
    Write-Host ("    было {0} -> станет {1}  (+{2}, удалено дублей: {3})  [{4}]" -f `
            $before, $out.Count, $added.Count, $dupes, $status)

    if ($VerbosePreference -ne 'SilentlyContinue' -and $added.Count -gt 0) {
        Write-Verbose ("Добавлено в {0}: {1}" -f $relPath, ($added -join ', '))
    }

    if ($changed -and -not $DryRun) {
        try {
            if (-not $NoBackup) {
                if ($null -eq $backupRoot) {
                    $backupRoot = Join-Path $rootPath ('_backup_list-general_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                }
                $backupPath = Join-Path $backupRoot ($relPath + '.bak')
                $backupDir = Split-Path -Parent $backupPath
                if (-not (Test-Path -LiteralPath $backupDir)) {
                    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $info.Path -Destination $backupPath -Force
            }

            [System.IO.File]::WriteAllText($info.Path, $newText, $info.Encoding)
        }
        catch {
            Write-Host ("    ОШИБКА записи: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $results += [PSCustomObject]@{ File = $relPath; Before = $before; After = $out.Count; Added = $added.Count; Error = $_.Exception.Message }
            continue
        }
    }

    $results += [PSCustomObject]@{ File = $relPath; Before = $before; After = $out.Count; Added = $added.Count; Error = $null }
}

# --- Итоги ----------------------------------------------------------------

$changedCount = @($results | Where-Object { $_.Added -gt 0 -or $_.Before -ne $_.After }).Count
$addedTotal = ($results | Measure-Object -Property Added -Sum).Sum
$errorCount = @($results | Where-Object { $_.Error }).Count

Write-Host ''
Write-Host 'Итог:' -ForegroundColor Cyan
Write-Host ("    Файлов обработано: {0}" -f $results.Count)
Write-Host ("    Файлов изменено:    {0}" -f $changedCount)
Write-Host ("    Добавлено записей:  {0}" -f $addedTotal)
Write-Host ("    Объединённый набор: {0} записей" -f $union.Count)
if ($ErrorCount -gt 0) {
    Write-Host ("    Ошибок записи:      {0}" -f $errorCount) -ForegroundColor Red
}
if ($backupRoot) {
    Write-Host ("    Резервные копии:    {0}" -f $backupRoot)
}
if ($DryRun) {
    Write-Host ''
    Write-Host 'Это был DRY RUN. Ни один файл не изменён.' -ForegroundColor Yellow
}
