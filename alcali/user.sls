# -*- coding: utf-8 -*-
# vim: ft=sls
---
{%- from "alcali/map.jinja" import alcali with context %}

alcali-group:
  group.present:
    - name: {{ alcali.deploy.group }}
    - system: true

alcali-user:
  user.present:
    - name: {{ alcali.deploy.user }}
    - gid: {{ alcali.deploy.group }}
    - home: {{ alcali.deploy.directory }}
    - shell: {{ alcali.deploy.shell }}
    - system: true
    - createhome: false
    - require:
      - group: alcali-group

alcali-deploy-directory:
  file.directory:
    - name: {{ alcali.deploy.directory }}
    - user: {{ alcali.deploy.user }}
    - group: {{ alcali.deploy.group }}
    - mode: '0750'
    - makedirs: true
    - require:
      - user: alcali-user
