# What was measured

Every design decision in this prototype rests on one of the numbers below.
They came from three places: a Python reference implementation built alongside
this one (lattice and Viterbi shared, cost model swappable, so comparisons are
same-lattice same-search), published sources, and this prototype's own test
sets.

**Read the caveats at the bottom before quoting any of this.** Several of these
numbers were revised once during the work, and the revisions were larger than
the differences being argued about.

---

## The engine

### mozc's costs are not scalars

High-frequency words are given a lexicalised context ID and have their cost
flattened towards zero, with the discriminating information moved into the
2672×2672 connection matrix.

```
です → デス cost=0    助動詞,特殊・デス,基本形,デス   ← lexicalised ID
       です cost=40
けっか → 結果 cost=1      名詞,副詞可能,…,結果        ← lexicalised ID
         けっか cost=6594
         結果  cost=15263 名詞,一般                    ← same surface, other entry
```

Reading these as "how likely is this word" is a category error. "Katakana beats
kanji" turned out to be a 40-point remainder left after throwing away half the
model — not something the dictionary asserts.

Consequence: **mozc's cost column cannot be reused as the scalar the design
asks dictionaries for.** Costs have to be estimated from text.

### Model decomposition

Same lattice, same search, cost model swapped. sent = exact match, charF =
character F1.

| model | gsd-test sent | charF | mozc-eval sent |
|---|---|---|---|
| **W+C** word cost + connection matrix | **63.1%** | 93.7% | 84.1% |
| W+L word cost + λ (best λ) | 22.4% | 73.6% | 46.2% |
| W+L per-item oracle λ | 29.5% | — | 57.0% |
| C matrix only (word costs zeroed) | 2.5% | 45.1% | 19.0% |
| L λ only | 3.6% | 46.2% | 31.6% |

**λ cannot reach it.** Sweeping 0–16000 in 33 steps and counting an item
correct if *any* λ gets it still leaves 33.6 points on the table. 70.5% of
items are wrong at every λ.

### λ was standing in for length normalisation

Re-estimating unigrams from 141k tokens and putting them in the same shape:

| gsd-test | sent | charF | best λ |
|---|---|---|---|
| mozc costs | 22.4% | 73.6% | 3500 |
| **re-estimated scalars** | **28.8%** | **82.8%** | **0** |
| oracle (MLE fitted on the test set) | 48.4% | 91.5% | 0 |

And the mechanism:

| unknown-word backoff | best sent | charF |
|---|---|---|
| constant (best of 36 combinations) | 21.4% | 65.4% |
| **character model (length-proportional), λ=0** | **28.8%** | **82.8%** |

**With correct costs λ=0 is optimal.** The boundary penalty existed to supply
the length normalisation a proper unigram gives for free.

Confirmed in this prototype: with mozc costs, λ=0 scores 31% and λ=5000 scores
84% — a 53-point spread. With estimated costs, 81% and 85% — four points.

### Parts of speech buy boundaries, not accuracy

| lattice | sent | charF | boundary P | segments |
|---|---|---|---|---|
| POS-constrained (文節) | 28.4% | 83.0% | 61.1% | 4.10 |
| free word lattice | 28.6% | 82.9% | 32.0% | 8.75 |

**Grammar pays for the unit shown to the user for correction, not for the
conversion.** This is why the segment-resize UI is not optional here: dropping
parts of speech halves boundary precision, and resizing is how the user covers
what the model gave up.

### Surface bigrams reach the full model

```
cost(w | previous surface) = -500 log[ λ P(w|previous) + (1-λ) P(w) ]
```

24M tokens (wiki:subs:news:talk = 3:1:1:0.3), 1.08M pairs seen twice or more,
λ=0.95:

| unit | unigram | **surface bigram** | mozc W+C |
|---|---|---|---|
| gsd phrase (4,434) | 75.3% | **85.6%** | 85.3% |
| gsd unit (1,283) | 40.7% | **61.5%** | 63.1% |

**No tags anywhere.** Still climbing at 24M (+3.2 points on the last doubling
at unit level). λ best at 0.85–0.95 — heavily towards the conditional.

A word the corpus never saw has no bigram and falls back to its unigram, so
adding an entry still behaves predictably. The layer design survives.

### 文節数最小法 needs parts of speech

Same dictionary, same lattice, same tiebreak:

