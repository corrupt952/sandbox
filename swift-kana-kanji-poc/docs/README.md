# Notes

Background for the prototype in the parent directory. Written to survive being
picked up cold — by someone else, or by the same person a month later.

| | |
|---|---|
| [`decisions.md`](decisions.md) | Why the engine is shaped this way. Start here. |
| [`measurements.md`](measurements.md) | Every number the decisions rest on, with caveats. |
| [`failures.md`](failures.md) | Bugs that mattered, and what caught them. |
| [`prior-art.md`](prior-art.md) | mozc, azooKey, Anthy, Helpfeel — borrowed from and diverged from. |
| [`ms-ime.md`](ms-ime.md) | What MS-IME actually does, from primary sources. The design's starting point. |

## The short version

The premise is that **a conversion engine does not need to be clever if the
dictionaries around it are good.** That came from MS-IME: its reputation is for
not breaking rather than for brilliance, it uses a plain word trigram with no
semantics, it keeps what you teach it in the dictionary layer rather than the
model, and it lets you switch individual system dictionaries off so it can be
told to stop being helpful. Cleverness was traded away deliberately and the
dictionary was opened up instead.

This pushes the same trade further: **no part-of-speech system at all.** A
dictionary supplies a reading, a surface, and optionally a number. That
constraint is the whole point — it is what lets a dictionary someone else wrote
drop in and behave predictably. Everyone else's engine requires each entry to
declare which of thousands of grammatical classes it belongs to, and everyone
else has already found that untenable for users and worked around it while
keeping the system internally.

Measurements said the trade is affordable. Parts of speech buy boundary
precision rather than accuracy; surface bigrams reach mozc's full model with no
tags; adding a dictionary needs one constant rather than a probability model.

## What is not settled

The bigram implementation here reaches 79% against the reference's 85.6%, for a
reason that is understood but not fixed — see the end of `decisions.md`.

The evaluation sets are hand-written and small, and the same overfitting
suspicion that applies to mozc's own regression set applies to them. The
prototype has not been used for days at a time, which was the original bar.

And one extrapolation in this work was already wrong by ten points before being
caught. The caveats at the end of `measurements.md` are not boilerplate.
