package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	queryLogPath  = "/adguard_work/data/querylog.json"
	procKmsgPath  = "/proc/kmsg"
	outputLogPath = "/app/blocked.log"
)

func logMessage(msg string) {
	// Always log in UTC with an explicit marker. The routing-fix image is
	// Alpine (no tzdata), so time.Now() already fell back to UTC — but pin it
	// so the format can't silently flip to local time if tzdata is ever added.
	// AdGuard's querylog.json is now UTC too (TZ=UTC in docker-compose.yml).
	timestamp := time.Now().UTC().Format("2006-01-02 15:04:05") + " UTC"
	formattedMsg := fmt.Sprintf("%s %s\n", timestamp, msg)
	fmt.Print(formattedMsg)

	f, err := os.OpenFile(outputLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("Error writing to log file: %v\n", err)
		return
	}
	defer f.Close()
	f.WriteString(formattedMsg)
}

func tailFile(filepath string, out chan<- string) {
	for {
		if _, err := os.Stat(filepath); os.IsNotExist(err) {
			time.Sleep(1 * time.Second)
			continue
		}
		break
	}

	f, err := os.Open(filepath)
	if err != nil {
		log.Printf("Error opening file %s: %v\n", filepath, err)
		return
	}
	defer func() {
		if f != nil {
			f.Close()
		}
	}()

	// Seek to end
	f.Seek(0, io.SeekEnd)
	reader := bufio.NewReader(f)

	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				stat, err := os.Stat(filepath)
				if err == nil {
					currentOffset, _ := f.Seek(0, io.SeekCurrent)
					if stat.Size() < currentOffset {
						// File truncated or rotated
						f.Close()
						for {
							if _, err := os.Stat(filepath); os.IsNotExist(err) {
								time.Sleep(1 * time.Second)
								continue
							}
							break
						}
						f, _ = os.Open(filepath)
						reader = bufio.NewReader(f)
						continue
					}
				}
				time.Sleep(500 * time.Millisecond)
				continue
			}
			log.Printf("Error reading file %s: %v\n", filepath, err)
			time.Sleep(1 * time.Second)
			continue
		}
		out <- line
	}
}

type adguardLogEntry struct {
	IP     string `json:"IP"`
	QH     string `json:"QH"`
	QT     string `json:"QT"`
	Result struct {
		IsFiltered bool `json:"IsFiltered"`
		Reason     int  `json:"Reason"`
		Rules      []struct {
			Text string `json:"Text"`
		} `json:"Rules"`
	} `json:"Result"`
}

func monitorDNS() {
	logMessage("[System] Starting DNS block logger...")
	lines := make(chan string)
	go tailFile(queryLogPath, lines)

	reasonMap := map[int]string{
		2: "CustomRule",
		3: "BlockList",
		4: "SafeBrowsing",
		5: "ParentalControl",
		6: "SafeSearch",
		7: "BlockedService",
	}

	for line := range lines {
		var data adguardLogEntry
		if err := json.Unmarshal([]byte(line), &data); err != nil {
			continue
		}

		res := data.Result
		if res.IsFiltered || (res.Reason != 0 && res.Reason != 1) {
			qh := data.QH
			if qh == "" {
				qh = "unknown"
			}
			qt := data.QT
			if qt == "" {
				qt = "unknown"
			}
			clientIP := data.IP
			if clientIP == "" {
				clientIP = "unknown"
			}

			ruleText := "unknown rule"
			if len(res.Rules) > 0 && res.Rules[0].Text != "" {
				ruleText = res.Rules[0].Text
			}

			reasonStr, ok := reasonMap[res.Reason]
			if !ok {
				reasonStr = fmt.Sprintf("Reason-%d", res.Reason)
			}

			logMessage(fmt.Sprintf("[DNS] Blocked %s (Type: %s) for client %s | Reason: %s | Rule: %s", qh, qt, clientIP, reasonStr, ruleText))
		}
	}
}

func monitorIPs() {
	logMessage("[System] Starting IP block logger...")
	
	prefixRe := regexp.MustCompile(`(IP_BLOCK_[A-Z_]+):`)
	srcRe := regexp.MustCompile(`SRC=([0-9a-fA-F\.:]+)`)
	dstRe := regexp.MustCompile(`DST=([0-9a-fA-F\.:]+)`)
	protoRe := regexp.MustCompile(`PROTO=([A-Z0-9]+)`)
	sptRe := regexp.MustCompile(`SPT=(\d+)`)
	dptRe := regexp.MustCompile(`DPT=(\d+)`)
	inRe := regexp.MustCompile(`IN=([a-zA-Z0-9\.\-_]+)`)
	outRe := regexp.MustCompile(`OUT=([a-zA-Z0-9\.\-_]+)`)

	f, err := os.Open(procKmsgPath)
	if err != nil {
		if os.IsPermission(err) {
			logMessage("[System] ERROR: Insufficient permissions to read /proc/kmsg. Enable CAP_SYSLOG.")
		} else {
			logMessage(fmt.Sprintf("[System] ERROR in IP logger: %v", err))
		}
		return
	}
	defer f.Close()

	reader := bufio.NewReader(f)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			logMessage(fmt.Sprintf("[System] ERROR reading kmsg: %v", err))
			time.Sleep(1 * time.Second)
			continue
		}

		if strings.Contains(line, "IP_BLOCK") {
			match := prefixRe.FindStringSubmatch(line)
			if len(match) > 1 {
				prefix := match[1]
				
				src := "unknown"
				if m := srcRe.FindStringSubmatch(line); len(m) > 1 {
					src = m[1]
				}
				
				dst := "unknown"
				if m := dstRe.FindStringSubmatch(line); len(m) > 1 {
					dst = m[1]
				}
				
				proto := "unknown"
				if m := protoRe.FindStringSubmatch(line); len(m) > 1 {
					proto = m[1]
				}
				
				spt := ""
				if m := sptRe.FindStringSubmatch(line); len(m) > 1 {
					spt = m[1]
				}
				
				dpt := ""
				if m := dptRe.FindStringSubmatch(line); len(m) > 1 {
					dpt = m[1]
				}
				
				inIf := ""
				if m := inRe.FindStringSubmatch(line); len(m) > 1 {
					inIf = m[1]
				}
				
				outIf := ""
				if m := outRe.FindStringSubmatch(line); len(m) > 1 {
					outIf = m[1]
				}

				direction := "inbound"
				if strings.HasSuffix(prefix, "DST") {
					direction = "outbound"
				}

				listType := "MALICIOUS"
				if !strings.Contains(prefix, "MALICIOUS") {
					parts := strings.Split(prefix, "_")
					if len(parts) >= 3 {
						listType = "GEO_" + parts[2]
					}
				}

				portStr := ""
				if dpt != "" {
					portStr = ":" + dpt
				}
				
				srcPortStr := ""
				if spt != "" {
					srcPortStr = ":" + spt
				}
				
				ifStr := ""
				if inIf != "" && outIf != "" {
					ifStr = fmt.Sprintf("IF: %s->%s", inIf, outIf)
				} else if inIf != "" || outIf != "" {
					ifStr = fmt.Sprintf("IF: %s%s", inIf, outIf)
				}

				logMessage(fmt.Sprintf("[IP] Blocked %s to %s%s (Proto: %s) from %s%s (%s) | List: %s", direction, dst, portStr, proto, src, srcPortStr, ifStr, listType))
			}
		}
	}
}

func main() {
	logMessage("[System] Nullexit Block Logger starting...")

	go monitorDNS()
	monitorIPs()
}
