-- =============================================================================
-- pg_health_check.sql
-- Stand-alone PostgreSQL health & performance check.
--
-- Targets : self-managed PostgreSQL, Amazon RDS for PostgreSQL, Aurora PostgreSQL
-- Versions: PostgreSQL 12 - 18 (version differences are detected at run time).
--           Tested on 16, 17 and 18, each as primary and as streaming standby.
--           The Aurora-only branches were exercised with stand-in functions, not
--           on a real Aurora cluster.
-- Client  : psql 11 or newer (uses \if, \gset and :{?var})
--
-- WHAT IT DOES
--   Runs ONE read-only query that returns a prioritised list of findings:
--     severity | category | check_name | object_name | current_value | details
--              | recommended_action
--   ordered CRITICAL -> HIGH -> MEDIUM -> LOW -> INFO. The first row is a summary.
--
-- SAFETY (why it is fine to run on a busy production system)
--   * Creates nothing: no functions, views, temp tables or extensions. It therefore
--     also works on hot standbys and Aurora reader instances.
--   * The session is forced read-only and gets a statement_timeout.
--   * Reads only catalogs and statistics views. Sizes come from pg_class.relpages
--     (planner statistics) instead of pg_relation_size(), so no user table is
--     opened or locked and the script cannot queue behind a DDL lock.
--
-- HOW TO RUN
--   psql -X -q -x -h HOST -U USER -d DB -f pg_health_check.sql              # readable
--   psql -X -q --csv -h HOST -U USER -d DB -f pg_health_check.sql -o hc.csv # spreadsheet
--   psql -X -q -H    -h HOST -U USER -d DB -f pg_health_check.sql -o hc.html
--
--   Every threshold listed in section 1 can be overridden, e.g.
--   psql ... -v top_n=50 -v long_query_min=15 -v bloat_min_mb=500 -f pg_health_check.sql
--
-- SCOPE - read this once
--   * Instance-wide checks (connections, replication, settings, wraparound,
--     pg_stat_statements) are complete from any database.
--   * Table / index / sequence checks only see the database you are connected to.
--     Run the script once per application database.
--   * Usage counters (index scans, dead tuples, last analyze ...) are kept per
--     instance and are NOT replicated. On a standby / Aurora reader the script
--     skips the checks that would be meaningless there and tells you so. Run it
--     on the primary / writer for the full picture, and on readers before you
--     drop an "unused" index.
--   * Run as a superuser, rds_superuser or a member of pg_monitor. With fewer
--     privileges other sessions' activity and some settings are hidden; the
--     script reports that as a finding instead of failing.
--   * Bloat figures are estimates from planner statistics. Confirm with the
--     pgstattuple extension before a rewrite.
--   * Not visible from SQL and therefore NOT covered: host CPU, memory, swap,
--     disk latency and free space. Use OS tooling, or CloudWatch / Performance
--     Insights / Enhanced Monitoring on AWS.
-- =============================================================================

\set ON_ERROR_STOP on
\pset pager off

-- -----------------------------------------------------------------------------
-- 1. Thresholds. Each one keeps a value passed with "psql -v name=value".
-- -----------------------------------------------------------------------------
-- Maximum rows reported per check (keeps the report readable on huge schemas)
\if :{?top_n} \else \set top_n 20 \endif
-- Safety net for the report query itself
\if :{?hc_statement_timeout} \else \set hc_statement_timeout 120s \endif

-- Connections & activity
\if :{?conn_warn_pct} \else \set conn_warn_pct 75 \endif
\if :{?conn_crit_pct} \else \set conn_crit_pct 90 \endif
\if :{?max_conn_warn} \else \set max_conn_warn 500 \endif
\if :{?idle_tx_min} \else \set idle_tx_min 5 \endif
\if :{?idle_tx_crit_min} \else \set idle_tx_crit_min 60 \endif
\if :{?long_query_min} \else \set long_query_min 5 \endif
\if :{?long_query_crit_min} \else \set long_query_crit_min 60 \endif
\if :{?long_xact_min} \else \set long_xact_min 60 \endif
\if :{?lock_wait_sec} \else \set lock_wait_sec 30 \endif
\if :{?wait_pile_min} \else \set wait_pile_min 5 \endif
\if :{?xmin_age_warn} \else \set xmin_age_warn 1000000 \endif

-- Vacuum, wraparound, bloat
\if :{?xid_age_warn} \else \set xid_age_warn 500000000 \endif
\if :{?xid_age_high} \else \set xid_age_high 1000000000 \endif
\if :{?xid_age_crit} \else \set xid_age_crit 1500000000 \endif
\if :{?dead_tup_min} \else \set dead_tup_min 10000 \endif
\if :{?dead_pct_warn} \else \set dead_pct_warn 20 \endif
\if :{?dead_pct_high} \else \set dead_pct_high 50 \endif
\if :{?stale_mod_min} \else \set stale_mod_min 10000 \endif
\if :{?stale_pct_warn} \else \set stale_pct_warn 20 \endif
\if :{?bloat_min_mb} \else \set bloat_min_mb 100 \endif
\if :{?bloat_pct_warn} \else \set bloat_pct_warn 30 \endif
\if :{?idx_bloat_factor} \else \set idx_bloat_factor 2 \endif
\if :{?hot_upd_min} \else \set hot_upd_min 100000 \endif
\if :{?big_table_rows} \else \set big_table_rows 10000000 \endif
\if :{?big_table_gb} \else \set big_table_gb 100 \endif
\if :{?max_partitions} \else \set max_partitions 1000 \endif

-- Indexes & schema
\if :{?unused_idx_min_mb} \else \set unused_idx_min_mb 10 \endif
\if :{?fk_min_rows} \else \set fk_min_rows 10000 \endif
\if :{?seqscan_min_rows} \else \set seqscan_min_rows 100000 \endif
\if :{?seqscan_min} \else \set seqscan_min 100 \endif
\if :{?max_indexes} \else \set max_indexes 15 \endif
\if :{?seq_warn_pct} \else \set seq_warn_pct 75 \endif
\if :{?seq_crit_pct} \else \set seq_crit_pct 90 \endif

-- I/O, WAL, replication
\if :{?cache_hit_warn} \else \set cache_hit_warn 95 \endif
\if :{?cache_hit_high} \else \set cache_hit_high 85 \endif
\if :{?temp_gb_per_day} \else \set temp_gb_per_day 1 \endif
\if :{?deadlocks_per_day} \else \set deadlocks_per_day 1 \endif
\if :{?rollback_pct_warn} \else \set rollback_pct_warn 10 \endif
\if :{?ckpt_req_pct_warn} \else \set ckpt_req_pct_warn 30 \endif
\if :{?slot_wal_gb} \else \set slot_wal_gb 10 \endif
\if :{?repl_lag_mb} \else \set repl_lag_mb 100 \endif
\if :{?repl_lag_sec} \else \set repl_lag_sec 60 \endif
\if :{?aurora_lag_ms} \else \set aurora_lag_ms 1000 \endif

-- pg_stat_statements
\if :{?pss_top} \else \set pss_top 10 \endif
\if :{?pss_share_warn} \else \set pss_share_warn 20 \endif
\if :{?pss_mean_ms} \else \set pss_mean_ms 1000 \endif

-- -----------------------------------------------------------------------------
-- 2. Session guard rails.
--    set_config() + \gset is used instead of SET so that nothing is printed and
--    CSV / HTML output stays clean. The previous values are restored at the end.
-- -----------------------------------------------------------------------------
select current_setting('statement_timeout')              as hc_old_statement_timeout,
       current_setting('default_transaction_read_only')  as hc_old_read_only
\gset
select set_config('statement_timeout', :'hc_statement_timeout', false) as hc_x1,
       set_config('default_transaction_read_only', 'on', false)        as hc_x2
\gset

-- -----------------------------------------------------------------------------
-- 3. Feature detection.
--    Catalog views differ between versions and platforms. A query that names a
--    view that does not exist fails at parse time, so the script first finds out
--    what is available and then plugs the matching sub-query into the report.
-- -----------------------------------------------------------------------------
select current_setting('server_version_num')::int >= 170000 as hc_pg17,   -- pg_stat_checkpointer
       current_setting('server_version_num')::int >= 160000 as hc_pg16,   -- pg_stat_io
       current_setting('server_version_num')::int >= 140000 as hc_pg14,   -- pg_stat_wal
       exists (select 1 from pg_proc where proname = 'aurora_version')        as hc_is_aurora,
       exists (select 1 from pg_proc where proname = 'aurora_replica_status') as hc_aurora_status,
       exists (select 1 from pg_roles where rolname = 'rds_superuser')        as hc_is_rds,
       -- pg_stat_statements is usable only if the extension exists in THIS database
       -- AND the library was preloaded (otherwise the view raises an error).
       -- shared_preload_libraries is hidden from unprivileged roles: read it through
       -- pg_settings, which then simply returns no row instead of failing.
       exists (select 1 from pg_extension where extname = 'pg_stat_statements')
         and coalesce((select setting from pg_settings where name = 'shared_preload_libraries'), '')
             like '%pg_stat_statements%'                                             as hc_has_pss,
       coalesce((select quote_ident(n.nspname)
                   from pg_extension e
                   join pg_namespace n on n.oid = e.extnamespace
                  where e.extname = 'pg_stat_statements'), 'public')                 as hc_pss_schema
\gset

-- Checkpoint counters: pg_stat_bgwriter up to v16, pg_stat_checkpointer from v17
\if :hc_pg17
  \set hc_q_ckpt 'select num_timed::numeric as timed, num_requested::numeric as req, stats_reset from pg_stat_checkpointer'
\else
  \set hc_q_ckpt 'select checkpoints_timed::numeric as timed, checkpoints_req::numeric as req, stats_reset from pg_stat_bgwriter'
\endif

-- fsync calls on data files made by ordinary backends: pg_stat_io from v16,
-- pg_stat_bgwriter before. (object = 'relation' matters: from v18 pg_stat_io also
-- counts WAL, and backends fsync WAL at every commit, which is normal.)
\if :hc_pg16
  \set hc_q_bfsync 'select coalesce(sum(fsyncs), 0)::numeric as n from pg_stat_io where backend_type = ''client backend'' and object = ''relation'''
