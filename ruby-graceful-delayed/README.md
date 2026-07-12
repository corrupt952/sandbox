# ruby-graceful-delayed

Experiments with graceful shutdown of [Delayed Job](https://github.com/collectiveidea/delayed_job)
workers while a long-running job is in flight.

## How it works

- `app/jobs/sleep_job.rb` — a deliberately slow job (`Kernel.sleep wait_time`)
  that logs `start job` / `end job`, so you can observe whether it survives a
  worker shutdown signal.
- `config/initializers/delayed_job_config.rb` — Delayed Job configuration with
  a dedicated `log/delayed_job.log`. The crux of the experiment is the
  commented-out line:

  ```ruby
  # Delayed::Worker.raise_signal_exceptions = :term
  ```

  Toggling it changes whether a `TERM` signal interrupts the running job
  immediately or lets it finish (graceful).

## Setup

Ruby 2.6.0 / Rails 5.2 / MySQL. A `Dockerfile` and `docker-compose.yml`
(app + MySQL 5.7) are included:

```sh
docker-compose up -d
docker-compose exec app bash
# inside the container:
bundle install
bin/rails db:setup
bin/delayed_job start        # or: bin/rails jobs:work
bin/rails runner 'SleepJob.perform_later(60)'
# then send TERM to the worker and watch log/delayed_job.log
```

## Notes

- Ruby 2.6 / Rails 5.2 are EOL. The Dockerfile does not copy the Gemfile at
  build time; gems are installed against the runtime volume mount.
