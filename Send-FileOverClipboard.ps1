<#
.SYNOPSIS
    Sends a file or folder over the clipboard in chunks using tar.xz (LZMA) compression.
.DESCRIPTION
    This version is optimized for speed with a larger 768 KB chunk size, resulting
    in a ~1 MB clipboard payload per transfer.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    # OPTIMIZATION: Chunk size increased to 768 KB for much faster transfers.
    # This becomes ~1 MB of text after Base64 encoding.
    [int]$ChunkSize = 786432 # 768 KB
)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
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
if ($sourceObject.Extension -in ".xz", ".txz") {
    Write-Log "Input is already a .tar.xz archive. Using it directly." -Color Green
    $archivePath = $sourceObject.FullName
    $needsArchiving = $false
} else {
    Write-Log "Input will be archived using tar.exe with xz (LZMA) compression." -Color Cyan
    $archivePath = Join-Path $env:TEMP "$baseName.tar.xz"
}

if ($needsArchiving) {
    if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
    try {
        Write-Log "Creating archive: tar -cJf '$archivePath' -C '$(Split-Path $Path)' '$(Split-Path $Path -Leaf)'" -Color Yellow
        tar.exe -cJf $archivePath -C (Split-Path -Path $Path -Parent) $baseName
        Write-Log "Successfully created tar.xz archive at '$archivePath'" -Color Green
    } catch {
        Write-Log "Error creating archive: $_" -Color Red
        return
    }
}

# --- 2. HASH AND CHUNK THE FILE ---
Write-Log "Computing SHA26 hash for '$archivePath'..." -Color Yellow
$fileHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
Write-Log "SHA256 Hash: $fileHash" -Color Green

$fileBytes = [System.IO.File]::ReadAllBytes($archivePath)
$totalChunks = [System.Math]::Ceiling($fileBytes.Length / $ChunkSize)
$archiveFileName = Split-Path $archivePath -Leaf

Write-Log "File size: $($fileBytes.Length) bytes. Splitting into $totalChunks chunks." -Color Yellow

# --- 3. SEND CHUNKS WITH ACKNOWLEDGEMENT ---
for ($i = 0; $i -lt $totalChunks; $i++) {
    $chunkNumber = $i + 1
    $offset = $i * $ChunkSize
    $remainingBytes = $fileBytes.Length - $offset
    $currentChunkSize = [System.Math]::Min($ChunkSize, $remainingBytes)

    $chunkBytes = $fileBytes[$offset..($offset + $currentChunkSize - 1)]
    $chunkBase64 = [System.Convert]::ToBase64String($chunkBytes)

    $payload = @{
        filename     = $archiveFileName
        hash         = $fileHash
        chunk_number = $chunkNumber
        total_chunks = $totalChunks
        data         = $chunkBase64
    } | ConvertTo-Json -Compress

    $ackReceived = $false
    while (-not $ackReceived) {
        Write-Log "Sending chunk $chunkNumber/$totalChunks..." -Color Cyan
        Set-Clipboard -Value $payload
        
        $expectedAck = "ACK $chunkNumber"
        Write-Log "Waiting for acknowledgement: '$expectedAck'" -Color Yellow
        
        $timeout = 0
        while ($timeout -lt 300) {
            $clipboardContent = Get-Clipboard
            if ($clipboardContent -eq $expectedAck) {
                Write-Log "ACK received for chunk $chunkNumber!" -Color Green
                $ackReceived = $true
                break
            }
            Start-Sleep -Milliseconds 200
            $timeout++
        }

        if (-not $ackReceived) {
             Write-Log "Timeout waiting for ACK for chunk $chunkNumber. Retrying..." -Color Red
        }
    }
}

Write-Log "File transfer complete for '$archiveFileName'." -Color Green

if ($needsArchiving) {
    Remove-Item $archivePath -Force
    Write-Log "Cleaned up temporary archive."
}