tell application "Finder" to set scriptDir to POSIX path of (container of (path to me) as alias)
try
	do shell script "true" with administrator privileges
on error
	return
end try
tell application "Terminal"
	activate
	do script "cd " & quoted form of scriptDir & "; ./toggle.sh"
end tell