\else
  \set hc_q_bfsync 'select buffers_backend_fsync::numeric as n from pg_stat_bgwriter'
\endif

-- WAL statistics (v14+). Read as JSON so that columns dropped in v18 do not matter.
\if :hc_pg14
  \set hc_q_wal 'select to_jsonb(w) as j from pg_stat_wal w'
\else
  \set hc_q_wal 'select null::jsonb as j where false'
\endif

-- pg_stat_statements, read as JSON: column names changed in v13 and again in v17
\if :hc_has_pss
  \set hc_q_pss 'select to_jsonb(p) as j from ' :hc_pss_schema '.pg_stat_statements p'
\else
  \set hc_q_pss 'select null::jsonb as j where false'
\endif

-- Aurora only: engine version and per-instance replica lag
\if :hc_is_aurora
  \set hc_q_aurora_version 'select aurora_version()::text as v'
\else
  \set hc_q_aurora_version 'select null::text as v'
\endif
\if :hc_aurora_status
  \set hc_q_aurora_status 'select to_jsonb(r) as j from aurora_replica_status() r'
\else
  \set hc_q_aurora_status 'select null::jsonb as j where false'
\endif

-- -----------------------------------------------------------------------------
-- 4. The report. One statement: building blocks first, then one SELECT per
--    check glued together with UNION ALL, then the final sort.
-- -----------------------------------------------------------------------------
with
-- ---- building blocks --------------------------------------------------------
s as (              -- all settings, looked up by name so a missing one is just NULL
  select name, setting, unit, boot_val, pending_restart from pg_settings
),
env as (            -- where are we running?
  select pg_is_in_recovery()                                as in_recovery,
         :'hc_is_aurora'::boolean                           as is_aurora,
         :'hc_is_rds'::boolean                              as is_rds,
         current_setting('server_version_num')::int / 10000 as major,
         current_setting('block_size')::bigint              as bs,
         -- "now" in WAL terms; pg_current_wal_lsn() is not allowed on a standby
         case when pg_is_in_recovery() then pg_last_wal_replay_lsn()
              else pg_current_wal_lsn() end                 as cur_lsn,
         (select rolsuper from pg_roles where rolname = current_user)
           or pg_has_role(current_user, 'pg_monitor', 'member') as can_monitor
),
cfg as (            -- settings converted to plain numbers (bytes where it is a size)
  select (select setting::bigint from s where name = 'max_connections')                  as max_conn,
         (select setting::bigint from s where name = 'superuser_reserved_connections')   as reserved_conn,
         (select setting::bigint from s where name = 'autovacuum_max_workers')           as av_workers,
         (select setting::numeric from s where name = 'autovacuum_vacuum_scale_factor')  as av_scale,
         (select setting::bigint from s where name = 'shared_buffers') * env.bs          as shared_buffers,
         (select setting::bigint from s where name = 'work_mem') * 1024                  as work_mem,
         (select setting::bigint from s where name = 'maintenance_work_mem') * 1024      as maint_work_mem,
         (select setting::bigint from s where name = 'max_wal_size') * 1024 * 1024       as max_wal_size,
         (select setting::numeric from s where name = 'random_page_cost')                as random_page_cost
    from env
),
dbs as (            -- cumulative statistics of the current database
  select d.*,
         to_jsonb(d) as j,
         -- age of the counters in days (minimum 1) to turn totals into daily rates
         greatest(extract(epoch from now() - coalesce(d.stats_reset, pg_postmaster_start_time())) / 86400.0, 1) as days
    from pg_stat_database d
   where d.datname = current_database()
),
act as (            -- every session except this one
  select a.*,
         extract(epoch from now() - a.query_start)  as query_sec,
         extract(epoch from now() - a.xact_start)   as xact_sec,
         extract(epoch from now() - a.state_change) as state_sec,
         'pid ' || a.pid || ' ' || coalesce(a.usename::text, '?') || '@' || coalesce(a.datname::text, '?')
           || coalesce(' app=' || nullif(a.application_name, ''), '') as who,
         left(regexp_replace(coalesce(a.query, ''), '\s+', ' ', 'g'), 200) as q
    from pg_stat_activity a
   where a.pid <> pg_backend_pid()
),
blk as (            -- who is waiting for whose lock (only sessions in a lock wait)
  select a.pid, a.who, a.q, a.query_sec, pg_blocking_pids(a.pid) as blockers
    from act a
   where a.wait_event_type = 'Lock'
),
tbl as (            -- user tables, materialized views and partitioned tables
  select c.oid, n.nspname, c.relname, format('%I.%I', n.nspname, c.relname) as fq,
         c.relkind, c.relpersistence, c.relispartition, c.reloptions,
         c.relfrozenxid, c.relminmxid,
         greatest(c.reltuples, 0)::numeric as reltuples,     -- -1 means "never analyzed"
         c.relpages::bigint                as relpages,
         c.relpages::bigint * env.bs       as bytes,         -- heap only, from planner stats
         st.seq_scan, st.seq_tup_read, st.idx_scan,
         st.n_tup_upd, st.n_tup_hot_upd, st.n_live_tup, st.n_dead_tup, st.n_mod_since_analyze,
         st.last_vacuum, st.last_autovacuum, st.last_analyze, st.last_autoanalyze
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    left join pg_stat_all_tables st on st.relid = c.oid
    cross join env
   where c.relkind in ('r', 'm', 'p')
     and n.nspname not in ('pg_catalog', 'information_schema')
     and n.nspname !~ '^pg_(toast|temp)'
),
idx as (            -- indexes on those tables
  select i.indexrelid, i.indrelid, t.fq as table_fq, t.nspname, t.relname as table_name,
         ci.relname as index_name, format('%I.%I', t.nspname, ci.relname) as fq,
         am.amname, i.indisunique, i.indisprimary, i.indisvalid, i.indisready,
         i.indnatts, i.indnkeyatts, i.indkey, i.indclass, i.indoption, i.indcollation,
         i.indexprs, i.indpred,
         greatest(ci.reltuples, 0)::numeric as reltuples,
         ci.relpages::bigint                as relpages,
         ci.relpages::bigint * env.bs       as bytes,
         ci.reloptions,
         coalesce(si.idx_scan, 0)           as idx_scan,
         -- true when the index implements a PRIMARY KEY / UNIQUE / EXCLUDE constraint
         exists (select 1 from pg_constraint k where k.conindid = i.indexrelid) as backs_constraint
    from pg_index i
    join tbl t        on t.oid = i.indrelid
    join pg_class ci  on ci.oid = i.indexrelid
    join pg_am am     on am.oid = ci.relam
    left join pg_stat_all_indexes si on si.indexrelid = i.indexrelid
    cross join env
),
tbl_idx as (        -- index count and total index size per table
  select indrelid, count(*) as n_idx, sum(bytes) as idx_bytes from idx group by indrelid
),
tbl_bloat as (      -- expected heap size from column statistics vs. actual size
  select x.*, (x.relpages - x.expected_pages) * env.bs as wasted_bytes
    from (
      select t.fq, t.relpages, t.reltuples, t.n_dead_tup, t.last_autovacuum, t.last_vacuum,
             -- rows * (24 byte header + 4 byte line pointer + avg data + ~4 padding)
             -- divided by the usable part of a page at the table's fillfactor
             ceil(t.reltuples * (32 + w.row_width)
                  / ((env.bs - 24) * coalesce((select substring(o from '=(\d+)')::numeric
                                                 from unnest(t.reloptions) o
                                                where o like 'fillfactor=%'), 100) / 100.0)) as expected_pages
        from tbl t
        cross join env
        cross join lateral (select sum((1 - ps.null_frac) * ps.avg_width)::numeric as row_width
                              from pg_stats ps
                             where ps.schemaname = t.nspname
                               and ps.tablename  = t.relname
                               and not ps.inherited) w
       where t.relkind in ('r', 'm') and t.reltuples > 0 and w.row_width is not null
    ) x cross join env
),
idx_bloat as (      -- same idea for plain b-tree indexes (no expressions)
  select x.*, (x.relpages - x.expected_pages) * env.bs as wasted_bytes
    from (
      select i.fq, i.table_fq, i.relpages, i.reltuples,
             -- entries * (8 byte header + aligned key + 4 byte line pointer) / 90 % of a page
             ceil(i.reltuples * (12 + ceil(w.key_width / 8.0) * 8) / ((env.bs - 40) * 0.9)) + 1 as expected_pages
        from idx i
        cross join env
        cross join lateral (select sum(ps.avg_width)::numeric as key_width, count(*) as n
                              from pg_attribute a
                              join pg_stats ps on ps.schemaname = i.nspname
                                              and ps.tablename  = i.table_name
                                              and ps.attname    = a.attname
                                              and not ps.inherited
                             where a.attrelid = i.indrelid
                               and a.attnum = any ((i.indkey::int2[])[0 : i.indnkeyatts - 1])) w
       where i.amname = 'btree' and i.indexprs is null and i.indisvalid
         and i.reltuples > 0 and w.n = i.indnkeyatts
    ) x cross join env
),
seqs as (           -- sequences with the real ceiling: the smaller of the sequence's
                    -- MAXVALUE and the range of the column it feeds (int2 / int4)
  select format('%I.%I', q.schemaname, q.sequencename) as fq,
         q.last_value, q.max_value,
         least(q.max_value, case a.atttypid when 21 then 32767 when 23 then 2147483647 end) as eff_max,
         case when a.attname is not null     -- NULL for a free-standing sequence
              then format('%I.%I.%I', q.schemaname, tc.relname, a.attname)
                   || ' (' || format_type(a.atttypid, a.atttypmod) || ')' end as feeds
    from pg_sequences q
    join pg_namespace n on n.nspname = q.schemaname
    join pg_class c     on c.relnamespace = n.oid and c.relname = q.sequencename and c.relkind = 'S'
    left join pg_depend d on d.classid = 'pg_class'::regclass and d.objid = c.oid
                         and d.refclassid = 'pg_class'::regclass and d.refobjsubid > 0
                         and d.deptype in ('a', 'i')
    left join pg_class tc     on tc.oid = d.refobjid
    left join pg_attribute a  on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
   where q.increment_by > 0 and not q.cycle and q.last_value is not null
),
slots as (          -- replication slots and how much WAL each one pins
  select rs.slot_name, rs.slot_type, rs.active, rs.temporary, rs.xmin, rs.catalog_xmin,
         to_jsonb(rs) ->> 'wal_status' as wal_status,            -- v13+
         pg_wal_lsn_diff(env.cur_lsn, rs.restart_lsn) as retained_bytes
    from pg_replication_slots rs cross join env
),
xmin_holders as (   -- everything that can stop VACUUM from removing dead rows
  select 'session ' || a.who || ' state=' || coalesce(a.state, '?') as holder, age(a.backend_xmin) as xage
    from act a where a.backend_xmin is not null
  union all
  select 'replication slot ' || slot_name, greatest(age(xmin), age(catalog_xmin))
    from slots where xmin is not null or catalog_xmin is not null
  union all
  select 'prepared transaction ' || gid, age(transaction) from pg_prepared_xacts
  union all
  select 'standby feedback from ' || coalesce(nullif(application_name, ''), 'pid ' || pid), age(backend_xmin)
    from pg_stat_replication where backend_xmin is not null
),
ckpt   as (:hc_q_ckpt),
bfsync as (:hc_q_bfsync),
wal    as (:hc_q_wal),
aurora_version as (:hc_q_aurora_version),
aurora_status  as (:hc_q_aurora_status),
pss as (            -- pg_stat_statements with version-independent column names
  select x.j ->> 'queryid'                                               as queryid,
         coalesce(d.datname::text, 'db ' || (x.j ->> 'dbid'))            as dbname,
         left(regexp_replace(coalesce(x.j ->> 'query', ''), '\s+', ' ', 'g'), 200) as q,
         (x.j ->> 'calls')::numeric                                      as calls,
         coalesce(x.j ->> 'total_exec_time', x.j ->> 'total_time')::numeric as total_ms,
         coalesce(x.j ->> 'mean_exec_time',  x.j ->> 'mean_time')::numeric  as mean_ms,
         (x.j ->> 'rows')::numeric                                       as n_rows,
         (x.j ->> 'shared_blks_hit')::numeric                            as blks_hit,
         (x.j ->> 'shared_blks_read')::numeric                           as blks_read,
         (x.j ->> 'temp_blks_written')::numeric                          as temp_blks
    from (:hc_q_pss) x
    left join pg_database d on d.oid = (x.j ->> 'dbid')::oid
   where (x.j ->> 'calls')::numeric > 0
),
pss_total as (select nullif(sum(total_ms), 0) as total_ms from pss),

