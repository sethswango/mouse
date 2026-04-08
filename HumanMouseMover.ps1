<#
.SYNOPSIS
    Locally generated mouse mover that keeps the session awake.
    Detects human mouse activity and defers gracefully — never fights the user.
#>

param(
    [int]$ZoneWidth = 140,
    [int]$ZoneHeight = 90,
    [int]$ZonePadding = 50,
    [int]$HumanThresholdPx = 8
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  =====================================" -ForegroundColor Cyan
Write-Host "   Human Mouse Mover - Local Build" -ForegroundColor Cyan
Write-Host "  =====================================" -ForegroundColor Cyan
Write-Host ""

$durationInput = Read-Host "  Duration in hours [default 0.5]"
if ([string]::IsNullOrWhiteSpace($durationInput)) {
    $script:durationHours = 0.5
} else {
    try {
        $script:durationHours = [double]$durationInput
        if ($script:durationHours -le 0) { $script:durationHours = 0.5 }
    } catch {
        $script:durationHours = 0.5
    }
}

$script:startTime = Get-Date
$script:durationSeconds = [Math]::Round($script:durationHours * 3600)
$script:endTime = $script:startTime.AddSeconds($script:durationSeconds)

Write-Host "  Running for $($script:durationHours) hour(s), until $($script:endTime.ToString('h:mm:ss tt'))" -ForegroundColor Green
Write-Host ""

$nativeCode = @'
using System;
using System.Runtime.InteropServices;

public static class NativeMouse
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
}
'@

try {
    Add-Type -TypeDefinition $nativeCode -ErrorAction Stop
} catch {
    if ($_.Exception.Message -notlike "*already exists*") { throw }
}

$script:lastKnownX = -1
$script:lastKnownY = -1

function Get-CursorPosition {
    $pos = New-Object NativeMouse+POINT
    [void][NativeMouse]::GetCursorPos([ref]$pos)
    return @{ X = [int]$pos.X; Y = [int]$pos.Y }
}

function Test-HumanMovedMouse {
    if ($script:lastKnownX -eq -1) { return $false }
    $now = Get-CursorPosition
    $dx = [Math]::Abs($now.X - $script:lastKnownX)
    $dy = [Math]::Abs($now.Y - $script:lastKnownY)
    return ($dx -gt $HumanThresholdPx -or $dy -gt $HumanThresholdPx)
}

function Save-CursorPosition {
    $pos = Get-CursorPosition
    $script:lastKnownX = $pos.X
    $script:lastKnownY = $pos.Y
}

function Get-ZoneBounds {
    $screenWidth = [NativeMouse]::GetSystemMetrics(0)
    $screenHeight = [NativeMouse]::GetSystemMetrics(1)
    $left = 100
    $top = 100
    $width = [Math]::Min($ZoneWidth, [Math]::Max(80, $screenWidth - 200))
    $height = [Math]::Min($ZoneHeight, [Math]::Max(60, $screenHeight - 200))

    try {
        $hwnd = [NativeMouse]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            $rect = New-Object NativeMouse+RECT
            if ([NativeMouse]::GetWindowRect($hwnd, [ref]$rect)) {
                $left = $rect.Left + $ZonePadding
                $top = $rect.Top + $ZonePadding
                $maxWidth = ($rect.Right - $rect.Left) - ($ZonePadding * 2)
                $maxHeight = ($rect.Bottom - $rect.Top) - ($ZonePadding * 2)
                $width = [Math]::Max(80, [Math]::Min($ZoneWidth, $maxWidth))
                $height = [Math]::Max(60, [Math]::Min($ZoneHeight, $maxHeight))
            }
        }
    } catch {
    }

    return @{
        Left = [int]$left
        Top = [int]$top
        Width = [int]$width
        Height = [int]$height
    }
}

function Get-RandomPointInZone {
    param([hashtable]$Zone)
    $x = Get-Random -Minimum $Zone.Left -Maximum ($Zone.Left + $Zone.Width)
    $y = Get-Random -Minimum $Zone.Top -Maximum ($Zone.Top + $Zone.Height)
    return @{ X = [int]$x; Y = [int]$y }
}

