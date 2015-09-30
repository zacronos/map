
CREATE EXTENSION IF NOT EXISTS tablefunc;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP TABLE IF EXISTS keystore;
ALTER TABLE keystore_property RENAME TO keystore;
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-16 20:57:29.018472', '2015-09-16 21:01:04.44772', 'sanity', 'ENCRYPTION_AT_REST', '"BjzOPoORSWUNoKMtBaCXWw==$$gXy8NPwXklFXY7mBGOxI1VzQ59a+9XUJFLL0wnM4$"');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-08-14 18:13:54.304403', '2015-09-30 19:09:49.81293', NULL, 'hirefire run timestamp', '1443640189800');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-08-20 14:35:21.260675', '2015-09-30 19:09:49.873394', NULL, 'job queue maintenance timestamp', '1443640189861');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-30 19:09:49.873394', '2015-09-30 19:09:49.873394', 'max logins', 'basic', '1');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-30 19:09:49.873394', '2015-09-30 19:09:49.873394', 'max logins', 'standard', '1');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-30 19:09:49.873394', '2015-09-30 19:09:49.873394', 'max logins', 'premium', '2');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-30 19:09:49.873394', '2015-09-30 19:09:49.873394', 'max logins', 'free', '1');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-30 19:09:49.873394', '2015-09-30 19:09:49.873394', 'hashing cost factors', 'password', '13');
INSERT INTO keystore (rm_inserted_time, rm_modified_time, namespace, key, value) VALUES ('2015-09-30 19:09:49.873394', '2015-09-30 19:09:49.873394', 'hashing cost factors', 'token', '11');

CREATE TABLE jq_current_subtasks (
  id integer NOT NULL,
  name text NOT NULL,
  task_name text NOT NULL,
  queue_name text NOT NULL,
  batch_id text NOT NULL,
  step_num integer,
  task_step text NOT NULL,
  data json,
  task_data json,
  retry_delay_seconds integer,
  retry_max_count integer,
  retry_num integer DEFAULT 0 NOT NULL,
  hard_fail_timeouts boolean NOT NULL,
  hard_fail_after_retries boolean NOT NULL,
  hard_fail_zombies boolean NOT NULL,
  warn_timeout_seconds integer,
  kill_timeout_seconds integer,
  ignore_until timestamp without time zone,
  enqueued timestamp without time zone DEFAULT now() NOT NULL,
  started timestamp without time zone,
  finished timestamp without time zone,
  status text DEFAULT 'queued'::text NOT NULL,
  auto_enqueue boolean DEFAULT true NOT NULL
);

CREATE FUNCTION jq_get_next_subtask(source_queue_name text) RETURNS jq_current_subtasks
LANGUAGE plpgsql
AS $$
  DECLARE
    selected_subtask INTEGER;
    subtask_details jq_current_subtasks;
  BEGIN
    SELECT id                                                           -- get the id...
    FROM (
      SELECT MIN(id) AS id                                              -- from the earliest-enqueued subtask...
      FROM jq_current_subtasks
      WHERE
        queue_name = source_queue_name AND                              -- that's in the queue with this lock...
        status = 'queued' AND
        COALESCE(ignore_until, '1970-01-01'::TIMESTAMP) <= NOW() AND
        task_step IN (
          SELECT task_name || '_' ||  LPAD(COALESCE(MIN(step_num)::TEXT, 'FINAL'), 5, '0'::TEXT)    -- from the earliest step in each task...
          FROM (
            SELECT
              task_name,
              step_num
            FROM jq_current_subtasks
            WHERE queue_name = source_queue_name
            GROUP BY
              task_name,
              step_num
            HAVING                                                      -- that isn't yet acceptably finished...
              COUNT(
                status IN ('queued', 'preparing', 'running', 'hard fail', 'infrastructure fail') OR
                (status = 'timeout' AND hard_fail_timeouts = TRUE) OR
                (status = 'zombie' AND hard_fail_zombies = TRUE) OR
                NULL
              ) > 0
          ) AS task_steps
          GROUP BY task_name
        ) AND
        EXISTS (
          SELECT name
          FROM jq_task_history
          WHERE
            jq_task_history.name = jq_current_subtasks.task_name AND
            jq_task_history.batch_id = jq_current_subtasks.batch_id AND
            jq_task_history.status = 'running'
        )
    ) AS selected_subtask_id
    INTO selected_subtask;

    UPDATE jq_current_subtasks                                          -- then mark the row we're grabbing...
    SET status = 'preparing'
    WHERE id = selected_subtask
    RETURNING *
    INTO subtask_details;                                               -- and return the data from that row

    RETURN subtask_details;
  END;
  $$;

CREATE FUNCTION jq_update_task_counts() RETURNS void
LANGUAGE plpgsql
AS $$
  BEGIN
    UPDATE jq_task_history
    SET
      subtasks_created = counts.created,
      subtasks_preparing = counts.preparing,
      subtasks_running = counts.running,
      subtasks_soft_failed = counts.soft_failed,
      subtasks_hard_failed = counts.hard_failed,
      subtasks_infrastructure_failed = counts.infrastructure_failed,
      subtasks_canceled = counts.canceled,
      subtasks_timeout = counts.timeout,
      subtasks_zombie = counts.zombie,
      subtasks_finished = counts.finished,
      subtasks_succeeded = counts.succeeded,
      subtasks_failed = counts.failed
    FROM (
      SELECT
        task_name,
        batch_id,
        COUNT(*) AS created,
        COUNT(status = 'preparing' OR NULL) AS preparing,
        COUNT(status = 'running' OR NULL) AS running,
        COUNT(status = 'soft fail' OR NULL) AS soft_failed,
        COUNT(status = 'hard fail' OR NULL) AS hard_failed,
        COUNT(status = 'infrastructure fail' OR NULL) AS infrastructure_failed,
        COUNT(status = 'canceled' OR NULL) AS canceled,
        COUNT(status = 'timeout' OR NULL) AS timeout,
        COUNT(status = 'zombie' OR NULL) AS zombie,
        COUNT(finished IS NOT NULL OR NULL) AS finished,
        COUNT(status = 'success' OR NULL) AS succeeded,
        COUNT(status NOT IN ('queued', 'preparing', 'running', 'success', 'canceled') OR NULL) AS failed
      FROM jq_current_subtasks
      GROUP BY task_name, batch_id
    ) AS counts
    WHERE
      jq_task_history.name = counts.task_name AND
      jq_task_history.batch_id = counts.batch_id AND
      jq_task_history.started >= (NOW() - '1 day'::INTERVAL);
  END;
  $$;

CREATE TABLE account_images (
  id integer NOT NULL,
  blob bytea,
  gravatar_url character varying
);

CREATE SEQUENCE account_images_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE account_images_id_seq OWNED BY account_images.id;

CREATE TABLE account_use_types (
  id integer NOT NULL,
  type character varying,
  description character varying
);
CREATE SEQUENCE account_use_types_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE account_use_types_id_seq OWNED BY account_use_types.id;

CREATE TABLE auth_group (
  id integer NOT NULL,
  name character varying(80) NOT NULL
);
CREATE SEQUENCE auth_group_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_group_id_seq OWNED BY auth_group.id;

CREATE TABLE auth_group_permissions (
  id integer NOT NULL,
  group_id integer NOT NULL,
  permission_id integer NOT NULL
);
CREATE SEQUENCE auth_group_permissions_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_group_permissions_id_seq OWNED BY auth_group_permissions.id;

CREATE TABLE auth_permission (
  id integer NOT NULL,
  name character varying(50) NOT NULL,
  codename character varying(100) NOT NULL
);
CREATE SEQUENCE auth_permission_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_permission_id_seq OWNED BY auth_permission.id;

CREATE TABLE auth_user (
  id integer NOT NULL,
  password character varying(128) NOT NULL,
  last_login timestamp with time zone NOT NULL,
  is_superuser boolean NOT NULL,
  username character varying(30) NOT NULL,
  first_name character varying(30) NOT NULL,
  last_name character varying(30) NOT NULL,
  email character varying(75) NOT NULL,
  is_staff boolean NOT NULL,
  is_active boolean NOT NULL,
  date_joined timestamp with time zone NOT NULL,
  cell_phone bigint,
  work_phone bigint,
  account_image_id integer,
  us_state_id integer,
  address_1 character varying,
  address_2 character varying,
  zip character varying,
  website_url character varying,
  account_use_type_id integer,
  city character varying,
  company_id integer
);

CREATE TABLE auth_user_groups (
  id integer NOT NULL,
  user_id integer NOT NULL,
  group_id integer NOT NULL
);
CREATE SEQUENCE auth_user_groups_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_user_groups_id_seq OWNED BY auth_user_groups.id;

CREATE SEQUENCE auth_user_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_user_id_seq OWNED BY auth_user.id;

CREATE TABLE auth_user_profile (
  filters json,
  properties_selected json,
  map_toggles json DEFAULT '{}'::json NOT NULL,
  map_position json,
  map_results json DEFAULT '{}'::json NOT NULL,
  parent_auth_user_id integer,
  auth_user_id integer NOT NULL,
  name character varying,
  project_id integer,
  id integer NOT NULL,
  rm_inserted_time timestamp without time zone DEFAULT now_utc() NOT NULL,
  rm_modified_time timestamp without time zone DEFAULT now_utc() NOT NULL,
  account_image_id integer
);
CREATE SEQUENCE auth_user_profile_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_user_profile_id_seq OWNED BY auth_user_profile.id;

CREATE TABLE auth_user_user_permissions (
  id integer NOT NULL,
  user_id integer NOT NULL,
  permission_id integer NOT NULL
);
CREATE SEQUENCE auth_user_user_permissions_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE auth_user_user_permissions_id_seq OWNED BY auth_user_user_permissions.id;

CREATE TABLE company (
  id integer NOT NULL,
  address_1 character varying,
  address_2 character varying,
  city character varying,
  zip character varying,
  us_state_id integer,
  phone character varying,
  fax character varying,
  website_url character varying,
  account_image_id integer,
  name character varying
);
CREATE SEQUENCE company_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE company_id_seq OWNED BY company.id;

CREATE TABLE data_normalization_config (
  data_source_id text NOT NULL,
  list text NOT NULL,
  output text,
  ordering integer NOT NULL,
  required boolean NOT NULL,
  input json,
  transform text,
  config json,
  data_source_type text NOT NULL,
  data_type text NOT NULL
);

CREATE TABLE external_accounts (
  id integer NOT NULL,
  name character varying,
  username character varying,
  password character varying,
  api_key character varying,
  other json
);
CREATE SEQUENCE external_accounts_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE external_accounts_id_seq OWNED BY external_accounts.id;

CREATE TABLE fips_lookup (
  state text NOT NULL,
  county text NOT NULL,
  code text NOT NULL
);
CREATE SEQUENCE jq_current_subtasks_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE jq_current_subtasks_id_seq OWNED BY jq_current_subtasks.id;

CREATE TABLE jq_queue_config (
  name text NOT NULL,
  lock_id integer NOT NULL,
  processes_per_dyno integer NOT NULL,
  subtasks_per_process integer NOT NULL,
  priority_factor double precision NOT NULL,
  active boolean DEFAULT true NOT NULL
);
CREATE SEQUENCE jq_queue_config_lock_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE jq_queue_config_lock_id_seq OWNED BY jq_queue_config.lock_id;

CREATE TABLE jq_subtask_config (
  name text NOT NULL,
  task_name text NOT NULL,
  queue_name text NOT NULL,
  step_num integer,
  data json,
  retry_delay_seconds integer,
  retry_max_count integer,
  hard_fail_timeouts boolean NOT NULL,
  hard_fail_after_retries boolean NOT NULL,
  hard_fail_zombies boolean NOT NULL,
  warn_timeout_seconds integer,
  kill_timeout_seconds integer,
  auto_enqueue boolean DEFAULT true NOT NULL
);

CREATE TABLE jq_subtask_error_history (
  id integer NOT NULL,
  name text NOT NULL,
  task_name text NOT NULL,
  queue_name text NOT NULL,
  batch_id text NOT NULL,
  step_num integer,
  task_step text NOT NULL,
  data json,
  task_data json,
  retry_delay_seconds integer,
  retry_max_count integer,
  retry_num integer DEFAULT 0 NOT NULL,
  hard_fail_timeouts boolean NOT NULL,
  hard_fail_after_retries boolean NOT NULL,
  hard_fail_zombies boolean NOT NULL,
  warn_timeout_seconds integer,
  kill_timeout_seconds integer,
  ignore_until timestamp without time zone,
  enqueued timestamp without time zone NOT NULL,
  started timestamp without time zone NOT NULL,
  finished timestamp without time zone,
  status text NOT NULL,
  error text NOT NULL,
  auto_enqueue boolean DEFAULT true NOT NULL,
  stack text
);

CREATE TABLE jq_task_history (
  name text NOT NULL,
  data json,
  batch_id text NOT NULL,
  started timestamp without time zone DEFAULT now() NOT NULL,
  initiator text NOT NULL,
  status_changed timestamp without time zone DEFAULT now() NOT NULL,
  finished timestamp without time zone,
  status text DEFAULT 'preparing'::text NOT NULL,
  current boolean DEFAULT true NOT NULL,
  warn_timeout_minutes integer,
  kill_timeout_minutes integer,
  subtasks_created integer DEFAULT 0 NOT NULL,
  subtasks_running integer DEFAULT 0 NOT NULL,
  subtasks_finished integer DEFAULT 0 NOT NULL,
  subtasks_soft_failed integer DEFAULT 0 NOT NULL,
  subtasks_hard_failed integer DEFAULT 0 NOT NULL,
  subtasks_infrastructure_failed integer DEFAULT 0 NOT NULL,
  subtasks_canceled integer DEFAULT 0 NOT NULL,
  subtasks_timeout integer DEFAULT 0 NOT NULL,
  subtasks_zombie integer DEFAULT 0 NOT NULL,
  subtasks_preparing integer DEFAULT 0 NOT NULL,
  subtasks_succeeded integer DEFAULT 0 NOT NULL,
  subtasks_failed integer DEFAULT 0 NOT NULL
);

CREATE VIEW jq_summary AS
  SELECT
    CASE
    WHEN ((jq_task_history.status = 'running'::text) OR (jq_task_history.status = 'preparing'::text)) THEN 'Last Hour'::text
    ELSE
      CASE
      WHEN (((date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) * (24)::double precision) + date_part('hour'::text, (now() - (jq_task_history.finished)::timestamp with time zone))) < (1)::double precision) THEN 'Last Hour'::text
      WHEN (((date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) * (24)::double precision) + date_part('hour'::text, (now() - (jq_task_history.finished)::timestamp with time zone))) < (24)::double precision) THEN 'Last Day'::text
      WHEN (date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) < (7)::double precision) THEN 'Last 7 Days'::text
      WHEN (date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) < (30)::double precision) THEN 'Last 30 Days'::text
      ELSE 'After 30 Days'::text
      END
    END AS timeframe,
    jq_task_history.status,
    count(*) AS count
  FROM jq_task_history
  GROUP BY
    CASE
    WHEN ((jq_task_history.status = 'running'::text) OR (jq_task_history.status = 'preparing'::text)) THEN 'Last Hour'::text
    ELSE
      CASE
      WHEN (((date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) * (24)::double precision) + date_part('hour'::text, (now() - (jq_task_history.finished)::timestamp with time zone))) < (1)::double precision) THEN 'Last Hour'::text
      WHEN (((date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) * (24)::double precision) + date_part('hour'::text, (now() - (jq_task_history.finished)::timestamp with time zone))) < (24)::double precision) THEN 'Last Day'::text
      WHEN (date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) < (7)::double precision) THEN 'Last 7 Days'::text
      WHEN (date_part('day'::text, (now() - (jq_task_history.finished)::timestamp with time zone)) < (30)::double precision) THEN 'Last 30 Days'::text
      ELSE 'After 30 Days'::text
      END
    END, jq_task_history.status
  UNION
  SELECT 'Current'::text AS timeframe,
    jq_task_history.status,
         count(
             CASE
             WHEN (jq_task_history.current = true) THEN 1
             ELSE NULL::integer
             END) AS count
  FROM jq_task_history
  GROUP BY jq_task_history.status, 'Current'::text;

CREATE TABLE jq_task_config (
  name text NOT NULL,
  description text,
  data json,
  ignore_until timestamp without time zone,
  repeat_period_minutes integer,
  warn_timeout_minutes integer,
  kill_timeout_minutes integer,
  active boolean DEFAULT true NOT NULL,
  fail_retry_minutes integer DEFAULT 1
);

CREATE TABLE management_useraccountprofile (
  id integer NOT NULL,
  user_id integer NOT NULL,
  suspended boolean NOT NULL,
  override_basic_monthly_charge double precision,
  override_basic_yearly_charge double precision,
  override_basic_num_logins integer,
  override_standard_monthly_charge double precision,
  override_standard_yearly_charge double precision,
  override_standard_num_logins integer,
  override_premium_monthly_charge double precision,
  override_premium_yearly_charge double precision,
  override_premium_num_logins integer,
  notes text NOT NULL
);
CREATE SEQUENCE management_useraccountprofile_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE management_useraccountprofile_id_seq OWNED BY management_useraccountprofile.id;

CREATE TABLE mls_config (
  id text NOT NULL,
  name text NOT NULL,
  notes text,
  username text NOT NULL,
  password text NOT NULL,
  url text NOT NULL,
  listing_data json NOT NULL,
  static_ip boolean DEFAULT false NOT NULL,
  data_rules json DEFAULT '{}'::json
);

CREATE TABLE notification (
  user_id integer NOT NULL,
  type text NOT NULL,
  method text NOT NULL
);

CREATE TABLE project (
  id integer NOT NULL,
  name character varying,
  rm_inserted_time timestamp without time zone DEFAULT now_utc() NOT NULL,
  rm_modified_time timestamp without time zone DEFAULT now_utc() NOT NULL
);
CREATE SEQUENCE project_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE project_id_seq OWNED BY project.id;

CREATE TABLE session (
  sid character varying NOT NULL,
  sess json NOT NULL,
  expire timestamp(6) without time zone NOT NULL
);

CREATE TABLE session_security (
  id integer NOT NULL,
  user_id integer NOT NULL,
  session_id character varying(64) NOT NULL,
  remember_me boolean NOT NULL,
  series_salt character varying(32) NOT NULL,
  token character varying(32) NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  app text NOT NULL
);
CREATE SEQUENCE session_security_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE session_security_id_seq OWNED BY session_security.id;

CREATE TABLE us_states (
  id integer NOT NULL,
  code character varying,
  name character varying
);
CREATE SEQUENCE us_states_id_seq
START WITH 1
INCREMENT BY 1
NO MINVALUE
NO MAXVALUE
CACHE 1;
ALTER SEQUENCE us_states_id_seq OWNED BY us_states.id;

ALTER TABLE ONLY account_images ALTER COLUMN id SET DEFAULT nextval('account_images_id_seq'::regclass);
ALTER TABLE ONLY account_use_types ALTER COLUMN id SET DEFAULT nextval('account_use_types_id_seq'::regclass);
ALTER TABLE ONLY auth_group ALTER COLUMN id SET DEFAULT nextval('auth_group_id_seq'::regclass);
ALTER TABLE ONLY auth_group_permissions ALTER COLUMN id SET DEFAULT nextval('auth_group_permissions_id_seq'::regclass);
ALTER TABLE ONLY auth_permission ALTER COLUMN id SET DEFAULT nextval('auth_permission_id_seq'::regclass);
ALTER TABLE ONLY auth_user ALTER COLUMN id SET DEFAULT nextval('auth_user_id_seq'::regclass);
ALTER TABLE ONLY auth_user_groups ALTER COLUMN id SET DEFAULT nextval('auth_user_groups_id_seq'::regclass);
ALTER TABLE ONLY auth_user_profile ALTER COLUMN id SET DEFAULT nextval('auth_user_profile_id_seq'::regclass);
ALTER TABLE ONLY auth_user_user_permissions ALTER COLUMN id SET DEFAULT nextval('auth_user_user_permissions_id_seq'::regclass);
ALTER TABLE ONLY company ALTER COLUMN id SET DEFAULT nextval('company_id_seq'::regclass);
ALTER TABLE ONLY external_accounts ALTER COLUMN id SET DEFAULT nextval('external_accounts_id_seq'::regclass);
ALTER TABLE ONLY jq_current_subtasks ALTER COLUMN id SET DEFAULT nextval('jq_current_subtasks_id_seq'::regclass);
ALTER TABLE ONLY jq_queue_config ALTER COLUMN lock_id SET DEFAULT nextval('jq_queue_config_lock_id_seq'::regclass);
ALTER TABLE ONLY management_useraccountprofile ALTER COLUMN id SET DEFAULT nextval('management_useraccountprofile_id_seq'::regclass);
ALTER TABLE ONLY project ALTER COLUMN id SET DEFAULT nextval('project_id_seq'::regclass);
ALTER TABLE ONLY session_security ALTER COLUMN id SET DEFAULT nextval('session_security_id_seq'::regclass);
ALTER TABLE ONLY us_states ALTER COLUMN id SET DEFAULT nextval('us_states_id_seq'::regclass);

INSERT INTO account_use_types (id, type, description) VALUES (1, 'realtor', 'I''m a realtor.');
INSERT INTO account_use_types (id, type, description) VALUES (2, 'real estate developer', 'I''m real estate developer.');
INSERT INTO account_use_types (id, type, description) VALUES (3, 'real estate investor', 'I''m real estate investor.');
INSERT INTO account_use_types (id, type, description) VALUES (4, 'property manager', 'I''m property manager.');
INSERT INTO account_use_types (id, type, description) VALUES (5, 'own residence', 'I''m doing research to buy or sell my own residence.');
INSERT INTO account_use_types (id, type, description) VALUES (6, 'staff', 'I''m a staff memeber.');

SELECT pg_catalog.setval('account_use_types_id_seq', 6, true);

