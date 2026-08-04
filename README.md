# Alcali formula

This formula installs Alcali as a native systemd service. It creates an
isolated Python environment, writes Alcali's environment file, applies Django
migrations, collects static assets, and runs Gunicorn as an unprivileged
account.

## Important project status

The formula targets the modernized `3006.4.0.dev0` application: Python 3.12,
Django 5.2, Vue 3 and Vuetify 3. Until that commit is published, the default
repository and revision deliberately remain on the original `v3006.3.0`
source. Replace both values together when the fork has a permanent home; the
current modernized candidate is `8f07bb66dff6428f833c838ab6f053e71ea16429`.

Keep Alcali on a trusted management network, bind Gunicorn to loopback, and
publish it only through an authenticated TLS reverse proxy.

Supported hosts are deliberately limited to:

- Debian 13
- Ubuntu 24.04

The selected `deploy:python` must be Python 3.12 or newer. Other distributions
can be added after provisioning and validating a suitable Python runtime.

## Why the previous formula commonly failed

The previous states had several independent failure paths:

- The example selected Alcali `v3003.1.0`, while modern Salt masters run the
  3006 line.
- Salt 3006 disables all salt-api client interfaces unless
  `netapi_enable_clients` is explicitly configured.
- It installed upstream requirements but did not make the full installation
  and migration lifecycle deterministic.
- Database migrations ran only when Git or `.env` changed. A failed initial
  migration would not necessarily be retried later.
- LDAP packages were stored under `ldap_pkgs` but read through the misspelled
  key `ldap_pks`.
- The LDAP pip state attempted to install a package literally named after its
  Salt state ID.
- The systemd template contained non-breaking spaces in command arguments.
- The deployment user could be created before its primary group.
- The cleanup states contained malformed `-name` YAML keys.
- The legacy source hardcodes Salt API certificate verification off. The
  formula patches only that exact revision; the modernized client verifies TLS
  itself.
- The formula did not explain that Alcali requires both a Salt job/event
  returner database and a working salt-api/eAuth configuration.

## Architecture and prerequisites

Alcali is not a self-contained Salt dashboard. A working deployment has three
connected components:

1. A MySQL/MariaDB or PostgreSQL database containing Salt's official returner
   tables (`jids`, `salt_returns`, and `salt_events`) plus Alcali's Django
   tables.
2. A Salt master configured to store its master job cache and events in that
   database.
3. salt-api configured with external authentication and the client interfaces
   Alcali is allowed to use.

The same database credentials are normally used by Alcali and the Salt master.
The formula can optionally manage the Salt master and salt-api configuration,
but database creation and initial loading of Salt's returner schema remain
explicit administrator operations.

Before applying the formula, verify:

- The host is also a Salt minion and can apply this formula.
- The database is reachable from both Alcali and the Salt master.
- The database/user and Salt returner tables already exist.
- The Salt API TLS certificate and private key already exist.
- The hostname in `alcali:salt_api:url` matches the API certificate, or the
  private CA is supplied through `alcali:salt_api:ca_bundle`.
- A reverse proxy is ready to publish `127.0.0.1:5000` over HTTPS.

Salt's official MySQL schema and current connection settings are documented in
the Salt 3006 MySQL returner reference. For PostgreSQL, use the corresponding
Salt PostgreSQL returner schema.

## Formula layout

| State | Purpose |
|---|---|
| `alcali` | Complete application and optional Salt-master integration |
| `alcali.user` | System account and `/opt/alcali` directory |
| `alcali.install` | Packages, pinned source, venv, dependencies, and legacy-only TLS patch |
| `alcali.config` | Validates secrets and writes `/opt/alcali/.env` |
| `alcali.migrate` | Applies pending migrations and collects static assets |
| `alcali.service` | Hardened systemd unit and running Gunicorn service |
| `alcali.master` | Optional Salt returner, salt-api, and eAuth configuration |
| `alcali.clean` | Removes Alcali while preserving packages and databases |

Defaults live in `defaults.yml`; pillar is merged through `map.jinja`. See
`pillar.example` for every supported setting.

## Database preparation

### MySQL or MariaDB

Create a dedicated database and user. Then load the exact schema shown by the
Salt 3006 `salt.returners.mysql` documentation. Do not use Alcali's old Docker
SQL file against an existing database because that file starts by dropping the
database.

Example account creation, adjusted for your own host restrictions:

```sql
CREATE DATABASE salt DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER 'alcali'@'127.0.0.1' IDENTIFIED BY 'replace-this-password';
GRANT ALL PRIVILEGES ON salt.* TO 'alcali'@'127.0.0.1';
FLUSH PRIVILEGES;
```

Load the `jids`, `salt_returns`, and `salt_events` definitions from Salt's
official MySQL returner documentation before the first state run. Alcali's
Django tables are added by `alcali.migrate`.

