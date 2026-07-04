package main

import (
	"bufio"
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	BlackListPath = "black_list.txt"
	WhiteListPath = "white_list.txt"
	OutputPath    = "adguard/work/userfilters/compiled_rules.txt"
	IpOutputPath  = "adguard/work/userfilters/ip_blocklist.ipset"
	IpCacheDir    = "adguard/work/userfilters/cache/ip"
	CacheDir      = "adguard/work/userfilters/cache"
)

var CoreLists = []string{
	"https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
	"https://raw.githubusercontent.com/anudeepND/blacklist/master/facebook.txt",
	"https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt",
	"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.samsung.txt",
	"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.apple.txt",
	"https://abp.oisd.nl/basic/",
	"https://adaway.org/hosts.txt",
	"https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext",
	"https://raw.githubusercontent.com/nextdns/cname-cloaking-blocklist/master/domains",
}

var MediumAdditions = []string{
	"https://raw.githubusercontent.com/lightswitch05/hosts/master/docs/lists/facebook-extended.txt",
	"https://someonewhocares.org/hosts/zero/hosts",
	"https://urlhaus.abuse.ch/downloads/hostfile/",
}

var HeavyAdditions = []string{
	"https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
	"https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV-AGH.txt",
	"https://raw.githubusercontent.com/DandelionSprout/adfilt/master/GameConsoleAdblockList.txt",
}

var IpBlockLists = []string{
	"https://feodotracker.abuse.ch/downloads/ipblocklist.txt",
	"https://www.spamhaus.org/drop/drop.txt",
	"https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt",
	"https://cinsscore.com/list/ci-badguys.txt",
}

func getProfiles() map[string][]string {
	profiles := make(map[string][]string)

	light := append([]string(nil), CoreLists...)
	light = append(light, "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/light.txt")
	profiles["light"] = light

	medium := append([]string(nil), CoreLists...)
	medium = append(medium, MediumAdditions...)
	medium = append(medium, "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/multi.txt")
	profiles["medium"] = medium

	heavy := append([]string(nil), CoreLists...)
	heavy = append(heavy, MediumAdditions...)
	heavy = append(heavy, HeavyAdditions...)
	heavy = append(heavy, "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt")
	profiles["heavy"] = heavy

	return profiles
}

func loadEnvProfile() string {
	profile := "medium"

	if bytesData, err := os.ReadFile(".env"); err == nil {
		scanner := bufio.NewScanner(strings.NewReader(string(bytesData)))
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line != "" && !strings.HasPrefix(line, "#") {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) == 2 {
					key := strings.TrimSpace(parts[0])
					val := strings.TrimSpace(parts[1])
					if key == "GATEWAY_RULE_PROFILE" {
						val = strings.Trim(val, "\"'")
						profile = strings.ToLower(val)
					}
				}
			}
		}
	} else if !os.IsNotExist(err) {
		fmt.Printf("Warning: Failed to read .env file for profile configuration (%v). Using default.\n", err)
	}

	if envVal := os.Getenv("GATEWAY_RULE_PROFILE"); envVal != "" {
		profile = strings.ToLower(envVal)
	}

	profiles := getProfiles()
	if _, exists := profiles[profile]; !exists {
		fmt.Printf("Warning: Profile '%s' is invalid. Falling back to 'medium'.\n", profile)
		profile = "medium"
	}
	return profile
}

func loadDomains(filepath string) map[string]bool {
	domains := make(map[string]bool)
	if bytesData, err := os.ReadFile(filepath); err == nil {
		scanner := bufio.NewScanner(strings.NewReader(string(bytesData)))
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line != "" && !strings.HasPrefix(line, "#") {
				domains[strings.ToLower(line)] = true
			}
		}
	}
	return domains
}

