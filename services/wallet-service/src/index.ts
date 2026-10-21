import Fastify from "fastify";
import { pool, waitForDb } from "./db.js";
import { startConsumer } from "./consumer.js";
import { startOutboxRelay } from "./outbox.js";

const PORT = Number(process.env.PORT ?? 4003);
const app = Fastify({ logger: true });

app.get<{ Params: { id: string } }>("/wallets/:id", async (req, reply) => {
  const { rows } = await pool.query("select id, owner_id, currency, balance_minor from wallets where id = $1", [
    req.params.id,
  ]);
  if (rows.length === 0) return reply.code(404).send({ error: "wallet not found" });
  return rows[0];
});

app.get<{ Params: { id: string } }>("/wallets/:id/ledger", async (req, reply) => {
  const { rows } = await pool.query(
    "select transfer_id, direction, amount_minor, created_at from ledger_entries where wallet_id = $1 order by created_at desc",
    [req.params.id]
  );
  return rows;
});

app.get("/health", async () => ({ status: "ok" }));

await waitForDb();
await startConsumer();
startOutboxRelay();

app.listen({ host: "0.0.0.0", port: PORT }).then(() => {
  console.log(`wallet-service listening on ${PORT}`);
});
