# 📋 ClipTunnel (7z Edition)

A pair of PowerShell scripts for transferring files and folders out of a restricted environment using only the VNC shared clipboard. This version uses the **7-Zip command-line tool** for superior LZMA2 compression.

---

## ✨ Features

-   **📦 Automatic Archiving**: Automatically archives folders or single files for easy transport.
-   **🔒 Superior Compression**: Requires and utilizes `7z.exe` for high-ratio **LZMA2 (.7z)** compression.
-   **🚀 Smart Chunking**: Splits large files into configurable chunks to avoid clipboard size limits.
-   **🤝 Reliable Handshake**: Uses an ACK (acknowledgement) protocol to ensure every chunk is received before sending the next.
-   **🔐 Integrity Check**: Verifies the reassembled file against a **SHA256 hash** to guarantee a perfect transfer.
-   **🏃 Background-Safe**: The receiver script runs reliably in the background without needing window focus.

---

## ⚠️ Prerequisites

-   **Sender VM**: The isolated machine **must** have [7-Zip](https://www.7-zip.org/) installed. The script will automatically look for `7z.exe` in:
    1.  The system's PATH environment variable.
    2.  The default installation directory (`C:\Program Files\7-Zip\`).

---

## 🚀 Usage

### Step 1: Start the Receiver on Your Host Machine

Open a PowerShell terminal on your main computer and run the receiver script.

```powershell
# To listen continuously
.\Receive-FileFromClipboard.ps1 -OutputDir "C:\Path\To\Your\Downloads"

# To listen for one file and then exit automatically
.\Receive-FileFromClipboard.ps1 -OutputDir "C:\Path\To\Your\Downloads" -ExitOnComplete