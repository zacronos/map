-- The point of this table is to provide a generic key-value store, with an optional
-- namespace so that multiple, related fields can be queried simultaneously.
-- The value is a JSON field so it can contain data of any time, including complex types.

DROP TABLE IF EXISTS keystore;
DROP TABLE IF EXISTS keystore_user;
CREATE TABLE keystore_user (
  rm_inserted_time TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now_utc(),
  rm_modified_time TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now_utc(),

  namespace TEXT,
  key TEXT NOT NULL,
  value JSON
);

CREATE UNIQUE INDEX ON keystore_user (namespace, key);

DROP TRIGGER IF EXISTS update_modified_time_keystore ON keystore_user;
CREATE TRIGGER update_modified_time_keystore
BEFORE UPDATE ON keystore_user
FOR EACH ROW EXECUTE PROCEDURE update_rm_modified_time_column();