function Move-Smooth {
    param(
        [int]$TargetX,
        [int]$TargetY,
        [int]$DurationMs = 700
    )

    $pos = New-Object NativeMouse+POINT
    [void][NativeMouse]::GetCursorPos([ref]$pos)
    $startX = [double]$pos.X
    $startY = [double]$pos.Y
    $steps = [Math]::Max(12, [int]($DurationMs / 16))

    for ($i = 1; $i -le $steps; $i++) {
        if (Test-HumanMovedMouse) { return $false }

        $t = [double]$i / [double]$steps
        $ease = $t * $t * (3 - 2 * $t)
        $jitterX = (Get-Random -Minimum -1.0 -Maximum 1.0) * 0.35
        $jitterY = (Get-Random -Minimum -1.0 -Maximum 1.0) * 0.35
        $nextX = [int]($startX + (($TargetX - $startX) * $ease) + $jitterX)
        $nextY = [int]($startY + (($TargetY - $startY) * $ease) + $jitterY)
        [void][NativeMouse]::SetCursorPos($nextX, $nextY)
        $script:lastKnownX = $nextX
        $script:lastKnownY = $nextY
        Start-Sleep -Milliseconds 16
    }
    return $true
}

function Get-RemainingSeconds {
    $elapsed = ((Get-Date) - $script:startTime).TotalSeconds
    return [Math]::Max(0, $script:durationSeconds - [int][Math]::Floor($elapsed))
}

function Format-RemainingTime {
    $remaining = Get-RemainingSeconds
    $h = [Math]::Floor($remaining / 3600)
    $m = [Math]::Floor(($remaining % 3600) / 60)
    $s = $remaining % 60
    if ($h -gt 0) { return "{0}h {1}m" -f $h, $m }
    if ($m -gt 0) { return "{0}m {1}s" -f $m, $s }
    return "{0}s" -f $s
}

function Test-TimeRemaining {
    return (Get-RemainingSeconds) -gt 0
}

