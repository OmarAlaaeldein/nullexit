#!/usr/bin/env python3
import os
import re
import sys
import json
import time
import datetime
import threading

# Configuration paths inside the container
QUERY_LOG_PATH = "/adguard_work/data/querylog.json"
PROC_KMSG_PATH = "/proc/kmsg"
OUTPUT_LOG_PATH = "/app/blocked.log"

def log_message(msg):
    """Write log message to console and append to the output file."""
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    formatted_msg = f"{timestamp} {msg}\n"
    print(formatted_msg, end="", flush=True)
    try:
        with open(OUTPUT_LOG_PATH, "a") as f:
            f.write(formatted_msg)
    except Exception as e:
        print(f"Error writing to log file: {e}", file=sys.stderr, flush=True)

def tail_file(filepath):
    """Yields lines appended to a file, handling truncation, rotation, and file creation."""
    while not os.path.exists(filepath):
        time.sleep(1)
    
    with open(filepath, 'r', errors='ignore') as f:
        # Go to the end of the file on initial open
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if not line:
                try:
                    current_size = os.path.getsize(filepath)
                except FileNotFoundError:
                    current_size = 0
                
                if current_size < f.tell():
                    f.close()
                    while not os.path.exists(filepath):
                        time.sleep(1)
                    f = open(filepath, 'r', errors='ignore')
                else:
                    time.sleep(0.5)
                continue
            yield line

def monitor_dns():
    log_message("[System] Starting DNS block logger...")
    for line in tail_file(QUERY_LOG_PATH):
        try:
            data = json.loads(line)
            res = data.get("Result", {})
            is_filtered = res.get("IsFiltered", False)
            reason = res.get("Reason", 0)
            
            # If filtered or blocked by any list/rules
            if is_filtered or (reason not in (0, 1) and reason is not None):
                qh = data.get("QH", "unknown")
                qt = data.get("QT", "unknown")
                client_ip = data.get("IP", "unknown")
                
                rule_text = "unknown rule"
                rules = res.get("Rules", [])
                if rules and isinstance(rules, list):
                    rule_text = rules[0].get("Text", "unknown rule")
                
                reason_str = {
                    2: "CustomRule",
                    3: "BlockList",
                    4: "SafeBrowsing",
                    5: "ParentalControl",
                    6: "SafeSearch",
                    7: "BlockedService",
                }.get(reason, f"Reason-{reason}")
                
                log_message(f"[DNS] Blocked {qh} (Type: {qt}) for client {client_ip} | Reason: {reason_str} | Rule: {rule_text}")
        except Exception:
            # Silently ignore parsing errors
            pass

def monitor_ips():
    log_message("[System] Starting IP block logger...")
    try:
        with open(PROC_KMSG_PATH, "r", errors="ignore") as f:
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.1)
                    continue
                
                # Look for our iptables log prefixes
                if "IP_BLOCK" in line:
                    match = re.search(r"(IP_BLOCK_[A-Z_]+):", line)
                    if match:
                        prefix = match.group(1)
                        
                        # Extract key-value pairs from iptables log
                        src = re.search(r"SRC=([0-9a-fA-F\.:]+)", line)
                        dst = re.search(r"DST=([0-9a-fA-F\.:]+)", line)
                        proto = re.search(r"PROTO=([A-Z0-9]+)", line)
                        spt = re.search(r"SPT=(\d+)", line)
                        dpt = re.search(r"DPT=(\d+)", line)
                        in_if = re.search(r"IN=([a-zA-Z0-9\.\-_]+)", line)
                        out_if = re.search(r"OUT=([a-zA-Z0-9\.\-_]+)", line)
                        
                        src_ip = src.group(1) if src else "unknown"
                        dst_ip = dst.group(1) if dst else "unknown"
                        protocol = proto.group(1) if proto else "unknown"
                        src_port = spt.group(1) if spt else ""
                        dst_port = dpt.group(1) if dpt else ""
                        in_interface = in_if.group(1) if in_if else ""
                        out_interface = out_if.group(1) if out_if else ""
                        
                        direction = "outbound" if prefix.endswith("DST") else "inbound"
                        list_type = "MALICIOUS" if "MALICIOUS" in prefix else f"GEO_{prefix.split('_')[2]}"
                        
                        port_str = f":{dst_port}" if dst_port else ""
                        src_port_str = f":{src_port}" if src_port else ""
                        if_str = f"IF: {in_interface}->{out_interface}" if in_interface and out_interface else f"IF: {in_interface or out_interface}"
                        
                        log_message(f"[IP] Blocked {direction} to {dst_ip}{port_str} (Proto: {protocol}) from {src_ip}{src_port_str} ({if_str}) | List: {list_type}")
    except PermissionError:
        log_message("[System] ERROR: Insufficient permissions to read /proc/kmsg. Enable CAP_SYSLOG.")
    except Exception as e:
        log_message(f"[System] ERROR in IP logger: {e}")

def main():
    log_message("[System] Nullexit Block Logger starting...")
    
    # Run DNS monitoring in a background thread
    dns_thread = threading.Thread(target=monitor_dns, daemon=True)
    dns_thread.start()
    
    # Run IP monitoring in the main thread (blocking)
    monitor_ips()

if __name__ == "__main__":
    main()