| method | sent | charF | boundary R | boundary P |
|---|---|---|---|---|
| longest match | 8.7% | 65.3% | 12.0% | 21.7% |
| fewest segments | 13.3% | 73.4% | 34.9% | 64.3% |
| minimum cost | **28.4%** | **83.0%** | 73.8% | 61.1% |

The ordering literature asserts (fewest > longest) holds, **but the size of the
gap depends on the tiebreak cost model** — with mozc's costs exact-match is
4.3% either way.

Crucially: **"fewest segments" is not implementable without parts of speech.**
The definition of a 文節 (one content word plus zero or more function words)
requires tags. Without them it degrades to "fewest dictionary entries" and
produces 1.68 segments against a gold 3.58, scoring 3.6%.

So the flat boundary penalty in this prototype is *not* 文節数最小法, despite
being described that way early on. It is fewest-entries, which is weaker.

---

## Dictionaries

### Adding entries is safe with one constant

212,957 personal-name entries (20% of the vocabulary) removed, then restored at
a flat cost D with **no probability estimation at all**:

| | gsd-test | mozc-eval |
|---|---|---|
| base (names removed) | 30.2% | 22.6% |
| + D=0 | 0.3% | 2.5% |
| + D=8000 | 30.5% | 22.7% |
| **+ D=10000** | **30.7%** | **23.1%** |
| + D=20000 | 30.2% | 22.6% |
| + corpus-estimated costs | 28.8% | 20.0% |

**Estimating probabilities is not a requirement.** D≥8000 is a wide plateau.
And a naive corpus estimate is *worse* than a constant, because a name that
happened to appear gets a low cost and then collides.

Where the harm is, at D=5000 (the dangerous end):

| slice | entries | sent | vs base |
|---|---|---|---|
| all | 212,957 | 21.6% | −8.6 |
| **reading collides with an existing one** | 101,092 | 21.9% | **−8.3** |
| reading is new | 111,865 | 28.5% | −1.7 |
| reading ≤3 characters | 73,020 | 24.2% | −6.0 |
| **reading ≥6 characters** | 40,330 | 30.6% | **+0.4** |

**Harm concentrates in short readings that collide, not in volume.** Forty
thousand entries with a bad cost did nothing when their readings were long.
Specialist vocabulary is long, which is the safe end — and the store's first
target domain is exactly that.

This reverses the causal claim in mozc's paper (that adding without estimating
probabilities degrades accuracy, BLEU 0.874 → 0.863). The observation may hold;
the explanation does not.

### Corpora saturate

Independently collected Wikipedia, word level:

| tokens | gsd-test | mozc-eval |
|---|---|---|
| 140k | 66.5% | 52.0% |
| 1.2M | 78.0% | 63.3% |
| 3.4M | 79.5% | 65.1% |
| 10M | 80.2% | 65.7% |
| 30M | **80.3%** | 66.1% |

**+0.1 point from 10M to 30M.** Every genre saturates around 80% word level.
Mixing genres raises the ceiling by about two points and three genres is the
limit — a fourth made it slightly worse. Weighting towards the largest clean
genre beat equal weighting.

The decisive split:

| unit | mozc W+C | unigram 3.4M | unigram 20M | gap |
|---|---|---|---|---|
| word | 84.6% | 81.1% | 82.3% | **+2.4** |
| phrase | 85.3% | 69.8% | 71.0% | +14.3 |
| unit | 63.1% | 33.5% | 34.6% | +28.4 |

Six times the corpus moves sentence level by 1.1 points. **Word-level gaps are
a data problem and close. Phrase and sentence gaps are missing connection
information and do not.**

---

## Prediction

Measured in keystroke-equivalents with one free parameter, `c_sel` — the cost
of picking a candidate, in keystrokes. Keystroke savings rate alone assumes
`c_sel = 0`, which is the thing in dispute.

| source | never fires | fire rate | saved | KSR |
|---|---|---|---|---|
| **lexicon by its own costs** | **80.0%** | **11.9%** | **0.19 kana** | **3.5%** |
| lexicon by corpus frequency | 79.4% | 17.4% | 0.30 | 5.5% |
| user history | 56.5% | 37.2% | 0.75 | 13.7% |
| history + lexicon | 52.8% | 39.5% | 0.80 | 14.5% |

Against improving conversion instead:

| c_sel | improve conversion | add prediction |
|---|---|---|
| 0.0 | +0.13 … +0.43 | +0.84 … +0.93 |
| **1.0** | +0.17 … +0.47 | **−0.06 … +0.03** |
| 2.0 | +0.22 … +0.52 | −0.96 … −0.87 |

