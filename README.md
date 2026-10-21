# Fintech Microservices: Wallet Transfer Saga

A small, runnable fintech backend built to explore the patterns that matter once money moves between services: database-per-service, the transactional outbox, a choreography-based saga, idempotency keys, and a double-entry ledger.

**Stack:** Node.js 20, TypeScript, Fastify, PostgreSQL, RabbitMQ. No ORM. Raw `pg` queries keep the transaction boundaries visible.

## Patterns demonstrated

| Pattern | Where to look |
|---|---|
| Database per service | Each service owns its own Postgres database; nothing queries another service's tables |
| Transactional outbox | `payments-service/src/index.ts`, `wallet-service/src/consumer.ts`, relays in each `src/outbox.ts` |
| Choreography saga | Payments initiates, wallet reacts, payments finalizes. No central orchestrator |
| Idempotent producer | `Idempotency-Key` header plus a unique constraint on `transfers.idempotency_key` |
| Idempotent consumers | `processed_events` table keyed by event id |
| Double-entry ledger | Every transfer writes one debit row and one credit row to `ledger_entries` |
| Row locking | `SELECT ... FOR UPDATE` on wallets; `FOR UPDATE SKIP LOCKED` in the outbox relay |

## Architecture

```
client --> api-gateway :4000 --+--> auth-service      :4001 --> auth DB
                               |
                               +--> payments-service  :4002 --> payments DB
                               |         ^   |
                               |         |   v
                               |      RabbitMQ (topic exchange: fintech.events)
                               |         ^   |
                               |         |   v
                               +--> wallet-service    :4003 --> wallet DB
```

| Service | Port | Responsibility |
|---|---|---|
| api-gateway | 4000 | Single entry point. Verifies JWTs locally and proxies requests |
| auth-service | 4001 | Issues JWTs for seeded demo users |
| payments-service | 4002 | Owns the transfer lifecycle (`pending`, `completed`, `failed`) |
| wallet-service | 4003 | Owns wallets and the double-entry ledger |

## Transfer flow

1. Client calls `POST /transfers` through the gateway with an `Idempotency-Key` header.
2. payments-service inserts the transfer (`pending`) and an outbox row in one database transaction, then returns `202`.
3. The payments outbox relay publishes `payments.transfer.initiated`.
4. wallet-service consumes it. In one transaction it locks both wallets, checks the balance, updates balances, writes the debit and credit ledger rows, records the event id, and writes the result event to its own outbox. If funds are insufficient it writes a failure event and moves no money.
5. The wallet outbox relay publishes `wallet.transfer.completed` or `wallet.transfer.failed`.
6. payments-service consumes the result and sets the transfer status.

The client sees `pending` first and polls `GET /transfers/:id` until it settles. That gap is the saga running through the broker.

## Prerequisites

**Windows (PowerShell, no Docker, no local Postgres):**

