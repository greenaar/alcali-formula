# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set backend = alcali.database.backend|lower %}
{%- set method = (alcali.deploy.get('method') or 'package')|lower %}
{%- set source_install = method == 'source' %}
{%- set legacy_source = source_install and alcali.deploy.revision == alcali.legacy.revision %}
{%- set python_overrides = alcali.legacy.python_overrides if legacy_source else alcali.python_overrides %}
{%- set connector = alcali.database.get('connector') or ('mysqlclient' if backend == 'mysql' else 'psycopg2') %}
{#- python-ldap and the non-binary database connectors are built from source. #}
{%- set needs_toolchain = alcali.features.ldap or not connector.endswith('-binary') %}
{%- set packages = ['ca-certificates', 'python3', 'python3-pip', 'python3-venv'] %}
{%- if needs_toolchain %}
{%-   do packages.extend(['gcc', 'pkg-config', 'python3-dev']) %}
{%-   if backend == 'mysql' and not connector.endswith('-binary') %}
{%-     do packages.append('default-libmysqlclient-dev') %}
{%-   elif backend == 'postgresql' and not connector.endswith('-binary') %}
{%-     do packages.append('libpq-dev') %}
{%-   endif %}
{%- endif %}
{%- if source_install %}
{%-   do packages.extend(['git', 'patch']) %}
{%- endif %}
{%- if alcali.features.ldap %}
{%-   do packages.extend(['libldap2-dev', 'libsasl2-dev', 'ldap-utils']) %}
{%- endif %}
{%- set known_host = alcali.deploy.get('known_host') or {} %}
{%- set identity = alcali.deploy.get('identity') %}
{%- set package_cfg = alcali.deploy.get('package') or {} %}
{%- set package_version = package_cfg.get('version') or alcali.version %}
{%- set extras = [] %}
{%- if alcali.features.ldap %}{%- do extras.append('ldap') %}{%- endif %}
{%- if alcali.features.social %}{%- do extras.append('social') %}{%- endif %}
{#- The Forgejo and Gitea package registries serve a file at
    {registry}/files/{name}/{version}/{filename}, which is what registry_url
    is composed against; set deploy:package:url outright for any registry
    that lays its files out differently. Naming the wheel outright
    means pip never queries an index for Alcali, so nothing published under
    the same name anywhere else can be selected instead. #}
{%- set wheel_name = 'alcali-' ~ package_version ~ '-py3-none-any.whl' %}
{#- `url` may carry {version} and {wheel} placeholders so a configured default
    follows alcali:version rather than pinning one release. A literal URL with
    neither placeholder is passed through unchanged. #}
{%- set url_template = package_cfg.get('url') %}
{%- set wheel_url = url_template|replace('{version}', package_version)|replace('{wheel}', wheel_name)
      if url_template else
      ((package_cfg.get('registry_url') or '').rstrip('/') ~ '/files/alcali/' ~ package_version ~ '/' ~ wheel_name) %}
{%- set requirement = 'alcali[' ~ extras|join(',') ~ '] @ ' ~ wheel_url if extras else 'alcali @ ' ~ wheel_url %}
{%- set registry_user = package_cfg.get('username') %}
{%- set registry_password = package_cfg.get('password') %}
{%- set registry_auth = registry_user and registry_password %}
{%- set netrc = alcali.deploy.directory ~ '/.netrc' %}
{#- The spec that is wanted, and the record of what was actually installed.
    The record lives inside the virtualenv so that removing the virtualenv
    also removes it, and the install runs again. #}
{%- set desired_spec = alcali.deploy.directory ~ '/.python-install-spec' %}
{%- set installed_spec = alcali.deploy.virtualenv ~ '/.alcali-install-spec' %}

include:
  - alcali.user

{%- if grains.get('os_family') != 'Debian' or grains.get('osfinger') not in alcali.supported_osfingers %}
alcali-supported-platform:
  test.fail_without_changes:
    - name: >-
        Alcali supports {{ alcali.supported_osfingers|join(', ') }} only;
        this host is {{ grains.get('osfinger', 'unknown') }}.
{%- elif backend not in ['mysql', 'postgresql'] %}
alcali-supported-database:
  test.fail_without_changes:
    - name: alcali:database:backend must be mysql or postgresql.
{%- elif method not in ['package', 'source'] %}
alcali-supported-method:
  test.fail_without_changes:
    - name: alcali:deploy:method must be package or source.
{%- elif method == 'package' and (registry_user or registry_password) and not registry_auth %}
alcali-registry-credentials-complete:
  test.fail_without_changes:
    - name: >-
        Set both alcali:deploy:package:username and
        alcali:deploy:package:password, or neither for an anonymous registry.
{%- elif method == 'package' and not (package_cfg.get('registry_url') or package_cfg.get('url')) %}
alcali-package-source-configured:
  test.fail_without_changes:
    - name: >-
        Set alcali:deploy:package:registry_url to the PyPI registry holding
        the alcali wheel, or alcali:deploy:package:url to the wheel itself.
{%- else %}
alcali-system-packages:
  pkg.installed:
    - pkgs: {{ packages|unique|list|json }}

alcali-supported-python:
  cmd.run:
    - name: echo "Python version check passed"
    - unless: >-
        {{ alcali.deploy.python }} -c
        "import sys; raise SystemExit(sys.version_info < (3, 12))"
    - require:
      - pkg: alcali-system-packages

{%- if source_install %}
{%- if known_host.get('name') %}
alcali-source-known-host:
  ssh_known_hosts.present:
    - name: {{ known_host.name }}
    - user: {{ alcali.deploy.user }}
    - port: {{ known_host.get('port', 22) }}
    {%- if known_host.get('enc') %}
    - enc: {{ known_host.enc }}
    {%- endif %}
    {%- if known_host.get('fingerprint') %}
    - fingerprint: {{ known_host.fingerprint }}
    - fingerprint_hash_type: sha256
    {%- endif %}
    - require:
      - pkg: alcali-system-packages
      - file: alcali-deploy-directory
{%- endif %}

alcali-source:
  git.latest:
    - name: {{ alcali.deploy.repository }}
    - target: {{ alcali.deploy.code_directory }}
    - rev: {{ alcali.deploy.revision }}
    - user: {{ alcali.deploy.user }}
    - force_reset: {{ alcali.deploy.force_reset }}
    - force_clone: false
    - fetch_tags: true
    {%- if identity %}
    - identity: {{ identity }}
    {%- endif %}
    - require:
      - pkg: alcali-system-packages
      - file: alcali-deploy-directory
      {%- if known_host.get('name') %}
      - ssh_known_hosts: alcali-source-known-host
      {%- endif %}

{%- if legacy_source %}
alcali-legacy-tls-verification:
  file.patch:
    - name: {{ alcali.deploy.code_directory }}/api/backend/netapi.py
    - source: salt://alcali/files/verify-salt-api-tls.patch
    - strip: 1
    - require:
      - git: alcali-source
{%- endif %}
{%- else %}
{%- if registry_auth %}
{#- The wheel URL carries no credentials: pip reads them from the deploy
    user's netrc, which keeps them out of process arguments and out of state
    output. #}
alcali-registry-credentials:
  file.managed:
    - name: {{ netrc }}
    - user: {{ alcali.deploy.user }}
    - group: {{ alcali.deploy.group }}
    - mode: '0600'
    - show_changes: false
    - contents: |
        machine {{ wheel_url.replace('https://', '').replace('http://', '').split('/')[0].split(':')[0] }}
        login {{ registry_user }}
        password {{ registry_password }}
    - require:
      - file: alcali-deploy-directory
{%- endif %}
{%- endif %}

alcali-virtualenv:
  cmd.run:
    - name: {{ alcali.deploy.python }} -m venv {{ alcali.deploy.virtualenv }}
    - creates: {{ alcali.deploy.virtualenv }}/bin/python
    - runas: {{ alcali.deploy.user }}
    - require:
      - pkg: alcali-system-packages
      - file: alcali-deploy-directory
      - cmd: alcali-supported-python

alcali-python-install-spec:
  file.managed:
    - name: {{ desired_spec }}
    - user: {{ alcali.deploy.user }}
    - group: {{ alcali.deploy.group }}
    - mode: '0640'
    - contents: |
        method={{ method }}
        source={{ alcali.deploy.revision if source_install else requirement }}
        connector={{ connector }}
        ldap={{ alcali.features.ldap }}
        social={{ alcali.features.social }}
        overrides={{ python_overrides|join(',') }}
    - require:
      - file: alcali-deploy-directory

alcali-python-dependencies:
  cmd.run:
{%- if source_install %}
    - name: >-
        {{ alcali.deploy.virtualenv }}/bin/pip install
        --disable-pip-version-check
        'setuptools<81'
        --requirement {{ alcali.deploy.code_directory }}/requirements/prod.txt
        {{ connector }}
        {% if alcali.features.ldap %}
        --requirement {{ alcali.deploy.code_directory }}/requirements/ldap.txt
        {% endif %}
        {% if alcali.features.social %}
        --requirement {{ alcali.deploy.code_directory }}/requirements/social.txt
        {% endif %}
    - cwd: {{ alcali.deploy.code_directory }}
{%- else %}
    - name: >-
        {{ alcali.deploy.virtualenv }}/bin/pip install
        --disable-pip-version-check --upgrade
        '{{ requirement }}' {{ connector }}
    - cwd: {{ alcali.deploy.directory }}
    {#- pip finds the registry credentials through the deploy user's netrc. #}
    - env:
        HOME: {{ alcali.deploy.directory }}
{%- endif %}
    - runas: {{ alcali.deploy.user }}
    - require:
{%- if source_install %}
      - git: alcali-source
      {% if legacy_source %}
      - file: alcali-legacy-tls-verification
      {% endif %}
{%- elif registry_auth %}
      - file: alcali-registry-credentials
{%- endif %}
      - cmd: alcali-virtualenv
    {#- Not `onchanges` on the spec file: that file is written before pip
        runs, so a failed install left it in place and every later run saw no
        change and skipped the install, leaving Alcali uninstalled with the
        state reporting success. This compares the spec against a record
        written only after the install actually succeeded. #}
    - unless:
      - cmp -s '{{ installed_spec }}' '{{ desired_spec }}'

{%- if not source_install %}
{#- The wheel cannot carry the repository's VERSION file, which sits outside
    every package, so an installed Alcali reports its version as "unknown".
    Write it next to the installed code, where settings.py looks for it. #}
alcali-version-file:
  cmd.run:
    - name: >-
        {{ alcali.deploy.virtualenv }}/bin/python -c
        "import pathlib, config;
        base = pathlib.Path(config.__file__).resolve().parent.parent;
        (base / 'VERSION').write_text('{{ package_version }}' + chr(10))"
    - runas: {{ alcali.deploy.user }}
    {#- python -c puts the working directory on sys.path, so run from a
        directory that cannot shadow the installed package. #}
    - cwd: /
    - require:
      - cmd: alcali-python-dependencies
    - onchanges:
      - cmd: alcali-python-dependencies
{%- endif %}

{%- if python_overrides %}
alcali-python-overrides:
  cmd.run:
    - name: >-
        {{ alcali.deploy.virtualenv }}/bin/pip install
        --disable-pip-version-check --upgrade
        {% for requirement in python_overrides %}
        '{{ requirement }}'
        {% endfor %}
    - runas: {{ alcali.deploy.user }}
    - cwd: {{ alcali.deploy.directory }}
    - require:
      - cmd: alcali-python-dependencies
    - onchanges:
      - cmd: alcali-python-dependencies
    - require_in:
      - cmd: alcali-python-install-recorded
{%- endif %}

{#- Written only once everything above has succeeded, and inside the
    virtualenv so that removing it forces a reinstall. Until this exists and
    matches the wanted spec, alcali-python-dependencies runs again - so a
    failed install (an unpublished wheel, a registry that was unreachable) is
    retried on the next run instead of being skipped forever. #}
alcali-python-install-recorded:
  cmd.run:
    - name: cp '{{ desired_spec }}' '{{ installed_spec }}'
    - runas: {{ alcali.deploy.user }}
    - unless:
      - cmp -s '{{ installed_spec }}' '{{ desired_spec }}'
    - require:
      - cmd: alcali-python-dependencies
      - file: alcali-python-install-spec
{%- endif %}
