<#
.SYNOPSIS
    ClipTunnel Receiver (with Part Reassembly)
.DESCRIPTION
    Receives file chunks from the clipboard. Automatically handles multi-part
    archives, reassembling parts first, then combining them into the final file
    before hash verification.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutputDir,
    [switch]$ExitOnComplete
)

$OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms

function Write-Log { param([string]$Message, [string]$Color="White") { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color } }
if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory | Out-Null }

# --- ENHANCED STATE MANAGEMENT ---
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
            try { $payload = $clipboardContent | ConvertFrom-Json } catch { continue }

            if ($payload -and $payload.base_filename) {
                # --- Part 1: Initialize Session on first-ever chunk ---
                if (-not $session.base_filename) {
                    $session = @{
                        base_filename    = $payload.base_filename
                        hash             = $payload.hash
                        total_parts      = $payload.total_parts
                        main_temp_dir    = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
                        parts_completed  = @{}
                        current_part     = $null
                    }
                    New-Item -Path $session.main_temp_dir -ItemType Directory | Out-Null
                    Write-Log "Receiving new file: $($session.base_filename) ($($session.total_parts) parts total)" -Color Cyan
                }

                # --- Part 2: Handle the current part's chunks ---
                if (($null -eq $session.current_part) -or ($session.current_part.part_filename -ne $payload.part_filename)) {
                    $session.current_part = @{
                        part_filename = $payload.part_filename
                        part_number   = $payload.part_number
                        total_chunks  = $payload.total_chunks
                        chunk_temp_dir= Join-Path $session.main_temp_dir "part_$($payload.part_number)"
                        chunks_saved  = @{}
                    }
                    New-Item -Path $session.current_part.chunk_temp_dir -ItemType Directory | Out-Null
                    Write-Log "Receiving Part $($payload.part_number)/$($session.total_parts): $($payload.part_filename)" -Color Magenta
                }
                
                $chunkNumber = $payload.chunk_number
                if (-not $session.current_part.chunks_saved.ContainsKey($chunkNumber)) {
                    Write-Log "Saving Part $($payload.part_number) Chunk $chunkNumber/$($session.current_part.total_chunks)..."
                    $chunkBytes = [System.Convert]::FromBase64String($payload.data)
                    $chunkPath = Join-Path $session.current_part.chunk_temp_dir "chunk_$($chunkNumber.ToString('00000')).bin"
                    [System.IO.File]::WriteAllBytes($chunkPath, $chunkBytes)
                    $session.current_part.chunks_saved[$chunkNumber] = $true
                }

                # --- Send ACK (now includes Part and Chunk number) ---
                $ackMessage = "ACK P$($payload.part_number)C$($chunkNumber)"
                [System.Windows.Forms.Clipboard]::SetText($ackMessage)
                
                # --- Part 3: Reassemble the CURRENT PART if all its chunks are received ---
                if ($session.current_part.chunks_saved.Count -eq $session.current_part.total_chunks) {
                    Write-Log "All chunks for Part $($session.current_part.part_number) received. Reassembling part..." -Color Yellow
                    $reassembledPartPath = Join-Path $session.main_temp_dir $session.current_part.part_filename
                    $fileStream = [System.IO.FileStream]::new($reassembledPartPath, [System.IO.FileMode]::Create)
                    Get-ChildItem -Path $session.current_part.chunk_temp_dir | Sort-Object Name | ForEach-Object {
                        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                        $fileStream.Write($bytes, 0, $bytes.Length)
                    }
                    $fileStream.Close(); $fileStream.Dispose()
                    
                    Remove-Item -Path $session.current_part.chunk_temp_dir -Recurse -Force
                    $session.parts_completed[$session.current_part.part_number] = $true
                    $session.current_part = $null # Reset to receive the next part
                    Write-Log "Part reassembled successfully." -Color Green
                }

                # --- Part 4: Reassemble the FINAL ARCHIVE if all parts are completed ---
                if ($session.parts_completed.Count -eq $session.total_parts) {
                    Write-Log "All parts received! Reassembling final archive..." -Color Cyan
                    $finalFilePath = Join-Path $OutputDir $session.base_filename
                    if (Test-Path $finalFilePath) { Remove-Item $finalFilePath }

                    $fileStream = [System.IO.FileStream]::new($finalFilePath, [System.IO.FileMode]::Create)
                    Get-ChildItem -Path $session.main_temp_dir -Filter "*.split.*" | Sort-Object Name | ForEach-Object {
                        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                        $fileStream.Write($bytes, 0, $bytes.Length)
                    }
                    $fileStream.Close(); $fileStream.Dispose()
                    
                    # --- Final Hash Verification ---
                    $reassembledHash = (Get-FileHash -Path $finalFilePath -Algorithm SHA256).Hash
                    if ($reassembledHash -eq $session.hash) {
                        Write-Log "✅ SUCCESS: Hash matches! Final file is valid." -Color Green
                        if ($ExitOnComplete) { Write-Log "Exiting."; break }
                    } else { Write-Log "❌ FAILURE: Hash mismatch!" -Color Red }

                    Remove-Item -Path $session.main_temp_dir -Recurse -Force
                    $session = @{} # Reset for next transfer
                }
            }
        }
    } catch { Write-Log "An error occurred: $($_.Exception.Message)" -Color Red }
    Start-Sleep -Milliseconds 100
}