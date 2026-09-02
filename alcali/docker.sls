# -*- coding: utf-8 -*-
# vim: ft=sls
---
{#-
  alcali.docker
  ---------------------------------------------------------------------------
  Runs the published Alcali container image on this host under Compose,
  instead of installing Python on the minion.

  What it deliberately does not run is a salt-master or a salt-minion. Alcali
  is a view onto a Salt installation that already exists; alcali.master does
  the wiring on the master side, and works whether Alcali is here, in this
  container, or on another host entirely (deploy:method: external).

  The container is driven by a systemd unit rather than by a Salt Docker
  module: `docker compose up -d` in a oneshot unit survives a reboot, is
  inspectable with the same tools as every other service on the host, and
  does not depend on a Salt execution module whose Compose support has been
  moved and removed more than once.
#}
{%- from "alcali/map.jinja" import alcali with context %}
{%- set docker = alcali.docker %}
{%- set secret = alcali.django.secret_key|string %}
{%- set db_password = alcali.database.password|string %}
{%- set verify_tls = alcali.salt_api.get('verify_tls', alcali.salt_api.get('verify_ssl', true)) %}
{%- set secrets_valid = secret|length >= 32 and db_password|length >= 16
      and not secret.startswith(('CHANGE_', 'REPLACE_'))
      and not db_password.startswith(('CHANGE_', 'REPLACE_')) %}

{%- set image = docker.image or (docker.registry.rstrip('/') ~ '/alcali:' ~ alcali.version) %}

{#- A container's loopback is the container, not the host. Anything the
    application must reach on this host has to go through the host gateway
    alias instead, or the connection silently goes nowhere. #}
{%- set loopback = ['127.0.0.1', 'localhost', '::1', '0.0.0.0', ''] %}
{%- set db_is_local = alcali.database.host|string in loopback %}
{%- if docker.bundled_database %}
{%-   set db_host = 'db' %}
{%- elif db_is_local %}
{%-   set db_host = 'host.docker.internal' %}
{%- else %}
{%-   set db_host = alcali.database.host %}
{%- endif %}

{#- salt-api gets no such rewrite. Substituting the gateway alias into
    SALT_URL would break certificate verification, because no master's
    salt-api certificate is issued for it, and the fix operators reach for
    when that fails is to turn verification off on the connection carrying
    their users' credentials. Requiring a routable name is the smaller ask. #}
{%- set salt_api_host = alcali.salt_api.url|string|regex_replace('^[a-zA-Z]+://', '')|regex_replace('[:/].*$', '') %}
{%- set salt_api_is_local = salt_api_host in loopback %}

{%- set ca_bundle = docker.ca_bundle_path if docker.ca_bundle_source else alcali.salt_api.ca_bundle %}

{%- if grains.get('os_family') != 'Debian' or grains.get('osfinger') not in alcali.supported_osfingers %}
alcali-docker-supported-platform:
  test.fail_without_changes:
    - name: >-
        Alcali supports {{ alcali.supported_osfingers|join(', ') }} only;
        this host is {{ grains.get('osfinger', 'unknown') }}.

{%- elif alcali.database.backend|lower != 'mysql' and docker.bundled_database %}
alcali-docker-bundled-database-backend:
  test.fail_without_changes:
    - name: >-
        alcali:docker:bundled_database runs MariaDB, so
        alcali:database:backend must be mysql. Point at an external
        PostgreSQL server instead.

{%- elif docker.bundled_database and not db_is_local %}
alcali-docker-bundled-database-address:
  test.fail_without_changes:
    - name: >-
        alcali:database:host is {{ alcali.database.host }}, but
        alcali:docker:bundled_database publishes the database on this host.
        Set alcali:database:host to the address the Salt master should
        connect to on this machine, or turn bundled_database off.

{%- elif docker.bundled_database and not docker.database_root_password %}
alcali-docker-bundled-database-root-password:
  test.fail_without_changes:
    - name: >-
        Set alcali:docker:database_root_password; MariaDB will not
        initialise without one.

{%- elif salt_api_is_local and verify_tls %}
alcali-docker-salt-api-address:
  test.fail_without_changes:
    - name: >-
        alcali:salt_api:url points at {{ salt_api_host }}, which inside the
        container is the container itself. Use the hostname the master's
        salt-api certificate is issued for, so that TLS verification keeps
        working; it must resolve and be routable from this host.

{%- elif not secrets_valid %}
alcali-docker-configuration-valid:
  test.fail_without_changes:
    - name: >-
        Set non-default alcali:django:secret_key and
        alcali:database:password values in pillar.

{%- elif (docker.registry_username or docker.registry_password) and not (docker.registry_username and docker.registry_password) %}
alcali-docker-registry-credentials-complete:
  test.fail_without_changes:
    - name: >-
        Set both alcali:docker:registry_username and
        alcali:docker:registry_password, or neither for an anonymous
        registry.

{%- else %}

{%- if docker.install_packages %}
alcali-docker-packages:
  pkg.installed:
    - pkgs: {{ docker.packages|json }}

alcali-docker-daemon:
  service.running:
    - name: docker
    - enable: true
    - require:
      - pkg: alcali-docker-packages
{%- endif %}

alcali-docker-directory:
  file.directory:
    - name: {{ docker.directory }}
    - user: root
    - group: root
    - mode: '0750'
    - makedirs: true
    {%- if docker.install_packages %}
    - require:
      - pkg: alcali-docker-packages
    {%- endif %}

{%- if docker.registry_username %}
{#- Written as a file rather than run through `docker login`, which would put
    the token in the command line, in the state output, and from there into
    the master job cache - which is the database Alcali itself reads. #}
{%- set registry_host = image.split('/')[0] %}
alcali-docker-registry-credentials:
  file.serialize:
    - name: /root/.docker/config.json
    - serializer: json
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: true
    - show_changes: false
    - merge_if_exists: true
    - dataset:
        auths:
          {{ registry_host }}:
            auth: {{ (docker.registry_username ~ ':' ~ docker.registry_password)|base64_encode }}
{%- endif %}

{%- if docker.bundled_database %}
alcali-docker-returner-schema:
  file.managed:
    - name: {{ docker.directory }}/initdb/01-salt-returner-schema.sql
    - source: salt://alcali/files/salt-returner-schema.sql
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: true
    - require:
      - file: alcali-docker-directory
{%- endif %}

{%- if docker.ca_bundle_source %}
alcali-docker-ca-bundle:
  file.managed:
    - name: {{ docker.ca_bundle_path }}
    {%- if docker.ca_bundle_source.startswith('salt://') %}
    - source: {{ docker.ca_bundle_source }}
    {%- else %}
    - source: file://{{ docker.ca_bundle_source }}
    {%- endif %}
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: true
    - require:
      - file: alcali-docker-directory
{%- endif %}

alcali-docker-environment:
  file.managed:
    - name: {{ docker.directory }}/.env
    - source: salt://alcali/files/alcali.env.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0600'
    {#- The file carries SECRET_KEY and the database password. A diff in the
        state output is copied into the master job cache, so it is suppressed
        here as it is for the systemd deployment. #}
    - show_changes: false
    - context:
        alcali: {{ alcali|json }}
        db_host: {{ db_host|json }}
        ca_bundle: {{ ca_bundle|json }}
        verify_tls: {{ verify_tls|json }}
        legacy_source: false
    - require:
      - file: alcali-docker-directory

alcali-docker-compose-file:
  file.managed:
    - name: {{ docker.compose_file }}
    - source: salt://alcali/files/docker-compose.yml.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0640'
    - context:
        alcali: {{ alcali|json }}
        docker: {{ docker|json }}
        image: {{ image|json }}
        ca_bundle: {{ ca_bundle|json }}
    - require:
      - file: alcali-docker-directory
      {%- if docker.bundled_database %}
      - file: alcali-docker-returner-schema
      {%- endif %}

alcali-compose-unit:
  file.managed:
    - name: /etc/systemd/system/{{ docker.service }}.service
    - source: salt://alcali/files/alcali-compose.service.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context:
        docker: {{ docker|json }}
    - require:
      - file: alcali-docker-compose-file
      - file: alcali-docker-environment

alcali-compose-systemd-reload:
  module.run:
    - service.systemctl_reload: []
    - onchanges:
      - file: alcali-compose-unit

alcali-compose-service:
  service.running:
    - name: {{ docker.service }}
    - enable: true
    - require:
      - file: alcali-compose-unit
      - module: alcali-compose-systemd-reload
      {%- if docker.install_packages %}
      - service: alcali-docker-daemon
      {%- endif %}
      {%- if docker.registry_username %}
      - file: alcali-docker-registry-credentials
      {%- endif %}
      {%- if docker.ca_bundle_source %}
      - file: alcali-docker-ca-bundle
      {%- endif %}
    {#- The unit is oneshot: `systemctl restart` reruns `docker compose up -d`,
        which recreates only the containers whose configuration changed and
        reruns the migration job to completion first. #}
    - watch:
      - file: alcali-docker-compose-file
      - file: alcali-docker-environment
      - file: alcali-compose-unit
      {%- if docker.ca_bundle_source %}
      - file: alcali-docker-ca-bundle
      {%- endif %}

{%- endif %}
