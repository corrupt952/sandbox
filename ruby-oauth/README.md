# ruby-oauth

Minimal Sinatra app implementing the Notion OAuth2 authorization-code flow.

## Endpoints

- `GET /login` — links to Notion's `/v1/oauth/authorize`
  (redirect URI: `http://localhost:3000/callback`)
- `GET /callback` — exchanges the authorization code for an access token at
  `/v1/oauth/token` using HTTP Basic auth (`CLIENT_ID:CLIENT_SECRET`), and stores
  the token and owner ID in the session
- `GET /` — with a token, calls Notion `/v1/users/{id}` and greets the user by
  name; otherwise redirects to `/login`
- `GET /logout` — clears the session

## Setup

Requires a Notion integration (public OAuth) and its credentials:

```sh
export NOTION_CLIENT_ID=...
export NOTION_CLIENT_SECRET=...
bundle install
bundle exec ruby app.rb   # http://localhost:3000
```

A `compose.yaml` (ruby:3 + Redis + RedisInsight) is also included.

## Notes

- `compose.yaml` runs `ruby main.rb`, but the file is `app.rb` — the app was
  renamed without updating compose, so the compose route fails as-is.
- Redis, `connection_pool`, the ridgepole `Schemafile`, and the `users` table
  are scaffolding for a session store that was never wired up; sessions are
  plain cookie sessions.
