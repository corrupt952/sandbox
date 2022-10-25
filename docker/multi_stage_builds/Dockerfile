# 全ての環境で共通
FROM alpine:3.16 as base
RUN apk add --update --no-cache redis
RUN sed -i 's/bind 127.0.0.1 -::1/bind 0.0.0.0 ::/g' /etc/redis.conf
CMD ["redis-server"]

# ローカル
FROM base as dev
RUN apk add --update --no-cache bash vim
RUN sed -i 's/loglevel notice/loglevel debug/g' /etc/redis.conf

# ステージング
FROM base as staging

# 本番
FROM base as production
RUN sed -i 's/loglevel notice/loglevel debug/g' /etc/redis.conf