- Node.js 20 or newer
- RabbitMQ installed as a Windows service (install Erlang first; the RabbitMQ installer page links the right version)
- A free [Neon](https://neon.tech) account for three Postgres databases

**Docker alternative:** `docker-compose.yml` is included and starts three Postgres containers, RabbitMQ, and all four services with `docker compose up --build`. The Windows workflow below does not use it, and it has not been exercised as part of that workflow.

## Quick start (Windows)

**1. Create the databases.** In Neon, create three databases named `auth`, `payments`, and `wallet`, and copy each connection string. They look like `postgresql://user:pass@ep-xxx.region.aws.neon.tech/auth?sslmode=require`.

**2. Run the migrations.** In the Neon SQL Editor, select each database and run the matching file:

| Database | File |
|---|---|
| auth | `services/auth-service/migrations/001_init.sql` |
| payments | `services/payments-service/migrations/001_init.sql` |
| wallet | `services/wallet-service/migrations/001_init.sql` |

**3. Run setup.** It checks Node and RabbitMQ, prompts for the three connection strings, writes one `.env` per service, and runs `npm install`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\scripts\setup-local.ps1"
```

**4. Start the services.** Each service opens in its own PowerShell window:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\scripts\start-local.ps1"
```

**5. Run the demo** (after about 10 seconds, once the services have connected):

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\scripts\demo.ps1"
```

`-ExecutionPolicy Bypass` applies to that single process only. Your system execution policy is never changed.

The demo checks all four health endpoints, logs in as Alice, sends a transfer to Bob, replays a request with the same idempotency key to prove no duplicate is created, triggers an insufficient-funds failure and verifies no balance changed, and prints the ledger entries.

## Seed data

| User | Wallet ID | Starting balance |
|---|---|---|
| alice@example.com | `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa` | NGN 100,000.00 |
| bob@example.com | `bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb` | NGN 50,000.00 |

Amounts are stored in minor units (kobo), so `100000` means NGN 1,000.00. Balances persist between runs. To reset, drop and recreate the databases (or tables) and re-run the migrations.

## API (through the gateway on :4000)

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/auth/login` | public | Body: `{"email": "alice@example.com"}`. Returns a JWT |
| GET | `/health` | public | |
| POST | `/transfers` | Bearer | Requires `Idempotency-Key` header. Returns `202` for new, `200` for a replay |
| GET | `/transfers/:id` | Bearer | |
| GET | `/wallets/:id` | Bearer | |
| GET | `/wallets/:id/ledger` | Bearer | Newest entries first |

Example in PowerShell:

```powershell
$login = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:4000/auth/login `
  -ContentType "application/json" -Body '{"email":"alice@example.com"}'

$headers = @{ Authorization = "Bearer $($login.token)"; "Idempotency-Key" = "my-key-001" }

Invoke-RestMethod -Method Post -Uri http://127.0.0.1:4000/transfers -Headers $headers `
  -ContentType "application/json" `
  -Body '{"fromWalletId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","toWalletId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","amountMinor":100000,"currency":"NGN"}'
```

## Project layout

```
fintech-microservices/
+-- docker-compose.yml
+-- README.md
+-- scripts/
|   +-- setup-local.ps1
|   +-- start-local.ps1
|   +-- demo.ps1
+-- services/
    +-- api-gateway/
    +-- auth-service/        (migrations/)
    +-- payments-service/    (migrations/)
    +-- wallet-service/      (migrations/)
```

Each service has its own `package.json`, `tsconfig.json`, `Dockerfile`, and `src/`. Event contracts live in a per-service `src/events.ts`. The copies are deliberate: services share a message contract, not code.

## Known limitations

This is an architecture exploration, not production code.

- **No resource authorization.** The gateway verifies the JWT but does not check that the caller owns `fromWalletId`. Any authenticated user can request a transfer from any wallet and read any wallet or ledger.
- **No passwords.** Login is by email only, and the JWT secret is shared with a default value in code.
- **Failures requeue forever.** A message that keeps failing is nack'd with requeue and retried indefinitely. It needs a retry counter and a dead-letter queue.
- **No publisher confirms.** Outbox relays mark a row published right after `channel.publish`, without waiting for a broker confirm.
- **Possible lock-order deadlock.** Two opposite-direction transfers between the same wallets can lock rows in different orders. Postgres aborts one, and the message is retried. Locking in a fixed id order would prevent it.
- **Idempotency keys are not scoped or checked.** They are global rather than per user, and reusing a key with a different body silently returns the original transfer.
- **The failure path is a rejection, not a compensation.** Only one step moves money, so nothing needs undoing. A compensating action becomes necessary once a saga has a second money-moving step.
- **No automated tests.** The code type-checks with `tsc --noEmit`, and `demo.ps1` acts as an end-to-end smoke test.

## Ideas - next steps

- Orchestrated saga with an explicit coordinator and persisted saga state
- Notification service as a second consumer of the result events
- Dead-letter queue with retry counts
- CQRS read model for transaction history
- Circuit breaker and timeouts in the gateway
- Registration, deposits, and an interactive CLI