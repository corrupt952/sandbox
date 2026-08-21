"""Re-tokenise the corpus with UniDic short units.

Counting by longest match over dictionary surfaces looked reasonable and is
not: it greedily takes long compound surfaces, so the pairs it records are not
the pairs the lattice proposes at conversion time. Measured, that covers 55% of
the adjacent pairs actually needed against 80% for short units — more bigrams,
the wrong ones.

This runs offline and emits plain text with spaces between units. Nothing at
runtime depends on it.
"""

import sys
from fugashi import Tagger

tagger = Tagger("-Owakati")

source, dest = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 0

lines = 0
with open(source, encoding="utf-8") as src, open(dest, "w", encoding="utf-8") as out:
    for line in src:
        line = line.strip()
        if not line:
            continue
        out.write(" ".join(w.surface for w in tagger(line)) + "\n")
        lines += 1
        if limit and lines >= limit:
            break
print(f"lines: {lines}")
