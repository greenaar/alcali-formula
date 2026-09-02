-- Managed by Salt via alcali.docker. Loaded by MariaDB's entrypoint the first
-- time alcali:docker:bundled_database initialises its volume.
--
-- This is the mysql returner's own schema, matching Salt's documented DDL for
-- salt.returners.mysql. Alcali reads these three tables as unmanaged Django
-- models; `manage.py migrate` neither creates nor alters them.
--
-- Nothing here drops. The entrypoint only runs initdb.d against an empty data
-- directory, but a script that opens with DROP DATABASE is one misplaced bind
-- mount away from destroying a job history, so that shape is not worth
-- keeping at all.
--
-- The MariaDB entrypoint has already created and selected MARIADB_DATABASE and
-- granted MARIADB_USER on it, so no CREATE DATABASE or GRANT is needed.

CREATE TABLE IF NOT EXISTS `jids` (
  `jid` varchar(255) NOT NULL,
  `load` mediumtext NOT NULL,
  UNIQUE KEY `jid` (`jid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `salt_returns` (
  `fun` varchar(50) NOT NULL,
  `jid` varchar(255) NOT NULL,
  `return` mediumtext NOT NULL,
  `id` varchar(255) NOT NULL,
  `success` varchar(10) NOT NULL,
  `full_ret` mediumtext NOT NULL,
  `alter_time` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  KEY `id` (`id`),
  KEY `jid` (`jid`),
  KEY `fun` (`fun`),
  -- Salt's own DDL stops at the three keys above. Alcali orders by alter_time
  -- on nearly every query against this table - the jobs list, the states page,
  -- the retention counts - and without these that degrades into a full scan
  -- plus a filesort over two mediumtext columns once the history is large.
  -- The composite serves "this minion's most recent returns", which is what
  -- the minion detail and conformity pages ask for.
  KEY `alter_time` (`alter_time`),
  KEY `id_alter_time` (`id`, `alter_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `salt_events` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `tag` varchar(255) NOT NULL,
  `data` mediumtext NOT NULL,
  `alter_time` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `master_id` varchar(255) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `tag` (`tag`),
  -- Alcali's dashboard and the master's own keep_jobs_seconds pruning both
  -- scan this table by time; the demo schema has no index for it.
  KEY `alter_time` (`alter_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
