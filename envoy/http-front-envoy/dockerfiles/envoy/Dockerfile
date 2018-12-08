FROM envoyproxy/envoy-alpine:01d726a41bdd790c16765e1d321cb50590574eb0

COPY dockerfiles/envoy/front-envoy.yaml /etc/front-envoy.yaml
CMD ["/usr/local/bin/envoy", "-c", "/etc/front-envoy.yaml", "--service-cluster", "front-proxy"]
