tell application "Finder" to set scriptDir to POSIX path of (container of (path to me) as alias)
tell application "Terminal"
	activate
	do script "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; cd " & quoted form of scriptDir & "; clear; echo \"Checking Gateway Status...\"; if docker compose ps --status running | grep -q 'warp'; then echo -e \"\\nGateway is RUNNING. Stopping it now...\"; docker compose down; echo -e \"\\nGateway has been STOPPED.\"; else echo -e \"\\nGateway is STOPPED. Starting it now...\"; colima status >/dev/null 2>&1 || colima start --memory 0.6; if [ -f \"adguard/conf/AdGuardHome.yaml\" ] && [ ! -s \"adguard/conf/AdGuardHome.yaml\" ]; then rm -f \"adguard/conf/AdGuardHome.yaml\"; echo \"Removed corrupted empty AdGuardHome.yaml to prevent crash loop.\"; fi; docker compose up -d; echo -e \"\\nGateway has been STARTED.\"; fi; echo -e \"\\nYou can close this window.\""
end tell
