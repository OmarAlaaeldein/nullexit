# Docker Gateway: Tailscale + Cloudflare WARP

This guide details how to set up a chained network gateway that routes all Tailscale exit-node traffic through a Cloudflare WARP VPN tunnel.

## 1. Prerequisites
- Docker and Docker Compose installed.
- A Tailscale account.
- `wgcf` tool to generate a WARP WireGuard profile.

## 2. Generate WARP WireGuard Profile
Use [`wgcf`](https://github.com/ViRb3/wgcf) to generate a Cloudflare WARP WireGuard profile.

1. Register a new identity:
   ```bash
   wgcf register
   ```
   Accept the Terms of Service. This will create a `wgcf-account.toml` file.

2. Generate the WireGuard profile:
   ```bash
   wgcf generate
   ```
   This will create a `wgcf-profile.conf` file.

3. Map the keys from `wgcf-profile.conf` to a `.env` file for your Docker setup. 
   Create a `.env` file in this directory and populate it:

   ```env
   # Extract these values from your generated wgcf-profile.conf
   WIREGUARD_PRIVATE_KEY=<PrivateKey from the [Interface] section>
   WIREGUARD_PUBLIC_KEY=<PublicKey from the [Peer] section>
   WIREGUARD_ADDRESSES=<Address from the [Interface] section (e.g., 172.16.0.2/32)>
   
   # Get this from your Tailscale Admin Console (Settings > Keys > Generate auth key)
   TS_AUTHKEY=tskey-auth-...
   ```

## 3. Deploy the Gateway

Run the following command to start the gateway in the background:
```bash
docker compose up -d
```
*Note: Make sure your `.env` file is in the same directory as the `docker-compose.yml` file.*

## 4. Post-Deployment Instructions

### Approve the Exit Node
1. Go to the [Tailscale Admin Console - Machines](https://login.tailscale.com/admin/machines).
2. Locate the new `tailscale` device in your machine list.
3. Click the `...` menu next to the machine and select **Edit route settings...**.
4. Under the "Exit nodes" section, toggle the switch to approve this machine as an exit node.

### Verify the Traffic Flow
1. On your mobile device (or any other Tailscale client), open the Tailscale app.
2. Ensure Tailscale is connected.
3. Tap on "Exit Node" and select the newly deployed gateway node.
4. Visit a site like [ipinfo.io](https://ipinfo.io/) or [whatismyip.com](https://www.whatismyip.com/).
5. Your IP should now reflect a Cloudflare IP instead of your local ISP, confirming the tunnel-in-tunnel (Tailscale -> WARP) traffic flow is working successfully.

## 5. Networking Notes

- **Port Usage**: Tailscale and WARP use entirely different internal ports, preventing any conflicts. Tailscale operates on random/dynamic UDP ports for its peer-to-peer mesh connections. Meanwhile, WARP's outbound WireGuard connection is explicitly targeting port 2408, which is the standard Cloudflare WARP destination port.
- **No Exposed Host Ports**: Because all communication relies purely on outbound tunnels, this Docker Gateway does not map or expose any ports to your local host machine.

## 6. Architecture & Security Insights

This setup implements a highly secure, zero-trust "Tunnel-in-Tunnel" architecture by aggressively routing a Tailscale Exit Node directly through a Gluetun-managed Cloudflare WARP tunnel.

### Traffic Flow & Double Encryption
1. **Device to Gateway (Tailscale):** Traffic leaving your client device (e.g., your phone) is encrypted using Tailscale's WireGuard implementation. It travels securely over the internet or cellular network to your Docker Gateway.
2. **Gateway to Internet (Cloudflare WARP):** Inside the Docker network namespace, the Tailscale container passes the decrypted traffic to the Gluetun container. Gluetun immediately re-encrypts the traffic using standard WireGuard and forces it out through Cloudflare WARP's infrastructure.

This creates a **Double Encryption** scenario. While this inherently introduces a slight latency penalty due to the encryption overhead and geographical routing (bouncing to your home gateway before routing to the broader internet), it ensures total privacy from local ISPs, public Wi-Fi administrators, and even the host network itself.

### Threat Model & Trust Assumptions
While this architecture effectively neutralizes local network threats (like man-in-the-middle attacks on cafe Wi-Fi) because traffic is heavily encrypted before touching a public network, it introduces a significant trust assumption:
1. **Physical Mesh Integrity:** Your physical devices (phone, host computer) and their private keys are not compromised.
2. **Cloudflare Integrity:** You are fully trusting Cloudflare not to maliciously log, intercept, or correlate your WARP connection with your decrypted exit traffic. This is a non-trivial assumption for a serious threat model.
3. **Operational Risk (`TS_AUTHKEY`):** Although the container entrypoint intentionally unsets the `TS_AUTHKEY` environment variable at runtime to prevent expiration crash loops, the key will still remain permanently visible in the raw `docker inspect` output. Anyone with socket access to your local Docker daemon can view it. However, this risk is largely moot: gaining socket access requires host-level access, which violates the first assumption of our threat model (Physical Mesh Integrity). If an attacker can run `docker inspect`, the physical device is already compromised.

### Advanced Routing Hacks (Under the Hood)
Building this required navigating intense firewall and routing conflicts between two VPN clients fighting for control over the same network stack:
- **IPv6 Forwarding Bug:** Tailscale aggressively checks both IPv4 and IPv6 forwarding statuses in the kernel. If Docker disables IPv6 forwarding by default, Tailscale silently disables its Exit Node functionality. This is bypassed by explicitly setting `net.ipv6.conf.all.forwarding=1` in the Compose file.
- **Strict Firewall Loops (The "DERP" bypass):** Gluetun's strict leak-prevention firewall (`iptables-nft`) intentionally drops unrecognized forwarded traffic. Furthermore, its policy routing forces all returning traffic out the `tun0` (WARP) interface, creating a blackhole for returning Tailscale packets. While most community setups accept degraded, slow DERP relay connections here, this architecture deploys an automated sidecar container (`routing-fix`). It persistently injects a high-priority `ip rule` (`ip rule add to 100.64.0.0/10 lookup 52 pref 99`), ensuring returning packets bypass the VPN blackhole and establish high-speed, direct P2P connections back into the Tailscale mesh.
- **Kernel-Space vs Userspace Conflict:** Tailscale is forced into kernel-space networking (`TS_USERSPACE=false`) because userspace mode prevents the container from functioning as a true Exit Node. This can occasionally cause Gluetun's strict health-checks to flap and restart due to kernel-table modifications. This is an accepted trade-off; Docker's `restart: unless-stopped` automatically recovers it, preserving maximum throughput and Exit Node capabilities.
- **macOS Memory Overhead (Colima):** Because macOS cannot run Linux containers natively, Colima must spin up a background Linux VM. While the actual containers (`warp`, `tailscale`, `routing-fix`) only consume roughly `~75MB` of RAM combined, the Colima VM requires a base memory allocation just to boot the Linux kernel and Docker daemon. We recommend running the VM stably at `0.5 GB` (512MB) of RAM (`colima start --memory 0.5`). Attempting to aggressively starve the VM to `0.3 GB` (300MB) will trigger an out-of-memory (`OOMKilled`) crash loop on the `warp` container during Wireguard/Unbound initialization.

## 7. Future Work
- **Native Linux Deployment:** Test and benchmark the architecture on a native Linux host (e.g., Raspberry Pi) to verify the native `~75MB` raw container footprint without the macOS hypervisor overhead.

## 8. Acknowledgements
- **[SyameimaruKoa](https://github.com/SyameimaruKoa):** For providing advanced, production-grade architectural optimizations to this project, specifically the dual-stack TCP MSS clamping rules to prevent payload fragmentation stalls, the `SIGHUP` state-tracking logic in the routing sidecar to seamlessly survive Gluetun restarts, and the smart `TS_AUTHKEY` lifecycle management entrypoint to prevent authentication crash loops.
