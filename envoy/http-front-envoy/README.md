# front-envoyの検証

## 環境
* docker ... 18.09.0
* docker-compose ...  1.23.2

## 概要
`Client` - HTTP1.1 -> `Envoy` - HTTP1.1 -> `NGINX(HTTP1.1サーバ)` といった構成で使えるかの確認.

## 手順
1. `docker-compose up -d`
2. access localhost:8000 in web browser

## メモ
* 基本的には[envoyproxy/envoy/examples/front-proxy](https://github.com/envoyproxy/envoy/tree/master/examples/front-proxy)を参考にしている
* Backendとの通信にHTTP1.1使う場合は、`http2_protocol_options`ではなく`http_protocol_options`を使う
