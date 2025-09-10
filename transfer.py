# transfer.py (v6 - Final Bidirectional Script)
import argparse
import base64
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import pyperclip
except ImportError:
    print("Warning: 'pyperclip' library not found. Please install with 'pip install pyperclip'", file=sys.stderr)

# --- Configuration & OS Detection ---
IS_WINDOWS = platform.system() == "Windows"
IS_LINUX = platform.system() == "Linux"

CHUNK_SIZE = 120 * 1024
ACK_TIMEOUT_SECONDS = 15

# --- OS-Aware Clipboard Abstraction ---
CLIPBOARD_TOOL_LINUX = None

def detect_linux_clipboard_tool():
    """Finds the first available clipboard tool on Linux."""
    global CLIPBOARD_TOOL_LINUX
    tools = {
        "xclip": {"check": "xclip", "copy": ["xclip", "-i", "-selection", "clipboard"], "paste": ["xclip", "-o", "-selection", "clipboard"]},
        "xsel": {"check": "xsel", "copy": ["xsel", "--input", "--clipboard"], "paste": ["xsel", "--output", "--clipboard"]},
        "wl-clipboard": {"check": "wl-copy", "copy": ["wl-copy"], "paste": ["wl-paste", "--no-newline"]}
    }
    for name, tool in tools.items():
        if shutil.which(tool["check"]):
            CLIPBOARD_TOOL_LINUX = tool
            return True
    return False

def initialize_clipboard():
    """Initializes the correct clipboard mechanism for the current OS."""
    if IS_WINDOWS:
        print("✅ Windows clipboard handler initialized.")
        return
    if IS_LINUX:
        if detect_linux_clipboard_tool():
            tool_name = CLIPBOARD_TOOL_LINUX["check"]
            print(f"✅ Linux clipboard handler initialized (using '{tool_name}').")
        else:
            print("❌ CRITICAL ERROR: No Linux clipboard tool (xclip, xsel, wl-clipboard) found.", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"❌ Unsupported OS: {platform.system()}", file=sys.stderr)
        sys.exit(1)

def copy_to_clipboard(text):
    if IS_WINDOWS:
        pyperclip.copy(text)
    elif IS_LINUX and CLIPBOARD_TOOL_LINUX:
        subprocess.run(CLIPBOARD_TOOL_LINUX["copy"], input=text, text=True, check=True)

def paste_from_clipboard():
    if IS_WINDOWS:
        return pyperclip.paste()
    elif IS_LINUX and CLIPBOARD_TOOL_LINUX:
        result = subprocess.run(CLIPBOARD_TOOL_LINUX["paste"], capture_output=True, text=True, check=False)
        return result.stdout
    return ""

# --- OS-Aware Archiver Detection ---
def find_executable(name, default_paths=[]):
    if shutil.which(name): return shutil.which(name)
    for path in default_paths:
        full_path = os.path.join(path, name)
        if os.path.exists(full_path): return full_path
    return None

def detect_archiver():
    """Finds the best available archiver for the current OS."""
    seven_zip_paths = [r"C:\Program Files\7-Zip", r"C:\Program Files (x86)\7-Zip"]
    git_bin_paths = [r"C:\Program Files\Git\usr\bin"]
    
    archivers = {
        "7z": {"ext": ".7z", "cmd": lambda archive, file: [find_executable("7z.exe" if IS_WINDOWS else "7z", seven_zip_paths), 'a', '-mx=9', archive, file]},
        "tar.xz": {"ext": ".tar.xz", "cmd": lambda archive, file: [find_executable("tar.exe" if IS_WINDOWS else "tar", git_bin_paths), '-cJf', archive, os.path.basename(file)]},
        "zip": {"ext": ".zip", "cmd": lambda archive, file: [find_executable("zip.exe" if IS_WINDOWS else "zip", git_bin_paths), '-9', '-j', archive, file]}
    }
    
    if find_executable("7z.exe" if IS_WINDOWS else "7z", seven_zip_paths): return archivers['7z']
    if find_executable("tar.exe" if IS_WINDOWS else "tar", git_bin_paths): return archivers['tar.xz']
    if find_executable("zip.exe" if IS_WINDOWS else "zip", git_bin_paths): return archivers['zip']
    return None

