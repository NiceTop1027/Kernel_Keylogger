param(
    [string]$TextLogPath = "",
    [string]$CsvLogPath = "",
    [string]$PidPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KeyFilterInterop
{
    public const UInt32 GENERIC_READ = 0x80000000;
    public const UInt32 GENERIC_WRITE = 0x40000000;
    public const UInt32 OPEN_EXISTING = 3;
    public const UInt32 FILE_DEVICE_UNKNOWN = 0x00000022;
    public const UInt32 METHOD_BUFFERED = 0;
    public const UInt32 FILE_READ_DATA = 0x0001;
    public const UInt32 FILE_WRITE_DATA = 0x0002;

    public static UInt32 CtlCode(UInt32 deviceType, UInt32 function, UInt32 method, UInt32 access)
    {
        return (deviceType << 16) | (access << 14) | (function << 2) | method;
    }

    public static readonly UInt32 IOCTL_KEYFILTER_READ =
        CtlCode(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_DATA);
    public static readonly UInt32 IOCTL_KEYFILTER_SUBMIT =
        CtlCode(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA);
    public static readonly UInt32 IOCTL_KEYFILTER_RESET =
        CtlCode(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_WRITE_DATA);
    public static readonly UInt32 IOCTL_KEYFILTER_STATUS =
        CtlCode(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_READ_DATA);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct KeyRecord
    {
        public UInt64 Timestamp100ns;
        public UInt16 MakeCode;
        public UInt16 Flags;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public UInt16[] TextUtf16;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct DriverStatus
    {
        public UInt32 QueuedCount;
        public UInt32 Capacity;
        public UInt32 Flags;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern SafeFileHandle CreateFile(
        string fileName,
        UInt32 desiredAccess,
        UInt32 shareMode,
        IntPtr securityAttributes,
        UInt32 creationDisposition,
        UInt32 flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        SafeFileHandle deviceHandle,
        UInt32 ioControlCode,
        IntPtr inBuffer,
        UInt32 inBufferSize,
        IntPtr outBuffer,
        UInt32 outBufferSize,
        out UInt32 bytesReturned,
        IntPtr overlapped);
}
'@

if ([string]::IsNullOrWhiteSpace($TextLogPath)) {
    $TextLogPath = Join-Path $PSScriptRoot "captured_keys_gui.txt"
}

if ([string]::IsNullOrWhiteSpace($CsvLogPath)) {
    $CsvLogPath = Join-Path $PSScriptRoot "captured_keys_gui.csv"
}

if ([string]::IsNullOrWhiteSpace($PidPath)) {
    $PidPath = Join-Path $PSScriptRoot "gui_demo.pid"
}

$ErrorLogPath = Join-Path $PSScriptRoot "gui_demo_error.log"
$MutexName = "Local\KernelKeyloggerGuiDemo"
$script:CaptureEnabled = $true
$script:TextLogPath = $TextLogPath
$script:CsvLogPath = $CsvLogPath
$script:PidPath = $PidPath
$script:LogBox = $null
$script:StatusLabel = $null
$script:InputBox = $null
$script:Mutex = $null
$script:DriverHandle = $null
$script:DriverReady = $false
$script:DriverQueue = 0
$script:DriverCapacity = 0
$script:LastDriverMessage = "Driver not connected."
$script:KeyRecordType = [type]"KeyFilterInterop+KeyRecord"
$script:DriverStatusType = [type]"KeyFilterInterop+DriverStatus"

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

function Get-Win32ErrorMessage {
    param([int]$Code)

    return (New-Object System.ComponentModel.Win32Exception($Code)).Message
}

function Close-DriverHandle {
    if ($null -ne $script:DriverHandle) {
        try {
            $script:DriverHandle.Close()
        }
        catch {
        }
        $script:DriverHandle = $null
    }

    $script:DriverReady = $false
    $script:DriverQueue = 0
    $script:DriverCapacity = 0
}

function Update-Status {
    if ($null -eq $script:StatusLabel) {
        return
    }

    $captureText = "Capture OFF"
    if ($script:CaptureEnabled) {
        $captureText = "Capture ON"
    }

    if ($script:DriverReady) {
        $script:StatusLabel.Text =
            "Driver CONNECTED | " + $captureText + " | Queue " +
            $script:DriverQueue + "/" + $script:DriverCapacity
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(28, 120, 40)
    }
    else {
        $script:StatusLabel.Text =
            "Driver DISCONNECTED | " + $captureText + " | " + $script:LastDriverMessage
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 40, 40)
    }
}

function Open-DriverHandle {
    $handle = [KeyFilterInterop]::CreateFile(
        "\\.\KeyFilter",
        [KeyFilterInterop]::GENERIC_READ -bor [KeyFilterInterop]::GENERIC_WRITE,
        0,
        [IntPtr]::Zero,
        [KeyFilterInterop]::OPEN_EXISTING,
        0,
        [IntPtr]::Zero
    )

    if ($handle.IsInvalid) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $script:LastDriverMessage = "Open failed: " + (Get-Win32ErrorMessage -Code $code)
        return $null
    }

    $script:LastDriverMessage = "Connected."
    return $handle
}

function Invoke-DriverReset {
    if ($null -eq $script:DriverHandle) {
        return $false
    }

    [uint32]$bytesReturned = 0
    $ok = [KeyFilterInterop]::DeviceIoControl(
        $script:DriverHandle,
        [KeyFilterInterop]::IOCTL_KEYFILTER_RESET,
        [IntPtr]::Zero,
        0,
        [IntPtr]::Zero,
        0,
        [ref]$bytesReturned,
        [IntPtr]::Zero
    )

    if (-not $ok) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $script:LastDriverMessage = "Reset failed: " + (Get-Win32ErrorMessage -Code $code)
    }

    return $ok
}

