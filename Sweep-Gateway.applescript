tell application "Finder" to set scriptDir to POSIX path of (container of (path to me) as alias)
try
	do shell script "cd " & quoted form of scriptDir & " && ./scripts/crypto.sh --verify"
on error errMsg
	display dialog "nullexit integrity check FAILED — sweep will not run." & return & return & "A signed file (scripts/sweep.sh, scripts/common.sh, …) no longer matches .signatures. If you edited it on purpose, re-sign with:" & return & "./scripts/crypto.sh --sign" & return & return & errMsg buttons {"Abort"} default button "Abort" with icon stop
	return
end try
tell application "Terminal"
	activate
	do script "cd " & quoted form of scriptDir & " && bash scripts/sweep.sh"
end tell
