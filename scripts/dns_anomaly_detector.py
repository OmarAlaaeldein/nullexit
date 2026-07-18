#!/usr/bin/env python3
"""
nullexit DNS anomaly detector (v2) — report-only DNS-tunneling / DGA / C2 finder.

Replaces the v1 whole-FQDN Shannon-entropy + mean±3σ demo (which measured the
wrong scope, was fooled by short encoded labels, assumed a normal distribution
DNS names don't have, and ignored the volumetric signal that actually defines
tunneling). v2 keeps the "statistical, data-based, 100% local, no third-party
deps" spirit but detects far better:

  1. n-gram (character bigram) improbability of the SUBDOMAIN labels only,
     trained on YOUR querylog. Robust on short strings where Shannon entropy
     fails (entropy is capped at log2(len)); scores "doesn't look like real
     naming", which is what encoded tunneling labels are.
  2. per-registered-domain AGGREGATION (unique-subdomain count, query volume,
     suspicious record types) — a stream of high-improbability names under ONE
     domain is the real tunneling tell, not any single name.
  3. robust thresholds (median + k·MAD, resistant to CDN/cloud hash outliers)
     instead of mean±3σ on a non-normal distribution.
  4. a data-driven allowlist of YOUR frequent domains, so CloudFront/S3/telemetry
     hashes don't false-positive.

Report-only by design: a privacy gateway must never silently drop DNS on a
statistical trip (a false positive = "my internet broke"). It surfaces findings;
promoting a domain to an actual block stays a human/AdGuard-blocklist decision.

Footprint: single streaming pass (never loads the log into RAM); the model is a
~40×40 bigram table + a few floats + a small allowlist (a few KB on disk); per-
domain state is a handful of ints plus a subdomain set capped at 64.

Exit codes (scan): 0 = ran, clean · 1 = ran, anomalies found · 2 = FAILED to run
(no/corrupt model, unreadable or empty querylog) — a failure is never reported as
"clean". selftest exits 3 if the detection logic itself is broken.

Usage:
  dns_anomaly_detector.py learn [--log PATH] [--out PATH]   # train from querylog
  dns_anomaly_detector.py scan  [--log PATH] [--model PATH] [--recent N] [--quiet]
  dns_anomaly_detector.py selftest                          # prove it detects (exit 3 if broken)
  dns_anomaly_detector.py demo                              # human-readable showcase
"""
import argparse
import json
import math
import os
import random
import re
import sys
import time
from collections import defaultdict

DEFAULT_LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "adguard", "work", "data", "querylog.json")
DEFAULT_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", ".dns_baseline.json")
OUTPUT_LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "output.log")


def log_fail(msg):
    """Persist a hard failure to output.log (besides stderr) so a broken detector
    is on the record even when run headless (launchd/sweep/CI). Heisenbug-safe by
    construction: it only ever APPENDS to a separate file — it touches neither
    stdout/stderr (which sweep captures) nor any detection state, and a logging
    error is swallowed so it can never change what the detector does or returns."""
    try:
        with open(OUTPUT_LOG, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [dns-anomaly] FAIL: {msg}\n")
    except OSError:
        pass

ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789-_"
AIDX = {c: i for i, c in enumerate(ALPHABET)}
OTHER = len(ALPHABET)          # bucket for any char outside the alphabet
NSYM = len(ALPHABET) + 1
BEG = NSYM                     # start-of-label marker
NSTATES = NSYM + 1

# Minimal two-level public suffixes so eTLD+1 grouping is stable without shipping
# the full ~200 KB Public Suffix List. Exact PSL isn't needed — we only need a
# consistent grouping key per registered domain.
TWO_LEVEL = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "co.kr", "co.in", "co.za",
    "co.nz", "com.au", "net.au", "org.au", "com.br", "com.mx", "com.tr",
    "com.cn", "com.hk", "com.sg", "com.tw", "com.ar", "co.il", "ne.jp",
}


def sym(ch):
    return AIDX.get(ch, OTHER)


