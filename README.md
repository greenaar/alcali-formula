# Alcali formula

This formula installs Alcali as a native systemd service. It creates an
isolated Python environment, writes Alcali's environment file, applies Django
migrations, collects static assets, and runs Gunicorn as an unprivileged
account.

## Important project status

The formula deploys the modernized `3008.2.0` application: Python 3.12,
Django 5.2, Vue 3 and Vuetify 3. It is pinned to the fork hosted on the
internal Forgejo instance:

```yaml
alcali:
  deploy:
    repository: ssh://git@forge.thatserver.ca:8222/salt/alcali-modernized.git
    revision: 14fe53a19aacff688fdc98cffc43b665bb813baf    # tag v3008.2.0
```

There are two installation methods, selected with `alcali:deploy:method`:

| | `package` (default) | `source` |
|---|---|---|
| Installs | the released wheel from the Forgejo PyPI registry | a Git checkout plus `requirements/` |
| Deploys | exactly the artifact CI built and released | whatever the pinned revision contains |
| Needs on the minion | a registry token | `git`, an SSH deploy key, and the forge host key |
| Supports the legacy upstream revision | no | yes |

Prefer `package`. The wheel is the artifact the release pipeline tested, it
carries the prebuilt frontend, and no source tree or build patch is left on the
minion. Use `source` to run an unreleased commit, or to fall back to the
original upstream release.

Move `deploy:revision` forward deliberately, one reviewed commit at a time. The
original upstream release remains available as a rollback target by setting
`deploy:repository` back to `https://github.com/latenighttales/alcali.git` and
`deploy:revision` to the value in `alcali:legacy:revision`; the formula then
re-enables the compatibility patch and Django pin that release needs.

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
| `alcali.install` | Packages, registry or Git source, venv, dependencies, and legacy-only TLS patch |
| `alcali.config` | Validates secrets and writes `/opt/alcali/.env` |
| `alcali.migrate` | Applies pending migrations and collects static assets |
| `alcali.service` | Hardened systemd unit and running Gunicorn service |
| `alcali.docker` | Compose deployment of the published container image (`method: docker`) |
| `alcali.master` | Optional Salt returner, salt-api, and eAuth configuration |
| `alcali.clean` | Removes Alcali while preserving packages and databases |

`init.sls` includes only the states the selected `deploy:method` needs.
`alcali.master` is always included, because the master-side wiring is required
however Alcali itself is deployed.

Defaults live in `defaults.yml`; pillar is merged through `map.jinja`. See
`pillar.example.sls` for every supported setting.

## Deployment methods

`alcali:deploy:method` selects what the formula deploys. All four produce the
same Salt-side result; they differ only in where Alcali itself runs.

| Method | What is deployed here | Use when |
|---|---|---|
| `package` | Wheel from the Forgejo PyPI registry into a venv, under systemd | Default. The deployed artifact is exactly what CI released. |
| `source` | Git checkout plus requirements, under systemd | The pinned revision predates the wheel, or you are testing a branch. |
| `docker` | Published container image under Compose and systemd | You would rather not install Python and its build dependencies on the host. |
| `external` | Nothing | Alcali runs on another host, in Kubernetes, or is otherwise not this formula's to manage. |

`docker` and `external` still need `alcali:database` and `alcali:salt_api` to
be correct — the master's returner and salt-api configuration is rendered from
them, and that is the whole of what `external` does.

### method: docker

Runs the published image on this host, driven by a systemd unit wrapping
`docker compose up -d`. `docker.io` and `docker-compose-v2` come from the
distribution, so no third-party repository is added. There is no salt-master
and no salt-minion in the Compose project: it is the application only.

```yaml
alcali:
  deploy:
    method: docker
  docker:
    image: forge.thatserver.ca/salt/alcali:3008.2.0
    registry_username: alcali-deploy
    registry_password: REPLACE_WITH_A_READ_ONLY_REGISTRY_TOKEN
    publish_address: 127.0.0.1
    publish_port: 8000
  database:
    host: db.example.com          # reached from inside the container
  salt_api:
    url: https://master.example.com:8080
```

Three things behave differently from the systemd methods, and each one is a
failure that is otherwise hard to diagnose:

- **`alcali:database:host` is resolved inside the container.** A loopback
  address there is the container, not the host, so the formula rewrites a
  loopback `database:host` to `host.docker.internal` and adds the matching
  `host-gateway` mapping. Set it to a real hostname when the database is
  elsewhere.
- **`alcali:salt_api:url` is *not* rewritten**, and the formula refuses to
  apply if it names a loopback address while `verify_tls` is on. Substituting
  a gateway alias would break certificate verification, and the usual next
  step is to turn verification off on the connection carrying users'
  credentials. Use the hostname the salt-api certificate is issued for.
- **The `^url` callback is derived from `docker:publish_address` and
  `docker:publish_port`**, not from `gunicorn:`. If the master is on a
  different host, set `alcali:salt_master:rest_auth:verify_url` explicitly to
  an address the master can reach.

Registry credentials are written to `/root/.docker/config.json` rather than
passed to `docker login`, which would put the token into the state output and
from there into the master job cache — the same database Alcali reads.

The container image is pinned; the Compose file is written in terms the image
has always provided (`manage.py` and a shell) rather than helper scripts, so
it keeps working against whichever tag you pin.

#### Bundled database

