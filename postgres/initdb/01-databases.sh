#!/bin/sh
# Runs once, on an empty volume. Mirrors RDS: one instance, two databases, and per database an
# owner role (runs migrations, owns the tables) and an app role (data only, no DDL).

set -eu

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -v auth_owner_pw="$AUTH_OWNER_PASSWORD" -v auth_app_pw="$AUTH_APP_PASSWORD" \
  -v members_owner_pw="$MEMBERS_OWNER_PASSWORD" -v members_app_pw="$MEMBERS_APP_PASSWORD" <<'SQL'
CREATE ROLE auth_owner LOGIN PASSWORD :'auth_owner_pw';
CREATE ROLE auth_app LOGIN PASSWORD :'auth_app_pw';
CREATE DATABASE auth OWNER auth_owner;
REVOKE CONNECT, TEMPORARY ON DATABASE auth FROM PUBLIC;
GRANT CONNECT ON DATABASE auth TO auth_app;

CREATE ROLE members_owner LOGIN PASSWORD :'members_owner_pw';
CREATE ROLE members_app LOGIN PASSWORD :'members_app_pw';
CREATE DATABASE members OWNER members_owner;
REVOKE CONNECT, TEMPORARY ON DATABASE members FROM PUBLIC;
GRANT CONNECT ON DATABASE members TO members_app;
SQL

for db in auth members; do
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" \
    -v owner="${db}_owner" -v app="${db}_app" <<'SQL'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app";
-- Tables the owner creates later (migrations) get these grants automatically.
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" GRANT USAGE, SELECT ON SEQUENCES TO :"app";
SQL
done
