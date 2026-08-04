# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set master = alcali.salt_master %}
{%- set connector = 'mysqlclient' if master.returner == 'mysql' else 'psycopg2' %}

{%- if master.manage and ((alcali.database.backend == 'mysql' and master.returner != 'mysql') or (alcali.database.backend == 'postgresql' and master.returner != 'postgres')) %}
alcali-salt-returner-valid:
  test.fail_without_changes:
    - name: >-
        alcali:salt_master:returner must be mysql for a mysql database or
        postgres for a postgresql database.
{%- elif master.manage %}
include:
  - alcali.service

{%- if master.install_connector %}
alcali-salt-returner-connector:
  pip.installed:
    - name: {{ connector }}
    - bin_env: {{ master.pip_bin }}
    - require:
      - pkg: alcali-system-packages
{%- endif %}

alcali-salt-api-certificate:
  file.exists:
    - name: {{ master.api.ssl_crt }}

alcali-salt-api-private-key:
  file.exists:
    - name: {{ master.api.ssl_key }}

alcali-salt-master-config:
  file.managed:
    - name: {{ master.config_file }}
    - source: salt://alcali/files/salt-master.conf.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: true
    - context:
        database: {{ alcali.database|json }}
        master: {{ master|json }}
    - require:
      - service: alcali-service
      - file: alcali-salt-api-certificate
      - file: alcali-salt-api-private-key
      {% if master.install_connector %}
      - pip: alcali-salt-returner-connector
      {% endif %}

alcali-salt-master-service:
  service.running:
    - name: {{ master.master_service }}
    - enable: true
    - watch:
      - file: alcali-salt-master-config
      {% if master.install_connector %}
      - pip: alcali-salt-returner-connector
      {% endif %}

alcali-salt-api-service:
  service.running:
    - name: {{ master.api_service }}
    - enable: true
    - require:
      - service: alcali-service
      - service: alcali-salt-master-service
    - watch:
      - file: alcali-salt-master-config
      {% if master.install_connector %}
      - pip: alcali-salt-returner-connector
      {% endif %}
{%- endif %}
