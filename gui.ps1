param(
    [string]$TextLogPath = "",
    [string]$CsvLogPath = "",
    [string]$PidPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if ([string]::IsNullOrWhiteSpace($TextLogPath)) {
    $TextLogPath = Join-Path $PSScriptRoot "captured_keys_gui.txt"
}

if ([string]::IsNullOrWhiteSpace($CsvLogPath)) {
    $CsvLogPath = Join-Path $PSScriptRoot "captured_keys_gui.csv"
}

if ([string]::IsNullOrWhiteSpace($PidPath)) {
    $PidPath = Join-Path $PSScriptRoot "gui.pid"
}

$ErrorLogPath = Join-Path $PSScriptRoot "gui_error.log"
$MutexName = "Local\KeyboardInputGui"
$script:CaptureEnabled = $true
$script:TextLogPath = $TextLogPath
$script:CsvLogPath = $CsvLogPath
$script:PidPath = $PidPath
$script:LogBox = $null
$script:StatusLabel = $null
$script:InputBox = $null
$script:Mutex = $null

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

function Update-Status {
    if ($null -eq $script:StatusLabel) {
        return
    }

    if ($script:CaptureEnabled) {
        $script:StatusLabel.Text = "Capture: ON"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(28, 120, 40)
    }
    else {
        $script:StatusLabel.Text = "Capture: OFF"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 40, 40)
    }
}

function Get-ModifierText {
    param([System.Windows.Forms.KeyEventArgs]$EventArgs)

    $mods = @()
    if ($EventArgs.Shift) { $mods += "Shift" }
    if ($EventArgs.Alt) { $mods += "Alt" }
    if ($EventArgs.Control) { $mods += "Ctrl" }

    if ($mods.Count -eq 0) {
        return ""
    }

    return ($mods -join "+")
}

function Append-Log {
    param(
        [string]$Display,
        [string]$Kind,
        [string]$KeyName,
        [string]$Modifiers
    )

    if (-not $script:CaptureEnabled) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = $timestamp + "  " + $Display

    if ($null -ne $script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }

    Add-Content -LiteralPath $script:TextLogPath -Encoding UTF8 -Value $line

    $csvLine = @(
        (Escape-CsvValue $timestamp)
        (Escape-CsvValue $Display)
        (Escape-CsvValue $Kind)
        (Escape-CsvValue $KeyName)
        (Escape-CsvValue $Modifiers)
    ) -join ","
    Add-Content -LiteralPath $script:CsvLogPath -Encoding UTF8 -Value $csvLine
}

function Get-SpecialDisplay {
    param([System.Windows.Forms.Keys]$KeyCode)

    switch ($KeyCode) {
        ([System.Windows.Forms.Keys]::Back) { return "[Backspace]" }
        ([System.Windows.Forms.Keys]::Tab) { return "[Tab]" }
        ([System.Windows.Forms.Keys]::Enter) { return "[Enter]" }
        ([System.Windows.Forms.Keys]::Escape) { return "[Esc]" }
        ([System.Windows.Forms.Keys]::Delete) { return "[Delete]" }
        ([System.Windows.Forms.Keys]::Insert) { return "[Insert]" }
        ([System.Windows.Forms.Keys]::Home) { return "[Home]" }
        ([System.Windows.Forms.Keys]::End) { return "[End]" }
        ([System.Windows.Forms.Keys]::PageUp) { return "[PageUp]" }
        ([System.Windows.Forms.Keys]::PageDown) { return "[PageDown]" }
        ([System.Windows.Forms.Keys]::Up) { return "[Up]" }
        ([System.Windows.Forms.Keys]::Down) { return "[Down]" }
        ([System.Windows.Forms.Keys]::Left) { return "[Left]" }
        ([System.Windows.Forms.Keys]::Right) { return "[Right]" }
        ([System.Windows.Forms.Keys]::F1) { return "[F1]" }
        ([System.Windows.Forms.Keys]::F2) { return "[F2]" }
        ([System.Windows.Forms.Keys]::F3) { return "[F3]" }
        ([System.Windows.Forms.Keys]::F4) { return "[F4]" }
        ([System.Windows.Forms.Keys]::F5) { return "[F5]" }
        ([System.Windows.Forms.Keys]::F6) { return "[F6]" }
        ([System.Windows.Forms.Keys]::F7) { return "[F7]" }
        ([System.Windows.Forms.Keys]::F8) { return "[F8]" }
        ([System.Windows.Forms.Keys]::F9) { return "[F9]" }
        ([System.Windows.Forms.Keys]::F10) { return "[F10]" }
        ([System.Windows.Forms.Keys]::F11) { return "[F11]" }
        ([System.Windows.Forms.Keys]::F12) { return "[F12]" }
        default { return "" }
    }
}

