# TOPKan

A small Sinatra people directory with a sign-in page and add, edit, delete, and search forms. The fifth database field is the record ID. Passwords are stored as bcrypt hashes in the `password` column; the plaintext password is never saved. On a new, empty database, the home page offers a one-time first account setup. After that, use the account email and password to sign in.

## Run locally

Requires Ruby 3.1 or newer and Bundler.

```sh
bundle install
bundle exec ruby app.rb
```

Open <http://localhost:4567>. Create the first account when prompted. Local records are stored in `db/topkan.sqlite3`.

## Deploy to Render

Push this project to a Git repository, connect that repository to Render, and create a Blueprint from `render.yaml`. The Blueprint configures a Sinatra web service and a PostgreSQL database. Render supplies `DATABASE_URL` and a generated `SESSION_SECRET`.

## Data fields

| Field | Purpose |
| --- | --- |
| `id` | Unique record ID |
| `first_name` | First name |
| `last_name` | Last name |
| `email` | Unique email address |
| `password` | Bcrypt password hash |
