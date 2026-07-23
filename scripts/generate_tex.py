#!/usr/bin/env python3
import os

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

IGNORE_DIRS = {'.git', '.github', 'adguard', '__pycache__', 'Recover Gateway.app', 'Toggle Gateway.app', 'Sweep Gateway.app','nullexit-knowledge-graph'}
IGNORE_FILES = {'.env', 'nullexit_unified.tex', 'nullexit_unified.pdf', 'output.log', 'blocked.log', '.DS_Store', '.lan_p2p_detected', '.signatures', '.gateway_ip', 'TUNNEL_FAILED_CLOSED.marker','.host_ips','refactor.md','sweep.md','.build_hash','.rules_hash','knowledge-graph.html','.dns_baseline.json','.last_wifi_ssid','.last_wifi_ssid.tmp'}
IGNORE_EXTS = {'.pdf', '.tex', '.png', '.jpg', '.jpeg', '.zip', '.tar', '.gz', '.log', '.aux', '.fls', '.fdb_latexmk', '.out', '.toc', '.xdv', '.synctex(busy)'}
# Transient runtime reports (timestamped names) carry live egress/peer IPs — never
# embed them in the published quine. Matched by filename prefix.
IGNORE_PREFIXES = ('sweep-', 'host-leak-diagnostic-')

# Exclude from code block inclusion, but keep in tree
SKIP_CONTENT_FILES = {'LICENSE'}

PRIORITY_FILES = [
    'README.md',
    'agent.md',
    'devref.md',
    'diagrams.md',
    'toggle.sh',
    'recover.sh',
    'setup.sh',
    'scripts/setup-linux.sh',
    'docker-compose.yml',
    'scripts/common.sh',
    'scripts/watcher.sh',
    'scripts/crypto.sh'
]

def get_language(filename):
    ext = os.path.splitext(filename)[1].lower()
    if ext == '.sh' or ext == '.applescript':
        return 'bash'
    elif ext == '.py':
        return 'Python'
    elif ext == '.go':
        return 'Go'
    elif ext in {'.yml', '.yaml'}:
        return 'bash'
    elif ext == '.plist':
        return 'XML'
    elif ext == '.md':
        return ''
    return ''

def escape_tex(text):
    return text.replace('_', '\\_')

def generate_tree(dir_path, prefix=""):
    tree_str = ""
    entries = sorted(os.listdir(dir_path))
    entries = [e for e in entries if e not in IGNORE_DIRS and e not in IGNORE_FILES and os.path.splitext(e)[1].lower() not in IGNORE_EXTS]
    
    for i, entry in enumerate(entries):
        path = os.path.join(dir_path, entry)
        is_last = (i == len(entries) - 1)
        connector = "`-- " if is_last else "|-- "
        tree_str += f"{prefix}{connector}{entry}\n"
        
        if os.path.isdir(path):
            extension = "    " if is_last else "|   "
            tree_str += generate_tree(path, prefix + extension)
            
    return tree_str

def main():
    tex_path = os.path.join(PROJECT_ROOT, 'nullexit_unified.tex')
    
    preamble = r"""\documentclass{article}
\usepackage[utf8]{inputenc}
\usepackage[margin=1in]{geometry}
\usepackage{listings}
\usepackage{xcolor}
\usepackage{hyperref}
\usepackage{tocloft}

\definecolor{codegreen}{rgb}{0,0.6,0}
\definecolor{codegray}{rgb}{0.5,0.5,0.5}
\definecolor{codepurple}{rgb}{0.58,0,0.82}
\definecolor{backcolour}{rgb}{0.97,0.97,0.96}

\lstdefinestyle{mystyle}{
    backgroundcolor=\color{backcolour},   
    commentstyle=\color{codegreen},
    keywordstyle=\color{blue}\bfseries,
    numberstyle=\tiny\color{codegray},
    stringstyle=\color{codepurple},
    basicstyle=\ttfamily\scriptsize,
    breakatwhitespace=false,         
    breaklines=true,                 
    captionpos=b,                    
    keepspaces=true,                 
    numbers=left,                    
    numbersep=5pt,                  
    showspaces=false,                
    showstringspaces=false,
    showtabs=false,                  
    tabsize=2,
    frame=single,
    rulecolor=\color{codegray},
    extendedchars=true,
    literate={─}{-}1 {═}{=}1 {✅}{{OK}}2 {—}{-}1 {│}{|}1 {┌}{+}1 {┐}{+}1 {└}{+}1 {┘}{+}1 {├}{+}1 {┤}{+}1 {┬}{+}1 {┴}{+}1 {┼}{+}1 {▾}{v}1
}
\lstset{style=mystyle}

\title{Nullexit: Unified Project Document}
\author{Omar Alaaeldein}
\date{\today}

\begin{document}
\maketitle

\tableofcontents
\newpage

\section{Project Directory Tree}
\begin{verbatim}
nullexit/
"""
    
    tree = generate_tree(PROJECT_ROOT)
    midamble = r"""\end{verbatim}
\newpage
"""

    all_relpaths = []
    for root, dirs, files in os.walk(PROJECT_ROOT):
        dirs[:] = sorted([d for d in dirs if d not in IGNORE_DIRS])
        for file in sorted(files):
            if file in IGNORE_FILES or file in SKIP_CONTENT_FILES or os.path.splitext(file)[1].lower() in IGNORE_EXTS:
                continue
            if file.startswith(IGNORE_PREFIXES):
                continue
            
            filepath = os.path.join(root, file)
            relpath = os.path.relpath(filepath, PROJECT_ROOT)
            all_relpaths.append(relpath)
            
    def sort_key(path):
        if path in PRIORITY_FILES:
            return (0, PRIORITY_FILES.index(path))
        return (1, path)
        
    all_relpaths.sort(key=sort_key)

    with open(tex_path, 'w', encoding='utf-8') as f:
        f.write(preamble)
        f.write(tree)
        f.write(midamble)
        
        for relpath in all_relpaths:
            lang = get_language(relpath)
            lang_attr = f"[language={lang}]" if lang else ""
            
            f.write(f"\\section{{{escape_tex(relpath)}}}\n")
            f.write(f"\\begin{{lstlisting}}{lang_attr}\n")
            try:
                with open(os.path.join(PROJECT_ROOT, relpath), 'r', encoding='utf-8', errors='ignore') as src:
                    content = src.read()
                    import re
                    # Strip all non-ASCII characters (emojis, box drawings, em dashes, etc)
                    # AND ASCII control characters except \t\n (binary payloads, ANSI escapes,
                    # form feeds — all invisible, all fatal to LaTeX compilation)
                    content = re.sub(r'[^\x09\x0A\x20-\x7E]+', '', content)
                    f.write(content)
                    if not content.endswith('\n'):
                        f.write('\n')
            except Exception as e:
                f.write(f"Error reading file: {e}\n")
            f.write("\\end{lstlisting}\n\n")
                    
        f.write("\\end{document}\n")

    print(f"Generated {tex_path}")

if __name__ == '__main__':
    main()
