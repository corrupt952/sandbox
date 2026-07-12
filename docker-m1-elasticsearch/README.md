# docker-m1-elasticsearch

Runs Elasticsearch OSS 6.8.23 and Kibana OSS 6.8.23 on Apple Silicon (M1) Macs
by forcing `platform: linux/amd64` (Rosetta/QEMU emulation), since these old
images have no arm64 builds. The Elasticsearch image is extended with the
`analysis-kuromoji` and `analysis-icu` plugins for Japanese text analysis.

## How to run

```sh
docker compose up
```

- Elasticsearch: <http://localhost:9200>
- Kibana: <http://localhost:5601>

Data persists in the `es-data` named volume. JVM heap is lowered to 256 MB via
`elastic-jvm.options`, which is mounted over the container's `config/jvm.options`.

## Notes

- Runs under amd64 emulation, so performance is poor by design.
- `bootstrap.memory_lock=true` is set but the matching `ulimits.memlock` block in
  `compose.yaml` is commented out, so memory locking may fail with a warning.
- Elasticsearch/Kibana 6.8 are long EOL; this exists to reproduce a legacy setup.
