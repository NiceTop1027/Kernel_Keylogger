param(
    [string]$TextLogPath = "",
    [string]$CsvLogPath = "",
    [switch]$Accept
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($TextLogPath)) {
    $TextLogPath = Join-Path $PSScriptRoot "captured_keys_portable.txt"
}

if ([string]::IsNullOrWhiteSpace($CsvLogPath)) {
    $CsvLogPath = Join-Path $PSScriptRoot "captured_keys_portable.csv"
}

$ErrorLogPath = Join-Path $PSScriptRoot "portable_error.log"

function Ensure-ParentDirectory {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Escape-CsvValue {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-KeyDisplay {
    param([System.ConsoleKeyInfo]$KeyInfo)

    $codePoint = [int][char]$KeyInfo.KeyChar
    if ($codePoint -ne 0) {
        if ($KeyInfo.KeyChar -eq [char]13) { return "[Enter]" }
        if ($KeyInfo.KeyChar -eq [char]9) { return "[Tab]" }
        if ($KeyInfo.KeyChar -eq [char]8) { return "[Backspace]" }
        if ($codePoint -lt 32) {
            return "[Ctrl+" + [char]($codePoint + 64) + "]"
        }
        return [string]$KeyInfo.KeyChar
    }

    $key = $KeyInfo.Key
    if ($key -eq [ConsoleKey]::Escape) { return "[Esc]" }
    if ($key -eq [ConsoleKey]::Backspace) { return "[Backspace]" }
    if ($key -eq [ConsoleKey]::Enter) { return "[Enter]" }
    if ($key -eq [ConsoleKey]::Tab) { return "[Tab]" }
    if ($key -eq [ConsoleKey]::Spacebar) { return " " }
    if ($key -eq [ConsoleKey]::Delete) { return "[Delete]" }
    if ($key -eq [ConsoleKey]::Insert) { return "[Insert]" }
    if ($key -eq [ConsoleKey]::Home) { return "[Home]" }
    if ($key -eq [ConsoleKey]::End) { return "[End]" }
    if ($key -eq [ConsoleKey]::PageUp) { return "[PageUp]" }
    if ($key -eq [ConsoleKey]::PageDown) { return "[PageDown]" }
    if ($key -eq [ConsoleKey]::UpArrow) { return "[Up]" }
    if ($key -eq [ConsoleKey]::DownArrow) { return "[Down]" }
    if ($key -eq [ConsoleKey]::LeftArrow) { return "[Left]" }
    if ($key -eq [ConsoleKey]::RightArrow) { return "[Right]" }

    return "[" + $KeyInfo.Key.ToString() + "]"
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

    $color = "Green"
    if ($Display.StartsWith("[")) {
        $color = "Yellow"
    }

    Write-Host $Timestamp -NoNewline -ForegroundColor DarkGray
    Write-Host ("  " + $Display) -ForegroundColor $color
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    Ensure-ParentDirectory -Path $TextLogPath
    Ensure-ParentDirectory -Path $CsvLogPath

    if (-not (Test-Path -LiteralPath $CsvLogPath)) {
        Set-Content -LiteralPath $CsvLogPath -Encoding UTF8 -Value '"timestamp","display","kind","consoleKey","modifiers"'
    }

    $notice = @(
        "윤리적 책임: 이 프로그램은 현재 콘솔 창에서만 입력을 기록합니다.",
        "본인 소유 장치 또는 명시적 동의를 받은 환경에서만 사용하십시오.",
        "무단 복제, 무단 배포, 무단 수집을 금지합니다.",
        "종료하려면 Esc 를 누르십시오."
    )

    foreach ($line in $notice) {
        Write-Host $line
    }

    Write-Host "Portable Console Input"
    Write-Host ("TXT log : " + $TextLogPath)
    Write-Host ("CSV log : " + $CsvLogPath)
    Write-Host "범위    : 현재 콘솔 창만"
    Write-Host "종료 키 : Esc"
    Write-Host ("-" * 55)

    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        $display = Get-KeyDisplay -KeyInfo $keyInfo
        $timestamp = Get-Date -Format "HH:mm:ss.fff"
        $kind = "text"
        if ($display.StartsWith("[")) {
            $kind = "special"
        }
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
            Write-Host "[EXIT] Esc"
            break
        }
    }

    exit 0
}
catch {
    $lines = @()
    $lines += "=== portable error ==="
    $lines += ("time=" + (Get-Date -Format "o"))
    $lines += ("message=" + $_.Exception.Message)
    if ($_.ScriptStackTrace) {
        $lines += "stack="
        $lines += $_.ScriptStackTrace
    }
    Set-Content -LiteralPath $ErrorLogPath -Encoding UTF8 -Value $lines

    Write-Host ""
    Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Error log: " + $ErrorLogPath) -ForegroundColor Yellow
    exit 1
}
