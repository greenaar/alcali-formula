# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set backend = alcali.database.backend|lower %}
{%- set legacy_source = alcali.deploy.revision == alcali.legacy.revision %}
{%- set python_overrides = alcali.legacy.python_overrides if legacy_source else alcali.python_overrides %}
{%- set packages = ['ca-certificates', 'git', 'gcc', 'patch', 'pkg-config', 'python3', 'python3-dev', 'python3-pip', 'python3-venv'] %}
{%- if backend == 'mysql' %}
{%-   do packages.append('default-libmysqlclient-dev') %}
{%- elif backend == 'postgresql' %}
{%-   do packages.append('libpq-dev') %}
{%- endif %}
{%- if alcali.features.ldap %}
{%-   do packages.extend(['libldap2-dev', 'libsasl2-dev', 'ldap-utils']) %}
{%- endif %}
{%- set connector = 'mysqlclient' if backend == 'mysql' else 'psycopg2' %}

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
{%- else %}
alcali-system-packages:
  pkg.installed:
    - pkgs: {{ packages|unique|list|json }}

alcali-supported-python:
  cmd.run:
    - name: >-
        {{ alcali.deploy.python }} -c
        "import sys; raise SystemExit(sys.version_info < (3, 12))"
    - require:
      - pkg: alcali-system-packages

alcali-source:
  git.latest:
    - name: {{ alcali.deploy.repository }}
    - target: {{ alcali.deploy.code_directory }}
    - rev: {{ alcali.deploy.revision }}
    - user: {{ alcali.deploy.user }}
    - force_reset: {{ alcali.deploy.force_reset }}
    - force_clone: false
    - fetch_tags: true
    - require:
      - pkg: alcali-system-packages
      - file: alcali-deploy-directory

{%- if legacy_source %}
alcali-legacy-tls-verification:
  file.patch:
    - name: {{ alcali.deploy.code_directory }}/api/backend/netapi.py
    - source: salt://alcali/files/verify-salt-api-tls.patch
    - strip: 1
    - require:
      - git: alcali-source
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
    - name: {{ alcali.deploy.directory }}/.python-install-spec
    - user: {{ alcali.deploy.user }}
    - group: {{ alcali.deploy.group }}
    - mode: '0640'
    - contents: |
        source={{ alcali.deploy.revision }}
        connector={{ connector }}
        ldap={{ alcali.features.ldap }}
        social={{ alcali.features.social }}
        overrides={{ python_overrides|join(',') }}
    - require:
      - file: alcali-deploy-directory

alcali-python-dependencies:
  cmd.run:
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
    - runas: {{ alcali.deploy.user }}
    - cwd: {{ alcali.deploy.code_directory }}
    - require:
      - git: alcali-source
      {% if legacy_source %}
      - file: alcali-legacy-tls-verification
      {% endif %}
      - cmd: alcali-virtualenv
    - onchanges:
      - git: alcali-source
      {% if legacy_source %}
      - file: alcali-legacy-tls-verification
      {% endif %}
      - cmd: alcali-virtualenv
      - file: alcali-python-install-spec

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
    - cwd: {{ alcali.deploy.code_directory }}
    - require:
      - cmd: alcali-python-dependencies
    - onchanges:
      - cmd: alcali-python-dependencies
      - file: alcali-python-install-spec
{%- endif %}
{%- endif %}