The Salt master requires `MySQLdb`. When
`alcali:salt_master:install_connector` is true, `alcali.master` installs
`mysqlclient` into the onedir Salt runtime using
`/opt/saltstack/salt/bin/pip3`.

### PostgreSQL

Set both of these values:

```yaml
alcali:
  database:
    backend: postgresql
    port: 5432
  salt_master:
    returner: postgres
```

Create the role/database, load Salt's PostgreSQL returner schema, and ensure
the role owns or can alter the schema so Django migrations can create Alcali's
tables. With connector management enabled, the formula installs `psycopg2`
into Salt's onedir environment.

## Pillar setup

Copy `pillar.example` into your pillar tree and at minimum change:

```yaml
alcali:
  database:
    password: a-long-random-database-password
    host: 127.0.0.1
  django:
    secret_key: a-different-long-random-django-secret
    allowed_hosts:
      - alcali.example.com
  salt_api:
    url: https://salt-master.example.com:8080
    master_minion_id: salt-master.example.com
```

Generate a Django key with a local secret generator, for example:

```bash
openssl rand -base64 48
```

The state intentionally fails before starting Alcali if either secret still
contains `CHANGE_ME` or is empty.

## Salt master and salt-api

There are two supported approaches.

### Let another formula manage the Salt master

Leave this setting disabled:

```yaml
alcali:
  salt_master:
    manage: false
```

Your Salt-master formula must provide the equivalent of:

```yaml
master_job_cache: mysql
event_return:
  - mysql
keep_jobs_seconds: 604800

mysql.host: '127.0.0.1'
mysql.user: 'alcali'
mysql.pass: 'replace-this-password'
mysql.db: 'salt'
mysql.port: 3306

rest_cherrypy:
  host: '127.0.0.1'
  port: 8080
  debug: false
  ssl_crt: '/etc/salt/pki/api.crt'
  ssl_key: '/etc/salt/pki/api.key'

netapi_enable_clients:
  - local
  - local_async
  - runner
  - runner_async
  - wheel
  - wheel_async

keep_acl_in_token: true
external_auth:
  rest:
    ^url: 'http://127.0.0.1:5000/api/token/verify/'
    admin:
      - '.*'
      - '@runner'
      - '@wheel'
      - '@jobs'
```

Install the matching database driver inside Salt's onedir Python runtime,
restart `salt-master`, and restart/start `salt-api`.

### Let this formula manage the integration

After reviewing the generated settings and creating the API certificate, set:

```yaml
alcali:
  salt_master:
    manage: true
```

This writes `/etc/salt/master.d/alcali.conf`, installs the database connector
into Salt's onedir runtime, and restarts both `salt-master` and `salt-api` when
the file changes. The generated file is mode `0600` because it contains the
database password.

The `rest_auth:users` ACL is security-sensitive. `'.*'`, `@runner`, and
`@wheel` effectively grant broad infrastructure administration. Replace the
example ACL with the narrowest permissions each account needs.

From Salt 3006 onward, omitting `netapi_enable_clients` disables salt-api
operations even when login succeeds. Do not remove the setting; reduce the
list if Alcali functionality permits it.

## Apply and verify

Preview first:

```bash
salt-call state.apply alcali test=True
```

Apply:

```bash
salt-call state.apply alcali
```

Verify the application locally:

```bash
systemctl status alcali --no-pager
curl --fail --silent --show-error http://127.0.0.1:5000/ >/dev/null
sudo -u alcali env ENV_PATH=/opt/alcali \
  /opt/alcali/venv/bin/python /opt/alcali/code/manage.py check
```

Verify Alcali's built-in environment/database check:

```bash
sudo -u alcali env ENV_PATH=/opt/alcali \
  /opt/alcali/venv/bin/python /opt/alcali/code/manage.py alcali_check
```

Verify salt-api independently before troubleshooting Alcali:

```bash
curl --cacert /path/to/your/ca.pem \
  https://salt-master.example.com:8080/
```

An HTTP response from CherryPy confirms connectivity; authentication is tested
after the first Alcali user/token exists.

## Create the first administrator

The formula does not put an interactive password in pillar or command output.
Create the first user after migrations complete:

```bash
sudo -u alcali env ENV_PATH=/opt/alcali \
  /opt/alcali/venv/bin/python /opt/alcali/code/manage.py createsuperuser
```

Log in through the reverse-proxy URL. Alcali generates/manages the user token
used with the Salt `rest` eAuth backend.

## Reverse proxy

Gunicorn defaults to `127.0.0.1:5000`. Terminate TLS in Apache, Nginx, HAProxy,
or another managed proxy. The proxy must support normal HTTP forwarding and
long-lived/event-stream responses. Preserve `Host`, `X-Forwarded-For`, and
`X-Forwarded-Proto` headers, and set appropriate upload/header/time limits.

