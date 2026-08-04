# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set legacy_source = alcali.deploy.revision == alcali.legacy.revision %}
{%- set python_overrides = alcali.legacy.python_overrides if legacy_source else alcali.python_overrides %}

include:
  - alcali.install
  - alcali.config

alcali-database-migrations:
  cmd.run:
    - name: {{ alcali.deploy.virtualenv }}/bin/python manage.py migrate --noinput
    - unless: {{ alcali.deploy.virtualenv }}/bin/python manage.py migrate --check
    - cwd: {{ alcali.deploy.code_directory }}
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
    - name: {{ alcali.deploy.virtualenv }}/bin/python manage.py collectstatic --noinput
    - cwd: {{ alcali.deploy.code_directory }}
    - runas: {{ alcali.deploy.user }}
    - env:
        ENV_PATH: {{ alcali.deploy.directory }}
    - require:
      - cmd: alcali-database-migrations
    - onchanges:
      - git: alcali-source
      - cmd: alcali-python-dependencies
      {% if python_overrides %}
      - cmd: alcali-python-overrides
      {% endif %}
