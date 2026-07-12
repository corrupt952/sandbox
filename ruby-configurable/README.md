# ruby-configurable

Demonstrates layered, per-environment application settings in Rails using the
[dry-configurable](https://dry-rb.org/gems/dry-configurable/) gem. The Rails app
itself is generated boilerplate; the experiment lives entirely in `config/settings/`.

## How it works

- `config/settings/default.rb` — defines a `Settings` class extending
  `Dry::Configurable` with a nested tree (`settings.services.redis.host` / `port`).
- `config/settings/development.rb` / `production.rb` — per-environment overrides
  (production points the Redis host at `example.com`).
- `config/initializers/0_settings.rb` — loads `default.rb`, then
  `config/settings/#{Rails.env}.rb`, so environment values override defaults.

Usage anywhere in the app:

```ruby
Settings.config.services.redis.host
```

## Setup

Standard Rails 5.1: `bin/setup`, then `bin/rails console` to poke at `Settings`.
No Docker setup.

## Notes

- Rails 5.1 with `therubyracer`, which is difficult to build on modern systems;
  treat this as a pattern reference rather than something to boot.
