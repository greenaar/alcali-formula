# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}
{%- set method = (alcali.deploy.get('method') or 'package')|lower %}
{%- set source_install = method == 'source' %}
{%- set manage = alcali.deploy.virtualenv ~ ('/bin/python manage.py' if source_install else '/bin/alcali') %}
{%- set run_cwd = alcali.deploy.code_directory if source_install else alcali.deploy.directory %}

{#- A Compose deployment has no venv on the host to run this from; there the
    equivalent is a scheduled `docker compose exec`, which is left to the
    operator rather than guessed at here. #}
{%- if method == 'docker' %}

alcali-notify-not-applicable-under-docker:
  test.show_notification:
    - text: |
        alcali:notifications:enabled has no effect with deploy:method: docker.
        Run `docker compose exec alcali alcali notify` on a schedule of
        your choosing instead.

{%- elif alcali.notifications.enabled %}

include:
  - alcali.config

alcali-notify-service:
  file.managed:
    - name: /etc/systemd/system/alcali-notify.service
    - source: salt://alcali/files/alcali-notify.service.jinja
    - template: jinja
    - mode: '0644'
    - context:
        alcali: {{ alcali|json }}
        manage: {{ manage }}
        directory: {{ alcali.deploy.directory }}
        working_directory: {{ run_cwd }}
        user: {{ alcali.deploy.user }}
        group: {{ alcali.deploy.group }}
    - require:
      - file: alcali-environment

alcali-notify-timer:
  file.managed:
    - name: /etc/systemd/system/alcali-notify.timer
    - source: salt://alcali/files/alcali-notify.timer.jinja
    - template: jinja
    - mode: '0644'
    - context:
        schedule: {{ alcali.notifications.schedule }}

alcali-notify-daemon-reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: alcali-notify-service
      - file: alcali-notify-timer

alcali-notify-timer-running:
  service.running:
    - name: alcali-notify.timer
    - enable: true
    - require:
      - module: alcali-notify-daemon-reload

{%- else %}

{#- Disabled rather than absent-by-omission: turning the flag off must
    actually stop the timer, not leave the last one it wrote still firing. #}
alcali-notify-timer-stopped:
  service.dead:
    - name: alcali-notify.timer
    - enable: false
    - onlyif: test -f /etc/systemd/system/alcali-notify.timer

alcali-notify-timer-removed:
  file.absent:
    - name: /etc/systemd/system/alcali-notify.timer
    - require:
      - service: alcali-notify-timer-stopped

alcali-notify-service-removed:
  file.absent:
    - name: /etc/systemd/system/alcali-notify.service
    - require:
      - service: alcali-notify-timer-stopped

{%- endif %}
