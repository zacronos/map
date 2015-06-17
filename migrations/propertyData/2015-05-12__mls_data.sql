DROP TABLE IF EXISTS mls_data;
CREATE TABLE mls_data (
  rm_inserted_time TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now_utc(),
  rm_modified_time TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now_utc(),

  data_source_id TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  deleted BOOLEAN NOT NULL,
  up_to_date TIMESTAMP NOT NULL,
  
  change_history JSON,
  
  rm_property_id TEXT NOT NULL,
  fips_code INTEGER NOT NULL,
  parcel_id TEXT NOT NULL,
  address JSON NOT NULL,
  price NUMERIC NOT NULL,
  days_on_market INTEGER NOT NULL,
  bedrooms INTEGER,
  baths_full INTEGER,
  acres NUMERIC,
  sqft_finished INTEGER,
  status TEXT NOT NULL,
  substatus TEXT NOT NULL,
  status_display TEXT NOT NULL,
  
  client_groups JSON NOT NULL,
  realtor_groups JSON NOT NULL,
  hidden_fields JSON NOT NULL,
  ungrouped_fields JSON NOT NULL
);

CREATE TRIGGER update_modified_time_mls_data
  AFTER UPDATE ON mls_data
  FOR EACH ROW EXECUTE PROCEDURE update_rm_modified_time_column();