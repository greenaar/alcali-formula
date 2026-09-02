# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set secret = alcali.django.secret_key|string %}
{%- set db_password = alcali.database.password|string %}
{%- set legacy_source = alcali.deploy.revision == alcali.legacy.revision %}
{%- set verify_tls = alcali.salt_api.get('verify_tls', alcali.salt_api.get('verify_ssl', true)) %}
{%- set valid = secret|length >= 32 and db_password|length >= 16 and not secret.startswith(('CHANGE_', 'REPLACE_')) and not db_password.startswith(('CHANGE_', 'REPLACE_')) %}

include:
  - alcali.user

alcali-configuration-valid:
  test.configurable_test_state:
    - name: Alcali secrets have been configured.
    - result: {{ valid }}
    - changes: false
    - comment: >-
        Set non-default alcali:django:secret_key and
        alcali:database:password values in pillar.

alcali-environment:
  file.managed:
    - name: {{ alcali.deploy.directory }}/.env
    - source: salt://alcali/files/alcali.env.jinja
    - template: jinja
    - user: root
    - group: {{ alcali.deploy.group }}
    - mode: '0640'
    - show_changes: false
    - context:
        alcali: {{ alcali|json }}
        db_host: {{ alcali.database.host|json }}
        ca_bundle: {{ alcali.salt_api.ca_bundle|json }}
        verify_tls: {{ verify_tls|json }}
        legacy_source: {{ legacy_source|json }}
    - require:
      - file: alcali-deploy-directory
      - test: alcali-configuration-valid
