# docker-run-and-exec-redirect-file

Executes a local script inside a container by feeding it over stdin to
`docker run` / `docker exec` (`-i` + input redirection), without copying
the file into the image or mounting it.

```sh
# run: bash script
docker run --rm -i ubuntu:latest bash -s <./main.sh

# run: Ruby script (ruby reads the program from stdin)
docker run --rm -i ruby:3 ruby <./main.rb

# exec: bash script (assumes a running container named "ubuntu")
docker exec -i ubuntu bash -s <./main.sh
```

## Notes

- The original memo piped `main.rb` into `bash -s`, which would fail —
  a Ruby script has to be fed to `ruby`, as above.
