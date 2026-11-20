// Throwaway Worker for issue #16. Every response carries CK16-MARKER so the
// checks can tell "the Worker or an asset answered" from "Access answered".
//
// Routes (anything that isn't a static asset reaches this Worker):
//   /api/ping              plain "pong", for request counting
//   /api/d1/batch?n=N      one D1 batch() of N statements
//   /api/d1/seq?n=N        N separate D1 queries
//   /secret/*              static asset served through the Worker (run_worker_first)
//   anything else          echo: what Access passed to the Worker
//
// Each echo and /secret/ hit is logged to the D1 table `hits`, so browser
// visits can be read back by the wizard without copying anything by hand.

const MARKER = "CK16-MARKER";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/api/ping") return new Response(`pong ${MARKER}\n`);
    if (path.startsWith("/api/d1/")) return d1Check(url, env);

    const seen = observe(request, url);

    if (path === "/secret" || path.startsWith("/secret/")) {
      ctx.waitUntil(logHit(env, seen));
      const asset = await env.ASSETS.fetch(request);
      const response = new Response(asset.body, asset);
      response.headers.set("x-ck16-saw-jwt", seen.jwtHeader ? "yes" : "no");
      return response;
    }

    ctx.waitUntil(logHit(env, seen));
    return Response.json(seen);
  },
};

// observe records which Access artefacts reached the Worker. Cookie values and
// the JWT signature are never stored: only cookie names and a few JWT claims.
function observe(request, url) {
  const jwt = request.headers.get("cf-access-jwt-assertion");
  const cookieNames = (request.headers.get("cookie") || "")
    .split(";")
    .map((c) => c.split("=")[0].trim())
    .filter(Boolean);
  return {
    marker: MARKER,
    path: url.pathname,
    method: request.method,
    tag: url.searchParams.get("tag") || "",
    jwtHeader: Boolean(jwt),
    jwtClaims: jwt ? claims(jwt) : null,
    cookieNames,
    cfAuthorizationCookie: cookieNames.includes("CF_Authorization"),
  };
}

function claims(jwt) {
  try {
    const payload = jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const c = JSON.parse(atob(payload));
    return {
      type: c.type ?? null,
      email: c.email ?? null,
      common_name: c.common_name ?? null,
      aud: c.aud ?? null,
      iss: c.iss ?? null,
    };
  } catch {
    return { error: "could not decode" };
  }
}

async function logHit(env, seen) {
  try {
    await env.DB.prepare(
      "INSERT INTO hits (ts, tag, path, method, jwt_header, jwt_type, jwt_email, cookie_names, cf_auth_cookie) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
    )
      .bind(
        new Date().toISOString(),
        seen.tag,
        seen.path,
        seen.method,
        seen.jwtHeader ? 1 : 0,
        seen.jwtClaims?.type ?? null,
        seen.jwtClaims?.email ?? null,
        seen.cookieNames.join(","),
        seen.cfAuthorizationCookie ? 1 : 0,
      )
      .run();
  } catch {
    // Logging is best effort; the echo response still answers the check.
  }
}

// Check 8: does each statement in batch() count toward the per-invocation
// query limit (50 on Workers Free, 1,000 on Paid)?
async function d1Check(url, env) {
  const mode = url.pathname.split("/")[3];
  const n = Math.max(1, Math.min(5000, Number(url.searchParams.get("n")) || 1));
  const statement = (i) => env.DB.prepare("SELECT ?1 AS i").bind(i);
  try {
    if (mode === "batch") {
      const results = await env.DB.batch(Array.from({ length: n }, (_, i) => statement(i)));
      return Response.json({ marker: MARKER, ok: true, mode, n, statements: results.length });
    }
    if (mode === "seq") {
      for (let i = 0; i < n; i++) await statement(i).first();
      return Response.json({ marker: MARKER, ok: true, mode, n });
    }
    return Response.json({ marker: MARKER, ok: false, error: `unknown mode ${mode}` }, { status: 400 });
  } catch (err) {
    return Response.json(
      { marker: MARKER, ok: false, mode, n, error: String(err?.message || err) },
      { status: 500 },
    );
  }
}
