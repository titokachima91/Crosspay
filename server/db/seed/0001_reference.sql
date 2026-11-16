-- seed/0001_reference.sql
-- Idempotent reference data for a new CrossPay database.
--
-- Deliberately NOT seeded:
--   * support_settings  - no real support desk exists yet; the app must say so.
--   * tier_limits       - daily limits are a product/finance decision.
--   * corridor_settings - no live pricing source is connected in B1.
--
-- Real names only. No placeholder phone numbers, emails or invented rates.

INSERT INTO config_versions (version, notes)
VALUES (1, 'B1 baseline: East African reference data, tiers and provisional ledger accounts.')
ON CONFLICT (version) DO NOTHING;

INSERT INTO countries (code, name, dial_code, national_number_length, sort_order, active)
VALUES
  ('TZ', 'Tanzania', '255', 9, 10, true),
  ('KE', 'Kenya', '254', 9, 20, true),
  ('UG', 'Uganda', '256', 9, 30, true),
  ('RW', 'Rwanda', '250', 9, 40, true),
  ('ZM', 'Zambia', '260', 9, 50, true),
  ('US', 'United States', '1', 10, 60, true)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  dial_code = EXCLUDED.dial_code,
  national_number_length = EXCLUDED.national_number_length,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

INSERT INTO currencies (code, name, country_code, decimals, sort_order, active)
VALUES
  ('TZS', 'Tanzanian Shilling', 'TZ', 0, 10, true),
  ('KES', 'Kenyan Shilling', 'KE', 2, 20, true),
  ('UGX', 'Ugandan Shilling', 'UG', 0, 30, true),
  ('RWF', 'Rwandan Franc', 'RW', 0, 40, true),
  ('ZMW', 'Zambian Kwacha', 'ZM', 2, 50, true),
  ('USD', 'US Dollar', 'US', 2, 60, true)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  country_code = EXCLUDED.country_code,
  decimals = EXCLUDED.decimals,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

INSERT INTO hubs (id, name, country_code, sort_order, active)
VALUES
  ('dar-es-salaam', 'Dar es Salaam', 'TZ', 10, true),
  ('nairobi', 'Nairobi', 'KE', 20, true),
  ('kampala', 'Kampala', 'UG', 30, true),
  ('kigali', 'Kigali', 'RW', 40, true),
  ('lusaka', 'Lusaka', 'ZM', 50, true)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  country_code = EXCLUDED.country_code,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

INSERT INTO carriers (id, name, country_code, prefix_pattern, sort_order, active)
VALUES
  ('vodacom-tz', 'Vodacom', 'TZ', '^(74|75|76|79)', 10, true),
  ('airtel-tz', 'Airtel', 'TZ', '^(68|69|78)', 20, true),
  ('tigo-tz', 'Tigo', 'TZ', '^(65|67|71|77)', 30, true),
  ('halotel-tz', 'Halotel', 'TZ', '^(61|62)', 40, true),
  ('ttcl-tz', 'TTCL', 'TZ', '^73', 50, true),
  ('safaricom-ke', 'Safaricom', 'KE', '^(70|71|72|74|79|11[0-9]|14[0-3]|18[0-2])', 10, true),
  ('airtel-ke', 'Airtel', 'KE', '^(73|75|78|100)', 20, true),
  ('telkom-ke', 'Telkom', 'KE', '^(77|105)', 30, true),
  ('mtn-ug', 'MTN', 'UG', '^(39|76|77|78)', 10, true),
  ('airtel-ug', 'Airtel', 'UG', '^(70|74|75)', 20, true),
  ('mtn-rw', 'MTN', 'RW', '^(78|79)', 10, true),
  ('airtel-rw', 'Airtel', 'RW', '^(72|73)', 20, true),
  ('mtn-zm', 'MTN', 'ZM', '^(76|96)', 10, true),
  ('airtel-zm', 'Airtel', 'ZM', '^(77|97)', 20, true),
  ('zamtel-zm', 'Zamtel', 'ZM', '^(75|95)', 30, true)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  country_code = EXCLUDED.country_code,
  prefix_pattern = EXCLUDED.prefix_pattern,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

