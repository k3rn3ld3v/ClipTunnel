<#
.SYNOPSIS
    ClipTunnel Sender (7z Edition - Two-Tier Chunks)
.DESCRIPTION
    Sends a file or folder over the clipboard using a two-tiered chunking system.
    The file is logically divided into large 'dividing chunks' for progress tracking,
    and these are sent as smaller 'clipboard chunks' to fit the clipboard buffer.

    This version requires the 7-Zip command-line tool (7z.exe) for compression.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [long]$DividingChunkSize = 20MB, # Size for logical file division
    [int]$ClipboardChunkSize = 1MB    # Size for the actual clipboard payload
)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

# --- PRE-FLIGHT CHECK: Find 7z.exe ---
Write-Log "Searching for 7z.exe..." -Color Yellow
$sevenZipPath = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source

if (-not $sevenZipPath) {
    Write-Log "7z.exe not found in PATH. Checking default installation directory..." -Color Yellow
    $defaultPath = "C:\Program Files\7-Zip\7z.exe"
    if (Test-Path $defaultPath) {
        Write-Log "Found 7z.exe at default location: $defaultPath" -Color Green
        $sevenZipPath = $defaultPath
    }
} else {
    Write-Log "Found 7z.exe in PATH: $sevenZipPath" -Color Green
}

if (-not $sevenZipPath) {
    Write-Log "FATAL: 7-Zip command-line tool (7z.exe) could not be found." -Color Red
    Write-Log "Please install 7-Zip to its default location or add its directory to the PATH." -Color Red
    return
}


# --- 1. PREPARE THE ARCHIVE ---
$sourceObject = Get-Item -Path $Path
$archivePath = ""

if (-not $sourceObject) {
    Write-Log "Error: Path '$Path' not found." -Color Red
    return
}

$needsArchiving = $true
$baseName = $sourceObject.Name
if ($sourceObject.Extension -eq ".7z") {
    Write-Log "Input is already a .7z archive. Using it directly." -Color Green
    $archivePath = $sourceObject.FullName
    $needsArchiving = $false
} else {
    Write-Log "Input will be archived using 7z.exe with LZMA2 compression." -Color Cyan
    $archivePath = Join-Path $env:TEMP "$baseName.7z"
}

if ($needsArchiving) {
    if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
    try {
        $arguments = "a -t7z -m0=lzma2 -mx=9 -mmt=on `"$archivePath`" `"$Path`""
        Write-Log "Executing: `"$sevenZipPath`" $arguments" -Color Yellow
        Start-Process -FilePath $sevenZipPath -ArgumentList $arguments -Wait -NoNewWindow
        if (-not (Test-Path $archivePath)) { throw "7z.exe failed to create the archive." }
        Write-Log "Successfully created 7z archive at '$archivePath'" -Color Green
    } catch {
        Write-Log "Error creating archive: $_" -Color Red
        return
    }
}

# --- 2. HASH THE FILE AND PREPARE FOR STREAMING ---
Write-Log "Computing SHA256 hash for '$archivePath'..." -Color Yellow
$fileHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
Write-Log "SHA256 Hash: $fileHash" -Color Green

$fileInfo = Get-Item -Path $archivePath
$fileSize = $fileInfo.Length
$archiveFileName = $fileInfo.Name

# Calculate total chunks for both tiers
$totalDividingChunks = [System.Math]::Ceiling($fileSize / $DividingChunkSize)
$totalClipboardChunks = [System.Math]::Ceiling($fileSize / $ClipboardChunkSize)

Write-Log "File size: $fileSize bytes." -Color Yellow
Write-Log "Logical divisions: $totalDividingChunks chunks of $DividingChunkSize bytes." -Color Yellow
Write-Log "Clipboard transfer: $totalClipboardChunks chunks of $ClipboardChunkSize bytes." -Color Yellow

# --- 3. STREAM CHUNKS WITH ACKNOWLEDGEMENT ---
$clipboardChunkNumber = 0
$bytesSent = 0
$fileStream = $null
try {
    $fileStream = New-Object System.IO.FileStream($archivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    $buffer = New-Object byte[] $ClipboardChunkSize

    while ($bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)) {
        if ($bytesRead -eq 0) { break }
        $clipboardChunkNumber++

        # Determine current dividing chunk
        $currentDividingChunk = [System.Math]::Floor($bytesSent / $DividingChunkSize) + 1

        $actualChunkBytes = if ($bytesRead -lt $buffer.Length) {
            $temp = New-Object byte[] $bytesRead
            [System.Array]::Copy($buffer, $temp, $bytesRead)
            $temp
        } else {
            $buffer
        }
        
        $chunkBase64 = [System.Convert]::ToBase64String($actualChunkBytes)

        $payload = @{
            filename                 = $archiveFileName
            hash                     = $fileHash
            dividing_chunk_number    = $currentDividingChunk
            total_dividing_chunks    = $totalDividingChunks
            clipboard_chunk_number   = $clipboardChunkNumber
            total_clipboard_chunks   = $totalClipboardChunks
            data                     = $chunkBase64
        } | ConvertTo-Json -Compress

        $ackReceived = $false
        while (-not $ackReceived) {
            $logMsg = "Sending Clipboard Chunk $clipboardChunkNumber/$totalClipboardChunks (Part of Dividing Chunk $currentDividingChunk/$totalDividingChunks)..."
            Write-Log $logMsg -Color Cyan
            Set-Clipboard -Value $payload

            $expectedAck = "ACK $clipboardChunkNumber"
            Write-Log "Waiting for acknowledgement: '$expectedAck'" -Color Yellow

            $timeout = 0
            while ($timeout -lt 300) {
                $clipboardContent = Get-Clipboard
                if ($clipboardContent -eq $expectedAck) {
                    Write-Log "ACK received for clipboard chunk $clipboardChunkNumber!" -Color Green
                    $ackReceived = $true
                    $bytesSent += $bytesRead
                    break
                }
                Start-Sleep -Milliseconds 200
                $timeout++
            }

            if (-not $ackReceived) {
                Write-Log "Timeout waiting for ACK for clipboard chunk $clipboardChunkNumber. Retrying..." -Color Red
            }
        }
    }
} finally {
    if ($fileStream -ne $null) {
        $fileStream.Close()
        $fileStream.Dispose()
    }
}

Write-Log "File transfer complete for '$archiveFileName'." -Color Green

if ($needsArchiving) {
    Remove-Item $archivePath -Force
    Write-Log "Cleaned up temporary archive."
}