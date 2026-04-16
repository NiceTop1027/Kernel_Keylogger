param(
    [string]$TextLogPath = (Join-Path $PSScriptRoot "captured_keys_portable.txt"),
    [string]$CsvLogPath = (Join-Path $PSScriptRoot "captured_keys_portable.csv"),
    [switch]$Accept
)

$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Ensure-ParentDirectory {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Escape-CsvValue {
    param([string]$Value)

    $escaped = $Value.Replace('"', '""')
    return '"' + $escaped + '"'
}

function Get-KeyDisplay {
    param([System.ConsoleKeyInfo]$KeyInfo)

    $codePoint = [int][char]$KeyInfo.KeyChar
    if ($codePoint -ne 0) {
        switch ($KeyInfo.KeyChar) {
            "`r" { return "[Enter]" }
            "`t" { return "[Tab]" }
            "`b" { return "[Backspace]" }
            default {
                if ($codePoint -lt 32) {
                    return "[Ctrl+$([char]($codePoint + 64))]"
                }
                return [string]$KeyInfo.KeyChar
            }
        }
    }

    switch ($KeyInfo.Key) {
        ([ConsoleKey]::Escape) { return "[Esc]" }
        ([ConsoleKey]::Backspace) { return "[Backspace]" }
        ([ConsoleKey]::Enter) { return "[Enter]" }
        ([ConsoleKey]::Tab) { return "[Tab]" }
        ([ConsoleKey]::Spacebar) { return " " }
        ([ConsoleKey]::Delete) { return "[Delete]" }
        ([ConsoleKey]::Insert) { return "[Insert]" }
        ([ConsoleKey]::Home) { return "[Home]" }
        ([ConsoleKey]::End) { return "[End]" }
        ([ConsoleKey]::PageUp) { return "[PageUp]" }
        ([ConsoleKey]::PageDown) { return "[PageDown]" }
        ([ConsoleKey]::UpArrow) { return "[Up]" }
        ([ConsoleKey]::DownArrow) { return "[Down]" }
        ([ConsoleKey]::LeftArrow) { return "[Left]" }
        ([ConsoleKey]::RightArrow) { return "[Right]" }
        default { return "[{0}]" -f $KeyInfo.Key }
    }
}

function Get-ModifierText {
    param([System.ConsoleKeyInfo]$KeyInfo)

    $mods = @()
    if (($KeyInfo.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) { $mods += "Shift" }
    if (($KeyInfo.Modifiers -band [ConsoleModifiers]::Alt) -ne 0) { $mods += "Alt" }
    if (($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0) { $mods += "Ctrl" }

    if ($mods.Count -eq 0) {
        return ""
    }

    return ($mods -join "+")
}

function Write-KeyLine {
    param(
        [string]$Timestamp,
        [string]$Display
    )

    $color = if ($Display.StartsWith("[") -or $Display.StartsWith("↑")) {
        "Yellow"
    } else {
        "Green"
    }

    Write-Host $Timestamp -NoNewline -ForegroundColor DarkGray
    Write-Host ("  " + $Display) -ForegroundColor $color
}

Ensure-ParentDirectory -Path $TextLogPath
Ensure-ParentDirectory -Path $CsvLogPath

if (-not (Test-Path -LiteralPath $CsvLogPath)) {
    Set-Content -LiteralPath $CsvLogPath -Encoding UTF8 -Value '"timestamp","display","kind","consoleKey","modifiers"'
}

$notice = @"
이 프로그램은 설치 없이 바로 실행되는 안전한 포터블 데모입니다.
입력 범위는 현재 콘솔 창으로 제한되며, 시스템 전역 입력이나 백그라운드 앱 입력은 읽지 않습니다.
윤리적 책임과 무단 복제/무단 수집 금지 원칙을 이해한 뒤에만 사용하십시오.
"@

Write-Host $notice

if (-not $Accept) {
    $answer = Read-Host "계속하려면 YES 를 입력하세요"
    if ($answer.ToUpperInvariant() -ne "YES") {
        throw "동의하지 않아 종료합니다."
    }
}

Write-Host "Portable Console Demo"
Write-Host ("TXT 저장  : " + $TextLogPath)
Write-Host ("CSV 저장  : " + $CsvLogPath)
Write-Host "입력 범위 : 현재 콘솔 창만"
Write-Host "종료 키   : Esc"
Write-Host ("-" * 55)

while ($true) {
    $keyInfo = [Console]::ReadKey($true)
    $display = Get-KeyDisplay -KeyInfo $keyInfo
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    $kind = if ($display.StartsWith("[")) { "special" } else { "text" }
    $modifiers = Get-ModifierText -KeyInfo $keyInfo

    Write-KeyLine -Timestamp $timestamp -Display $display
    Add-Content -LiteralPath $TextLogPath -Encoding UTF8 -Value ($timestamp + "  " + $display)

    $csvLine = @(
        (Escape-CsvValue $timestamp)
        (Escape-CsvValue $display)
        (Escape-CsvValue $kind)
        (Escape-CsvValue $keyInfo.Key.ToString())
        (Escape-CsvValue $modifiers)
    ) -join ","
    Add-Content -LiteralPath $CsvLogPath -Encoding UTF8 -Value $csvLine

    if ($keyInfo.Key -eq [ConsoleKey]::Escape) {
        Write-Host ""
        Write-Host "[종료] Esc 입력"
        break
    }
}
