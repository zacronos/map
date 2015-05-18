
INSERT INTO jq_queue_config (
  name,
  lock_id,
  processes_per_dyno,
  subtasks_per_process,
  priority_factor,
  active
) VALUES (
  'cartodb',
  x'cf980b42'::INTEGER,
  '1',
  '1',
  '0.01',
  TRUE
);

INSERT INTO jq_task_config (
  name,
  description,
  data,
  repeat_period_minutes,
  warn_timeout_minutes,
  kill_timeout_minutes,
  active
) VALUES (
  'cartodb_wake',
  'Wake up the cartodb tile svc every hour.',
  '{}',
  '60',
  '1',
  '2',
  FALSE
);
