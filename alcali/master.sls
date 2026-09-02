# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set master = alcali.salt_master %}
{%- set connector = 'mysqlclient' if master.returner == 'mysql' else 'psycopg2' %}

{#- salt-api must not come up before whatever answers the external_auth
    callback, or the first logins fail while it is still starting. What that
    is depends on the deployment method, and for an external Alcali it is
    nothing this minion runs. #}
{%- if alcali.method in ['package', 'source'] %}
{%-   set alcali_service_state = 'alcali-service' %}
{%-   set alcali_service_kind = 'service' %}
{%- elif alcali.method == 'docker' %}
{%-   set alcali_service_state = 'alcali-compose-service' %}
{%-   set alcali_service_kind = 'service' %}
{%- else %}
{%-   set alcali_service_state = none %}
{%-   set alcali_service_kind = none %}
{%- endif %}

{%- if master.manage and ((alcali.database.backend == 'mysql' and master.returner != 'mysql') or (alcali.database.backend == 'postgresql' and master.returner != 'postgres')) %}
alcali-salt-returner-valid:
  test.fail_without_changes:
    - name: >-
        alcali:salt_master:returner must be mysql for a mysql database or
        postgres for a postgresql database.

{%- elif master.manage and not master.rest_auth.verify_url %}
{#- Reached only for deploy:method: external, where there is no local
    deployment to derive the callback from. Rendering the master config
    without it would produce an external_auth block that rejects every
    login, and the failure surfaces on the master rather than in Alcali. #}
alcali-verify-url-configured:
  test.fail_without_changes:
    - name: >-
        Set alcali:salt_master:rest_auth:verify_url to the URL at which this
        master can reach the external Alcali's /api/token/verify/ endpoint.

{%- elif master.manage %}
{%- if alcali_service_state %}
include:
{%- if alcali.method in ['package', 'source'] %}
  - alcali.service
{%- else %}
  - alcali.docker
{%- endif %}
{%- endif %}

{%- if master.install_connector %}
alcali-salt-returner-connector:
  pip.installed:
    - name: {{ connector }}
    - bin_env: {{ master.pip_bin }}
    {#- The system packages state only exists for a local Python install;
        docker and external deployments have no such state to require. #}
    {%- if alcali.method in ['package', 'source'] %}
    - require:
      - pkg: alcali-system-packages
    {%- endif %}
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
      {%- if alcali_service_state %}
      - {{ alcali_service_kind }}: {{ alcali_service_state }}
      {%- endif %}
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
      {%- if alcali_service_state %}
      - {{ alcali_service_kind }}: {{ alcali_service_state }}
      {%- endif %}
      - service: alcali-salt-master-service
    - watch:
      - file: alcali-salt-master-config
      {% if master.install_connector %}
      - pip: alcali-salt-returner-connector
      {% endif %}
{%- endif %}
