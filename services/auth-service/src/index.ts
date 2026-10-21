import Fastify from "fastify";
import jwt from "jsonwebtoken";
import pg from "pg";

const JWT_SECRET = process.env.JWT_SECRET ?? "dev-secret-change-me";
const PORT = Number(process.env.PORT ?? 4001);

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

async function waitForDb() {
  for (let attempt = 1; attempt <= 20; attempt++) {
    try {
      await pool.query("select 1");
      return;
    } catch {
      console.log(`auth-service: waiting for postgres (attempt ${attempt})`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error("auth-service: could not connect to postgres");
}

const app = Fastify({ logger: true });

// In a real system this would check a password hash. This is a demo auth
// flow: "log in" as any seeded user by email, no password, to keep focus on
// the microservices patterns rather than auth mechanics.
app.post<{ Body: { email: string } }>("/login", async (req, reply) => {
  const { email } = req.body;
  if (!email) return reply.code(400).send({ error: "email is required" });

  const { rows } = await pool.query("select id, email from users where email = $1", [email]);
  if (rows.length === 0) return reply.code(404).send({ error: "user not found" });

  const user = rows[0];
  const token = jwt.sign({ sub: user.id, email: user.email }, JWT_SECRET, { expiresIn: "1h" });
  return { token, userId: user.id };
});

// Explicit verification endpoint — useful if a service wants to double-check
// a token against the issuing service rather than trusting the shared secret
// locally (the gateway in this project verifies locally for latency reasons).
app.get("/verify", async (req, reply) => {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return reply.code(401).send({ error: "missing bearer token" });

  try {
    const decoded = jwt.verify(header.slice(7), JWT_SECRET);
    return { valid: true, decoded };
  } catch {
    return reply.code(401).send({ valid: false });
  }
});

app.get("/health", async () => ({ status: "ok" }));

await waitForDb();
app.listen({ host: "0.0.0.0", port: PORT }).then(() => {
  console.log(`auth-service listening on ${PORT}`);
});
