# -*- coding: utf-8 -*-
# vim: ft=sls

{%- from "alcali/map.jinja" import alcali with context %}

include:
{%- if alcali.method in ['package', 'source'] %}
  - alcali.user
  - alcali.install
  - alcali.config
  - alcali.migrate
  - alcali.service
  - alcali.notify
{%- elif alcali.method == 'docker' %}
  - alcali.docker
{%- endif %}
{#- Always applied. For deploy:method: external this is the only thing the
    formula does: the returner, salt-api and external_auth configuration that
    an Alcali running elsewhere still depends on. It is itself opt-in through
    alcali:salt_master:manage. #}
  - alcali.master