function Get-DriverStatusInfo {
    if ($null -eq $script:DriverHandle) {
        return $null
    }

    $size = [System.Runtime.InteropServices.Marshal]::SizeOf($script:DriverStatusType)
    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)

    try {
        [uint32]$bytesReturned = 0
        $ok = [KeyFilterInterop]::DeviceIoControl(
            $script:DriverHandle,
            [KeyFilterInterop]::IOCTL_KEYFILTER_STATUS,
            [IntPtr]::Zero,
            0,
            $buffer,
            [uint32]$size,
            [ref]$bytesReturned,
            [IntPtr]::Zero
        )

        if (-not $ok) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $script:LastDriverMessage = "Status failed: " + (Get-Win32ErrorMessage -Code $code)
            return $null
        }

        return [System.Runtime.InteropServices.Marshal]::PtrToStructure(
            $buffer,
            $script:DriverStatusType
        )
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}

function Ensure-DriverConnection {
    if ($null -ne $script:DriverHandle -and -not $script:DriverHandle.IsInvalid) {
        return $true
    }

    Close-DriverHandle
    $handle = Open-DriverHandle
    if ($null -eq $handle) {
        $script:DriverReady = $false
        Update-Status
        return $false
    }

    $script:DriverHandle = $handle
    $script:DriverReady = $true
    $null = Get-DriverStatusInfo
    Update-Status
    return $true
}

function Convert-TextToUtf16Units {
    param([string]$Text)

    $units = New-Object "System.UInt16[]" 16
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Text)
    $count = [Math]::Min(16, [int]($bytes.Length / 2))

    for ($i = 0; $i -lt $count; $i++) {
        $units[$i] = [BitConverter]::ToUInt16($bytes, $i * 2)
    }

    return $units
}

function New-DriverRecord {
    param(
        [string]$Display,
        [uint16]$MakeCode,
        [uint16]$Flags
    )

    $record = [Activator]::CreateInstance($script:KeyRecordType)
    $record.Timestamp100ns = [UInt64]0
    $record.MakeCode = $MakeCode
    $record.Flags = $Flags
    $record.TextUtf16 = Convert-TextToUtf16Units -Text $Display
    return $record
}

function Convert-DriverRecordToText {
    param($Record)

    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($unit in $Record.TextUtf16) {
        if ($unit -eq 0) {
            break
        }
        $chars.Add([char]$unit)
    }

    return -join $chars.ToArray()
}

