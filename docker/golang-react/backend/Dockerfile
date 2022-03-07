FROM golang:1.17-bullseye

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

ENV APP_PATH /go/src/app
WORKDIR $APP_PATH

RUN go install github.com/cosmtrek/air@latest
CMD ["air"]