function Show-Error {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message + [Environment]::NewLine + "Error log: " + $ErrorLogPath,
        "Keyboard Input GUI",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

try {
    Ensure-ParentDirectory -Path $script:TextLogPath
    Ensure-ParentDirectory -Path $script:CsvLogPath
    Ensure-ParentDirectory -Path $script:PidPath

    if (-not (Test-Path -LiteralPath $script:CsvLogPath)) {
        Set-Content -LiteralPath $script:CsvLogPath -Encoding UTF8 -Value '"timestamp","display","kind","key","modifiers"'
    }

    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    if (-not $createdNew) {
        [System.Windows.Forms.MessageBox]::Show(
            "The GUI is already running.",
            "Keyboard Input GUI",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        exit 0
    }

    Set-Content -LiteralPath $script:PidPath -Encoding ASCII -Value $PID

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Keyboard Input GUI"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(980, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 680)
    $form.BackColor = [System.Drawing.Color]::FromArgb(247, 244, 236)
    $form.KeyPreview = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Keyboard Input GUI"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(24, 18)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = "윤리적 책임: 이 프로그램은 본인 소유 장치 또는 명시적 동의를 받은 환경에서만 사용하십시오.`r`n무단 복제, 무단 배포, 무단 수집을 금지하며 입력은 이 창 내부에서만 기록됩니다."
    $notice.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $notice.Location = New-Object System.Drawing.Point(28, 58)
    $notice.Size = New-Object System.Drawing.Size(900, 36)
    $form.Controls.Add($notice)

    $statusCaption = New-Object System.Windows.Forms.Label
    $statusCaption.Text = "Status"
    $statusCaption.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $statusCaption.Location = New-Object System.Drawing.Point(28, 104)
    $statusCaption.AutoSize = $true
    $form.Controls.Add($statusCaption)

    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:StatusLabel.Location = New-Object System.Drawing.Point(88, 104)
    $script:StatusLabel.AutoSize = $true
    $form.Controls.Add($script:StatusLabel)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "ON"
    $startButton.Location = New-Object System.Drawing.Point(720, 22)
    $startButton.Size = New-Object System.Drawing.Size(90, 34)
    $startButton.BackColor = [System.Drawing.Color]::FromArgb(49, 126, 58)
    $startButton.ForeColor = [System.Drawing.Color]::White
    $startButton.FlatStyle = "Flat"
    $form.Controls.Add($startButton)

    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = "OFF"
    $stopButton.Location = New-Object System.Drawing.Point(820, 22)
    $stopButton.Size = New-Object System.Drawing.Size(90, 34)
    $stopButton.BackColor = [System.Drawing.Color]::FromArgb(161, 54, 54)
    $stopButton.ForeColor = [System.Drawing.Color]::White
    $stopButton.FlatStyle = "Flat"
    $form.Controls.Add($stopButton)

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = "Clear View"
    $clearButton.Location = New-Object System.Drawing.Point(720, 66)
    $clearButton.Size = New-Object System.Drawing.Size(190, 30)
    $clearButton.FlatStyle = "Flat"
    $form.Controls.Add($clearButton)

    $inputLabel = New-Object System.Windows.Forms.Label
    $inputLabel.Text = "Input Area"
    $inputLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $inputLabel.Location = New-Object System.Drawing.Point(28, 132)
    $inputLabel.AutoSize = $true
    $form.Controls.Add($inputLabel)

    $inputHint = New-Object System.Windows.Forms.Label
    $inputHint.Text = "Click here and type. Only keystrokes entered in this box are logged."
    $inputHint.Location = New-Object System.Drawing.Point(28, 156)
    $inputHint.Size = New-Object System.Drawing.Size(760, 20)
    $form.Controls.Add($inputHint)

    $script:InputBox = New-Object System.Windows.Forms.TextBox
    $script:InputBox.Multiline = $true
    $script:InputBox.AcceptsReturn = $true
    $script:InputBox.AcceptsTab = $true
    $script:InputBox.ScrollBars = "Vertical"
    $script:InputBox.Font = New-Object System.Drawing.Font("Consolas", 12)
    $script:InputBox.Location = New-Object System.Drawing.Point(28, 184)
    $script:InputBox.Size = New-Object System.Drawing.Size(882, 210)
    $form.Controls.Add($script:InputBox)

    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = "Captured Log"
    $logLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $logLabel.Location = New-Object System.Drawing.Point(28, 414)
    $logLabel.AutoSize = $true
    $form.Controls.Add($logLabel)

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = "TXT: " + $script:TextLogPath + "    CSV: " + $script:CsvLogPath
    $pathLabel.Location = New-Object System.Drawing.Point(28, 438)
    $pathLabel.Size = New-Object System.Drawing.Size(880, 18)
    $form.Controls.Add($pathLabel)

    $script:LogBox = New-Object System.Windows.Forms.TextBox
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = "Vertical"
    $script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:LogBox.Location = New-Object System.Drawing.Point(28, 464)
    $script:LogBox.Size = New-Object System.Drawing.Size(882, 214)
    $form.Controls.Add($script:LogBox)

    Update-Status

    $startButton.Add_Click({
        $script:CaptureEnabled = $true
        Update-Status
        $script:InputBox.Focus()
    })

    $stopButton.Add_Click({
        $script:CaptureEnabled = $false
        Update-Status
        $script:InputBox.Focus()
    })

    $clearButton.Add_Click({
        $script:InputBox.Clear()
        $script:LogBox.Clear()
        $script:InputBox.Focus()
    })

    $script:InputBox.Add_KeyPress({
        param($sender, $eventArgs)

        if (-not $script:CaptureEnabled) {
            return
        }

        $code = [int][char]$eventArgs.KeyChar
        if ($code -eq 13 -or $code -eq 9 -or $code -eq 8) {
            return
        }

        if ($code -lt 32) {
            return
        }

        Append-Log -Display ([string]$eventArgs.KeyChar) -Kind "text" -KeyName "Char" -Modifiers ""
    })

    $script:InputBox.Add_KeyDown({
        param($sender, $eventArgs)

        if (-not $script:CaptureEnabled) {
            return
        }

        $display = Get-SpecialDisplay -KeyCode $eventArgs.KeyCode
        if ([string]::IsNullOrWhiteSpace($display)) {
            return
        }

        Append-Log -Display $display -Kind "special" -KeyName $eventArgs.KeyCode.ToString() -Modifiers (Get-ModifierText -EventArgs $eventArgs)
    })

    $form.Add_Shown({
        $script:InputBox.Focus()
    })

    $form.Add_FormClosed({
        if (Test-Path -LiteralPath $script:PidPath) {
            Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
        }

        if ($null -ne $script:Mutex) {
            $script:Mutex.ReleaseMutex() | Out-Null
            $script:Mutex.Dispose()
        }
    })

    [System.Windows.Forms.Application]::Run($form)
    exit 0
}
catch {
    $lines = @()
    $lines += "=== gui error ==="
    $lines += ("time=" + (Get-Date -Format "o"))
    $lines += ("message=" + $_.Exception.Message)
    if ($_.ScriptStackTrace) {
        $lines += "stack="
        $lines += $_.ScriptStackTrace
    }
    Set-Content -LiteralPath $ErrorLogPath -Encoding UTF8 -Value $lines
    Show-Error -Message $_.Exception.Message
    exit 1
}