function Append-UiLog {
    param(
        [string]$Timestamp,
        [string]$Display
    )

    $line = $Timestamp + "  " + $Display

    if ($null -ne $script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }

    Add-Content -LiteralPath $script:TextLogPath -Encoding UTF8 -Value $line
}

function Drain-DriverLog {
    if ($null -eq $script:DriverHandle) {
        return
    }

    $recordSize = [System.Runtime.InteropServices.Marshal]::SizeOf($script:KeyRecordType)
    $bufferSize = $recordSize * 64
    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufferSize)

    try {
        while ($true) {
            [uint32]$bytesReturned = 0
            $ok = [KeyFilterInterop]::DeviceIoControl(
                $script:DriverHandle,
                [KeyFilterInterop]::IOCTL_KEYFILTER_READ,
                [IntPtr]::Zero,
                0,
                $buffer,
                [uint32]$bufferSize,
                [ref]$bytesReturned,
                [IntPtr]::Zero
            )

            if (-not $ok) {
                $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                $script:LastDriverMessage = "Read failed: " + (Get-Win32ErrorMessage -Code $code)
                Close-DriverHandle
                Update-Status
                return
            }

            $count = [int]($bytesReturned / $recordSize)
            if ($count -le 0) {
                break
            }

            for ($i = 0; $i -lt $count; $i++) {
                $itemPtr = [IntPtr]($buffer.ToInt64() + ($i * $recordSize))
                $record = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                    $itemPtr,
                    $script:KeyRecordType
                )
                $display = Convert-DriverRecordToText -Record $record
                if ([string]::IsNullOrWhiteSpace($display)) {
                    continue
                }

                $dt = [DateTime]::FromFileTimeUtc([Int64]$record.Timestamp100ns).ToLocalTime()
                $timestamp = $dt.ToString("yyyy-MM-dd HH:mm:ss.fff")
                Append-UiLog -Timestamp $timestamp -Display $display

                $kind = "text"
                if ($display.StartsWith("[")) {
                    $kind = "special"
                }

                $csvLine = @(
                    (Escape-CsvValue $timestamp)
                    (Escape-CsvValue $display)
                    (Escape-CsvValue $kind)
                    (Escape-CsvValue $record.MakeCode.ToString())
                    (Escape-CsvValue $record.Flags.ToString())
                ) -join ","
                Add-Content -LiteralPath $script:CsvLogPath -Encoding UTF8 -Value $csvLine
            }
        }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}

function Refresh-DriverState {
    if (-not (Ensure-DriverConnection)) {
        return
    }

    $status = Get-DriverStatusInfo
    if ($null -eq $status) {
        Close-DriverHandle
        Update-Status
        return
    }

    $script:DriverReady = $true
    $script:DriverQueue = [int]$status.QueuedCount
    $script:DriverCapacity = [int]$status.Capacity

    if ($script:DriverQueue -gt 0) {
        Drain-DriverLog
        $status = Get-DriverStatusInfo
        if ($null -ne $status) {
            $script:DriverQueue = [int]$status.QueuedCount
            $script:DriverCapacity = [int]$status.Capacity
        }
    }

    Update-Status
}

function Submit-DriverEvent {
    param(
        [string]$Display,
        [uint16]$MakeCode,
        [uint16]$Flags
    )

    if (-not $script:CaptureEnabled) {
        return
    }

    if (-not (Ensure-DriverConnection)) {
        return
    }

    $record = New-DriverRecord -Display $Display -MakeCode $MakeCode -Flags $Flags
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf($script:KeyRecordType)
    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    $recordWritten = $false

    try {
        [System.Runtime.InteropServices.Marshal]::StructureToPtr($record, $buffer, $false)
        $recordWritten = $true
        [uint32]$bytesReturned = 0
        $ok = [KeyFilterInterop]::DeviceIoControl(
            $script:DriverHandle,
            [KeyFilterInterop]::IOCTL_KEYFILTER_SUBMIT,
            $buffer,
            [uint32]$size,
            [IntPtr]::Zero,
            0,
            [ref]$bytesReturned,
            [IntPtr]::Zero
        )

        if (-not $ok) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $script:LastDriverMessage = "Submit failed: " + (Get-Win32ErrorMessage -Code $code)
            Close-DriverHandle
            Update-Status
            return
        }
    }
    finally {
        if ($recordWritten) {
            [System.Runtime.InteropServices.Marshal]::DestroyStructure($buffer, $script:KeyRecordType)
        }
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }

    Drain-DriverLog
    Refresh-DriverState
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
        "Kernel Keylogger GUI Demo",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

