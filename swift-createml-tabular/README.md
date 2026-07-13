# swift-createml-tabular

A miniature Kaggle loop with Create ML tabular models: load a CSV with
`TabularData.DataFrame`, tweak the feature set on the command line, retrain,
and see accuracy change — each run finishes in ~0.03 s.

Part of a series of experiments comparing feedback-loop speed across the Apple
ML stack (Create ML / Core ML / MLX).

## Structure

| Target | Kind | Purpose |
|--------|------|---------|
| `TabularCore` | library | Option parsing, DataFrame preprocessing (column selection, median impute, nil-row drop, seeded split) — unit-tested |
| `train` | CLI | Trains `MLBoostedTreeClassifier` / `MLLogisticRegressionClassifier` / `MLBoostedTreeRegressor` / `MLLinearRegressor` and prints train/validation/test metrics |

## How to run

```sh
Scripts/fetch-titanic.sh   # downloads data/titanic.csv

swift run -c release train --data data/titanic.csv --target Survived \
  --features Pclass,Sex
swift run -c release train --data data/titanic.csv --target Survived \
  --features Pclass,Sex,Age,Fare,SibSp,Parch
swift run -c release train --data data/titanic.csv --target Survived \
  --features Pclass,Sex,Age,Fare,SibSp,Parch --model linear
```

Options: `--task classification|regression`, `--model boostedTree|linear`,
`--split 0.8`, `--seed 42`. Numeric columns are median-imputed; remaining rows
with nils are dropped; the train/test split is seeded and deterministic.

Tests:

```sh
swift test
```

## Results (Titanic, M5 Max, macOS 26.5)

| Features | Model | Test accuracy | Elapsed |
|----------|-------|--------------:|--------:|
| Pclass, Sex | boostedTree | 78.8% | 0.03 s |
| + Age, Fare, SibSp, Parch | boostedTree | 82.7% | 0.02 s |
| + Age, Fare, SibSp, Parch | linear | 79.3% | 0.02 s |

The hypothesis→train→score loop closes instantly; the bottleneck is thinking
of the next feature, not compute.

## Requirements

macOS 14+.