-- ---- the checks -------------------------------------------------------------
-- Columns: sev, category, check_name, object_name, current_value, details,
--          action, ord (bigger = listed first inside the same check)
findings (sev, category, check_name, object_name, current_value, details, action, ord) as (

  -- ===========================================================================
  -- A. INSTANCE OVERVIEW (context for everything else)
  -- ===========================================================================
  select 'INFO'::text, 'Instance'::text, 'Version and platform'::text, 'instance'::text,
         current_setting('server_version')
           || case when env.is_aurora then ' / Aurora PostgreSQL ' || coalesce((select v from aurora_version), '')
                   when env.is_rds    then ' / Amazon RDS'
                   else ' / self-managed' end
           || case when env.in_recovery then ' / REPLICA (read-only)' else ' / PRIMARY (writer)' end,
         'Started ' || to_char(pg_postmaster_start_time(), 'YYYY-MM-DD HH24:MI TZ')
           || coalesce(', statistics of this database counted since '
                       || to_char((select stats_reset from dbs), 'YYYY-MM-DD HH24:MI TZ'),
                       ', statistics of this database never reset'),
         'None. Context for the findings below.'::text,
         null::numeric
    from env

  union all
  select 'INFO', 'Instance', 'Database size', current_database(),
         pg_size_pretty(pg_database_size(current_database())),
         'Total size of the connected database.', 'None. Track growth over time.', null
  union all
  (select 'INFO', 'Instance', 'Largest tables', t.fq,
          pg_size_pretty(t.bytes + coalesce(ti.idx_bytes, 0)) || ' (heap ' || pg_size_pretty(t.bytes)
            || ', indexes ' || pg_size_pretty(coalesce(ti.idx_bytes, 0)) || ', ~' || t.reltuples::bigint || ' rows)',
          'Biggest relations by heap + index size (TOAST excluded, taken from planner statistics).',
          'None. These are where bloat, missing indexes and vacuum lag hurt most.',
          t.bytes + coalesce(ti.idx_bytes, 0)
     from tbl t left join tbl_idx ti on ti.indrelid = t.oid
    where t.relkind <> 'p' and t.bytes > 0
    order by 8 desc limit 5)

  union all   -- the script cannot judge what it cannot see
  select 'LOW', 'Instance', 'Limited visibility', current_user::text,
         'not a superuser and not a member of pg_monitor',
         'Other sessions'' queries, replication details, sequence positions and some settings are hidden, so activity, locking, replication and sequence checks may silently find nothing.',
         'Run as a monitoring role: GRANT pg_monitor TO ' || quote_ident(current_user) || ';', null
    from env where not env.can_monitor

  union all   -- most checks below read replicated catalogs, some read local counters
  select 'INFO', 'Instance', 'Connected to a replica', 'instance',
         'pg_is_in_recovery() = true',
         'Usage counters are per instance. Dead-tuple, analyze, HOT-update and autovacuum checks are skipped here because the work happens on the primary / writer.',
         'Run this script on the primary / writer as well.', null
    from env where env.in_recovery

  union all   -- rates computed from young counters are noisy
  select 'LOW', 'Instance', 'Statistics were reset recently', current_database(),
         'reset ' || to_char(dbs.stats_reset, 'YYYY-MM-DD HH24:MI TZ'),
         'Cumulative counters are less than a day old. Unused-index, sequential-scan, cache-hit and temp-file findings are not yet reliable.',
         'Re-run after the workload has gone through at least one full business cycle.', null
    from dbs where dbs.stats_reset > now() - interval '1 day'

  union all   -- community support ends 5 years after release
  select case when env.major <= 13 then 'HIGH' else 'MEDIUM' end, 'Instance', 'PostgreSQL major version end-of-life',
         'instance', 'major version ' || env.major,
         'PostgreSQL 13 and older no longer get fixes; PostgreSQL 14 reaches end-of-life in November 2026. RDS / Aurora move such versions to paid Extended Support or force an upgrade.',
         'Plan a major version upgrade (pg_upgrade, logical replication, or RDS/Aurora blue-green deployment).', null
    from env where env.major <= 14

  union all
  select 'LOW', 'Instance', 'Setting change waiting for restart', s.name,
         'pending_restart = true', 'The value was changed but the running server still uses the old one.',
         'Restart / reboot the instance in a maintenance window.', null
    from s where s.pending_restart

  -- ===========================================================================
  -- B. CONNECTIONS AND RUNNING ACTIVITY (a snapshot of "right now")
  -- ===========================================================================
  union all   -- running out of connection slots = new clients get errors
  select case when c.pct >= :conn_crit_pct then 'CRITICAL' else 'HIGH' end,
         'Connections', 'Connection slots nearly exhausted', 'instance',
         c.used || ' of ' || c.usable || ' usable connections (' || round(c.pct, 1) || '%)',
         'active ' || c.n_active || ', idle ' || c.n_idle || ', idle in transaction ' || c.n_idle_tx
           || '. New connections fail once the limit is reached.',
         'Put a pooler in front (PgBouncer, RDS Proxy), close leaked connections, and only then consider raising max_connections.',
         c.pct
    from (select count(*) as used,
                 count(*) filter (where state = 'active') as n_active,
                 count(*) filter (where state = 'idle') as n_idle,
                 count(*) filter (where state like 'idle in transaction%') as n_idle_tx,
                 (select max_conn - reserved_conn from cfg) as usable,
                 count(*) * 100.0 / nullif((select max_conn - reserved_conn from cfg), 0) as pct
            from pg_stat_activity where backend_type = 'client backend') c
   where c.pct >= :conn_warn_pct

  union all   -- each idle backend still costs memory and makes snapshots slower
  select 'LOW', 'Connections', 'Many idle connections', 'instance',
         c.n_idle || ' idle of ' || c.used || ' client connections',
         'Most connections are doing nothing. Each one holds memory and adds overhead to every snapshot.',
         'Use transaction-level connection pooling (PgBouncer, RDS Proxy) and shrink application pool sizes.',
         c.n_idle
    from (select count(*) as used, count(*) filter (where state = 'idle') as n_idle
            from pg_stat_activity where backend_type = 'client backend') c
   where c.used >= 100 and c.n_idle >= 0.8 * c.used

  union all
  select 'LOW', 'Connections', 'max_connections is very high', 'max_connections', cfg.max_conn::text,
         'Hundreds of direct connections cause lock-manager and snapshot contention long before CPU is exhausted.',
         'Keep max_connections modest and multiplex clients through a pooler.', null
    from cfg where cfg.max_conn >= :max_conn_warn

  union all   -- an open transaction that does nothing blocks vacuum and holds locks
  (select case when a.state_sec >= :idle_tx_crit_min * 60 then 'CRITICAL' else 'HIGH' end,
          'Connections', 'Idle in transaction', a.who,
          'idle for ' || round(a.state_sec / 60) || ' min, transaction open ' || round(a.xact_sec / 60) || ' min',
          'The session opened a transaction and stopped. It keeps its locks and stops VACUUM from cleaning rows. Last statement: ' || a.q,
          'Fix the application (missing COMMIT / ROLLBACK). Stop it with SELECT pg_terminate_backend(' || a.pid
            || '); and set idle_in_transaction_session_timeout.',
          a.state_sec
     from act a
    where a.state like 'idle in transaction%' and a.state_sec >= :idle_tx_min * 60
    order by 8 desc limit :top_n)

  union all
  (select case when a.query_sec >= :long_query_crit_min * 60 then 'HIGH' else 'MEDIUM' end,
          'Connections', 'Long-running query', a.who,
          'running ' || round(a.query_sec / 60) || ' min'
            || coalesce(', waiting on ' || a.wait_event_type || ':' || a.wait_event, ''),
          a.q,
          'Check the plan with EXPLAIN (ANALYZE, BUFFERS). Cancel with SELECT pg_cancel_backend(' || a.pid
            || '); Consider statement_timeout for the application role.',
          a.query_sec
     from act a
    where a.state = 'active' and a.backend_type = 'client backend' and a.query_sec >= :long_query_min * 60
    order by 8 desc limit :top_n)

  union all   -- many short statements inside one very old transaction
  (select 'MEDIUM', 'Connections', 'Long-running transaction', a.who,
          'transaction open ' || round(a.xact_sec / 60) || ' min',
          'A long transaction pins the oldest visible row version, so VACUUM cannot clean up behind it. Current statement: ' || a.q,
          'Break batch jobs into smaller transactions; move reporting to a replica.',
          a.xact_sec
     from act a
    where a.state = 'active' and a.backend_type = 'client backend'
      and a.xact_sec >= :long_xact_min * 60 and a.query_sec < :long_query_min * 60
    order by 8 desc limit :top_n)

  union all   -- two-phase transactions survive restarts and are easy to forget
  select 'HIGH', 'Connections', 'Orphaned prepared transaction', p.gid,
         'prepared ' || to_char(p.prepared, 'YYYY-MM-DD HH24:MI') || ' by ' || p.owner || ' in ' || p.database,
         'A PREPARE TRANSACTION that was never committed keeps locks and blocks VACUUM indefinitely, even across restarts.',
         'Resolve it: COMMIT PREPARED ''' || p.gid || '''; or ROLLBACK PREPARED ''' || p.gid || ''';',
         null
    from pg_prepared_xacts p
   where p.prepared < now() - :long_xact_min * interval '1 minute'

  union all   -- snapshot of what active sessions are stuck on
  select 'MEDIUM', 'Connections', 'Sessions piling up on one wait event',
         w.wait_event_type || ':' || w.wait_event, w.n || ' active sessions waiting',
         'Several sessions wait on the same thing at this instant. Lock = row/table locks, LWLock = internal contention, IO = storage, IPC = parallel workers or replication.',
         'Sample again a few times. Persistent Lock waits -> see the Locks findings; LWLock -> fewer connections / pooling; IO -> storage throughput or missing indexes.',
         w.n
    from (select wait_event_type, wait_event, count(*) as n
            from act
           where state = 'active' and backend_type = 'client backend'
             and wait_event_type in ('Lock', 'LWLock', 'IO', 'IPC', 'BufferPin')
           group by 1, 2) w
   where w.n >= :wait_pile_min

  -- ===========================================================================
  -- C. LOCKS
  -- ===========================================================================
  union all   -- the head of a blocking chain: fix this one and the queue drains
  (select 'HIGH', 'Locks', 'Blocking session (head of the queue)', a.who,
          'blocks ' || r.victims || ' session(s); state ' || coalesce(a.state, '?')
            || ', transaction open ' || coalesce(round(a.xact_sec / 60)::text, '?') || ' min',
          'This session is not waiting for anyone but others wait for it. Its statement: ' || a.q,
          'Let it finish or stop it: SELECT pg_terminate_backend(' || a.pid || '); Use lock_timeout for DDL.',
          r.victims
     from (select b.blocker, count(*) as victims
             from (select unnest(blockers) as blocker from blk) b
            where b.blocker not in (select pid from blk where cardinality(blockers) > 0)
            group by 1) r
     join act a on a.pid = r.blocker
    order by 8 desc limit :top_n)

  union all
  (select case when b.query_sec >= :lock_wait_sec then 'HIGH' else 'MEDIUM' end,
          'Locks', 'Session blocked by a lock', b.who,
          'waiting, statement started ' || round(b.query_sec) || ' s ago; blocked by pid(s) ' || array_to_string(b.blockers, ', '),
          b.q,
          'Look at the blocking session above. Enable log_lock_waits to record these in the server log.',
          b.query_sec
     from blk b where cardinality(b.blockers) > 0
    order by 8 desc limit :top_n)

  union all
  select case when dbs.deadlocks / dbs.days >= :deadlocks_per_day then 'MEDIUM' else 'LOW' end,
         'Locks', 'Deadlocks', dbs.datname::text,
         dbs.deadlocks || ' deadlocks (' || round((dbs.deadlocks / dbs.days)::numeric, 1) || ' per day)',
         'PostgreSQL resolved these by aborting one transaction each time. The application saw an error.',
         'Make transactions touch rows in a consistent order; details are in the server log (search "deadlock detected").',
         dbs.deadlocks
    from dbs where dbs.deadlocks > 0

  -- ===========================================================================
  -- D. TRANSACTION-ID WRAPAROUND (the one problem that can stop all writes)
  -- ===========================================================================
  union all
  select case when x.a >= :xid_age_crit then 'CRITICAL' when x.a >= :xid_age_high then 'HIGH' else 'MEDIUM' end,
         'Wraparound', 'Database transaction-ID age', x.datname::text,
         x.a || ' (' || round(x.a / 2147483647.0 * 100, 1) || '% of the 2.1 billion limit)',
         'Old row versions must be frozen by VACUUM before the 32-bit transaction counter wraps. Close to the limit PostgreSQL refuses writes.',
         'Find what holds vacuum back (see "Oldest snapshot holders" and the per-table list), then VACUUM (FREEZE, VERBOSE) the oldest tables.',
         x.a
    from (select datname, age(datfrozenxid)::bigint as a from pg_database where datallowconn) x
   where x.a >= :xid_age_warn

  union all
  select case when x.a >= :xid_age_crit then 'CRITICAL' when x.a >= :xid_age_high then 'HIGH' else 'MEDIUM' end,
         'Wraparound', 'Database multixact-ID age', x.datname::text,
         x.a || ' (' || round(x.a / 2147483647.0 * 100, 1) || '% of the limit)',
         'Multixact IDs (shared row locks, typically foreign-key checks and SELECT ... FOR SHARE) wrap around the same way transaction IDs do.',
         'VACUUM (FREEZE) the affected tables; check that autovacuum is not being cancelled.',
         x.a
    from (select datname, mxid_age(datminmxid)::bigint as a from pg_database where datallowconn) x
   where x.a >= :xid_age_warn

  union all   -- which tables (including TOAST) are responsible in this database
  (select case when x.a >= :xid_age_crit then 'CRITICAL' when x.a >= :xid_age_high then 'HIGH' else 'MEDIUM' end,
          'Wraparound', 'Table transaction-ID age', x.fq,
          x.a || ' transactions old, ' || pg_size_pretty(x.bytes),
          'This table holds the oldest unfrozen rows of the database.',
          'VACUUM (FREEZE, VERBOSE) ' || x.fq || ';',
          x.a
     from (select format('%I.%I', n.nspname, c.relname) as fq, age(c.relfrozenxid)::bigint as a,
                  c.relpages::bigint * env.bs as bytes
             from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join env
            where c.relkind in ('r', 'm', 't') and c.relfrozenxid <> '0'::xid) x
    where x.a >= :xid_age_warn
    order by 8 desc limit :top_n)

  union all   -- why vacuum cannot clean: something still needs the old rows
  (select case when h.xage >= :xmin_age_warn::bigint * 50 then 'HIGH' else 'MEDIUM' end,
          'Vacuum', 'Oldest snapshot holders (xmin horizon)', h.holder,
          'holds back cleanup by ' || h.xage || ' transactions',
          'VACUUM cannot remove any row version newer than the oldest snapshot in the system. Until this holder goes away, dead rows and bloat accumulate in every table.',
          'End the session / transaction, drop the unused replication slot, or fix the lagging standby that uses hot_standby_feedback.',
          h.xage
     from xmin_holders h
    where h.xage >= :xmin_age_warn
    order by 8 desc limit :top_n)

  -- ===========================================================================
  -- E. VACUUM AND STATISTICS
  -- ===========================================================================
  union all
  select 'CRITICAL', 'Vacuum', 'Autovacuum switched off', s.name, s.setting,
         'Without autovacuum (and the row counters it relies on) dead rows are never cleaned, statistics go stale and wraparound protection is lost.',
         'Set ' || s.name || ' = on (parameter group on RDS / Aurora).', null
    from s where s.name in ('autovacuum', 'track_counts') and s.setting = 'off'

  union all
  (select 'HIGH', 'Vacuum', 'Autovacuum disabled on a table', t.fq,
          array_to_string(t.reloptions, ', ') || '; ~' || t.reltuples::bigint || ' rows, ' || pg_size_pretty(t.bytes),
          'The table is excluded from automatic cleanup and analyze.',
          'ALTER TABLE ' || t.fq || ' RESET (autovacuum_enabled); unless a job vacuums it explicitly.',
          t.bytes
     from tbl t
    where exists (select 1 from unnest(t.reloptions) o where o ~* '^autovacuum_enabled=(false|off|no|0)$')
    order by 8 desc limit :top_n)

  union all   -- primary only: dead-row counters are not replicated
  (select case when d.pct >= :dead_pct_high then 'HIGH' else 'MEDIUM' end,
          'Vacuum', 'Many dead rows', d.fq,
          d.n_dead_tup || ' dead vs ' || d.n_live_tup || ' live rows (' || round(d.pct, 1) || '% dead)',
          'Last autovacuum: ' || coalesce(to_char(d.last_autovacuum, 'YYYY-MM-DD HH24:MI'), 'never')
            || ', last manual vacuum: ' || coalesce(to_char(d.last_vacuum, 'YYYY-MM-DD HH24:MI'), 'never')
            || '. Dead rows make scans read pages that return nothing.',
          'VACUUM (VERBOSE) ' || d.fq || '; If it removes little, look at "Oldest snapshot holders". For hot tables lower autovacuum_vacuum_scale_factor per table.',
          d.n_dead_tup
     from (select t.*, t.n_dead_tup * 100.0 / nullif(t.n_live_tup + t.n_dead_tup, 0) as pct from tbl t) d
     cross join env
    where not env.in_recovery and d.n_dead_tup >= :dead_tup_min and d.pct >= :dead_pct_warn
    order by 8 desc limit :top_n)

  union all   -- all workers busy = tables wait in line for cleanup
  select 'MEDIUM', 'Vacuum', 'All autovacuum workers busy', 'instance',
         w.n || ' of ' || cfg.av_workers || ' workers running',
         'Every autovacuum slot is in use right now. If this is the normal state, cleanup is falling behind.',
         'Raise autovacuum_vacuum_cost_limit (lets workers go faster) before raising autovacuum_max_workers.', null
    from (select count(*) as n from pg_stat_activity where backend_type = 'autovacuum worker') w cross join cfg
   where w.n >= cfg.av_workers

  union all
  (select case when a.query like '%to prevent wraparound%' then 'MEDIUM' else 'LOW' end,
          'Vacuum', 'Long-running autovacuum', coalesce(pv.relid::regclass::text, a.who),
          'running ' || round(a.query_sec / 60) || ' min'
            || coalesce(', phase ' || pv.phase || ', ' || round(pv.heap_blks_scanned * 100.0 / nullif(pv.heap_blks_total, 0)) || '% of heap scanned', ''),
          a.q || case when a.query like '%to prevent wraparound%'
                      then ' -- an anti-wraparound vacuum does not give way to DDL that needs the table' else '' end,
          'Usually just let it finish. If it is routinely this slow, raise autovacuum_vacuum_cost_limit and maintenance_work_mem.',
          a.query_sec
     from act a left join pg_stat_progress_vacuum pv on pv.pid = a.pid
    where a.backend_type = 'autovacuum worker' and a.query_sec >= :long_xact_min * 60
    order by 8 desc limit :top_n)

  union all   -- the planner guesses blindly without statistics
  (select 'MEDIUM', 'Statistics', 'Table never analyzed', t.fq,
          '~' || t.n_live_tup || ' rows, never analyzed',
          'There are no planner statistics, so row estimates and join plans for this table are guesses.',
          'ANALYZE ' || t.fq || ';',
          t.n_live_tup
     from tbl t cross join env
    where not env.in_recovery and t.relkind in ('r', 'm')
      and t.last_analyze is null and t.last_autoanalyze is null and t.n_live_tup >= 1000
    order by 8 desc limit :top_n)

  union all
  (select 'MEDIUM', 'Statistics', 'Stale planner statistics', t.fq,
          t.n_mod_since_analyze || ' rows changed since last analyze (~' || t.reltuples::bigint || ' rows in table)',
          'Last analyze: ' || coalesce(to_char(greatest(t.last_analyze, t.last_autoanalyze), 'YYYY-MM-DD HH24:MI'), 'never')
            || '. Plans are based on an outdated picture of the data.',
          'ANALYZE ' || t.fq || '; For large tables lower autovacuum_analyze_scale_factor per table.',
          t.n_mod_since_analyze
     from tbl t cross join env
    where not env.in_recovery
      and (t.last_analyze is not null or t.last_autoanalyze is not null)
      and t.n_mod_since_analyze >= :stale_mod_min
      and t.n_mod_since_analyze >= :stale_pct_warn / 100.0 * greatest(t.reltuples, 1)
    order by 8 desc limit :top_n)

  union all   -- default 20 % trigger is far too lazy for very large tables
  select 'LOW', 'Vacuum', 'Autovacuum trigger too lazy for big tables', 'autovacuum_vacuum_scale_factor',
         cfg.av_scale || ' with ' || b.n || ' table(s) over ' || :big_table_rows || ' rows (largest ' || b.biggest || ')',
         'With a ' || round(cfg.av_scale * 100) || '% trigger a 100-million-row table collects '
           || round(cfg.av_scale * 100) || ' million dead rows before autovacuum even starts.',
         'Per table: ALTER TABLE ... SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_analyze_scale_factor = 0.01);',
         null
    from cfg
    cross join (select count(*) as n, (array_agg(t.fq order by t.reltuples desc))[1] as biggest
                  from tbl t
                 where t.reltuples >= :big_table_rows
                   and not exists (select 1 from unnest(t.reloptions) o where o like 'autovacuum_vacuum_scale_factor=%')) b
   where cfg.av_scale >= 0.1 and b.n > 0

  -- ===========================================================================
  -- F. BLOAT (estimates - space that holds no live data)
  -- ===========================================================================
  union all
  (select case when b.wasted_bytes >= 10 * :bloat_min_mb * 1024 * 1024::bigint then 'MEDIUM' else 'LOW' end,
          'Bloat', 'Table bloat (estimated)', b.fq,
          '~' || pg_size_pretty(b.wasted_bytes) || ' of ' || pg_size_pretty(b.relpages * env.bs)
            || ' (' || round(b.wasted_bytes * 100.0 / (b.relpages * env.bs)) || '%) looks empty',
          'Estimated from column statistics. Bloated tables waste cache and make every scan slower.',
          'Confirm with pgstattuple. Fix the cause first (vacuum blockers), then pg_repack / pg_squeeze online, or VACUUM FULL in a maintenance window (exclusive lock).',
          b.wasted_bytes
     from tbl_bloat b cross join env
    where b.wasted_bytes >= :bloat_min_mb * 1024 * 1024::bigint
      and b.wasted_bytes * 100.0 / (b.relpages * env.bs) >= :bloat_pct_warn
    order by 8 desc limit :top_n)

  union all
  (select case when b.wasted_bytes >= 10 * :bloat_min_mb * 1024 * 1024::bigint then 'MEDIUM' else 'LOW' end,
          'Bloat', 'Index bloat (estimated, b-tree)', b.fq,
          pg_size_pretty(b.relpages * env.bs) || ' on disk, ~' || pg_size_pretty(b.expected_pages * env.bs)
            || ' expected (' || round(b.relpages / b.expected_pages, 1) || 'x)',
          'Index on ' || b.table_fq || '. Estimated from column statistics; indexes do not shrink on their own after mass deletes or updates.',
          'REINDEX INDEX CONCURRENTLY ' || b.fq || ';',
          b.wasted_bytes
     from idx_bloat b cross join env
    where b.wasted_bytes >= :bloat_min_mb * 1024 * 1024::bigint
      and b.relpages >= :idx_bloat_factor * b.expected_pages
    order by 8 desc limit :top_n)

  union all   -- updates that cannot stay on the same page must touch every index
  (select 'LOW', 'Bloat', 'Few HOT updates', t.fq,
          round(t.n_tup_hot_upd * 100.0 / t.n_tup_upd, 1) || '% of ' || t.n_tup_upd || ' updates were HOT',
          'A HOT update skips index maintenance. A low share means updated columns are indexed or pages have no free room, which bloats indexes and adds WAL.',
          'Drop indexes on frequently updated columns if unused, or leave room per page: ALTER TABLE ' || t.fq || ' SET (fillfactor = 85);',
          t.n_tup_upd
     from tbl t cross join env
    where not env.in_recovery and t.n_tup_upd >= :hot_upd_min and t.n_tup_hot_upd < 0.2 * t.n_tup_upd
    order by 8 desc limit :top_n)

  -- ===========================================================================
  -- G. INDEXES
  -- ===========================================================================
  union all   -- left behind by a failed CREATE / REINDEX ... CONCURRENTLY
  select 'HIGH', 'Indexes', 'Invalid index', i.fq,
         pg_size_pretty(i.bytes) || ', valid=' || i.indisvalid || ', ready=' || i.indisready,
         'Index on ' || i.table_fq || ' is never used for reads but is still maintained on every write. (Ignore it if a CREATE INDEX CONCURRENTLY is running right now.)',
         'DROP INDEX CONCURRENTLY ' || i.fq || '; and create it again, or REINDEX INDEX CONCURRENTLY ' || i.fq || ';',
         i.bytes
    from idx i where not i.indisvalid or not i.indisready

  union all   -- pure write overhead
  (select case when i.bytes >= 100 * 1024 * 1024 then 'MEDIUM' else 'LOW' end,
          'Indexes', 'Unused index', i.fq,
          pg_size_pretty(i.bytes) || ', 0 scans since '
            || coalesce(to_char((select stats_reset from dbs), 'YYYY-MM-DD'), 'statistics began (never reset)'),
          'Index on ' || i.table_fq || ' has not been used on THIS instance since statistics were reset. It still slows every INSERT / UPDATE and takes cache.',
          'Check all replicas / readers and month-end jobs first, then DROP INDEX CONCURRENTLY ' || i.fq || ';',
          i.bytes
     from idx i
    where i.idx_scan = 0 and i.indisvalid and not i.indisunique and not i.backs_constraint
      and i.bytes >= :unused_idx_min_mb * 1024 * 1024::bigint
    order by 8 desc limit :top_n)

  union all   -- identical definition twice
  (select 'MEDIUM', 'Indexes', 'Duplicate indexes', d.table_fq,
          d.names || ' (' || pg_size_pretty(d.bytes) || ' in total)',
          'These indexes have exactly the same columns, order, operator classes and predicate. Only one is needed.',
          'Keep the one that backs a constraint (if any) and DROP INDEX CONCURRENTLY the others.',
          d.bytes
     from (select i.table_fq, string_agg(i.index_name, ', ' order by i.index_name) as names, sum(i.bytes) as bytes
             from idx i
            where i.indisvalid
            group by i.table_fq, i.indrelid, i.amname, i.indkey::text, i.indclass::text, i.indoption::text,
                     i.indcollation::text, coalesce(i.indexprs::text, ''), coalesce(i.indpred::text, '')
           having count(*) > 1) d
    order by 8 desc limit :top_n)

  union all   -- index (a) is covered by index (a, b)
  (select 'LOW', 'Indexes', 'Index is a prefix of another index', a.fq,
          pg_size_pretty(a.bytes) || ', covered by ' || b.index_name,
          'All columns of this index are the leading columns of ' || b.fq || ', which can answer the same lookups.',
          'If nothing depends on it being smaller, DROP INDEX CONCURRENTLY ' || a.fq || ';',
          a.bytes
     from idx a
     join idx b on b.indrelid = a.indrelid and b.indexrelid <> a.indexrelid
    where a.amname = 'btree' and b.amname = 'btree' and a.indisvalid and b.indisvalid
      and a.indexprs is null and b.indexprs is null and a.indpred is null and b.indpred is null
      and not a.indisunique and not a.backs_constraint
      and a.indnatts = a.indnkeyatts and a.indnkeyatts < b.indnkeyatts
      and b.indkey::text       like a.indkey::text       || ' %'
      and b.indclass::text     like a.indclass::text     || ' %'
      and b.indoption::text    like a.indoption::text    || ' %'
      and b.indcollation::text like a.indcollation::text || ' %'
    order by 8 desc limit :top_n)

  union all   -- parent DELETE/UPDATE must scan the whole child table
  (select 'MEDIUM', 'Indexes', 'Foreign key without index', t.fq,
          k.conname || ' (' || (select string_agg(a.attname, ', ' order by u.ord)
                                  from unnest(k.conkey) with ordinality u(attnum, ord)
                                  join pg_attribute a on a.attrelid = k.conrelid and a.attnum = u.attnum)
            || ') -> ' || k.confrelid::regclass || ', ~' || t.reltuples::bigint || ' rows',
          'Every DELETE or key UPDATE on the referenced table scans this table completely, holding locks while it does. Joins on the key are slow too.',
          'CREATE INDEX CONCURRENTLY ON ' || t.fq || ' ('
            || (select string_agg(quote_ident(a.attname), ', ' order by u.ord)
                  from unnest(k.conkey) with ordinality u(attnum, ord)
                  join pg_attribute a on a.attrelid = k.conrelid and a.attnum = u.attnum) || ');',
          t.reltuples
     from pg_constraint k
     join tbl t on t.oid = k.conrelid
    where k.contype = 'f' and k.conparentid = 0
      and (t.relkind = 'p' or t.reltuples >= :fk_min_rows)
      and not exists (select 1 from pg_index i
                       where i.indrelid = k.conrelid and i.indisvalid and i.indpred is null
                         -- the FK columns must be the leading columns of the index, in any order
                         and (i.indkey::int2[])[0 : cardinality(k.conkey) - 1] @> k.conkey)
    order by 8 desc limit :top_n)

  union all   -- large tables that are read front to back again and again
  (select 'MEDIUM', 'Indexes', 'Frequent sequential scans on a large table', t.fq,
          t.seq_scan || ' seq scans reading ' || round(t.seq_tup_read / t.seq_scan) || ' rows each on average; '
            || coalesce(t.idx_scan, 0) || ' index scans; ~' || t.n_live_tup || ' rows',
          'Queries regularly read most of this table. That usually means a WHERE or JOIN column has no usable index.',
          'Find the statements in pg_stat_statements, check them with EXPLAIN, and add the missing index.',
          t.seq_tup_read
     from tbl t
    where t.seq_scan >= :seqscan_min and t.n_live_tup >= :seqscan_min_rows
      and t.seq_tup_read / t.seq_scan >= 0.1 * :seqscan_min_rows
    order by 8 desc limit :top_n)

  union all   -- every index is extra work on every write
  (select 'LOW', 'Indexes', 'Table carries a lot of index', t.fq,
          ti.n_idx || ' indexes, ' || pg_size_pretty(ti.idx_bytes) || ' of index for ' || pg_size_pretty(t.bytes) || ' of table',
          'Each index is updated on every INSERT and most UPDATEs, generates WAL and competes for cache.',
          'Review with the unused / duplicate / prefix findings and drop what is not needed.',
          ti.idx_bytes
     from tbl t join tbl_idx ti on ti.indrelid = t.oid
    where ti.n_idx >= :max_indexes
       or (t.bytes >= 100 * 1024 * 1024 and ti.idx_bytes >= 3 * t.bytes)
    order by 8 desc limit :top_n)

  -- ===========================================================================
  -- H. SCHEMA
  -- ===========================================================================
  union all
  (select 'MEDIUM', 'Schema', 'Table without primary key', t.fq,
          '~' || t.reltuples::bigint || ' rows, ' || pg_size_pretty(t.bytes),
          'Rows cannot be addressed uniquely. Logical replication, AWS DMS and blue-green deployments cannot replicate UPDATE / DELETE for it, and duplicates creep in.',
          'Add a primary key (build a unique index CONCURRENTLY first, then ADD CONSTRAINT ... PRIMARY KEY USING INDEX).',
          t.bytes
     from tbl t
    where t.relkind in ('r', 'p') and not t.relispartition
      and not exists (select 1 from pg_constraint k where k.conrelid = t.oid and k.contype = 'p')
    order by 8 desc limit :top_n)

  union all
  (select 'LOW', 'Schema', 'Constraint not validated', t.fq,
          k.conname || ' is NOT VALID',
          'The constraint is enforced for new rows only. The planner cannot rely on it and old rows may violate it.',
          'ALTER TABLE ' || t.fq || ' VALIDATE CONSTRAINT ' || quote_ident(k.conname) || ';',
          t.bytes
     from pg_constraint k join tbl t on t.oid = k.conrelid
    where k.contype in ('f', 'c') and not k.convalidated
    order by 8 desc limit :top_n)

  union all
  (select 'LOW', 'Schema', 'Unlogged table', t.fq,
          '~' || t.reltuples::bigint || ' rows, ' || pg_size_pretty(t.bytes),
          'Unlogged tables are emptied after a crash or failover and do not exist on replicas.',
          'Fine for scratch data. Otherwise ALTER TABLE ' || t.fq || ' SET LOGGED;',
          t.bytes
     from tbl t where t.relpersistence = 'u' and t.relkind = 'r'
    order by 8 desc limit :top_n)

  union all   -- planning time grows with the number of partitions
  select 'LOW', 'Schema', 'Very many partitions', p.parent,
         p.n || ' partitions',
         'Planning time and lock counts grow with the partition count, especially for queries that cannot prune.',
         'Use coarser partitions, detach / drop old ones, and make sure queries filter on the partition key.',
         p.n
    from (select i.inhparent::regclass::text as parent, count(*) as n
            from pg_inherits i join pg_class c on c.oid = i.inhparent
           where c.relkind = 'p' group by 1) p
   where p.n >= :max_partitions

  union all
  (select 'INFO', 'Schema', 'Very large unpartitioned table', t.fq,
          pg_size_pretty(t.bytes) || ', ~' || t.reltuples::bigint || ' rows',
          'A single huge table makes vacuum, index rebuilds and data retention slow and hard to schedule.',
          'Consider partitioning (for example by time) if old data is archived or queries are confined to recent ranges.',
          t.bytes
     from tbl t
    where t.relkind = 'r' and not t.relispartition and t.bytes >= :big_table_gb * 1024 * 1024 * 1024::bigint
    order by 8 desc limit :top_n)

  -- ===========================================================================
  -- I. SEQUENCES (running out = every INSERT fails)
  -- ===========================================================================
  union all
  (select case when q.pct >= :seq_crit_pct then 'CRITICAL' else 'HIGH' end,
          'Sequences', 'Sequence close to its limit', q.fq,
          round(q.pct, 1) || '% used (' || q.last_value || ' of ' || q.eff_max || ')',
          case when q.eff_max < q.max_value
               then 'The sequence itself can go further, but it feeds ' || q.feeds || ', which overflows first.'
               else 'When the sequence reaches its maximum, nextval() fails.' || coalesce(' Feeds ' || q.feeds || '.', '') end,
          'Change the column (and sequence) to bigint. On large tables: add a new bigint column, backfill in batches, swap.',
          q.pct
     from (select s2.*, s2.last_value * 100.0 / s2.eff_max as pct from seqs s2) q
    where q.pct >= :seq_warn_pct
    order by 8 desc limit :top_n)

  -- ===========================================================================
  -- J. MEMORY AND I/O
  -- ===========================================================================
  union all   -- share of page requests answered from shared_buffers
  select case when r.pct < :cache_hit_high then 'HIGH' else 'MEDIUM' end,
         'Memory & I/O', 'Low buffer cache hit ratio', dbs.datname::text,
         round(r.pct, 2) || '% (' || dbs.blks_read || ' blocks read from outside shared_buffers)',
         case when env.is_aurora
              then 'Aurora has no OS page cache, so every miss is a storage read.'
              else 'Misses are served by the OS cache or by disk.' end
           || ' OLTP systems normally sit above 99%.',
         'Check for sequential scans and bloat first; then size memory (instance class / shared_buffers) so the working set fits.',
         100 - r.pct
    from dbs cross join env
    cross join lateral (select dbs.blks_hit * 100.0 / nullif(dbs.blks_hit + dbs.blks_read, 0) as pct) r
   where dbs.blks_hit + dbs.blks_read >= 1000000 and r.pct < :cache_hit_warn

  union all   -- sorts / hashes that did not fit into work_mem
  select 'MEDIUM', 'Memory & I/O', 'Heavy temporary file usage', dbs.datname::text,
         pg_size_pretty(dbs.temp_bytes) || ' in ' || dbs.temp_files || ' files ('
           || pg_size_pretty((dbs.temp_bytes / dbs.days)::bigint) || ' per day)',
         'Sorts, hash joins and aggregates spilled to disk because they did not fit into work_mem ('
           || pg_size_pretty((select work_mem from cfg)) || ').',
         'Find the statements (pg_stat_statements temp_blks_written, or log_temp_files = 0). Add indexes that avoid the sort, or raise work_mem for that role only.',
         dbs.temp_bytes
    from dbs
   where dbs.temp_bytes / dbs.days >= :temp_gb_per_day * 1024 * 1024 * 1024::bigint

  union all
  select 'LOW', 'Memory & I/O', 'High rollback ratio', dbs.datname::text,
         round(dbs.xact_rollback * 100.0 / (dbs.xact_commit + dbs.xact_rollback), 1) || '% of '
           || (dbs.xact_commit + dbs.xact_rollback) || ' transactions rolled back',
         'Rolled-back work still costs I/O and leaves dead rows behind. Often caused by errors, timeouts or retry loops.',
         'Look for the errors in the server log / application log.',
         dbs.xact_rollback
    from dbs
   where dbs.xact_commit + dbs.xact_rollback >= 10000
     and dbs.xact_rollback * 100.0 / (dbs.xact_commit + dbs.xact_rollback) >= :rollback_pct_warn

  union all   -- v12+, only counts when data checksums are enabled
  select 'CRITICAL', 'Memory & I/O', 'Data checksum failures', dbs.datname::text,
         (dbs.j ->> 'checksum_failures') || ' failures, last ' || coalesce(dbs.j ->> 'checksum_last_failure', '?'),
         'PostgreSQL read pages whose checksum did not match: storage corruption.',
         'Check hardware / storage immediately, verify backups, and restore or rebuild the affected relations.',
         null
    from dbs where (dbs.j ->> 'checksum_failures')::bigint > 0

  union all   -- replica only: queries cancelled because WAL replay needed their rows
  select 'MEDIUM', 'Replication', 'Queries cancelled by recovery conflicts', dbs.datname::text,
         dbs.conflicts || ' cancelled queries',
         'On a replica, replay of changes from the primary had to cancel queries that still needed the old rows or held conflicting locks.',
         'Raise max_standby_streaming_delay, or enable hot_standby_feedback (trades bloat on the primary for fewer cancellations).',
         dbs.conflicts
    from dbs cross join env where env.in_recovery and dbs.conflicts > 0

  -- ===========================================================================
  -- K. WAL AND CHECKPOINTS (self-managed and RDS; Aurora storage works differently)
  -- ===========================================================================
  union all   -- checkpoints forced by WAL volume instead of the timer
  select 'MEDIUM', 'WAL & Checkpoints', 'Checkpoints forced by WAL volume', 'instance',
         round(c.req * 100.0 / (c.timed + c.req)) || '% requested (' || c.req || ' requested, ' || c.timed || ' timed)',
         'max_wal_size (' || pg_size_pretty((select max_wal_size from cfg)) || ') fills before checkpoint_timeout expires. Frequent checkpoints cause I/O spikes and extra full-page WAL.',
         'Raise max_wal_size until most checkpoints are timed; keep checkpoint_completion_target at 0.9.',
         null
    from ckpt c cross join env
   where not env.is_aurora and c.timed + c.req >= 10
     and c.req * 100.0 / (c.timed + c.req) >= :ckpt_req_pct_warn

  union all   -- ordinary backends had to fsync themselves
  select 'MEDIUM', 'WAL & Checkpoints', 'Backends had to fsync data files', 'instance',
         b.n || ' fsync calls by client backends',
         'Normally only the checkpointer syncs files. Backends doing it means the checkpointer could not keep up, and queries stalled on storage.',
         'Check storage latency; spread checkpoints out (max_wal_size, checkpoint_completion_target).',
         null
    from bfsync b cross join env where not env.is_aurora and b.n > 0

  union all   -- v14+
  select 'LOW', 'WAL & Checkpoints', 'WAL buffers too small', 'wal_buffers',
         (w.j ->> 'wal_buffers_full') || ' times full since ' || coalesce(left(w.j ->> 'stats_reset', 16), 'start'),
         'Backends had to write WAL to disk themselves because the WAL buffer was full.',
         'Raise wal_buffers (for example 64MB; needs a restart).', null
    from wal w cross join env
   where not env.is_aurora
     and (w.j ->> 'wal_buffers_full')::numeric
         / greatest(extract(epoch from now() - coalesce((w.j ->> 'stats_reset')::timestamptz, pg_postmaster_start_time())) / 86400.0, 1) >= 1000

  union all   -- failed archiving keeps WAL on disk until the volume is full
  select 'CRITICAL', 'WAL & Checkpoints', 'WAL archiving is failing', 'archive_command',
         a.failed_count || ' failures, last ' || to_char(a.last_failed_time, 'YYYY-MM-DD HH24:MI')
           || ' on ' || coalesce(a.last_failed_wal, '?'),
         'Last success: ' || coalesce(to_char(a.last_archived_time, 'YYYY-MM-DD HH24:MI'), 'never')
           || '. WAL files pile up in pg_wal until the disk is full, and point-in-time recovery has a gap.',
         'Fix archive_command / archive_library (permissions, destination space, network).', null
    from pg_stat_archiver a cross join env
   where not env.is_aurora and a.failed_count > 0
     and (a.last_archived_time is null or a.last_failed_time > a.last_archived_time)

  -- ===========================================================================
  -- L. REPLICATION
  -- ===========================================================================
  union all   -- a slot nobody reads from keeps WAL forever
  select case when sl.wal_status in ('lost', 'unreserved') then 'CRITICAL' else 'HIGH' end,
         'Replication', 'Replication slot at risk', sl.slot_name::text,
         sl.slot_type || ', active=' || sl.active || coalesce(', wal_status=' || sl.wal_status, '')
           || ', retains ' || coalesce(pg_size_pretty(sl.retained_bytes), 'unknown') || ' of WAL',
         case when sl.wal_status = 'lost' then 'The slot fell too far behind and was invalidated; its consumer must be rebuilt.'
              when sl.wal_status = 'unreserved' then 'The slot is past max_slot_wal_keep_size and will be invalidated at the next checkpoint.'
              when not sl.active then 'Nobody is connected to this slot. The server keeps every WAL file since it was last read, until storage runs out. It can also hold back VACUUM.'
              else 'The consumer is connected but far behind; WAL keeps accumulating.' end,
         'If the consumer is gone: SELECT pg_drop_replication_slot(''' || sl.slot_name || '''); Otherwise fix the consumer. Set max_slot_wal_keep_size as a safety limit.',
         sl.retained_bytes
    from slots sl
   where not sl.temporary
     and (not sl.active or sl.wal_status in ('lost', 'unreserved')
          or sl.retained_bytes >= :slot_wal_gb * 1024 * 1024 * 1024::bigint)

  union all   -- seen from the sending side
  select case when r.state <> 'streaming' then 'MEDIUM' else 'HIGH' end,
         'Replication', 'Standby lagging or not streaming',
         coalesce(nullif(r.application_name, ''), 'pid ' || r.pid) || coalesce(' (' || r.client_addr::text || ')', ''),
         'state=' || coalesce(r.state, '?') || ', behind by '
           || coalesce(pg_size_pretty(pg_wal_lsn_diff(env.cur_lsn, r.replay_lsn)), '?')
           || coalesce(', replay lag ' || round(extract(epoch from r.replay_lag)) || ' s', ''),
         'The standby has not applied everything the primary generated. Reads there are stale and a failover would take longer.',
         'Check network and I/O on the standby, long queries there (max_standby_streaming_delay), and WAL volume on the primary.',
         pg_wal_lsn_diff(env.cur_lsn, r.replay_lsn)
    from pg_stat_replication r cross join env
   where r.state <> 'streaming'
      or pg_wal_lsn_diff(env.cur_lsn, r.replay_lsn) >= :repl_lag_mb * 1024 * 1024::bigint
      or extract(epoch from r.replay_lag) >= :repl_lag_sec

  union all   -- seen from the receiving side (community streaming replication)
  select 'HIGH', 'Replication', 'This standby is behind', 'instance',
         round(d.delay_sec) || ' s behind the primary',
         'WAL has been received but not yet replayed, or nothing has arrived for a while on a busy primary.',
         'Look for long queries on this standby that block replay and for I/O saturation.',
         d.delay_sec
    from env
    cross join lateral (select case when pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() then 0
                                    else extract(epoch from now() - pg_last_xact_replay_timestamp()) end as delay_sec) d
   where env.in_recovery and not env.is_aurora and d.delay_sec >= :repl_lag_sec

  union all
  select 'MEDIUM', 'Replication', 'WAL receiver not running', 'instance',
         'no row in pg_stat_wal_receiver',
         'This standby is not streaming from a primary. That is expected only for a pure archive-recovery (log-shipping) standby.',
         'Check primary_conninfo, network, credentials and the replication slot on the primary.', null
    from env
   where env.in_recovery and not env.is_aurora and env.can_monitor
     and not exists (select 1 from pg_stat_wal_receiver)

  union all   -- Aurora replicas share storage; lag is reported by aurora_replica_status()
  select case when l.ms >= 10 * :aurora_lag_ms then 'HIGH' else 'MEDIUM' end,
         'Replication', 'Aurora replica lag', coalesce(st.j ->> 'server_id', '?'),
         round(l.ms) || ' ms behind the writer',
         'Aurora readers normally stay within tens of milliseconds. Sustained lag means the reader is overloaded or the writer produces changes faster than the reader can apply them; Aurora restarts readers that fall too far behind.',
         'Check reader CPU and long-running queries on the reader; use an instance class at least as large as the writer.',
         l.ms
    from aurora_status st
    cross join lateral (select (st.j ->> 'replica_lag_in_msec')::numeric as ms) l
   where l.ms >= :aurora_lag_ms

  union all   -- logical replication subscriber side
  select 'HIGH', 'Replication', 'Subscription enabled but not running', sub.subname::text,
         'no apply worker', 'The subscription is enabled, yet no worker is attached. Usually it is failing in a loop (conflict, missing table, connection).',
         'Read the subscriber''s server log for the apply error; check pg_stat_subscription_stats (v15+).', null
    from pg_subscription sub
   where sub.subenabled
     and sub.subdbid = (select oid from pg_database where datname = current_database())
     and not exists (select 1 from pg_stat_subscription ss where ss.subid = sub.oid and ss.pid is not null)

  -- ===========================================================================
  -- M. CONFIGURATION
  -- ===========================================================================
  union all   -- durability switches that must never be off outside throw-away systems
  select case s.name when 'fsync' then 'CRITICAL' else 'HIGH' end, 'Configuration', 'Crash safety disabled', s.name, s.setting,
         'With ' || s.name || ' = off a crash or power loss can corrupt the database beyond repair.',
         'Set ' || s.name || ' = on.', null
    from s cross join env
   where not env.is_aurora and s.name in ('fsync', 'full_page_writes') and s.setting = 'off'

  union all
  select 'LOW', 'Configuration', 'synchronous_commit is off', 'synchronous_commit', s.setting,
         'Commits return before WAL reaches disk. Fast, but the last moments of committed transactions can be lost in a crash (no corruption).',
         'Keep it only if the application tolerates that; otherwise set it per transaction where speed matters.', null
    from s where s.name = 'synchronous_commit' and s.setting = 'off'

  union all   -- memory settings still at the tiny built-in defaults
  select 'MEDIUM', 'Configuration', 'shared_buffers at the built-in default', 'shared_buffers',
         pg_size_pretty(cfg.shared_buffers),
         'The 128MB default is meant to let PostgreSQL start anywhere, not to run a workload.',
         'Self-managed: about 25% of RAM. RDS: use the default parameter-group formula.', null
    from cfg cross join env where not env.is_aurora and cfg.shared_buffers <= 128 * 1024 * 1024

  union all
  select 'LOW', 'Configuration', 'work_mem at or below the default', 'work_mem', pg_size_pretty(cfg.work_mem),
         'Sorts and hashes larger than this spill to temporary files. See "Heavy temporary file usage".',
         'Raise carefully (16-64MB is common): the limit applies per sort/hash node per session, so multiply by concurrency.', null
    from cfg where cfg.work_mem <= 4 * 1024 * 1024

  union all
  select 'LOW', 'Configuration', 'maintenance_work_mem at or below the default', 'maintenance_work_mem',
         pg_size_pretty(cfg.maint_work_mem),
         'VACUUM, CREATE INDEX and ALTER TABLE ADD FOREIGN KEY run slower with little memory.',
         'Raise to 512MB - 2GB depending on RAM (autovacuum_work_mem can be set separately).', null
    from cfg where cfg.maint_work_mem <= 64 * 1024 * 1024

  union all   -- 4.0 models spinning disks
  select 'LOW', 'Configuration', 'random_page_cost assumes spinning disks', 'random_page_cost', cfg.random_page_cost::text,
         'The default of 4 tells the planner random reads are 4x as expensive as sequential ones, which pushes it away from index scans. On SSD, EBS and Aurora storage that is wrong.',
         'Set random_page_cost = 1.1 (test on a replica or per session first).', null
    from cfg where cfg.random_page_cost >= 4

  union all
  select 'LOW', 'Configuration', 'max_wal_size at or below the default', 'max_wal_size', pg_size_pretty(cfg.max_wal_size),
         'With 1GB of WAL between checkpoints a write-heavy system checkpoints constantly.',
         'Raise to several GB (4-16GB is common); watch the "Checkpoints forced by WAL volume" finding.', null
    from cfg cross join env where not env.is_aurora and cfg.max_wal_size <= 1024 * 1024 * 1024

  union all
  select 'LOW', 'Configuration', 'Huge pages off with large shared_buffers', 'huge_pages', s.setting,
         'shared_buffers is ' || pg_size_pretty(cfg.shared_buffers) || '. With 4kB pages the kernel page tables for that become large and TLB misses cost CPU.',
         'Configure huge pages in the OS (vm.nr_hugepages) and set huge_pages = try or on.', null
    from s cross join cfg cross join env
   where not env.is_aurora and not env.is_rds
     and s.name = 'huge_pages' and s.setting = 'off' and cfg.shared_buffers >= 8 * 1024 * 1024 * 1024::bigint

  union all   -- safety nets against runaway sessions
  select 'LOW', 'Configuration', 'No timeout for idle transactions', 'idle_in_transaction_session_timeout', '0 (disabled)',
         'A forgotten open transaction can block vacuum and DDL indefinitely.',
         'Set idle_in_transaction_session_timeout (for example 5-15 min), globally or per application role.', null
    from s where s.name = 'idle_in_transaction_session_timeout' and s.setting = '0'

  union all   -- diagnostics that cost almost nothing and are missed when needed
  select 'LOW', 'Configuration', 'Diagnostic logging / tracking is off', s.name, s.setting, v.why, v.fix, null
    from s
    join (values
      ('log_min_duration_statement', '-1',  true,  'Slow statements are not logged, so there is no record of what was slow and when.', 'Set log_min_duration_statement, for example 1000 (ms).'),
      ('log_lock_waits',             'off', true,  'Sessions waiting longer than deadlock_timeout for a lock are not logged.', 'Set log_lock_waits = on.'),
      ('log_temp_files',             '-1',  true,  'Statements that spill to temporary files are not logged.', 'Set log_temp_files = 0 (or a size threshold in kB).'),
      ('log_autovacuum_min_duration','-1',  true,  'Autovacuum runs are not logged, so slow or ineffective vacuums go unnoticed.', 'Set log_autovacuum_min_duration, for example 10000 (ms).'),
      ('log_checkpoints',            'off', false, 'Checkpoint timing is not logged.', 'Set log_checkpoints = on.'),
      ('track_io_timing',            'off', true,  'Read / write times are missing from EXPLAIN (BUFFERS), pg_stat_statements and pg_stat_io.', 'Set track_io_timing = on.')
    ) as v(name, bad, on_aurora, why, fix) on v.name = s.name and v.bad = s.setting
    cross join env
   where v.on_aurora or not env.is_aurora

  union all   -- without it nobody can say which statements cost the most
  select 'MEDIUM', 'Configuration', 'pg_stat_statements not available', current_database(),
         case when not exists (select 1 from s where name = 'shared_preload_libraries')
              then 'cannot tell: this role may not read shared_preload_libraries'
              when (select setting from s where name = 'shared_preload_libraries') like '%pg_stat_statements%'
              then 'library loaded, extension not created in this database'
              else 'not in shared_preload_libraries' end,
         'There are no per-statement statistics, so the Queries section of this report is empty.',
         'Add pg_stat_statements to shared_preload_libraries (parameter group on RDS / Aurora, restart needed), then CREATE EXTENSION pg_stat_statements; Run this script as a pg_monitor member.',
         null
   where not :'hc_has_pss'::boolean

  union all
  select 'INFO', 'Configuration', 'JIT compilation is enabled', 'jit', s.setting,
         'JIT helps long analytic queries but can add tens of milliseconds to short ones when the planner over-estimates cost.',
         'For OLTP workloads consider jit = off, or raise jit_above_cost.', null
    from s where s.name = 'jit' and s.setting = 'on'

  -- ===========================================================================
  -- N. QUERIES (pg_stat_statements, all databases of the instance)
  -- ===========================================================================
  union all   -- where the database spends its time: the best place to start tuning
  (select case when p.total_ms * 100 / t.total_ms >= :pss_share_warn then 'MEDIUM' else 'INFO' end,
          'Queries', 'Top statements by total time', 'queryid ' || p.queryid || ' (' || p.dbname || ')',
          round(p.total_ms * 100 / t.total_ms, 1) || '% of all execution time; ' || p.calls || ' calls, mean '
            || round(p.mean_ms, 2) || ' ms, ' || round(p.n_rows / p.calls, 1) || ' rows/call',
          p.q,
          'EXPLAIN (ANALYZE, BUFFERS) this statement. High calls with low mean: cache or batch in the application. High mean: index or rewrite.',
          p.total_ms
     from pss p cross join pss_total t
    where t.total_ms is not null
    order by 8 desc limit :pss_top)

  union all
  (select 'MEDIUM', 'Queries', 'Slow statements (high mean time)', 'queryid ' || p.queryid || ' (' || p.dbname || ')',
          'mean ' || round(p.mean_ms) || ' ms over ' || p.calls || ' calls',
          p.q,
          'EXPLAIN (ANALYZE, BUFFERS); look for sequential scans, bad row estimates and sorts on disk.',
          p.mean_ms
     from pss p
    where p.mean_ms >= :pss_mean_ms and p.calls >= 5
    order by 8 desc limit :pss_top)

  union all
  (select 'LOW', 'Queries', 'Statements spilling to temp files', 'queryid ' || p.queryid || ' (' || p.dbname || ')',
          pg_size_pretty((p.temp_blks * env.bs)::bigint) || ' written to temp files over ' || p.calls || ' calls',
          p.q,
          'Add an index that delivers rows already sorted, reduce the row set earlier, or raise work_mem for this role.',
          p.temp_blks
     from pss p cross join env
    where p.temp_blks * env.bs >= 100 * 1024 * 1024
    order by 8 desc limit :pss_top)

  union all
  (select 'LOW', 'Queries', 'Statements reading most from disk', 'queryid ' || p.queryid || ' (' || p.dbname || ')',
          pg_size_pretty((p.blks_read * env.bs)::bigint) || ' read from outside the buffer cache, hit ratio '
            || round(p.blks_hit * 100 / nullif(p.blks_hit + p.blks_read, 0), 1) || '%, ' || p.calls || ' calls',
          p.q,
          'These statements drive read I/O. Check for missing indexes and for scans over bloated tables.',
          p.blks_read
     from pss p cross join env
    where p.blks_read * env.bs >= 1024 * 1024 * 1024::bigint
      and p.blks_hit * 100 / nullif(p.blks_hit + p.blks_read, 0) < 90
    order by 8 desc limit :pss_top)
)

-- ---- output: one summary row, then the findings by severity ------------------
select r.severity, r.category, r.check_name, r.object_name, r.current_value, r.details, r.recommended_action
  from (
    select 0 as sev_rank, 'SUMMARY'::text as severity, 'Summary'::text as category,
           'Findings by severity'::text as check_name,
           current_database()::text || ' @ ' || to_char(now(), 'YYYY-MM-DD HH24:MI TZ') as object_name,
           'CRITICAL ' || count(*) filter (where sev = 'CRITICAL')
             || ', HIGH '   || count(*) filter (where sev = 'HIGH')
             || ', MEDIUM ' || count(*) filter (where sev = 'MEDIUM')
             || ', LOW '    || count(*) filter (where sev = 'LOW')
             || ', INFO '   || count(*) filter (where sev = 'INFO') as current_value,
           'Each check lists at most ' || :top_n || ' objects. Table, index and sequence checks cover this database only.' as details,
           'Work from the top: CRITICAL and HIGH first.'::text as recommended_action,
           null::numeric as ord
      from findings
    union all
    select case sev when 'CRITICAL' then 1 when 'HIGH' then 2 when 'MEDIUM' then 3 when 'LOW' then 4 else 5 end,
           sev, category, check_name, object_name, current_value, details, action, ord
      from findings
  ) r
 order by r.sev_rank, r.category, r.check_name, r.ord desc nulls last, r.object_name;

-- -----------------------------------------------------------------------------
-- 5. Put the session settings back (matters only when the script is run with \i
--    inside an interactive session).
-- -----------------------------------------------------------------------------
select set_config('statement_timeout', :'hc_old_statement_timeout', false)             as hc_x1,
       set_config('default_transaction_read_only', :'hc_old_read_only', false)         as hc_x2
\gset
