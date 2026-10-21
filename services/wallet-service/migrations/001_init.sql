CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE wallets (
  id UUID PRIMARY KEY,
  owner_id UUID NOT NULL,
  currency TEXT NOT NULL,
  balance_minor BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Double-entry ledger: every balance movement is one debit row and one
-- credit row. The two always sum to zero across a transfer. This table is
-- append-only and is the audit trail — balances on `wallets` are a
-- derived/cached value for fast reads.
CREATE TABLE ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID NOT NULL REFERENCES wallets(id),
  transfer_id UUID NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('debit', 'credit')),
  amount_minor BIGINT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Outbox pattern: events are written here in the same DB transaction as the
-- business data, then a separate relay process publishes them to the
-- broker and marks them published. This guarantees we never lose an event
-- to a post-commit crash, and never publish an event for a write that
-- didn't actually commit.
CREATE TABLE outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  published BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Tracks which inbound event IDs have already been processed, so a
-- redelivered message (broker retry, consumer crash after commit but
-- before ack) doesn't get applied twice.
CREATE TABLE processed_events (
  event_id UUID PRIMARY KEY,
  processed_at TIMESTAMPTZ DEFAULT now()
);

-- Seed wallets. Owner IDs match the seeded users in auth-service.
-- Balances are in minor units (kobo), e.g. 10_000_000 = NGN 100,000.00
INSERT INTO wallets (id, owner_id, currency, balance_minor) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'NGN', 10000000),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'NGN', 5000000);
