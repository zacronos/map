CREATE TABLE user_history (
  auth_user_id INT REFERENCES auth_user (id),
  category TEXT NOT NULL,  -- broad category for an action, something like `account`, `project`, or `mail`
  subcategory TEXT NOT NULL,  -- more specific name for the action that compliments category, like `account`-`deactivate` or `mail`-`submitted`
  description TEXT, -- contains text for notes or description, can often be user defined like a typed reason for `account`-`deactivate`
  rm_inserted_time TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now_utc()
);
