# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set legacy_source = alcali.deploy.revision == alcali.legacy.revision %}
{%- set python_overrides = alcali.legacy.python_overrides if legacy_source else alcali.python_overrides %}

include:
  - alcali.migrate

alcali-systemd-unit:
  file.managed:
    - name: /etc/systemd/system/{{ alcali.service.name }}.service
    - source: salt://alcali/files/alcali.service.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context:
        service_name: {{ alcali.service.name }}
        directory: {{ alcali.deploy.directory }}
        code_directory: {{ alcali.deploy.code_directory }}
        virtualenv: {{ alcali.deploy.virtualenv }}
        user: {{ alcali.deploy.user }}
        group: {{ alcali.deploy.group }}
        bind: {{ alcali.gunicorn.bind }}
        port: {{ alcali.gunicorn.port }}
        workers: {{ alcali.gunicorn.workers }}
        timeout: {{ alcali.gunicorn.timeout }}
    - require:
      - cmd: alcali-python-dependencies
      {% if python_overrides %}
      - cmd: alcali-python-overrides
      {% endif %}

alcali-systemd-reload:
  module.run:
    - service.systemctl_reload: []
    - onchanges:
      - file: alcali-systemd-unit

alcali-service:
  service.running:
    - name: {{ alcali.service.name }}
    - enable: true
    - require:
      - cmd: alcali-database-migrations
      - file: alcali-systemd-unit
      - module: alcali-systemd-reload
    - watch:
      - file: alcali-environment
      - file: alcali-systemd-unit
      - git: alcali-source
      {% if legacy_source %}
      - file: alcali-legacy-tls-verification
      {% endif %}
      - cmd: alcali-python-dependencies
      {% if python_overrides %}
      - cmd: alcali-python-overrides
      {% endif %}
