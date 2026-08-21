# Decisions

Why the engine is shaped the way it is. Numbers referenced here are in
[`measurements.md`](measurements.md).

The through-line: **the engine is deliberately not clever, and the dictionaries
around it carry the weight.** That came from looking at what MS-IME actually
does — see [`ms-ime.md`](ms-ime.md) — and every measurement since has supported
it being viable.

---

## No parts of speech, anywhere

A dictionary supplies a reading, a surface, and optionally a number. Nothing
else.

The alternative is what everyone ships: mozc's 2672 context IDs, azooKey's
1319, MS-IME's ~3000 classes. The cost of that is paid by whoever wants to add
a word — they have to be told which class it belongs to. Everyone has already
found this untenable and worked around it: azooKey exposes three booleans, mozc
exposes 48 labels, macOS's part-of-speech field is vestigial. **All of them
concluded users cannot be asked for parts of speech, and all of them kept the
system internally anyway.**

The measurement that makes dropping it viable: a POS-constrained lattice scores
28.4% against a free lattice's 28.6%. Parts of speech buy boundary precision
(61% against 32%), not accuracy. And surface bigrams reach mozc's full model
(85.6% against 85.3%) with no tags at all.

Note the asymmetry: azooKey's own roadmap lists exposing parts of speech to
users as a *wanted feature*. For them the absence is a limitation. Here it is
the design. The same state of affairs, opposite meanings — which is why "azooKey
also manages without" is not an argument that can be borrowed.

**What this costs.** Boundary precision halves, so the split lands wrong more
often than in a tagged engine. That is what the resize UI is for. It also means
文節数最小法 is unavailable — its definition of a 文節 requires tags, and
without them it degrades to fewest-dictionary-entries and scores 3.6%. The flat
boundary penalty here is that weaker thing, despite being described as 文節数最小法
earlier in the work.

## Four layers, ordered absolutely

```
user      written down on purpose. never decays
learned   picked up from typing. halves every 32 days
mode      installed for a domain
baseline  mozc's vocabulary
```

Conflicts settle by layer, not by cost. A cost-based engine cannot promise that
adding a word makes it win — enough accumulated cost elsewhere still beats it.
A total order can, without exception. When the product promise is "install this
dictionary and this word converts", the cruder mechanism is the one that keeps
it.

**Learning is a separate layer from the user dictionary** because *confirmed
once* and *written down deliberately* are different claims. One confirmation
survives a month and is then gone — 1 >> 1 is 0. Everything shipping guards
against permanent mislearning somehow: Anthy caps each kind at 100–1000
entries, Mozc refuses to generalise a correction across differing parts of
speech, Chinese IMEs decline to add to the vocabulary at all. azooKey's decay
is the version that survives having no parts of speech to check with, so that
is the one used.

Forgetting is deliberately coarse — a surface goes wherever it appears under
that reading. Being asked to forget a candidate and seeing it again because
another entry spelled it the same way is worse than forgetting slightly too
much. azooKey names the same choice `testCoarseForget`.

## Layer priority does not decide the split

User and mode entries enter the lattice at a neutral cost and win only *within*
a segment.

This was learned the hard way. きょうは confirmed once as 教派, with the usual
absolute priority, blocked きょう|は permanently. **A long reading covering a
sentence, given priority, swallows it.** And note this is not a cost problem —
no costs were involved. Any entry covering a long reading suppresses better
splits, and absolute priority makes that stronger rather than weaker.

The same distinction appears in Helpfeel's patent (【００７７】, which rejects
"prepare more articles" because irrelevant ones then match) and in mozc's
`SUGGESTION_ONLY` label (vocabulary that appears in suggestions but never in the
lattice). Two independent arrivals at: **expanded or added entries must not
silently compete in the search.**

## Expansion at build time, not derivation at conversion time

Two things are expanded when the index is built.

**Inflections.** mozc stores stems — `かい → 書い` tagged 連用タ接続, with the
た supplied by an auxiliary entry the lattice joins on. Without a lattice,
`かいた` returns place names and no verb.

Three things make this easy to get quietly wrong, and all three were:

- 撥音便 and ガ行 voice the suffix (読ん+だ, 泳い+だ). Charging た produced
  読んた, which nobody types, and lost 読んだ entirely.
- サ行五段 has no 連用タ接続 at all; 話し+た comes off 連用形. Excluding all
  五段 from 連用形 to avoid 書きた also lost 話した.
- 未然形+ず manufactured 見ず — a 文語 form mozc deliberately does not carry —
  which then outranked 水.

The last one is the general lesson: **an expansion inherits its stem's cost, so
a rare suffix on a common stem undercuts a common word.** Suffixes have to earn
their place. There is no formula for that; mozc's own suffix costs are all zero,
being lexicalised function words.

**Readings.** A word is reachable only through readings it was given. XSS filed
under くろすさいとすくりぷてぃんぐ is unreachable to anyone typing
えっくすえすえす. Generating the ways in is the concept's central bet and it
measured well: 19/57 → 57/57 reachable with every other score unchanged.

The failure mode here is silence. A kanji surface with no reading written down
produces nothing — the row is in the file, the word never appears. Nine terms
were in that state. `kkc expand` now reports them, because **a store taking
third-party submissions will hit this constantly.**

