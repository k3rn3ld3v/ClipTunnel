<#
.SYNOPSIS
    Receives a file from the clipboard in chunks.
.DESCRIPTION
    Continuously polls the clipboard for file chunks and reassembles them.
    Can optionally exit after a successful transfer.
.PARAMETER OutputDir
    The directory where the final reassembled file will be saved.
.PARAMETER ExitOnComplete
    If specified, the script will automatically exit after one successful file transfer.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutputDir,

    [switch]$ExitOnComplete
)

# --- FIX 1: Set the output encoding to UTF-8 to correctly display emojis ---
$OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

$session = @{}
$lastClipboardContent = ""

Write-Log "Receiver started. Monitoring clipboard..." -Color Green
if ($ExitOnComplete) { Write-Log "Script will exit after the next successful transfer." -Color Yellow }
else { Write-Log "Press CTRL+C to stop." -Color Yellow }

while ($true) {
    try {
        $clipboardContent = [System.Windows.Forms.Clipboard]::GetText()
        
        if ($clipboardContent -and $clipboardContent -ne $lastClipboardContent) {
            $lastClipboardContent = $clipboardContent
            $payload = $null

            try { $payload = $clipboardContent | ConvertFrom-Json } catch { continue }

            if ($payload -and $payload.filename -and $payload.hash) {
                
                if (-not $session.filename) {
                    $session.filename = $payload.filename
                    $session.hash = $payload.hash
                    $session.total_chunks = $payload.total_chunks
                    $session.temp_dir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
                    $session.chunks_received = @{}
                    New-Item -Path $session.temp_dir -ItemType Directory | Out-Null
                    Write-Log "Receiving new file: $($session.filename)" -Color Cyan
                }

                $chunkNumber = $payload.chunk_number
                if (-not $session.chunks_received.ContainsKey($chunkNumber)) {
                    Write-Log "Received chunk $chunkNumber/$($session.total_chunks)"
                    $chunkBytes = [System.Convert]::FromBase64String($payload.data)
                    $chunkPath = Join-Path $session.temp_dir "chunk_$($chunkNumber.ToString('00000')).bin"
                    [System.IO.File]::WriteAllBytes($chunkPath, $chunkBytes)
                    $session.chunks_received[$chunkNumber] = $true
                }
                
                $ackMessage = "ACK $chunkNumber"
                [System.Windows.Forms.Clipboard]::SetText($ackMessage)
                Write-Log "Sent acknowledgement: '$ackMessage'" -Color Yellow

                if ($session.chunks_received.Count -eq $session.total_chunks) {
                    Write-Log "All chunks received! Reassembling file..." -Color Cyan
                    $finalFilePath = Join-Path $OutputDir $session.filename
                    if (Test-Path $finalFilePath) { Remove-Item $finalFilePath }

                    $fileStream = [System.IO.FileStream]::new($finalFilePath, [System.IO.FileMode]::Create)
                    Get-ChildItem -Path $session.temp_dir | Sort-Object Name | ForEach-Object {
                        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                        $fileStream.Write($bytes, 0, $bytes.Length)
                    }
                    $fileStream.Close(); $fileStream.Dispose()
                    
                    $reassembledHash = (Get-FileHash -Path $finalFilePath -Algorithm SHA256).Hash
                    if ($reassembledHash -eq $session.hash) {
                        Write-Log "✅ SUCCESS: Hash matches! File transfer successful." -Color Green
                        
                        # --- FIX 2: Check for the -ExitOnComplete switch ---
                        if ($ExitOnComplete) {
                            Write-Log "Exiting as requested." -Color Green
                            break # Exit the 'while ($true)' loop
                        }
                    } else {
                        Write-Log "❌ FAILURE: Hash mismatch!" -Color Red
                    }

                    Remove-Item -Path $session.temp_dir -Recurse -Force
                    $session = @{}
                }
            }
        }
    } catch {
        Write-Log "An error occurred: $($_.Exception.Message)" -Color Red
    }
    
    Start-Sleep -Milliseconds 100
}