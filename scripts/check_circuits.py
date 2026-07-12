#!/usr/bin/env python3
import socket
import os
import re

def query_tor(port, command):
    try:
        s = socket.socket()
        s.settimeout(2)
        s.connect(('127.0.0.1', port))
        s.sendall(f"AUTHENTICATE\r\n{command}\r\nQUIT\r\n".encode())
        response = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            response += chunk
        return response.decode()
    except Exception as e:
        return f"Error connecting to Tor Control Port: {e}"

def get_ports():
    ports = {}
    ports_file = "/tmp/nullexit-ports.env"
    if os.path.exists(ports_file):
        with open(ports_file, 'r') as f:
            for line in f:
                if line.startswith("export "):
                    # Split at first '=' to handle potential multiple '=' in value
                    parts = line.replace("export ", "").strip().split("=", 1)
                    if len(parts) == 2:
                        key, val = parts
                        try:
                            ports[key] = int(val)
                        except ValueError:
                            ports[key] = val
    return ports

def main():
    ports = get_ports()
    control_port = ports.get("TOR_CONTROL_PORT", 9051)
    
    print(f"Connecting to Tor Control Port on 127.0.0.1:{control_port}...")
    status = query_tor(control_port, "GETINFO circuit-status")
    
    if "Error" in status:
        print(status)
        return
        
    print("\nActive Tor Circuits:")
    circuits = re.findall(r"(\d+)\s+BUILT\s+(.+?)\s+PURPOSE", status)
    if not circuits:
        print("No active built circuits found yet. Tor might still be bootstrapping.")
        return
        
    for circ_id, path_str in circuits:
        print(f"\nCircuit #{circ_id}:")
        nodes = path_str.split(",")
        for idx, node in enumerate(nodes):
            fingerprint = node.split("~")[0].replace("$", "")
            nickname = node.split("~")[1] if "~" in node else "unknown"
            
            # Fetch node IP
            ns_info = query_tor(control_port, f"GETINFO ns/id/{fingerprint}")
            ip = "unknown"
            for line in ns_info.split("\n"):
                if line.startswith("r "):
                    parts = line.split(" ")
                    if len(parts) >= 7:
                        ip = parts[6]
                        break
            
            # Fetch country
            country = "unknown"
            if ip != "unknown":
                country_info = query_tor(control_port, f"GETINFO ip-to-country/{ip}")
                for line in country_info.split("\n"):
                    if line.startswith("250-ip-to-country/"):
                        country = line.split("=")[1].strip().upper()
                        break
            
            role = "Guard" if idx == 0 else ("Exit" if idx == len(nodes) - 1 else "Middle")
            print(f"  [{role}] {nickname} ({ip}) - Country: {country}")

if __name__ == "__main__":
    main()
