<#
.SYNOPSIS
    ClipTunnel Sender (7z Edition with Splitting)
.DESCRIPTION
    Sends a file over the clipboard. Can optionally split the source archive into
    smaller parts on disk before sending, making it ideal for very large files
    in low-memory environments.
.PARAMETER Path
    The path to the file or folder to send.
.PARAMETER ByPart
    Switch to enable splitting the archive into smaller parts before sending.
.PARAMETER PartSize
    The size of each part (e.g., "10MB", "500KB"). Mandatory when -ByPart is used.
#>
[CmdletBinding(DefaultParameterSetName='Default')]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [int]$ChunkSize = 786432, # 768 KB

    [Parameter(ParameterSetName='Split')]
    [switch]$ByPart,

    [Parameter(ParameterSetName='Split', Mandatory=$true)]
    [string]$PartSize
)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

# --- PRE-FLIGHT CHECK: Find 7z.exe ---
# (Same logic as before to find 7z.exe in PATH or default location)
Write-Log "Searching for 7z.exe..." -Color Yellow
$sevenZipPath = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
if (-not $sevenZipPath) {
    $defaultPath = "C:\Program Files\7-Zip\7z.exe"
    if (Test-Path $defaultPath) { $sevenZipPath = $defaultPath; Write-Log "Found 7z.exe at default location." -Color Green }
} else { Write-Log "Found 7z.exe in PATH." -Color Green }

if (-not $sevenZipPath) {
    Write-Log "FATAL: 7-Zip (7z.exe) could not be found." -Color Red; return
}

# --- 1. PREPARE THE MAIN ARCHIVE ---
# (This part is mostly the same, it always creates one large initial archive)
$sourceObject = Get-Item -Path $Path
if (-not $sourceObject) { Write-Log "Error: Path '$Path' not found." -Color Red; return }

$tempDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
New-Item -Path $tempDir -ItemType Directory | Out-Null
$archivePath = Join-Path $tempDir "$($sourceObject.Name).7z"
$archiveFileName = Split-Path $archivePath -Leaf

if ($sourceObject.Extension -eq ".7z" -and !$ByPart) {
    Write-Log "Input is a .7z archive and not splitting. Using it directly." -Color Green
    $archivePath = $sourceObject.FullName
    $tempDir = Split-Path $archivePath -Parent
} else {
    try {
        $arguments = "a -t7z -m0=lzma2 -mx=9 -mmt=on `"$archivePath`" `"$Path`""
        Write-Log "Creating main archive..." -Color Cyan
        Start-Process -FilePath $sevenZipPath -ArgumentList $arguments -Wait -NoNewWindow
        if (-not (Test-Path $archivePath)) { throw "7z.exe failed to create the archive." }
    } catch { Write-Log "Error creating archive: $_" -Color Red; return }
}

# --- 2. CALCULATE HASH (ALWAYS ON THE FULL, UN-SPLIT ARCHIVE) ---
Write-Log "Computing SHA256 hash for the complete archive..." -Color Yellow
$fileHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
Write-Log "SHA256 Hash: $fileHash" -Color Green

# --- 3. GET FILE LIST TO SEND (EITHER 1 FILE OR MANY PARTS) ---
$filesToSend = @()
if ($ByPart) {
    Write-Log "Splitting archive into parts of size $PartSize..." -Color Cyan
    try {
        # -v (volume) switch splits the archive.
        $splitArgs = "a -t7z `"-v$($PartSize)`" `"$($archivePath).split`" `"$archivePath`""
        Start-Process -FilePath $sevenZipPath -ArgumentList $splitArgs -Wait -NoNewWindow
        $filesToSend = Get-ChildItem -Path "$tempDir" -Filter "$($archiveFileName).split.*" | Sort-Object Name
        if ($filesToSend.Count -eq 0) { throw "7z.exe failed to create split parts." }
        Write-Log "Archive split into $($filesToSend.Count) parts." -Color Green
    } catch { Write-Log "Error splitting archive: $_" -Color Red; return }
} else {
    $filesToSend = @(Get-Item $archivePath)
}

# --- 4. ITERATE AND SEND EACH FILE (PART) ---
$totalParts = $filesToSend.Count
$partNumber = 1
foreach ($file in $filesToSend) {
    Write-Log "Preparing to send Part $partNumber/$totalParts: $($file.Name)" -Color Magenta
    
    # Use streaming for low memory usage
    try {
        $fileStream = [System.IO.File]::OpenRead($file.FullName)
        $reader = [System.IO.BinaryReader]::new($fileStream)
        $totalChunks = [System.Math]::Ceiling($fileStream.Length / $ChunkSize)
        $chunkNumber = 1

        while ($fileStream.Position -lt $fileStream.Length) {
            $bytesToRead = [System.Math]::Min($ChunkSize, $fileStream.Length - $fileStream.Position)
            $chunkBytes = $reader.ReadBytes($bytesToRead)
            $chunkBase64 = [System.Convert]::ToBase64String($chunkBytes)

            # --- METADATA PAYLOAD (NOW INCLUDES PART INFO) ---
            $payload = @{
                base_filename = $archiveFileName # Original archive name
                part_filename = $file.Name       # Name of this specific part (e.g., archive.7z.001)
                hash          = $fileHash        # Hash of the ORIGINAL archive
                part_number   = $partNumber
                total_parts   = $totalParts
                chunk_number  = $chunkNumber
                total_chunks  = $totalChunks
                data          = $chunkBase64
            } | ConvertTo-Json -Compress

            # --- ACK HANDSHAKE (UNCHANGED) ---
            $ackReceived = $false
            while (-not $ackReceived) {
                Write-Log "Sending Part $partNumber Chunk $chunkNumber/$totalChunks..." -Color Cyan
                Set-Clipboard -Value $payload
                $expectedAck = "ACK P$($partNumber)C$($chunkNumber)"
                Write-Log "Waiting for acknowledgement: '$expectedAck'" -Color Yellow
                
                $timeout = 0
                while ($timeout -lt 300) {
                    if ((Get-Clipboard) -eq $expectedAck) {
                        Write-Log "ACK received!" -Color Green; $ackReceived = $true; break
                    }
                    Start-Sleep -Milliseconds 200; $timeout++
                }
                if (-not $ackReceived) { Write-Log "Timeout waiting for ACK. Retrying..." -Color Red }
            }
            $chunkNumber++
        }
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
    }
    $partNumber++
}

Write-Log "All parts transferred successfully." -Color Green
Remove-Item -Path $tempDir -Recurse -Force
Write-Log "Cleaned up temporary files."