# --- Sender Logic ---
def run_send_mode(file_path, use_archive):
    archive_type = None
    with tempfile.TemporaryDirectory() as temp_dir:
        if use_archive:
            print("📦 Archiving enabled. Searching for best compression tool...")
            archiver = detect_archiver()
            if not archiver:
                print("❌ No compatible archiver found. Aborting.", file=sys.stderr); return
            
            tool_name = os.path.basename(archiver['cmd'](None, None)[0])
            print(f"✅ Found archiver: {tool_name}. Compressing file...")
            original_filename = os.path.basename(file_path)
            archive_path = os.path.join(temp_dir, original_filename + archiver['ext'])
            original_dir = os.path.dirname(os.path.abspath(file_path))
            try:
                subprocess.run(archiver['cmd'](archive_path, original_filename), check=True, cwd=original_dir, capture_output=True)
            except (subprocess.CalledProcessError, FileNotFoundError) as e:
                print(f"❌ Archiving failed: {getattr(e, 'stderr', e)}", file=sys.stderr); return
            
            print(f"✅ Compression complete. Archive size: {os.path.getsize(archive_path) / 1024:.2f} KB")
            file_to_send, archive_type = archive_path, archiver['ext']
        else:
            file_to_send = file_path

        with open(file_to_send, 'rb') as f: binary_data = f.read()
        print(f"--- Preparing to send '{os.path.basename(file_to_send)}' ---")
        file_hash = hashlib.sha256(binary_data).hexdigest()
        print(f"🔑 SHA256 of file to send: {file_hash}")
        base64_string = base64.b64encode(binary_data).decode('utf-8')
        total_chunks = math.ceil(len(base64_string) / CHUNK_SIZE)
        print(f"✅ Encoded. Ready to send in {total_chunks} chunks.")
        print("-" * 30); input("Press Enter to begin the transfer...")

        last_cb_content = ""
        for i in range(total_chunks):
            chunk_num, is_acked = i + 1, False
            while not is_acked:
                start, end = i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE
                payload = base64_string[start:end]
                payload_hash = hashlib.sha256(payload.encode('utf-8')).hexdigest()
                packet = json.dumps({"type": "data", "chunk_num": chunk_num, "total_chunks": total_chunks, "original_file_hash": file_hash, "archive_type": archive_type, "hash": payload_hash, "payload": payload})
                copy_to_clipboard(packet)
                print(f"\n📤 Sending chunk {chunk_num}/{total_chunks}...")
                
                start_time = time.time()
                while time.time() - start_time < ACK_TIMEOUT_SECONDS:
                    cb_content = paste_from_clipboard()
                    if cb_content == last_cb_content: time.sleep(1); continue
                    last_cb_content = cb_content
                    try:
                        ack = json.loads(cb_content)
                        if ack.get("type") == "ack" and ack.get("ack_num") == chunk_num:
                            print(f"✅ ACK received for chunk {chunk_num}."); is_acked = True; break
                    except (json.JSONDecodeError, AttributeError): pass
                    time.sleep(1)
                if not is_acked: print(f"⌛️ Timeout for chunk {chunk_num}. Retrying...")
        
        print("\n🎉 Transfer complete! All chunks acknowledged.")
        copy_to_clipboard(json.dumps({"type": "finish"}))

