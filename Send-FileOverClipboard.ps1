<#
.SYNOPSIS
    ClipTunnel Sender (7z Edition)
.DESCRIPTION
    Sends a file or folder over the clipboard in chunks. This version requires the
    7-Zip command-line tool (7z.exe) for compression. It will first look for 7z.exe
    in the system PATH, and if not found, will check the default install location.
#>
[CmdletBinding(DefaultParameterSetName='SingleFile')]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [int]$ChunkSize = 786432, # 768 KB

    [Parameter(Mandatory=$true, ParameterSetName='ByPart')]
    [switch]$ByPart,

    [Parameter(Mandatory=$true, ParameterSetName='ByPart')]
    [string]$PartSize
)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Parse-Size {
    param([string]$SizeStr)
    $SizeStr = $SizeStr.ToUpper().Trim()

    # Correctly separate the numeric value from the unit string.
    $valueStr = ($SizeStr -replace '[A-Z]').Trim()
    $unit = ($SizeStr -replace '[0-9. ]').Trim()

    if (-not $valueStr) {
        Write-Log "Invalid size string: $SizeStr" -Color Red
        return 0
    }
    $multiplier = 1
    switch ($unit) {
        "B"  { $multiplier = 1 }
        "KB" { $multiplier = 1KB }
        "MB" { $multiplier = 1MB }
        "GB" { $multiplier = 1GB }
        ""   { $multiplier = 1 } # Default to bytes if no unit
    }
    try {
        # Use the correctly isolated numeric string for parsing.
        return [int64]([double]::Parse($valueStr) * $multiplier)
    } catch {
        Write-Log "Failed to parse size string: '$SizeStr'. Could not parse value: '$valueStr'." -Color Red
        return 0
    }
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

# Archive the source using 7z.exe for ultra compression
if ($needsArchiving) {
    if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
    try {
        # a = add to archive
        # -t7z = archive type 7z
        # -m0=lzma2 = algorithm
        # -mx=9 = compression level (ultra)
        # -mmt=on = multi-threading on
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

function Send-File {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePathToSend,
        [Parameter(Mandatory=$true)]
        [int]$TransferChunkSize
    )

    $fileToSendName = Split-Path $FilePathToSend -Leaf
    Write-Log "Starting transfer process for '$fileToSendName'..." -Color Cyan

    # --- HASH AND CHUNK THE FILE ---
    Write-Log "Computing SHA256 hash for '$fileToSendName'..." -Color Yellow
    $fileHash = (Get-FileHash -Path $FilePathToSend -Algorithm SHA256).Hash
    Write-Log "SHA256 Hash: $fileHash" -Color Green

    $fileBytes = [System.IO.File]::ReadAllBytes($FilePathToSend)
    $totalChunks = [System.Math]::Ceiling($fileBytes.Length / $TransferChunkSize)

    Write-Log "File size: $($fileBytes.Length) bytes. Splitting into $totalChunks chunks of max $TransferChunkSize bytes." -Color Yellow

    # --- SEND CHUNKS WITH ACKNOWLEDGEMENT ---
    for ($i = 0; $i -lt $totalChunks; $i++) {
        $chunkNumber = $i + 1
        $offset = $i * $TransferChunkSize
        $remainingBytes = $fileBytes.Length - $offset
        $currentChunkSize = [System.Math]::Min($TransferChunkSize, $remainingBytes)

        $chunkBytes = $fileBytes[$offset..($offset + $currentChunkSize - 1)]
        $chunkBase64 = [System.Convert]::ToBase64String($chunkBytes)

        $payload = @{
            filename     = $fileToSendName
            hash         = $fileHash
            chunk_number = $chunkNumber
            total_chunks = $totalChunks
            data         = $chunkBase64
        } | ConvertTo-Json -Compress

        $ackReceived = $false
        while (-not $ackReceived) {
            Write-Log "Sending chunk $chunkNumber/$totalChunks for '$fileToSendName'..." -Color Cyan
            Set-Clipboard -Value $payload

            $expectedAck = "ACK $chunkNumber"
            Write-Log "Waiting for acknowledgement: '$expectedAck'" -Color Yellow

            $timeout = 0
            while ($timeout -lt 300) { # 60 seconds timeout
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

    Write-Log "File transfer complete for '$fileToSendName'." -Color Green
}

# --- 2. TRANSFER LOGIC ---
if ($ByPart.IsPresent) {
    $partSizeBytes = Parse-Size $PartSize
    if ($partSizeBytes -eq 0) {
        # Error message was already printed by Parse-Size. Exit gracefully.
        return
    }

    Write-Log "Splitting '$archivePath' into parts of up to $PartSize..." -Color Yellow

    $fullFileBytes = [System.IO.File]::ReadAllBytes($archivePath)
    $fullFileSize = $fullFileBytes.Length
    $archiveFileLeafName = Split-Path $archivePath -Leaf
    $partNumber = 1
    $offset = 0

    while ($offset -lt $fullFileSize) {
        $bytesRemaining = $fullFileSize - $offset
        $currentPartSize = [System.Math]::Min($partSizeBytes, $bytesRemaining)

        $partBytes = $fullFileBytes[$offset..($offset + $currentPartSize - 1)]

        $tempPartFileName = "$($archiveFileLeafName).part$($partNumber.ToString('000'))"
        $tempPartPath = Join-Path $env:TEMP $tempPartFileName

        Write-Log "Preparing part #$partNumber: '$tempPartFileName' ($currentPartSize bytes)" -Color Cyan
        [System.IO.File]::WriteAllBytes($tempPartPath, $partBytes)

        # Send this part using the refactored function
        Send-File -FilePathToSend $tempPartPath -TransferChunkSize $ChunkSize

        # Clean up the temporary part file
        Remove-Item $tempPartPath -Force
        Write-Log "Cleaned up temporary part file '$tempPartFileName'." -Color Yellow

        $offset += $currentPartSize
        $partNumber++
    }

    Write-Log "All parts have been transferred." -Color Green

} else {
    Send-File -FilePathToSend $archivePath -TransferChunkSize $ChunkSize
}


if ($needsArchiving) {
    Remove-Item $archivePath -Force
    Write-Log "Cleaned up temporary archive."
}