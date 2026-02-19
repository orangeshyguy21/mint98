import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { spawn, execFile, ChildProcess } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = 3999;
const SCRIPT = join(__dirname, "mint-activity-sim.sh");

let simProcess: ChildProcess | null = null;
const sseClients: Set<ServerResponse> = new Set();

// ---- Helpers ---------------------------------------------------------------

function broadcast(data: string) {
  for (const res of sseClients) {
    res.write(`data: ${JSON.stringify(data)}\n\n`);
  }
}

function broadcastStatus() {
  const running = simProcess !== null;
  for (const res of sseClients) {
    res.write(`event: status\ndata: ${JSON.stringify({ running })}\n\n`);
  }
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => resolve(body));
  });
}

function buildEnv(params: Record<string, any>): Record<string, string> {
  return {
    ...(process.env as Record<string, string>),
    MINT_URL: params.mintUrl,
    UNIT: params.unit,
    MIN_AMOUNT: String(params.minAmount),
    MAX_AMOUNT: String(params.maxAmount),
    MIN_DELAY: String(params.minDelay),
    MAX_DELAY: String(params.maxDelay),
    MIN_BALANCE_FOR_SPEND: String(params.minBalance),
    FUNDING_NODE: params.fundingNode,
    INVOICE_NODE: params.invoiceNode,
    BACKUP_NODE: params.backupNode,
  };
}

/** Run the script with a subcommand and stream output to SSE. Returns exit code. */
function runScriptOp(
  env: Record<string, string>,
  args: string[],
): Promise<number> {
  return new Promise((resolve) => {
    const proc = spawn("bash", [SCRIPT, ...args], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    proc.stdout?.on("data", (chunk: Buffer) => {
      for (const line of chunk.toString().split("\n").filter(Boolean)) {
        broadcast(line);
      }
    });
    proc.stderr?.on("data", (chunk: Buffer) => {
      for (const line of chunk.toString().split("\n").filter(Boolean)) {
        broadcast(`[stderr] ${line}`);
      }
    });
    proc.on("close", (code) => resolve(code ?? 1));
  });
}

// ---- Route Handlers --------------------------------------------------------

async function handleStart(req: IncomingMessage, res: ServerResponse) {
  const body = await readBody(req);
  if (simProcess) {
    res.writeHead(409, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Already running" }));
    return;
  }

  const params = JSON.parse(body);
  const env = buildEnv(params);

  broadcast(`--- Starting simulator: ${params.mintUrl}  unit=${params.unit} ---`);

  simProcess = spawn("bash", [SCRIPT], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  simProcess.stdout?.on("data", (chunk: Buffer) => {
    for (const line of chunk.toString().split("\n").filter(Boolean)) {
      broadcast(line);
    }
  });

  simProcess.stderr?.on("data", (chunk: Buffer) => {
    for (const line of chunk.toString().split("\n").filter(Boolean)) {
      broadcast(`[stderr] ${line}`);
    }
  });

  simProcess.on("close", (code) => {
    broadcast(`--- Simulator exited (code ${code}) ---`);
    simProcess = null;
    broadcastStatus();
  });

  broadcastStatus();
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));
}

function handleStop(_req: IncomingMessage, res: ServerResponse) {
  if (!simProcess) {
    res.writeHead(409, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Not running" }));
    return;
  }
  broadcast("--- Sending SIGTERM... ---");
  simProcess.kill("SIGTERM");
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));
}

function handleSSE(_req: IncomingMessage, res: ServerResponse) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });
  res.write(`data: ${JSON.stringify("Connected to server")}\n\n`);
  sseClients.add(res);
  res.on("close", () => sseClients.delete(res));
}

function handleStatus(_req: IncomingMessage, res: ServerResponse) {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ running: simProcess !== null }));
}

/**
 * Run `cdk-cli balance` once and parse per-mint balances.
 * Output format: "0: http://localhost:5551 47435 sat"
 */
async function handleBalance(req: IncomingMessage, res: ServerResponse) {
  const body = await readBody(req);
  const params = JSON.parse(body);
  const mintUrls: string[] = params.mintUrls ?? [params.mintUrl];

  const cdkCli =
    process.env.CDK_CLI ??
    join(process.env.HOME ?? "", "Sites/cdk/target/release/cdk-cli");

  const results: Record<string, string> = {};
  // Pre-fill all requested mints with "0" so missing ones show 0
  for (const url of mintUrls) results[url] = "0";

  await new Promise<void>((resolve) => {
    execFile(cdkCli, ["balance"], (err, stdout) => {
      if (!err && stdout) {
        // Parse lines like: "0: http://localhost:5551 47435 sat"
        for (const line of stdout.split("\n")) {
          const match = line.match(/^\d+:\s+(\S+)\s+(\d+)\s+(\S+)/);
          if (match) {
            const [, url, bal, unit] = match;
            if (url in results) {
              results[url] = `${bal} ${unit}`;
            }
          }
        }
      }
      resolve();
    });
  });

  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(results));
}

/** Run a manual one-shot operation (mint, melt, swap). */
async function handleManualOp(req: IncomingMessage, res: ServerResponse) {
  const body = await readBody(req);
  const params = JSON.parse(body);
  const op: string = params.op; // "mint" | "melt" | "swap"
  const amount: number = params.amount;
  const env = buildEnv(params);

  broadcast(`--- Manual ${op}: ${amount} ${params.unit} on ${params.mintUrl} ---`);

  const code = await runScriptOp(env, [op, String(amount)]);

  broadcast(`--- Manual ${op} finished (exit ${code}) ---`);

  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: code === 0, exitCode: code }));
}

// ---- Server ----------------------------------------------------------------

const server = createServer(async (req, res) => {
  const url = req.url ?? "/";

  if (url === "/" && req.method === "GET") {
    const html = await readFile(join(__dirname, "index.html"), "utf-8");
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(html);
  } else if (url === "/start" && req.method === "POST") {
    handleStart(req, res);
  } else if (url === "/stop" && req.method === "POST") {
    handleStop(req, res);
  } else if (url === "/events" && req.method === "GET") {
    handleSSE(req, res);
  } else if (url === "/status" && req.method === "GET") {
    handleStatus(req, res);
  } else if (url === "/balance" && req.method === "POST") {
    handleBalance(req, res);
  } else if (url === "/manual" && req.method === "POST") {
    handleManualOp(req, res);
  } else {
    res.writeHead(404);
    res.end("Not found");
  }
});

server.listen(PORT, () => {
  console.log(`Mint Sim GUI → http://localhost:${PORT}`);
});
