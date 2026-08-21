# MS-IME の変換はどう決まっているのか

自作エンジンの設計判断のための調査。中心の問いは **「変換結果を文意によって変えているのか、それとも履歴ベースなのか」**。

結論から書くと **どちらでもあり、どちらでもない**。文脈は使うが「文意」ではなく単語 N-gram という局所統計で、履歴はその N-gram に混ざるのではなく**辞書層に書き戻される別レイヤー**として効く。この分離こそが MS-IME の体感を作っている。

---

## 1. 変換エンジン: トライグラム → バイグラム → クラスタバイグラム

一次情報は Microsoft 名義の特許 [US8744833B2](https://patents.google.com/patent/US8744833B2/en)（発明者 Rie Maeda / Yoshiharu Sato / Miyuki Seki、2006年出願・2014年登録、現権利者 Microsoft Technology Licensing）。かな漢字変換の言語モデルそのものを扱っている。

処理はこうなっている。

```
かな入力 → 部分文字列に分割 → 各部分の漢字候補を生成
  → トライグラム確率（閾値を満たすか）
  → 満たさなければ バイグラム
  → それも満たさなければ クラスタバイグラム
```

独立クレーム1の核心部分:

> select a Kanji candidate based on cluster bigram probabilities of the Kanji candidates,
> wherein at least one cluster in the cluster bigram probabilities includes combining
> the same Kanji-Kana pairs with different parts-of-speech

重要なのは **ユニグラムに落とさない**という設計判断。通常の N-gram バックオフは最後に文脈を失った単独確率まで落ちるが、この特許は「ユニグラムへのバックオフをクラスタバイグラムで置き換える」と明言している。文脈を最後まで手放さない。

クラスタとは「表記と読みが同じで品詞だけが違うもの」を束ねた類。データが薄い組み合わせでも、品詞クラスの単位でなら統計が立つ。特許は狙いを **表層的な属性から統計的に学習できること**（意味的な人手判断を要求しないこと）に置いていると述べている。

つまり **意味解析はしていない**。「ピアノの奏者だから演奏者」のような推論ではなく、単語の並びの出現統計を見ているだけ。ただし窓は Mozc より広い。

| | 文脈の窓 |
|---|---|
| MS-IME（特許の設計） | トライグラム（直前2語）+ クラスタバイグラムのフォールバック |
| Mozc / Google 日本語入力 | 原則 **直前1単語のみ** |
| 自作エンジン現状（ipadic 連接コスト） | 直前1語の品詞バイグラム相当 |

Mozc の窓の狭さは[さくらのナレッジの Zenzai 開発記事](https://knowledge.sakura.ad.jp/42901/)に明記されている。「かいじょう」（会場／海上）のような同音異義語を1語窓では捌けない、というのが Zenzai を作った動機として語られている。

**時期の裏取り**: [Wikipedia 日本語版](https://ja.wikipedia.org/wiki/Microsoft_IME) は Office IME 2007 (v12.0) で Trigram/SLM アルゴリズムに切り替えたと記述している（出典なし・信頼度低）。ただし特許の出願が2006年、2007年版で文節区切りが細かくなる不具合が出て修正プログラムが出たという事実と整合する。**状況証拠としては強いが、現行版（v15 系 / 2020年の新 IME）が今もこの構成かは未確認**。

## 2. 履歴は言語モデルに混ざらない。辞書に書き戻される

ここが最も設計に効く発見。

[ADMX_EAIME Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-eaime)（Microsoft 公式、2025-03 更新）に、学習系の機能がポリシー単位で列挙されている。そして `L_TurnOffCustomDictionary` の説明にこう書かれている。

> [Clear auto-tuning information] removes self-tuned words **from the custom dictionary**

**自動チューニングの結果はユーザー辞書（カスタム辞書）に入っている。** 言語モデルを再推定しているのではなく、辞書エントリとして書き足されている。だから「学習情報の消去」がユーザー辞書からの削除操作として表現される。

保存先も実体として確認できる（コミュニティ情報、Tier C）:

```
学習情報   %LOCALAPPDATA%\Microsoft\IME\15.0\IMEJP\Cache\imjp15cache.dat
ユーザー辞書 %APPDATA%\Microsoft\IME\15.0\IMEJP\UserDict\imjp15cu.dic
```

学習キャッシュと辞書がファイルとして分かれている点は、上の「辞書に書き戻される」という記述と厳密には整合しない可能性がある（キャッシュ＝短期学習、辞書＝自動チューニング語、という二段構成と読むのが自然）。**ここは未解決**。

関連ポリシーの全体像:

| ポリシー | 既定 | 意味 |
|---|---|---|
| `L_TurnOffHistorybasedPredictiveInput` | 履歴ベース予測入力は**オン** | 予測入力が入力履歴を使う |
| `L_TurnOffSavingAutoTuningDataToFile` | 保存**する** | 自動チューニング結果をファイルに永続化 |
| `L_TurnOffCustomDictionary` | 使える | ユーザー辞書。自己学習語もここ |
| `L_TurnOnCloudCandidate` | **オフ** | オンにするとキー入力が Microsoft に送信される |
| `L_TurnOnMisconversionLoggingForMisconversionReport` | **オフ** | 誤変換ログ |
| `L_TurnOffOpenExtendedDictionary` | 使える | オープン拡張辞書 |

設定 UI 側も同じ分離になっている（[Microsoft Japanese IME サポート文書](https://support.microsoft.com/en-us/windows/microsoft-japanese-ime-da40471d-6b91-4042-ae8b-713a96476916)）。予測入力の設定は3つが**独立に**オン／オフできる。

- 入力履歴を使う
- システム辞書を使う
- 提案サービスを使う（"anything that is written is encrypted and sent to Microsoft to get text suggestions from Bing"）

そして「学習と辞書」に別立てで **"Improve input accuracy based on what I type on this PC"**。

**独立に切れるということは、実装上も別ソースだということ。** 混ざった単一モデルなら個別に無効化できない。

## 3. 全体像

```
[スペースキーによる変換]
    静的な統計言語モデル（トライグラム + クラスタバイグラム）で最小コスト経路
    ＋ ユーザー辞書 / システム辞書 / オープン拡張辞書のエントリ
    ＋ 自動チューニングで書き戻された語（＝過去の確定が辞書層で効く）

[予測入力（変換前のサジェスト）]
    入力履歴 ／ システム辞書 ／ Bing  ← 3系統、独立にオン/オフ

[クラウド]
    既定オフ。ローカル辞書に無い語のためだけ
```

ユーザーが「最近の MS-IME は使いやすい」と感じている中身は、おそらくこの2つの合成である。

1. トライグラム＋クラスタバイグラムで、長文一括変換でも文節区切りが崩れにくい
2. 一度確定した変換が辞書層に落ちて、次から確実に第一候補に来る

**賢い文脈理解で当てているのではない。そこそこの局所統計と、辞書層での確実な上書きの組み合わせ。**

## 4. 対照: Apple は別の解を採っていた

[US7548863B2 "Adaptive context sensitive analysis"](https://patents.google.com/patent/US7548863B2/en) は **Apple**（発明者 Yasuo Kida ほか、2002年出願、現在は期限切れ）。当初 Microsoft 特許だと想定して当たったが違った。

やっていることが面白い。ユーザー履歴 DB を持たず、**入力中のテキストをベクトル化して既存文書とコサイン類似度で照合し、似た文書での語の出現頻度で辞書に重みを付ける**。

> finding documents that are similar to the input data and using the similar documents
> to create a customized dictionary

履歴を貯めずに文脈適応する、という第三の道。macOS 標準 IME の系譜がこれを実装しているかは未確認だが、発想として記録しておく価値がある。

## 5. 辞書フォーマットの再確認

オープン拡張辞書は DCTX（XML ベースのテキスト）と DCTXC（CAB 圧縮、配布用）の2形式。エディタと Excel テンプレートが Microsoft から配布されていた（Office IME 2010 時代、現在は NOT SUPPORTED 扱い）。ダブルクリックでインストールされる。

ポリシーで丸ごと無効化できる（`L_TurnOffOpenExtendedDictionary`）という事実は、**オープン拡張辞書が変換エンジンにとって差し替え可能な独立レイヤーとして実装されている**ことを意味する。辞書ストア構想にとって好材料。

## 6. 自作エンジンへの含意

### 6.1 ipadic のコストが変換用でない、の答えがはっきりした

[`kkc eval`](../README.md#findings) の結果（top-1 47% / top-5 77%、「ちょっと」→「チョット」型の失敗）は、モデルの窓の問題ではなく **コストの推定元**の問題だった。

MS-IME も Mozc も、コストは「書かれたテキストの単語 N-gram」から推定している。ipadic のコストは形態素解析（分割精度の最大化）用で、「読みから何を書くか」の分布ではない。

Zenzai の学習データの作り方がそのまま答えになっている。**オープンコーパスに読み推定をかけて1.9億文**を作った、と記事にある。変換用のモデルは「表記に読みを自動付与したコーパス」から作る。これは自作エンジンでも同じ手順が採れる。

### 6.2 次の一手（改訂）

README に書いた3案のうち、**②「書き言葉コーパスから生起コストを再推定」が本命**と確定した。①のヒューリスティックは②までのつなぎ。

さらに MS-IME の設計から2点持ち込む価値がある。

- **クラスタバイグラムの発想**: ipadic の連接コスト行列は既に品詞（文脈ID）バイグラムなので、これは実質そのまま使える。差し替えるべきは生起コストだけ、という最小手が成立する
- **ユニグラムに落とさない**: データが薄いときに文脈を捨てるのではなく、粗いクラスの文脈に退避する

### 6.3 「辞書で補える設計」は正しかった

[Labee - Ideas のコンセプト](https://example.invalid)（入力モードでIMEを再定義する／辞書ストア／軽量 macOS IME）が置いている前提——**エンジンで殴らず辞書で補う、辞書追加の効き方が説明可能である**——は、MS-IME が実際に採っている構造と一致する。

しかも MS-IME は学習結果すら辞書層に置いている。**「学習」と「配布される辞書」を同じレイヤーで扱えるという実例**であり、自作エンジンでも同じ構造が採れる。ユーザーの確定履歴とストアから入れた辞書が同じ仕組みで効くなら、実装も説明も一本化できる。

### 6.4 Helpfeel 方式との関係

コンセプトノートにある事前展開型（1つの表記に複数の読み・表記ゆれ・タイポを事前生成して索引化）は **読み側の入口を増やす**手法であって、**コスト（順位付け）の問題は解かない**。両方が要る。

- 事前展開 → 「引けない」を消す
- コスト再推定 → 「引けるが順位が違う」を消す

現状の失敗（top-5 77%）はほぼ後者。優先順位は コスト再推定 > 事前展開。

---

## 検証状況

| 主張 | 根拠 | 信頼度 |
|---|---|---|
| MS-IME 系のエンジンはトライグラム＋クラスタバイグラム | US8744833B2（Microsoft 名義の一次情報） | 高（ただし現行版での採用は未確認） |
| Office IME 2007 で SLM に切替 | Wikipedia（出典なし）＋ 特許出願時期の整合 | 中 |
| 自動チューニング語はユーザー辞書に入る | Microsoft Learn Policy CSP の明文 | 高 |
| 履歴・辞書・クラウドは独立レイヤー | Policy CSP ＋ 設定 UI の独立トグル | 高 |
| クラウド候補は既定オフ | Policy CSP の明文 | 高 |
| Mozc は直前1単語のみ | さくらのナレッジ（Zenzai 開発者記事） | 中〜高 |
| Apple は文書類似度で文脈適応 | US7548863B2（Apple 名義の一次情報） | 高（実装への反映は未確認） |
| 学習情報のファイル配置 | 個人ブログ・技術記事 | 低（要検証） |

## 未解決

- **現行 MS-IME（2020年の新 IME / v15 系）のエンジン構成**。2006年の特許が今も生きているかは公開情報から確定できない
- **`imjp15cache.dat`（学習キャッシュ）と `imjp15cu.dic`（ユーザー辞書）の役割分担**。短期学習と自動チューニングの二段構成と推測しているが未確認
- **DCTX の `Priority` が変換コストにどう写像されるか**。仕様書は公開されていない
- **macOS 標準 IME が US7548863B2 の文書類似度方式を実装しているか**

## 参考

一次情報:
- [US8744833B2 - Method and apparatus for creating a language model and kana-kanji conversion](https://patents.google.com/patent/US8744833B2/en)（Microsoft、2006出願／2014登録）
- [US7548863B2 - Adaptive context sensitive analysis](https://patents.google.com/patent/US7548863B2/en)（Apple、2002出願）
- [ADMX_EAIME Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-eaime)（2025-03）
- [Microsoft Japanese IME](https://support.microsoft.com/en-us/windows/microsoft-japanese-ime-da40471d-6b91-4042-ae8b-713a96476916)
- [Japanese IME - Globalization](https://learn.microsoft.com/en-us/globalization/input/japanese-ime)（2024-06）
- [入力方式エディター (IME) の以前のバージョンに戻す](https://support.microsoft.com/ja-jp/windows/hardware/input-devices/revert-to-a-previous-version-of-an-input-method-editor-ime)

二次情報:
- [ニューラルかな漢字変換システム「Zenzai」の開発](https://knowledge.sakura.ad.jp/42901/) — Mozc の1語窓の限界
- [日本語入力の15年：OS標準IMEの進化と停滞](https://note.com/fukuy/n/nd6a1555df944)（2025-12）
- [Microsoft IME - Wikipedia](https://ja.wikipedia.org/wiki/Microsoft_IME)
- [オープン拡張辞書の DCTX / DCTXC 形式](https://publisher2.exblog.jp/15384060)
- [Copilot Keyboard - Windows Blog for Japan](https://blogs.windows.com/japan/2026/01/20/copilot-keyboard-japanese-input/)（2026-01）
- [新語は"Google超え"――Microsoftの「Copilot Keyboard」](https://www.itmedia.co.jp/news/articles/2601/15/news131.html)（2026-01）
