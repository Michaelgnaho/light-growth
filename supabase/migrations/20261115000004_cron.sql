-- Light Growth Academy: scheduled jobs.
-- One idempotent sweep every 5 minutes: opens the day, closes expired days (unreported -> Not done),
-- queues reminders and alerts, prepares level reviews, and re-queues stuck notifications.
-- Safe to re-run; guarded by an advisory lock inside run_sweep().

create extension if not exists pg_cron with schema pg_catalog;

select cron.unschedule(jobid) from cron.job where jobname = 'lga-sweep';
select cron.schedule('lga-sweep', '*/5 * * * *', $$select public.run_sweep();$$);

-- Notification dispatcher (WhatsApp + email) is an Edge Function that calls
-- public.claim_notifications(50) with the service role, sends, then marks rows
-- sent / failed (back to 'queued' with next_attempt_at backoff, max 5 attempts).
-- Trigger it every minute with pg_net once the function URL and key are in Vault, e.g.:
--
--   select cron.schedule('lga-dispatch', '* * * * *', $$
--     select net.http_post(
--       url     := 'https://<project-ref>.supabase.co/functions/v1/dispatch-notifications',
--       headers := jsonb_build_object('Authorization', 'Bearer ' ||
--                    (select decrypted_secret from vault.decrypted_secrets where name = 'dispatch_key'))
--     );
--   $$);
