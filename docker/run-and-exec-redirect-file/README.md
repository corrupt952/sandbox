# docker runやexecに標準入力でファイルの内容を渡してスクリプトを実行する

```sh
# run: bash script
docker run --rm -i ubuntu:latest bash -s <./main.sh

# run: Ruby script
docker run --rm -i ruby:3 bash -s <./main.rb

# exec: bash script
docker exec -i ubuntu bash -s <./main.sh
```