`alcali:docker:bundled_database: true` adds MariaDB to the Compose project and
loads Salt's returner schema into it on first start. Off by default: a master
that is already returning to a database should keep doing so, and Alcali
should read that one.

When it is on, `alcali:database:host` and `:port` are where the container
publishes the database — which must be an address on this host — and the same
values are rendered into the master's returner configuration, so the two
cannot disagree. `alcali:docker:database_root_password` is then required.

The volume holding it (`alcali_db-data`) is the master's job cache. Neither
`alcali.clean` nor the unit's `ExecStop` removes it; delete it deliberately
with `docker volume rm` once you are certain.

### method: external

Deploys nothing. Applies only `alcali.master`: the returner configuration, the
database connector in the master's Python, salt-api, and the `external_auth`
block. Use it when Alcali runs somewhere this formula does not reach.

```yaml
alcali:
  deploy:
    method: external
  database:
    host: db.example.com
    user: alcali
    password: REPLACE_WITH_A_LONG_RANDOM_PASSWORD
  salt_master:
    manage: true
    rest_auth:
      # Required: nothing local to derive it from. The *master* resolves this.
      verify_url: https://alcali.example.com/api/token/verify/
```

`verify_url` has no default here and the formula refuses to render the master
configuration without it. An `external_auth` block with the wrong callback
rejects every login, and it does so inside the master, so nothing appears in
Alcali's log.

Because Alcali is not deployed here, `alcali:django:secret_key` is unused and
`alcali:database:password` is only used to render the master's returner
configuration — it must match what the external Alcali uses.

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

## Registry access (method: package)

The wheel lives in a private registry, so the minion authenticates before pip
can reach it:

1. Create a Forgejo access token with the `read:package` scope. A token that
   can only read packages is enough; do not reuse the release pipeline's
   `write:package` token.
2. Put it in pillar:

   ```yaml
   alcali:
     deploy:
       method: package
       package:
         registry_url: https://forge.thatserver.ca/api/packages/salt/pypi
         username: alcali-deploy
         password: a-read-only-registry-token
   ```

The formula writes those credentials to `/opt/alcali/.netrc` (mode `0600`,
owned by the deploy user), where pip finds them. They never appear in a command
line, in `ps` output, or in state return data. Set both values or neither; a
registry that needs no authentication simply gets no netrc.

Alcali is installed from its exact file URL, which the formula derives as:

```
{registry_url}/files/alcali/{version}/alcali-{version}-py3-none-any.whl
```

No package index is consulted for Alcali itself, so nothing published under
that name on another index can be selected in its place. Its dependencies are
ordinary PyPI packages and resolve normally. Set
`alcali:deploy:package:url` to override the whole URL if the registry layout
ever differs.

The installed version comes from `alcali:version`, or from
`alcali:deploy:package:version` when the two need to differ. Upgrading is a
pillar change: raise the version and re-apply.

Because a wheel cannot carry the repository's `VERSION` file, the formula
writes it next to the installed package so the interface and
`manage.py current_version` report the deployed release rather than
`unknown`.

### Dropping the build toolchain

`gcc`, `python3-dev`, `pkg-config` and the database client headers are
installed only because `mysqlclient`, `psycopg2` and `python-ldap` compile from
source. On PostgreSQL without LDAP, selecting a prebuilt connector removes all
of them:

```yaml
alcali:
  database:
    backend: postgresql
    connector: psycopg2-binary
```

## Source access (method: source)

The Forgejo repository is private, so the minion authenticates before it can
clone:

1. Create a **read-only deploy key** for `salt/alcali-modernized` in Forgejo.
2. Place the private key where the minion can read it, either in the
   fileserver next to this formula (`files/deploy_key`, kept out of any public
   repository) or already on the minion, and point at it:

   ```yaml
   alcali:
     deploy:
       identity: salt://alcali/files/deploy_key
   ```

3. Leave `deploy:known_host` populated. It writes the forge's host key into
   the deploy user's `known_hosts` before the first clone, so an unexpected
   key aborts the run instead of being trusted silently. Confirm the pinned
   fingerprint against the forge's own SSH settings page:

   ```bash
   ssh-keyscan -p 8222 -t ssh-ed25519 forge.thatserver.ca | ssh-keygen -lf -
   ```

For a public HTTPS repository, set `deploy:identity` and `deploy:known_host`
to `null`.

When a host was previously deployed from the GitHub source, the change of
`deploy:repository` re-points the existing checkout. If Git refuses the
transition, remove `/opt/alcali/code` once and re-apply; the virtualenv,
`.env` and database are untouched.

## Pillar setup

Copy `pillar.example.sls` into your pillar tree and at minimum change:

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

`alcali:salt_master:config_file` defaults to `/etc/salt/master.d/alcali.conf`.
If the `salt` formula also manages this master, it deploys `master.d` with
`clean: true` and deletes files it does not own. Its `config_d_preserve_from`
default resolves `alcali:salt_master:config_file` and preserves whatever this
formula is configured to write, so nothing needs to be repeated under `salt:`.
On an older `salt` formula without that mechanism, either rename this file to
`_alcali.conf` or add it to `salt:master_config_d_preserve` — otherwise it is
removed on the next highstate, and the symptom is that logins and job history
stop working with nothing in Alcali's log.

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
  /opt/alcali/venv/bin/python /opt/alcali/code/manage.py diagnose
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
`pillar.example.sls`.

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

This applies to `method: source` only; `method: package` keeps no checkout.

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