**Improving conversion is positive in all twelve cells. Prediction changes sign
around one keystroke.**

And more data does not rescue it:

| repeat rate | break-even selection cost |
|---|---|
| 20% | 1.06 keystrokes |
| 43.8% (measured) | 0.97 |
| 95% | 0.93 |

**The break-even barely moves.** As repetition rises, savings and selections
rise together. Accumulating history makes whichever side you are on larger, not
better.

Prediction is effectively a repeat detector: 85.0% fire rate on phrases already
in history, 4.0% on new ones — a 21× difference. Which is the transcribing /
thinking axis exactly.

Window contention, with the true candidate's visibility:

| window | conversion only | interleaved | bottom slots reserved |
|---|---|---|---|
| 3 | 79.8% | 78.4% (−1.4) | **65.5% (−14.3)** |
| 5 | 84.6% | 83.3% (−1.3) | 79.8% (−4.8) |

**Reserving slots is what does the damage; merging by score is nearly free.**

---

## This prototype

| | phrase (75) | word (199) | sentence (46) | breakdowns (12) |
|---|---|---|---|---|
| index layer only | 51% | 89% | 9% | 12/12 |
| **+ segmentation** | **84%** | 88% | 46% | 11/12 |
| + surface bigram | 79% | 83% | 43% | 11/12 |

Pre-expansion of readings, on 57 security terms:

| | reachable | top-1 |
|---|---|---|
| without the mode dictionary | 19/57 (33%) | 9% |
| **with it** | **57/57 (100%)** | **86%** |

Word, phrase and breakdown scores were **identical** either way. The average
did not move; the worst case disappeared. That is the shape the mode dictionary
is for — an unreachable term costs a trip to a browser, not a worse ranking.

Minimum reading length, measured rather than assumed:

| floor | reachable | word | breakdowns | phrase |
|---|---|---|---|---|
| 3 | 57/57 | 176/199 | 11/12 | 63/75 |
| 4 | 54/57 | 176/199 | 11/12 | 63/75 |
| 5 | 51/57 | 176/199 | 11/12 | 63/75 |

Nothing else moved at any setting, so the floor was buying nothing. **This does
not scale** — ten short readings among 63 terms are invisible, and the harm it
guards against was measured across 212,957 entries.

---

## Caveats

**gsd-test is not a shared benchmark.** It was constructed from
UD_Japanese-GSD's 543 test sentences (gold boundaries from `BunsetuBILabel`,
readings from fugashi + unidic-lite). It is Wikipedia text, CC BY-SA. It is
free of mozc's tuning, which is what it was for, but it carries no authority as
a benchmark. The real shared one is the **Microsoft Research IME Corpus
(MSR-TR-2005-168)** — 6,000 sentences with readings and 100-best lists. Not
used here. What azooKey evaluates against was never checked.

**mozc-eval is mozc's own regression set.** mozc scores 84.1% there against
63.1% on gsd-test; a surface-bigram model scores 46% there against 61.5%. The
ordering inverts with the evaluation set, which is what overfitting looks like.
Comparisons on mozc-eval measure how well mozc is tuned, not how good it is.
**This prototype's own test sets are hand-written and carry the same risk.**

**One extrapolation was already wrong.** "Same genre, 3.4M tokens, 89%" came
from a power law fitted to a train/test split of one sample — the same
collection and tokenisation pipeline, so adding data covered that sample's own
vocabulary and the curve looked unbounded. Independent data gave 79.5% and a
saturation curve. Any remaining extrapolation here deserves the same suspicion.

**W+C is not mozc.** No rewriter, no collocation, no suffix dictionary, no
learning, no user dictionary. It reproduces 87.4% of mozc's OK rows and 74.5%
of its FAILED rows — the separation is weak. Read 63.1% and 84.1% as lower
bounds. Model-to-model comparisons are unaffected, being within one engine.

**Top-1 only.** A real IME lets you take the second or third candidate, and
none of these numbers account for that. The framing objection raised against
sentence-level evaluation applies to the phrase-level numbers too.

**No timing study.** `c_sel` decides the prediction question and was left as a
parameter rather than measured. Settling it needs people typing the same text
with and without prediction. The cited literature (Palin et al. 2019, n=37,370;
Koester & Levine) is English and mobile, where the baseline differs — Japanese
input already requires candidate selection.

**The bigram does not work here yet.** 79%, against 85.6% in the reference
implementation. See `decisions.md`.
