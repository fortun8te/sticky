#!/usr/bin/env bash
# Sticky rule enforcement. See AGENTS.md §1.
# Exit 1 on any violation. Run before every commit; CI runs it on every push.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
SRC=(mac win)

report() { printf '\033[31m✗ %s\033[0m\n  %s\n' "$1" "$2"; fail=1; }

ban() { # ban <pattern> <human reason> [extra-grep-args]
  local pat="$1" why="$2"; shift 2
  local hits
  hits=$(grep -rnE "$pat" "${SRC[@]}" --include='*.swift' --include='*.cs' --include='*.xaml' "$@" 2>/dev/null) || true
  [ -n "$hits" ] && report "$why" "$(echo "$hits" | head -5)"
}

echo "── banned APIs ──────────────────────────────────────"
ban 'addGlobalMonitorForEvents'        'global event monitor — use .onDrop / NSDraggingDestination'
ban 'CGEvent\.tapCreate|CGEventTap'    'event tap — requires Accessibility'
ban 'AXIsProcessTrusted|AXUIElement'   'Accessibility API — we never ask for it'
ban 'globalShortcut|RegisterHotKey'    'global hotkey — the old build stole ⌘⇧V'
ban 'osascript|NSAppleScript'          'AppleScript — requires Automation'
ban 'NSApp\.activate'                  'steals focus from Finder mid-drag'
ban 'dlopen\(|PrivateFrameworks'       'private framework'
ban 'sel(ector)?\(\s*"_|#selector\(_'  'underscore-prefixed selector is private API'
ban 'CGWindowListCreateImage'          'screen capture — out of scope'

echo "── geometry law (AGENTS.md §3) ──────────────────────"
ban 'frame\.midX\s*-.*[wW]idth\s*/\s*2' 'notch origin from midX — off by 0.5 pt; use auxiliaryTopLeftArea.width'
hits=$(grep -rnE '\b(185|370|188|220|32\.0|38\.0)\b' mac --include='*.swift' \
        | grep -viE 'Tests|//|NotchGeometry\.swift|\.md:' ) || true
[ -n "$hits" ] && report 'hardcoded notch dimension — measure at runtime' "$(echo "$hits" | head -5)"

echo "── window posture ───────────────────────────────────"
if [ -d mac/Sticky/Portal ]; then
  if ! grep -rq 'ignoresMouseEvents' mac --include='*.swift' 2>/dev/null; then
    report 'no ignoresMouseEvents anywhere' 'the notch panel must be click-through when idle'
  fi
fi
hits=$(grep -rnE 'setFrame\(|setContentSize\(' mac --include='*.swift' \
        | grep -viE 'Tests|setFrameOrigin' ) || true
[ -n "$hits" ] && report 'panel resize — create once at max envelope, setFrameOrigin only' "$(echo "$hits" | head -5)"

echo "── design tokens ────────────────────────────────────"
hits=$(grep -rnE '(Color|NSColor)\(\s*(red|white|hue|#|"#)|#[0-9a-fA-F]{6}' \
        mac/Sticky/Portal mac/Sticky/MenuBar --include='*.swift' 2>/dev/null) || true
[ -n "$hits" ] && report 'literal colour in a view — use DS.Colors.*' "$(echo "$hits" | head -5)"
hits=$(grep -rnE 'cornerRadius:\s*[0-9]' mac/Sticky/Portal mac/Sticky/MenuBar \
        --include='*.swift' 2>/dev/null) || true
[ -n "$hits" ] && report 'literal corner radius in a view — use DS.CornerRadius.*' "$(echo "$hits" | head -5)"
hits=$(grep -rlnE '\.spring\(|dampingFraction:|response:|extraBounce:' mac --include='*.swift' 2>/dev/null \
        | grep -v 'Motion.swift' | grep -v Tests) || true
[ -n "$hits" ] && report 'spring constant outside Motion.swift' "$(echo "$hits" | head -5)"

echo "── error handling ───────────────────────────────────"
hits=$(grep -rnE 'catch\s*\{\s*\}|catch\s*\{\s*/\*|catch\s*\(.*\)\s*\{\s*\}' "${SRC[@]}" \
        --include='*.swift' --include='*.cs' 2>/dev/null) || true
[ -n "$hits" ] && report 'empty catch — log which branch was taken instead' "$(echo "$hits" | head -5)"

echo "── icons ────────────────────────────────────────────"
hits=$(python3 - "${SRC[@]}" <<'PYEOF' || true
import sys,os,re,unicodedata
pat=re.compile('[\U0001F300-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\uFE0F]')
out=[]
for root in sys.argv[1:]:
    for d,_,fs in os.walk(root):
        for f in fs:
            if not f.endswith(('.swift','.cs','.xaml')): continue
            p=os.path.join(d,f)
            try: lines=open(p,encoding='utf-8',errors='ignore').read().splitlines()
            except OSError: continue
            for i,l in enumerate(lines,1):
                if pat.search(l): out.append(f"{p}:{i}:{l.strip()[:100]}")
print("\n".join(out))
PYEOF
)
[ -n "$hits" ] && report 'emoji in UI code — use SF Symbols (mac) / Lucide (win)' "$(echo "$hits" | head -5)"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32m✓ clean\033[0m\n'; else printf '\033[31m✗ %s\033[0m\n' "violations above"; fi
exit "$fail"
