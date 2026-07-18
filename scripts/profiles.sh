#!/bin/bash
# scripts/profiles.sh — named config profiles that tame the .env flag sprawl.
#
# CONFIG-ONLY BY DESIGN: this tool ONLY reads/writes .env. It NEVER touches the
# live gateway — no routing, no PF, no containers, no restart — so it cannot break
# your running network. Changes take effect only on your NEXT ./toggle.sh --restart.
#
# A profile is a coherent, known-good bundle of the intent-level switches, so you
# pick ONE intent instead of reasoning about ~7 interacting flags. KILL_SWITCH is
# forced true in every profile — the fail-closed invariant is never negotiable.
#
# Usage:
#   bash scripts/profiles.sh show            # current config, grouped + explained (read-only)
#   bash scripts/profiles.sh list            # available profiles and what each sets (read-only)
#   bash scripts/profiles.sh preview <name>  # exactly what 'apply' would change (read-only)
#   bash scripts/profiles.sh apply <name>    # write the profile to .env (backs up; never restarts)
#
# Profiles: campus (AP-isolated enterprise, conservative) · home (trusted, fast) ·
#           hardened (max privacy: cover traffic + Tor bridges, no real-IP exposure)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1
case "${1:-}" in --help|-h) sed -n '2,25p' "$0"; exit 0 ;; esac

python3 - "$@" <<'PY'
import sys, os, shutil, time

ENV = os.environ.get("PROFILES_ENV_FILE", ".env")

# Intent-level switches each profile manages. KILL_SWITCH is a forced invariant.
PROFILES = {
  "campus":   {"KILL_SWITCH":"true","TAILSCALE_ALLOW_LAN_P2P":"false","FACETIME_SPLIT_ROUTE":"false",
               "PIHOLE_LAN_MODE":"false","NOISE_ENABLED":"false","TOR_USE_BRIDGES":"false","WARP_FAIL_THRESHOLD":"6"},
  "home":     {"KILL_SWITCH":"true","TAILSCALE_ALLOW_LAN_P2P":"true","FACETIME_SPLIT_ROUTE":"true",
               "PIHOLE_LAN_MODE":"true","NOISE_ENABLED":"false","TOR_USE_BRIDGES":"false","WARP_FAIL_THRESHOLD":"6"},
  "hardened": {"KILL_SWITCH":"true","TAILSCALE_ALLOW_LAN_P2P":"false","FACETIME_SPLIT_ROUTE":"false",
               "PIHOLE_LAN_MODE":"false","NOISE_ENABLED":"true","NOISE_PAD_MODE":"topup",
               "TOR_USE_BRIDGES":"true","WARP_FAIL_THRESHOLD":"3"},
}
DESC = {
  "campus":"AP-isolated enterprise/campus: DERP (no SNAT poisoning), everything conservative, no real-IP exposure.",
  "home":"Trusted network: direct LAN P2P (fast), FaceTime split-route + LAN Pi-hole on, no cover-traffic battery cost.",
  "hardened":"Max privacy on a hostile net: cover traffic (topup) + Tor bridges, fail-fast WARP, never expose the real IP.",
}
META = {
  "KILL_SWITCH":"PF fail-closed kill-switch (forced true — never negotiable)",
  "TAILSCALE_ALLOW_LAN_P2P":"direct LAN P2P vs forced DERP relay",
  "FACETIME_SPLIT_ROUTE":"route Apple /16s direct (fixes FaceTime; exposes real IP for them)",
  "PIHOLE_LAN_MODE":"serve AdGuard DNS to non-mesh LAN devices",
  "NOISE_ENABLED":"cover-traffic padding",
  "NOISE_PAD_MODE":"padding rate mode (constant / topup)",
  "TOR_USE_BRIDGES":"Tor via obfs4 bridges only",
  "WARP_FAIL_THRESHOLD":"consecutive warp=off polls before auto-shutdown",
}

def read_env():
    if not os.path.exists(ENV):
        print(f"profiles: {ENV} not found", file=sys.stderr); sys.exit(1)
    return open(ENV, encoding="utf-8").read().splitlines()

def get_val(lines, key):
    for l in lines:
        s = l.strip()
        if s.startswith(key + "="):
            return s.split("=", 1)[1]
    return None

def which_profile(lines):
    """Name the profile that matches the current .env, or None."""
    for name, flags in PROFILES.items():
        if all(get_val(lines, k) == v for k, v in flags.items()):
            return name
    return None

def cmd_show():
    lines = read_env()
    active = which_profile(lines)
    print(f"\n=== nullexit config (current){'  — profile: ' + active if active else '  — custom (no exact profile match)'} ===\n")
    for k, d in META.items():
        v = get_val(lines, k)
        print(f"  {k:26} = {str(v):9} · {d}")
    print("\n  Read-only. 'list' to see profiles, 'apply <name>' for a known-good bundle.")

def cmd_list():
    lines = read_env()
    print()
    for name, flags in PROFILES.items():
        print(f"  ▸ {name} — {DESC[name]}")
        for k, v in flags.items():
            cur = get_val(lines, k)
            print(f"      {k:26} → {v}{'' if cur == v else '   (now: ' + str(cur) + ')'}")
        print()

def diff_for(name):
    lines = read_env()
    return [(k, get_val(lines, k), v) for k, v in PROFILES[name].items() if get_val(lines, k) != v]

def cmd_preview(name):
    if name not in PROFILES:
        print(f"unknown profile '{name}' (try: {', '.join(PROFILES)})", file=sys.stderr); sys.exit(2)
    ch = diff_for(name)
    print(f"\nprofile '{name}' — {DESC[name]}\n")
    if not ch:
        print("  already applied — no changes."); return
    print("  would change:")
    for k, cur, v in ch:
        print(f"    {k:26} {cur} → {v}")
    print("\n  Preview only — nothing written, network untouched.")

def set_key(lines, key, val):
    for i, l in enumerate(lines):
        if l.strip().startswith(key + "="):
            lead = l[:len(l) - len(l.lstrip())]
            lines[i] = f"{lead}{key}={val}"
            return
    lines.append(f"{key}={val}")

def cmd_apply(name):
    if name not in PROFILES:
        print(f"unknown profile '{name}' (try: {', '.join(PROFILES)})", file=sys.stderr); sys.exit(2)
    ch = diff_for(name)
    if not ch:
        print(f"profile '{name}' already applied — no changes."); return
    lines = read_env()
    bak = f"{ENV}.bak.{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(ENV, bak)
    for k, v in PROFILES[name].items():
        set_key(lines, k, v)
    with open(ENV, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\napplied '{name}' to {ENV}  (backup: {bak})\n")
    for k, cur, v in ch:
        print(f"    {k:26} {cur} → {v}")
    print("\n  ⚠️  .env only — your LIVE gateway is UNCHANGED. Apply with:  ./toggle.sh --restart")

cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
arg = sys.argv[2] if len(sys.argv) > 2 else ""
{"show": cmd_show, "list": cmd_list,
 "preview": (lambda: cmd_preview(arg)), "apply": (lambda: cmd_apply(arg))}.get(cmd, cmd_show)()
PY