# --- Receiver Logic ---
def run_receive_mode(output_filename):
    stored_chunks, total_chunks, file_hash, archive_type = {}, -1, None, None
    last_cb_content = ""
    print("📋 Receiver is running. Waiting for data...")

    while True:
        try:
            cb_content = paste_from_clipboard()
            if cb_content == last_cb_content or not cb_content: time.sleep(1); continue
            last_cb_content = cb_content
            try:
                packet = json.loads(cb_content)
                if packet.get("type") == "finish": print("\n🏁 Finish signal received."); break
                if packet.get("type") != "data": continue
                if file_hash is None:
                    file_hash, archive_type = packet.get("original_file_hash"), packet.get("archive_type")
                    if file_hash: print(f"🔑 Original hash received: {file_hash[:10]}...")
                    if archive_type: print(f"📦 This is an archived transfer ({archive_type}).")
                
                chunk_num, payload = packet["chunk_num"], packet["payload"]
                if hashlib.sha256(payload.encode('utf-8')).hexdigest() != packet["hash"]:
                    print(f"⚠️ Corrupt chunk {chunk_num}. Ignoring."); continue
                if total_chunks == -1:
                    total_chunks = packet["total_chunks"]
                    print(f"🚀 Transfer initiated. Expecting {total_chunks} chunks.")
                if chunk_num not in stored_chunks:
                    stored_chunks[chunk_num] = payload
                    print(f"📥 Received chunk {chunk_num}/{total_chunks}. Sending ACK...")
                
                ack_packet = json.dumps({"type": "ack", "ack_num": chunk_num})
                copy_to_clipboard(ack_packet)
                last_cb_content = ack_packet
            except (json.JSONDecodeError, KeyError, TypeError): pass
            if total_chunks != -1 and len(stored_chunks) == total_chunks: print("\n✅ All chunks received."); break
            time.sleep(1)
        except KeyboardInterrupt: print("\n🛑 User interrupted."); sys.exit(1)

    if not stored_chunks or len(stored_chunks) != total_chunks:
        print(f"❌ Transfer incomplete. Received {len(stored_chunks)}/{total_chunks} chunks."); return

    final_path = output_filename
    if archive_type and not final_path.endswith(archive_type):
        final_path += archive_type
    print(f"🧩 Reassembling file to '{final_path}'...")
    full_b64 = "".join(stored_chunks[i] for i in sorted(stored_chunks.keys()))
    try:
        binary_data = base64.b64decode(full_b64)
        with open(final_path, 'wb') as f: f.write(binary_data)
        print("✅ File saved.")
    except Exception as e:
        print(f"❌ Failed to save file: {e}"); return

    print("\n--- Final Integrity Check ---")
    if not file_hash: print("⚠️ Could not verify file hash."); return
    with open(final_path, 'rb') as f: reassembled_hash = hashlib.sha256(f.read()).hexdigest()
    print(f"  - Original hash:    {file_hash}")
    print(f"  - Reassembled hash: {reassembled_hash}")
    if file_hash == reassembled_hash:
        print("\n🎉 SUCCESS: Hashes match! The file transfer is verified.")
        if archive_type: print(f"❕ REMINDER: Extract '{final_path}' to get the original content.")
    else:
        print("\n❌ FAILURE: Hashes do not match! The file may be corrupt.")

# --- Main Entry Point & Arg Parsing ---
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Bidirectional Clipboard File Transfer Tool.", formatter_class=argparse.RawTextHelpFormatter)
    subparsers = parser.add_subparsers(dest="mode", required=True, help="Mode of operation")

    parser_send = subparsers.add_parser('send', help="Send a file.")
    parser_send.add_argument("-f", "--file", required=True, help="Path to the file to send.")
    parser_send.add_argument("-a", "--archive", action="store_true", help="Compress the file before sending.")

    parser_receive = subparsers.add_parser('receive', help="Receive a file.")
    parser_receive.add_argument("-o", "--output", required=True, help="Output path for the received file.")

    args = parser.parse_args()

    initialize_clipboard()
    
    # Clear clipboard on start to ensure a clean state
    print("🧹 Clearing clipboard for a clean start...")
    copy_to_clipboard('')
    time.sleep(0.5) # Small delay for the OS to process the clipboard change

    if args.mode == 'send':
        run_send_mode(args.file, args.archive)
    elif args.mode == 'receive':
        run_receive_mode(args.output)