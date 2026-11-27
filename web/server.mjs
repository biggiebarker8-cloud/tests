import { createServer as createHTTPServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const publicDirectory = resolve(fileURLToPath(new URL("./public/", import.meta.url)));
const maxBodyBytes = 42 * 1024 * 1024;
const allowedRoles = new Set(["user", "assistant"]);

function json(response, status, value) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBodyBytes) {
      throw Object.assign(new Error("Request body is too large."), { status: 413 });
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw Object.assign(new Error("Request body must be valid JSON."), { status: 400 });
  }
}

function validateMessages(messages) {
  if (!Array.isArray(messages) || messages.length < 1 || messages.length > 100) {
    return false;
  }

  return messages.some((message) => message?.role === "user")
    && messages.every((message) => {
      if (!message || !allowedRoles.has(message.role)) return false;
      if (typeof message.content === "string") return message.content.length <= 20_000;
      if (!Array.isArray(message.content) || message.content.length > 7) return false;
      return message.content.every((part) => {
        if (part?.type === "text") return typeof part.text === "string" && part.text.length <= 20_000;
        if (part?.type !== "image_url") return false;
        const url = part.image_url?.url;
        return typeof url === "string"
          && /^data:image\/(?:jpeg|png|gif|webp);base64,[A-Za-z0-9+/=]+$/i.test(url);
      });
    });
}

function responseText(payload) {
  if (typeof payload?.reply === "string") return payload.reply.trim();
  const content = payload?.choices?.[0]?.message?.content;
  if (typeof content === "string") return content.trim();
  if (Array.isArray(content)) {
    return content
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text)
      .join("")
      .trim();
  }
  return "";
}

export function createAppServer({ endpoint, apiKey, model = "lark-consultant-v1" } = {}) {
  const handler = async (request, response) => {
    const url = new URL(request.url, "http://localhost");

    if (request.method === "GET" && url.pathname === "/api/config") {
      return json(response, 200, { configured: Boolean(endpoint && apiKey?.trim()) });
    }

    if (request.method === "POST" && url.pathname === "/api/chat") {
      if (!endpoint || !apiKey?.trim()) {
        return json(response, 503, { error: "Live chat is not configured on this server." });
      }

      let payload;
      try {
        payload = await readJSON(request);
      } catch (error) {
        return json(response, error.status ?? 400, { error: error.message });
      }
      if (!validateMessages(payload?.messages)) {
        return json(response, 400, { error: "Messages are missing or have an unsupported format." });
      }

      try {
        const upstream = await fetch(endpoint, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify({ model, messages: payload.messages }),
          signal: AbortSignal.timeout(60_000),
        });
        if (!upstream.ok) {
          return json(response, 502, { error: `AI service returned HTTP ${upstream.status}.` });
        }
        const text = responseText(await upstream.json());
        if (!text) return json(response, 502, { error: "AI service returned an empty or unsupported response." });
        return json(response, 200, { reply: text });
      } catch (error) {
        const message = error.name === "TimeoutError"
          ? "AI service request timed out."
          : "Could not reach the AI service or read its response.";
        return json(response, 502, { error: message });
      }
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return json(response, 405, { error: "Method not allowed." });
    }

    const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
    const filename = resolve(publicDirectory, `.${pathname}`);
    if (!filename.startsWith(`${publicDirectory}/`)) {
      return json(response, 404, { error: "Not found." });
    }
    try {
      const data = await readFile(filename);
      const contentTypes = {
        ".html": "text/html; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
      };
      response.writeHead(200, {
        "content-type": contentTypes[extname(filename)] ?? "application/octet-stream",
        "x-content-type-options": "nosniff",
        "content-security-policy": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
      });
      return response.end(request.method === "HEAD" ? undefined : data);
    } catch {
      return json(response, 404, { error: "Not found." });
    }
  };

  return createHTTPServer((request, response) => {
    handler(request, response).catch(() => {
      if (!response.headersSent) json(response, 500, { error: "Unexpected server error." });
      else response.destroy();
    });
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = createAppServer({
    endpoint: process.env.LARK_AI_ENDPOINT,
    apiKey: process.env.LARK_AI_API_KEY,
    model: process.env.LARK_AI_MODEL || "lark-consultant-v1",
  });
  const port = Number(process.env.PORT || 4173);
  const host = process.env.HOST || "127.0.0.1";
  server.listen(port, host, () => {
    console.log(`Lark AI Consultant browser app listening on port ${port}`);
  });
}
