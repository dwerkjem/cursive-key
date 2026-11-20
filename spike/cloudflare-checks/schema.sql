CREATE TABLE IF NOT EXISTS hits (
  ts TEXT NOT NULL,
  tag TEXT,
  path TEXT,
  method TEXT,
  jwt_header INTEGER,
  jwt_type TEXT,
  jwt_email TEXT,
  cookie_names TEXT,
  cf_auth_cookie INTEGER
);
