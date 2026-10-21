-- 004: consumed HCOW is split 70 / 20 / 10, not burned in full.
--
-- HCOWProfitShare used to send every consumed HCOW to the burn address, so
-- revenue_windows.burned_* was computed as sum(hcowDeducted). Since the split,
-- hcowDeducted is what was CONSUMED: 70% went to the reward vault, 20% to the
-- burn address and 10% to the team address, and each split is reported by a
-- ConsumedHcowRouted event in the same transaction. Left as it was, burned_*
-- would overstate the real burn fivefold.
--
-- burned_* keeps its name and meaning (HCOW sent to the burn address by
-- settlements) so nothing that reads it breaks; it is now read from the
-- routing event. consumed_* carries the old figure under its real name, and
-- the two new legs are added beside it. Forfeits are routed the same way and
-- appear in consumed_hcow_routes with source 'forfeit'; revenue_windows counts
-- settlements only, exactly as before.

create or replace view consumed_hcow_routes with (security_invoker = true) as
select
  chain_id,
  block_time,
  tx_hash,
  case when account = '0x0000000000000000000000000000000000000000' then null else account end as account,
  case when account = '0x0000000000000000000000000000000000000000' then 'settlement' else 'forfeit' end as source,
  (args->>'toRewards')::numeric as to_rewards,
  (args->>'burned')::numeric    as burned,
  (args->>'toTeam')::numeric    as to_team
from chain_events
where event = 'ConsumedHcowRouted';

create or replace view revenue_windows with (security_invoker = true) as
with s as (
  select chain_id,
    coalesce(sum(gross_received_usdt) filter (where settled_at > now() - interval '24 hours'), 0) as gross_24h,
    coalesce(sum(gross_received_usdt) filter (where settled_at > now() - interval '7 days'),   0) as gross_7d,
    coalesce(sum(gross_received_usdt) filter (where settled_at > now() - interval '30 days'),  0) as gross_30d,
    coalesce(sum(participants_usdt)   filter (where settled_at > now() - interval '30 days'),  0) as participants_30d,
    coalesce(sum(hcow_deducted)       filter (where settled_at > now() - interval '24 hours'), 0) as consumed_24h,
    coalesce(sum(hcow_deducted)       filter (where settled_at > now() - interval '30 days'),  0) as consumed_30d
  from epoch_settlements
  group by chain_id
), r as (
  select chain_id,
    coalesce(sum(burned)     filter (where block_time > now() - interval '24 hours'), 0) as burned_24h,
    coalesce(sum(burned)     filter (where block_time > now() - interval '30 days'),  0) as burned_30d,
    coalesce(sum(to_rewards) filter (where block_time > now() - interval '30 days'),  0) as to_rewards_30d,
    coalesce(sum(to_team)    filter (where block_time > now() - interval '30 days'),  0) as to_team_30d
  from consumed_hcow_routes
  where source = 'settlement'
  group by chain_id
)
-- Column order matches 002 for the first seven, so create or replace is legal;
-- the new columns are appended.
select
  s.chain_id,
  s.gross_24h, s.gross_7d, s.gross_30d, s.participants_30d,
  coalesce(r.burned_24h, 0) as burned_24h,
  coalesce(r.burned_30d, 0) as burned_30d,
  s.consumed_24h, s.consumed_30d,
  coalesce(r.to_rewards_30d, 0) as to_rewards_30d,
  coalesce(r.to_team_30d, 0)    as to_team_30d
from s left join r using (chain_id);

grant select on consumed_hcow_routes, revenue_windows to anon, authenticated;
