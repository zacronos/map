insert into jq_subtask_config (
	name,
	task_name,
	queue_name,
	step_num,
	retry_delay_seconds,
	hard_fail_timeouts,
	hard_fail_after_retries,
	hard_fail_zombies,
	retry_max_count,
	warn_timeout_seconds,
	kill_timeout_seconds,
	auto_enqueue,
	active
)
values
(
	'<default_mls_photos_config>_setLastUpdateTimestamp',
	'<default_mls_photos_config>',
	'mls',
	6,
	10,
	false,
	true,
	false,
	5,
	30,
	60,
	false,
	true
),
(
	'swflmls_photos_setLastUpdateTimestamp',
	'swflmls_photos',
	'mls',
	6,
	10,
	false,
	true,
	false,
	5,
	30,
	60,
	false,
	true
);

delete from jq_subtask_config where name like '%_storePhotosPrep' or name like '%_storePhotos' or name like '%_clearPhotoRetries';
