-- Run after enabling pg_cron and pg_net and creating the three Vault secrets
-- documented in README.md. pg_cron uses UTC: 18:00 UTC = 02:00 MYT.
select cron.schedule(
  'voltway-ocm-daily',
  '0 18 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'voltway_project_url') || '/functions/v1/sync-ocm',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'voltway_publishable_key'),
      'x-sync-token', (select decrypted_secret from vault.decrypted_secrets where name = 'voltway_ocm_sync_token')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $$
);
