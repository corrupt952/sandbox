FROM golang:alpine
WORKDIR /go/src/app
COPY main.go /go/src/app/main.go
RUN mkdir -p /var/run/glaaki \
    && apk add --no-cache git \
    && go get -d -v ./...
CMD ["go", "run", "main.go"]
