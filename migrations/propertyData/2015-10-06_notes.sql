DROP TRIGGER IF EXISTS update_modified_geom_point_raw_notes ON user_notes;
DROP TRIGGER IF EXISTS insert_modified_geom_point_raw_notes ON user_notes;

CREATE TRIGGER update_modified_geom_point_raw_notes
  BEFORE UPDATE ON user_notes
  FOR EACH ROW EXECUTE PROCEDURE update_geom_point_raw_from_geom_point_json();

CREATE TRIGGER insert_modified_geom_point_raw_notes
  BEFORE INSERT ON user_notes
  FOR EACH ROW EXECUTE PROCEDURE update_geom_point_raw_from_geom_point_json();

ALTER TABLE user_notes ADD COLUMN rm_property_id varchar(64);
