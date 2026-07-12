# docker-orion

Runs the Eclipse Orion 8.0 browser-based IDE in a CentOS 7 container with OpenJDK 8.

## How to run

```sh
docker build -t orion .
docker run --rm -p 8080:8080 orion
```

Then open <http://localhost:8080>.

## Notes

This is a historical experiment and almost certainly no longer builds:

- CentOS 7 is EOL and its yum mirrors are gone.
- The Orion 8.0 (2015) download URL on the JAIST mirror is very likely dead.