## Kana is not a dictionary entry

Hiragana and katakana of the reading are appended to every candidate list and
kept out of the index.

mozc carries them (けっか→けっか at 6594, きょうと→キョウト, こと→コト) and they
beat the word they compete with. Chasing that with costs is the wrong move:
character-type conversion is derivable from the reading and needs no dictionary.
Taking them out of the competition and appending them means 結果 no longer has
to outrank けっか, and a candidate list is never empty.

Not uniformly, though — for a particle, an interjection or an adverb the kana
*is* the answer. は, ありがとう, ちょっと. The split that survived: katakana
identity always drops (it is a display transform in every case), hiragana
identity drops only for nouns.

## Remembered segmentations instead of connection costs

Committing stores the split whole; the next occurrence recalls it. Prefix
matching means yesterday's きょうは carries into today's きょうはさむかった.

Same move as expanding inflections, applied to joins: rather than deriving
今日 + は at conversion time, `きょうは → 今日は` goes in the store. **The concept
of a connection cost disappears rather than being approximated.**

The search-engine analogy is exact — `newyorktimes` is split by query logs, not
by a grammar. What makes it work here is the segment UI: committing used to
yield one string, and now yields a split the user looked at and accepted, which
is far stronger evidence.

One trap found immediately: a prediction covers more than was typed, so
choosing クロスサイトスクリプティング after typing くろす must record the
*candidate's* reading, not the segment's. Recording くろす →
クロスサイトスクリプティング would be false and then recalled forever.

## Prediction only from layers that know this user

The baseline lexicon does not predict.

Ranking a million entries by their own costs puts something useful in the
window 11.9% of the time and produces nothing at all for 80% of phrases; user
history gives 39.5%. What the lexicon reliably does is fill the window with
のんで→ノンデイト and ですか→デス書き込み. Turning it off removed the pollution
and moved no conversion score.

Candidates merge by score rather than occupying reserved slots — reserving is
what costs (−14.3 points in a three-slot window against −1.4 for interleaving).

The final segment keeps its predictions, since more input could still follow
there. Interior segments have their readings fixed by what comes after, so a
longer reading cannot apply. Dropping predictions everywhere threw away the
candidate the user was typing towards at the exact moment of converting.

## Measured at phrase granularity

The product converts a chunk at a time. The evaluation sets were originally
whole sentences, and that was measuring something this architecture cannot
reach: a model without connection information does *worse* on whole sentences
than on the same text phrase by phrase (22.4% against 26.0%), while a bigram
model does better (63.3% against 60.0%). The gap between models shrinks to a
third at phrase granularity, and the optimal λ moves.

Both granularities are kept. The sentence numbers being low is information
about the architecture, not something to hide.

**Breakdowns are scored separately from accuracy.** けっか coming back as けっか
is not a failure — the reading returned unconverted, and the user can add a word
or confirm it once. みず coming back as 見ず is, because nothing asked for 見ず.
Counting both as "wrong" hides the difference and points tuning at the wrong
target. Forbidden cases match by substring: an exact-string list only catches
the breakage already seen, and did in fact miss 教派扱った after 教派暑かった was
listed.

## Third-party dictionaries take a constant

No probability estimation required. 212,957 entries added at a flat cost moved
accuracy from 30.2% to 30.7%; harm concentrates entirely in short readings that
collide with existing words, and readings of six characters or more caused
none. A naive corpus estimate was *worse* than the constant.

Screening is mechanical: reading length and collision. Specialist vocabulary is
long, which is the safe end — and the store's first target domain is exactly
that.

---

## Open

**The bigram does not work here.** 79% against the reference implementation's
85.6%. Two causes were found and one is fixed.

Fixed: node cost and transition cost were drawing on different backoffs. The
node used the dictionary's baked-in value (corpus unigram, or a length formula
when absent) while the transition subtracted the bigram model's own unigram
(character-model backoff). For words the corpus never saw these are different
functions, so they do not cancel and the remainder is charged at random. The
same model scores 81.4% when one function prices everything and 40–75% when the
backoffs disagree. Fixing it moved 72% → 79%.

Open: **the two counts want different tokenisations and one pass cannot serve
both.**

```
unigrams  want the dictionary's units    mozc holds 勉強する and 東京都 as single entries
bigrams   want morphological short units so the pairs match what the lattice proposes
```

Longest match over dictionary surfaces gives the first and covers 55% of the
pairs actually needed (against 80% for short units). Short units give the second
and leave compounds priced by their characters — 22 points at word level. Two
separate passes should resolve it. Bigrams are off by default until then.

**Sentence-level conversion stays weak**, and the measurements say that is
expected rather than fixable by more data. Single-genre corpora saturate around
80% at word level however much is added; mixing raises the ceiling about two
points; the phrase and sentence gaps are connection information, not coverage.

**Not built:** character-type conversion as an explicit operation (derivable
from the reading, so independent of everything above), and an InputMethodKit
shell. The app substitutes for the latter — an input source has to be installed
and logged back into, and takes your typing down with it when it breaks, which
is a bad trade while the thing under test is still changing.