function Wait-WithHumanCheck {
    param([int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline -and (Test-TimeRemaining)) {
        Start-Sleep -Milliseconds 500
        [void][NativeMouse]::SetThreadExecutionState(
            [NativeMouse]::ES_CONTINUOUS -bor
            [NativeMouse]::ES_SYSTEM_REQUIRED -bor
            [NativeMouse]::ES_DISPLAY_REQUIRED
        )
    }
}

function Start-MouseMover {
    $zone = Get-ZoneBounds
    Write-Host "  Zone: $($zone.Width)x$($zone.Height) near this window" -ForegroundColor Gray
    Write-Host "  Pattern: move 3-5s, pause 30-55s, human override aware" -ForegroundColor Gray
    Write-Host "  Press Ctrl+C to stop early." -ForegroundColor Yellow
    Write-Host ""

    [void][NativeMouse]::SetThreadExecutionState(
        [NativeMouse]::ES_CONTINUOUS -bor
        [NativeMouse]::ES_SYSTEM_REQUIRED -bor
        [NativeMouse]::ES_DISPLAY_REQUIRED
    )

    Save-CursorPosition

    $cycle = 0
    while (Test-TimeRemaining) {
        $cycle++

        if (Test-HumanMovedMouse) {
                $ts = Get-Date -Format 'HH:mm:ss'
            $rem = Format-RemainingTime
            Write-Host "  [$ts] Human active - deferring, $rem left" -ForegroundColor Magenta
            Save-CursorPosition
            Wait-WithHumanCheck -Seconds 10
            continue
        }

        $moveFor = Get-Random -Minimum 3 -Maximum 6
            $ts = Get-Date -Format 'HH:mm:ss'
            $rem = Format-RemainingTime
            Write-Host "  [$ts] Cycle $cycle moving (${moveFor}s), $rem left" -ForegroundColor DarkCyan

        $humanTookOver = $false
        $moveUntil = (Get-Date).AddSeconds($moveFor)
        while ((Get-Date) -lt $moveUntil -and (Test-TimeRemaining)) {
            $point = Get-RandomPointInZone -Zone $zone
            $completed = Move-Smooth -TargetX $point.X -TargetY $point.Y -DurationMs (Get-Random -Minimum 550 -Maximum 1050)
            if ($completed -eq $false) {
                $humanTookOver = $true
                break
            }
        }

        if ($humanTookOver) {
            $ts = Get-Date -Format 'HH:mm:ss'
            Write-Host "  [$ts] Human took over mid-move - yielding" -ForegroundColor Magenta
            Save-CursorPosition
            Wait-WithHumanCheck -Seconds 10
            continue
        }

        if (-not (Test-TimeRemaining)) { break }

        Save-CursorPosition

        $pauseFor = Get-Random -Minimum 30 -Maximum 56
            $ts = Get-Date -Format 'HH:mm:ss'
            $rem = Format-RemainingTime
            Write-Host "  [$ts] Pausing ${pauseFor}s, $rem left" -ForegroundColor Yellow
        Wait-WithHumanCheck -Seconds $pauseFor
    }

    Write-Host ""
    Write-Host "  Finished. Duration complete." -ForegroundColor Green
}

try {
    Start-MouseMover
} finally {
    [void][NativeMouse]::SetThreadExecutionState([NativeMouse]::ES_CONTINUOUS)
    Write-Host "  Sleep settings restored." -ForegroundColor Gray
    Write-Host ""
}

# SIG # Begin signature block
# MIIcIwYJKoZIhvcNAQcCoIIcFDCCHBACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBsbIT7eR31lz0q
# SyFfCU1gvFCV+ov/pEgtce35JIENOqCCFmAwggMiMIICCqADAgECAhAUQNiZp7Ch
# vEqhbsquXu7GMA0GCSqGSIb3DQEBCwUAMCkxJzAlBgNVBAMMHkxvY2FsIE1vdXNl
# IE1vdmVyIENvZGUgU2lnbmluZzAeFw0yNjAzMDQwMDQ1NDZaFw0yNzAzMDQwMTA1
# NDZaMCkxJzAlBgNVBAMMHkxvY2FsIE1vdXNlIE1vdmVyIENvZGUgU2lnbmluZzCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMTxIFWi/GAx2EGZs7OyXnUn
# OfFK4Rl+9+r2bPNNKPGvB2z3YQFV+Cq9ChN7M+P3MzHkRC1KTmVFAT9DA3YgN9M0
# 6jYoOfPwVbN2FLWBAx7q3FJLxIScqCHQMqYX0u+mOslzFb1BscNqpSoNUgR9SgPJ
# AhhLS0Hjv1+pRyrzdoSDzQ6h/lK/Xw01QQQ6CXZQAbRxncitEwlHg+KOw0p+Pw17
# BlB8vrLdprbUb3q1J5lJ2t1Yb0Ll7DzCTSDyxBJmjS14YOHBkEmhvWmrTIRv9O/b
# A+0PxI6poZ5MThIjSOdgtjZWQSzB21CL46sNweGqAJQVWSB3upxsOQIxVJd16R0C
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBTAw/V5/geFFf+8ufUwhIWYX97jMTANBgkqhkiG9w0BAQsFAAOCAQEA
# maTR1UzWTFfymX7QVoZVk1NTCpmWEtVr3jSK/SNS2q2ZbPv6wunliRL8rvg+40z9
# 2Dr9qZJZjImdd7/z8ckmFtAN+cGS4fPe5O0w1ACQmGthhKg4j61sl5NrsIt5nGVE
# og6EJybT3o0YfTk0fL5WlcQs4m+bYnINr0QJxU/2HtVi14LDIznIITAtMLHt2TsA
# XN7lLypMM7bC5y71NZdttqTyvIr6WPk9WYqHiRPz5JNr9gcZDiCMV7tAMpYm0tqg
# glml0ZUpZjxIsT4zQugrSe3d2fjULKPfMdrXlOUA50AOJ4gfp0lQ1GezO8Txw056
# FR9m6HW+0WNAafieMGDVoDCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFow
# DQYJKoZIhvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNl
# cnQgQXNzdXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIz
# NTk1OVowYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcG
# A1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3Rl
# ZCBSb290IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2je
# u+RdSjwwIjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bG
# l20dq7J58soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBE
# EC7fgvMHhOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/N
# rDRAX7F6Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A
# 2raRmECQecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8
# IUzUvK4bA3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfB
# aYh2mHY9WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaa
# RBkrfsCUtNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZi
# fvaAsPvoZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXe
# eqxfjT/JvNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g
# /KEexcCPorF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQY
# MBaAFEXroq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEF
# BQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBD
# BggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1Ud
# IAQKMAgwBgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22
# Ftf3v1cHvZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih
# 9/Jy3iS8UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYD
# E3cnRNTnf+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c
# 2PR3WlxUjG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88n
# q2x2zm8jLfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5
# lDCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAw
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysdduj
# Rmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S
# 9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+
# 42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg6
# 2IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21
# Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8
# y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQ
# NfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gao
# u30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6g
# qztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJD
# psZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D
# 8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC
# 0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6F
# TGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mC
# efSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57m
# QfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9
# ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dB
# wp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdq
# fMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2
# puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAO
# k5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL
# 0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBun
# vAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE
# 1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNV
# BAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNl
# cnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBD
# QTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNI
# QTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHf
# yjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPx
# NyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpk
# BaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFv
# ZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1zn
# OM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8f
# cpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ah
# fvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUD
# y9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9
# w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTn
# nkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKa
# cJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7
# /PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ
# 7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYI
# KwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0Ex
# LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcN
# AQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF
# 0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKq
# dT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbU
# UO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTe
# HihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG
# 7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NB
# qycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6
# +iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaA
# yBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyP
# ehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3F
# NwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIFGTCC
# BRUCAQEwPTApMScwJQYDVQQDDB5Mb2NhbCBNb3VzZSBNb3ZlciBDb2RlIFNpZ25p
# bmcCEBRA2JmnsKG8SqFuyq5e7sYwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGC
# NwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgo7rdbM9H
# gaKlwhoOLF26g9HQ0SoCn1aEVLVyBDytw8MwDQYJKoZIhvcNAQEBBQAEggEAi20y
# hngxOO09wzx1C75ox9Q7lQEnHMlhv5Nx0Gty8yomOd42Oij9IxwgEkxQv8TPSPKE
# JIS33sSE7/B5ZEIL5XdzVsT0OX/IbathCNX5bt1r7xHM9CssD7D2x1D1p7s+NwIf
# L5dhJabwYUnM0i3EizzDQEEWwuYsF2DiRb5Vjnk+yWyVCRXCJsbHb7KCRelRToa4
# FJwB7fQx7JEGlXaGuLybSwG0g3UNUZAidy1BAbKXQKNOmJmcZkAqKpj8WVKsUat2
# p2AuRlG9/QzJXs4xq+ioSICI9lXJxGXERgcorR91DXUR9XJDlWRc5Kz/HhUGezih
# wfxHcSOQMgV9/w2cEqGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkq
# hkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA0MDgwNzAy
# NDlaMC8GCSqGSIb3DQEJBDEiBCCxQCeJpB4BnIJWGVVp/MiVd8F6I0i7zesnkWK2
# JpwqfTANBgkqhkiG9w0BAQEFAASCAgBL27T7gh5JNpfSucGt6N6cf4IgSNIB91m5
# sdFUybgq/ZF4kLSVksAbUJnQ/es85KlTwq+V8AMsYpCug/O36dH4RgRx2hmkVa8n
# Qi2lV4Wh62GKHWiYs8p73lVaX8kFpudmI5J83526EnHbrf987n4LBOfEuC5RaIUe
# adWb1U9Q2o0cbsoZ/+MDx3Wc+PnroTrzQcwqYypHRoFtcVzTuquo2PE9Txmpp6HH
# 24lz8D1FCKg47UdJ+HW3p7n6yEBTlP8qdvNyrGyL+Q6+RNi+gpCymEkzxQhjRLeo
# 2FVlIHDqoq7fznyu8CdErQX33gWJBqhS3B+FctDQtiCClAvUUzfVxnKgqvPDlYB1
# VSEJAXMNrTIssO/D7x50WOlQd0/08uhJRUfHGOacEjP3TTYnUrJrAdu/te/V7jgN
# oWTKw7ZsLpPcVEF80OtiDyIChWO9NkEpfNuXPSxjaMwS35VSHx0JP4Njw6PUBQej
# CjDq+oUBbXNc3X+zmF+hGU0KyirzK3jTBXd9AHWOkEqE0X0E9FCxotT5nBGvCCAQ
# f2ES1V5CmFp4b0i+JYe8DGtgb7L2xTH+YWEZbJcu4Y5gtquPZeTdr4EMeUyCqkk8
# 5DFVrg/s083lpbcjgSWiaGykcfGov5Z7BWS7xItqXYDuM5NUwhp22zGs0FJ+Ikcv
# KlpwO549dQ==
# SIG # End signature block
