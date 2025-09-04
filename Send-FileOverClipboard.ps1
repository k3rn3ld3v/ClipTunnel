<#
.SYNOPSIS
    ClipTunnel Sender (7z Edition)
.DESCRIPTION
    Sends a file or folder over the clipboard in chunks. This version requires the
    7-Zip command-line tool (7z.exe) for compression. It will first look for 7z.exe
    in the system PATH, and if not found, will check the default install location.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [int]$ChunkSize = 786432 # 768 KB
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

# --- 2. HASH THE FILE AND PREPARE FOR STREAMING ---
Write-Log "Computing SHA256 hash for '$archivePath'..." -Color Yellow
$fileHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
Write-Log "SHA256 Hash: $fileHash" -Color Green

$fileInfo = Get-Item -Path $archivePath
$fileSize = $fileInfo.Length
$totalChunks = [System.Math]::Ceiling($fileSize / $ChunkSize)
$archiveFileName = $fileInfo.Name

Write-Log "File size: $fileSize bytes. Splitting into $totalChunks chunks." -Color Yellow

# --- 3. STREAM CHUNKS WITH ACKNOWLEDGEMENT ---
$chunkNumber = 0
$fileStream = $null
try {
    $fileStream = New-Object System.IO.FileStream($archivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    $buffer = New-Object byte[] $ChunkSize

    while ($bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)) {
        if ($bytesRead -eq 0) { break }
        $chunkNumber++

        # For the last chunk, the buffer might be larger than the bytes read
        $actualChunkBytes = if ($bytesRead -lt $buffer.Length) {
            $temp = New-Object byte[] $bytesRead
            [System.Array]::Copy($buffer, $temp, $bytesRead)
            $temp
        } else {
            $buffer
        }
        
        $chunkBase64 = [System.Convert]::ToBase64String($actualChunkBytes)

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