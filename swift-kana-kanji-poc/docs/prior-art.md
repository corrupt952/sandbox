# Prior art

What existing systems do, where this design borrowed, and where it diverged on
purpose. MS-IME has its own document ([`ms-ime.md`](ms-ime.md)) since it is the
starting point rather than a comparison.

---

## Helpfeel — pre-expansion, from a patent

Not an IME. A search product whose central claim is the same mechanism this
engine uses for readings, which is why it is here.

The patent describes a 誘導文辞書: for each 目的文章 (the answer you want the
user to reach), multiple 誘導文候補 are **generated and registered in advance**,
each phrased with more common vocabulary than the answer itself. A query matches
a candidate; the candidate points at the answer. Runtime is a plain lookup —
all the work happened at dictionary-build time.

That is exactly the bet made here on readings. XSS filed only under
くろすさいとすくりぷてぃんぐ is unreachable to anyone typing えっくすえすえす;
generating the ways in at build time makes the runtime a lookup and nothing more.

Two paragraphs earned their place in the design:

**【００７７】 rejects "just prepare more articles."** Providing many rephrased
variants does make queries hit — and makes irrelevant things hit too, produces
several near-identical answers that confuse, and wrecks maintainability. This is
the same failure that 教派 caused here: expansion increases what can match, and
what can match competes. It is why expanded and added entries win *within* a
segment but do not get to decide the split.

**【００７８】 rejects learned relevance ranking**, on grounds that are worth
reading against the reflex to add a model: it does not stop unintended results
being ranked high; results that are commercially or compliance-wise unacceptable
are hard to reliably exclude; and it reacts slowly when the underlying service
changes, because it learns from past queries. Substituting "dictionary" for
"articles" gives the argument for a total order over layers rather than a
cost-based one.

**【０３９３】's 辞書改善部 learns from non-selection** — candidates presented
and then *not* confirmed feed back into the keyword/candidate mapping. Nothing
here uses negative signal; this engine only learns from commits. Worth
remembering as an available signal, since an IME sees exactly the same event
(candidate shown, user typed past it).

Raw text is not copied into this repo — it is third-party full text, 96 KB, and
retrievable. The prior art it cites for its own background is 特開2015-056014.

## mozc

The vocabulary source, and the reference implementation for measurement.

- **2672 context IDs** in a connection matrix. High-frequency words get
  lexicalised IDs and have their cost flattened towards zero, with the
  discriminating information living in the matrix. This is why mozc's cost
  column cannot be read as a unigram — です is 0, デス is 40, 結果 exists at both
  1 and 15263.
- **48 user-facing labels** over those 2672 IDs. Another engine that concluded
  users cannot be asked for parts of speech, and kept the system internally.
- **`SUGGESTION_ONLY`** — vocabulary that appears in suggestions but never
  enters the lattice. An independent arrival at the same separation as 【００７７】.
- **Refuses to generalise a correction across differing parts of speech** — a
  guard against permanent mislearning that requires tags, and is therefore
  unavailable here. Decay replaces it.
- Keyed by **surface**, since morphological analysis reads text. Conversion
  needs the other direction, so the index is rebuilt on the reading column.

## azooKey

Explicitly not adopted as an engine. Read for reference, and one mechanism
taken.

- **Decay learning**: a `UInt8` count halved every 32 days. This is the
  mislearning guard that survives having no parts of speech to check against,
  so it is the one used here.
- **`testCoarseForget`** — forgetting is deliberately coarse; a surface goes
  wherever it appears under that reading. Same conclusion reached
  independently: being asked to forget a candidate and seeing it again because
  another entry spelled it the same way is worse than forgetting too much.
- **1319 context IDs**, and three booleans exposed to users in place of them.
- Its roadmap lists **exposing parts of speech to users as a wanted feature.**
  Worth stating plainly: for azooKey the absence is a limitation, here it is the
  design. The same state of affairs with opposite meanings — so "azooKey manages
  without them too" is not an argument that can be borrowed.

## Anthy

Caps learned entries at 100–1000 per kind. The bluntest of the mislearning
guards, and evidence that every shipping engine has one. A cap bounds damage by
count; decay bounds it by time. Time is the better axis for this design, since
the cost of a mistake here is that it keeps being recalled, not that there are
many of them.

## Chinese IMEs

Decline to add to the vocabulary from user input at all — learning reorders what
exists rather than creating entries. The most conservative point on the same
axis, and a reminder that "learn a new word from one commit" is a choice, not a
default.

## macOS / Kotoeri

The user-dictionary part-of-speech field is vestigial. Kotoeri's own behaviour
is also the honest baseline for this whole project: *"if you just added
dictionaries to Kotoeri, wouldn't you get the same thing?"* is a fair question,
and the answer this prototype offers is the four-layer total order plus
build-time expansion — mechanisms Kotoeri does not expose — rather than better
conversion.

Input methods run out-of-process on macOS, unlike Windows TSF which loads the
IME into the host application. A crash cannot take an app down with it, but it
does take your typing down, which is why the daily-driver trial is gated on
having a working IME to switch back to.
