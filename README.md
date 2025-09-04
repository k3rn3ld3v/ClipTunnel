# 📋 PClip-Transfer

A pair of PowerShell scripts for transferring files and folders out of a restricted environment (like a CTF VM) using only the VNC shared clipboard. This tool handles archiving, compression, chunking, and integrity checks automatically.

---

## ✨ Features

-   **📁 Automatic Archiving**: Automatically archives folders or single files for easy transport.
-   **⚡ High-Compression**: Uses the native `tar.exe` with **LZMA (.tar.xz)** for better compression than standard Zip.
-   **📦 Smart Chunking**: Splits large files into configurable chunks to avoid clipboard size limits.
-   **🤝 Reliable Handshake**: Uses an ACK (acknowledgement) protocol to ensure every chunk is received before sending the next.
-   **🔒 Integrity Check**: Verifies the reassembled file against a **SHA256 hash** to guarantee a perfect transfer.
-   **🚀 Background-Safe**: The receiver script runs reliably in the background without needing window focus.

---

## ⚙️ How It Works

The transfer is a coordinated handshake between two scripts:

1.  **💻 Sender (`Send-FileOverClipboard.ps1`)**:
    -   Takes a file or folder path.
    -   Archives it to a `.tar.xz` file (if not already an archive).
    -   Calculates the SHA256 hash of the archive.
    -   Splits the archive into binary chunks.
    -   For each chunk, it creates a JSON payload (with metadata and Base64 data), places it on the clipboard, and waits.

2.  **📥 Receiver (`Receive-FileFromClipboard.ps1`)**:
    -   Continuously monitors the clipboard for a valid JSON payload.
    -   When it sees a new chunk, it decodes and saves it to a temporary folder.
    -   It then places an "ACK" message on the clipboard to signal the sender.
    -   Once all chunks are received, it reassembles them, verifies the SHA256 hash, and saves the final file.

---

## 🚀 Usage

### Step 1: Start the Receiver on Your Host Machine

Open a PowerShell terminal on your main computer and run the receiver script. It will begin listening for incoming file chunks.

```powershell
# To listen continuously
.\Receive-FileFromClipboard.ps1 -OutputDir "C:\Path\To\Your\Downloads"

# To listen for one file and then exit automatically
.\Receive-FileFromClipboard.ps1 -OutputDir "C:\Path\To\Your\Downloads" -ExitOnComplete
```

You can now minimize this window or click away from it.

### Step 2: Run the Sender from the Isolated VM

On the VM, open a PowerShell terminal and run the sender script, pointing it to the file or folder you want to transfer.

```powershell
# Example: Send a folder from the Desktop
.\Send-FileOverClipboard.ps1 -Path "C:\Users\Admin\Desktop\secret-project"

# Example: Send a single file
.\Send-FileFromClipboard.ps1 -Path "C:\Users\Admin\Documents\flag.txt"
```

The transfer will begin automatically. You can monitor the progress in both terminals.

### Step 3: Extract the Final Archive

The received file will be a `.tar.xz` archive. You can extract it using 7-Zip or the native `tar` command on Windows:

```powershell
tar -xf "secret-project.tar.xz"
```