# Failures

Bugs that mattered, what caused them, and — the part worth keeping — **what
caught them**. Grouped by the last question, because the detection method
generalises further than the bug does.

The pattern across all of them: **the expensive bugs were silent.** Nothing
crashed, no test went red, output looked plausible. Every one was found by
something that compares against an external expectation rather than by the code
disagreeing with itself.

---

## Found only because an outside source said the data was different

### The cost-1 結果 was thrown away at build time

mozc has `けっか 1918 1918 1 結果` — cost 1, a lexicalised high-frequency entry.
The build deduplicated by reading and surface keeping whichever row came first
in the file, and the cost-15263 row came first. The good entry was silently
discarded on every build.

Fix: sort by `(key, cost)` before dedup, so the cheapest row wins rather than
the first.

```swift
entries.sort {
  let order = compareBytes($0.key, $1.key)
  if order != 0 { return order < 0 }
  return $0.cost < $1.cost
}
```

**Caught by:** a research agent reading mozc's dictionary files reported the
cost-1 entry as evidence for something unrelated. Nothing in this code could
have found it — the output was a valid entry for a valid reading, just the wrong
one of two. There was no oracle for *which* 結果 should be there.

### Nine mode-dictionary terms produced nothing at all

A kanji surface with no reading written down is unreachable. The rows were in
`dict-src/security.tsv`, the build consumed them without complaint, and the
words never appeared in any candidate list.

Fix: `kkc expand` now reports unreachable rows.

**Caught by:** coverage counting (19/57 reachable) rather than by any test. A
store taking third-party submissions will hit this constantly, which is why it
became a build-time report rather than a one-off correction.

## Found by typing into the app

Four bugs that every test passed through.

### Predictions vanished at the moment of pressing Space

Typing くろす showed クロスサイトスクリプティング; pressing Space to convert
made it disappear. The candidate the user was aiming at was destroyed by the
act of asking for candidates.

Cause: segmentation dropped predictions everywhere, on the reasoning that an
interior segment's reading is fixed by what follows. True for interior segments,
false for the last one, where more input can still arrive.

Fix: the final segment keeps `predictionKeys: 8`.

### Committing a prediction learned a false reading

Immediately downstream of the above. Choosing クロスサイトスクリプティング after
typing くろす recorded `くろす → クロスサイトスクリプティング` in the learning
store — a reading that is simply not this word's reading, now permanent and
recalled forever.

Fix: commit records the *candidate's* reading, not the segment's
(`chosenReading`).

**Both caught by:** using it. Neither is visible in a conversion accuracy score,
because neither involves conversion being wrong.

### The segment appeared in the middle of the paragraph

Laying the composition out as an `HStack` of per-segment `Text` views broke text
flow — the converting segment rendered mid-paragraph instead of in reading
order.

Fix: one concatenated `Text` with underline colours carrying the segment
boundaries.

### Keyboard focus went to the buttons

SwiftUI's `.onKeyPress` loses first responder to any focusable control on
screen, so arrow keys stopped reaching the composition once buttons existed.

Fix: an `NSView` that claims first responder (`KeyCaptureView`).

## Found by an adversarial pass over own code

### 教派 swallowed the sentence

きょうは confirmed once as 教派, entering the lattice with the user layer's
absolute priority, permanently blocked きょう|は. Any subsequent sentence
starting きょうは converted wrong.

This one is worth stating precisely because the obvious reading is wrong: **it
is not a cost bug.** No costs were involved — absolute priority bypasses them.
Any entry covering a long reading suppresses better splits, and priority makes
that stronger rather than weaker.

Fix: layer priority decides candidates *within* a segment and does not
participate in choosing the split.

### The no-garbage test was checking the wrong thing

The regression set forbade exact output strings. Having listed 教派暑かった after
finding it, 教派扱った sailed through — a different garbage output from the same
root cause.

Fix: substring matching. An exact-match list can only catch breakage that has
already been seen, which makes it a record rather than a test.

## Found by a metric moving the wrong way

### Bigram scored 40–75% depending on nothing in particular

Two bugs stacked. First, node cost and transition cost both charged the unigram
— double-counting. Fixing that by subtracting exposed the second and worse one:
the two sides drew on *different backoffs*. The node used the dictionary's baked
value (corpus unigram, or a length formula when the corpus had never seen the
word); the transition subtracted the bigram model's own unigram (character-model
backoff). For unseen words these are different functions, so they do not cancel,
and the remainder was charged as if it meant something.

Fix: node cost 0, one function prices everything. 72% → 79%, and 81.4% for the
model that had been scoring anywhere in 40–75%.

**The lesson is narrow and reusable:** an interpolated model has to be priced by
one function end to end. Splitting the arithmetic across two places in the code
means the backoffs have to agree by coincidence, and they will not.

### Switching to short-unit tokenisation made everything worse

Morphological short units cover 80% of the pairs the lattice proposes against
55% for longest-match over dictionary surfaces, so this should have helped.
Phrase went 79% → 75% and word 88% → 66%.

Cause: **unigrams and bigrams want different tokenisations.** mozc holds 勉強する
and 東京都 as single dictionary entries; short units split them, so compound
entries lost their unigram and got priced by their characters. 22 points at word
level, in exchange for better pair coverage.

Not fixed. Two separate counting passes should resolve it; bigrams are off by
default (`--bigrams-on`) until then.

## Found by a test, as intended

The inflection expansion, where three separate rules were wrong and each
produced a different kind of damage:

| bug | output | kind of damage |
|---|---|---|
| た charged after 撥音便/ガ行 | 読んた exists, 読んだ does not | manufactured a form nobody types, lost a common one |
| all 五段 excluded from 連用形 | 話した missing | over-broad rule, correct forms lost |
| 未然形 + ず | 見ず outranked 水 | manufactured a 文語 form mozc deliberately omits |

The third generalises: **an expansion inherits its stem's cost, so a rare suffix
on a common stem undercuts a common word.** Suffixes have to earn inclusion, and
there is no formula for it — mozc's own suffix costs are all zero, being
lexicalised function words.

Romaji conversion had two of the same shape. A loop generating youon entries
overwrote existing base entries, mapping `shi` to しぃ and `ji` to じぃ; and the
`nn → ん` rule fired without looking ahead, so `konnyaku` became こんやく instead
of こんにゃく. Both are the same mistake — a rule applied without checking what
it was displacing.

## Failures that were not code

### Building the wrong layer first

The 構成層 was built before the 索引層. The task notes had been updated to
reverse that order and the update was not re-read.

### Extrapolating from a train/test split of one sample

"Same genre, 3.4M tokens, 89%" was a power law fitted to a split of a single
collection — same source, same tokenisation pipeline, so adding data mostly
covered that sample's own vocabulary and the curve looked unbounded. Independent
data gave 79.5% and a clear saturation curve.

Ten points, in the direction that flattered the plan. It is recorded in
`measurements.md` next to the numbers it undermines rather than quietly
corrected, because the remaining extrapolations deserve the same suspicion and
nothing in the method prevents a repeat.
