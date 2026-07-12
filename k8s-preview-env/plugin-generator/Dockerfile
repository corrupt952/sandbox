FROM golang:1.23 AS build
WORKDIR /app
COPY main.go .
RUN go mod init plugin-generator && \
    CGO_ENABLED=0 go build -o plugin-generator .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /app/plugin-generator /plugin-generator
USER nonroot:nonroot
ENTRYPOINT ["/plugin-generator"]
