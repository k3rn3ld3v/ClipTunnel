# **📎 ClipTunnel**

Securely and reliably tunnel files through your clipboard.

Have you ever been stuck in a remote session (VNC, RDP) with no direct file transfer, a disabled USB passthrough, and only a shared clipboard to rely on? **ClipTunnel** is a single-script utility designed to solve this exact problem.

It creates a robust, bidirectional tunnel for transferring files between two machines using only the clipboard, making it perfect for restricted environments.

## **✨ Features**

* **Bidirectional Transfer:** Send files from Windows to Linux, or from Linux to Windows, using the same universal script.  
* **Automatic Archiving:** Optionally compress files with 7z, tar.xz, or zip before transfer to dramatically reduce size and time.  
* **Reliable & Resilient:** Uses a handshake protocol with timeouts, acknowledgements, and send-side verification to ensure clipboard data is copied correctly. An interrupted transfer can be continued by simply keeping the windows in focus.  
* **Guaranteed Integrity:** End-to-end **SHA256 hash verification** ensures the received file is a perfect, uncorrupted copy of the original.  
* **Intelligent Tool Detection:** Automatically finds the necessary clipboard and archiving tools on both Windows and Linux, including in non-PATH locations.  
* **Zero-Install:** It's a single Python script. No complex installation or dependencies beyond pyperclip.

## **📋 Requirements**

* **Python 3.6+**  
* The pyperclip library:  
  pip install pyperclip

* **On Linux**, a command-line clipboard tool is also required:  
  \# For Debian/Ubuntu  
  sudo apt-get install xclip

  \# For CentOS/RHEL/Fedora  
  sudo yum install xsel

## **🚀 Usage**

The script transfer.py has two main modes: send and receive.

### **Example 1: Windows (Sender) to Linux (Receiver)**

1. **On the Linux (Receiver) machine**, run:  
   python3 transfer.py receive \-o my\_received\_file.whl

   The script will start listening.  
2. **On the Windows (Sender) machine**, run:  
   python transfer.py send \-f "C:\\path\\to\\my\_package.whl"

   Press Enter to start, then immediately click on the Linux remote session window to give it focus.

### **Example 2: Linux (Sender) to Windows (Receiver)**

1. **On the Windows (Receiver) machine**, open a terminal and run:  
   python transfer.py receive \-o my\_script.py

2. **On the Linux (Sender) machine**, run:  
   python3 transfer.py send \-f /home/user/scripts/my\_script.py

### **Compressing Files for Faster Transfer**

To automatically find the best archiver (7z, tar.xz, zip) and compress the file before sending, just add the \-a or \--archive flag to the **send** command. The receiver will handle it automatically.

\# Example: Send a large file with maximum compression  
python transfer.py send \-f "big\_log\_file.txt" \--archive

## **⚙️ How It Works**

ClipTunnel establishes a mini-protocol over the clipboard:

1. The **sender** can optionally **archive** the file to reduce its size.  
2. It calculates the file's **SHA256 hash**.  
3. The file is encoded into **Base64** text and split into small, clipboard-friendly chunks.  
4. Each chunk is wrapped in a **JSON packet** containing its sequence number, integrity hashes, and metadata.  
5. The sender places a packet on the clipboard, **verifies it was copied correctly**, and then waits for an **acknowledgement (ACK)** packet from the receiver.  
6. The **receiver** reads the packet, verifies its integrity, stores the chunk, and places an ACK packet on the clipboard.  
7. If the sender doesn't receive an ACK within a time limit, it **resends** the chunk.  
8. Once all chunks are received, the file is reassembled. A final **SHA256 hash check** is performed on the reassembled file to guarantee a perfect transfer.

## **📜 License**

This project is licensed under the MIT License.