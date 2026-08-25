-- Run this on an existing database that already has public.rounds.
-- A fresh database gets the column from 001 and does not need this file.
--
-- Adds the flood guard key. player_ref comes from the request body, so a
-- limit keyed on it is a limit on honest clients only: rotating the value
-- walks around it. This column is written by the edge function from the
-- caller address, is not part of any leaf, and is never canonicalised, so
-- adding it does not change a single anchored hash.

alter table public.rounds add column if not exists source_ip text;

create index if not exists rounds_player_idx on public.rounds (player_ref, ended_at);
create index if not exists rounds_ip_idx     on public.rounds (source_ip, ended_at);

-- EpochSettled gained a `refundedUsdt` field. Re-run 002 to pick it up in the
-- epoch_settlements view; the view is `create or replace` and holds no data,
-- so re-running it is safe at any time.
