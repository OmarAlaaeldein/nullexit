tell application "Finder" to set scriptDir to POSIX path of (container of (path to me) as alias)
tell application "Terminal"
	activate
	do script "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; cd " & quoted form of scriptDir & "; clear; echo \"Checking Gateway Status...\"; if docker compose ps --status running | grep -q 'warp'; then echo -e \"\\nGateway is RUNNING. Stopping it now...\"; docker compose down; echo -e \"\\nGateway has been STOPPED.\"; else echo -e \"\\nGateway is STOPPED. Starting it now...\"; docker compose up -d; echo -e \"\\nGateway has been STARTED.\"; fi; echo -e \"\\nYou can close this window.\""
end tell
