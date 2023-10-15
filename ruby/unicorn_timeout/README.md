# Unicorn timeout

Unicornのタイムアウト検証

## 設定

- Nginxのタイムアウト ... 3秒（`nginx/conf.d/default.conf`）
- Unicornのタイムアウト ... 3秒（`app/unicorn.conf`）
- RailsのControllerでのsleep ... 5秒（`app/app/controllers/top_controller.rb`）

## 検証手順

### Unicornのタイムアウト設定の確認

Unicornの設定ファイルにある`timeout`を超える処理をすると、UnicornのWorker ProcessがKillされます。

1. コンテナの起動 ... `docker compose up -d`
1. リクエストがタイムアウトすることを確認する ... <http://127.0.0.1:8080>
1. Unicorn側のタイムアウトが起きていることを確認する ... `docker compose logs app | grep killing`

### タイムアウトを設定しなかった場合

Unicornのタイムアウトは、デフォルトだと30秒か60秒あたりなので、それを超えるともちろんKillされますが、
超えない場合はKillされずにリクエストの処理が続行されます。

1. Unicornのタイムアウト設定をコメントアウトする ... `vim app/unicorn.conf`
1. コンテナの起動 ... `docker compose restart`
1. リクエストがタイムアウトすることを確認する ... <http://127.0.0.1:8080>
1. Unicorn側のタイムアウトが起きていることを確認する ... `docker compose logs app | grep killing`

以下の図のように時間のかかる処理が複数ある場合、ALBやNginxがタイムアウトしても処理が続行されます。  

```mermaid
gantt

dateFormat HH:mm:ss
axisFormat %H:%M:%S

section Request α
ALB : a1, 11:00:00, 60sec
Nginx : a2, 11:00:01, 60sec
Unicorn : a3, active, 11:00:02, 50sec

section Request β
ALB : b1, 11:00:30, 60sec
Nginx : b2, 11:00:31, 60sec
Unicorn : b3, after a3, 50sec
```

1プロセスで処理している前提になりますが、リクエストαは、ALBとNginxのタイムアウト内でリクエストを返せていますが、リクエストβはαの処理が終わるまで処理されないため、ユーザには504が返ってしまいます。  
実際には、1プロセスで処理することはないですが、複数プロセスでも基本的な考え方としては一緒です。
