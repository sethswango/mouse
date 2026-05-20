<#
.SYNOPSIS
    Locally generated mouse mover that keeps the session awake.
    All operational logic runs as compiled .NET to avoid PowerShell command logging.
    Only the shell (prompt + banner) generates PS log entries.
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
    $durationHours = 0.5
} else {
    try {
        $durationHours = [double]$durationInput
        if ($durationHours -le 0) { $durationHours = 0.5 }
    } catch {
        $durationHours = 0.5
    }
}

$endTime = (Get-Date).AddHours($durationHours)
Write-Host "  Running for $durationHours hour(s), until $($endTime.ToString('h:mm:ss tt'))" -ForegroundColor Green
Write-Host ""

$moverCode = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class MouseMover
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint esFlags);

    private const uint ES_CONTINUOUS = 0x80000000;
    private const uint ES_SYSTEM_REQUIRED = 0x00000001;
    private const uint ES_DISPLAY_REQUIRED = 0x00000002;

    private static Random rng = new Random();
    private static int lastKnownX = -1;
    private static int lastKnownY = -1;
    private static int humanThreshold = 8;

    private static int zoneLeft;
    private static int zoneTop;
    private static int zoneWidth;
    private static int zoneHeight;

    public static void Run(double durationSeconds, int configZoneWidth, int configZoneHeight, int configZonePadding, int configHumanThreshold)
    {
        humanThreshold = configHumanThreshold;
        DateTime endTime = DateTime.Now.AddSeconds(durationSeconds);

        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        ComputeZone(configZoneWidth, configZoneHeight, configZonePadding);
        SaveCursorPosition();

        Console.ForegroundColor = ConsoleColor.Gray;
        Console.WriteLine("  Zone: " + zoneWidth + "x" + zoneHeight + " near this window");
        Console.WriteLine("  Pattern: brief move every ~30s, human override aware");
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("  Press Ctrl+C to stop early.");
        Console.ResetColor();
        Console.WriteLine();

        int cycle = 0;
        try
        {
            while (DateTime.Now < endTime)
            {
                cycle++;

                if (HumanMovedMouse())
                {
                    int remMin = (int)((endTime - DateTime.Now).TotalMinutes);
                    Console.ForegroundColor = ConsoleColor.Magenta;
                    Console.WriteLine("  [" + DateTime.Now.ToString("HH:mm:ss") + "] Human active - deferring, ~" + remMin + "m left");
                    Console.ResetColor();
                    SaveCursorPosition();
                    Thread.Sleep(30000);
                    continue;
                }

                int remMin2 = (int)((endTime - DateTime.Now).TotalMinutes);
                Console.ForegroundColor = ConsoleColor.DarkCyan;
                Console.WriteLine("  [" + DateTime.Now.ToString("HH:mm:ss") + "] Cycle " + cycle + ", ~" + remMin2 + "m left");
                Console.ResetColor();

                int targetX = rng.Next(zoneLeft, zoneLeft + zoneWidth);
                int targetY = rng.Next(zoneTop, zoneTop + zoneHeight);

                bool completed = MoveSmooth(targetX, targetY);

                if (!completed)
                {
                    Console.ForegroundColor = ConsoleColor.Magenta;
                    Console.WriteLine("  [" + DateTime.Now.ToString("HH:mm:ss") + "] Human took over - yielding");
                    Console.ResetColor();
                    SaveCursorPosition();
                    Thread.Sleep(30000);
                    continue;
                }

                if (DateTime.Now >= endTime) break;

                SaveCursorPosition();
                int pauseMs = rng.Next(25000, 36001);
                Thread.Sleep(pauseMs);
            }
        }
        finally
        {
            SetThreadExecutionState(ES_CONTINUOUS);
        }

        Console.WriteLine();
        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine("  Finished. Duration complete.");
        Console.ForegroundColor = ConsoleColor.Gray;
        Console.WriteLine("  Sleep settings restored.");
        Console.ResetColor();
        Console.WriteLine();
    }

    private static void ComputeZone(int configWidth, int configHeight, int padding)
    {
        int screenWidth = GetSystemMetrics(0);
        int screenHeight = GetSystemMetrics(1);
        zoneLeft = 100;
        zoneTop = 100;
        zoneWidth = Math.Min(configWidth, Math.Max(80, screenWidth - 200));
        zoneHeight = Math.Min(configHeight, Math.Max(60, screenHeight - 200));

        try
        {
            IntPtr hwnd = GetConsoleWindow();
            if (hwnd != IntPtr.Zero)
            {
                RECT rect;
                if (GetWindowRect(hwnd, out rect))
                {
                    zoneLeft = rect.Left + padding;
                    zoneTop = rect.Top + padding;
                    int maxW = (rect.Right - rect.Left) - (padding * 2);
                    int maxH = (rect.Bottom - rect.Top) - (padding * 2);
                    zoneWidth = Math.Max(80, Math.Min(configWidth, maxW));
                    zoneHeight = Math.Max(60, Math.Min(configHeight, maxH));
                }
            }
        }
        catch { }
    }

    private static bool MoveSmooth(int targetX, int targetY)
    {
        POINT pos;
        GetCursorPos(out pos);
        double startX = pos.X;
        double startY = pos.Y;
        int steps = 15;

        for (int i = 1; i <= steps; i++)
        {
            if (i % 5 == 0 && HumanMovedMouse()) return false;

            double t = (double)i / steps;
            double ease = t * t * (3.0 - 2.0 * t);
            int nextX = (int)(startX + ((targetX - startX) * ease));
            int nextY = (int)(startY + ((targetY - startY) * ease));
            SetCursorPos(nextX, nextY);
            lastKnownX = nextX;
            lastKnownY = nextY;
            Thread.Sleep(50);
        }
        return true;
    }

    private static bool HumanMovedMouse()
    {
        if (lastKnownX == -1) return false;
        POINT pos;
        GetCursorPos(out pos);
        int dx = Math.Abs(pos.X - lastKnownX);
        int dy = Math.Abs(pos.Y - lastKnownY);
        return (dx > humanThreshold || dy > humanThreshold);
    }

    private static void SaveCursorPosition()
    {
        POINT pos;
        GetCursorPos(out pos);
        lastKnownX = pos.X;
        lastKnownY = pos.Y;
    }
}
'@

