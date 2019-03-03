# docker-composeの各サービス間でのUnix Domain Socket通信の確認

## 環境
* docker ... 18.09.0
* docker-compose ...  1.23.2

## 概要
NginxからEchoサーバーへの通信をUnix Domain Socketで行えるかの動作検証

## 手順
1. `docker-compose up -d`
2. access localhost:8000 in web browser