INSERT INTO payout_rails (id, name, country_code, kind, sort_order, active)
VALUES
  ('mpesa-tz', 'M-Pesa', 'TZ', 'mobile_money', 10, true),
  ('airtel-money-tz', 'Airtel Money', 'TZ', 'mobile_money', 20, true),
  ('tigo-pesa-tz', 'Tigo Pesa', 'TZ', 'mobile_money', 30, true),
  ('crdb-bank-tz', 'CRDB Bank', 'TZ', 'bank', 40, true),
  ('nmb-bank-tz', 'NMB Bank', 'TZ', 'bank', 50, true),
  ('mpesa-ke', 'M-Pesa', 'KE', 'mobile_money', 10, true),
  ('airtel-money-ke', 'Airtel Money', 'KE', 'mobile_money', 20, true),
  ('equity-bank-ke', 'Equity Bank', 'KE', 'bank', 30, true),
  ('kcb-bank-ke', 'KCB Bank', 'KE', 'bank', 40, true),
  ('mtn-momo-ug', 'MTN Mobile Money', 'UG', 'mobile_money', 10, true),
  ('airtel-money-ug', 'Airtel Money', 'UG', 'mobile_money', 20, true),
  ('stanbic-bank-ug', 'Stanbic Bank', 'UG', 'bank', 30, true),
  ('mtn-momo-rw', 'MTN Mobile Money', 'RW', 'mobile_money', 10, true),
  ('airtel-money-rw', 'Airtel Money', 'RW', 'mobile_money', 20, true),
  ('bank-of-kigali-rw', 'Bank of Kigali', 'RW', 'bank', 30, true),
  ('mtn-momo-zm', 'MTN Mobile Money', 'ZM', 'mobile_money', 10, true),
  ('airtel-money-zm', 'Airtel Money', 'ZM', 'mobile_money', 20, true),
  ('zanaco-bank-zm', 'Zanaco', 'ZM', 'bank', 30, true)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  country_code = EXCLUDED.country_code,
  kind = EXCLUDED.kind,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

INSERT INTO tiers (code, name, active, sort_order)
VALUES ('starter', 'Starter', true, 10)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  active = EXCLUDED.active,
  sort_order = EXCLUDED.sort_order;

-- Conservative transition graph. Operations may add a row later, but may not
-- skip a documented state. Terminal states have no outgoing rows here.
INSERT INTO trade_status_transitions (from_status, to_status)
VALUES
  ('pending_deposit', 'escrowed'),
  ('pending_deposit', 'expired'),
  ('pending_deposit', 'failed'),
  ('pending_deposit', 'cancelled'),
  ('escrowed', 'expired'),
  ('escrowed', 'matching'),
  ('escrowed', 'refunded'),
  ('escrowed', 'failed'),
  ('escrowed', 'cancelled'),
  ('matching', 'expired'),
  ('matching', 'matched'),
  ('matching', 'refunded'),
  ('matching', 'failed'),
  ('matching', 'cancelled'),
  ('matched', 'disbursing'),
  ('matched', 'refunded'),
  ('matched', 'failed'),
  ('matched', 'cancelled'),
  ('disbursing', 'completed'),
  ('disbursing', 'refunded'),
  ('disbursing', 'failed'),
  ('completed', 'refunded'),
  ('failed', 'refunded'),
  ('expired', 'refunded')
ON CONFLICT (from_status, to_status) DO NOTHING;

-- Provisional chart of accounts, one account per active currency. Codes are
-- stable; Finance and Legal must approve or replace them before real postings.
WITH chart(code, name, type, normal_side) AS (
  VALUES
    ('1000', 'Partner trust cash', 'asset', 'debit'),
    ('1100', 'Payout clearing', 'asset', 'debit'),
    ('2000', 'Trade payable', 'liability', 'credit'),
    ('2050', 'Liquidity provider payable', 'liability', 'credit'),
    ('2100', 'Refund payable', 'liability', 'credit'),
    ('3000', 'Fee revenue', 'revenue', 'credit'),
    ('3100', 'Spread revenue', 'revenue', 'credit'),
    ('4000', 'FX position', 'asset', 'debit'),
    ('5000', 'FX clearing', 'asset', 'debit'),
    ('6000', 'Provider fees', 'expense', 'debit'),
    ('6100', 'Compensation expense', 'expense', 'debit'),
    ('7000', 'CrossPay treasury funding', 'liability', 'credit'),
    ('9000', 'Suspense', 'liability', 'credit')
)
INSERT INTO ledger_accounts (code, name, type, normal_side, currency_code, is_provisional, active)
SELECT chart.code || '-' || c.code,
       chart.name || ' (' || c.code || ')',
       chart.type,
       chart.normal_side,
       c.code,
       true,
       true
FROM chart
CROSS JOIN currencies c
WHERE c.active
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  type = EXCLUDED.type,
  normal_side = EXCLUDED.normal_side,
  currency_code = EXCLUDED.currency_code,
  is_provisional = EXCLUDED.is_provisional,
  active = EXCLUDED.active;