try {
    Add-Type -TypeDefinition $moverCode -ErrorAction Stop
} catch {
    if ($_.Exception.Message -notlike "*already exists*") { throw }
}

$durationSeconds = [Math]::Round($durationHours * 3600)
[MouseMover]::Run($durationSeconds, $ZoneWidth, $ZoneHeight, $ZonePadding, $HumanThresholdPx)

# SIG # Begin signature block
# MIIcIwYJKoZIhvcNAQcCoIIcFDCCHBACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCiBlImOZAOXNi3
# ZDu0I+p9i/U5tUF0UepeG2F9qxBbIKCCFmAwggMiMIICCqADAgECAhAUQNiZp7Ch
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgaCDT4YBS
# hgxUJAo2xQ3RZNWUelnBMwmIxl3M1cIT2QcwDQYJKoZIhvcNAQEBBQAEggEAA3zB
# 8gxnfxB/zoHw6N8EqVhI3bWN6IP5z+5tT+BRmZchdYzTv1BD0cEL0pdn9xGcUB6U
# G0H6Z9CnleioRqSzCxfBXThvnVRbBUuRU7BdmnfFzbiSgTr+4k0g6e0ffLldnHsV
# tJtAiZeeNSLuzwhhnqr3MRg7mm+9OtWpzgcWagMW3aw5WP6i8YXHOjH44kG7E3sm
# WORamtOKROKAD2yvRe2ajz3PyFfxdjoQBlXaWJqCPxKTZoIuB4A1KCk/iQomHEHQ
# NHDPfjXOOd2YBiMJwXHXM2LutrbAClyFMIUj+7pHDiUK3X2RqzIAwwFBc1AtQnkC
# TUl6rghNjxZ6kyHnO6GCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkq
# hkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA1MjAxOTI5
# NTdaMC8GCSqGSIb3DQEJBDEiBCBzDo0zyUneLRHknBXQC/Kefzs4P2Yoj0FgDf9C
# sY0BnDANBgkqhkiG9w0BAQEFAASCAgAR3JuDER4n6szA7hxO4VrzRslb43cWrFow
# GQ5gVNyvZKaXxb/a+NQKj8fCUBN2zJ20Eb5313HUzP9+O8uFNBz1NR8vyjK/fHcP
# 7uXShNDt7VcxTfeRoRLwV1rQLQUw0Kct5YU66GZNSGiYYUMhAHh0NryMKSPtJlC8
# FfA7dzmezYdf7H/xoMgEjvTc5foq37zMncxWgLuBuMXWPmQcI0tkNOHyPi7nhjHb
# z7Cp83NtLBIS9GufXC3k6dZNYwR2rl4+azEiUnRNLvvaOqu1BvFChR+FoeDKpdPO
# 2YWsplv5M0WmaKkYX4p+6hWqExBDfWERoOaFHYv5NYKVuXijgeC/uIN3KCw4JZJg
# uCA0Ib9U7z9HrWzxZUkn+4QxQqGZCxryysAAKFW0k77vcyrGT+zV3DO0CaxQy54I
# M28UhdDbq1sAi5TOxw1MP6qVTxopHh6ulJJZWSeRGXdcxlDDaE29B9YgcSIQJl2Z
# 7EeoRzPbe/bgOeLOsXWkC0QolaW3lDbS692xUlFDNyuxmBuYj4KSyRV+e+XCmLi8
# iM60qOnwynNUUcD3+f/+TZhJutBXlMWJ86HaeKK6vLimu8vsyegX/T99E5OnFyJC
# XDfwdAdgGH7J+EDptv6lFFmh4u8aXPSS3cem3XZSCXNOZJ+fXE77aUP8F8iVO4wB
# MkAv4fw1GQ==
# SIG # End signature block
