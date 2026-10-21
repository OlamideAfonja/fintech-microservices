import { pool } from "./db.js";
import { EXCHANGE, getChannel } from "./broker.js";

const POLL_INTERVAL_MS = 500;
const BATCH_SIZE = 20;

export function startOutboxRelay() {
  setInterval(relayOnce, POLL_INTERVAL_MS);
}

async function relayOnce() {
  const channel = await getChannel();
  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    // SKIP LOCKED lets multiple relay instances run concurrently without
    // fighting over the same rows — important once you scale this service
    // horizontally.
    const { rows } = await client.query(
      `select id, event_type, payload from outbox
       where published = false
       order by created_at
       limit $1
       for update skip locked`,
      [BATCH_SIZE]
    );

    for (const row of rows) {
      channel.publish(EXCHANGE, row.event_type, Buffer.from(JSON.stringify(row.payload)), {
        persistent: true,
      });
      await client.query("update outbox set published = true where id = $1", [row.id]);
    }

    await client.query("COMMIT");
  } catch (err) {
    await client.query("ROLLBACK");
    console.error("payments-service: outbox relay error", err);
  } finally {
    client.release();
  }
}