def registered_and_sub(qh):
    """Split a query host into (registered_domain, subdomain_labels_string)."""
    qh = qh.rstrip(".").lower()
    parts = qh.split(".")
    if len(parts) <= 2:
        return qh, ""
    last2 = ".".join(parts[-2:])
    reg_n = 3 if last2 in TWO_LEVEL else 2
    reg = ".".join(parts[-reg_n:])
    sub = ".".join(parts[:-reg_n])
    return reg, sub


def iter_querylog(path, recent=0):
    """Stream (QH, QT) from an AdGuard querylog. recent>0 keeps only the last N."""
    if recent > 0:
        # Bounded tail without loading the file: keep a ring buffer of raw lines.
        from collections import deque
        buf = deque(maxlen=recent)
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.strip():
                    buf.append(line)
        lines = buf
    else:
        lines = _line_reader(path)
    for line in lines:
        try:
            rec = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        qh = rec.get("QH")
        if not qh:
            continue
        qh = qh.strip().lower()
        if qh.endswith("in-addr.arpa") or qh.endswith("ip6.arpa"):
            continue
        yield qh, rec.get("QT", "")


def _line_reader(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if line.strip():
                yield line


# ─── n-gram model ────────────────────────────────────────────────────────────
def label_improbability(label, logp):
    """Mean -log2 P(char|prev) over a label. High = doesn't look like real naming."""
    if not label:
        return 0.0
    prev = BEG
    total = 0.0
    for ch in label:
        s = sym(ch)
        total += logp[prev][s]
        prev = s
    return total / len(label)


def name_score(sub, logp):
    """Worst-label improbability across the subdomain (tunneling hides in one label)."""
    if not sub:
        return 0.0
    return max(label_improbability(lbl, logp) for lbl in sub.split(".") if lbl)


def finalize_logp(counts):
    """Add-1 smoothed transition matrix → -log2 probabilities."""
    logp = [[0.0] * NSYM for _ in range(NSTATES)]
    for a in range(NSTATES):
        row_total = sum(counts[a]) + NSYM  # +NSYM for add-1 smoothing
        for b in range(NSYM):
            p = (counts[a][b] + 1) / row_total
            logp[a][b] = -math.log2(p)
    return logp


def learn(log_path, out_path):
    counts = [[0] * NSYM for _ in range(NSTATES)]
    reg_counts = defaultdict(int)
    reservoir = []          # sampled subdomain strings for threshold calibration
    RES_MAX = 6000
    seen = 0

    for qh, _qt in iter_querylog(log_path):
        reg, sub = registered_and_sub(qh)
        reg_counts[reg] += 1
        if not sub:
            continue
        for lbl in sub.split("."):
            prev = BEG
            for ch in lbl:
                s = sym(ch)
                counts[prev][s] += 1
                prev = s
        # Reservoir-sample subdomains (unbiased) for a robust score distribution.
        seen += 1
        if len(reservoir) < RES_MAX:
            reservoir.append(sub)
        else:
            j = random.randint(0, seen - 1)
            if j < RES_MAX:
                reservoir[j] = sub

    if seen == 0:
        print("learn: no subdomained queries found — nothing to train on.", file=sys.stderr)
        return 1

    logp = finalize_logp(counts)

    # Robust threshold from the score distribution: median + k·MAD (MAD·1.4826≈σ,
    # so k=6 ≈ mean+4σ but resistant to the CDN-hash outliers that wreck plain σ).
    scores = sorted(name_score(s, logp) for s in reservoir if s)
    median = _median(scores)
    mad = _median(sorted(abs(x - median) for x in scores)) or 1e-9
    threshold = median + 6.0 * mad

    # Data-driven allowlist: the user's frequent registered domains (their normal
    # traffic, incl. their habitual CDNs) — tunneling to a NEW domain isn't here.
    top = sorted(reg_counts.items(), key=lambda kv: kv[1], reverse=True)
    allow_cut = max(20, int(0.002 * seen))   # "frequent" = seen a lot for this net
    allowlist = [r for r, c in top if c >= allow_cut][:400]

    model = {
        "version": 2,
        "counts": counts,              # compact ints; logp recomputed on load
        "threshold": threshold,
        "median": median,
        "mad": mad,
        "allowlist": allowlist,
        "trained_on": seen,
        "unique_registered": len(reg_counts),
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(model, f, separators=(",", ":"))
    print(f"learn: trained on {seen} subdomained queries across "
          f"{len(reg_counts)} registered domains.")
    print(f"  score median={median:.3f} MAD={mad:.3f} → threshold={threshold:.3f}")
    print(f"  allowlist: {len(allowlist)} frequent domains  →  {out_path} "
          f"({os.path.getsize(out_path)} bytes)")
    return 0


def _median(xs):
    n = len(xs)
    if n == 0:
        return 0.0
    xs = sorted(xs)
    m = n // 2
    return xs[m] if n % 2 else (xs[m - 1] + xs[m]) / 2.0


# ─── scan ────────────────────────────────────────────────────────────────────
SUSPICIOUS_QT = {"TXT", "NULL", "CNAME", "ANY"}   # classic tunneling data channels
SUB_CAP = 64                                       # bound per-domain memory

# High-entropy-but-legit CDN/cloud suffixes: their hostnames LOOK random but are
# structured, not encoded payload. A tiny static safety net beside the data-driven
# frequency allowlist (which only catches domains queried a lot in THIS log).
CDN_SUFFIXES = (
    "nflxvideo.net", "nflxso.net", "googleusercontent.com", "usercontent.goog",
    "cloudfront.net", "akamai.net", "akamaihd.net", "akamaiedge.net", "edgekey.net",
    "edgesuite.net", "fastly.net", "fbcdn.net", "ytimg.com", "ggpht.com", "gvt1.com",
    "gvt2.com", "1e100.net", "azureedge.net", "cloudflare.net", "cloudflarestream.com",
    "digitaloceanspaces.com", "b-cdn.net", "llnwd.net", "wac.edgecastcdn.net", "cdn77.org",
)

_HEX = re.compile(r"^[0-9a-f]{16,}$")
_B32 = re.compile(r"^[a-z2-7]{16,}$")


def looks_encoded(label):
    """True if a label looks like an encoded payload (hex/base32/long base64),
    NOT just a random-ish structured CDN name or a long dictionary word. This is
    the strongest single discriminator between DNS tunneling and legitimate
    high-entropy hostnames."""
    if _HEX.match(label):                              # 16+ hex chars
        return True
    # base32 alphabet [a-z2-7] fully overlaps lowercase letters, so a long word
    # like "visualstudioexptteam" would match — require digits, which real base32
    # payload always carries (~19% of chars) but dictionary words don't.
    if _B32.match(label) and sum(c in "234567" for c in label) >= 2:
        return True
    # long base64-ish: high char diversity AND several digits (excludes words).
    if len(label) >= 20 and len(set(label)) >= 13 and sum(c.isdigit() for c in label) >= 3:
        return True
    return False


def is_allowlisted(reg, allow):
    return reg in allow or any(reg == s or reg.endswith("." + s) for s in CDN_SUFFIXES)


def scan(log_path, model_path, recent, quiet):
    # Fail LOUD, never silently: a corrupt/absent model or an unreadable log must
    # NOT look like a clean result — that would be a security detector reporting
    # "all clear" while blind. Each failure prints to stderr and exits non-zero.
    try:
        with open(model_path, "r", encoding="utf-8") as f:
            model = json.load(f)
        counts = model["counts"]
        threshold = float(model["threshold"])
        if (not isinstance(counts, list) or len(counts) != NSTATES
                or any(not isinstance(r, list) or len(r) != NSYM for r in counts)):
            raise ValueError("bigram matrix has the wrong shape")
    except (OSError, json.JSONDecodeError, KeyError, ValueError, TypeError) as e:
        msg = (f"could not load a usable baseline model at {model_path} "
               f"({type(e).__name__}: {e}) — run 'learn' first")
        print(f"scan: FAILED to {msg}.", file=sys.stderr)
        log_fail(msg)
        return 2
    logp = finalize_logp(counts)
    allow = set(model.get("allowlist", []))

    agg = {}   # reg -> [queries, {subdomains cap64}, sum_score, n_scored, susp_qt, maxlen, encoded]
    for qh, qt in iter_querylog(log_path, recent=recent):
        reg, sub = registered_and_sub(qh)
        a = agg.get(reg)
        if a is None:
            a = agg[reg] = [0, set(), 0.0, 0, 0, 0, 0]
        a[0] += 1
        if qt in SUSPICIOUS_QT:
            a[4] += 1
        if sub:
            if len(a[1]) < SUB_CAP:
                a[1].add(sub)
            sc = name_score(sub, logp)
            a[2] += sc
            a[3] += 1
            for l in sub.split("."):
                if len(l) > a[5]:
                    a[5] = len(l)
                if not a[6] and looks_encoded(l):
                    a[6] = 1

    if not agg:
        msg = (f"the querylog at {log_path} yielded 0 parseable DNS records — "
               f"the detector did NOT run; this is NOT a clean result")
        print(f"scan: FAILED — {msg}.", file=sys.stderr)
        log_fail(msg)
        return 2

    findings = []
    for reg, (q, subs, ssum, sn, susp, maxlen, encoded) in agg.items():
        if sn == 0 or is_allowlisted(reg, allow):
            continue
        mean_score = ssum / sn
        uniq = len(subs)
        improbable = mean_score > threshold
        # Three independent tunneling signatures (any one flags), each tunneling-
        # SHAPED so structured CDN names don't trip it. Encoded-payload volume is
        # primary because encoded labels score like CDN hashes under the bigram
        # model — the improbability threshold alone can't separate them, but their
        # SHAPE (pure hex/base32/base64) and per-domain multiplicity can:
        strong_encoded = encoded and uniq >= 8          # many unique encoded payloads
        txt_abuse = susp >= 5                             # sustained TXT/NULL channel
        improbable_vol = improbable and (uniq >= 8 or maxlen >= 24)
        if strong_encoded or txt_abuse or improbable_vol:
            corro = min(1.0, uniq / 30.0 + susp / 12.0 + encoded * 0.45 + (maxlen >= 40) * 0.2)
            over = min(1.0, max(0.0, mean_score - threshold) / (threshold + 1e-9))
            findings.append((round(0.55 * corro + 0.45 * over, 3), reg, round(mean_score, 2),
                             uniq + (SUB_CAP if uniq >= SUB_CAP else 0), susp, maxlen, q))

    findings.sort(reverse=True)
    if quiet:
        print(f"DNS anomaly scan: {len(findings)} suspicious domain(s) "
              f"(threshold={threshold:.2f}, {len(agg)} domains scanned)")
    else:
        print(f"\n=== DNS anomaly scan — {len(findings)} suspicious domain(s) "
              f"of {len(agg)} scanned (threshold {threshold:.2f}) ===")
        if findings:
            print(f"{'conf':>5}  {'registered domain':32} {'score':>6} {'uniqsub':>7} "
                  f"{'txt/null':>8} {'maxlbl':>6} {'queries':>7}")
            for conf, reg, sc, uniq, susp, maxlen, q in findings[:25]:
                cap = "+" if uniq > SUB_CAP else " "
                print(f"{conf:>5}  {reg:32.32} {sc:>6} {min(uniq, SUB_CAP):>6}{cap} "
                      f"{susp:>8} {maxlen:>6} {q:>7}")
        else:
            print("  clean — no domain combined improbable naming with a volumetric signal.")
    return 1 if findings else 0


# ─── demo (self-test, no querylog needed) ────────────────────────────────────
def demo():
    normal = ["google.com", "api.github.com", "mail.google.com", "cdn.jsdelivr.net",
              "en.wikipedia.org", "outlook.office365.com", "i.redd.it", "apple.com",
              "static.cloudflareinsights.com", "play.googleapis.com"] * 40
    counts = [[0] * NSYM for _ in range(NSTATES)]
    for qh in normal:
        _reg, sub = registered_and_sub(qh)
        for lbl in sub.split("."):
            prev = BEG
            for ch in lbl:
                s = sym(ch)
                counts[prev][s] += 1
                prev = s
    logp = finalize_logp(counts)
    samples = [registered_and_sub(q)[1] for q in normal]
    scores = sorted(name_score(s, logp) for s in samples if s)
    med = _median(scores)
    mad = _median(sorted(abs(x - med) for x in scores)) or 1e-9
    thr = med + 6.0 * mad
    print(f"demo threshold = {thr:.3f}  (median {med:.3f}, MAD {mad:.3f})")
    tests = [("api.github.com", "normal"), ("mail.google.com", "normal"),
             ("A8F93BD72Q9X.attacker.com", "base64 tunnel"),
             ("c732488a09b2e4f6d1.tunnel.evil.org", "hex tunnel"),
             ("kZ9x-Qw82-Lp01-Vn55.dns.io", "high-entropy tunnel")]
    for qh, label in tests:
        _reg, sub = registered_and_sub(qh)
        sc = name_score(sub, logp)
        flag = "🚨 anomalous" if sc > thr else "✅ normal"
        print(f"  {flag:14} score={sc:5.2f}  {qh}  ({label})")


def selftest():
    """Prove the detection logic works end-to-end. Exit 0 = healthy, 3 = BROKEN
    (loud). Lets sweep/CI catch a regression instead of silently trusting a
    detector that no longer detects. Validates BOTH signal paths: the n-gram
    language model (improbability) and the encoding-shape detector."""
    normal = ["google.com", "api.github.com", "mail.google.com", "cdn.jsdelivr.net",
              "en.wikipedia.org", "outlook.office365.com", "i.redd.it", "apple.com"] * 40
    counts = [[0] * NSYM for _ in range(NSTATES)]
    for qh in normal:
        for lbl in registered_and_sub(qh)[1].split("."):
            prev = BEG
            for ch in lbl:
                s = sym(ch)
                counts[prev][s] += 1
                prev = s
    logp = finalize_logp(counts)
    scores = sorted(name_score(registered_and_sub(q)[1], logp) for q in normal
                    if registered_and_sub(q)[1])
    med = _median(scores)
    mad = _median(sorted(abs(x - med) for x in scores)) or 1e-9
    thr = med + 6.0 * mad

    fails = []
    for g in ("mail.google.com", "api.github.com", "cdn.jsdelivr.net"):
        sub = registered_and_sub(g)[1]
        if name_score(sub, logp) > thr or any(looks_encoded(l) for l in sub.split(".")):
            fails.append(f"false-positive on known-good '{g}'")
    # hex/base32 encoded payloads must be caught by the SHAPE detector:
    for enc in ("a8f93bd72c9e4f16.evil.com", "mzxw6ytb2do4zb3q7a.tunnel.io"):
        lbl = registered_and_sub(enc)[1].split(".")[0]
        if not looks_encoded(lbl):
            fails.append(f"encoding detector missed '{lbl}'")
    # an unpronounceable non-encoded label must be caught by the n-gram model:
    imp = registered_and_sub("xqzjvkwbmqpzrfxn.dga.net")[1].split(".")[0]
    if name_score(imp, logp) <= thr:
        fails.append(f"n-gram model missed improbable label '{imp}'")

    if fails:
        print("SELFTEST FAILED — detector is not working:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        log_fail("selftest — detector is not working: " + "; ".join(fails))
        return 3
    print("selftest OK — flags hex/base32 payloads + improbable labels, clears known-good.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="nullexit DNS anomaly detector (report-only)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("learn"); pl.add_argument("--log", default=DEFAULT_LOG); pl.add_argument("--out", default=DEFAULT_MODEL)
    ps = sub.add_parser("scan")
    ps.add_argument("--log", default=DEFAULT_LOG); ps.add_argument("--model", default=DEFAULT_MODEL)
    ps.add_argument("--recent", type=int, default=0, help="scan only the last N records (0=all)")
    ps.add_argument("--quiet", action="store_true")
    sub.add_parser("demo")
    sub.add_parser("selftest")
    args = ap.parse_args()

    if args.cmd == "learn":
        if not os.path.exists(args.log):
            print(f"learn: querylog not found at {args.log}", file=sys.stderr); return 1
        return learn(args.log, args.out)
    if args.cmd == "scan":
        if not os.path.exists(args.log):
            print(f"scan: querylog not found at {args.log}", file=sys.stderr); return 2
        return scan(args.log, args.model, args.recent, args.quiet)
    if args.cmd == "demo":
        demo(); return 0
    if args.cmd == "selftest":
        return selftest()


if __name__ == "__main__":
    sys.exit(main())
