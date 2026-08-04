# -*- coding: utf-8 -*-
# vim: ft=sls

{%- from "alcali/map.jinja" import alcali with context %}

alcali-service-removed:
  service.dead:
    - name: {{ alcali.service.name }}
    - enable: false

alcali-systemd-unit-removed:
  file.absent:
    - name: /etc/systemd/system/{{ alcali.service.name }}.service
    - require:
      - service: alcali-service-removed

alcali-systemd-reload-after-removal:
  module.run:
    - service.systemctl_reload: []
    - onchanges:
      - file: alcali-systemd-unit-removed

alcali-deployment-removed:
  file.absent:
    - name: {{ alcali.deploy.directory }}
    - require:
      - service: alcali-service-removed

alcali-user-removed:
  user.absent:
    - name: {{ alcali.deploy.user }}
    - require:
      - file: alcali-deployment-removed

alcali-group-removed:
  group.absent:
    - name: {{ alcali.deploy.group }}
    - require:
      - user: alcali-user-removed

{%- if alcali.salt_master.remove_on_clean %}
alcali-salt-master-config-removed:
  file.absent:
    - name: {{ alcali.salt_master.config_file }}
{%- endif %}
