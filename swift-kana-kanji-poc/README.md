# swift-kana-kanji-poc

A kana-kanji conversion engine written from scratch in Swift, to answer one
question: **can an engine that isn't clever be good enough, if the dictionaries
around it are?**

That framing came from looking at what MS-IME actually does. Its reputation is
not for brilliance — it is for not breaking. It uses a plain word trigram, no
semantics anywhere; it keeps what you teach it in the dictionary layer rather
than in the model; and it lets you switch individual system dictionaries off so
it can be told to stop being helpful. Cleverness was traded away on purpose,
and the dictionary was opened up instead.

So this tries the same trade, pushed further: **no part-of-speech system at
all**. A dictionary supplies a reading, a surface, and optionally a number.
Nothing else. That constraint is the point — it is what lets a dictionary
someone else wrote drop in and behave predictably.

## Where it stands

| | phrase | word | sentence | breakdowns |
|---|---|---|---|---|
| index layer only | 51% | 89% | 9% | 12/12 |
| **+ segmentation** | **84%** | 88% | 46% | 11/12 |
| + surface bigram | 79% | 83% | 43% | 11/12 |

Word-level conversion is the strong part and has been since early on. Phrase
level works. Whole sentences do not, and the measurements below say why.

Terminology: **phrase** is what the product actually converts — you type a
chunk, convert, commit, type the next. **Sentence** is the whole thing at once.
**Breakdowns** counts outputs nobody would ever want, which is a different
question from accuracy and is scored separately for that reason.

## Running it

```sh
scripts/fetch-mozc-dict.sh          # vocabulary        → dict/mozc/
scripts/fetch-wikipedia.sh          # text for counting → dict/corpus/
swift run -c release kkc build      # compile the index (≈5 s)
swift run -c release kkc expand     # mode dictionaries from dict-src/
swift run -c release kkclab         # the app
swift test
```

Nothing downloaded is committed; `dict/` is gitignored. That mirrors how this
would have to ship anyway — code in the package, language resources fetched —
which is how mozc-UT sidesteps redistribution.

```sh
kkc index <reading>      # index layer alone
kkc segment <reading>    # with segmentation
kkc eval --set samples/phrase
kkc scan                 # count surfaces and pairs in the corpus
```

## How it is put together

### Four dictionaries, ordered absolutely

```
user      dict/user.txt           written down on purpose. never decays
learned   dict/learned.tsv        picked up from typing. halves every 32 days
mode      dict/mode/*.tsv         installed for a domain
baseline  dict/build/lexicon.bin  mozc's vocabulary
```

Conflicts are settled by layer, not by cost. This is stronger than it sounds: a
cost-based engine cannot promise that adding a word makes it win, because
enough accumulated cost elsewhere still beats it. A total order can. When the
product promise is "install this dictionary and this word converts", the
cruder mechanism is the one that keeps it.

Learning goes to its own layer rather than into the user's dictionary, because
*what you confirmed once* and *what you wrote down deliberately* are different
claims. One confirmation survives a month and then is gone — 1 >> 1 is 0 — so a
mistaken commit stops being a life sentence. Everything shipping guards against
this somehow; azooKey's decay is the version that survives having no parts of
speech to check.

### Index layer: reading → words

mozc is keyed by surface form, since morphological analysis reads text and
produces morphemes. Conversion needs the other direction, so the index is
rebuilt on the reading column. Lookup is a binary search over sorted keys, not
a trie: an input is a few dozen characters, so the trie can wait until it shows
up in a profile.

Two things are expanded at build time rather than derived at conversion time.

**Inflections.** mozc stores stems — `かい → 書い` tagged 連用タ接続, with the
た supplied by an auxiliary entry the lattice joins on. Without a lattice,
`かいた` returns place names and no verb. Expanding gives 626k entries and the
table is written out where it can be read and argued with. Getting it wrong is
easy and quiet: 撥音便 and ガ行 take だ/で rather than た/て (読ん+だ, 泳い+だ),
サ行五段 has no 連用タ接続 at all (話し+た comes off 連用形), and 未然形+ず
manufactured 見ず — a 文語 form mozc deliberately lacks — which then outranked
水.

**Readings.** A word is reachable only through readings it was given. XSS filed
under くろすさいとすくりぷてぃんぐ is unreachable to anyone typing
えっくすえすえす, which is what people type. Generating the ways in took the
security dictionary's coverage from 19/57 to 57/57 **while moving nothing else
at all** — word, phrase and breakdown scores were identical. That shape matters
more than the average: the cost of an unreachable term is not a worse ranking,
it is switching to a browser to search for it and losing the thread.

The failure to watch for is silent. A kanji surface with no reading written
down produces nothing — the row is in the file and the word simply never
appears. Nine terms were in that state; `kkc expand` now reports them.

### Segmentation: no parts of speech

```
path_cost = Σ entry_cost(w) + λ × (number of segments)
```

A flat penalty per segment, and it needs no grammar. It beat ipadic's
part-of-speech connection matrix on top-1 (35% against 20%) with neither a
matrix nor a tag.

This is *not* 文節数最小法, despite being called that earlier in the work. That
method's 文節 is defined by parts of speech — content word plus its attached
function words — so without tags it degrades to fewest-dictionary-entries, which
measures 3.6%. What is implemented here is the weaker thing.

