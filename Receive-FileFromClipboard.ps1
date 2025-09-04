<#
.SYNOPSIS
    Receives a file from the clipboard using a streaming approach.
.DESCRIPTION
    Continuously polls the clipboard for file chunks and writes them directly
    to a file stream, reassembling the file on the fly. This version is
    compatible with the two-tiered sender.
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
$expectedClipboardChunk = 1

Write-Log "Receiver started. Monitoring clipboard for streamed file..." -Color Green
if ($ExitOnComplete) { Write-Log "Script will exit after the next successful transfer." -Color Yellow }
else { Write-Log "Press CTRL+C to stop." -Color Yellow }

while ($true) {
    try {
        $clipboardContent = [System.Windows.Forms.Clipboard]::GetText()
        
        if ($clipboardContent -and $clipboardContent -ne $lastClipboardContent) {
            $lastClipboardContent = $clipboardContent
            $payload = $null

            try { $payload = $clipboardContent | ConvertFrom-Json } catch { continue }

            if ($payload -and $payload.filename -and $payload.hash -and $payload.clipboard_chunk_number) {
                
                # --- SESSION INITIALIZATION (FIRST CHUNK) ---
                if (-not $session.filename) {
                    # Basic validation of the first chunk
                    if ($payload.clipboard_chunk_number -ne 1) {
                        Write-Log "Ignoring out-of-order chunk. Waiting for chunk #1 to start." -Color Magenta
                        continue
                    }

                    $session.filename = $payload.filename
                    $session.hash = $payload.hash
                    $session.total_clipboard_chunks = $payload.total_clipboard_chunks

                    $session.temp_path = Join-Path $OutputDir "$($session.filename).incomplete"
                    $session.final_path = Join-Path $OutputDir $session.filename

                    if (Test-Path $session.temp_path) { Remove-Item $session.temp_path }
                    if (Test-Path $session.final_path) { Remove-Item $session.final_path }

                    $session.file_stream = [System.IO.FileStream]::new($session.temp_path, [System.IO.FileMode]::Create)

                    Write-Log "Receiving new file: $($session.filename) ($($session.total_clipboard_chunks) clipboard chunks)" -Color Cyan
                }

                # --- CHUNK PROCESSING ---
                $clipboardChunkNumber = $payload.clipboard_chunk_number

                # Process only the chunk we are expecting, ensuring in-order assembly
                if ($clipboardChunkNumber -eq $expectedClipboardChunk) {
                    $logMsg = "Received Clipboard Chunk $clipboardChunkNumber/$($session.total_clipboard_chunks) (from Dividing Chunk $($payload.dividing_chunk_number)/$($payload.total_dividing_chunks))"
                    Write-Log $logMsg

                    $chunkBytes = [System.Convert]::FromBase64String($payload.data)
                    $session.file_stream.Write($chunkBytes, 0, $chunkBytes.Length)

                    $expectedClipboardChunk++
                }
                
                # Always ACK the chunk number received, sender will handle retries if we miss one
                $ackMessage = "ACK $clipboardChunkNumber"
                [System.Windows.Forms.Clipboard]::SetText($ackMessage)
                # Write-Log "Sent acknowledgement: '$ackMessage'" -Color DarkGray # Reduce log noise

                # --- FINALIZATION ---
                if ($clipboardChunkNumber -eq $session.total_clipboard_chunks -and $expectedClipboardChunk -gt $session.total_clipboard_chunks) {
                    Write-Log "All chunks received! Finalizing file..." -Color Cyan

                    $session.file_stream.Close()
                    $session.file_stream.Dispose()
                    
                    $reassembledHash = (Get-FileHash -Path $session.temp_path -Algorithm SHA256).Hash
                    if ($reassembledHash -eq $session.hash) {
                        Write-Log "✅ SUCCESS: Hash matches! File transfer successful." -Color Green
                        Rename-Item -Path $session.temp_path -NewName $session.filename
                        
                        if ($ExitOnComplete) {
                            Write-Log "Exiting as requested." -Color Green
                            break # Exit the 'while ($true)' loop
                        }
                    } else {
                        Write-Log "❌ FAILURE: Hash mismatch! Expected $($session.hash), got $reassembledHash" -Color Red
                        Remove-Item $session.temp_path -Force
                    }

                    # Reset for next transfer
                    $session = @{}
                    $expectedClipboardChunk = 1
                }
            }
        }
    } catch {
        Write-Log "An error occurred: $($_.Exception.Message)" -Color Red
        # Clean up on error
        if ($session.file_stream) { $session.file_stream.Dispose() }
        if ($session.temp_path -and (Test-Path $session.temp_path)) { Remove-Item $session.temp_path -Force }
        $session = @{}
        $expectedClipboardChunk = 1
    }
    
    Start-Sleep -Milliseconds 100
}