func parseDomainsFromContent(content string) map[string]bool {
	domains := make(map[string]bool)
	scanner := bufio.NewScanner(strings.NewReader(content))
	ipRegex := regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$`)
	agRegex := regexp.MustCompile(`^\|\|([a-z0-9.-]+)\^$`)
	domainRegex := regexp.MustCompile(`^[a-z0-9.-]+$`)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "!") || strings.HasPrefix(line, "[") {
			continue
		}
		parts := strings.SplitN(line, "#", 2)
		line = strings.TrimSpace(parts[0])
		if line == "" {
			continue
		}

		fields := strings.Fields(line)
		var rule string
		if len(fields) >= 2 {
			if ipRegex.MatchString(fields[0]) {
				rule = fields[1]
			} else {
				rule = fields[0]
			}
		} else {
			rule = fields[0]
		}

		rule = strings.TrimSpace(strings.ToLower(rule))

		var domain string
		if m := agRegex.FindStringSubmatch(rule); m != nil {
			domain = m[1]
		} else if domainRegex.MatchString(rule) {
			domain = rule
		} else {
			domain = rule
		}

		if domain != "" && domain != "localhost" && domain != "0.0.0.0" && domain != "127.0.0.1" && domain != "broadcasthost" {
			domains[domain] = true
		}
	}
	return domains
}

func getAdguardNativeLists() []string {
	yamlPath := "adguard/conf/AdGuardHome.yaml"
	var enabledUrls []string
	if _, err := os.Stat(yamlPath); os.IsNotExist(err) {
		return enabledUrls
	}

	contentBytes, err := os.ReadFile(yamlPath)
	if err != nil {
		fmt.Printf("Warning: Failed to parse AdGuardHome.yaml for native lists (%v)\n", err)
		return enabledUrls
	}
	content := string(contentBytes)

	filtersRegex := regexp.MustCompile(`(?ms)^filters:(.*?)(?:^[a-zA-Z_]+:|\z)`)
	match := filtersRegex.FindStringSubmatch(content)
	if len(match) > 1 {
		filtersText := match[1]
		blocks := strings.Split(filtersText, "\n  - ")
		urlRegex := regexp.MustCompile(`url:\s*(\S+)`)

		for _, block := range blocks {
			if strings.TrimSpace(block) == "" {
				continue
			}
			if strings.Contains(block, "enabled: true") {
				urlMatch := urlRegex.FindStringSubmatch(block)
				if len(urlMatch) > 1 {
					url := urlMatch[1]
					if !strings.Contains(url, "compiled_rules.txt") {
						enabledUrls = append(enabledUrls, url)
					}
				}
			}
		}
	}
	return enabledUrls
}

func getAdguardCompiledRulesCachePath() string {
	yamlPath := "adguard/conf/AdGuardHome.yaml"
	if _, err := os.Stat(yamlPath); os.IsNotExist(err) {
		return ""
	}

	contentBytes, err := os.ReadFile(yamlPath)
	if err != nil {
		fmt.Printf("Warning: Failed to resolve compiled_rules.txt cache path (%v)\n", err)
		return ""
	}
	content := string(contentBytes)

	filtersRegex := regexp.MustCompile(`(?ms)^filters:(.*?)(?:^[a-zA-Z_]+:|\z)`)
	match := filtersRegex.FindStringSubmatch(content)
	if len(match) > 1 {
		blocks := strings.Split(match[1], "\n  - ")
		idRegex := regexp.MustCompile(`id:\s*(\d+)`)
		for _, block := range blocks {
			if !strings.Contains(block, "compiled_rules.txt") {
				continue
			}
			idMatch := idRegex.FindStringSubmatch(block)
			if len(idMatch) > 1 {
				return fmt.Sprintf("adguard/work/data/filters/%s.txt", idMatch[1])
			}
		}
	}
	return ""
}

func handleFetchError(urlStr string, cacheFile string, err error) map[string]bool {
	if _, statErr := os.Stat(cacheFile); statErr == nil {
		fmt.Printf(" -> Warning: Failed to fetch %s (%v). Falling back to expired local cache.\n", urlStr, err)
		content, readErr := os.ReadFile(cacheFile)
		if readErr == nil {
			domains := parseDomainsFromContent(string(content))
			fmt.Printf(" -> Loaded from expired cache (%d domains).\n", len(domains))
			return domains
		}
		fmt.Printf(" -> Warning: Failed to read expired cache (%v). Using local lists only.\n", readErr)
	} else {
		fmt.Printf(" -> Warning: Failed to fetch %s (%v). Using local lists only for this source.\n", urlStr, err)
	}
	return make(map[string]bool)
}

func fetchRemoteDomains(urlStr string) map[string]bool {
	os.MkdirAll(CacheDir, 0755)

	hash := md5.Sum([]byte(urlStr))
	urlHash := hex.EncodeToString(hash[:])
	cacheFile := filepath.Join(CacheDir, fmt.Sprintf("%s.txt", urlHash))

	if stat, err := os.Stat(cacheFile); err == nil {
		fileAge := time.Since(stat.ModTime()).Seconds()
		if fileAge < 86400 {
			fmt.Printf("Loading remote blacklist from cache: %s\n", urlStr)
			content, err := os.ReadFile(cacheFile)
			if err == nil {
				domains := parseDomainsFromContent(string(content))
				fmt.Printf(" -> Loaded from cache (copy is %.1f hours old, %d domains).\n", fileAge/3600.0, len(domains))
				return domains
			}
			fmt.Printf(" -> Warning: Failed to read cache file %s (%v). Re-fetching...\n", cacheFile, err)
		}
	}

	fmt.Printf("Fetching remote blacklist from: %s ...\n", urlStr)

	req, err := http.NewRequest("GET", urlStr, nil)
	if err != nil {
		return handleFetchError(urlStr, cacheFile, err)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return handleFetchError(urlStr, cacheFile, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return handleFetchError(urlStr, cacheFile, fmt.Errorf("HTTP %d", resp.StatusCode))
	}

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return handleFetchError(urlStr, cacheFile, err)
	}

	content := string(bodyBytes)
	domains := parseDomainsFromContent(content)

	if len(domains) < 10 {
		return handleFetchError(urlStr, cacheFile, fmt.Errorf("Sanity check failed: only found %d domains. Possible 404 or bad URL", len(domains)))
	}

	err = os.WriteFile(cacheFile, bodyBytes, 0644)
	if err != nil {
		fmt.Printf(" -> Warning: Failed to save cache file (%v)\n", err)
	}

	fmt.Printf(" -> Successfully fetched and cached %d domains.\n", len(domains))
	return domains
}

func optimizeSubdomains(domains map[string]bool, listName string) map[string]bool {
	fmt.Printf("Optimizing %s by removing redundant subdomains...\n", listName)
	rawCount := len(domains)
	if rawCount == 0 {
		return make(map[string]bool)
	}

	optimized := make(map[string]bool)
	for domain := range domains {
		if strings.ContainsAny(domain, "|^@$/") {
			optimized[domain] = true
			continue
		}

		parts := strings.Split(domain, ".")
		hasParent := false

		for i := 1; i < len(parts)-1; i++ {
			parent := strings.Join(parts[i:], ".")
			if domains[parent] {
				hasParent = true
				break
			}
		}

		if !hasParent {
			optimized[domain] = true
		}
	}

	saved := rawCount - len(optimized)
	reduction := float64(0)
	if rawCount > 0 {
		reduction = (float64(saved) / float64(rawCount)) * 100
	}
	fmt.Printf(" -> Reduced %s from %d to %d domains (-%d / %.1f%% reduction).\n", listName, rawCount, len(optimized), saved, reduction)
	return optimized
}

func parseIpsFromContent(content string) map[string]bool {
	ips := make(map[string]bool)
	scanner := bufio.NewScanner(strings.NewReader(content))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) > 0 {
			token := strings.TrimRight(fields[0], ";,")
			if _, err := netip.ParsePrefix(token); err == nil {
				ips[token] = true
			} else if _, err := netip.ParseAddr(token); err == nil {
				ips[token] = true
			}
		}
	}
	return ips
}

func handleIpFetchError(urlStr string, cacheFile string, err error) map[string]bool {
	if _, statErr := os.Stat(cacheFile); statErr == nil {
		fmt.Printf(" -> Warning: fetch failed (%v). Falling back to stale cache.\n", err)
		content, readErr := os.ReadFile(cacheFile)
		if readErr == nil {
			ips := parseIpsFromContent(string(content))
			fmt.Printf(" -> %d IPs loaded from stale cache.\n", len(ips))
			return ips
		}
		fmt.Printf(" -> Warning: stale cache also failed (%v).\n", readErr)
	} else {
		fmt.Printf(" -> Warning: %s failed (%v). No cache available. Skipping.\n", urlStr, err)
	}
	return make(map[string]bool)
}

func fetchRemoteIps(urlStr string) map[string]bool {
	os.MkdirAll(IpCacheDir, 0755)

	hash := md5.Sum([]byte(urlStr))
	urlHash := hex.EncodeToString(hash[:])
	cacheFile := filepath.Join(IpCacheDir, fmt.Sprintf("%s.txt", urlHash))

	if stat, err := os.Stat(cacheFile); err == nil {
		fileAge := time.Since(stat.ModTime()).Seconds()
		if fileAge < 86400 {
			fmt.Printf("Loading IP feed from cache: %s\n", urlStr)
			content, err := os.ReadFile(cacheFile)
			if err == nil {
				ips := parseIpsFromContent(string(content))
				fmt.Printf(" -> %d IPs (cache is %.1fh old).\n", len(ips), fileAge/3600.0)
				return ips
			}
			fmt.Printf(" -> Warning: cache read failed (%v). Re-fetching...\n", err)
		}
	}

	fmt.Printf("Fetching IP feed: %s ...\n", urlStr)
	req, err := http.NewRequest("GET", urlStr, nil)
	if err != nil {
		return handleIpFetchError(urlStr, cacheFile, err)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return handleIpFetchError(urlStr, cacheFile, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return handleIpFetchError(urlStr, cacheFile, fmt.Errorf("HTTP %d", resp.StatusCode))
	}

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return handleIpFetchError(urlStr, cacheFile, err)
	}

	content := string(bodyBytes)
	ips := parseIpsFromContent(content)
	if len(ips) < 1 {
		return handleIpFetchError(urlStr, cacheFile, fmt.Errorf("Sanity check failed: only %d IPs found. Possible 404", len(ips)))
	}

	err = os.WriteFile(cacheFile, bodyBytes, 0644)
	if err != nil {
		fmt.Printf(" -> Warning: cache write failed (%v)\n", err)
	}

	fmt.Printf(" -> %d IPs fetched and cached.\n", len(ips))
	return ips
}

func compileIpBlocklist() int {
	fmt.Println("\n─── IP Blocklist Compilation ───")

	allIps := make(map[string]bool)
	var mu sync.Mutex
	var wg sync.WaitGroup

	maxThreads := 8
	if len(IpBlockLists) < 8 {
		maxThreads = len(IpBlockLists)
	}
	semaphore := make(chan struct{}, maxThreads)

	for _, urlStr := range IpBlockLists {
		wg.Add(1)
		go func(u string) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			ips := fetchRemoteIps(u)
			mu.Lock()
			for ip := range ips {
				allIps[ip] = true
			}
			mu.Unlock()
		}(urlStr)
	}
	wg.Wait()

	fmt.Printf("Total unique entries before filtering: %d\n", len(allIps))

	reservedStr := []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
		"127.0.0.0/8",
		"169.254.0.0/16",
		"100.64.0.0/10",
		"0.0.0.0/8",
	}
	var reserved []netip.Prefix
	for _, s := range reservedStr {
		p, _ := netip.ParsePrefix(s)
		reserved = append(reserved, p)
	}

	cleanIps := make(map[string]bool)
	for entry := range allIps {
		var prefix netip.Prefix
		p, err := netip.ParsePrefix(entry)
		if err != nil {
			addr, err2 := netip.ParseAddr(entry)
			if err2 != nil {
				continue
			}
			prefix = netip.PrefixFrom(addr, addr.BitLen())
		} else {
			prefix = p
		}

		overlaps := false
		for _, r := range reserved {
			if r.Overlaps(prefix) {
				overlaps = true
				break
			}
		}
		if !overlaps {
			cleanIps[entry] = true
		}
	}

	removed := len(allIps) - len(cleanIps)
	if removed > 0 {
		fmt.Printf(" -> Removed %d private/reserved entries.\n", removed)
	}
	fmt.Printf(" -> Final IP blocklist: %d entries.\n", len(cleanIps))

	os.MkdirAll(filepath.Dir(IpOutputPath), 0755)

	f, err := os.Create(IpOutputPath)
	if err != nil {
		fmt.Printf("Error writing IP output file: %v\n", err)
		return len(cleanIps)
	}
	defer f.Close()

	f.WriteString("# nullexit Compiled IP Blocklist\n")
	f.WriteString("# Sources: Feodo Tracker, Spamhaus DROP/EDROP, Emerging Threats, CINS\n")
	f.WriteString(fmt.Sprintf("# Entries: %d\n\n", len(cleanIps)))

	f.WriteString("create block_malicious_new hash:net maxelem 200000 -exist\n")

	var sortedIps []string
	for ip := range cleanIps {
		sortedIps = append(sortedIps, ip)
	}
	sort.Strings(sortedIps)

	for _, ip := range sortedIps {
		f.WriteString(fmt.Sprintf("add block_malicious_new %s -exist\n", ip))
	}

	f.WriteString("create block_malicious hash:net maxelem 200000 -exist\n")
	f.WriteString("swap block_malicious block_malicious_new\n")
	f.WriteString("destroy block_malicious_new\n")

	fmt.Printf("IP blocklist written to %s\n", IpOutputPath)
	return len(cleanIps)
}

func main() {
	profile := loadEnvProfile()
	fmt.Printf("Active memory profile: '%s'\n", strings.ToUpper(profile))

	localBlackList := loadDomains(BlackListPath)
	whiteList := loadDomains(WhiteListPath)

	blackList := make(map[string]bool)
	for k := range localBlackList {
		blackList[k] = true
	}

	profiles := getProfiles()
	urlsToFetch := profiles[profile]

	fmt.Printf("\nStarting concurrent downloads for %d lists...\n", len(urlsToFetch))
	startTime := time.Now()

	var mu sync.Mutex
	var wg sync.WaitGroup

	maxThreads := 16
	if len(urlsToFetch) < 16 {
		maxThreads = len(urlsToFetch)
	}
	semaphore := make(chan struct{}, maxThreads)

	for _, urlStr := range urlsToFetch {
		wg.Add(1)
		go func(u string) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			domains := fetchRemoteDomains(u)
			mu.Lock()
			for d := range domains {
				blackList[d] = true
			}
			mu.Unlock()
		}(urlStr)
	}
	wg.Wait()

	fmt.Printf("Finished concurrent downloads in %.2f seconds using %d threads.\n", time.Since(startTime).Seconds(), maxThreads)

	adguardNativeUrls := getAdguardNativeLists()
	var adguardNativeDomains map[string]bool
	if len(adguardNativeUrls) > 0 {
		fmt.Printf("\nFetching %d AdGuard native list(s) for deduplication...\n", len(adguardNativeUrls))
		adguardNativeDomains = make(map[string]bool)

		maxNativeThreads := 4
		if len(adguardNativeUrls) < 4 {
			maxNativeThreads = len(adguardNativeUrls)
		}
		nativeSemaphore := make(chan struct{}, maxNativeThreads)

		for _, urlStr := range adguardNativeUrls {
			wg.Add(1)
			go func(u string) {
				defer wg.Done()
				nativeSemaphore <- struct{}{}
				defer func() { <-nativeSemaphore }()

				domains := fetchRemoteDomains(u)
				mu.Lock()
				for d := range domains {
					adguardNativeDomains[d] = true
				}
				mu.Unlock()
			}(urlStr)
		}
		wg.Wait()

		if len(adguardNativeDomains) > 0 {
			fmt.Println("Deduplicating compiled rules against AdGuard native lists...")
			originalSize := len(blackList)
			for d := range adguardNativeDomains {
				delete(blackList, d)
			}
			fmt.Printf(" -> Removed %d redundant rules already covered by AdGuard.\n", originalSize-len(blackList))
		}
	}

	var contradictions []string
	for d := range whiteList {
		if blackList[d] {
			contradictions = append(contradictions, d)
		}
	}

	if len(contradictions) > 0 {
		fmt.Printf("Detected %d contradictions. Whitelist taking priority.\n", len(contradictions))
		sort.Strings(contradictions)
		for _, domain := range contradictions {
			if localBlackList[domain] {
				fmt.Printf(" -> Removed local blacklist domain: %s\n", domain)
			}
			delete(blackList, domain)
		}
	}

	blackList = optimizeSubdomains(blackList, "blacklist")
	whiteList = optimizeSubdomains(whiteList, "whitelist")

	os.MkdirAll(filepath.Dir(OutputPath), 0755)
	outFile, err := os.Create(OutputPath)
	if err != nil {
		fmt.Printf("Error creating output file: %v\n", err)
		return
	}
	defer outFile.Close()

	outFile.WriteString("! Custom Compiled Rules (Auto-Generated)\n")
	outFile.WriteString(fmt.Sprintf("! Memory Profile: %s\n", strings.ToUpper(profile)))
	outFile.WriteString(fmt.Sprintf("! Total Block Rules: %d\n", len(blackList)))
	outFile.WriteString(fmt.Sprintf("! Native AdGuard Rules: %d\n", len(adguardNativeDomains)))
	outFile.WriteString(fmt.Sprintf("! Total Whitelist Rules: %d\n\n", len(whiteList)))

	outFile.WriteString("! --- Blacklist Rules ---\n")

	var sortedBlacklist []string
	for d := range blackList {
		sortedBlacklist = append(sortedBlacklist, d)
	}
	sort.Strings(sortedBlacklist)

	for _, domain := range sortedBlacklist {
		if strings.Contains(domain, "$") {
			parts := strings.SplitN(domain, "$", 2)
			dom, mod := parts[0], parts[1]
			if strings.HasPrefix(dom, "||") {
				if strings.HasSuffix(dom, "^") {
					outFile.WriteString(fmt.Sprintf("%s$%s\n", dom, mod))
				} else {
					outFile.WriteString(fmt.Sprintf("%s^$%s\n", dom, mod))
				}
			} else {
				outFile.WriteString(fmt.Sprintf("||%s^$%s\n", dom, mod))
			}
		} else if strings.HasPrefix(domain, "/") || strings.HasPrefix(domain, "|") || strings.HasSuffix(domain, "|") || strings.HasSuffix(domain, "^") {
			outFile.WriteString(fmt.Sprintf("%s\n", domain))
		} else {
			outFile.WriteString(fmt.Sprintf("||%s^\n", domain))
		}
	}

	outFile.WriteString("\n! --- Whitelist Rules ---\n")
	var sortedWhitelist []string
	for d := range whiteList {
		sortedWhitelist = append(sortedWhitelist, d)
	}
	sort.Strings(sortedWhitelist)

	for _, domain := range sortedWhitelist {
		if strings.HasPrefix(domain, "/") || strings.HasPrefix(domain, "|") || strings.HasSuffix(domain, "|") || strings.HasSuffix(domain, "^") || strings.HasPrefix(domain, "@@") {
			rule := domain
			if !strings.HasPrefix(domain, "@@") {
				rule = "@@" + domain
			}
			outFile.WriteString(fmt.Sprintf("%s\n", rule))
		} else {
			outFile.WriteString(fmt.Sprintf("@@||%s^\n", domain))
		}
	}

	fmt.Printf("\nSuccessfully compiled %d block rules and %d allow rules to %s\n", len(blackList), len(whiteList), OutputPath)

	cachedFilterPath := getAdguardCompiledRulesCachePath()
	if cachedFilterPath != "" {
		input, err := os.ReadFile(OutputPath)
		if err == nil {
			err = os.WriteFile(cachedFilterPath, input, 0644)
			if err == nil {
				fmt.Printf("Updated AdGuard filter cache: %s\n", cachedFilterPath)
			} else {
				fmt.Printf("Warning: Could not update AdGuard filter cache %s (%v)\n", cachedFilterPath, err)
			}
		} else {
			fmt.Printf("Warning: Could not read OutputPath to copy to cache (%v)\n", err)
		}
	} else {
		fmt.Println("Warning: Could not determine compiled_rules.txt cache path from AdGuardHome.yaml; skipping cache update.")
	}

	adguardReachable := false

	dockerComposeYamlExists := false
	if _, err := os.Stat("docker-compose.yml"); err == nil {
		dockerComposeYamlExists = true
	}
	dockerPath, err := exec.LookPath("docker")
	if err == nil && dockerComposeYamlExists {
		cmd := exec.Command(dockerPath, "compose", "ps", "--status", "running", "-q", "adguardhome")
		out, err := cmd.Output()
		if err == nil && strings.TrimSpace(string(out)) != "" {
			fmt.Println("Force-recreating AdGuard Home container to drop persisted filter state...")
			upCmd := exec.Command(dockerPath, "compose", "up", "-d", "--force-recreate", "--no-deps", "adguardhome")
			err := upCmd.Run()
			if err == nil {
				fmt.Println("AdGuard Home force-recreated successfully.")
				time.Sleep(8 * time.Second)
				adguardReachable = true
			} else {
				fmt.Println("Failed to restart AdGuard Home. Is it running?")
			}
		}
	}

	if adguardReachable {
		agPass := "nullexit"
		if bytesData, err := os.ReadFile(".env"); err == nil {
			scanner := bufio.NewScanner(strings.NewReader(string(bytesData)))
			for scanner.Scan() {
				line := scanner.Text()
				if strings.HasPrefix(line, "ADGUARD_PASSWORD=") {
					parts := strings.SplitN(line, "=", 2)
					if len(parts) == 2 {
						agPass = strings.Trim(strings.TrimSpace(parts[1]), "\"'")
					}
					break
				}
			}
		}

		creds := base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("admin:%s", agPass)))
		req, err := http.NewRequest("POST", "http://127.0.0.1:3000/control/filtering/refresh", bytes.NewBuffer([]byte("{}")))
		if err == nil {
			req.Header.Set("Authorization", fmt.Sprintf("Basic %s", creds))
			req.Header.Set("Content-Type", "application/json")
			client := &http.Client{Timeout: 15 * time.Second}
			resp, err := client.Do(req)
			if err == nil {
				fmt.Printf("Triggered AdGuard filter refresh via REST API (HTTP=%d).\n", resp.StatusCode)
				resp.Body.Close()
			} else {
				fmt.Printf("Warning: AdGuard filter refresh API call failed (%v). New whitelist will not load until next refresh tick (~24h) or manual refresh.\n", err)
			}
		}
	}

	compileIpBlocklist()
}
