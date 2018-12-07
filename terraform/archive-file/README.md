# data.archive_fileの検証コード

## 環境
* Terraform ... v0.11.7 or later

## やりたいこと
以下の条件でzipファイルを作成できるか確認する.

* 単一ファイルのzip化
* 単一ファイルが存在するディレクトリをzip化
* 複数ファイルが存在するディレクトリをzip化
* 単一のsourceブロックを指定してzip化
* 複数のsourceブロックを指定してzip化
