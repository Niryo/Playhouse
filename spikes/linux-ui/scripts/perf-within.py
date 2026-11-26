"""perf script (demangled) on stdin; argv[1] = frame substring. For samples
whose stack contains it, prints the share of self time by the nearest named
'interesting' frame (first frame matching argv[2] regex, default: Swift
SwiftCrossUI/GtkBackend-looking symbols) and by leaf symbol."""
import sys, re, collections
need = sys.argv[1]
interesting = re.compile(sys.argv[2] if len(sys.argv) > 2 else r'(GtkBackend\.|Text\.|ViewGraphNode\.|LayoutSystem\.|Pango\.|CSS|css|EnvironmentValues|Animator|DynamicProperty|forEachField|updateEnvironment|BodyTracking|trackBody|withObservationTracking|ObservationRegistrar|_installTracking|Modifier\.|View\.|Stack|Icon|Gradient|Shape|Path|gtk_|pango_|cairo_)')
stacks, cur, total = [], [], 0
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line.strip():
        if cur: stacks.append(cur); cur = []
        continue
    if line[0] not in ' \t': continue
    parts = line.strip().split(' ', 1)
    if len(parts) < 2: continue
    sym = re.sub(r'\s+\(\S+\)$', '', parts[1]); sym = re.sub(r'\+0x[0-9a-f]+$', '', sym)
    cur.append(sym)
if cur: stacks.append(cur)
total = len(stacks)
sel = [s for s in stacks if any(need in f for f in s)]
print(f"{len(sel)} of {total} samples ({100*len(sel)/total:.1f}%) contain {need}")
by = collections.Counter()
leaf = collections.Counter()
for s in sel:
    leaf[s[0][:90]] += 1
    for f in s:
        if interesting.search(f) and 'partial apply' not in f and 'closure' not in f and 'protocol witness' not in f:
            by[f[:110]] += 1; break
    else:
        by['(other) ' + s[0][:80]] += 1
print("\nby nearest interesting frame:")
for k, n in by.most_common(35): print(f"  {100*n/total:5.1f}%  {k}")
print("\nby leaf:")
for k, n in leaf.most_common(15): print(f"  {100*n/total:5.1f}%  {k}")