INSERT INTO auth_group (id, name) VALUES (3, 'Standard Tier');
INSERT INTO auth_group (id, name) VALUES (4, 'Premium Tier');
INSERT INTO auth_group (id, name) VALUES (1, 'Free Tier');
INSERT INTO auth_group (id, name) VALUES (2, 'Basic Tier');

SELECT pg_catalog.setval('auth_group_id_seq', 4, true);

SELECT pg_catalog.setval('auth_group_permissions_id_seq', 1, false);

INSERT INTO auth_permission (id, name, codename) VALUES (2, 'Can change log entry', 'change_logentry');
INSERT INTO auth_permission (id, name, codename) VALUES (3, 'Can delete log entry', 'delete_logentry');
INSERT INTO auth_permission (id, name, codename) VALUES (4, 'Can add permission', 'add_permission');
INSERT INTO auth_permission (id, name, codename) VALUES (5, 'Can change permission', 'change_permission');
INSERT INTO auth_permission (id, name, codename) VALUES (6, 'Can delete permission', 'delete_permission');
INSERT INTO auth_permission (id, name, codename) VALUES (7, 'Can add group', 'add_group');
INSERT INTO auth_permission (id, name, codename) VALUES (8, 'Can change group', 'change_group');
INSERT INTO auth_permission (id, name, codename) VALUES (9, 'Can delete group', 'delete_group');
INSERT INTO auth_permission (id, name, codename) VALUES (10, 'Can add user', 'add_user');
INSERT INTO auth_permission (id, name, codename) VALUES (11, 'Can change user', 'change_user');
INSERT INTO auth_permission (id, name, codename) VALUES (12, 'Can delete user', 'delete_user');
INSERT INTO auth_permission (id, name, codename) VALUES (16, 'Can add session', 'add_session');
INSERT INTO auth_permission (id, name, codename) VALUES (17, 'Can change session', 'change_session');
INSERT INTO auth_permission (id, name, codename) VALUES (18, 'Can delete session', 'delete_session');
INSERT INTO auth_permission (id, name, codename) VALUES (19, 'Unlimited logins', 'unlimited_logins');
INSERT INTO auth_permission (id, name, codename) VALUES (20, 'Can add user account profile', 'add_useraccountprofile');
INSERT INTO auth_permission (id, name, codename) VALUES (21, 'Can change user account profile', 'change_useraccountprofile');
INSERT INTO auth_permission (id, name, codename) VALUES (22, 'Can delete user account profile', 'delete_useraccountprofile');
INSERT INTO auth_permission (id, name, codename) VALUES (29, 'Can add user project', 'add_project');
INSERT INTO auth_permission (id, name, codename) VALUES (30, 'Can change user project', 'change_project');
INSERT INTO auth_permission (id, name, codename) VALUES (31, 'Can delete user project', 'delete_project');
INSERT INTO auth_permission (id, name, codename) VALUES (32, 'Can access staff content', 'access_staff');
INSERT INTO auth_permission (id, name, codename) VALUES (33, 'Can add mls config', 'add_mlsconfig');
INSERT INTO auth_permission (id, name, codename) VALUES (34, 'Can change mls config', 'change_mlsconfig');
INSERT INTO auth_permission (id, name, codename) VALUES (35, 'Can change mls config main property data ', 'change_mlsconfig_mainpropertydata');
INSERT INTO auth_permission (id, name, codename) VALUES (36, 'Can delete mls config', 'delete_mlsconfig');
INSERT INTO auth_permission (id, name, codename) VALUES (37, 'Can add user company', 'add_company');
INSERT INTO auth_permission (id, name, codename) VALUES (38, 'Can change user company', 'change_company');
INSERT INTO auth_permission (id, name, codename) VALUES (39, 'Can delete user company', 'delete_company');
INSERT INTO auth_permission (id, name, codename) VALUES (40, 'Can change mls config server info', 'change_mlsconfig_serverdata');

SELECT pg_catalog.setval('auth_permission_id_seq', 40, true);

INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (5, 'bcrypt$$2a$13$.J08ccjrP4CrZA9TdOlz5.jSAdaFwKSNxHaMBHKwWWV/S8g5YEPdi', '2015-01-30 14:39:00+00', true, 'josh', '', '', 'josh@realtymaps.com', true, true, '2015-01-30 14:39:00+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (7, 'bcrypt$$2a$13$XCwKnvLcRpOch.AWN4SXQujWKEAVzvnhRMe21KdADMFQh3njpGaMC', '2015-03-26 13:17:09.270362+00', true, 'justin', 'Justin', 'Taylor', 'justin@realtymaps.com', true, true, '2015-03-24 20:26:49+00', 4108027727, NULL, NULL, 17, '2037 Bashford Manor Ln.', NULL, '40218', NULL, 6, 'Louisville', NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (3, 'bcrypt$$2a$13$23BIlQK.gOQmrIQfXAt/T.MSKH9.U3tP/gKrJzc75INkkTLVuqg2q', '2014-12-18 19:55:04.491909+00', true, 'nick', '', '', 'nick@realtymaps.com', true, true, '2014-08-19 11:54:49+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (9, 'bcrypt$$2a$13$yCWLLtomGyaz4VMn0j0xk.H7LsBuIRg0hD0Gkj8j4kpD2/AKTSBdK', '2015-05-26 15:20:58.243975+00', true, 'jesse', '', '', 'jesse@realtymaps.com', true, true, '2015-05-26 15:20:23+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (10, 'bcrypt$$2a$13$ez2MItI1xAn0xMPeeHl44evhTsCo2lVDmpeoE.t/fpKaRzj2egIQe', '2014-12-18 19:55:04+00', false, 'load_test', '', '', 'load_test@realtymaps.com', false, true, '2014-08-19 11:54:49+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (1, 'bcrypt$$2a$13$f8djG48PyjfM7T10RzW9ZOGVUn4mwv.C00WRxZrcFrBenDE6MHDgS', '2015-06-18 17:21:58.14846+00', true, 'joe', '', '', 'joe@realtymaps.com', true, true, '2014-08-18 21:37:43.221913+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (2, 'bcrypt$$2a$13$QmZ2fiz8p35BVDvZtb25Iew2JnsQJOWdU7iHbYTsM4HAXFj08.7fu', '2015-01-15 19:25:58.261366+00', true, 'dan', 'Dan', 'Sexton', 'dan@realtymaps.com', true, true, '2014-08-19 11:54:37+00', 2398777853, 2398777853, NULL, 10, '123 Main St.', NULL, '34102', 'www.dansexton.com', NULL, 'Naples', NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (4, 'bcrypt$$2a$13$ZkHO9xazVzp5DNgtyb1uSuvFuhi84Sx8Ktlr9u0KsrUu.3nsb4Brm', '2015-01-30 14:38:48+00', true, 'jon', 'Jon', 'Rubinton', 'jon@rbdevelopmentgroup.com', true, true, '2015-01-30 14:38:48+00', 2395551212, NULL, NULL, 10, '123 Main St.', NULL, '34192', NULL, NULL, 'Naples', NULL);
INSERT INTO auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined, cell_phone, work_phone, account_image_id, us_state_id, address_1, address_2, zip, website_url, account_use_type_id, city, company_id) VALUES (8, 'bcrypt$$2a$13$/9D94D7fqeR4/JC5I0ldGeJVhme87KP6Y6FH0S/8LdxfelASfbiey', '2015-04-16 21:55:44+00', true, 'julie', 'Julie', 'Mategrano', 'julie@realtymaps.com', true, true, '2015-04-16 21:55:44+00', 6302408480, 6302408480, NULL, 14, '1588 Wadham Pl.', NULL, '60189', NULL, NULL, 'Wheaton', NULL);

SELECT pg_catalog.setval('auth_user_groups_id_seq', 1, false);

SELECT pg_catalog.setval('auth_user_id_seq', 10, true);

INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"sqftMax":"3,500","status":["for sale","pending","recently sold"]}', '{"12021_66272840003_001":{"rm_property_id":"12021_66272840003_001","isSaved":true,"isHidden":false},"12021_66272880005_001":{"rm_property_id":"12021_66272880005_001","isSaved":true,"isHidden":false},"12021_66272760002_001":{"rm_property_id":"12021_66272760002_001","isSaved":true,"isHidden":false},"12021_66272600007_001":{"rm_property_id":"12021_66272600007_001","isSaved":true,"isHidden":false},"12021_00238440801_001":{"rm_property_id":"12021_00238440801_001","isSaved":true,"isHidden":false}}', '{"showResults":"false","showDetails":"false","showFilters":"false","showSearch":"true","isFetchingLocation":"false","hasPreviousLocation":"false","showAddresses":"true","showPrices":"true","showLayerPanel":"false"}', '{"center":{"lng":"-81.80175304412842","lat":"26.26388152261401","lon":"-81.7979433528858","latitude":"26.2547026720946","longitude":"-81.7979433528858","zoom":"15","autoDiscover":"false"}}', '{"selectedResultId":"12021_00177000603_001"}', NULL, 5, NULL, NULL, 5, '2015-07-01 14:44:29.305164', '2015-07-01 14:44:29.305164', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"bedsMin":"2","bathsMin":"2","priceMin":"$250,000","priceMax":"$500,000"}', NULL, '{"showResults":"false","showDetails":"false","showFilters":"true","showSearch":"false","isFetchingLocation":"false","hasPreviousLocation":"false","showAddresses":"true","showPrices":"true"}', '{"center":{"lng":"-81.7822265625","lat":"26.056937099247385","lon":"-81.782227","latitude":"26.05678288577881","longitude":"-81.782227","zoom":"12","autoDiscover":"false"}}', '{}', NULL, 8, NULL, NULL, 6, '2015-07-01 14:44:29.305164', '2015-07-01 14:44:29.305164', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"discontinued":"false","auction":"false","status":["for sale","pending"]}', NULL, '{"showResults":"false","showDetails":"false","showFilters":"false","showSearch":"false","isFetchingLocation":"false","hasPreviousLocation":"true","showAddresses":"true","showPrices":"true"}', '{"center":{"lng":"-82.53753662109375","lat":"26.49024045886963","lon":"-81.782227","latitude":"25.944461680551118","longitude":"-81.782227","zoom":"9","autoDiscover":"false"}}', '{}', NULL, 7, NULL, NULL, 3, '2015-07-01 14:44:29.305164', '2015-07-27 18:38:33.448586', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"discontinued":"false","auction":"false","listedDaysMin":"120","bedsMin":"2","ownerName":"Tibstra","status":["for sale"]}', '{"12021_06230880007_001":{"rm_property_id":"12021_06230880007_001","isSaved":true,"isHidden":false}}', '{"showResults":"false","showDetails":"true","showFilters":"false","showSearch":"true","isFetchingLocation":"false","hasPreviousLocation":"true","showAddresses":"true","showPrices":"true","showLayerPanel":"false"}', '{"center":{"lng":"-81.8095850944519","lat":"26.166993659289542","lon":"-81.810749973513","latitude":"26.1658179114509","longitude":"-81.810749973513","zoom":"16","autoDiscover":"false"}}', '{"selectedResultId":"12021_06287480007_001"}', NULL, 1, NULL, NULL, 8, '2015-07-01 14:44:29.305164', '2015-09-25 14:36:38.850014', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"status":["for sale","pending","recently sold"]}', '{"12021_12933560003_001":{"rm_property_id":"12021_12933560003_001","isSaved":true,"isHidden":false},"12021_12985520004_001":{"rm_property_id":"12021_12985520004_001","isSaved":true,"isHidden":false},"12021_12933960001_001":{"rm_property_id":"12021_12933960001_001","isSaved":true,"isHidden":false},"12021_12786960009_001":{"rm_property_id":"12021_12786960009_001","isSaved":true,"isHidden":false}}', '{"showResults":"true","showDetails":"true","showFilters":"false","showSearch":"false","isFetchingLocation":"false","hasPreviousLocation":"true","showAddresses":"true","showPrices":"true","showLayerPanel":"false"}', '{"center":{"lng":"-81.80313169956207","lat":"26.18714115539398","lon":"-81.8031326664726","latitude":"26.1871414930078","longitude":"-81.8031326664726","zoom":"19","autoDiscover":"false"}}', '{"selectedResultId":"12021_13033280004_001"}', NULL, 3, 'profile 1', NULL, 2, '2015-07-01 14:44:29.305164', '2015-09-24 13:49:30.048717', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"bathsMin":"3","status":["for sale"]}', '{"12021_00722880003_001":{"rm_property_id":"12021_00722880003_001","isSaved":true,"isHidden":false}}', '{"showResults":"true","showDetails":"false","showFilters":"false","showSearch":"true","isFetchingLocation":"false","hasPreviousLocation":"true","showAddresses":"true","showPrices":"true","showLayerPanel":"false"}', '{"center":{"lng":"-81.661376953125","lat":"26.184710160832072","lon":"-81.5511310790699","latitude":"26.043519768322884","longitude":"-81.5511310790699","zoom":"11","autoDiscover":"false"}}', '{"selectedResultId":"12021_41712000001_001"}', NULL, 9, NULL, NULL, 9, '2015-07-27 19:59:32.541358', '2015-09-18 16:54:53.741583', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"rm_property_id":"12021_14013160004_001","columns":"all","status":["for sale"]}', '{"12021_11183720005_001":{"rm_property_id":"12021_11183720005_001","isSaved":true,"isHidden":false},"12021_11184480001_001":{"rm_property_id":"12021_11184480001_001","isSaved":true,"isHidden":false},"12021_11184520000_001":{"rm_property_id":"12021_11184520000_001","isSaved":true,"isHidden":false}}', '{"showResults":"false","showDetails":"false","showFilters":"false","showSearch":"false","isFetchingLocation":"false","hasPreviousLocation":"false","showAddresses":"true","showPrices":"true","showLayerPanel":"false"}', '{"center":{"lng":"-81.8006482940326","lat":"26.131698268060227","lon":"-81.8006482940326","latitude":"26.131698268060227","longitude":"-81.8006482940326","zoom":"19"}}', '{"selectedResultId":"12021_14018960005_001"}', NULL, 2, NULL, NULL, 7, '2015-07-01 14:44:29.305164', '2015-09-30 19:10:54.856865', NULL);
INSERT INTO auth_user_profile (filters, properties_selected, map_toggles, map_position, map_results, parent_auth_user_id, auth_user_id, name, project_id, id, rm_inserted_time, rm_modified_time, account_image_id) VALUES ('{"rm_property_id":"12021_11182080005_001","columns":"all"}', '{}', '{"showResults":"true","showDetails":"false","showFilters":"false","showSearch":"false","isFetchingLocation":"false","hasPreviousLocation":"true","showAddresses":"true","showPrices":"true","showLayerPanel":"false"}', '{"center":{"lng":"-81.7955356836319","lat":"26.162955316315024","lon":"-81.7955368069382","latitude":"26.1629540037066","longitude":"-81.7955368069382","zoom":"19","autoDiscover":"false"}}', '{"selectedResultId":"12021_11182080005_001"}', NULL, 4, NULL, NULL, 4, '2015-07-01 14:44:29.305164', '2015-09-10 14:49:00.955796', NULL);

SELECT pg_catalog.setval('auth_user_profile_id_seq', 9, true);

INSERT INTO auth_user_user_permissions (id, user_id, permission_id) VALUES (1, 10, 19);

SELECT pg_catalog.setval('auth_user_user_permissions_id_seq', 1, true);

INSERT INTO company (id, address_1, address_2, city, zip, us_state_id, phone, fax, website_url, account_image_id, name) VALUES (1, '1093 14th Ave. N.', NULL, 'Naples', '34102', 10, '239-877-7853', NULL, NULL, NULL, 'Paradise Realty of Naples');
INSERT INTO company (id, address_1, address_2, city, zip, us_state_id, phone, fax, website_url, account_image_id, name) VALUES (2, '1093 14th Ave. N.', NULL, 'Naples', '34102', 10, '2398777853', NULL, NULL, NULL, 'Paradise Realty of Naples');
INSERT INTO company (id, address_1, address_2, city, zip, us_state_id, phone, fax, website_url, account_image_id, name) VALUES (3, '1093 14th Ave N.', NULL, 'Naples', '34102', 10, '2398777853', NULL, 'www.realtymaps.com', NULL, 'Paradise Realty of Naples');

SELECT pg_catalog.setval('company_id_seq', 3, true);

INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'acres', 0, false, '"Acreage"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'address', 1, true, '{"city":"City","state":"State","streetNum":"Street Number","streetName":"Street Name","zip":"Zip Code","unitNum":"Unit Number","streetSuffix":"Street Suffix","streetDirPrefix":"Compass Point"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'baths_full', 2, false, '"# Full Baths"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'bedrooms', 3, false, '"Bedrooms (All Levels)"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'days_on_market', 4, true, '[null,"Market Time"]', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'fips_code', 5, true, '{"county":"County","stateCode":"State"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'hide_address', 6, false, '""', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'hide_listing', 7, false, '""', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'parcel_id', 8, true, '"Parcel Identification Number"', NULL, '{"stripFormatting":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'price', 9, true, '"List Price"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'rm_property_id', 10, true, '{"county":"County","stateCode":"State","parcelId":"Parcel Identification Number"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'sqft_finished', 11, false, '"Approx Sq Ft"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'status', 12, true, '"Status"', NULL, '{"map":{"Active":"for sale","Back on Market":"for sale","Cancelled":"not for sale","Closed":"recently sold","Contingent":"pending","Expired":"not for sale","New":"for sale","Pending":"pending","Price Change":"for sale","Re-activated":"for sale","Rented":"not for sale","Temporarily No Showings":"for sale","Auction":"for sale"}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'status_display', 13, true, '"Status"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'substatus', 14, true, '"Status"', NULL, '{"map":{"Active":"for sale","Back on Market":"for sale","Cancelled":"discontinued","Closed":"recently sold","Contingent":"pending","Expired":"discontinued","New":"for sale","Pending":"pending","Price Change":"for sale","Re-activated":"for sale","Rented":"discontinued","Temporarily No Showings":"for sale","Auction":"for sale"}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'close_date', 15, false, '"Closed Date"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'sale', 'Selling Agent Full Name', 0, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'discontinued_date', 16, false, '"Off-Market Date"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'base', 'data_source_uuid', 17, true, '"MLS #"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'sale', 'Selling Office Name', 1, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'sale', 'Selling Office Phone', 2, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'lot', 'Parcel Identification Number', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'lot', 'Lot Dimensions', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'lot', 'Lot Description', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'lot', 'Lot Size', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'lot', 'Acreage', 4, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'LP/SqFt', 0, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'ML #', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Property Subtype', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'County Name', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Community Name', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Virtual Tour Link', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Sale Price', 6, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Subdivision Name XP', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'SP/SqFt [w/cents]', 8, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Approx Total Liv Area', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Subdivision Name', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Actual Close Date', 11, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'List Price', 12, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'List Date', 13, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Approx Liv Area', 14, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Property Type', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Bedrooms', 16, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Full Baths', 17, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Half Baths', 18, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', '3/4 Baths', 19, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Year Built', 20, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Lot Sqft', 21, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'general', 'Approximate Acreage', 22, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Manufactured', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Landscape Description', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Internet?  Y/N', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Interior Description', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'House Views', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'House Faces', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Heating Fuel Description', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Property Condition', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Oven Description', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Other Appliance Description', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Heating Description', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Exterior Description', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Condo Conversion Y/N', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Spa Description', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Assoc/Comm Features Desc', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Unit Description', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Gated Y/N', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Lot Description', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Legal Location Township', 1, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Legal Location Section', 2, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Legal Location Range', 3, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Legal LctnTownship (Search)', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Legal Lctn Section (Search)', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Legal Lctn Range (Search)', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Parcel #', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Land Use', 8, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'lot', 'Zoning', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Total # Units in Building', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Total Rental Income $', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Type-Multi', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Net Oper Income $', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Lot Rental (Monthly)', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Fee/Lease $', 6, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', '# Half Baths in Building', 7, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', '# Full Baths in Building', 8, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Township', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Property Type', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Remarks', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Post Directional', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Addtl Zip', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Type Detached', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'General Information', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Type Attached', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Total Full/Half Baths', 17, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', '# Stories', 18, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', '# Rooms', 19, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Master Plan Fee - M,Q,Y,N', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Master Plan Fee Amount', 1, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Tax District', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Annual Property Taxes', 3, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Association Fee Y/N', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Association Fee Includes', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Association Fee 2 - M,Q,Y,N', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Association Fee 2', 7, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'SID/LID Y/N', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'SID/LID Annual Amount', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'SID/LID Balance', 10, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Association Fee 1 - M,Q,Y,N', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Association Fee 1', 12, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Assessment Y/N', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Assessment Amount Type', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'restrictions', 'Assessment Amount', 15, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Sale Type', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Est Clo/Lse dt', 1, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Buyer Broker', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Days from Listing to Close', 3, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Auction Type', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Sold Term', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'sale', 'Auction Date', 6, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Age', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Approx Sq Ft', 21, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Photo', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'MLS #', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'LP/SqFt (w/cents)', 0, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Photo Excluded', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Public Address', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Public Address Y/N', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Record Delete Flag', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Record Delete Date', 5, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Length', 6, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Last Transaction Date', 7, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'MHYrBlt', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Metro Map Page XP', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Metro Map Map Page', 10, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Metro Map Map Coor', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Metro Map Coor XP', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Last Transaction Code', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Last Image Trans Date', 14, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Images', 15, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'IDX', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'DocumentFolderID', 17, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'DocumentFolderCount', 18, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Court Approval', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Compass Point', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'CommentaryY/N', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Sort Price', 22, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'T Status Date', 23, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'SP/LP', 24, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Temp Off Mrkt Status Desc', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Width', 26, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'zUnused', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Subdivision Number', 28, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Subdivision # (Search)', 29, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'hidden', 'Baths Total', 30, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', 'Bedrooms (All Levels)', 24, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'general', '# Full Baths', 25, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'location', 'Year Round School', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'location', 'Jr High School', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'location', 'High School', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'location', 'Elementary School 3-5', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'location', 'Elementary School K-2', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Loft Dimensions 2ndFloor', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'acres', 0, false, '"Approximate Acreage"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'address', 1, true, '{"city":"City/Town","state":"State","streetName":"Street Name","streetNum":"Street Number","zip":"Zip Code","unitNum":"UnitNumber"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'baths_full', 2, false, '"Full Baths"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'bedrooms', 3, false, '"Bedrooms"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'days_on_market', 4, true, '[null,"Active DOM"]', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'fips_code', 5, true, '{"stateCode":"State","county":"County Name"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Loft Dimensions 1stFloor', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'LOFT Dim', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Loft Description', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Living Room Dimensions', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Living Room Description', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Master Bath Desc', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Master Bedroom Description', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Great Room Y/N', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Great Room Dimensions', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'hide_address', 6, false, '""', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'hide_listing', 7, false, '""', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'parcel_id', 8, true, '"Parcel #"', NULL, '{"stripFormatting":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'price', 9, true, '"List Price"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'rm_property_id', 10, true, '{"county":"County Name","stateCode":"State","parcelId":"Parcel #"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'sqft_finished', 11, false, '"Approx Liv Area"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Great Room Description', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Family Room Dimensions', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Family Room Description', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'DEN Dim', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Dining Room Dimensions', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', 'Master Bedroom Dimensions', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', '2nd Bedroom Dimensions', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', '3rd Bedroom Dimensions', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', '4th Bedroom Dimensions', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'dimensions', '5th Bedroom Dimensions', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'LO Phone', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'LO Name', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'List Office Code', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'List Agent Public ID', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'LA Name', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'LA Phone', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'Fax #', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'contacts', 'Email', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'NOD Date', 0, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Repo/Reo Y/N', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Litigation Type', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Litigation', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Lease End', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Miscellaneous Description', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Model', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Open House Flag', 7, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Entry Date', 8, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'DOM', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Directions', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Converted to Real Property', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Contingency Desc', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'AVM Y/N', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'status', 12, true, '"Status"', NULL, '{"map":{"Active-Exclusive Right":"for sale","Exclusive Agency":"for sale","Auction":"for sale","Contingent Offer":"pending","Pending Offer":"pending","Closed":"recently sold","Temporarily Off The Market":"not for sale","Model":"not for sale","Expired":"not for sale","Withdrawn Conditional":"not for sale","Withdrawn Unconditional":"not for sale"}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'status_display', 13, true, '"Status"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'substatus', 14, true, '"Status"', NULL, '{"map":{"Active-Exclusive Right":"for sale","Exclusive Agency":"for sale","Auction":"auction","Contingent Offer":"pending","Pending Offer":"pending","Closed":"not for sale","Leased":"not for sale","Temporarily Off The Market":"discontinued","Withdrawn Unconditional":"discontinued","Withdrawn Conditional":"discontinued","Expired":"discontinued","Comp Only Sold":"not for sale"}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'close_date', 15, false, '"Actual Close Date"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'discontinued_date', 16, false, '""', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'base', 'data_source_uuid', 17, true, '"sysid"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Ground Mounted? Y/N', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Green Year Certified', 1, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Green Features', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Green Certifying Body', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Green Certification Rating', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Green Building Certification', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Sewer', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Type', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Garage Description', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Garage', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Parking Description', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Roof Description', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Utility Information', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Carport Description', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Carport', 14, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Built Description', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Building Number', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'building', 'Builder/Manufacturer', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Internet Listing', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Omt', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'IDX Status', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Solar Electric', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Fence', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Pool Width', 19, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Pool Length', 20, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Pool Description', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'PvSpa', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'PvPool', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Refrigerator Included', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Studio Y/N', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Washer Dryer Location', 26, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Washer Included?', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Water', 28, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Water Heater Description', 29, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Approx Addl Liv Area', 30, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Age Restricted Y/N', 31, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Fireplace Description', 32, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Flooring Description', 33, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Fireplace Location', 34, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Fireplaces', 35, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Fence Type', 36, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Equestrian Description', 37, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Energy Description', 38, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Dryer Utilities', 39, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Dryer Included?', 40, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Disposal Included', 41, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Dishwasher Inc', 42, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Cooling System', 43, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Cooling Fuel Description', 44, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Converted Garage', 45, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Construction Description', 46, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Bedrooms (Total Possible #)', 47, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Bedroom Downstairs? Y/N', 48, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Bath Downstairs? Y/N', 49, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Bath Downstairs Description', 50, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Accessibility Features', 51, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', '5th Bedroom Description', 52, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', '4th Bedroom Description', 53, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', '3rd Bedroom Description', 54, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', '2nd Bedroom Description', 55, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', '#Loft', 56, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', '#Den/Other', 57, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Kitchen Description', 58, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Ownership', 59, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Bldg Desc', 60, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Furnishings Description', 61, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Dining Room Description', 62, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'details', 'Property Description', 63, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Listing On Internet YN', 0, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Property Addresson Internet YN', 1, false, 'null', NULL, '{"advanced":false,"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Active Open House Count', 2, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Bedrooms', 3, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Internet Sites', 4, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'MLS', 5, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Photo Count', 6, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Photo Modification Timestamp', 7, false, 'null', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Table', 8, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Virtual Tour URL', 9, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Blogging YN', 10, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Co List Office MUI', 11, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Co List Office MLSID', 12, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Co List Agent MUI', 13, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'List Agent MUI', 14, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'List Agent MLSID', 15, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'List Office MUI', 16, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'List Office MLSID', 17, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Selling Agent MUI', 18, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Selling Agent MLSID', 19, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Franchisor Feed(y/n)', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'listing', 'Original List Price', 1, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'List Date Received', 5, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'North', 0, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Grid', 1, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'East', 2, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Waterfront (Y/N)', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'West', 4, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'South', 5, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Subdivision', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Latitude', 7, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Area Amenities', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Other Public Sch Dist', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', '2nd/Alternate Elementary School', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Property Information', 0, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Furnished Desc', 1, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Building Design', 2, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Ownership Desc', 3, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Amenities', 4, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Guest House Desc', 5, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Baths Total', 0, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'List Price', 1, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Conditional Date', 2, false, 'null', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Close Date', 3, false, 'null', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Close Price', 4, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Acres', 5, false, 'null', NULL, '{"nullZero":true,"advanced":false,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Approx Living Area', 6, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Total Area', 7, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Price Per Sq Ft', 8, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Sell Price Per Sq Ft', 9, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'DOM', 10, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'CDOM', 11, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Baths Full', 12, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Baths Half', 13, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Beds Total', 14, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'general', 'Year Built', 15, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Guest House Living Area', 6, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Room Count', 7, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Kitchen Description', 8, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Dining Description', 9, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Bedroom Desc', 10, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Master Bath Description', 11, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Equipment', 12, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Flooring', 13, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Numberof Ceiling Fans', 14, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Cooling', 15, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Heat', 16, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Interior Features', 17, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Exterior Features', 18, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Parking', 19, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Storm Protection', 20, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Community Type', 21, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Floor Plan Type', 22, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Additional Rooms', 23, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Private Pool Desc', 24, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Private Pool YN', 25, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Private Spa Desc', 26, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Private Spa YN', 27, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Cable Available YN', 28, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Management', 29, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'Maintenance', 30, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Selling Office MUI', 20, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Selling Office MLSID', 21, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'hidden', 'Current Price', 22, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Show (Additional)', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Area', 15, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'StatusChangeDate', 16, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Foreclosure Commenced Y/N', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Financing Considered', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Existing Rent', 19, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Earnest Deposit', 20, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Buyer Agent Public ID', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Association Phone', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Association Name', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Additional AU Sold Terms', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Owner Licensee', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Photo Instructions', 26, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Possession Description', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Power On or Off', 28, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Previous Price', 29, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'PriceChgDate', 30, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Realtor? Y/N', 31, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Sale Office Bonus', 32, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Sellers Contribution $', 33, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Short Sale', 34, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'sysid', 35, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Amt Owner Will Carry', 36, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Active DOM', 37, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('GLVAR', 'realtor', 'Acceptance Date', 38, false, '""', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Board Number', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Misc $', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Lowest Parking Fee', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Coop Tax Deduction Year', 2, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Coop Annual Tax Deduction', 3, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Buyer Entry Fee', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Amt', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Tax Exemptions', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Taxes', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Tax Year', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Special Service Area Fee', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Special Service Area', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Special Assessments', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Updated Date', 9, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Brand Name', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Virtual Tour Date', 11, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Update Date', 12, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'VOW Comments/Reviews (Y/N)', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'VOW AVM (Y/N)', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Vehicle Tax', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Vehicle Identification Number', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Additional Media Type 1', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', '3x5 Color', 18, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Additional Media Type 2', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Additional Tipout Size', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', '8x10 Color', 21, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Additional Media URL 2', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Remarks On Internet? (Y/N)', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Managing Broker (Y/N)', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Are any property photos virtually staged?', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Virtual Tour', 26, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Othr Public Sch', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Longitude', 12, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', '2nd/Alternate Jr High/Middle School', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', '2nd/Alternate High School', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Corporate Limits', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'County', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Jr High/Middle School', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Jr High/Middle Dist', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Park Name', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Park Amenities', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Elementary School', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Elementary Sch Dist', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'Directions', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'High School', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'location', 'High Sch Dist', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 4 Size', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 3 Size', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 8 Size', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 10 Size', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Master Bedroom Size', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 5 Size', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Kitchen Size', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 6 Size', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Living Room Size', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 7 Size', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Laundry Size', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Dining Room Size', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Family Room Size', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', '2nd Bedroom Size', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', '3rd Bedroom Size', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'details', 'View', 31, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Created Date', 0, false, 'null', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Original List Price', 1, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Last Change Timestamp', 2, false, 'null', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Last Change Type', 3, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Status Type', 4, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Property Type', 5, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Foreclosed REOYN', 6, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Potential Short Sale YN', 7, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Possession', 8, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Sourceof Measure Living Area', 9, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Sourceof Measure Lot Dimensions', 10, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Sourceof Measurements', 11, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Sourceof Measure Total Area', 12, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'listing', 'Special Information', 13, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Garage Dimension', 0, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Building Desc', 1, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character","choices":{"Traditional":""}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Building Number', 2, false, 'null', NULL, '{"advanced":false,"nullEmpty":false,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Carport Desc', 3, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Property Address On Internet? (Y/N)', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', 'Additional Media URL 1', 28, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'hidden', '5x7 Color', 29, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Carport Spaces', 4, false, 'null', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Construction', 5, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Elevator', 6, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Garage Desc', 7, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Garage Spaces', 8, false, 'null', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Roof', 9, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Builder Product YN', 10, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Exterior Finish', 11, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Windows', 12, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Num Unit Floor', 13, false, 'null', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Total Floors', 14, false, 'null', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Unit Count', 15, false, 'null', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Unit Floor', 16, false, 'null', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Unitsin Building', 17, false, 'null', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'building', 'Unitsin Complex', 18, false, 'null', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Parcel Number', 0, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Lot Desc', 1, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 2 Size', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', 'Addtl Room 1 Size', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'dimensions', '4th Bedroom Size', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'rm_property_id', 0, true, '{"county":"County Or Parish","stateCode":"State Or Province","parcelId":"Parcel Number"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'fips_code', 1, true, '{"county":"County Or Parish","stateCode":"State Or Province"}', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'parcel_id', 2, true, '"Parcel Number"', NULL, '{"stripFormatting":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'address', 3, true, '{"streetNum":"Street Number","streetName":"Street Name","state":"State Or Province","zip":"Postal Code","zip9":"Postal Code Plus 4","streetDirPrefix":"Street Dir Prefix","streetDirSuffix":"Street Dir Suffix","streetNumSuffix":"Street Number Modifier","streetFull":"Full Address","unitNum":"Unit Number","city":"City","streetSuffix":"Street Suffix"}', NULL, '{"advanced":false}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'price', 4, true, '"Current Price"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'days_on_market', 5, true, '["CDOM","DOM"]', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'bedrooms', 6, false, '"Beds Total"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'baths_full', 7, false, '"Baths Full"', NULL, '{"advanced":false}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'acres', 8, false, '"Acres"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'sqft_finished', 9, false, '"Approx Living Area"', NULL, '{"advanced":false}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'status', 10, true, '"Status"', NULL, '{"choices":{"Active":"for sale","Active Contingent":"for sale","Application In Progress":"for sale","Act Cont Short Sale":"for sale","Incoming":"for sale","Pending":"pending","Pending With Contingencies":"pending","Rented":"not for sale","Sold":"recently sold","Terminated":"not for sale","Withdrawn":"not for sale","Expired":"not for sale"},"map":{"Active":"for sale","Active Contingent":"for sale","Application In Progress":"pending","Act Cont Short Sale":"for sale","Incoming":"for sale","Pending":"pending","Pending With Contingencies":"pending","Rented":"not for sale","Sold":"recently sold","Terminated":"not for sale","Withdrawn":"not for sale","Expired":"not for sale"},"advanced":false}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'substatus', 11, true, '"Status"', NULL, '{"choices":{"Active":"for sale","Active Contingent":"for sale","Application In Progress":"for sale","Act Cont Short Sale":"for sale","Incoming":"for sale","Pending":"pending","Pending With Contingencies":"pending","Rented":"discontinued","Sold":"recently sold","Terminated":"discontinued","Withdrawn":"discontinued","Expired":"discontinued"},"map":{"Active":"for sale","Active Contingent":"for sale","Application In Progress":"pending","Act Cont Short Sale":"for sale","Incoming":"for sale","Pending":"pending","Pending With Contingencies":"pending","Rented":"discontinued","Sold":"recently sold","Terminated":"discontinued","Withdrawn":"discontinued","Expired":"discontinued"}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'status_display', 12, true, '"Status"', NULL, '{"choices":{"Act Cont Short Sale":"Active Contingent Short Sale"},"map":{"Act Cont Short Sale":"Active Contingent Short Sale"}}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'hide_address', 13, true, '"Property Addresson Internet YN"', NULL, '{"advanced":false,"invert":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'data_source_uuid', 14, true, '"MLS Number"', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'close_date', 15, false, '"Close Date"', NULL, '{"advanced":false}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'hide_listing', 16, false, '"Listing On Internet YN"', NULL, '{"invert":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'base', 'discontinued_date', 17, false, '""', NULL, '{}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 4 Flooring', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 10 Flooring', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Tenant Pays - Unit 4', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 4 Level', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 3 Name', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 3 Level', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 3 Flooring', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 10 Level', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Unit Floor Level', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 10 Name', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 10 Window Treatments', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Tenant Pays - Unit 3', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 4 Name', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 4 Window Treatments', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 3 Window Treatments', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Tenant Pays - Unit 2', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'realtor', 'Matrix Unique ID', 0, false, 'null', NULL, '{"DataType":"Long","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'realtor', 'Matrix Modified DT', 1, false, 'null', NULL, '{"DataType":"DateTime"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'realtor', 'MLS Number', 2, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Tenant Pays - Unit 1', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Security Deposit', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Sec Deposit $ - Unit 4', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Sec Deposit $ - Unit 3', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Sec Deposit $ - Unit 2', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Sec Deposit $ - Unit 1', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Repairs / Maintenance $', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Rent $ - Unit 4', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Rent $ - Unit 3', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Rent $ - Unit 2', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Lot Frontage', 2, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Lot Back', 3, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Lot Left', 4, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Lot Right', 5, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Rear Exposure', 6, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Gulf Access YN', 7, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Gulf Access Type', 8, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Boat Access', 9, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Rent $ - Unit 1', 26, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Possession', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Parking Ownership', 28, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Other Addl Income', 29, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Mobile Home Features', 30, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Bath-Unit 4', 31, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Bath-Unit 3', 32, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Bath-Unit 2', 33, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Bath-Unit 1', 34, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Management Phone', 35, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Canal Width', 10, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Waterfront Desc', 11, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Waterfront YN', 12, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Irrigation', 13, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Legal Desc', 14, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Legal Unit', 15, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Lot Unit', 16, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Road', 17, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Sewer', 18, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Water', 19, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'lot', 'Zoning Code', 20, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'MLS Area Major', 0, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'County Or Parish', 1, false, 'null', NULL, '{"transformString":"forceInitCaps","nullEmpty":false,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Development', 2, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Development Name', 3, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Sub Condo Name', 4, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Subdivision Number', 5, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Elementary School', 6, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Middle School', 7, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'High School', 8, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Block', 9, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Range', 10, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Section', 11, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'location', 'Township', 12, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Management Contact Name', 36, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Management Company', 37, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Management', 38, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Lease Exp Date (Mo/Yr) - Unit 4', 39, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Lease Exp Date (Mo/Yr) - Unit 3', 40, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Lease Exp Date (Mo/Yr) - Unit 2', 41, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Lease Exp Date (Mo/Yr) - Unit 1', 42, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Bdrms - Unit 4', 43, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Bdrms - Unit 3', 44, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Bdrms - Unit 2', 45, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Bdrms - Unit 1', 46, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Half Baths-Unit 4', 47, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Half Baths-Unit 3', 48, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Restrictions', 0, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Approval', 1, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Pets', 2, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Pets Limit Max Number', 3, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Pets Limit Max Weight', 4, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Pets Limit Other', 5, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Min Daysof Lease', 6, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Lease Limits YN', 7, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Leases Per Year', 8, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Amenity Rec Fee', 9, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Amen Rec Freq', 10, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Application Fee', 11, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Condo Fee', 12, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Condo Fee Freq', 13, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Mandatory HOAYN', 14, false, 'null', NULL, '{"DataType":"Boolean"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'HOA Desc', 15, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'HOA Fee', 16, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'HOA Fee Freq', 17, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Master HOA Fee', 18, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Master HOA Fee Freq', 19, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Association Mngmt Phone', 20, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Land Lease Fee', 21, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Land Lease Fee Freq', 22, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Mandatory Club Fee', 23, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Mandatory Club Fee Freq', 24, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'One Time Land Lease Fee', 25, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'One Time Mandatory Club Fee', 26, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'One Time Othe Fee', 27, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'One Time Rec Lease Fee', 28, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'One Time Special Assessment Fee', 29, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Special Assessment', 30, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Special Assessment Fee Freq', 31, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Tax Desc', 32, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Tax District Type', 33, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Taxes', 34, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Tax Year', 35, false, 'null', NULL, '{"DataType":"Int","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'restrictions', 'Transfer Fee', 36, false, 'null', NULL, '{"DataType":"Decimal","nullZero":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'List Agent Full Name', 0, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'List Agent Direct Work Phone', 1, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'List Office Name', 2, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'List Office Phone', 3, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'Co List Agent Full Name', 4, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'Co List Office Name', 5, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('swflmls', 'contacts', 'Co List Office Phone', 6, false, 'null', NULL, '{"DataType":"Character","nullEmpty":true}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Half Baths-Unit 2', 49, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Half Baths-Unit 1', 50, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Full Baths-Unit 4', 51, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Full Baths-Unit 3', 52, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Full Baths-Unit 2', 53, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Full Baths-Unit 1', 54, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Land Incl (Y/N)', 55, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Is Parking Included in Price', 56, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Heat $', 57, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Gross Rental Income $', 58, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Gross Expenses $', 59, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Gas $', 60, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Garage On-Site', 61, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Floor # - Unit 4', 62, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Floor # - Unit 3', 63, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Floor # - Unit 2', 64, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Floor # - Unit 1', 65, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Estimated Occupancy Date', 66, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Equipment', 67, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Electricity', 68, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Electricity Expense', 69, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Driveway', 70, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Down Payment Resource', 71, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Doublewide (Y/N)', 72, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Appliances/Features Unit 3', 73, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Appliances/Features Unit 4', 74, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Rooms - Unit 1', 75, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Rooms - Unit 2', 76, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Rooms - Unit 3', 77, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '3 Br Un In Bldg (Y/N)', 78, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Rooms - Unit 4', 79, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Appliances/Features Unit 2', 80, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Appliances/Features Unit 1', 81, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 5 Name', 83, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 5 Level', 84, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 5 Flooring', 85, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '% Common Area/Coop/Condo Ownership', 86, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Of Cars', 87, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Zoning Type', 88, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Water/Sewer $', 89, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Water', 90, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Short Sale', 91, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Sewer', 92, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 8 Name', 93, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Basement Bathrooms (Y/N)', 94, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Sale Includes', 95, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Pet Information', 96, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Roof Type', 97, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Recent Rehab (Y/N)', 98, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Living Room Level', 99, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Parking Details', 100, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Bath', 101, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Pets Allowed (Y/N)', 102, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Parking', 103, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Parking On-Site', 104, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'New Construction', 105, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'New/Proposed Construction Options', 106, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Window Treatments', 107, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Level', 108, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Master Bedroom Flooring', 109, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Living Room Flooring', 110, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Laundry Window Treatments', 111, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Laundry Flooring', 112, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Living Room Window Treatments', 113, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Laundry Level', 114, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Heat/Fuel', 115, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Interior Fireplaces', 116, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Bath Amenities', 117, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Attic', 118, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 9 Size', 119, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 9 Window Treatments', 120, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Fireplace Details', 121, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 9 Name', 122, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 9 Level', 123, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 9 Flooring', 124, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 8 Level', 125, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 7 Level', 126, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 8 Window Treatments', 127, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 8 Flooring', 128, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 5 Window Treatments', 129, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 7 Window Treatments', 130, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 7 Name', 131, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 6 Name', 132, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 7 Flooring', 133, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 6 Level', 134, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 6 Flooring', 135, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Interior Property Features', 136, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 6 Window Treatments', 137, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Kitchen Window Treatments', 138, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Kitchen Level', 139, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Kitchen Type', 140, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Garage Type', 141, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Kitchen Flooring', 142, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Garage Details', 143, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Fireplace Location', 144, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Garage Ownership', 145, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '2nd Bedroom Window Treatments', 146, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Family Room Flooring', 147, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Exterior Property Features', 148, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Family Room Level', 149, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Family Room Window Treatments', 150, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Dining Room', 151, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Dining Room Window Treatments', 152, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Dining Room Level', 153, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Dining Room Flooring', 154, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Common Area Amenities', 155, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 1 Flooring', 156, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 1 Name', 157, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 1 Level', 158, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '4th Bedroom Window Treatments', 159, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Bedrooms (Above Grade)', 160, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 2 Flooring', 161, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Bedrooms (Below Grade)', 162, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 2 Window Treatments', 163, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Additional Rooms', 164, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 2 Name', 165, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 2 Level', 166, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '3rd Bedroom Level', 167, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Addtl Room 1 Window Treatments', 168, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '4th Bedroom Flooring', 169, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '4th Bedroom Level', 170, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '3rd Bedroom Window Treatments', 171, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '3rd Bedroom Flooring', 172, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Basement Description', 173, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '2nd Bedroom Level', 174, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '2nd Bedroom Flooring', 175, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Basement', 176, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', '# Half Baths', 177, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Approx Year Built', 178, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Appliances', 179, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'details', 'Air Conditioning', 180, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'List Office Location ID', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Owner''s Name', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Owner''s Phone', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office State', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Zip Code', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Website', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Street Number', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Street Name', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Name', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Phone Number', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office City', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office ID', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Fax Number', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Zip Code', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Office Email Address', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Street Name', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Street Number', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent State', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Pager Number', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent First Name', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Office Phone', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent ID', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Last Name', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Fax Number', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Email Address', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent City', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Additional Info', 26, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Cell Phone', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Listing Agent Additional Address', 28, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'contacts', 'Co-Lister ID', 29, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Showing Instructions', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Agent Remarks', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Lock Box Type', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Compensation paid on', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Ownership', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Expiration Date', 7, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Mobile Home Size', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Energy/Green Building Rating Source', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Disability Access/Equipment Details', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Disability Access and/or Equipped', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Style Of House', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Exterior Building Type', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Model', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Built Before 1978 (Y/N)', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Green Supporting Documents', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'HERS Index Score', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Green Features', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Foundation', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Existing Basement/Foundation', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', 'Exposure', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', '# Parking Spaces', 14, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'building', '# Garage Spaces', 15, false, '""', NULL, '{"nullZero":true,"DataType":"Decimal"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Park Approval (Y/N)', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Janitorial $', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Master Association Fee', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Master Association Fee($)', 15, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Frequency', 16, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Assessment Includes', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Highest Parking Fee', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Mgmnt Fee $', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Insurance $', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Max Pet Weight', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Scavenger $', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Parking Fee/Lease $', 23, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Deeded Garage Cost', 24, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Deeded Parking Cost', 25, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'restrictions', 'Assessment/Association Dues $', 26, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Cooperative  Compensation', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', '% Owner Occupied', 9, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Continue to Show?', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Back on Market Date', 11, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Attached Disclosures', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Secure ShowingAssist Instructions', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Area', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Agent Owned/Interest (Y/N)', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', '# Of Days For Bd Apprvl', 16, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'realtor', 'Contract Date', 17, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office State', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Finance Code', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Zip Code', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Website', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Street Number', 4, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office City', 5, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Street Name', 6, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Name', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Phone Number', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office ID', 9, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Fax Number', 10, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Office Email Address', 11, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Pager Number', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Zip Code', 13, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Street Number', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Street Name', 15, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Sale Price', 16, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent State', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Office Phone', 18, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent First Name', 19, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Last Name', 20, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent ID', 21, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Email Address', 22, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Cell Phone', 23, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Fax Number', 24, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Seller Concessions Amount/Points', 25, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent City', 26, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Selling Agent Additional Address', 27, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Sale Terms', 28, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Seller Concessions', 29, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Sale Office Location ID', 30, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'sale', 'Additional Sales Information', 31, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Market Code', 0, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'MLS # of Rental (if known)', 1, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Virtual Tour Url', 2, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Square Feet Source', 3, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Status Date', 4, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Photo Date', 5, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Photo Count', 6, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Contingency Flag', 7, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Listing Type', 8, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'List Date', 9, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Listing Market Time', 10, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Auction Date', 11, false, '""', NULL, '{"DataType":"Date"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Multiple Pin Numbers (Y/N)', 12, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Market Time', 13, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Offered for Sale or Rent', 14, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Original List Price', 15, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Opening Bid/Reserve Price', 16, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'Auction Price Description', 17, false, '""', NULL, '{"nullEmpty":true,"DataType":"Character"}', 'mls', 'listing');
INSERT INTO data_normalization_config (data_source_id, list, output, ordering, required, input, transform, config, data_source_type, data_type) VALUES ('MRED', 'listing', 'List Price', 18, false, '""', NULL, '{"nullZero":true,"DataType":"Int"}', 'mls', 'listing');

INSERT INTO external_accounts (id, name, username, password, api_key, other) VALUES (1, 'heroku', '8CeiTSxFMByFw5+39D0eOg==$$sd4Z9Zhat9xzYQ2DVHHJQEPy26ZA8cU=$', 'TJBpZg4B/WjR0aZxMPiBHw==$$R50hpjQ1gQZTsmLuUP8b1TxXTQ==$', 'V7zMdXTV56HS42b6OYFthQ==$$u8f1opqyRoNIoa1hwhfD9diF63uXT6apKoXOeMeJj6N5Hkn5$', NULL);
INSERT INTO external_accounts (id, name, username, password, api_key, other) VALUES (2, 'digimaps', 'qA/+HXav3N7pn+vo01jzyQ==$$4vZeyxKA4KGh3kXCsA==$', '73YIq2m3GWc9S/642Q2U+A==$$OTVAIGwh+g==$', NULL, '{"URL":"0OvdNT2/xiWVS3K7mWOPuQ==$$jCGay+ELVEcI+gxu4XA=$"}');

SELECT pg_catalog.setval('external_accounts_id_seq', 2, true);

INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Autauga', '01001');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Baldwin', '01003');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Barbour', '01005');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Bibb', '01007');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Blount', '01009');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Bullock', '01011');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Butler', '01013');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Calhoun', '01015');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Chambers', '01017');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Cherokee', '01019');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Chilton', '01021');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Choctaw', '01023');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Clarke', '01025');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Clay', '01027');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Cleburne', '01029');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Coffee', '01031');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Colbert', '01033');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Conecuh', '01035');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Coosa', '01037');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Covington', '01039');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Crenshaw', '01041');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Cullman', '01043');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Dale', '01045');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Dallas', '01047');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'De Kalb', '01049');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Elmore', '01051');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Escambia', '01053');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Etowah', '01055');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Fayette', '01057');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Franklin', '01059');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Geneva', '01061');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Greene', '01063');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Hale', '01065');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Henry', '01067');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Houston', '01069');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Jackson', '01071');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Jefferson', '01073');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Lamar', '01075');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Lauderdale', '01077');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Lawrence', '01079');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Lee', '01081');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Limestone', '01083');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Lowndes', '01085');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Macon', '01087');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Madison', '01089');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Marengo', '01091');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Marion', '01093');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Marshall', '01095');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Mobile', '01097');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Monroe', '01099');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Montgomery', '01101');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Morgan', '01103');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Perry', '01105');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Pickens', '01107');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Pike', '01109');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Randolph', '01111');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Russell', '01113');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'St Clair', '01115');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Shelby', '01117');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Sumter', '01119');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Talladega', '01121');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Tallapoosa', '01123');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Tuscaloosa', '01125');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Walker', '01127');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Washington', '01129');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Wilcox', '01131');
INSERT INTO fips_lookup (state, county, code) VALUES ('AL', 'Winston', '01133');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Aleutians East', '02013');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Aleutians West', '02016');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Anchorage', '02020');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Bethel', '02050');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Bristol Bay', '02060');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Denali', '02068');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Dillingham', '02070');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Fairbanks North Star', '02090');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Haines', '02100');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Juneau', '02110');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Kenai Peninsula', '02122');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Ketchikan Gateway', '02130');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Kodiak Island', '02150');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Lake and Peninsula', '02164');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Matanuska Susitna', '02170');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Nome', '02180');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'North Slope', '02185');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Northwest Arctic', '02188');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Prince Wales Ketchikan', '02201');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Sitka', '02220');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Skagway Hoonah Angoon', '02232');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Southeast Fairbanks', '02240');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Valdez Cordova', '02261');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Wade Hampton', '02270');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Wrangell Petersburg', '02280');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Yakutat', '02282');
INSERT INTO fips_lookup (state, county, code) VALUES ('AK', 'Yukon Koyukuk', '02290');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Apache', '04001');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Cochise', '04003');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Coconino', '04005');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Gila', '04007');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Graham', '04009');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Greenlee', '04011');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'La Paz', '04012');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Maricopa', '04013');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Mohave', '04015');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Navajo', '04017');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Pima', '04019');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Pinal', '04021');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Santa Cruz', '04023');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Yavapai', '04025');
INSERT INTO fips_lookup (state, county, code) VALUES ('AZ', 'Yuma', '04027');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Arkansas', '05001');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Ashley', '05003');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Baxter', '05005');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Benton', '05007');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Boone', '05009');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Bradley', '05011');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Calhoun', '05013');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Carroll', '05015');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Chicot', '05017');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Clark', '05019');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Clay', '05021');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Cleburne', '05023');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Cleveland', '05025');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Columbia', '05027');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Conway', '05029');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Craighead', '05031');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Crawford', '05033');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Crittenden', '05035');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Cross', '05037');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Dallas', '05039');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Desha', '05041');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Drew', '05043');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Faulkner', '05045');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Franklin', '05047');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Fulton', '05049');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Garland', '05051');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Grant', '05053');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Greene', '05055');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Hempstead', '05057');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Hot Spring', '05059');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Howard', '05061');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Independence', '05063');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Izard', '05065');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Jackson', '05067');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Jefferson', '05069');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Johnson', '05071');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Lafayette', '05073');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Lawrence', '05075');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Lee', '05077');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Lincoln', '05079');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Little River', '05081');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Logan', '05083');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Lonoke', '05085');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Madison', '05087');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Marion', '05089');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Miller', '05091');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Mississippi', '05093');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Monroe', '05095');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Nevada', '05099');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Newton', '05101');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Ouachita', '05103');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Perry', '05105');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Phillips', '05107');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Pike', '05109');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Poinsett', '05111');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Polk', '05113');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Pope', '05115');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Prairie', '05117');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Pulaski', '05119');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Randolph', '05121');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'St Francis', '05123');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Saline', '05125');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Scott', '05127');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Searcy', '05129');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Sebastian', '05131');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Sevier', '05133');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Sharp', '05135');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Stone', '05137');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Union', '05139');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Van Buren', '05141');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Washington', '05143');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'White', '05145');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Woodruff', '05147');
INSERT INTO fips_lookup (state, county, code) VALUES ('AR', 'Yell', '05149');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Alameda', '06001');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Alpine', '06003');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Amador', '06005');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Butte', '06007');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Calaveras', '06009');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Colusa', '06011');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Contra Costa', '06013');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Del Norte', '06015');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'El Dorado', '06017');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Fresno', '06019');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Glenn', '06021');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Humboldt', '06023');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Imperial', '06025');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Inyo', '06027');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Kern', '06029');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Kings', '06031');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Lake', '06033');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Lassen', '06035');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Los Angeles', '06037');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Madera', '06039');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Marin', '06041');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Mariposa', '06043');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Mendocino', '06045');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Merced', '06047');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Modoc', '06049');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Mono', '06051');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Monterey', '06053');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Napa', '06055');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Nevada', '06057');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Orange', '06059');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Placer', '06061');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Plumas', '06063');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Riverside', '06065');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Sacramento', '06067');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Benito', '06069');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Bernardino', '06071');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Diego', '06073');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Francisco', '06075');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Joaquin', '06077');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Luis Obispo', '06079');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'San Mateo', '06081');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Santa Barbara', '06083');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Santa Clara', '06085');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Santa Cruz', '06087');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Shasta', '06089');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Sierra', '06091');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Siskiyou', '06093');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Solano', '06095');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Sonoma', '06097');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Stanislaus', '06099');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Sutter', '06101');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Tehama', '06103');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Trinity', '06105');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Tulare', '06107');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Tuolumne', '06109');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Ventura', '06111');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Yolo', '06113');
INSERT INTO fips_lookup (state, county, code) VALUES ('CA', 'Yuba', '06115');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Adams', '08001');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Alamosa', '08003');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Arapahoe', '08005');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Archuleta', '08007');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Baca', '08009');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Bent', '08011');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Boulder', '08013');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Broomfield', '08014');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Chaffee', '08015');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Cheyenne', '08017');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Clear Creek', '08019');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Conejos', '08021');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Costilla', '08023');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Crowley', '08025');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Custer', '08027');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Delta', '08029');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Denver', '08031');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Dolores', '08033');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Douglas', '08035');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Eagle', '08037');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Elbert', '08039');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'El Paso', '08041');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Fremont', '08043');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Garfield', '08045');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Gilpin', '08047');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Grand', '08049');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Gunnison', '08051');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Hinsdale', '08053');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Huerfano', '08055');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Jackson', '08057');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Jefferson', '08059');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Kiowa', '08061');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Kit Carson', '08063');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Lake', '08065');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'La Plata', '08067');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Larimer', '08069');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Las Animas', '08071');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Lincoln', '08073');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Logan', '08075');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Mesa', '08077');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Mineral', '08079');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Moffat', '08081');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Montezuma', '08083');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Montrose', '08085');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Morgan', '08087');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Otero', '08089');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Ouray', '08091');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Park', '08093');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Phillips', '08095');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Pitkin', '08097');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Prowers', '08099');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Pueblo', '08101');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Rio Blanco', '08103');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Rio Grande', '08105');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Routt', '08107');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Saguache', '08109');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'San Juan', '08111');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'San Miguel', '08113');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Sedgwick', '08115');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Summit', '08117');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Teller', '08119');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Washington', '08121');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Weld', '08123');
INSERT INTO fips_lookup (state, county, code) VALUES ('CO', 'Yuma', '08125');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'Fairfield', '09001');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'Hartford', '09003');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'Litchfield', '09005');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'Middlesex', '09007');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'New Haven', '09009');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'New London', '09011');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'Tolland', '09013');
INSERT INTO fips_lookup (state, county, code) VALUES ('CT', 'Windham', '09015');
INSERT INTO fips_lookup (state, county, code) VALUES ('DE', 'Kent', '10001');
INSERT INTO fips_lookup (state, county, code) VALUES ('DE', 'New Castle', '10003');
INSERT INTO fips_lookup (state, county, code) VALUES ('DE', 'Sussex', '10005');
INSERT INTO fips_lookup (state, county, code) VALUES ('DC', 'District of Columbia', '11001');
INSERT INTO fips_lookup (state, county, code) VALUES ('DC', 'Montgomery', '11031');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Alachua', '12001');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Baker', '12003');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Bay', '12005');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Bradford', '12007');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Brevard', '12009');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Broward', '12011');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Calhoun', '12013');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Charlotte', '12015');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Citrus', '12017');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Clay', '12019');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Collier', '12021');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Columbia', '12023');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'De Soto', '12027');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Dixie', '12029');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Duval', '12031');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Escambia', '12033');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Flagler', '12035');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Franklin', '12037');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Gadsden', '12039');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Gilchrist', '12041');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Glades', '12043');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Gulf', '12045');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Hamilton', '12047');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Hardee', '12049');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Hendry', '12051');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Hernando', '12053');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Highlands', '12055');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Hillsborough', '12057');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Holmes', '12059');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Indian River', '12061');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Jackson', '12063');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Jefferson', '12065');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Lafayette', '12067');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Lake', '12069');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Lee', '12071');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Leon', '12073');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Levy', '12075');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Liberty', '12077');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Madison', '12079');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Manatee', '12081');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Marion', '12083');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Martin', '12085');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Miami-Dade', '12086');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Monroe', '12087');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Nassau', '12089');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Okaloosa', '12091');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Okeechobee', '12093');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Orange', '12095');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Osceola', '12097');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Palm Beach', '12099');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Pasco', '12101');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Pinellas', '12103');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Polk', '12105');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Putnam', '12107');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'St Johns', '12109');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'St Lucie', '12111');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Santa Rosa', '12113');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Sarasota', '12115');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Seminole', '12117');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Sumter', '12119');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Suwannee', '12121');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Taylor', '12123');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Union', '12125');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Volusia', '12127');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Wakulla', '12129');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Walton', '12131');
INSERT INTO fips_lookup (state, county, code) VALUES ('FL', 'Washington', '12133');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Appling', '13001');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Atkinson', '13003');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Bacon', '13005');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Baker', '13007');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Baldwin', '13009');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Banks', '13011');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Barrow', '13013');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Bartow', '13015');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Ben Hill', '13017');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Berrien', '13019');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Bibb', '13021');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Bleckley', '13023');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Brantley', '13025');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Brooks', '13027');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Bryan', '13029');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Bulloch', '13031');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Burke', '13033');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Butts', '13035');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Calhoun', '13037');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Camden', '13039');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Candler', '13043');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Carroll', '13045');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Catoosa', '13047');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Charlton', '13049');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Chatham', '13051');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Chattahoochee', '13053');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Chattooga', '13055');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Cherokee', '13057');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Clarke', '13059');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Clay', '13061');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Clayton', '13063');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Clinch', '13065');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Cobb', '13067');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Coffee', '13069');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Colquitt', '13071');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Columbia', '13073');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Cook', '13075');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Coweta', '13077');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Crawford', '13079');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Crisp', '13081');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Dade', '13083');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Dawson', '13085');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Decatur', '13087');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'De Kalb', '13089');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Dodge', '13091');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Dooly', '13093');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Dougherty', '13095');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Douglas', '13097');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Early', '13099');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Echols', '13101');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Effingham', '13103');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Elbert', '13105');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Emanuel', '13107');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Evans', '13109');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Fannin', '13111');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Fayette', '13113');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Floyd', '13115');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Forsyth', '13117');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Franklin', '13119');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Fulton', '13121');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Gilmer', '13123');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Glascock', '13125');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Glynn', '13127');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Gordon', '13129');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Grady', '13131');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Greene', '13133');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Gwinnett', '13135');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Habersham', '13137');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Hall', '13139');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Hancock', '13141');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Haralson', '13143');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Harris', '13145');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Hart', '13147');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Heard', '13149');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Henry', '13151');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Houston', '13153');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Irwin', '13155');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Jackson', '13157');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Jasper', '13159');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Jeff Davis', '13161');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Jefferson', '13163');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Jenkins', '13165');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Johnson', '13167');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Jones', '13169');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Lamar', '13171');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Lanier', '13173');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Laurens', '13175');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Lee', '13177');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Liberty', '13179');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Lincoln', '13181');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Long', '13183');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Lowndes', '13185');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Lumpkin', '13187');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'McDuffie', '13189');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'McIntosh', '13191');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Macon', '13193');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Madison', '13195');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Marion', '13197');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Meriwether', '13199');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Miller', '13201');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Mitchell', '13205');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Monroe', '13207');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Montgomery', '13209');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Morgan', '13211');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Murray', '13213');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Muscogee', '13215');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Newton', '13217');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Oconee', '13219');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Oglethorpe', '13221');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Paulding', '13223');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Peach', '13225');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Pickens', '13227');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Pierce', '13229');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Pike', '13231');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Polk', '13233');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Pulaski', '13235');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Putnam', '13237');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Quitman', '13239');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Rabun', '13241');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Randolph', '13243');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Richmond', '13245');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Rockdale', '13247');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Schley', '13249');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Screven', '13251');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Seminole', '13253');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Spalding', '13255');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Stephens', '13257');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Stewart', '13259');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Sumter', '13261');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Talbot', '13263');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Taliaferro', '13265');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Tattnall', '13267');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Taylor', '13269');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Telfair', '13271');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Terrell', '13273');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Thomas', '13275');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Tift', '13277');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Toombs', '13279');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Towns', '13281');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Treutlen', '13283');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Troup', '13285');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Turner', '13287');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Twiggs', '13289');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Union', '13291');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Upson', '13293');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Walker', '13295');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Walton', '13297');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Ware', '13299');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Warren', '13301');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Washington', '13303');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Wayne', '13305');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Webster', '13307');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Wheeler', '13309');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'White', '13311');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Whitfield', '13313');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Wilcox', '13315');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Wilkes', '13317');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Wilkinson', '13319');
INSERT INTO fips_lookup (state, county, code) VALUES ('GA', 'Worth', '13321');
INSERT INTO fips_lookup (state, county, code) VALUES ('HI', 'Hawaii', '15001');
INSERT INTO fips_lookup (state, county, code) VALUES ('HI', 'Honolulu', '15003');
INSERT INTO fips_lookup (state, county, code) VALUES ('HI', 'Kauai', '15007');
INSERT INTO fips_lookup (state, county, code) VALUES ('HI', 'Maui', '15009');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Ada', '16001');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Adams', '16003');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Bannock', '16005');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Bear Lake', '16007');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Benewah', '16009');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Bingham', '16011');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Blaine', '16013');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Boise', '16015');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Bonner', '16017');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Bonneville', '16019');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Boundary', '16021');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Butte', '16023');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Camas', '16025');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Canyon', '16027');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Caribou', '16029');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Cassia', '16031');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Clark', '16033');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Clearwater', '16035');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Custer', '16037');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Elmore', '16039');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Franklin', '16041');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Fremont', '16043');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Gem', '16045');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Gooding', '16047');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Idaho', '16049');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Jefferson', '16051');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Jerome', '16053');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Kootenai', '16055');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Latah', '16057');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Lemhi', '16059');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Lewis', '16061');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Lincoln', '16063');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Madison', '16065');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Minidoka', '16067');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Nez Perce', '16069');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Oneida', '16071');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Owyhee', '16073');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Payette', '16075');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Power', '16077');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Shoshone', '16079');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Teton', '16081');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Twin Falls', '16083');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Valley', '16085');
INSERT INTO fips_lookup (state, county, code) VALUES ('ID', 'Washington', '16087');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Adams', '17001');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Alexander', '17003');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Bond', '17005');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Boone', '17007');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Brown', '17009');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Bureau', '17011');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Calhoun', '17013');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Carroll', '17015');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Cass', '17017');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Champaign', '17019');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Christian', '17021');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Clark', '17023');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Clay', '17025');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Clinton', '17027');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Coles', '17029');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Cook', '17031');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Crawford', '17033');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Cumberland', '17035');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'De Kalb', '17037');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Dewitt', '17039');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Douglas', '17041');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Du Page', '17043');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Edgar', '17045');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Edwards', '17047');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Effingham', '17049');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Fayette', '17051');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Ford', '17053');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Franklin', '17055');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Fulton', '17057');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Gallatin', '17059');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Greene', '17061');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Grundy', '17063');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Hamilton', '17065');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Hancock', '17067');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Hardin', '17069');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Henderson', '17071');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Henry', '17073');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Iroquois', '17075');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Jackson', '17077');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Jasper', '17079');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Jefferson', '17081');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Jersey', '17083');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Jo Daviess', '17085');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Johnson', '17087');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Kane', '17089');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Kankakee', '17091');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Kendall', '17093');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Knox', '17095');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Lake', '17097');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'La Salle', '17099');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Lawrence', '17101');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Lee', '17103');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Livingston', '17105');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Logan', '17107');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'McDonough', '17109');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'McHenry', '17111');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Mclean', '17113');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Macon', '17115');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Macoupin', '17117');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Madison', '17119');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Marion', '17121');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Marshall', '17123');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Mason', '17125');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Massac', '17127');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Menard', '17129');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Mercer', '17131');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Monroe', '17133');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Montgomery', '17135');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Morgan', '17137');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Moultrie', '17139');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Ogle', '17141');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Peoria', '17143');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Perry', '17145');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Piatt', '17147');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Pike', '17149');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Pope', '17151');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Pulaski', '17153');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Putnam', '17155');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Randolph', '17157');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Richland', '17159');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Rock Island', '17161');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'St Clair', '17163');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Saline', '17165');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Sangamon', '17167');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Schuyler', '17169');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Scott', '17171');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Shelby', '17173');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Stark', '17175');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Stephenson', '17177');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Tazewell', '17179');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Union', '17181');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Vermilion', '17183');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Wabash', '17185');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Warren', '17187');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Washington', '17189');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Wayne', '17191');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'White', '17193');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Whiteside', '17195');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Will', '17197');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Williamson', '17199');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Winnebago', '17201');
INSERT INTO fips_lookup (state, county, code) VALUES ('IL', 'Woodford', '17203');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Adams', '18001');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Allen', '18003');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Bartholomew', '18005');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Benton', '18007');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Blackford', '18009');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Boone', '18011');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Brown', '18013');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Carroll', '18015');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Cass', '18017');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Clark', '18019');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Clay', '18021');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Clinton', '18023');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Crawford', '18025');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Daviess', '18027');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Dearborn', '18029');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Decatur', '18031');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'De Kalb', '18033');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Delaware', '18035');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Dubois', '18037');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Elkhart', '18039');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Fayette', '18041');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Floyd', '18043');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Fountain', '18045');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Franklin', '18047');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Fulton', '18049');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Gibson', '18051');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Grant', '18053');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Greene', '18055');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Hamilton', '18057');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Hancock', '18059');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Harrison', '18061');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Hendricks', '18063');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Henry', '18065');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Howard', '18067');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Huntington', '18069');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Jackson', '18071');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Jasper', '18073');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Jay', '18075');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Jefferson', '18077');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Jennings', '18079');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Johnson', '18081');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Knox', '18083');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Kosciusko', '18085');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Lagrange', '18087');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Lake', '18089');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'La Porte', '18091');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Lawrence', '18093');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Madison', '18095');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Marion', '18097');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Marshall', '18099');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Martin', '18101');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Miami', '18103');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Monroe', '18105');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Montgomery', '18107');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Morgan', '18109');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Newton', '18111');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Noble', '18113');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Ohio', '18115');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Orange', '18117');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Owen', '18119');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Parke', '18121');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Perry', '18123');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Pike', '18125');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Porter', '18127');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Posey', '18129');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Pulaski', '18131');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Putnam', '18133');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Randolph', '18135');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Ripley', '18137');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Rush', '18139');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'St Joseph', '18141');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Scott', '18143');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Shelby', '18145');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Spencer', '18147');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Starke', '18149');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Steuben', '18151');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Sullivan', '18153');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Switzerland', '18155');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Tippecanoe', '18157');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Tipton', '18159');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Union', '18161');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Vanderburgh', '18163');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Vermillion', '18165');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Vigo', '18167');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Wabash', '18169');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Warren', '18171');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Warrick', '18173');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Washington', '18175');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Wayne', '18177');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Wells', '18179');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'White', '18181');
INSERT INTO fips_lookup (state, county, code) VALUES ('IN', 'Whitley', '18183');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Adair', '19001');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Adams', '19003');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Allamakee', '19005');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Appanoose', '19007');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Audubon', '19009');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Benton', '19011');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Black Hawk', '19013');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Boone', '19015');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Bremer', '19017');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Buchanan', '19019');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Buena Vista', '19021');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Butler', '19023');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Calhoun', '19025');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Carroll', '19027');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Cass', '19029');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Cedar', '19031');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Cerro Gordo', '19033');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Cherokee', '19035');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Chickasaw', '19037');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Clarke', '19039');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Clay', '19041');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Clayton', '19043');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Clinton', '19045');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Crawford', '19047');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Dallas', '19049');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Davis', '19051');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Decatur', '19053');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Delaware', '19055');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Des Moines', '19057');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Dickinson', '19059');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Dubuque', '19061');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Emmet', '19063');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Fayette', '19065');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Floyd', '19067');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Franklin', '19069');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Fremont', '19071');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Greene', '19073');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Grundy', '19075');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Guthrie', '19077');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Hamilton', '19079');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Hancock', '19081');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Hardin', '19083');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Harrison', '19085');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Henry', '19087');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Howard', '19089');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Humboldt', '19091');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Ida', '19093');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Iowa', '19095');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Jackson', '19097');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Jasper', '19099');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Jefferson', '19101');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Johnson', '19103');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Jones', '19105');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Keokuk', '19107');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Kossuth', '19109');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Lee', '19111');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Linn', '19113');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Louisa', '19115');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Lucas', '19117');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Lyon', '19119');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Madison', '19121');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Mahaska', '19123');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Marion', '19125');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Marshall', '19127');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Mills', '19129');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Mitchell', '19131');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Monona', '19133');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Monroe', '19135');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Montgomery', '19137');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Muscatine', '19139');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Obrien', '19141');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Osceola', '19143');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Page', '19145');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Palo Alto', '19147');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Plymouth', '19149');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Pocahontas', '19151');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Polk', '19153');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Pottawattamie', '19155');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Poweshiek', '19157');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Ringgold', '19159');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Sac', '19161');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Scott', '19163');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Shelby', '19165');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Sioux', '19167');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Story', '19169');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Tama', '19171');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Taylor', '19173');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Union', '19175');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Van Buren', '19177');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Wapello', '19179');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Warren', '19181');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Washington', '19183');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Wayne', '19185');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Webster', '19187');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Winnebago', '19189');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Winneshiek', '19191');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Woodbury', '19193');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Worth', '19195');
INSERT INTO fips_lookup (state, county, code) VALUES ('IA', 'Wright', '19197');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Allen', '20001');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Anderson', '20003');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Atchison', '20005');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Barber', '20007');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Barton', '20009');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Bourbon', '20011');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Brown', '20013');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Butler', '20015');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Chase', '20017');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Chautauqua', '20019');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Cherokee', '20021');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Cheyenne', '20023');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Clark', '20025');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Clay', '20027');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Cloud', '20029');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Coffey', '20031');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Comanche', '20033');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Cowley', '20035');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Crawford', '20037');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Decatur', '20039');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Dickinson', '20041');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Doniphan', '20043');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Douglas', '20045');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Edwards', '20047');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Elk', '20049');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Ellis', '20051');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Ellsworth', '20053');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Finney', '20055');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Ford', '20057');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Franklin', '20059');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Geary', '20061');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Gove', '20063');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Graham', '20065');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Grant', '20067');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Gray', '20069');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Greeley', '20071');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Greenwood', '20073');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Hamilton', '20075');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Harper', '20077');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Harvey', '20079');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Haskell', '20081');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Hodgeman', '20083');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Jackson', '20085');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Jefferson', '20087');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Jewell', '20089');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Johnson', '20091');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Kearny', '20093');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Kingman', '20095');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Kiowa', '20097');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Labette', '20099');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Lane', '20101');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Leavenworth', '20103');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Lincoln', '20105');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Linn', '20107');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Logan', '20109');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Lyon', '20111');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'McPherson', '20113');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Marion', '20115');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Marshall', '20117');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Meade', '20119');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Miami', '20121');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Mitchell', '20123');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Montgomery', '20125');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Morris', '20127');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Morton', '20129');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Nemaha', '20131');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Neosho', '20133');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Ness', '20135');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Norton', '20137');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Osage', '20139');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Osborne', '20141');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Ottawa', '20143');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Pawnee', '20145');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Phillips', '20147');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Pottawatomie', '20149');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Pratt', '20151');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Rawlins', '20153');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Reno', '20155');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Republic', '20157');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Rice', '20159');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Riley', '20161');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Rooks', '20163');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Rush', '20165');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Russell', '20167');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Saline', '20169');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Scott', '20171');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Sedgwick', '20173');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Seward', '20175');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Shawnee', '20177');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Sheridan', '20179');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Sherman', '20181');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Smith', '20183');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Stafford', '20185');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Stanton', '20187');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Stevens', '20189');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Sumner', '20191');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Thomas', '20193');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Trego', '20195');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Wabaunsee', '20197');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Wallace', '20199');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Washington', '20201');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Wichita', '20203');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Wilson', '20205');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Woodson', '20207');
INSERT INTO fips_lookup (state, county, code) VALUES ('KS', 'Wyandotte', '20209');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Adair', '21001');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Allen', '21003');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Anderson', '21005');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Ballard', '21007');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Barren', '21009');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Bath', '21011');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Bell', '21013');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Boone', '21015');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Bourbon', '21017');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Boyd', '21019');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Boyle', '21021');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Bracken', '21023');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Breathitt', '21025');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Breckinridge', '21027');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Bullitt', '21029');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Butler', '21031');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Caldwell', '21033');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Calloway', '21035');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Campbell', '21037');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Carlisle', '21039');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Carroll', '21041');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Carter', '21043');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Casey', '21045');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Christian', '21047');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Clark', '21049');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Clay', '21051');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Clinton', '21053');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Crittenden', '21055');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Cumberland', '21057');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Daviess', '21059');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Edmonson', '21061');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Elliott', '21063');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Estill', '21065');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Fayette', '21067');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Fleming', '21069');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Floyd', '21071');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Franklin', '21073');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Fulton', '21075');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Gallatin', '21077');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Garrard', '21079');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Grant', '21081');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Graves', '21083');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Grayson', '21085');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Green', '21087');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Greenup', '21089');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Hancock', '21091');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Hardin', '21093');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Harlan', '21095');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Harrison', '21097');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Hart', '21099');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Henderson', '21101');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Henry', '21103');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Hickman', '21105');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Hopkins', '21107');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Jackson', '21109');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Jefferson', '21111');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Jessamine', '21113');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Johnson', '21115');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Kenton', '21117');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Knott', '21119');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Knox', '21121');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Larue', '21123');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Laurel', '21125');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Lawrence', '21127');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Lee', '21129');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Leslie', '21131');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Letcher', '21133');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Lewis', '21135');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Lincoln', '21137');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Livingston', '21139');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Logan', '21141');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Lyon', '21143');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'McCracken', '21145');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'McCreary', '21147');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Mclean', '21149');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Madison', '21151');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Magoffin', '21153');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Marion', '21155');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Marshall', '21157');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Martin', '21159');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Mason', '21161');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Meade', '21163');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Menifee', '21165');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Mercer', '21167');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Metcalfe', '21169');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Monroe', '21171');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Montgomery', '21173');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Morgan', '21175');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Muhlenberg', '21177');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Nelson', '21179');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Nicholas', '21181');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Ohio', '21183');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Oldham', '21185');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Owen', '21187');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Owsley', '21189');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Pendleton', '21191');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Perry', '21193');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Pike', '21195');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Powell', '21197');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Pulaski', '21199');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Robertson', '21201');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Rockcastle', '21203');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Rowan', '21205');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Russell', '21207');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Scott', '21209');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Shelby', '21211');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Simpson', '21213');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Spencer', '21215');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Taylor', '21217');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Todd', '21219');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Trigg', '21221');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Trimble', '21223');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Union', '21225');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Warren', '21227');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Washington', '21229');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Wayne', '21231');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Webster', '21233');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Whitley', '21235');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Wolfe', '21237');
INSERT INTO fips_lookup (state, county, code) VALUES ('KY', 'Woodford', '21239');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Acadia', '22001');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Allen', '22003');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Ascension', '22005');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Assumption', '22007');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Avoyelles', '22009');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Beauregard', '22011');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Bienville', '22013');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Bossier', '22015');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Caddo', '22017');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Calcasieu', '22019');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Caldwell', '22021');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Cameron', '22023');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Catahoula', '22025');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Claiborne', '22027');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Concordia', '22029');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'De Soto', '22031');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'East Baton Rouge', '22033');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'East Carroll', '22035');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'East Feliciana', '22037');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Evangeline', '22039');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Franklin', '22041');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Grant', '22043');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Iberia', '22045');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Iberville', '22047');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Jackson', '22049');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Jefferson', '22051');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Jefferson Davis', '22053');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Lafayette', '22055');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Lafourche', '22057');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'La Salle', '22059');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Lincoln', '22061');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Livingston', '22063');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Madison', '22065');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Morehouse', '22067');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Natchitoches', '22069');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Orleans', '22071');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Ouachita', '22073');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Plaquemines', '22075');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Pointe Coupee', '22077');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Rapides', '22079');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Red River', '22081');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Richland', '22083');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Sabine', '22085');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Bernard', '22087');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Charles', '22089');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Helena', '22091');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St James', '22093');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St John The Baptist', '22095');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Landry', '22097');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Martin', '22099');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Mary', '22101');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'St Tammany', '22103');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Tangipahoa', '22105');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Tensas', '22107');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Terrebonne', '22109');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Union', '22111');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Vermilion', '22113');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Vernon', '22115');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Washington', '22117');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Webster', '22119');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'West Baton Rouge', '22121');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'West Carroll', '22123');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'West Feliciana', '22125');
INSERT INTO fips_lookup (state, county, code) VALUES ('LA', 'Winn', '22127');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Androscoggin', '23001');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Aroostook', '23003');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Cumberland', '23005');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Franklin', '23007');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Hancock', '23009');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Kennebec', '23011');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Knox', '23013');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Lincoln', '23015');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Oxford', '23017');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Penobscot', '23019');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Piscataquis', '23021');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Sagadahoc', '23023');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Somerset', '23025');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Waldo', '23027');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'Washington', '23029');
INSERT INTO fips_lookup (state, county, code) VALUES ('ME', 'York', '23031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Allegany', '24001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Anne Arundel', '24003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Baltimore', '24005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Calvert', '24009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Caroline', '24011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Carroll', '24013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Cecil', '24015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Charles', '24017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Dorchester', '24019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Frederick', '24021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Garrett', '24023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Harford', '24025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Howard', '24027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Kent', '24029');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Montgomery', '24031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Prince Georges', '24033');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Queen Annes', '24035');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'St Marys', '24037');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Somerset', '24039');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Talbot', '24041');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Washington', '24043');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Wicomico', '24045');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Worcester', '24047');
INSERT INTO fips_lookup (state, county, code) VALUES ('MD', 'Baltimore City', '24510');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Barnstable', '25001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Berkshire', '25003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Bristol', '25005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Dukes', '25007');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Essex', '25009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Franklin', '25011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Hampden', '25013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Hampshire', '25015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Middlesex', '25017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Nantucket', '25019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Norfolk', '25021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Plymouth', '25023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Suffolk', '25025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MA', 'Worcester', '25027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Alcona', '26001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Alger', '26003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Allegan', '26005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Alpena', '26007');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Antrim', '26009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Arenac', '26011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Baraga', '26013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Barry', '26015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Bay', '26017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Benzie', '26019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Berrien', '26021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Branch', '26023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Calhoun', '26025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Cass', '26027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Charlevoix', '26029');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Cheboygan', '26031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Chippewa', '26033');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Clare', '26035');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Clinton', '26037');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Crawford', '26039');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Delta', '26041');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Dickinson', '26043');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Eaton', '26045');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Emmet', '26047');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Genesee', '26049');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Gladwin', '26051');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Gogebic', '26053');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Grand Traverse', '26055');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Gratiot', '26057');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Hillsdale', '26059');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Houghton', '26061');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Huron', '26063');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Ingham', '26065');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Ionia', '26067');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Iosco', '26069');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Iron', '26071');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Isabella', '26073');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Jackson', '26075');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Kalamazoo', '26077');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Kalkaska', '26079');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Kent', '26081');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Keweenaw', '26083');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Lake', '26085');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Lapeer', '26087');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Leelanau', '26089');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Lenawee', '26091');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Livingston', '26093');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Luce', '26095');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Mackinac', '26097');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Macomb', '26099');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Manistee', '26101');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Marquette', '26103');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Mason', '26105');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Mecosta', '26107');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Menominee', '26109');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Midland', '26111');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Missaukee', '26113');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Monroe', '26115');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Montcalm', '26117');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Montmorency', '26119');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Muskegon', '26121');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Newaygo', '26123');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Oakland', '26125');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Oceana', '26127');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Ogemaw', '26129');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Ontonagon', '26131');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Osceola', '26133');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Oscoda', '26135');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Otsego', '26137');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Ottawa', '26139');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Presque Isle', '26141');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Roscommon', '26143');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Saginaw', '26145');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'St Clair', '26147');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'St Joseph', '26149');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Sanilac', '26151');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Schoolcraft', '26153');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Shiawassee', '26155');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Tuscola', '26157');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Van Buren', '26159');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Washtenaw', '26161');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Wayne', '26163');
INSERT INTO fips_lookup (state, county, code) VALUES ('MI', 'Wexford', '26165');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Aitkin', '27001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Anoka', '27003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Becker', '27005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Beltrami', '27007');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Benton', '27009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Big Stone', '27011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Blue Earth', '27013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Brown', '27015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Carlton', '27017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Carver', '27019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Cass', '27021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Chippewa', '27023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Chisago', '27025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Clay', '27027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Clearwater', '27029');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Cook', '27031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Cottonwood', '27033');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Crow Wing', '27035');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Dakota', '27037');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Dodge', '27039');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Douglas', '27041');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Faribault', '27043');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Fillmore', '27045');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Freeborn', '27047');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Goodhue', '27049');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Grant', '27051');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Hennepin', '27053');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Houston', '27055');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Hubbard', '27057');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Isanti', '27059');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Itasca', '27061');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Jackson', '27063');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Kanabec', '27065');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Kandiyohi', '27067');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Kittson', '27069');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Koochiching', '27071');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Lac Qui Parle', '27073');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Lake', '27075');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Lake of The Woods', '27077');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Le Sueur', '27079');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Lincoln', '27081');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Lyon', '27083');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'McLeod', '27085');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Mahnomen', '27087');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Marshall', '27089');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Martin', '27091');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Meeker', '27093');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Mille Lacs', '27095');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Morrison', '27097');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Mower', '27099');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Murray', '27101');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Nicollet', '27103');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Nobles', '27105');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Norman', '27107');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Olmsted', '27109');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Otter Tail', '27111');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Pennington', '27113');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Pine', '27115');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Pipestone', '27117');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Polk', '27119');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Pope', '27121');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Ramsey', '27123');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Red Lake', '27125');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Redwood', '27127');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Renville', '27129');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Rice', '27131');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Rock', '27133');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Roseau', '27135');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'St Louis', '27137');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Scott', '27139');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Sherburne', '27141');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Sibley', '27143');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Stearns', '27145');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Steele', '27147');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Stevens', '27149');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Swift', '27151');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Todd', '27153');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Traverse', '27155');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Wabasha', '27157');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Wadena', '27159');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Waseca', '27161');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Washington', '27163');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Watonwan', '27165');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Wilkin', '27167');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Winona', '27169');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Wright', '27171');
INSERT INTO fips_lookup (state, county, code) VALUES ('MN', 'Yellow Medicine', '27173');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Adams', '28001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Alcorn', '28003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Amite', '28005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Attala', '28007');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Benton', '28009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Bolivar', '28011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Calhoun', '28013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Carroll', '28015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Chickasaw', '28017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Choctaw', '28019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Claiborne', '28021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Clarke', '28023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Clay', '28025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Coahoma', '28027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Copiah', '28029');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Covington', '28031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'De Soto', '28033');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Forrest', '28035');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Franklin', '28037');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'George', '28039');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Greene', '28041');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Grenada', '28043');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Hancock', '28045');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Harrison', '28047');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Hinds', '28049');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Holmes', '28051');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Humphreys', '28053');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Issaquena', '28055');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Itawamba', '28057');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Jackson', '28059');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Jasper', '28061');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Jefferson', '28063');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Jefferson Davis', '28065');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Jones', '28067');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Kemper', '28069');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lafayette', '28071');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lamar', '28073');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lauderdale', '28075');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lawrence', '28077');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Leake', '28079');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lee', '28081');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Leflore', '28083');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lincoln', '28085');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Lowndes', '28087');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Madison', '28089');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Marion', '28091');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Marshall', '28093');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Monroe', '28095');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Montgomery', '28097');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Neshoba', '28099');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Newton', '28101');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Noxubee', '28103');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Oktibbeha', '28105');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Panola', '28107');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Pearl River', '28109');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Perry', '28111');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Pike', '28113');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Pontotoc', '28115');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Prentiss', '28117');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Quitman', '28119');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Rankin', '28121');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Scott', '28123');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Sharkey', '28125');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Simpson', '28127');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Smith', '28129');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Stone', '28131');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Sunflower', '28133');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Tallahatchie', '28135');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Tate', '28137');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Tippah', '28139');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Tishomingo', '28141');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Tunica', '28143');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Union', '28145');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Walthall', '28147');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Warren', '28149');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Washington', '28151');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Wayne', '28153');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Webster', '28155');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Wilkinson', '28157');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Winston', '28159');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Yalobusha', '28161');
INSERT INTO fips_lookup (state, county, code) VALUES ('MS', 'Yazoo', '28163');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Adair', '29001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Andrew', '29003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Atchison', '29005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Audrain', '29007');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Barry', '29009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Barton', '29011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Bates', '29013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Benton', '29015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Bollinger', '29017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Boone', '29019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Buchanan', '29021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Butler', '29023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Caldwell', '29025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Callaway', '29027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Camden', '29029');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Cape Girardeau', '29031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Carroll', '29033');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Carter', '29035');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Cass', '29037');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Cedar', '29039');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Chariton', '29041');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Christian', '29043');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Clark', '29045');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Clay', '29047');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Clinton', '29049');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Cole', '29051');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Cooper', '29053');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Crawford', '29055');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Dade', '29057');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Dallas', '29059');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Daviess', '29061');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Dekalb', '29063');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Dent', '29065');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Douglas', '29067');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Dunklin', '29069');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Franklin', '29071');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Gasconade', '29073');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Gentry', '29075');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Greene', '29077');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Grundy', '29079');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Harrison', '29081');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Henry', '29083');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Hickory', '29085');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Holt', '29087');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Howard', '29089');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Howell', '29091');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Iron', '29093');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Jackson', '29095');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Jasper', '29097');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Jefferson', '29099');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Johnson', '29101');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Knox', '29103');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Laclede', '29105');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Lafayette', '29107');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Lawrence', '29109');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Lewis', '29111');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Lincoln', '29113');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Linn', '29115');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Livingston', '29117');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Mcdonald', '29119');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Macon', '29121');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Madison', '29123');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Maries', '29125');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Marion', '29127');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Mercer', '29129');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Miller', '29131');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Mississippi', '29133');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Moniteau', '29135');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Monroe', '29137');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Montgomery', '29139');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Morgan', '29141');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'New Madrid', '29143');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Newton', '29145');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Nodaway', '29147');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Oregon', '29149');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Osage', '29151');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Ozark', '29153');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Pemiscot', '29155');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Perry', '29157');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Pettis', '29159');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Phelps', '29161');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Pike', '29163');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Platte', '29165');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Polk', '29167');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Pulaski', '29169');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Putnam', '29171');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Ralls', '29173');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Randolph', '29175');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Ray', '29177');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Reynolds', '29179');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Ripley', '29181');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'St Charles', '29183');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'St Clair', '29185');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Ste Genevieve', '29186');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'St Francois', '29187');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'St Louis', '29189');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Saline', '29195');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Schuyler', '29197');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Scotland', '29199');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Scott', '29201');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Shannon', '29203');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Shelby', '29205');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Stoddard', '29207');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Stone', '29209');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Sullivan', '29211');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Taney', '29213');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Texas', '29215');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Vernon', '29217');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Warren', '29219');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Washington', '29221');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Wayne', '29223');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Webster', '29225');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Worth', '29227');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'Wright', '29229');
INSERT INTO fips_lookup (state, county, code) VALUES ('MO', 'St Louis City', '29510');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Beaverhead', '30001');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Big Horn', '30003');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Blaine', '30005');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Broadwater', '30007');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Carbon', '30009');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Carter', '30011');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Cascade', '30013');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Chouteau', '30015');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Custer', '30017');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Daniels', '30019');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Dawson', '30021');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Deer Lodge', '30023');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Fallon', '30025');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Fergus', '30027');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Flathead', '30029');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Gallatin', '30031');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Garfield', '30033');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Glacier', '30035');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Golden Valley', '30037');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Granite', '30039');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Hill', '30041');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Jefferson', '30043');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Judith Basin', '30045');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Lake', '30047');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Lewis and Clark', '30049');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Liberty', '30051');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Lincoln', '30053');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'McCone', '30055');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Madison', '30057');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Meagher', '30059');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Mineral', '30061');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Missoula', '30063');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Musselshell', '30065');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Park', '30067');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Petroleum', '30069');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Phillips', '30071');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Pondera', '30073');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Powder River', '30075');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Powell', '30077');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Prairie', '30079');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Ravalli', '30081');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Richland', '30083');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Roosevelt', '30085');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Rosebud', '30087');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Sanders', '30089');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Sheridan', '30091');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Silver Bow', '30093');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Stillwater', '30095');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Sweet Grass', '30097');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Teton', '30099');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Toole', '30101');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Treasure', '30103');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Valley', '30105');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Wheatland', '30107');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Wibaux', '30109');
INSERT INTO fips_lookup (state, county, code) VALUES ('MT', 'Yellowstone', '30111');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Adams', '31001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Antelope', '31003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Arthur', '31005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Banner', '31007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Blaine', '31009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Boone', '31011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Box Butte', '31013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Boyd', '31015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Brown', '31017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Buffalo', '31019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Burt', '31021');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Butler', '31023');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Cass', '31025');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Cedar', '31027');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Chase', '31029');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Cherry', '31031');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Cheyenne', '31033');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Clay', '31035');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Colfax', '31037');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Cuming', '31039');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Custer', '31041');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Dakota', '31043');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Dawes', '31045');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Dawson', '31047');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Deuel', '31049');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Dixon', '31051');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Dodge', '31053');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Douglas', '31055');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Dundy', '31057');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Fillmore', '31059');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Franklin', '31061');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Frontier', '31063');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Furnas', '31065');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Gage', '31067');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Garden', '31069');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Garfield', '31071');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Gosper', '31073');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Grant', '31075');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Greeley', '31077');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Hall', '31079');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Hamilton', '31081');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Harlan', '31083');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Hayes', '31085');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Hitchcock', '31087');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Holt', '31089');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Hooker', '31091');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Howard', '31093');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Jefferson', '31095');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Johnson', '31097');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Kearney', '31099');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Keith', '31101');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Keya Paha', '31103');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Kimball', '31105');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Knox', '31107');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Lancaster', '31109');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Lincoln', '31111');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Logan', '31113');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Loup', '31115');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'McPherson', '31117');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Madison', '31119');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Merrick', '31121');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Morrill', '31123');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Nance', '31125');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Nemaha', '31127');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Nuckolls', '31129');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Otoe', '31131');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Pawnee', '31133');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Perkins', '31135');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Phelps', '31137');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Pierce', '31139');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Platte', '31141');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Polk', '31143');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Red Willow', '31145');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Richardson', '31147');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Rock', '31149');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Saline', '31151');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Sarpy', '31153');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Saunders', '31155');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Scotts Bluff', '31157');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Seward', '31159');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Sheridan', '31161');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Sherman', '31163');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Sioux', '31165');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Stanton', '31167');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Thayer', '31169');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Thomas', '31171');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Thurston', '31173');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Valley', '31175');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Washington', '31177');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Wayne', '31179');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Webster', '31181');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'Wheeler', '31183');
INSERT INTO fips_lookup (state, county, code) VALUES ('NE', 'York', '31185');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Churchill', '32001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Clark', '32003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Douglas', '32005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Elko', '32007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Esmeralda', '32009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Eureka', '32011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Humboldt', '32013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Lander', '32015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Lincoln', '32017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Lyon', '32019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Mineral', '32021');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Nye', '32023');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Pershing', '32027');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Storey', '32029');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Washoe', '32031');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'White Pine', '32033');
INSERT INTO fips_lookup (state, county, code) VALUES ('NV', 'Carson City', '32510');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Belknap', '33001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Carroll', '33003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Cheshire', '33005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Coos', '33007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Grafton', '33009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Hillsborough', '33011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Merrimack', '33013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Rockingham', '33015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Strafford', '33017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NH', 'Sullivan', '33019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Atlantic', '34001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Bergen', '34003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Burlington', '34005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Camden', '34007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Cape May', '34009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Cumberland', '34011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Essex', '34013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Gloucester', '34015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Hudson', '34017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Hunterdon', '34019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Mercer', '34021');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Middlesex', '34023');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Monmouth', '34025');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Morris', '34027');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Ocean', '34029');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Passaic', '34031');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Salem', '34033');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Somerset', '34035');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Sussex', '34037');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Union', '34039');
INSERT INTO fips_lookup (state, county, code) VALUES ('NJ', 'Warren', '34041');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Bernalillo', '35001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Catron', '35003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Chaves', '35005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Cibola', '35006');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Colfax', '35007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Curry', '35009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'De Baca', '35011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Dona Ana', '35013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Eddy', '35015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Grant', '35017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Guadalupe', '35019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Harding', '35021');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Hidalgo', '35023');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Lea', '35025');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Lincoln', '35027');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Los Alamos', '35028');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Luna', '35029');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Mckinley', '35031');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Mora', '35033');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Otero', '35035');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Quay', '35037');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Rio Arriba', '35039');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Roosevelt', '35041');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Sandoval', '35043');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'San Juan', '35045');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'San Miguel', '35047');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Santa Fe', '35049');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Sierra', '35051');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Socorro', '35053');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Taos', '35055');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Torrance', '35057');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Union', '35059');
INSERT INTO fips_lookup (state, county, code) VALUES ('NM', 'Valencia', '35061');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Albany', '36001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Allegany', '36003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Bronx', '36005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Broome', '36007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Cattaraugus', '36009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Cayuga', '36011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Chautauqua', '36013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Chemung', '36015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Chenango', '36017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Clinton', '36019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Columbia', '36021');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Cortland', '36023');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Delaware', '36025');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Dutchess', '36027');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Erie', '36029');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Essex', '36031');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Franklin', '36033');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Fulton', '36035');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Genesee', '36037');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Greene', '36039');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Hamilton', '36041');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Herkimer', '36043');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Jefferson', '36045');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Kings', '36047');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Lewis', '36049');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Livingston', '36051');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Madison', '36053');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Monroe', '36055');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Montgomery', '36057');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Nassau', '36059');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'New York', '36061');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Niagara', '36063');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Oneida', '36065');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Onondaga', '36067');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Ontario', '36069');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Orange', '36071');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Orleans', '36073');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Oswego', '36075');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Otsego', '36077');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Putnam', '36079');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Queens', '36081');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Rensselaer', '36083');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Richmond', '36085');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Rockland', '36087');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'St Lawrence', '36089');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Saratoga', '36091');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Schenectady', '36093');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Schoharie', '36095');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Schuyler', '36097');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Seneca', '36099');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Steuben', '36101');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Suffolk', '36103');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Sullivan', '36105');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Tioga', '36107');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Tompkins', '36109');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Ulster', '36111');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Warren', '36113');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Washington', '36115');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Wayne', '36117');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Westchester', '36119');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Wyoming', '36121');
INSERT INTO fips_lookup (state, county, code) VALUES ('NY', 'Yates', '36123');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Alamance', '37001');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Alexander', '37003');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Alleghany', '37005');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Anson', '37007');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Ashe', '37009');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Avery', '37011');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Beaufort', '37013');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Bertie', '37015');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Bladen', '37017');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Brunswick', '37019');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Buncombe', '37021');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Burke', '37023');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Cabarrus', '37025');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Caldwell', '37027');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Camden', '37029');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Carteret', '37031');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Caswell', '37033');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Catawba', '37035');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Chatham', '37037');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Cherokee', '37039');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Chowan', '37041');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Clay', '37043');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Cleveland', '37045');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Columbus', '37047');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Craven', '37049');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Cumberland', '37051');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Currituck', '37053');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Dare', '37055');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Davidson', '37057');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Davie', '37059');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Duplin', '37061');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Durham', '37063');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Edgecombe', '37065');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Forsyth', '37067');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Franklin', '37069');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Gaston', '37071');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Gates', '37073');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Graham', '37075');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Granville', '37077');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Greene', '37079');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Guilford', '37081');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Halifax', '37083');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Harnett', '37085');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Haywood', '37087');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Henderson', '37089');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Hertford', '37091');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Hoke', '37093');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Hyde', '37095');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Iredell', '37097');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Jackson', '37099');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Johnston', '37101');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Jones', '37103');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Lee', '37105');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Lenoir', '37107');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Lincoln', '37109');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'McDowell', '37111');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Macon', '37113');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Madison', '37115');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Martin', '37117');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Mecklenburg', '37119');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Mitchell', '37121');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Montgomery', '37123');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Moore', '37125');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Nash', '37127');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'New Hanover', '37129');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Northampton', '37131');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Onslow', '37133');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Orange', '37135');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Pamlico', '37137');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Pasquotank', '37139');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Pender', '37141');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Perquimans', '37143');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Person', '37145');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Pitt', '37147');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Polk', '37149');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Randolph', '37151');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Richmond', '37153');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Robeson', '37155');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Rockingham', '37157');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Rowan', '37159');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Rutherford', '37161');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Sampson', '37163');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Scotland', '37165');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Stanly', '37167');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Stokes', '37169');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Surry', '37171');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Swain', '37173');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Transylvania', '37175');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Tyrrell', '37177');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Union', '37179');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Vance', '37181');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Wake', '37183');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Warren', '37185');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Washington', '37187');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Watauga', '37189');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Wayne', '37191');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Wilkes', '37193');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Wilson', '37195');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Yadkin', '37197');
INSERT INTO fips_lookup (state, county, code) VALUES ('NC', 'Yancey', '37199');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Adams', '38001');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Barnes', '38003');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Benson', '38005');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Billings', '38007');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Bottineau', '38009');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Bowman', '38011');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Burke', '38013');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Burleigh', '38015');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Cass', '38017');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Cavalier', '38019');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Dickey', '38021');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Divide', '38023');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Dunn', '38025');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Eddy', '38027');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Emmons', '38029');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Foster', '38031');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Golden Valley', '38033');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Grand Forks', '38035');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Grant', '38037');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Griggs', '38039');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Hettinger', '38041');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Kidder', '38043');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Lamoure', '38045');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Logan', '38047');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'McHenry', '38049');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'McIntosh', '38051');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Mckenzie', '38053');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Mclean', '38055');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Mercer', '38057');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Morton', '38059');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Mountrail', '38061');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Nelson', '38063');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Oliver', '38065');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Pembina', '38067');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Pierce', '38069');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Ramsey', '38071');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Ransom', '38073');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Renville', '38075');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Richland', '38077');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Rolette', '38079');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Sargent', '38081');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Sheridan', '38083');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Sioux', '38085');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Slope', '38087');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Stark', '38089');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Steele', '38091');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Stutsman', '38093');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Towner', '38095');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Traill', '38097');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Walsh', '38099');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Ward', '38101');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Wells', '38103');
INSERT INTO fips_lookup (state, county, code) VALUES ('ND', 'Williams', '38105');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Adams', '39001');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Allen', '39003');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Ashland', '39005');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Ashtabula', '39007');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Athens', '39009');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Auglaize', '39011');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Belmont', '39013');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Brown', '39015');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Butler', '39017');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Carroll', '39019');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Champaign', '39021');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Clark', '39023');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Clermont', '39025');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Clinton', '39027');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Columbiana', '39029');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Coshocton', '39031');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Crawford', '39033');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Cuyahoga', '39035');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Darke', '39037');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Defiance', '39039');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Delaware', '39041');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Erie', '39043');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Fairfield', '39045');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Fayette', '39047');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Franklin', '39049');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Fulton', '39051');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Gallia', '39053');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Geauga', '39055');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Greene', '39057');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Guernsey', '39059');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Hamilton', '39061');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Hancock', '39063');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Hardin', '39065');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Harrison', '39067');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Henry', '39069');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Highland', '39071');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Hocking', '39073');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Holmes', '39075');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Huron', '39077');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Jackson', '39079');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Jefferson', '39081');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Knox', '39083');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Lake', '39085');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Lawrence', '39087');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Licking', '39089');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Logan', '39091');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Lorain', '39093');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Lucas', '39095');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Madison', '39097');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Mahoning', '39099');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Marion', '39101');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Medina', '39103');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Meigs', '39105');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Mercer', '39107');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Miami', '39109');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Monroe', '39111');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Montgomery', '39113');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Morgan', '39115');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Morrow', '39117');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Muskingum', '39119');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Noble', '39121');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Ottawa', '39123');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Paulding', '39125');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Perry', '39127');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Pickaway', '39129');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Pike', '39131');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Portage', '39133');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Preble', '39135');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Putnam', '39137');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Richland', '39139');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Ross', '39141');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Sandusky', '39143');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Scioto', '39145');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Seneca', '39147');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Shelby', '39149');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Stark', '39151');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Summit', '39153');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Trumbull', '39155');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Tuscarawas', '39157');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Union', '39159');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Van Wert', '39161');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Vinton', '39163');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Warren', '39165');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Washington', '39167');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Wayne', '39169');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Williams', '39171');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Wood', '39173');
INSERT INTO fips_lookup (state, county, code) VALUES ('OH', 'Wyandot', '39175');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Adair', '40001');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Alfalfa', '40003');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Atoka', '40005');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Beaver', '40007');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Beckham', '40009');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Blaine', '40011');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Bryan', '40013');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Caddo', '40015');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Canadian', '40017');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Carter', '40019');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Cherokee', '40021');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Choctaw', '40023');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Cimarron', '40025');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Cleveland', '40027');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Coal', '40029');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Comanche', '40031');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Cotton', '40033');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Craig', '40035');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Creek', '40037');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Custer', '40039');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Delaware', '40041');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Dewey', '40043');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Ellis', '40045');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Garfield', '40047');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Garvin', '40049');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Grady', '40051');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Grant', '40053');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Greer', '40055');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Harmon', '40057');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Harper', '40059');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Haskell', '40061');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Hughes', '40063');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Jackson', '40065');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Jefferson', '40067');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Johnston', '40069');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Kay', '40071');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Kingfisher', '40073');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Kiowa', '40075');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Latimer', '40077');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Le Flore', '40079');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Lincoln', '40081');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Logan', '40083');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Love', '40085');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Mcclain', '40087');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'McCurtain', '40089');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'McIntosh', '40091');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Major', '40093');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Marshall', '40095');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Mayes', '40097');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Murray', '40099');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Muskogee', '40101');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Noble', '40103');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Nowata', '40105');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Okfuskee', '40107');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Oklahoma', '40109');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Okmulgee', '40111');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Osage', '40113');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Ottawa', '40115');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Pawnee', '40117');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Payne', '40119');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Pittsburg', '40121');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Pontotoc', '40123');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Pottawatomie', '40125');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Pushmataha', '40127');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Roger Mills', '40129');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Rogers', '40131');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Seminole', '40133');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Sequoyah', '40135');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Stephens', '40137');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Texas', '40139');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Tillman', '40141');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Tulsa', '40143');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Wagoner', '40145');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Washington', '40147');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Washita', '40149');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Woods', '40151');
INSERT INTO fips_lookup (state, county, code) VALUES ('OK', 'Woodward', '40153');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Baker', '41001');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Benton', '41003');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Clackamas', '41005');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Clatsop', '41007');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Columbia', '41009');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Coos', '41011');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Crook', '41013');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Curry', '41015');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Deschutes', '41017');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Douglas', '41019');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Gilliam', '41021');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Grant', '41023');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Harney', '41025');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Hood River', '41027');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Jackson', '41029');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Jefferson', '41031');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Josephine', '41033');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Klamath', '41035');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Lake', '41037');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Lane', '41039');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Lincoln', '41041');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Linn', '41043');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Malheur', '41045');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Marion', '41047');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Morrow', '41049');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Multnomah', '41051');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Polk', '41053');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Sherman', '41055');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Tillamook', '41057');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Umatilla', '41059');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Union', '41061');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Wallowa', '41063');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Wasco', '41065');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Washington', '41067');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Wheeler', '41069');
INSERT INTO fips_lookup (state, county, code) VALUES ('OR', 'Yamhill', '41071');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Adams', '42001');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Allegheny', '42003');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Armstrong', '42005');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Beaver', '42007');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Bedford', '42009');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Berks', '42011');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Blair', '42013');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Bradford', '42015');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Bucks', '42017');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Butler', '42019');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Cambria', '42021');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Cameron', '42023');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Carbon', '42025');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Centre', '42027');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Chester', '42029');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Clarion', '42031');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Clearfield', '42033');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Clinton', '42035');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Columbia', '42037');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Crawford', '42039');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Cumberland', '42041');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Dauphin', '42043');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Delaware', '42045');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Elk', '42047');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Erie', '42049');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Fayette', '42051');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Forest', '42053');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Franklin', '42055');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Fulton', '42057');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Greene', '42059');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Huntingdon', '42061');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Indiana', '42063');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Jefferson', '42065');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Juniata', '42067');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Lackawanna', '42069');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Lancaster', '42071');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Lawrence', '42073');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Lebanon', '42075');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Lehigh', '42077');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Luzerne', '42079');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Lycoming', '42081');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'McKean', '42083');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Mercer', '42085');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Mifflin', '42087');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Monroe', '42089');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Montgomery', '42091');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Montour', '42093');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Northampton', '42095');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Northumberland', '42097');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Perry', '42099');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Philadelphia', '42101');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Pike', '42103');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Potter', '42105');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Schuylkill', '42107');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Snyder', '42109');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Somerset', '42111');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Sullivan', '42113');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Susquehanna', '42115');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Tioga', '42117');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Union', '42119');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Venango', '42121');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Warren', '42123');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Washington', '42125');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Wayne', '42127');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Westmoreland', '42129');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'Wyoming', '42131');
INSERT INTO fips_lookup (state, county, code) VALUES ('PA', 'York', '42133');
INSERT INTO fips_lookup (state, county, code) VALUES ('RI', 'Bristol', '44001');
INSERT INTO fips_lookup (state, county, code) VALUES ('RI', 'Kent', '44003');
INSERT INTO fips_lookup (state, county, code) VALUES ('RI', 'Newport', '44005');
INSERT INTO fips_lookup (state, county, code) VALUES ('RI', 'Providence', '44007');
INSERT INTO fips_lookup (state, county, code) VALUES ('RI', 'Washington', '44009');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Abbeville', '45001');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Aiken', '45003');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Allendale', '45005');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Anderson', '45007');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Bamberg', '45009');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Barnwell', '45011');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Beaufort', '45013');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Berkeley', '45015');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Calhoun', '45017');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Charleston', '45019');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Cherokee', '45021');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Chester', '45023');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Chesterfield', '45025');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Clarendon', '45027');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Colleton', '45029');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Darlington', '45031');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Dillon', '45033');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Dorchester', '45035');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Edgefield', '45037');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Fairfield', '45039');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Florence', '45041');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Georgetown', '45043');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Greenville', '45045');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Greenwood', '45047');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Hampton', '45049');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Horry', '45051');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Jasper', '45053');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Kershaw', '45055');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Lancaster', '45057');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Laurens', '45059');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Lee', '45061');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Lexington', '45063');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'McCormick', '45065');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Marion', '45067');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Marlboro', '45069');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Newberry', '45071');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Oconee', '45073');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Orangeburg', '45075');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Pickens', '45077');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Richland', '45079');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Saluda', '45081');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Spartanburg', '45083');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Sumter', '45085');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Union', '45087');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'Williamsburg', '45089');
INSERT INTO fips_lookup (state, county, code) VALUES ('SC', 'York', '45091');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Aurora', '46003');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Beadle', '46005');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Bennett', '46007');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Bon Homme', '46009');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Brookings', '46011');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Brown', '46013');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Brule', '46015');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Buffalo', '46017');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Butte', '46019');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Campbell', '46021');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Charles Mix', '46023');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Clark', '46025');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Clay', '46027');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Codington', '46029');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Corson', '46031');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Custer', '46033');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Davison', '46035');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Day', '46037');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Deuel', '46039');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Dewey', '46041');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Douglas', '46043');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Edmunds', '46045');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Fall River', '46047');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Faulk', '46049');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Grant', '46051');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Gregory', '46053');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Haakon', '46055');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Hamlin', '46057');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Hand', '46059');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Hanson', '46061');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Harding', '46063');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Hughes', '46065');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Hutchinson', '46067');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Hyde', '46069');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Jackson', '46071');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Jerauld', '46073');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Jones', '46075');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Kingsbury', '46077');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Lake', '46079');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Lawrence', '46081');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Lincoln', '46083');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Lyman', '46085');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'McCook', '46087');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'McPherson', '46089');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Marshall', '46091');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Meade', '46093');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Mellette', '46095');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Miner', '46097');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Minnehaha', '46099');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Moody', '46101');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Pennington', '46103');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Perkins', '46105');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Potter', '46107');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Roberts', '46109');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Sanborn', '46111');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Shannon', '46113');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Spink', '46115');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Stanley', '46117');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Sully', '46119');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Todd', '46121');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Tripp', '46123');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Turner', '46125');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Union', '46127');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Walworth', '46129');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Yankton', '46135');
INSERT INTO fips_lookup (state, county, code) VALUES ('SD', 'Ziebach', '46137');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Anderson', '47001');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Bedford', '47003');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Benton', '47005');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Bledsoe', '47007');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Blount', '47009');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Bradley', '47011');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Campbell', '47013');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Cannon', '47015');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Carroll', '47017');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Carter', '47019');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Cheatham', '47021');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Chester', '47023');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Claiborne', '47025');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Clay', '47027');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Cocke', '47029');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Coffee', '47031');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Crockett', '47033');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Cumberland', '47035');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Davidson', '47037');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Decatur', '47039');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Dekalb', '47041');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Dickson', '47043');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Dyer', '47045');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Fayette', '47047');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Fentress', '47049');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Franklin', '47051');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Gibson', '47053');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Giles', '47055');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Grainger', '47057');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Greene', '47059');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Grundy', '47061');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hamblen', '47063');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hamilton', '47065');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hancock', '47067');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hardeman', '47069');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hardin', '47071');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hawkins', '47073');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Haywood', '47075');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Henderson', '47077');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Henry', '47079');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Hickman', '47081');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Houston', '47083');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Humphreys', '47085');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Jackson', '47087');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Jefferson', '47089');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Johnson', '47091');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Knox', '47093');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Lake', '47095');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Lauderdale', '47097');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Lawrence', '47099');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Lewis', '47101');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Lincoln', '47103');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Loudon', '47105');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'McMinn', '47107');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'McNairy', '47109');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Macon', '47111');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Madison', '47113');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Marion', '47115');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Marshall', '47117');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Maury', '47119');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Meigs', '47121');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Monroe', '47123');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Montgomery', '47125');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Moore', '47127');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Morgan', '47129');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Obion', '47131');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Overton', '47133');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Perry', '47135');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Pickett', '47137');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Polk', '47139');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Putnam', '47141');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Rhea', '47143');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Roane', '47145');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Robertson', '47147');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Rutherford', '47149');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Scott', '47151');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Sequatchie', '47153');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Sevier', '47155');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Shelby', '47157');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Smith', '47159');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Stewart', '47161');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Sullivan', '47163');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Sumner', '47165');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Tipton', '47167');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Trousdale', '47169');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Unicoi', '47171');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Union', '47173');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Van Buren', '47175');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Warren', '47177');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Washington', '47179');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Wayne', '47181');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Weakley', '47183');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'White', '47185');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Williamson', '47187');
INSERT INTO fips_lookup (state, county, code) VALUES ('TN', 'Wilson', '47189');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Anderson', '48001');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Andrews', '48003');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Angelina', '48005');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Aransas', '48007');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Archer', '48009');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Armstrong', '48011');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Atascosa', '48013');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Austin', '48015');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bailey', '48017');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bandera', '48019');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bastrop', '48021');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Baylor', '48023');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bee', '48025');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bell', '48027');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bexar', '48029');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Blanco', '48031');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Borden', '48033');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bosque', '48035');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Bowie', '48037');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Brazoria', '48039');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Brazos', '48041');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Brewster', '48043');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Briscoe', '48045');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Brooks', '48047');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Brown', '48049');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Burleson', '48051');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Burnet', '48053');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Caldwell', '48055');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Calhoun', '48057');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Callahan', '48059');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Cameron', '48061');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Camp', '48063');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Carson', '48065');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Cass', '48067');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Castro', '48069');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Chambers', '48071');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Cherokee', '48073');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Childress', '48075');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Clay', '48077');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Cochran', '48079');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Coke', '48081');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Coleman', '48083');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Collin', '48085');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Collingsworth', '48087');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Colorado', '48089');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Comal', '48091');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Comanche', '48093');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Concho', '48095');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Cooke', '48097');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Coryell', '48099');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Cottle', '48101');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Crane', '48103');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Crockett', '48105');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Crosby', '48107');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Culberson', '48109');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Dallam', '48111');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Dallas', '48113');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Dawson', '48115');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Deaf Smith', '48117');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Delta', '48119');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Denton', '48121');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'De Witt', '48123');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Dickens', '48125');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Dimmit', '48127');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Donley', '48129');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Duval', '48131');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Eastland', '48133');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Ector', '48135');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Edwards', '48137');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Ellis', '48139');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'El Paso', '48141');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Erath', '48143');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Falls', '48145');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Fannin', '48147');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Fayette', '48149');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Fisher', '48151');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Floyd', '48153');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Foard', '48155');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Fort Bend', '48157');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Franklin', '48159');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Freestone', '48161');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Frio', '48163');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Gaines', '48165');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Galveston', '48167');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Garza', '48169');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Gillespie', '48171');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Glasscock', '48173');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Goliad', '48175');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Gonzales', '48177');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Gray', '48179');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Grayson', '48181');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Gregg', '48183');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Grimes', '48185');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Guadalupe', '48187');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hale', '48189');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hall', '48191');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hamilton', '48193');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hansford', '48195');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hardeman', '48197');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hardin', '48199');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Harris', '48201');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Harrison', '48203');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hartley', '48205');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Haskell', '48207');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hays', '48209');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hemphill', '48211');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Henderson', '48213');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hidalgo', '48215');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hill', '48217');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hockley', '48219');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hood', '48221');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hopkins', '48223');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Houston', '48225');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Howard', '48227');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hudspeth', '48229');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hunt', '48231');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Hutchinson', '48233');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Irion', '48235');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jack', '48237');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jackson', '48239');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jasper', '48241');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jeff Davis', '48243');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jefferson', '48245');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jim Hogg', '48247');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jim Wells', '48249');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Johnson', '48251');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Jones', '48253');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Karnes', '48255');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kaufman', '48257');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kendall', '48259');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kenedy', '48261');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kent', '48263');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kerr', '48265');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kimble', '48267');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'King', '48269');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kinney', '48271');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Kleberg', '48273');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Knox', '48275');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lamar', '48277');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lamb', '48279');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lampasas', '48281');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'La Salle', '48283');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lavaca', '48285');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lee', '48287');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Leon', '48289');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Liberty', '48291');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Limestone', '48293');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lipscomb', '48295');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Live Oak', '48297');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Llano', '48299');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Loving', '48301');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lubbock', '48303');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Lynn', '48305');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'McCulloch', '48307');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'McLennan', '48309');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'McMullen', '48311');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Madison', '48313');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Marion', '48315');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Martin', '48317');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Mason', '48319');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Matagorda', '48321');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Maverick', '48323');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Medina', '48325');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Menard', '48327');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Midland', '48329');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Milam', '48331');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Mills', '48333');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Mitchell', '48335');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Montague', '48337');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Montgomery', '48339');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Moore', '48341');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Morris', '48343');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Motley', '48345');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Nacogdoches', '48347');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Navarro', '48349');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Newton', '48351');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Nolan', '48353');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Nueces', '48355');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Ochiltree', '48357');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Oldham', '48359');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Orange', '48361');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Palo Pinto', '48363');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Panola', '48365');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Parker', '48367');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Parmer', '48369');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Pecos', '48371');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Polk', '48373');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Potter', '48375');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Presidio', '48377');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Rains', '48379');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Randall', '48381');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Reagan', '48383');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Real', '48385');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Red River', '48387');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Reeves', '48389');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Refugio', '48391');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Roberts', '48393');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Robertson', '48395');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Rockwall', '48397');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Runnels', '48399');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Rusk', '48401');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Sabine', '48403');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'San Augustine', '48405');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'San Jacinto', '48407');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'San Patricio', '48409');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'San Saba', '48411');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Schleicher', '48413');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Scurry', '48415');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Shackelford', '48417');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Shelby', '48419');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Sherman', '48421');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Smith', '48423');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Somervell', '48425');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Starr', '48427');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Stephens', '48429');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Sterling', '48431');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Stonewall', '48433');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Sutton', '48435');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Swisher', '48437');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Tarrant', '48439');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Taylor', '48441');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Terrell', '48443');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Terry', '48445');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Throckmorton', '48447');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Titus', '48449');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Tom Green', '48451');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Travis', '48453');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Trinity', '48455');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Tyler', '48457');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Upshur', '48459');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Upton', '48461');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Uvalde', '48463');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Val Verde', '48465');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Van Zandt', '48467');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Victoria', '48469');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Walker', '48471');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Waller', '48473');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Ward', '48475');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Washington', '48477');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Webb', '48479');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wharton', '48481');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wheeler', '48483');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wichita', '48485');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wilbarger', '48487');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Willacy', '48489');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Williamson', '48491');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wilson', '48493');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Winkler', '48495');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wise', '48497');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Wood', '48499');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Yoakum', '48501');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Young', '48503');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Zapata', '48505');
INSERT INTO fips_lookup (state, county, code) VALUES ('TX', 'Zavala', '48507');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Beaver', '49001');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Box Elder', '49003');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Cache', '49005');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Carbon', '49007');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Daggett', '49009');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Davis', '49011');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Duchesne', '49013');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Emery', '49015');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Garfield', '49017');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Grand', '49019');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Iron', '49021');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Juab', '49023');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Kane', '49025');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Millard', '49027');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Morgan', '49029');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Piute', '49031');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Rich', '49033');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Salt Lake', '49035');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'San Juan', '49037');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Sanpete', '49039');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Sevier', '49041');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Summit', '49043');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Tooele', '49045');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Uintah', '49047');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Utah', '49049');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Wasatch', '49051');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Washington', '49053');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Wayne', '49055');
INSERT INTO fips_lookup (state, county, code) VALUES ('UT', 'Weber', '49057');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Addison', '50001');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Bennington', '50003');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Caledonia', '50005');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Chittenden', '50007');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Essex', '50009');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Franklin', '50011');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Grand Isle', '50013');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Lamoille', '50015');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Orange', '50017');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Orleans', '50019');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Rutland', '50021');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Washington', '50023');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Windham', '50025');
INSERT INTO fips_lookup (state, county, code) VALUES ('VT', 'Windsor', '50027');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Accomack', '51001');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Albemarle', '51003');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Alleghany', '51005');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Amelia', '51007');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Amherst', '51009');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Appomattox', '51011');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Arlington', '51013');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Augusta', '51015');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Bath', '51017');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Bedford', '51019');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Bland', '51021');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Botetourt', '51023');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Brunswick', '51025');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Buchanan', '51027');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Buckingham', '51029');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Campbell', '51031');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Caroline', '51033');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Carroll', '51035');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Charles City', '51036');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Charlotte', '51037');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Chesterfield', '51041');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Clarke', '51043');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Craig', '51045');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Culpeper', '51047');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Cumberland', '51049');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Dickenson', '51051');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Dinwiddie', '51053');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Essex', '51057');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Fairfax', '51059');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Fauquier', '51061');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Floyd', '51063');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Fluvanna', '51065');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Franklin', '51067');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Frederick', '51069');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Giles', '51071');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Gloucester', '51073');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Goochland', '51075');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Grayson', '51077');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Greene', '51079');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Greensville', '51081');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Halifax', '51083');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Hanover', '51085');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Henrico', '51087');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Henry', '51089');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Highland', '51091');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Isle of Wight', '51093');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'James City', '51095');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'King and Queen', '51097');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'King George', '51099');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'King William', '51101');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Lancaster', '51103');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Lee', '51105');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Loudoun', '51107');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Louisa', '51109');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Lunenburg', '51111');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Madison', '51113');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Mathews', '51115');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Mecklenburg', '51117');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Middlesex', '51119');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Montgomery', '51121');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Nelson', '51125');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'New Kent', '51127');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Northampton', '51131');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Northumberland', '51133');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Nottoway', '51135');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Orange', '51137');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Page', '51139');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Patrick', '51141');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Pittsylvania', '51143');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Powhatan', '51145');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Prince Edward', '51147');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Prince George', '51149');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Prince William', '51153');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Pulaski', '51155');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Rappahannock', '51157');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Richmond', '51159');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Roanoke', '51161');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Rockbridge', '51163');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Rockingham', '51165');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Russell', '51167');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Scott', '51169');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Shenandoah', '51171');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Smyth', '51173');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Southampton', '51175');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Spotsylvania', '51177');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Stafford', '51179');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Surry', '51181');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Sussex', '51183');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Tazewell', '51185');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Warren', '51187');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Washington', '51191');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Westmoreland', '51193');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Wise', '51195');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Wythe', '51197');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'York', '51199');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Alexandria City', '51510');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Bedford City', '51515');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Bristol City', '51520');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Buena Vista City', '51530');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Charlottesville City', '51540');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Chesapeake City', '51550');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Clifton Forge City', '51560');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Colonial Heights City', '51570');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Covington City', '51580');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Danville City', '51590');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Emporia City', '51595');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Fairfax City', '51600');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Falls Church City', '51610');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Franklin City', '51620');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Fredericksburg City', '51630');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Galax City', '51640');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Hampton City', '51650');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Harrisonburg City', '51660');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Hopewell City', '51670');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Lexington City', '51678');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Lynchburg City', '51680');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Manassas City', '51683');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Manassas Park City', '51685');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Martinsville City', '51690');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Newport News City', '51700');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Norfolk City', '51710');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Norton City', '51720');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Petersburg City', '51730');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Poquoson City', '51735');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Portsmouth City', '51740');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Radford', '51750');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Richmond City', '51760');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Roanoke City', '51770');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Salem City', '51775');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'South Boston City', '51780');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Staunton City', '51790');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Suffolk City', '51800');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Virginia Beach City', '51810');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Waynesboro City', '51820');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Williamsburg City', '51830');
INSERT INTO fips_lookup (state, county, code) VALUES ('VA', 'Winchester City', '51840');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Adams', '53001');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Asotin', '53003');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Benton', '53005');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Chelan', '53007');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Clallam', '53009');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Clark', '53011');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Columbia', '53013');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Cowlitz', '53015');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Douglas', '53017');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Ferry', '53019');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Franklin', '53021');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Garfield', '53023');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Grant', '53025');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Grays Harbor', '53027');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Island', '53029');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Jefferson', '53031');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'King', '53033');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Kitsap', '53035');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Kittitas', '53037');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Klickitat', '53039');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Lewis', '53041');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Lincoln', '53043');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Mason', '53045');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Okanogan', '53047');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Pacific', '53049');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Pend Oreille', '53051');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Pierce', '53053');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'San Juan', '53055');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Skagit', '53057');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Skamania', '53059');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Snohomish', '53061');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Spokane', '53063');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Stevens', '53065');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Thurston', '53067');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Wahkiakum', '53069');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Walla Walla', '53071');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Whatcom', '53073');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Whitman', '53075');
INSERT INTO fips_lookup (state, county, code) VALUES ('WA', 'Yakima', '53077');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Barbour', '54001');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Berkeley', '54003');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Boone', '54005');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Braxton', '54007');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Brooke', '54009');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Cabell', '54011');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Calhoun', '54013');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Clay', '54015');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Doddridge', '54017');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Fayette', '54019');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Gilmer', '54021');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Grant', '54023');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Greenbrier', '54025');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Hampshire', '54027');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Hancock', '54029');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Hardy', '54031');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Harrison', '54033');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Jackson', '54035');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Jefferson', '54037');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Kanawha', '54039');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Lewis', '54041');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Lincoln', '54043');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Logan', '54045');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'McDowell', '54047');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Marion', '54049');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Marshall', '54051');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Mason', '54053');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Mercer', '54055');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Mineral', '54057');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Mingo', '54059');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Monongalia', '54061');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Monroe', '54063');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Morgan', '54065');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Nicholas', '54067');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Ohio', '54069');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Pendleton', '54071');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Pleasants', '54073');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Pocahontas', '54075');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Preston', '54077');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Putnam', '54079');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Raleigh', '54081');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Randolph', '54083');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Ritchie', '54085');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Roane', '54087');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Summers', '54089');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Taylor', '54091');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Tucker', '54093');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Tyler', '54095');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Upshur', '54097');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Wayne', '54099');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Webster', '54101');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Wetzel', '54103');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Wirt', '54105');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Wood', '54107');
INSERT INTO fips_lookup (state, county, code) VALUES ('WV', 'Wyoming', '54109');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Adams', '55001');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Ashland', '55003');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Barron', '55005');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Bayfield', '55007');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Brown', '55009');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Buffalo', '55011');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Burnett', '55013');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Calumet', '55015');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Chippewa', '55017');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Clark', '55019');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Columbia', '55021');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Crawford', '55023');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Dane', '55025');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Dodge', '55027');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Door', '55029');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Douglas', '55031');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Dunn', '55033');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Eau Claire', '55035');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Florence', '55037');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Fond Du Lac', '55039');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Forest', '55041');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Grant', '55043');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Green', '55045');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Green Lake', '55047');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Iowa', '55049');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Iron', '55051');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Jackson', '55053');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Jefferson', '55055');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Juneau', '55057');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Kenosha', '55059');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Kewaunee', '55061');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'La Crosse', '55063');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Lafayette', '55065');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Langlade', '55067');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Lincoln', '55069');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Manitowoc', '55071');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Marathon', '55073');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Marinette', '55075');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Marquette', '55077');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Menominee', '55078');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Milwaukee', '55079');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Monroe', '55081');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Oconto', '55083');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Oneida', '55085');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Outagamie', '55087');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Ozaukee', '55089');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Pepin', '55091');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Pierce', '55093');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Polk', '55095');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Portage', '55097');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Price', '55099');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Racine', '55101');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Richland', '55103');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Rock', '55105');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Rusk', '55107');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'St Croix', '55109');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Sauk', '55111');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Sawyer', '55113');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Shawano', '55115');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Sheboygan', '55117');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Taylor', '55119');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Trempealeau', '55121');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Vernon', '55123');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Vilas', '55125');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Walworth', '55127');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Washburn', '55129');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Washington', '55131');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Waukesha', '55133');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Waupaca', '55135');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Waushara', '55137');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Winnebago', '55139');
INSERT INTO fips_lookup (state, county, code) VALUES ('WI', 'Wood', '55141');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Albany', '56001');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Big Horn', '56003');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Campbell', '56005');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Carbon', '56007');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Converse', '56009');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Crook', '56011');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Fremont', '56013');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Goshen', '56015');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Hot Springs', '56017');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Johnson', '56019');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Laramie', '56021');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Lincoln', '56023');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Natrona', '56025');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Niobrara', '56027');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Park', '56029');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Platte', '56031');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Sheridan', '56033');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Sublette', '56035');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Sweetwater', '56037');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Teton', '56039');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Uinta', '56041');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Washakie', '56043');
INSERT INTO fips_lookup (state, county, code) VALUES ('WY', 'Weston', '56045');

