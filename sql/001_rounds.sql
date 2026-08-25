-- HashCow round ledger. Run once in the Supabase SQL editor.
--
-- One row per finished round, across all games. This is the table the
-- anchor worker reads. Nothing else writes to it and nothing ever updates
-- or deletes from it: rows are append only, enforced below, because a row
-- that can change after it was anchored would make the anchor a lie.

create table if not exists public.rounds (
  id            bigserial primary key,

  kind          text        not null default 'skill'
                            check (kind in ('skill','seeded')),

  game_id       text        not null,
  round_id      text        not null,
  player_ref    text        not null,

  -- skill records
  mode          text,
  level         integer,
  score         integer,
  duration_ms   integer,

  -- seeded records
  server_seed_hash text,
  server_seed      text,
  client_seed      text,
  nonce            integer,

  outcome       text        not null,
  ended_at      bigint      not null,          -- unix seconds, settled time

  inserted_at   timestamptz not null default now(),

  -- The caller address, as seen by the edge function. Not part of any leaf
  -- and never canonicalised: it exists only so the flood guard can be keyed
  -- on something the caller does not choose. player_ref comes from the request
  -- body and can be rotated freely, which makes a limit on it a limit on
  -- honest clients only.
  source_ip     text,

  -- a round id must be unique inside a game, forever
  constraint rounds_game_round_unique unique (game_id, round_id),

  -- a skill row must carry the skill fields, a seeded row the seeded ones
  constraint rounds_shape check (
    (kind = 'skill'  and mode is not null and level is not null
                     and score is not null and duration_ms is not null)
    or
    (kind = 'seeded' and server_seed_hash is not null and server_seed is not null
                     and client_seed is not null and nonce is not null)
  )
);

create index if not exists rounds_ended_at_idx on public.rounds (ended_at);
create index if not exists rounds_game_idx     on public.rounds (game_id, ended_at);
create index if not exists rounds_player_idx   on public.rounds (player_ref, ended_at);
-- source_ip is added by this file on a fresh database. On a database created
-- before it existed, run sql/003_source_ip.sql instead: re-running this file
-- there is a no-op for the table (`if not exists`) and then fails on the index
-- below, because the column is not there.
create index if not exists rounds_ip_idx       on public.rounds (source_ip, ended_at);

-- ---------------------------------------------------------------------
-- append only
-- ---------------------------------------------------------------------
create or replace function public.rounds_no_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'rounds is append only. rows cannot be updated or deleted.';
end $$;

drop trigger if exists rounds_block_update on public.rounds;
create trigger rounds_block_update before update on public.rounds
  for each row execute function public.rounds_no_mutation();

drop trigger if exists rounds_block_delete on public.rounds;
create trigger rounds_block_delete before delete on public.rounds
  for each row execute function public.rounds_no_mutation();

-- ---------------------------------------------------------------------
-- access
-- ---------------------------------------------------------------------
alter table public.rounds enable row level security;

-- Nobody reads this table with the public key. Rounds are written through
-- a server side function and read by the worker with the service key.
-- Without this, one anon key in a game file would expose every player's
-- history to anyone who opened dev tools.
revoke all on public.rounds from anon, authenticated;

-- ---------------------------------------------------------------------
-- anchor bookkeeping
-- ---------------------------------------------------------------------
create table if not exists public.anchors (
  epoch        bigint      primary key,
  root         text        not null,
  record_count integer     not null,
  tx_hash      text,
  anchored_at  timestamptz not null default now()
);

-- One row per round once its epoch is anchored, so a receipt can be handed
-- to a player later without rebuilding the tree.
create table if not exists public.receipts (
  game_id   text   not null,
  round_id  text   not null,
  epoch     bigint not null references public.anchors(epoch),
  leaf      text   not null,
  proof     jsonb  not null,
  primary key (game_id, round_id)
);

alter table public.anchors  enable row level security;
alter table public.receipts enable row level security;
revoke all on public.anchors, public.receipts from anon, authenticated;
