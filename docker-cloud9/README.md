# docker-cloud9

Runs the legacy Cloud9 IDE ([c9/core](https://github.com/c9/core)) built from source
in a CentOS 7 container, with a Node.js toolchain provisioned via nvm and Ruby via rbenv.

## How to run

```sh
docker build -t cloud9 .
docker run --rm -p 8181:8181 cloud9
```

Then open <http://localhost:8181>. The workspace directory is `~/workspace`.

## Notes

This is a historical experiment and almost certainly no longer builds:

- CentOS 7 is EOL and its yum mirrors are gone.
- `nvm_install.sh` clones nvm over the `git://` protocol, which GitHub no longer supports,
  and contains an interactive prompt that stalls a non-interactive `docker build`.
- `rbenv_install.sh` fetches rbenv/ruby-build from the archived `sstephenson` repositories.
- Node.js 0.10 and Cloud9 core itself are long abandoned.
