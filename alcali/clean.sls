# -*- coding: utf-8 -*-
# vim: ft=sls

{%- from "alcali/map.jinja" import alcali with context %}

{#- Nothing is deployed for deploy:method: external, so there is nothing to
    remove but the master-side configuration below. #}
{%- if alcali.method == 'docker' %}
{%- set docker = alcali.docker %}

alcali-compose-service-removed:
  service.dead:
    - name: {{ docker.service }}
    - enable: false

{#- `down` without -v. The bundled database's volume holds the Salt job
    history, which is not this state's to delete: it is also the master's job
    cache. Remove it deliberately with
    `docker volume rm {{ docker.project_name }}_db-data` once you are sure. #}
alcali-compose-project-removed:
  cmd.run:
    - name: >-
        docker compose --file {{ docker.compose_file }} down --remove-orphans
    - onlyif: test -f {{ docker.compose_file }}
    - require:
      - service: alcali-compose-service-removed

alcali-compose-unit-removed:
  file.absent:
    - name: /etc/systemd/system/{{ docker.service }}.service
    - require:
      - cmd: alcali-compose-project-removed

alcali-compose-systemd-reload-after-removal:
  module.run:
    - service.systemctl_reload: []
    - onchanges:
      - file: alcali-compose-unit-removed

alcali-compose-directory-removed:
  file.absent:
    - name: {{ docker.directory }}
    - require:
      - cmd: alcali-compose-project-removed

{%- elif alcali.method in ['package', 'source'] %}

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

{%- endif %}

{%- if alcali.salt_master.remove_on_clean %}
alcali-salt-master-config-removed:
  file.absent:
    - name: {{ alcali.salt_master.config_file }}
{%- endif %}
