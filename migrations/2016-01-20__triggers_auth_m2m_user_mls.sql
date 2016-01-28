DROP TRIGGER IF EXISTS delete_modified_auth_m2m_user_mls_to_auth_user_fips_codes
on auth_m2m_user_mls;

CREATE TRIGGER delete_modified_auth_m2m_user_mls_to_auth_user_fips_codes
AFTER DELETE ON auth_m2m_user_mls
FOR EACH ROW EXECUTE PROCEDURE f_update_fips_codes();

DROP TRIGGER IF EXISTS insert_modified_auth_m2m_user_mls_to_auth_user_fips_codes
on auth_m2m_user_mls;

CREATE TRIGGER insert_modified_auth_m2m_user_mls_to_auth_user_fips_codes
BEFORE INSERT ON auth_m2m_user_mls
FOR EACH ROW EXECUTE PROCEDURE f_update_fips_codes();

DROP TRIGGER IF EXISTS update_modified_auth_m2m_user_mls_to_auth_user_fips_codes
on auth_m2m_user_mls;
CREATE TRIGGER update_modified_auth_m2m_user_mls_to_auth_user_fips_codes
BEFORE UPDATE ON auth_m2m_user_mls
FOR EACH ROW EXECUTE PROCEDURE f_update_fips_codes();