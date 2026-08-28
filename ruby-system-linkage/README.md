# ruby-system-linkage

Demonstrates synchronizing data between two Rails apps ("system linkage") through
a shared Rails engine, an internal JSON API, and a periodic Sidekiq worker.

## Components

- `simple_posts/` — a mountable Rails engine holding the shared domain:
  `Category` / `Post` models (CarrierWave thumbnail uploads), an internal JSON
  API (`/api/categories`, `/api/posts`), and Roar representers used for JSON
  (de)serialization on both sides.
- `app1/` — the admin/authoring app (source of truth). Full CRUD for posts,
  categories, and images (S3 via CarrierWave + fog-aws), and serves the shared
  `/api` endpoints from the engine.
- `app2/` — the public blog (read-only, ransack filtering + kaminari
  pagination). `app/workers/synchronizing_worker.rb` runs every minute via
  sidekiq-cron, pulls `/categories` and `/posts` from app1's API with
  rest-client, and mirrors them into app2's local database through the engine's
  representers.

## Requirements

- redis (for Sidekiq in app2)
- ImageMagick (rmagick)
- S3 access key and secret
- Summernote 0.6.4 in `app1`, fetched by `./fetch-summernote.sh` (see Licensing)

## Setup

For each app: copy `config/environment.yml.examle` to `config/environment.yml`
(sic — the template filename is misspelled) and fill in the AWS credentials and
`api.app1_url_base` (default `http://localhost:3001/api`), then `bin/setup`.
Run app1 on port 3001, app2 on another port, plus `bundle exec sidekiq` for
app2. Sidekiq's dashboard is mounted at `/sidekiq`.

## Licensing

Every JavaScript and CSS dependency here comes from somewhere else and none of
them are redistributed from this repository. Bootstrap, jQuery, and Font Awesome
arrive through the `Gemfile`. [Summernote](https://github.com/summernote/summernote)
(MIT) is the one that cannot, because 0.6.4 predates its npm packages and the
asset pipeline expects the files on disk — `fetch-summernote.sh` pulls them from
the upstream `v0.6.4` tag into `app1/vendor/assets/`, where git ignores them.
`app/assets/javascripts/summernote.coffee` is this app's own configuration of the
editor, not part of Summernote.

## Notes

- Rails 4.2.1 with `therubyracer`, `rmagick`, and `fog` — painful to install on
  modern systems; treat this as an architecture reference.
- The asset manifests reference Summernote by name, so `bin/setup` fails until
  `fetch-summernote.sh` has run.
- Latent typo: app1's routes use `expect:` instead of `except:`, so the option
  is silently ignored and `show` routes are generated anyway.
