# Front ProxyとしてEnvoyとNginxの速度検証

## 環境
* docker ... 18.09.0
* docker-compose ...  1.23.2

## 概要
以下2つのパターンそれぞれの速度結果を取得する.

* `Client` - HTTP1.1 -> `Envoy` - HTTP1.1 -> `NGINX(HTTP1.1サーバ)` 
* `Client` - HTTP1.1 -> `Nginx` - HTTP1.1 -> `NGINX(HTTP1.1サーバ)` 

## 手順
1. `docker-compose up -d`
2. `wrk -t 10 -c 10 http://localhost:8000`
3. `wrk -t 10 -c 10 http://localhost:8001`

## メモ
* 基本的には[envoyproxy/envoy/examples/front-proxy](https://github.com/envoyproxy/envoy/tree/master/examples/front-proxy)を参考にしている
* Backendとの通信にHTTP1.1使う場合は、`http2_protocol_options`ではなく`http_protocol_options`を使う
