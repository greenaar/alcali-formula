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
    - user: root
    - group: {{ alcali.deploy.group }}
    - mode: '0640'
    - contents: |
        # Managed by Salt. Do not edit locally.
        DB_BACKEND={{ alcali.database.backend|yaml_dquote }}
        DB_NAME={{ alcali.database.name|yaml_dquote }}
        DB_USER={{ alcali.database.user|yaml_dquote }}
        DB_PASS={{ alcali.database.password|yaml_dquote }}
        DB_HOST={{ alcali.database.host|yaml_dquote }}
        DB_PORT={{ alcali.database.port|yaml_dquote }}
        SECRET_KEY={{ alcali.django.secret_key|yaml_dquote }}
        ALLOWED_HOSTS={{ alcali.django.allowed_hosts|join(' ')|yaml_dquote }}
        DJANGO_DEBUG={{ alcali.django.debug|string|lower|yaml_dquote }}
        MASTER_MINION_ID={{ alcali.salt_api.master_minion_id|yaml_dquote }}
        SALT_URL={{ alcali.salt_api.url|yaml_dquote }}
        SALT_AUTH={{ alcali.salt_api.auth|yaml_dquote }}
        SALT_VERIFY_TLS={{ verify_tls|string|lower|yaml_dquote }}
        {% if legacy_source %}
        # Used only by the currently pinned legacy revision.
        SALT_VERIFY_SSL={{ verify_tls|string|lower|yaml_dquote }}
        {% endif %}
        SALT_TIMEOUT={{ alcali.salt_api.timeout|yaml_dquote }}
        {% if alcali.salt_api.ca_bundle %}
        SALT_CA_BUNDLE={{ alcali.salt_api.ca_bundle|yaml_dquote }}
        {% endif %}
        {% if alcali.django.auth_backend %}
        AUTH_BACKEND={{ alcali.django.auth_backend|yaml_dquote }}
        {% endif %}
        {% for key, value in alcali.environment|dictsort %}
        {{ key|upper }}={{ value|string|yaml_dquote }}
        {% endfor %}
    - require:
      - file: alcali-deploy-directory
      - test: alcali-configuration-valid
