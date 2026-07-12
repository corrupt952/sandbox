# ruby-yamaha-diff

Fetches the running configuration from a Yamaha RTX router by driving Telnet
over an SSH session (`net-ssh` + `net-ssh-telnet`). The script switches the
console to ASCII output and unlimited lines, then prints the result of
`show config` — the idea being to capture snapshots that can be diffed over
time (the diff half was never implemented, hence only a dump).

## How to run

```sh
gem install net-ssh net-ssh-telnet   # no Gemfile

export RTX_HOSTNAME=192.168.100.1
export RTX_USERNAME=...
export RTX_PASSWORD=...
ruby main.rb
```

## Notes

- Despite the name, there is no diff logic — the script only dumps the config.
- No Gemfile or `.ruby-version`; dependencies must be installed manually.