Do not change `gunicorn:bind` to `0.0.0.0` merely to make the site reachable.
Use a firewall-restricted reverse proxy and include its public hostname in
`django:allowed_hosts`.

## LDAP and Google authentication

For LDAP:

```yaml
alcali:
  features:
    ldap: true
  django:
    auth_backend: ldap
  environment:
    AUTH_LDAP_SERVER_URI: ldaps://ldap.example.com
    AUTH_LDAP_BIND_DN: cn=alcali,ou=services,dc=example,dc=com
    AUTH_LDAP_BIND_PASSWORD: replace-me
    AUTH_LDAP_USER_BASE_CN: ou=people,dc=example,dc=com
    AUTH_LDAP_USER_SEARCH_FILTER: '(uid=%(user)s)'
```

The formula installs the required Debian LDAP development libraries and
upstream LDAP Python requirements.

For Google OAuth, enable `features:social`, set `django:auth_backend` to
`social`, and provide the `SOCIAL_AUTH_*` variables shown in
`pillar.example`.

## TLS verification

The modernized client verifies the Salt API certificate by default. For an
internal CA, configure its PEM bundle directly:

```yaml
alcali:
  salt_api:
    ca_bundle: /etc/ssl/certs/internal-ca.pem
```

Ensure that file exists and is readable by the `alcali` group. Setting
`salt_api:verify_tls: false` is available for short diagnostic tests only; it
must not be a permanent production setting.

## Troubleshooting

### Alcali service will not start

```bash
journalctl -u alcali -n 100 --no-pager
sudo -u alcali env ENV_PATH=/opt/alcali \
  /opt/alcali/venv/bin/gunicorn --chdir /opt/alcali/code \
  config.wsgi:application --bind 127.0.0.1:5001 --workers 1
```

Typical causes are an unreachable database, an invalid `.env` value, pending
migrations, or an unreadable CA bundle.

### Database connection refused

Test from the Alcali host using exactly the pillar host and port. A local MySQL
Unix socket is not used by Django when `DB_HOST` is an IP address. If MySQL is
bound only to the host address, use that address instead of `localhost` and
grant the Alcali user from the corresponding source host.

### Login works but jobs, keys, or execution fail

Check, in order:

1. `netapi_enable_clients` exists in the effective master configuration.
2. `salt-api` was restarted after the configuration change.
3. The user's `external_auth:rest` ACL includes the requested client/function.
4. `SALT_URL` is reachable from the Alcali service account.
5. The API certificate validates with `SALT_CA_BUNDLE`.
6. The database contains current `jids`, `salt_returns`, and `salt_events`.

Inspect the effective master configuration without printing secrets into a
ticket or shared log.

### The dashboard is empty

Alcali cannot reconstruct historical jobs that were never sent to the SQL
returner. After enabling `master_job_cache` and `event_return`, run a harmless
job such as `test.ping`, then confirm rows appear in `jids`, `salt_returns`,
and `salt_events`.

### Git reports a modified source tree

Only the legacy revision receives the TLS compatibility patch, so a modified
source tree is expected while that revision remains selected. The patch is
automatically omitted once `deploy:revision` points at the modernized commit.
Use `deploy:force_reset: true` once for a controlled transition from a patched
legacy checkout, then return it to `false`.

## Removal

```bash
salt-call state.apply alcali.clean test=True
salt-call state.apply alcali.clean
```

The clean state stops Alcali and removes its systemd unit, service account,
source, virtual environment, and `.env`. It deliberately preserves:

- the database and all job history;
- system packages shared with other software;
- Salt onedir connector packages;
- `/etc/salt/master.d/alcali.conf` by default.

Set `alcali:salt_master:remove_on_clean: true` only if the Salt-master config
should also be removed. Restart the Salt master and salt-api after removing
that file.

## Relationship to upstream

**This is a heavily modified fork of
[`saltstack-formulas/alcali-formula`](https://github.com/saltstack-formulas/alcali-formula). Do not treat it as a drop-in
replacement for it.**

States have been renamed, split, merged, and removed; pillar keys have moved;
defaults differ; and behaviour has changed in ways that are not backward
compatible. Pointing an existing deployment at this formula without reading
`pillar.example` and the state list above will not do what you expect.

It is also not a newer version of upstream — it diverged and was maintained
separately, so upstream may well have fixes and platform support that this
does not. If you want the maintained original, use
[`saltstack-formulas/alcali-formula`](https://github.com/saltstack-formulas/alcali-formula).

### Credit

The foundation of this formula, and much of what still works well in it, is
the work of the [saltstack-formulas](https://github.com/saltstack-formulas) authors and contributors. Any
bugs introduced in the divergence are this fork's own.

## License

Dedicated to the public domain under [CC0 1.0 Universal](LICENSE).
