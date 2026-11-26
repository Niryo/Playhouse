"""Reads `perf script` output (demangled) on stdin and prints, for the hottest
leaf symbols, the nearest named callers (skipping unnamed addresses and
observation/closure plumbing), plus inclusive time of selected frames."""
import sys, collections, re
SKIP = re.compile(r'^(0x|\[unknown\]|partial apply|closure #|withUnsafeMutablePointer|generateAccessList|withObservationTracking|thunk|reabstraction|protocol witness|specialized protocol witness)')
stacks = []
cur = []
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line.strip():
        if cur: stacks.append(cur); cur = []
        continue
    if line[0] not in ' \t':
        continue  # header
    parts = line.strip().split(' ', 1)
    if len(parts) < 2: continue
    sym = parts[1]
    sym = re.sub(r'\s+\(\S+\)$', '', sym)  # dso
    sym = re.sub(r'\+0x[0-9a-f]+$', '', sym)
    cur.append(sym)
if cur: stacks.append(cur)
total = len(stacks)
leaf = collections.Counter(s[0] for s in stacks)
print(f"samples {total}")
for name, n in leaf.most_common(int(sys.argv[1]) if len(sys.argv) > 1 else 8):
    print(f"\n{100*n/total:5.1f}% leaf {name[:120]}")
    callers = collections.Counter()
    for s in stacks:
        if s[0] != name: continue
        chain = [f for f in s[1:] if not SKIP.match(f) and not f.startswith(('g_', 'gtk_', '_g_'))][:3]
        callers[' <- '.join(c[:70] for c in chain)] += 1
    for c, m in callers.most_common(6):
        print(f"   {100*m/total:5.1f}%  {c}")
print("\ninclusive (selected):")
incl = collections.Counter()
for s in stacks:
    for f in set(s):
        incl[f] += 1
for f, n in incl.most_common(400):
    if re.search(r'(measure|Text|Icon|Pango|pango|preferred|Image|naturalSize|setSize|setPosition|computeLayout\(with|commit\(\)|body|update\(_:with|DynamicProperty|Environment|forEachField|Observation|observe|snapshot|css)', f, re.I):
        print(f"  {100*n/total:5.1f}%  {f[:150]}")
