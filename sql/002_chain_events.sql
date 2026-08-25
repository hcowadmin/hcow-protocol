-- HCOW event index
--
-- Chain events are public by definition, so this table is world readable. It
-- exists because a browser cannot scan a year of BSC logs on page load: public
-- RPCs cap eth_getLogs by block range and by result count, and a dApp that
-- tries it just hangs. A worker walks the chain once and writes here; the app
-- reads a normal indexed table.
--
-- Nothing in here is a source of truth. Every figure can be recomputed from
-- the chain, and the contracts remain authoritative for balances. This is a
-- cache with a cursor.
--
-- Run this in the Supabase SQL editor.

create table if not exists chain_events (
  id            bigserial primary key,
  chain_id      integer      not null,
  contract      text         not null,          -- lower case address
  event         text         not null,          -- solidity event name
  block_number  bigint       not null,
  block_time    timestamptz  not null,
  tx_hash       text         not null,
  log_index     integer      not null,
  -- Denormalised for the two queries the app actually runs.
  account       text,                           -- lower case, null for protocol events
  epoch         bigint,                         -- EpochSettled only
  -- Full decoded arguments, wei kept as strings so nothing is rounded.
  args          jsonb        not null default '{}'::jsonb,

  -- A log is uniquely identified by its transaction and position in it.
  -- This is what makes the worker safe to re-run over a range it already did.
  unique (tx_hash, log_index)
);

create index if not exists chain_events_account_idx
  on chain_events (account, block_number desc)
  where account is not null;

create index if not exists chain_events_kind_time_idx
  on chain_events (event, block_time desc);

create index if not exists chain_events_epoch_idx
  on chain_events (epoch)
  where epoch is not null;

-- Cursor. One row per contract so a newly added contract can be backfilled
-- without rewinding the others.
create table if not exists indexer_state (
  key           text primary key,               -- '<chainId>:<contract>'
  last_block    bigint      not null,
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
-- Read: anyone. This is public chain data and the verification story depends
-- on anybody being able to check it.
-- Write: the service role only, which is the worker. The anon key the browser
-- ships with must never be able to insert a row, or the "index" becomes a
-- place to plant a fake settlement.

alter table chain_events  enable row level security;
alter table indexer_state enable row level security;

drop policy if exists chain_events_public_read on chain_events;
create policy chain_events_public_read
  on chain_events for select
  to anon, authenticated
  using (true);

-- No insert, update or delete policy is defined for anon or authenticated,
-- so with RLS on they cannot write. The service role bypasses RLS.

-- Granted explicitly rather than relying on the project's default privileges,
-- which differ between a fresh Supabase project and one that has been locked
-- down. An index nobody can read is a silent failure in the browser.
grant select on chain_events to anon, authenticated;

revoke insert, update, delete on chain_events  from anon, authenticated;
revoke all                    on indexer_state from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rollups the dashboard reads
-- ---------------------------------------------------------------------------
-- security_invoker so the views are read with the caller's own permissions
-- rather than the owner's. Without it a view silently becomes a way around
-- row level security, which is exactly the kind of hole nobody notices.
--
-- Views rather than materialised views: the volume is one settlement per week,
-- so freshness matters more than speed, and a stale materialised view showing
-- last week's revenue as this week's is a worse failure than a slow query.

create or replace view epoch_settlements with (security_invoker = true) as
select
  chain_id,
  epoch,
  block_time                                as settled_at,
  tx_hash,
  (args->>'grossReceivedUsdt')::numeric     as gross_received_usdt,
  (args->>'directCostsUsdt')::numeric       as direct_costs_usdt,
  (args->>'netRevenueUsdt')::numeric        as net_revenue_usdt,
  (args->>'operatingCostsUsdt')::numeric    as operating_costs_usdt,
  (args->>'distributableProfitUsdt')::numeric as distributable_profit_usdt,
  (args->>'participantsUsdt')::numeric      as participants_usdt,
  -- The part of the participant leg the eligible pool could not take, returned
  -- to the settler in the same transaction. Zero whenever every share is
  -- eligible, which is the steady state. The waterfall is
  -- distributable = participants + refunded + gameCompany + team, and it does
  -- not reconcile without this column. coalesce so the view still works over
  -- rows indexed before the field existed.
  coalesce((args->>'refundedUsdt')::numeric, 0) as refunded_usdt,
  (args->>'hcowDeducted')::numeric          as hcow_deducted,
  (args->>'snapshotBondedHcow')::numeric    as snapshot_bonded_hcow
from chain_events
where event = 'EpochSettled';

-- Windowed totals, in wei. The app divides by 1e18 at its own boundary.
create or replace view revenue_windows with (security_invoker = true) as
select
  chain_id,
  coalesce(sum(gross_received_usdt) filter (where settled_at > now() - interval '24 hours'), 0) as gross_24h,
  coalesce(sum(gross_received_usdt) filter (where settled_at > now() - interval '7 days'),   0) as gross_7d,
  coalesce(sum(gross_received_usdt) filter (where settled_at > now() - interval '30 days'),  0) as gross_30d,
  coalesce(sum(participants_usdt)   filter (where settled_at > now() - interval '30 days'),  0) as participants_30d,
  coalesce(sum(hcow_deducted)       filter (where settled_at > now() - interval '24 hours'), 0) as burned_24h,
  coalesce(sum(hcow_deducted)       filter (where settled_at > now() - interval '30 days'),  0) as burned_30d
from epoch_settlements
group by chain_id;

grant select on epoch_settlements, revenue_windows to anon, authenticated;