**Layer priority is deliberately kept out of the split.** A user entry covering
a long reading, given its usual absolute priority, swallows the sentence:
きょうは confirmed once as 教派 then blocks きょう|は forever. So user and mode
entries enter the lattice at a neutral cost and win only *within* a segment.

The segment UI is not a luxury. Measured, dropping parts of speech costs almost
nothing in conversion accuracy but halves boundary precision — this engine puts
the split in the wrong place more often than a tagged one does. Resizing is how
the user pays for the part the model gave up.

### Remembered segmentations

Committing stores the split whole, and the next occurrence recalls it instead
of recomputing. Prefix matching means yesterday's きょうは carries into today's
きょうはさむかった, which is where the value is: openings repeat even when
sentences do not.

This is the same move as expanding inflections, applied to joins — rather than
deriving 今日 + は at conversion time, `きょうは → 今日は` goes in the store.
**The concept of a connection cost disappears instead of being approximated.**
The search-engine analogy is exact: query logs, not a grammar.

## What was measured

Numbers below are from a reference implementation built alongside this one, run
on UD_Japanese-GSD with gold boundaries. Full tables, sources and caveats are in
[`docs/measurements.md`](docs/measurements.md); the reasoning they support is in
[`docs/decisions.md`](docs/decisions.md).

**mozc's costs are not scalars.** High-frequency words get a lexicalised
context ID and have their cost flattened towards zero, with the discriminating
information moved into the 2672×2672 matrix. です is 0 and デス is 40; 結果
exists at both 1 and 15263. Reading those as "how likely is this word" is a
category error, and it is why a boundary penalty was needed at all — λ was
standing in for length normalisation a real unigram gives for free. With costs
re-estimated from text, λ=0 becomes optimal.

**Adding a dictionary is safe with one constant.** 212,957 entries added with
no probability estimation at all, at a flat cost, moved accuracy from 30.2% to
30.7%. Harm concentrates entirely in *short readings that collide with existing
words*: readings of six characters or more caused none. Specialist vocabulary
is long, which is the safe end. And a naive corpus estimate for those entries
was **worse** than the constant.

**Parts of speech buy boundaries, not accuracy.** A POS-constrained lattice
scored 28.4% against a free lattice's 28.6% — but boundary precision was 61%
against 32%. Grammar is paying for the unit you show the user to correct, not
for the conversion.

**The measure decides the design.** Converting phrase by phrase rather than
sentence at once cuts the gap between models to a third, and moves the optimal
λ. A model without connection information does *worse* on whole sentences than
on the same text converted phrase by phrase, while a bigram model does better.
Tuning against sentence-level scores was optimising a number this architecture
cannot reach.

**Surface bigrams close the gap that parts of speech were supposedly needed
for.** `cost(w | previous surface)` interpolated with the unigram reaches 85.6%
at phrase level against mozc's full model at 85.3% — no tags anywhere, and a
word the corpus never saw simply has no bigram and falls back, so adding
entries still behaves predictably.

**Prediction from the baseline dictionary is worth switching off.** Ranking a
million-entry lexicon by its own costs puts something useful in the window
11.9% of the time and produces nothing at all for 80% of phrases; user history
gives 39.5%. What the lexicon reliably does is fill the window with
のんで→ノンデイト. Prediction now comes only from layers that know this user.

## Open

**The bigram here reaches 79%, not the 85% the reference implementation gets.**
The remaining gap is the tokenisation used to count: this counts by
longest-match over dictionary surfaces, which covers 55% of the pairs the
lattice actually proposes against 80% for morphological short units. More
bigrams, the wrong ones. Fixing it means running an analyser offline — no
runtime dependency, but a build-time one.

Sentence-level conversion stays weak and the measurements say that is expected
rather than fixable by more data: single-genre corpora saturate around 80% at
word level however much is added, mixing genres raises the ceiling about two
points, and the phrase and sentence gaps are connection information rather than
coverage.

Not built: character-type conversion as an explicit operation, and an
InputMethodKit shell. The app substitutes for the latter — an input source has
to be installed and logged back into, and takes your typing down with it when
it breaks, which is a bad trade while the thing under test is still changing.

## Layout

```
docs/                      decisions, measurements, and the MS-IME study
Sources/KanaKanjiCore/
  Kana / Romaji            kana normalisation, romaji input
  Lexicon                  mmapped index, prefix search
  DictionaryBuilder        mozc or ipadic → compiled index
  Inflection / Expansion   build-time expansion of forms and readings
  LayeredIndex             the four layers and their total order
  Lattice                  k-best Viterbi, transition cost injected
  SegmentingConverter      segmentation without parts of speech
  LearningStore            decaying word memory
  SegmentationStore        remembered splits
  CorpusEstimator          unigram costs from text
  SurfaceScanner           counting surfaces and pairs in raw text
  BigramModel              transition costs from text
Sources/kkc                CLI
Sources/kkclab             the app
samples/                   phrase/ sentence, regression/ word-level and no-garbage
dict-src/                  mode dictionaries before expansion
```

## Notes

- mozc's dictionary is BSD-3-Clause plus IPAdic terms; Wikipedia text is
  CC BY-SA. Neither is committed. Redistribution is a gate on shipping, not on
  finding out whether the approach works.
- macOS input methods run in their own process, unlike Windows TSF which loads
  the IME into the host application. A crash cannot take an app down with it —
  but it does take your typing down, so any daily-driver trial needs a working
  IME to switch back to.
