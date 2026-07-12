FROM golang:1.17-bullseye as backend
WORKDIR /go/src/app
# 今回は外部ライブラリを使用していないため、go.sumが存在しないが、存在する場合は以下のようにしておく
# COPY backend/go.mod backend/go.sum ./
COPY backend/go.mod ./
RUN go mod tidy
COPY backend .
ARG CGO_ENABLED=0
ARG GOOS=linux
ARG GOARCH=amd64
RUN go build \
    -o /go/bin/main \
    -ldflags '-s -w'

FROM node:16-bullseye as frontend
WORKDIR /app
COPY frontend/package.json frontend/yarn.lock ./
RUN yarn install --frozen-lockfile --ignore-optional
COPY frontend .
RUN yarn build

FROM scratch
WORKDIR /app
COPY --from=backend /go/bin/main ./main
COPY --from=frontend /app/dist ./public
CMD ["./main"]
