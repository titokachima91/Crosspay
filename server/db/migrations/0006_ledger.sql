-- 0006_ledger.sql
-- Double-entry ledger. Every journal transaction is single-currency and must
-- balance to zero. Ledger history is append-only; corrections are reversals.

CREATE TABLE ledger_accounts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code           text NOT NULL UNIQUE CHECK (code ~ '^[0-9]{4}(-[A-Z]{3})?$'),
  name           text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  type           text NOT NULL
                   CHECK (type IN ('asset', 'liability', 'equity', 'revenue', 'expense')),
  normal_side    text NOT NULL CHECK (normal_side IN ('debit', 'credit')),
  currency_code  char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  is_provisional boolean NOT NULL DEFAULT true,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ledger_accounts_currency_idx
  ON ledger_accounts (currency_code, code) WHERE active;

CREATE TABLE journal_transactions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_key           text NOT NULL UNIQUE
                          CHECK (posting_key ~ '^[a-z0-9][a-z0-9:._-]{2,199}$'),
  kind                  text NOT NULL
                          CHECK (kind IN ('deposit_received', 'fee_earned', 'payout_sent',
                                          'refund_paid', 'fx_conversion', 'adjustment',
                                          'opening_balance')),
  trade_id              uuid REFERENCES trades (id) ON DELETE RESTRICT,
  payment_event_id      uuid REFERENCES payment_events (id) ON DELETE RESTRICT,
  payout_id             uuid REFERENCES payouts (id) ON DELETE RESTRICT,
  refund_id             uuid REFERENCES refunds (id) ON DELETE RESTRICT,
  currency_code         char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  fx_group_id           uuid,
  reverses_transaction_id uuid REFERENCES journal_transactions (id) ON DELETE RESTRICT,
  occurred_at           timestamptz NOT NULL DEFAULT now(),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT journal_not_self_reversing CHECK (
    reverses_transaction_id IS NULL OR reverses_transaction_id <> id
  ),
  CONSTRAINT journal_fx_group_not_self CHECK (fx_group_id IS NULL OR fx_group_id <> id)
);

CREATE INDEX journal_transactions_trade_idx
  ON journal_transactions (trade_id, occurred_at) WHERE trade_id IS NOT NULL;
CREATE INDEX journal_transactions_payment_idx
  ON journal_transactions (payment_event_id) WHERE payment_event_id IS NOT NULL;
CREATE INDEX journal_transactions_payout_idx
  ON journal_transactions (payout_id) WHERE payout_id IS NOT NULL;
CREATE INDEX journal_transactions_refund_idx
  ON journal_transactions (refund_id) WHERE refund_id IS NOT NULL;
CREATE INDEX journal_transactions_fx_idx
  ON journal_transactions (fx_group_id, occurred_at) WHERE fx_group_id IS NOT NULL;
CREATE INDEX journal_transactions_occurred_idx ON journal_transactions (occurred_at);

CREATE TABLE journal_lines (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id uuid NOT NULL REFERENCES journal_transactions (id) ON DELETE RESTRICT,
  account_id     uuid NOT NULL REFERENCES ledger_accounts (id) ON DELETE RESTRICT,
  amount_minor   bigint NOT NULL CHECK (amount_minor <> 0),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT journal_line_unique_amount UNIQUE (transaction_id, account_id, amount_minor)
);

CREATE INDEX journal_lines_transaction_idx ON journal_lines (transaction_id);
CREATE INDEX journal_lines_account_idx ON journal_lines (account_id, created_at);

CREATE FUNCTION assert_journal_balanced()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  tx_currency char(3);
  line_total bigint;
  line_count integer;
  mismatched integer;
BEGIN
  SELECT currency_code INTO tx_currency
  FROM journal_transactions
  WHERE id = NEW.transaction_id;

  IF tx_currency IS NULL THEN
    RAISE EXCEPTION 'journal transaction % does not exist', NEW.transaction_id
      USING ERRCODE = '23503';
  END IF;

  SELECT count(*) INTO mismatched
  FROM journal_lines l
  JOIN ledger_accounts a ON a.id = l.account_id
  WHERE l.transaction_id = NEW.transaction_id
    AND a.currency_code <> tx_currency;

  IF mismatched > 0 THEN
    RAISE EXCEPTION 'journal transaction % mixes account currencies', NEW.transaction_id
      USING ERRCODE = '23514';
  END IF;

  SELECT COALESCE(sum(amount_minor), 0), count(*)
  INTO line_total, line_count
  FROM journal_lines
  WHERE transaction_id = NEW.transaction_id;

  IF line_count < 2 OR line_total <> 0 THEN
    RAISE EXCEPTION 'journal transaction % is not balanced (lines=%, total=%)',
      NEW.transaction_id, line_count, line_total
      USING ERRCODE = '23514';
  END IF;

  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER journal_lines_balanced
  AFTER INSERT ON journal_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION assert_journal_balanced();

CREATE FUNCTION reject_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION '% is append-only; use a reversing entry', TG_TABLE_NAME
    USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER journal_transactions_append_only
  BEFORE UPDATE OR DELETE ON journal_transactions
  FOR EACH ROW EXECUTE FUNCTION reject_ledger_mutation();
CREATE TRIGGER journal_lines_append_only
  BEFORE UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION reject_ledger_mutation();

CREATE TRIGGER ledger_accounts_set_updated_at
  BEFORE UPDATE ON ledger_accounts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE VIEW journal_transaction_balances AS
SELECT t.id AS transaction_id,
       t.posting_key,
       t.currency_code,
       COALESCE(sum(l.amount_minor), 0)::bigint AS balance_minor,
       count(l.id)::integer AS line_count
FROM journal_transactions t
LEFT JOIN journal_lines l ON l.transaction_id = t.id
GROUP BY t.id, t.posting_key, t.currency_code;

CREATE VIEW ledger_account_balances AS
SELECT a.id AS account_id,
       a.code,
       a.name,
       a.type,
       a.normal_side,
       a.currency_code,
       COALESCE(sum(l.amount_minor), 0)::bigint AS balance_minor
FROM ledger_accounts a
LEFT JOIN journal_lines l ON l.account_id = a.id
GROUP BY a.id, a.code, a.name, a.type, a.normal_side, a.currency_code;

COMMENT ON TABLE ledger_accounts IS
  'Chart of accounts. Seeded rows are marked provisional until Finance and Legal approve them.';
COMMENT ON TABLE journal_transactions IS
  'One economic event in one currency. posting_key is unique per event, so a retried webhook cannot post twice.';
COMMENT ON TABLE journal_lines IS
  'Signed minor-unit debit and credit lines. The deferred trigger requires each transaction to balance to zero.';
COMMENT ON VIEW ledger_account_balances IS
  'Derived balances. No customer wallet or spendable balance is stored.';