try {
    Ensure-ParentDirectory -Path $script:TextLogPath
    Ensure-ParentDirectory -Path $script:CsvLogPath
    Ensure-ParentDirectory -Path $script:PidPath

    if (-not (Test-Path -LiteralPath $script:CsvLogPath)) {
        Set-Content -LiteralPath $script:CsvLogPath -Encoding UTF8 -Value '"timestamp","display","kind","makeCode","flags"'
    }

    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    if (-not $createdNew) {
        [System.Windows.Forms.MessageBox]::Show(
            "The GUI demo is already running.",
            "Kernel Keylogger GUI Demo",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        exit 0
    }

    Set-Content -LiteralPath $script:PidPath -Encoding ASCII -Value $PID

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Kernel Keylogger GUI Demo"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(980, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 680)
    $form.BackColor = [System.Drawing.Color]::FromArgb(247, 244, 236)
    $form.KeyPreview = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Kernel Keylogger GUI Demo"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(24, 18)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = "Kernel-backed safe mode: only input inside this window is submitted to the driver."
    $notice.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $notice.Location = New-Object System.Drawing.Point(28, 58)
    $notice.Size = New-Object System.Drawing.Size(900, 22)
    $form.Controls.Add($notice)

    $statusCaption = New-Object System.Windows.Forms.Label
    $statusCaption.Text = "Status"
    $statusCaption.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $statusCaption.Location = New-Object System.Drawing.Point(28, 94)
    $statusCaption.AutoSize = $true
    $form.Controls.Add($statusCaption)

    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:StatusLabel.Location = New-Object System.Drawing.Point(88, 94)
    $script:StatusLabel.Size = New-Object System.Drawing.Size(620, 40)
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
    $inputHint.Text = "Click here and type. This is the only input scope that gets sent to the driver."
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
    $logLabel.Text = "Driver Log"
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

    $driverTimer = New-Object System.Windows.Forms.Timer
    $driverTimer.Interval = 900
    $driverTimer.Add_Tick({
        Refresh-DriverState
    })

    $startButton.Add_Click({
        $script:CaptureEnabled = $true
        Refresh-DriverState
        $script:InputBox.Focus()
    })

    $stopButton.Add_Click({
        $script:CaptureEnabled = $false
        Refresh-DriverState
        $script:InputBox.Focus()
    })

    $clearButton.Add_Click({
        $script:InputBox.Clear()
        $script:LogBox.Clear()
        if (Ensure-DriverConnection) {
            $null = Invoke-DriverReset
            Refresh-DriverState
        }
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

        Submit-DriverEvent -Display ([string]$eventArgs.KeyChar) -MakeCode ([uint16]$code) -Flags ([uint16]0x0400)
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

        $flags = [uint16]0x0400
        Submit-DriverEvent -Display $display -MakeCode ([uint16]$eventArgs.KeyValue) -Flags $flags
    })

    $form.Add_Shown({
        if (Ensure-DriverConnection) {
            $null = Invoke-DriverReset
            Drain-DriverLog
        }
        Refresh-DriverState
        $driverTimer.Start()
        $script:InputBox.Focus()
    })

    $form.Add_FormClosed({
        $driverTimer.Stop()

        if (Test-Path -LiteralPath $script:PidPath) {
            Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
        }

        Close-DriverHandle

        if ($null -ne $script:Mutex) {
            $script:Mutex.ReleaseMutex() | Out-Null
            $script:Mutex.Dispose()
        }
    })

    Update-Status
    [System.Windows.Forms.Application]::Run($form)
    exit 0
}
catch {
    $lines = @()
    $lines += "=== gui demo error ==="
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
