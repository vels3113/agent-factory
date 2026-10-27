"""The part of a build or test step's output worth reading, at most 50 lines.
Used by agent-check.sh after a failed step.
Usage: check_excerpt.py compiler|ctest|pytest|generic <output-file>
  compiler  the first 5 compiler, flex, linker or CMake errors with their context
  ctest     the failing tests and the end of their output
  pytest    the failing tests and their assertion sections
  generic   (and any parser that finds nothing) the last 30 lines
"""
import re
import sys

kind, path = sys.argv[1:]
lines = open(path, errors="replace").read().splitlines()
out = []
if kind == "compiler":
    diag = re.compile(r"\b(fatal )?error:|^\S+\.l:\d+:|undefined reference|ld returned|^CMake Error")
    ctx = re.compile(r"^\s|note:|required from|In instantiation")
    shown, i = [], 0
    while i < len(lines) and len(shown) < 5:
        if diag.search(lines[i]) and lines[i] not in shown:
            shown.append(lines[i]); out.append(lines[i])
            j = i + 1
            while j < len(lines) and j <= i + 3 and ctx.search(lines[j]) and not diag.search(lines[j]):
                out.append(lines[j]); j += 1
            i = j
        else:
            i += 1
    more = len({l for l in lines if diag.search(l)} - set(shown))
    if more: out.append(f"... and {more} more error line(s)")
elif kind == "ctest" and "The following tests FAILED:" in lines:
    k = lines.index("The following tests FAILED:")
    names = [m.group(1) for l in lines[k + 1:] if (m := re.match(r"^\s*\d+ - (.+?) \([^)]*\)\s*$", l))]
    out.append(f"Failed tests ({len(names)}): " + ", ".join(names[:10]) + (f" and {len(names) - 10} more" if len(names) > 10 else ""))
    stop = re.compile(r"^\s*(Start\s+\d+:|\d+/\d+ Test\s+#)|^\d+% tests passed")
    for name in names[:3]:
        head = re.compile(r"Test\s+#\d+: " + re.escape(name) + r" \.*\*\*\*")
        start = next((n for n, l in enumerate(lines) if head.search(l)), None)
        if start is None: continue
        end = next((n for n in range(start + 1, len(lines)) if stop.search(lines[n])), len(lines))
        out.append(f"--- {name}")
        out += lines[max(start + 1, end - 15):end]
elif kind == "pytest":
    fails = [l for l in lines if re.match(r"^(FAILED|ERROR) ", l)]
    if fails:
        out.append(f"Failed tests ({len(fails)}):")
        out += fails[:10]
        sec = re.compile(r"^_{3,} .+ _{3,}$|^=+ short test summary")
        starts = [n for n, l in enumerate(lines) if sec.search(l)]
        for a, b in list(zip(starts, starts[1:]))[:3]:
            if lines[a].startswith("="): break
            out.append(lines[a])
            out += lines[max(a + 1, b - 15):b]
if not out:
    out = lines[-30:]
for l in out[:50]:
    print(l if len(l) <= 300 else l[:300] + " ...")
if len(out) > 50: print("... (cut; see the full log)")