INSERT INTO jq_queue_config (name, lock_id, processes_per_dyno, subtasks_per_process, priority_factor, active) VALUES ('parcel_update', -1205876972, 2, 3, 0.100000000000000006, true);
INSERT INTO jq_queue_config (name, lock_id, processes_per_dyno, subtasks_per_process, priority_factor, active) VALUES ('mls', 539680176, 16, 1, 0.5, true);
INSERT INTO jq_queue_config (name, lock_id, processes_per_dyno, subtasks_per_process, priority_factor, active) VALUES ('misc', 1403811233, 2, 2, 0.5, true);
INSERT INTO jq_queue_config (name, lock_id, processes_per_dyno, subtasks_per_process, priority_factor, active) VALUES ('corelogic', 1951319906, 10, 1, 1, true);

SELECT pg_catalog.setval('jq_queue_config_lock_id_seq', 6, true);

INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('swflmls_loadRawData', 'swflmls', 'mls', 1, '{"dataType":"listing"}', 10, 10, false, true, true, 600, 750, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_loadRawData', 'corelogic', 'corelogic', 2, '{"dataType":"listing"}', 30, 10, false, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('MRED_loadRawData', 'MRED', 'mls', 1, '{"dataType":"listing"}', 10, 10, false, true, true, 600, 750, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('GLVAR_loadRawData', 'GLVAR', 'mls', 1, '{"dataType":"listing"}', 10, 10, false, true, true, 600, 750, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('temp_loadRawData', 'temp', 'mls', 1, '{"dataType":"listing"}', 10, 10, false, true, true, 600, 750, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('digimaps_define_imports', 'parcel_update', 'parcel_update', 1, NULL, 4, 4, false, true, true, 300, 600, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('digimaps_save', 'parcel_update', 'parcel_update', 2, NULL, 4, 4, false, true, true, 300, 600, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('sync_mv_parcels', 'parcel_update', 'parcel_update', 3, NULL, 4, 4, false, true, true, 300, 600, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('sync_cartodb', 'parcel_update', 'parcel_update', 4, NULL, 4, 4, false, true, true, 300, 600, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('swflmls_normalizeData', 'swflmls', 'mls', 2, NULL, NULL, 0, true, true, true, 60, 75, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('swflmls_recordChangeCounts', 'swflmls', 'mls', 3, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('swflmls_finalizeData', 'swflmls', 'mls', 5, NULL, NULL, 0, true, true, true, 600, 750, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('swflmls_finalizeDataPrep', 'swflmls', 'mls', 4, 'null', NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('swflmls_activateNewData', 'swflmls', 'mls', 6, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_checkFtpDrop', 'corelogic', 'misc', 1, NULL, 30, 10, false, true, true, 240, 300, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_normalizeData', 'corelogic', 'corelogic', 3, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_recordChangeCounts', 'corelogic', 'corelogic', 4, NULL, NULL, 0, true, true, true, 60, 75, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_finalizeDataPrep', 'corelogic', 'corelogic', 5, NULL, NULL, 0, true, true, true, 60, 75, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_finalizeData', 'corelogic', 'corelogic', 6, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_activateNewData', 'corelogic', 'corelogic', 7, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('corelogic_saveProcessDates', 'corelogic', 'corelogic', 8, NULL, NULL, 0, true, true, true, 15, 30, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('cleanup_rawTables', 'cleanup', 'misc', 1, NULL, 30, 2, true, true, true, 300, 600, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('cleanup_subtaskErrors', 'cleanup', 'misc', 1, NULL, 30, 2, true, true, true, 30, 60, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('cartodb_wake', 'cartodb', 'misc', 1, NULL, 4, 4, false, true, true, 60, 75, true);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('MRED_normalizeData', 'MRED', 'mls', 2, NULL, NULL, 0, true, true, true, 60, 75, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('MRED_recordChangeCounts', 'MRED', 'mls', 3, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('MRED_finalizeDataPrep', 'MRED', 'mls', 4, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('MRED_finalizeData', 'MRED', 'mls', 5, NULL, NULL, 0, true, true, true, 600, 750, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('MRED_activateNewData', 'MRED', 'mls', 6, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('GLVAR_normalizeData', 'GLVAR', 'mls', 2, NULL, NULL, 0, true, true, true, 60, 75, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('GLVAR_finalizeDataPrep', 'GLVAR', 'mls', 4, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('GLVAR_recordChangeCounts', 'GLVAR', 'mls', 3, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('GLVAR_finalizeData', 'GLVAR', 'mls', 5, NULL, NULL, 0, true, true, true, 600, 750, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('GLVAR_activateNewData', 'GLVAR', 'mls', 6, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('temp_normalizeData', 'temp', 'mls', 2, NULL, NULL, 0, true, true, true, 60, 75, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('temp_recordChangeCounts', 'temp', 'mls', 3, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('temp_finalizeDataPrep', 'temp', 'mls', 4, NULL, NULL, 0, true, true, true, 30, 45, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('temp_finalizeData', 'temp', 'mls', 5, NULL, NULL, 0, true, true, true, 600, 750, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('temp_activateNewData', 'temp', 'mls', 6, NULL, NULL, 0, true, true, true, 240, 300, false);
INSERT INTO jq_subtask_config (name, task_name, queue_name, step_num, data, retry_delay_seconds, retry_max_count, hard_fail_timeouts, hard_fail_after_retries, hard_fail_zombies, warn_timeout_seconds, kill_timeout_seconds, auto_enqueue) VALUES ('cleanup_deleteMarkers', 'cleanup', 'misc', 1, NULL, 30, 2, true, true, true, 30, 60, true);

INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('swflmls', 'Refresh mls data', '{}', NULL, 15, 12, 14, true, 1);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('cleanup', 'Clean up old logs, temp data tables, etc', '{}', NULL, 1440, 10, 15, true, 60);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('cartodb', 'Wake up the cartodb tile svc every hour.', '{}', NULL, 60, 1, 2, false, 1);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('GLVAR', 'Refresh mls data', '{}', NULL, 15, 12, 14, true, 1);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('temp', 'Refresh mls data', '{}', NULL, 15, 12, 14, false, 1);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('MRED', 'Refresh mls data', '{}', NULL, 15, 12, 14, true, 1);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('corelogic', 'Check every day for new corelogic data files to process', '{"host":"ftp2.resftp.com","user":"Realty_Mapster","password":"0/m0OTjQRVbo7xgZMWpWXA==$$taqwaMV4fdg0z60=$"}', NULL, 1440, 20, 25, false, 60);
INSERT INTO jq_task_config (name, description, data, ignore_until, repeat_period_minutes, warn_timeout_minutes, kill_timeout_minutes, active, fail_retry_minutes) VALUES ('parcel_update', 'Fetch new parcels save them to the parcels tables, sync mv_parcels, then sync cartodb.', '{"DIGIMAPS":{"ACCOUNT":"NgximUzHDCfMmFVv3h3Gbg==$$oDusRMRFqw36MyE7fw==$","URL":"YRQ4iKv4N+AchZVT34L4Yw==$$X3UzwUTrkuqo9DxdDfo=$","PASSWORD":"z/tipYeaOU9rrZ8cyJHJSQ==$$/gecucU1ag==$"}}', NULL, 1440, 1, 2, false, 1);

INSERT INTO management_useraccountprofile (id, user_id, suspended, override_basic_monthly_charge, override_basic_yearly_charge, override_basic_num_logins, override_standard_monthly_charge, override_standard_yearly_charge, override_standard_num_logins, override_premium_monthly_charge, override_premium_yearly_charge, override_premium_num_logins, notes) VALUES (1, 1, false, 0, 0, NULL, 0, 0, NULL, 0, 0, NULL, '');
INSERT INTO management_useraccountprofile (id, user_id, suspended, override_basic_monthly_charge, override_basic_yearly_charge, override_basic_num_logins, override_standard_monthly_charge, override_standard_yearly_charge, override_standard_num_logins, override_premium_monthly_charge, override_premium_yearly_charge, override_premium_num_logins, notes) VALUES (2, 3, false, 0, 0, NULL, 0, 0, NULL, 0, 0, NULL, '');
INSERT INTO management_useraccountprofile (id, user_id, suspended, override_basic_monthly_charge, override_basic_yearly_charge, override_basic_num_logins, override_standard_monthly_charge, override_standard_yearly_charge, override_standard_num_logins, override_premium_monthly_charge, override_premium_yearly_charge, override_premium_num_logins, notes) VALUES (3, 2, false, 0, 0, NULL, 0, 0, NULL, 0, 0, NULL, '');

SELECT pg_catalog.setval('management_useraccountprofile_id_seq', 3, true);

INSERT INTO mls_config (id, name, notes, username, password, url, listing_data, static_ip, data_rules) VALUES ('temp', 'temp', '', 'temp', 'Atpt7FLghwzYJ1OulDvlDQ==$$ftHQLw==$', 'temp', '{"queryTemplate":"[(__FIELD_NAME__=]YYYY-MM-DD[T]HH:mm:ss[+)]"}', false, '{}');
INSERT INTO mls_config (id, name, notes, username, password, url, listing_data, static_ip, data_rules) VALUES ('MRED', 'Illinois - Chicago', 'still having issues with duplicate log ins - could not download a CSV to check field values - FYI', 'RETS_RealtyMapster', '+/tjpODv3mSiuOIlQ7M4nA==$$VWoUqPkGsyNeew==$', 'http://connectmls-rets.mredllc.com/rets/server/login', '{"queryTemplate":"[(__FIELD_NAME__=]YYYY-MM-DD[T]HH:mm:ss[+)]","db":"Property","table":"ResidentialProperty","field":"RECORDMODDATE"}', false, '{}');
INSERT INTO mls_config (id, name, notes, username, password, url, listing_data, static_ip, data_rules) VALUES ('swflmls', 'Southwest Florida', '', 'NAPMLSRealtyMapster', 'XULf8vbWlSun4GPyo/L4LA==$$gK8zgUYlMLQe1g==$', 'http://matrix.swflamls.com/rets/login.ashx', '{"queryTemplate":"[(__FIELD_NAME__=]YYYY-MM-DD[T]HH:mm:ss[+)]","db":"Property","table":"RES","field":"LastChangeTimestamp"}', false, '{"nullString":""}');
INSERT INTO mls_config (id, name, notes, username, password, url, listing_data, static_ip, data_rules) VALUES ('GLVAR', 'Nevada - Las Vegas', '', 'realmap', 'Y9aI5LN0QXcnz3bAhKESJg==$$wdXG7w22Ww==$', 'http://glvar.apps.retsiq.com/rets/login', '{"queryTemplate":"[(__FIELD_NAME__=]YYYY-MM-DD[T]HH:mm:ss[+)]","db":"Property","table":"1","field":"135"}', false, '{"nullString":"***"}');

SELECT pg_catalog.setval('project_id_seq', 1, false);

INSERT INTO us_states (id, code, name) VALUES (1, 'AL', 'Alabama');
INSERT INTO us_states (id, code, name) VALUES (2, 'AK', 'Alaska');
INSERT INTO us_states (id, code, name) VALUES (3, 'AZ', 'Arizona');
INSERT INTO us_states (id, code, name) VALUES (4, 'AR', 'Arkansas');
INSERT INTO us_states (id, code, name) VALUES (5, 'CA', 'California');
INSERT INTO us_states (id, code, name) VALUES (6, 'CO', 'Colorado');
INSERT INTO us_states (id, code, name) VALUES (7, 'CT', 'Connecticut');
INSERT INTO us_states (id, code, name) VALUES (8, 'DE', 'Delaware');
INSERT INTO us_states (id, code, name) VALUES (9, 'DC', 'District of Columbia');
INSERT INTO us_states (id, code, name) VALUES (10, 'FL', 'Florida');
INSERT INTO us_states (id, code, name) VALUES (11, 'GA', 'Georgia');
INSERT INTO us_states (id, code, name) VALUES (12, 'HI', 'Hawaii');
INSERT INTO us_states (id, code, name) VALUES (13, 'ID', 'Idaho');
INSERT INTO us_states (id, code, name) VALUES (14, 'IL', 'Illinois');
INSERT INTO us_states (id, code, name) VALUES (15, 'IN', 'Indiana');
INSERT INTO us_states (id, code, name) VALUES (16, 'IA', 'Iowa');
INSERT INTO us_states (id, code, name) VALUES (17, 'KS', 'Kansas');
INSERT INTO us_states (id, code, name) VALUES (18, 'KY', 'Kentucky');
INSERT INTO us_states (id, code, name) VALUES (19, 'LA', 'Louisiana');
INSERT INTO us_states (id, code, name) VALUES (20, 'ME', 'Maine');
INSERT INTO us_states (id, code, name) VALUES (21, 'MD', 'Maryland');
INSERT INTO us_states (id, code, name) VALUES (22, 'MA', 'Massachusetts');
INSERT INTO us_states (id, code, name) VALUES (23, 'MI', 'Michigan');
INSERT INTO us_states (id, code, name) VALUES (24, 'MN', 'Minnesota');
INSERT INTO us_states (id, code, name) VALUES (25, 'MS', 'Mississippi');
INSERT INTO us_states (id, code, name) VALUES (26, 'MO', 'Missouri');
INSERT INTO us_states (id, code, name) VALUES (27, 'MT', 'Montana');
INSERT INTO us_states (id, code, name) VALUES (28, 'NE', 'Nebraska');
INSERT INTO us_states (id, code, name) VALUES (29, 'NV', 'Nevada');
INSERT INTO us_states (id, code, name) VALUES (30, 'NH', 'New Hampshire');
INSERT INTO us_states (id, code, name) VALUES (31, 'NJ', 'New Jersey');
INSERT INTO us_states (id, code, name) VALUES (32, 'NM', 'New Mexico');
INSERT INTO us_states (id, code, name) VALUES (33, 'NY', 'New York');
INSERT INTO us_states (id, code, name) VALUES (34, 'NC', 'North Carolina');
INSERT INTO us_states (id, code, name) VALUES (35, 'ND', 'North Dakota');
INSERT INTO us_states (id, code, name) VALUES (36, 'OH', 'Ohio');
INSERT INTO us_states (id, code, name) VALUES (37, 'OK', 'Oklahoma');
INSERT INTO us_states (id, code, name) VALUES (38, 'OR', 'Oregon');
INSERT INTO us_states (id, code, name) VALUES (39, 'PA', 'Pennsylvania');
INSERT INTO us_states (id, code, name) VALUES (40, 'RI', 'Rhode Island');
INSERT INTO us_states (id, code, name) VALUES (41, 'SC', 'South Carolina');
INSERT INTO us_states (id, code, name) VALUES (42, 'SD', 'South Dakota');
INSERT INTO us_states (id, code, name) VALUES (43, 'TN', 'Tennessee');
INSERT INTO us_states (id, code, name) VALUES (44, 'TX', 'Texas');
INSERT INTO us_states (id, code, name) VALUES (45, 'UT', 'Utah');
INSERT INTO us_states (id, code, name) VALUES (46, 'VT', 'Vermont');
INSERT INTO us_states (id, code, name) VALUES (47, 'VA', 'Virginia');
INSERT INTO us_states (id, code, name) VALUES (48, 'WA', 'Washington');
INSERT INTO us_states (id, code, name) VALUES (49, 'WV', 'West Virginia');
INSERT INTO us_states (id, code, name) VALUES (50, 'WI', 'Wisconsin');
INSERT INTO us_states (id, code, name) VALUES (51, 'WY', 'Wyoming');

SELECT pg_catalog.setval('us_states_id_seq', 51, true);

ALTER TABLE ONLY account_images
ADD CONSTRAINT account_images_pkey PRIMARY KEY (id);

ALTER TABLE ONLY account_use_types
ADD CONSTRAINT account_use_types_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_group
ADD CONSTRAINT auth_group_name_key UNIQUE (name);

ALTER TABLE ONLY auth_group_permissions
ADD CONSTRAINT auth_group_permissions_group_id_permission_id_key UNIQUE (group_id, permission_id);

ALTER TABLE ONLY auth_group_permissions
ADD CONSTRAINT auth_group_permissions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_group
ADD CONSTRAINT auth_group_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_permission
ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_user
ADD CONSTRAINT auth_user_email_unique_key UNIQUE (email);

ALTER TABLE ONLY auth_user_groups
ADD CONSTRAINT auth_user_groups_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_user_groups
ADD CONSTRAINT auth_user_groups_user_id_group_id_key UNIQUE (user_id, group_id);

ALTER TABLE ONLY auth_user
ADD CONSTRAINT auth_user_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_user_profile
ADD CONSTRAINT auth_user_profile_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_user_user_permissions
ADD CONSTRAINT auth_user_user_permissions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY auth_user_user_permissions
ADD CONSTRAINT auth_user_user_permissions_user_id_permission_id_key UNIQUE (user_id, permission_id);

ALTER TABLE ONLY company
ADD CONSTRAINT company_pkey PRIMARY KEY (id);

ALTER TABLE ONLY external_accounts
ADD CONSTRAINT external_accounts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY fips_lookup
ADD CONSTRAINT fips_lookup_code_key UNIQUE (code);

ALTER TABLE ONLY jq_current_subtasks
ADD CONSTRAINT jq_current_subtasks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY jq_queue_config
ADD CONSTRAINT jq_queue_config_lock_id_key UNIQUE (lock_id);

ALTER TABLE ONLY jq_queue_config
ADD CONSTRAINT jq_queue_config_pkey PRIMARY KEY (name);

ALTER TABLE ONLY jq_task_config
ADD CONSTRAINT jq_task_config_pkey PRIMARY KEY (name);

ALTER TABLE ONLY jq_task_history
ADD CONSTRAINT jq_task_history_name_batch_id_key UNIQUE (name, batch_id);

ALTER TABLE ONLY management_useraccountprofile
ADD CONSTRAINT management_useraccountprofile_pkey PRIMARY KEY (id);

ALTER TABLE ONLY management_useraccountprofile
ADD CONSTRAINT management_useraccountprofile_user_id_key UNIQUE (user_id);

ALTER TABLE ONLY mls_config
ADD CONSTRAINT mls_config_pkey PRIMARY KEY (id);

ALTER TABLE ONLY project
ADD CONSTRAINT project_pkey PRIMARY KEY (id);

ALTER TABLE ONLY session
ADD CONSTRAINT session_pkey PRIMARY KEY (sid);

ALTER TABLE ONLY session_security
ADD CONSTRAINT session_security_pkey PRIMARY KEY (id);

ALTER TABLE ONLY us_states
ADD CONSTRAINT us_states_pkey PRIMARY KEY (id);

CREATE INDEX auth_group_name_like ON auth_group USING btree (name varchar_pattern_ops);

CREATE INDEX auth_group_permissions_group_id ON auth_group_permissions USING btree (group_id);

CREATE INDEX auth_group_permissions_permission_id ON auth_group_permissions USING btree (permission_id);

CREATE INDEX auth_user_groups_group_id ON auth_user_groups USING btree (group_id);

CREATE INDEX auth_user_groups_user_id ON auth_user_groups USING btree (user_id);

CREATE INDEX auth_user_user_permissions_permission_id ON auth_user_user_permissions USING btree (permission_id);

CREATE INDEX auth_user_user_permissions_user_id ON auth_user_user_permissions USING btree (user_id);

CREATE INDEX auth_user_username_like ON auth_user USING btree (username varchar_pattern_ops);

CREATE INDEX data_normalization_config_data_source_id_data_type_list_ord_idx ON data_normalization_config USING btree (data_source_id, data_type, list, ordering);

CREATE INDEX fips_lookup_county_idx ON fips_lookup USING gist (county gist_trgm_ops);

CREATE INDEX fips_lookup_state_idx ON fips_lookup USING btree (state);

CREATE UNIQUE INDEX jq_subtask_config_name_idx ON jq_subtask_config USING btree (name);

CREATE UNIQUE INDEX jq_subtask_config_task_name_name_idx ON jq_subtask_config USING btree (task_name, name);

CREATE TRIGGER update_modified_time_auth_user_profile BEFORE UPDATE ON auth_user_profile FOR EACH ROW EXECUTE PROCEDURE update_rm_modified_time_column();

CREATE TRIGGER update_modified_time_project BEFORE UPDATE ON project FOR EACH ROW EXECUTE PROCEDURE update_rm_modified_time_column();

ALTER TABLE ONLY auth_group_permissions
ADD CONSTRAINT auth_group_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES auth_permission(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY auth_user_profile
ADD CONSTRAINT auth_profile_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth_user(id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY auth_user_profile
ADD CONSTRAINT auth_profile_parent_auth_user_id_fkey FOREIGN KEY (parent_auth_user_id) REFERENCES auth_user(id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY auth_user_profile
ADD CONSTRAINT auth_profile_project_id_fkey FOREIGN KEY (project_id) REFERENCES project(id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY auth_user_groups
ADD CONSTRAINT auth_user_groups_group_id_fkey FOREIGN KEY (group_id) REFERENCES auth_group(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY auth_user_user_permissions
ADD CONSTRAINT auth_user_user_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES auth_permission(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY company
ADD CONSTRAINT company_account_photo_id_fkey FOREIGN KEY (account_image_id) REFERENCES account_images(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY auth_user
ADD CONSTRAINT fk_auth_user_account_image_id FOREIGN KEY (account_image_id) REFERENCES account_images(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY auth_user
ADD CONSTRAINT fk_auth_user_account_use_type_id FOREIGN KEY (account_use_type_id) REFERENCES account_use_types(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY auth_user
ADD CONSTRAINT fk_auth_user_company_id FOREIGN KEY (company_id) REFERENCES company(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY auth_user_profile
ADD CONSTRAINT fk_auth_user_profile_account_image_id FOREIGN KEY (account_image_id) REFERENCES account_images(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY auth_user
ADD CONSTRAINT fk_auth_user_us_state_id FOREIGN KEY (us_state_id) REFERENCES us_states(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY company
ADD CONSTRAINT fk_company_us_state_id FOREIGN KEY (us_state_id) REFERENCES us_states(id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY auth_group_permissions
ADD CONSTRAINT group_id_refs_id_f4b32aac FOREIGN KEY (group_id) REFERENCES auth_group(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY management_useraccountprofile
ADD CONSTRAINT management_useraccountprofile_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth_user(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY notification
ADD CONSTRAINT notification_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth_user(id);

ALTER TABLE ONLY session_security
ADD CONSTRAINT session_security_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth_user(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY auth_user_groups
ADD CONSTRAINT user_id_refs_id_40c41112 FOREIGN KEY (user_id) REFERENCES auth_user(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY auth_user_user_permissions
ADD CONSTRAINT user_id_refs_id_4dc23c39 FOREIGN KEY (user_id) REFERENCES auth_user(id) DEFERRABLE INITIALLY DEFERRED;


