# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set method = (alcali.deploy.get('method') or 'package')|lower %}
{%- set source_install = method == 'source' %}
{%- set legacy_source = source_install and alcali.deploy.revision == alcali.legacy.revision %}
{%- set python_overrides = alcali.legacy.python_overrides if legacy_source else alcali.python_overrides %}
{#- A source checkout is driven through manage.py; an installed wheel exposes
    the same entry point as the `alcali` console script. #}
{%- set manage = alcali.deploy.virtualenv ~ ('/bin/python manage.py' if source_install else '/bin/alcali') %}
{%- set run_cwd = alcali.deploy.code_directory if source_install else alcali.deploy.directory %}

include:
  - alcali.install
  - alcali.config

alcali-database-migrations:
  cmd.run:
    - name: {{ manage }} migrate --noinput
    - unless: {{ manage }} migrate --check
    - cwd: {{ run_cwd }}
    - runas: {{ alcali.deploy.user }}
    - env:
        ENV_PATH: {{ alcali.deploy.directory }}
    - require:
      - cmd: alcali-python-dependencies
      {% if python_overrides %}
      - cmd: alcali-python-overrides
      {% endif %}
      - file: alcali-environment

alcali-static-assets:
  cmd.run:
    - name: {{ manage }} collectstatic --noinput
    - cwd: {{ run_cwd }}
    - runas: {{ alcali.deploy.user }}
    - env:
        ENV_PATH: {{ alcali.deploy.directory }}
    - require:
      - cmd: alcali-database-migrations
    - onchanges:
      {% if source_install %}
      - git: alcali-source
      {% endif %}
      - cmd: alcali-python-dependencies
      {% if python_overrides %}
      - cmd: alcali-python-overrides
      {% endif %}
