-- Run only after PLANMalaysia reuse permission is documented and MEVNET_REUSE_APPROVED=true.
-- Requires pg_cron, pg_net, and the Vault secrets described in README.md.
-- 18:30 UTC = 02:30 MYT, after the daily OCM job.
select cron.schedule(
  'voltway-mevnet-daily',
  '30 18 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'voltway_project_url') || '/functions/v1/sync-mevnet',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'voltway_publishable_key'),
      'x-sync-token', (select decrypted_secret from vault.decrypted_secrets where name = 'voltway_mevnet_sync_token')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $$
);
