# ruby-yamaha-config-dump

Fetches the running configuration from a Yamaha RTX router by driving Telnet
over an SSH session (`net-ssh` + `net-ssh-telnet`). The script switches the
console to ASCII output and unlimited lines, then prints the result of
`show config`. The original idea was to capture snapshots that could be
diffed over time; only the dump half was implemented.

## How to run

```sh
gem install net-ssh net-ssh-telnet   # no Gemfile

export RTX_HOSTNAME=192.168.100.1
export RTX_USERNAME=...
export RTX_PASSWORD=...
ruby main.rb
```

## Notes

- No Gemfile or `.ruby-version`; dependencies must be installed manually.
