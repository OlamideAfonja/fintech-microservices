import Fastify from "fastify";
import jwt from "jsonwebtoken";

const PORT = Number(process.env.PORT ?? 4000);
const JWT_SECRET = process.env.JWT_SECRET ?? "dev-secret-change-me";
const AUTH_URL = process.env.AUTH_URL ?? "http://localhost:4001";
const PAYMENTS_URL = process.env.PAYMENTS_URL ?? "http://localhost:4002";
const WALLET_URL = process.env.WALLET_URL ?? "http://localhost:4003";

const app = Fastify({ logger: true });

// The gateway verifies the JWT signature locally with the shared secret
// rather than calling auth-service on every request — that round trip
// would add latency to every single call through the gateway. auth-service
// stays the source of truth for issuing tokens; verification is cheap and
// stateless so it's fine to duplicate here.
app.addHook("preHandler", async (req, reply) => {
  if (req.url === "/auth/login" || req.url === "/health") return;

  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) {
    return reply.code(401).send({ error: "missing bearer token" });
  }
  try {
    (req as any).user = jwt.verify(header.slice(7), JWT_SECRET);
  } catch {
    return reply.code(401).send({ error: "invalid or expired token" });
  }
});

app.post("/auth/login", async (req, reply) => {
  const res = await fetch(`${AUTH_URL}/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(req.body),
  });
  const body = await res.json();
  return reply.code(res.status).send(body);
});

app.post("/transfers", async (req, reply) => {
  const res = await fetch(`${PAYMENTS_URL}/transfers`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "idempotency-key": (req.headers["idempotency-key"] as string) ?? "",
    },
    body: JSON.stringify(req.body),
  });
  const body = await res.json();
  return reply.code(res.status).send(body);
});

app.get<{ Params: { id: string } }>("/transfers/:id", async (req, reply) => {
  const res = await fetch(`${PAYMENTS_URL}/transfers/${req.params.id}`);
  const body = await res.json();
  return reply.code(res.status).send(body);
});

app.get<{ Params: { id: string } }>("/wallets/:id", async (req, reply) => {
  const res = await fetch(`${WALLET_URL}/wallets/${req.params.id}`);
  const body = await res.json();
  return reply.code(res.status).send(body);
});

app.get<{ Params: { id: string } }>("/wallets/:id/ledger", async (req, reply) => {
  const res = await fetch(`${WALLET_URL}/wallets/${req.params.id}/ledger`);
  const body = await res.json();
  return reply.code(res.status).send(body);
});

app.get("/health", async () => ({ status: "ok" }));

app.listen({ host: "0.0.0.0", port: PORT }).then(() => {
  console.log(`api-gateway listening on ${PORT}`);
});
