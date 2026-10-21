import Fastify from "fastify";
import { pool, waitForDb } from "./db.js";
import { startConsumer } from "./consumer.js";
import { startOutboxRelay } from "./outbox.js";
import { EVENT_TYPES, type TransferInitiatedPayload } from "./events.js";

const PORT = Number(process.env.PORT ?? 4002);
const app = Fastify({ logger: true });

interface CreateTransferBody {
  fromWalletId: string;
  toWalletId: string;
  amountMinor: number;
  currency: string;
}

app.post<{ Body: CreateTransferBody }>("/transfers", async (req, reply) => {
  const idempotencyKey = req.headers["idempotency-key"] as string | undefined;
  if (!idempotencyKey) return reply.code(400).send({ error: "Idempotency-Key header is required" });

  const { fromWalletId, toWalletId, amountMinor, currency } = req.body;
  if (!fromWalletId || !toWalletId || !amountMinor || !currency) {
    return reply.code(400).send({ error: "fromWalletId, toWalletId, amountMinor, currency are required" });
  }
  if (amountMinor <= 0) return reply.code(400).send({ error: "amountMinor must be positive" });

  // Idempotency: a client retrying the same request (timeout, network blip)
  // must not create a second transfer. Returning the existing row makes the
  // endpoint safe to call repeatedly with the same key.
  const existing = await pool.query("select * from transfers where idempotency_key = $1", [idempotencyKey]);
  if (existing.rows.length > 0) {
    return reply.code(200).send(toResponse(existing.rows[0]));
  }

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const { rows } = await client.query(
      `insert into transfers (from_wallet_id, to_wallet_id, amount_minor, currency, idempotency_key)
       values ($1, $2, $3, $4, $5) returning *`,
      [fromWalletId, toWalletId, amountMinor, currency, idempotencyKey]
    );
    const transfer = rows[0];

    const payload: TransferInitiatedPayload = {
      eventId: crypto.randomUUID(),
      transferId: transfer.id,
      fromWalletId,
      toWalletId,
      amountMinor,
      currency,
    };
    // Outbox write happens in the SAME transaction as the transfer insert —
    // this is what makes the event delivery reliable. Either both commit or
    // neither does.
    await client.query("insert into outbox (event_type, payload) values ($1, $2)", [
      EVENT_TYPES.TRANSFER_INITIATED,
      JSON.stringify(payload),
    ]);

    await client.query("COMMIT");
    return reply.code(202).send(toResponse(transfer));
  } catch (err) {
    await client.query("ROLLBACK");
    // Unique constraint race: two concurrent requests with the same key.
    if ((err as { code?: string }).code === "23505") {
      const retry = await pool.query("select * from transfers where idempotency_key = $1", [idempotencyKey]);
      return reply.code(200).send(toResponse(retry.rows[0]));
    }
    throw err;
  } finally {
    client.release();
  }
});

app.get<{ Params: { id: string } }>("/transfers/:id", async (req, reply) => {
  const { rows } = await pool.query("select * from transfers where id = $1", [req.params.id]);
  if (rows.length === 0) return reply.code(404).send({ error: "transfer not found" });
  return toResponse(rows[0]);
});

app.get("/health", async () => ({ status: "ok" }));

function toResponse(row: Record<string, unknown>) {
  return {
    id: row.id,
    fromWalletId: row.from_wallet_id,
    toWalletId: row.to_wallet_id,
    amountMinor: row.amount_minor,
    currency: row.currency,
    status: row.status,
    reason: row.reason,
    createdAt: row.created_at,
  };
}

await waitForDb();
await startConsumer();
startOutboxRelay();

app.listen({ host: "0.0.0.0", port: PORT }).then(() => {
  console.log(`payments-service listening on ${PORT}`);
});
