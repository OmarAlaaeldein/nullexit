import urllib.request
import urllib.error
import time
from html.parser import HTMLParser
import concurrent.futures

class ResourceParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        url = None
        if tag in ['img', 'script']:
            url = attrs.get('src')
        elif tag == 'link' and attrs.get('rel') == 'stylesheet':
            url = attrs.get('href')
        
        if url and url.startswith('http'):
            self.urls.add(url)

def fetch_url(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        urllib.request.urlopen(req, timeout=3)
        return True
    except Exception:
        return False

def measure_url(target_url):
    print(f"\nTesting {target_url} Load...")
    start_total = time.time()
    
    # Fetch main HTML
    try:
        req = urllib.request.Request(target_url, headers={'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'})
        response = urllib.request.urlopen(req, timeout=5)
        html = response.read().decode('utf-8', errors='ignore')
    except Exception as e:
        print(f"Failed to fetch {target_url}: {e}")
        return
        
    parser = ResourceParser()
    parser.feed(html)
    urls = list(parser.urls)
    print(f"Found {len(urls)} subresources to fetch (scripts, images, css)...")
    
    # Concurrently fetch subresources
    success_count = 0
    fail_count = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=30) as executor:
        results = list(executor.map(fetch_url, urls))
        
    success_count = sum(1 for r in results if r)
    fail_count = len(results) - success_count
    
    total_time = time.time() - start_total
    print(f"Time taken: {total_time:.2f} seconds")
    print(f"Successfully fetched: {success_count}, Failed/Blocked: {fail_count}")

urls_to_test = [
    "https://www.dailymail.co.uk/home/index.html",
    "https://www.cnet.com/",
    "https://www.independent.co.uk/"
]

for u in urls_to_test:
    measure_url(u)
