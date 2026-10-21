CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_wallet_id UUID NOT NULL,
  to_wallet_id UUID NOT NULL,
  amount_minor BIGINT NOT NULL,
  currency TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', -- pending | completed | failed
  reason TEXT,
  idempotency_key TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Outbox pattern (see wallet-service migration for the full rationale):
-- the TRANSFER_INITIATED event is written here in the same transaction as
-- the transfer row, so a crash right after the HTTP write can never lose
-- the event or publish one for a transfer that didn't actually save.
CREATE TABLE outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  published BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE processed_events (
  event_id UUID PRIMARY KEY,
  processed_at TIMESTAMPTZ DEFAULT now()
);
