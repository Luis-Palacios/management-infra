# Deployment Roadmap

Working doc for deploying `staff-app` (Next.js), `auth-server` (better-auth/Hono) and
`membership-applications` (FastAPI) to AWS. The goals are to learn AWS step by step, to run
something real for the church (~20 users), and to end up with something worth showing in
interviews. As in the other roadmaps, each phase is a learning step. Do the manual (console)
version first, then automate it. Pick up at whichever phase is still marked `[ ]`.

Status markers: `[ ]` not started, `[~]` in progress, `[x]` done.

Started: 2026-09-21

---

## Where we left off (2026-10-08)

**Phases 0 and 1 are done and merged to `main` in every repo.** **Phase 2: auth-server
([PR #18](https://github.com/Luis-Palacios/auth-server/pull/18)) and membership-applications
([PR #20](https://github.com/Luis-Palacios/membership-applications/pull/20)) are done and merged.**
staff-app's groundwork is merged: line endings
([PR #30](https://github.com/Luis-Palacios/staff-app/pull/30)), lockfile + pnpm pin
([PR #31](https://github.com/Luis-Palacios/staff-app/pull/31)) and `.dockerignore`
([PR #32](https://github.com/Luis-Palacios/staff-app/pull/32)). Old local `deploy/*`, `docs/*` and
`feature/*` branches in the other repos were rebase-merged, so git still lists them as unmerged;
they can be deleted.

**Next session starts here: the staff-app Dockerfile** (see the staff-app item in Phase 2, and
auth-server's Dockerfile for the pnpm pattern). Same way of working: Claude explains, the owner
writes (or asks Claude to, with a preview of each change first), Claude reviews and tests from the
image.

State of branches:
- **management-infra `docs/phase-2-staff-app`**: this roadmap's updates.
- **Windows clone of staff-app:** before pulling `main`, delete any untracked local
  `pnpm-lock.yaml`, or the pull refuses to overwrite it.
- **Line endings:** auth-server and membership-applications enforce LF with `.gitattributes` (what
  Git stores) **and** `.editorconfig` (what the editor creates; needs `root = true` and a `[*]`
  section, or it's silently ignored). staff-app now has both as well (PR #30, 16 files renormalized).
  Lesson: VS Code on Windows creates CRLF files by default. In auth-server, the Biome VS Code
  extension shows only lint diagnostics, never formatting differences, so CRLF showed up only in
  `biome check` on the CLI. In staff-app (ESLint + Prettier), `.prettierrc` had
  `"endOfLine": "auto"`, which keeps whatever ending a file has, so CRLF was never flagged; it's now
  `"lf"`. After pulling a renormalize commit on another clone, refresh the working tree with
  `git rm --cached -r -q . ; git reset --hard` (no uncommitted work).
- **staff-app** line endings, merged in [PR #30](https://github.com/Luis-Palacios/staff-app/pull/30):
  `c373443` config, `4dff435` renormalize. `prettier --check .` still flags 10 files with existing
  formatting differences (no CRs). Fix them in their own commit some time; not blocking.

Follow-ups noted along the way (not blocking):
- **membership-applications `ruff.toml` `target-version = "py310"`** should be `py314`. Changing it
  gives 39 lint errors, mostly `TC001-003` (Python 3.14's lazy annotations make ruff want imports
  under `TYPE_CHECKING`). Don't blindly `--fix`: pydantic models and FastAPI dependencies need those
  types at runtime. Configure `lint.flake8-type-checking.runtime-evaluated-base-classes` first.
- **membership-applications `uvloop`/`httptools`:** add them when routes go async (async Postgres),
  and set `loop="uvloop"`, `http="httptools"` explicitly in `run.py`, so a missing package fails at
  startup instead of silently falling back to asyncio (uvicorn's default is `"auto"`).
- **membership-applications one `DEBUG` flag** controls tracebacks, log level and SQL echo (with
  bound parameters). Split into `LOG_LEVEL` and an opt-in SQL echo (`hide_parameters=True`) when
  structured logging arrives (Phase 9).

Useful checks:
- **How to check the build context:** build a throwaway image whose Dockerfile is
  `FROM busybox`, `COPY . /ctx`, `RUN find /ctx -type f`, using
  `docker build --no-cache --progress=plain -f <that file> <repo>`. It lists exactly what the
  `.dockerignore` lets through. Use it for the other two repos too.
- **How to run the image against local Postgres** (container `my-postgres`, port 5432): replace
  `localhost` with `host.docker.internal` in `DATABASE_URL`, e.g.
  `docker run --rm -e DATABASE_URL=postgresql://user:pass@host.docker.internal:5432/db auth-server:dev node dist/migrate.js`.
  For a throwaway DB: `docker exec my-postgres psql -U <user> -d postgres -c "create database x"`.

**How we work (read this at every session start):** the main goal is for the owner to learn, not
just to ship, so go slowly.
- **Explain every decision:** what the options are, which one is standard in industry, and why this
  one was picked.
- **One change at a time.** Show each code change before it is applied. The owner decides: they
  implement it and Claude reviews it, or Claude implements it. Then move on to the next item.
- **Ask questions** whenever something is unclear. Don't guess what the owner wants.
- **Challenge the owner and don't sugar-coat.** Question every decision, including the owner's own
  and ones already written in this doc. Don't take the owner's claims on trust; verify them. Say
  plainly when something is wrong.
- Prefer industry-standard production patterns over the minimum for ~20 users, and design for the
  API and auth-server possibly going public later (mobile app).
- The owner switches between Windows (PowerShell 7) and macOS (zsh). Ask which machine they're on,
  or give commands that work in both (single-line, or a script file), not multi-line bash only.

**Local setup still needed after this session's changes:**
- `auth-server/.env`: add a bare `TRUSTED_PROXIES=` line. It is now required to be *present*
  (empty is allowed), and auth-server won't start without it.
- `membership-applications/.env`: needs `JWT_ISSUER` and `JWT_AUDIENCE` (both `http://localhost:5000`
  locally, same as `AUTH_SERVER_URL`). Already done and verified. `RATE_LIMIT_STORAGE_URI` is
  optional (defaults to `memory://`).
- `auth-server/.env`: `CORS_ORIGINS=http://localhost:3000,http://localhost:8000` became
  `TRUSTED_ORIGINS=http://localhost:3000` plus an empty `CORS_ORIGINS=`. Without `TRUSTED_ORIGINS`,
  sign-in from staff-app gets `403 INVALID_ORIGIN`. `membership-applications/.env`:
  `CORS_ALLOWED_ORIGINS=` (empty). Both are already done on this machine.

**Decisions and findings from Phase 1 so far (details are in the items below):**
- Listen `PORT` and public `BETTER_AUTH_URL` are separate variables in auth-server.
- membership-applications validates `iss`/`aud` from `JWT_ISSUER`/`JWT_AUDIENCE` (public URL) and
  fetches keys from `AUTH_SERVER_URL` (internal address).
- Rate limiting in membership-applications is now per user on the verified JWT `sub`, built directly
  on the `limits` library in a FastAPI dependency (not slowapi). Storage is swappable to Redis through
  `RATE_LIMIT_STORAGE_URI`; needed once there is more than one worker or replica. The anonymous per-IP
  layer is deliberately left to Cloudflare/WAF (Phase 8.5) and must be revisited before exposing the
  API publicly. This was smoke-tested end to end with a real token: ten `200`s, then `429` with
  `Retry-After`.
- auth-server's `TRUST_PROXY` boolean was replaced by `TRUSTED_PROXIES` (IPs/CIDRs). Behind an ALB
  the forwarded header holds several addresses, which better-auth cannot resolve without a trusted
  list. **Remember to set it in the auth-server task definition (Phase 8: the VPC CIDR; Phase 8.5:
  add Cloudflare's ranges).** Forgetting it gives no error, only one shared sign-in rate-limit
  bucket for all users, apart from a startup warning under `NODE_ENV=production`.

---

## Decisions made

| Decision | Choice | Why |
|---|---|---|
| Where cross-repo files live | This repo (`infra`): compose, IaC, this plan | Each app repo keeps only its own `Dockerfile` + CI workflow |
| Environments | **prod only** for now; staging later if wanted | Budget |
| Budget target | ~$30–60/mo (see [Cost](#cost-estimate): realistic is closer to $65–80) | |
| Compute | ECS on Fargate | Common in job postings, no servers to patch |
| Auth DB | RDS PostgreSQL, single-AZ `db.t4g.micro` | |
| Church DB | Existing Azure SQL; a **dev/test copy exists** for local + testing | |
| Deploy order | Manual console first → GitHub Actions → rebuild everything in IaC | Learn each piece before automating it |
| IaC tool | **Terraform CLI (HCL)**, pinned version (see [Phase 11](#phase-11--infrastructure-as-code)) | Shows up most in job postings; most tutorials and docs use it |
| Domain / DNS | Existing domain, **DNS stays on Cloudflare** (no Route 53) | Already set up; Resend's sending domain is already verified there |
| AWS region | **`us-east-2` (Ohio)** (see below) | Close to Azure SQL in South Central US (Texas) |
| Azure SQL firewall | You (subscription owner) add the NAT Elastic IP rule | |
| Profile icons (S3) | Owned by **auth-server** | It already stores the user's `image` field |
| Cloudflare proxy | **DNS-only at launch, then proxy on** in [Phase 8.5](#phase-85--cloudflare-proxy-orange-cloud) | Debug one layer at a time; then free DDoS/WAF in front of a public login page |

### Region choice

Azure South Central US is in Texas. AWS has no full region in Texas (Dallas is only a Local
Zone). The two candidates are `us-east-2` (Ohio) and `us-east-1` (N. Virginia). Both are about
the same distance from Texas, and prices are the same for everything used here. Prefer
**`us-east-2`**: `us-east-1` is AWS's oldest and busiest region and has had the most big
outages. Once the VPC exists, measure the real latency to Azure SQL from a task, for example
with `/health` timings. If it's surprisingly high, it's still easy to switch before Phase 11.

## Open decisions

None right now.

---

## Target architecture

```
                      Internet
                         │  HTTPS (ACM cert)
       Cloudflare DNS (CNAME) ─► ALB  (public subnets)
                         │
            ┌────────────▼─────────────┐           private subnets
            │ staff-app  (Fargate)     │  BFF: the only public service
            └──┬──────────────────┬────┘
   /api/auth/* │ proxy            │ Bearer JWT
               ▼                  ▼
   ┌──────────────────┐   ┌───────────────────────────┐
   │ auth-server      │◄──│ membership-applications   │  (JWKS fetch)
   │ (Fargate)        │   │ (Fargate)                 │
   └───┬──────────┬───┘   └────────────┬──────────────┘
       │          │ Resend API         │
       ▼          ▼                    ▼
  RDS Postgres   NAT (Elastic IP) ───► Azure SQL (firewall allowlists the EIP)
```

Why it's shaped this way:

- **Only staff-app is public.** The browser reaches auth-server through staff-app's existing
  `/api/auth/*` proxy, so auth-server and membership-applications need no public endpoint.
  Security groups allow only staff-app → auth-server/membership, and auth-server → RDS.
- **`BETTER_AUTH_URL` = staff-app's public URL** (e.g. `https://staff.example.org`). Cookies,
  email verification links and reset links all go through the proxy. This requires the
  code fixes in Phase 1.
- **Services talk to each other through ECS Service Connect** (e.g.
  `http://auth-server:5000`), not through the ALB.
- **NAT with a static Elastic IP**: Azure SQL's firewall needs a fixed source IP. Fargate tasks
  get random IPs, so all egress goes through NAT. NAT Gateway is ~$33/mo plus data. A
  [`fck-nat`](https://fck-nat.dev) `t4g.nano` instance is ~$3–4/mo. Use fck-nat.

---

## Phase 0 — AWS account & guardrails
`[x]`

Do this first, even before Docker. It's quick, and it's what keeps a surprise bill from happening.

- [x] Create the account. Turn on **MFA for root**, then stop using root. (**Have to keep using root, see note on next item**)
- [ ] Enable **IAM Identity Center**. Create your own admin user and sign in with it. (**If I do this an AWS Organization is created and the free credits expire**)
- [x] Install AWS CLI v2 and run `aws configure sso` (short-lived credentials, no access keys on disk). (**Had to to run aws login instead**)
- [x] **AWS Budgets**: alerts at $20, $50 and $80 (actual and forecasted).
- [x] Enable **Cost Anomaly Detection**. Check what free-tier credits the new account got.
- [x] Set the default region to `us-east-2` (CLI profile + console) and create everything there.

Note: Ended up creating a new account via the new experience so now I have a AWS Builder ID  
**New concepts:** root vs IAM identities, SSO/short-lived credentials, the billing console.

---

## Phase 1 — Code changes needed before deployment
`[x]`

Found while reviewing the repos. Each one works on localhost but breaks behind an ALB or
Service Connect.

- [x] **auth-server: listen port is derived from `BETTER_AUTH_URL`** (`src/lib/config.ts:62`).
      In prod that URL is `https://staff.example.org`, so it would try to listen on 443. Add a
      separate `PORT` env var (default 5000) and keep `BETTER_AUTH_URL` only as the public URL.
- [x] **membership-applications: `AUTH_SERVER_URL` is used for both the JWKS fetch and `iss`/`aud`**
      (`api/jwt_auth.py:17,43-44`). In AWS the fetch URL is internal (`http://auth-server:5000`)
      but the issuer is the public URL, so every token would fail validation. Split it into
      `AUTH_SERVER_URL` (fetch) and `JWT_ISSUER`/`JWT_AUDIENCE` (validation).
- [x] **Rate limiters will treat all users as one client.** Behind the BFF, every request comes
      from staff-app's IP:
  - [x] membership-applications' `slowapi` used `get_remote_address`, so 60/min would be shared by
    *everyone*. Replaced by a per-user limiter on the verified JWT `sub` (`limits` library in a
    FastAPI dependency, storage swappable to Redis via `RATE_LIMIT_STORAGE_URI`). The per-IP layer for
    anonymous traffic is left to Cloudflare (Phase 8.5); revisit before exposing the API publicly.
  - [x] auth-server with `TRUST_PROXY=false` would see staff-app's IP too, so better-auth's
    sign-in limit (3 per 10s) would become global. **Verified, and the original plan
    (`TRUST_PROXY=true`) was not enough:** Next's rewrite forwards `X-Forwarded-For` untouched (it
    adds nothing), so auth-server gets whatever the ALB produced, and better-auth treats a
    multi-address header as unresolvable unless told which hops are trusted (everyone then shares
    one `no-trusted-ip` bucket). Replaced the boolean with `TRUSTED_PROXIES` (comma-separated
    IPs/CIDRs, validated at startup, passed to better-auth's `advanced.ipAddress.trustedProxies`,
    which reads the header right to left and skips trusted hops). The variable is required (startup
    fails if it's absent; an empty value is allowed and means "no proxy", with a startup warning under
    `NODE_ENV=production`). **Set it in the auth-server task definition (Phase 8):** the VPC CIDR;
    Phase 8.5 adds Cloudflare's ranges.
- [x] **staff-app: `NEXT_PUBLIC_AUTH_SERVER_URL` is now only used server-side.** Renamed to a
      server-only `AUTH_SERVER_URL` in `lib/env/server.ts` (a module marked `server-only`). Its value
      must be a bare `http(s)` origin, because `proxy.ts` (`new URL(absolutePath, base)`) drops a
      base path, while `apiFetch`'s `joinUrl` keeps it. **Local setup:** rename the variable in
      `staff-app/.env.local`.
- [x] **Env validation runs lazily (verified 2026-09-28):** an invalid `AUTH_SERVER_URL` only crashes
      on the first request that goes through the middleware, not when the server boots. `/api/health`
      is outside the matcher, so an ECS task would pass its health check and the circuit breaker
      would miss the bad config. Plan: validate at boot in `instrumentation.ts` `register()`.
      Importing the env module in `next.config.mjs` (the t3-env pattern) was rejected, because it
      validates at build time and breaks "build once, deploy anywhere".
      **Verified:** under `next start`, `register()` is lazy too. `Ready` is logged before anything
      loads, and `prepare()` (which calls `register()`) only runs on the first request
      (`next.js:182`, `base-server.js:467`). With `instrumentation.ts` importing the env module, a
      bad value makes *every* request return 500, including routes outside the middleware (tested:
      `/api/nothing` gave `500, 500`), while the process keeps running. `server-only` works in the
      instrumentation bundle. So the ALB health check will fail and the circuit breaker can catch
      it. `/api/health` must be a dynamic Next route (not a static file) for this to hold.
      **Decision: no `instrumentation.ts`.** `/api/health` imports the env module itself, so an
      invalid config fails the ALB health check (a *readiness* check) and the ALB never sends
      traffic to that task. This is explicit and doesn't depend on Next's lazy `prepare()`. The
      trade-off is a weaker ECS signal ("failed ELB health checks" rather than "container exited").
      Rule: **any new config module must be imported by `/api/health`**. Rejected alternatives:
      `register()` + `process.exit(1)` (depends on Next internals), and a preflight script in the
      Docker `CMD` (the only truly boot-time option, but it duplicates the TS schema; can revisit in
      Phase 2).
- [x] **staff-app: `rewrites()` in `next.config.mjs` is evaluated at build time** (it ends up in
      the routes manifest). **Verified (2026-09-28):** built with the URL set to
      `http://baked-at-build.invalid:5000` (it showed up in `.next/routes-manifest.json`), then ran
      `next start` with a different URL. The proxy still tried `baked-at-build.invalid`
      (`ENOTFOUND`), so the env var at start is ignored. The `NEXT_PUBLIC_` prefix is not the
      cause: `next.config.mjs` isn't bundled, and `next build` calls `rewrites()` once and writes the
      result as data. So the auth-server URL is baked into the image.
      **Fixed:** the rewrite was replaced by a middleware rewrite in `proxy.ts`, which goes first and
      skips the session logic, with the matcher `/api/auth/:path+`. It ends in the same
      `proxyRequest()` as config rewrites. A build with an `.invalid` URL, run against a local echo
      server, showed the URL is read at runtime, the query string and cookies are forwarded,
      `X-Forwarded-For` arrives untouched, and both `Set-Cookie`s come back. A route handler that
      reimplements the proxy was rejected (hand-written auth proxy, and `X-Forwarded-For` would have
      to be rebuilt by hand). That's
      acceptable with prod only (pass it as a build arg), but the cleaner fix is a runtime route
      handler `app/api/auth/[...all]/route.ts` that proxies using the env var at request time.
- [x] **staff-app: add `output: "standalone"`** (small image, no `node_modules` copy) and a
      `/api/health` route for the ALB target group. **Done** (staff-app `c4cebe9`, `fde6318`,
      branch `deploy/runtime-auth-proxy`). Verified with `node .next/standalone/server.js`:
      - The output is ~23 MB, has no `.env*` files, and gets config only from real env vars. With
        a variable missing, `/api/health` returned 500 on its own.
      - `public/` and `.next/static/` are **not** included. Without them, CSS returned 404 while
        `/api/health` returned 200, so the health check can't catch this (see Phase 2).
      - `server.js` reads `PORT` and `HOSTNAME`. In Docker, set `HOSTNAME=0.0.0.0` (Docker sets
        `HOSTNAME` to the container name).
      - `pnpm start` (`next start`) is kept for quick local runs and prints a warning under
        standalone. **Test production behaviour with compose (Phase 3), not with `pnpm start`.**

      The `/api/health` route must be dynamic and must import
      `lib/env/server` (see the env validation item above). **Decided: shallow check, no call to
      auth-server.** If staff-app's check depended on auth-server, a short auth-server outage would
      make every staff-app task unhealthy. ECS would restart them in a loop (a cascading failure
      that outlasts the original one), a good staff-app deploy could be rolled back, and the ALB
      fails open when all targets are unhealthy anyway. Dependency outages belong to monitoring
      (Phase 9).
- [x] **auth-server: add `build` + `start` scripts.** The source uses `.js` import specifiers
      for `.ts` files, so it needs `tsc` → `dist/` and then `node dist/index.js`.
      **Done** (auth-server `e1ce659`, branch `deploy/build-scripts`). Findings and decisions:
      - The server had only ever run under **Bun**, while prod is Node 24. Verified that the `tsc`
        output runs on Node (all imports resolve, `/api/auth/ok` gives 200, `/health` gives 503
        with the DB down). **Bun is dropped entirely:** `pnpm dev` is `tsx watch` (Node), so dev
        runs on the prod runtime.
      - **`tsc`, not a bundler:** it's already the type-checker, the output maps 1:1 to the
        source, and a server ships `node_modules` anyway. Node's built-in type stripping was
        rejected (needs `.ts` import specifiers); `tsx`/`bun` in prod is not standard.
      - A plain `tsc` emit put output in `dist/src/` (the base tsconfig also includes
        `drizzle.config.ts`). A separate `tsconfig.build.json` sets `rootDir: src`,
        `outDir: dist` and turns off declaration files (those are for libraries). The base
        `tsconfig.json` stays for the editor and `pnpm typecheck`.
      - `start` is `node --enable-source-maps dist/index.js`, so stack traces in CloudWatch point
        at `.ts` lines. Verified.
      - Biome now reuses `.gitignore` (skips `dist/`) and ignores drizzle's generated snapshots.
        `biome check .` had already been failing on formatting, so that got fixed in a separate
        formatting-only commit. It still warns about the `!` in `drizzle.config.ts`.
      - `src/data/seed.ts` was deleted. It inserted a `user` row without an `account` row (where
        better-auth keeps the password hash), so that user could never sign in. The first admin
        is created with `pnpm dlx auth@latest create-admin` (Phase 6).
      - Known gap: `tsc` never deletes stale files from `dist/`. Docker builds start clean, so
        only local builds are affected.
- [x] **auth-server: load `.env` only in dev.** `src/lib/config.ts` did `import 'dotenv/config'`,
      so the prod code would load a `.env` if one were ever present in the image. **Done**
      (auth-server `cd2445f`, `364e08e`, branch `deploy/node-env-file`). Findings and decisions:
      - The `dev` script is now `tsx watch --env-file-if-exists=.env src/index.ts` (Node's built-in
        parser, which dotenv's own README now recommends). Verified: `tsx watch` passes the flag
        through, and a variable set in the shell beats the file (`PORT=5055` won over `.env`).
        Strict `--env-file` was rejected: the zod schema already reports missing variables, and
        the strict flag would break dev runs with only real env vars (compose).
      - **Verified that prod ignores `.env`:** `pnpm start` with `.env` sitting next to it fails
        config validation. "Prod config comes only from real env vars" is now enforced by the
        code, not just by `.dockerignore`.
      - `drizzle.config.ts` uses `process.loadEnvFile('.env')`, guarded by `existsSync` (it throws
        `ENOENT` otherwise). drizzle-kit loads the config itself, so the dev script's flag
        doesn't reach it. Verified with `drizzle-kit check` and `migrate`. In the Phase 2 migrate
        container there is no `.env`, so real env vars are used. `dotenv` is removed completely.
        Wrapping drizzle-kit in `node --env-file-if-exists` was rejected (it depends on the
        package's internal `bin.cjs` path).
      - `.env` is read once at startup, as it was with dotenv: restart `pnpm dev` after editing it.
- [x] **auth-server: graceful shutdown** (its own ROADMAP Phase 6). ECS sends SIGTERM on every
      deploy, so finish this before prod. **Done** (auth-server `e8aa9ea`, branch
      `deploy/graceful-shutdown`; details are in auth-server's ROADMAP Phase 6). On a signal it
      runs `server.close()`, then `pool.end()`, and exits `0`. The hard deadline is
      `SHUTDOWN_TIMEOUT_MS` (default 20s), after which it exits `1`.
      - **Found by testing:** a keep-alive socket that is busy when shutdown starts keeps
        `server.close()` waiting for `keepAliveTimeout` after its response. With keep-alive above
        the proxy's idle timeout, that runs past the grace period into `SIGKILL`. Fixed by sending
        `Connection: close` on every response during shutdown.
      - Tested in Docker with real signals and node as PID 1: in-flight requests complete, new
        connections are refused, and the deadline and double-signal paths exit `1`. A terminal
        Ctrl+C under `tsx watch` (a process-group SIGINT) shuts down once. Testing gotcha: on
        Docker Desktop the *host* port still accepts TCP after the app stops listening (Docker's
        proxy does it). Probe from inside the container instead.
      - Not tested on Windows: a native Ctrl+C under `pnpm dev`.
      - Follow-ups are in Phase 2 (`CMD`), Phase 3 (`stop_grace_period`) and Phase 8 (`stopTimeout`,
        Service Connect draining).
- [x] **Production CORS.** The original plan was to set auth-server's `CORS_ORIGINS` to the staff
      public URL. **Replaced** (auth-server `feee555`, branch `deploy/split-origins`;
      membership-applications `3afdab2`, branch `deploy/cors-opt-in`). Findings:
      - `CORS_ORIGINS` fed two different controls: `hono/cors`, and better-auth's `trustedOrigins`
        (CSRF on the `Origin` header plus redirect-target checks). **CORS was dead config**: no
        browser calls auth-server or membership-applications cross-origin, locally or in prod.
        `http://localhost:8000` in the list did nothing.
      - better-auth **always trusts its base URL's origin** (`context/helpers.mjs:74`, v1.7.2). In
        prod that's the staff URL, so no extra trusted origins are needed.
      - A mobile app would need `trustedOrigins` (its app scheme) but never CORS, which is a
        browser-only mechanism. So the two controls are split.
      - auth-server: optional `TRUSTED_ORIGINS` (to better-auth) and optional `CORS_ORIGINS`.
        **Empty `CORS_ORIGINS` means the middleware isn't mounted**, and entries must be bare
        origins (validated at startup). `baseURL` is now passed explicitly, so better-auth no
        longer reads `process.env.BETTER_AUTH_URL` itself.
      - membership-applications: `CORSMiddleware` is mounted only when `CORS_ALLOWED_ORIGINS` is
        non-empty.
      - **Prod values: all three empty** (auth-server `TRUSTED_ORIGINS` and `CORS_ORIGINS`,
        membership-applications `CORS_ALLOWED_ORIGINS`).
      - Verified locally:
        - Staff and base-URL origins pass the CSRF check; a foreign origin gets
          `403 INVALID_ORIGIN`.
        - With `TRUSTED_ORIGINS` empty, only the base URL origin passes.
        - Preflights get no CORS headers unless CORS is configured.
        - A trailing slash in `CORS_ORIGINS` fails startup.

---

## Phase 2 — Dockerfiles (one per app repo)
`[~]`

Besides the `Dockerfile` itself, each repo needs:

- **`.dockerignore`**: `node_modules`, `.next`, `.venv`, `.git`, **`.env*`** (never bake
  secrets into an image), caches.
- **Multi-stage build**: a build stage with dev tooling, and a slim runtime stage.
- **Non-root user** in the runtime stage.
- **Config only through env vars at runtime**, never `.env` files inside the image.
- **Pinned base images** (e.g. `node:24-slim`, `python:3.14-slim`), and later pinned by digest.
- **Target `linux/arm64`** too: Fargate on Graviton is ~20% cheaper. The local Docker Desktop is
  `linux/amd64`, so arm64 builds here are emulated (QEMU) and slow.

**`.dockerignore` lessons (from auth-server):**
- Docker has **no default ignores** and doesn't read `.gitignore`. Without the file, `.git` and
  `.env` are sent.
- Patterns are **anchored to the context root**, and `*` doesn't cross `/`. `*.md` only matches
  the root, so use `**/*.md` for any depth. This differs from `.gitignore`.
- It's a denylist (the owner's choice: more common and easier to read), so secrets get the broadest
  patterns.
- Every line should match something real in the repo, so no template leftovers.
- Keeping `.ts` out of the *final image* is the multi-stage build's job, not `.dockerignore`'s:
  the build needs the `.ts` files.
- `.git` is excluded because it holds the full history (including deleted secrets) and busts the
  layer cache. If the app needs the SHA, pass it as a build arg.
- auth-server's context is 21 files, 252 KB (it was 2.5 MB).

Per repo:

- [x] **membership-applications**: `.dockerignore` (`6a291c8`) and Dockerfile (`7e148da`), in
      [PR #20](https://github.com/Luis-Palacios/membership-applications/pull/20). Entry point
      `python -m membership_applications.api.run`, `WORKERS=1` (scale with tasks instead). Azure SQL
      needs `Encrypt=yes` in the connection string. Decisions and findings (2026-10-08):
      - **Groundwork first, found while reviewing:**
        - Both settings classes always read `.env`, and `ENVIRONMENT` defaulted to `local` (public
          `/docs`) and `DEBUG` to `True` (tracebacks in 500s, SQL echo with bound parameters in the
          logs). Now `ENVIRONMENT` is required, `DEBUG` defaults to `False`, and a validator refuses
          `DEBUG=True` in production (fail closed).
        - `.env` handling (`env_file.py`): read unless `ENVIRONMENT` is `staging`/`production` *in
          the real environment*. Deployments must set it (it's required), so they never read a stray
          `.env`; locally it's not in the shell, so `.env` is read and supplies `ENVIRONMENT=local`.
          The owner rejected `uv run --env-file .env` (a flag on every command). A first attempt
          gated on `ENVIRONMENT == "local"` *before* `.env` was read, so it never read it locally.
        - **Don't bake `ENVIRONMENT=production` into the image:** that would make the required check
          pointless. **Set `ENVIRONMENT=production` in the task definition (Phase 8).**
      - **Prod vs dev dependencies:** `fastapi[standard]` was a runtime dependency (fastapi-cli,
        fastapi-cloud-cli with sentry-sdk, rich, typer, httpx, jinja2, watchfiles, ...; none used).
        It's now in the API member's `[dependency-groups] dev` (for `fastapi dev`); prod has
        `fastapi` + `uvicorn` (imported by `run.py`, previously undeclared). Prod-only install:
        57 → 30 packages. Owner chose plain `uvicorn` over `uvicorn[standard]` for now (see
        follow-ups). Lesson: `uv remove X` + `uv add X` re-resolves X's subtree at the latest
        versions; edit `pyproject.toml` and run `uv lock` to keep pins. The upgrades were kept as their
        own commit. FastAPI 0.142 added `opentelemetry-api` as a *runtime* dependency (~300 KB).
      - **Two stages.** `builder`: pinned uv `0.12.23`, deps-only layer with bind-mounted `uv.lock` +
        both `pyproject.toml` files (`--locked --no-install-workspace`), then `COPY . .` and
        `uv sync --locked --no-dev --all-packages --no-editable` (the project lands in
        `site-packages`). `runtime`: same base, driver, and `COPY --from=builder /app/.venv` only (no
        uv, no source). Same base and same `/app/.venv` path in both stages, because venv scripts have
        absolute shebangs.
      - **`--locked`, not `--frozen`:** `--frozen` doesn't check the lock against `pyproject.toml`.
      - **Base `python:3.14.7-slim-trixie`:** pinned including the Debian release, because the
        driver repo URL is Debian 13 specific.
      - **`msodbcsql18` 18.7.1.1-1** via Microsoft's `packages-microsoft-prod.deb` (no gpg needed),
        `ACCEPT_EULA=Y`, curl purged in the same `RUN`. Available for trixie on amd64 and arm64.
        **Found by testing:** the driver links `libgssapi_krb5.so.2` but its package doesn't declare
        it. It arrived with curl and was auto-removed with it, giving `Can't open lib ... file not
        found` on the first real connection while `pyodbc.drivers()` still listed the driver (it only
        reads `odbcinst.ini`). Fixed by installing `libgssapi-krb5-2` explicitly; check with `ldd`.
      - Root-owned `.venv`, runs as UID 10001 (`useradd` without `--system`, which expects ≤ 999).
        Exec-form `CMD ["python", "-m", ...]`, python as PID 1.
      - `UV_COMPILE_BYTECODE=1` (faster cold start; most of why the venv is 71 MB),
        `UV_LINK_MODE=copy`, `UV_PYTHON_DOWNLOADS=0`.
      - `.dockerignore` also excludes the Dockerfile and dev-tool config, so editing them doesn't
        invalidate the `COPY . .` layer. `README.md` must stay (`uv_build` needs it). Context:
        4106 files / 140 MB → 47 files / 528 KB.
      - **Verified from the image (amd64):** `/health` 200 against the dev Azure SQL copy with
        `ENVIRONMENT=production`; `/docs` 404; 401 without a token; startup fails without config;
        `docker stop` exits 0 in ~1s. Image is 270 MB (~135 base, 71 venv, 10 driver).
        **Not yet tested:** arm64 (Phase 4) and in-flight requests during SIGTERM (Phase 3/8).
      - Testing gotcha on Windows: probe published ports with `127.0.0.1`, not `localhost`
        (`localhost` tries IPv6 `::1` first and the request hung).
- [x] **auth-server**: `.dockerignore` (`59a6c70`), Dockerfile (`55d933f`), `migrate.ts`
      (`59800e7`) and `set-role.ts` (`0d4ff3f`) are done, in
      [PR #18](https://github.com/Luis-Palacios/auth-server/pull/18). Dockerfile decisions and findings:
      - **Alpine, not slim:** ~90 MB smaller. Node on musl is "Experimental" tier, which is
        acceptable because no runtime dependency is a native addon. Switch to `-slim` if one breaks.
      - **Pinned exactly** (`24.21.0`, Alpine `3.24`). A floating tag only changes when you
        rebuild and pull, and then the change arrives untested. Bumps should come as their own
        commits (Dependabot/Renovate, Phase 10).
      - pnpm comes from `npm i -g` and lives only in the build stages. `ARG PNPM_VERSION` must
        match `packageManager`.
      - **drizzle-kit leak (found by measuring):** better-auth declares `drizzle-kit` as an
        optional peer and never imports it. pnpm satisfied that peer with our devDependency, so
        `--prod` shipped drizzle-kit and esbuild (~105 MB). Fixed with a `readPackage` hook in
        `.pnpmfile.cjs` (`03fb44a`). A scoped `overrides` entry was tried first and doesn't affect
        peers. The lockfile records the hook's checksum, so the build fails with
        `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH` if `.pnpmfile.cjs` isn't mounted.
      - Results: image 466 → 320 MB, prod `node_modules` 179 → 68 MB.

      **`migrate.ts` (`59800e7`), decisions and findings:**
      - **The two runners agree (verified 2026-10-01):** `drizzle-kit migrate` imports
        `drizzle-orm/node-postgres/migrator`, the same `migrate()`. Same `drizzle.__drizzle_migrations`
        table, same SHA-256 hashes. Run against the DB drizzle-kit had migrated, it applied nothing.
      - drizzle v1 picks pending migrations **by folder name**, not by timestamp, so a migration
        generated earlier but merged later still runs. All pending migrations run in **one
        transaction**.
      - Doesn't import `lib/config.ts`: the migrate task gets only `DATABASE_URL`.
      - One `pg.Client`. `pg_advisory_lock` comes first (a second run waits), then
        `SET lock_timeout = '10s'` (a blocked `ALTER` fails fast instead of queueing the app's
        queries behind it). The order matters, because `lock_timeout` also applies to advisory locks.
        Advisory locks are per database.
      - No SIGTERM handler: if the task is killed, Postgres rolls back and releases the lock.
      - Tested from the image: no-op on an up-to-date DB, full apply on a fresh DB, rerun is a
        no-op, waits while another session holds the lock, two simultaneous runs apply each
        migration once, and an unreachable DB or missing `DATABASE_URL` gives exit `1` (no hang).
        **Not yet tested:** `lock_timeout` actually firing. Do that with the next real migration.
      - The lock only serializes runs. Order and compatibility belong to the pipeline (Phase 10,
        "Migration safety").

      **`set-role.ts` (`0d4ff3f`), decisions and findings (2026-10-07):**
      `node dist/scripts/set-role.js <email> <role>`; the first admin signs up normally in staff-app
      (role `pending`), then this promotes them. It's also the break-glass fix if every admin is lost.
      - **Direct drizzle update, not better-auth.** `auth.api.setRole` runs `adminMiddleware` with
        `requireHeaders` (needs an admin session). `internalAdapter.updateUser` would work but means
        importing `lib/auth.ts` → `config.ts` → every secret. The "never raw inserts" rule protects the
        `account` row with the password hash, which a role change doesn't touch. Cost: better-auth's
        `databaseHooks` don't run (none configured; noted in the script and CLAUDE.md). Deciding
        argument: a break-glass tool should work even when the app's config is broken.
      - **Imports:** only `auth-schema.ts` and `permissions/statements.ts`, which now exports one
        `roles` map shared with the admin plugin (`b42ff0d`). Validated with `Object.hasOwn`, because
        `in` walks the prototype chain (`toString` would pass). Verified: runs with only
        `DATABASE_URL`.
      - **DB user:** the app user (DML only), so it runs from the normal `auth-server` task definition
        with a command override, not `auth-server-migrate`. That task definition injects all secrets
        anyway; the benefit of not importing config is robustness, not hiding secrets.
      - **When the new role applies:** `session.cookieCache` is off, so `getSession` reads the user row
        on every request and the change is immediate. staff-app mints a fresh JWT on every call, so
        membership-applications sees it on the next call; a token already copied elsewhere keeps the
        old role until it expires (15 min default).
      - **No session revocation** (owner's decision: the script is for promoting the first admin and
        break-glass). Accepted gap: if admins were lost *because an account was compromised*, the
        script can promote a new admin but doesn't kick the attacker out. The new admin then bans the
        compromised account from staff-app (ban revokes its sessions).
      - **Refuses unverified accounts** (exit `1`), so a typo'd or squatted address can't be promoted.
        Emails are trimmed and lowercased, because better-auth stores them lowercased.
      - **Read and write in one transaction with `SELECT ... FOR UPDATE`**, so the logged old role is
        correct even if someone changes the role at the same time. The log line is written only after
        the commit; it's the audit record (who ran it is in CloudTrail, `ecs:RunTask`).
      - **Exit codes:** `0` changed or already that role (idempotent), `1` failure at run time (not
        found, unverified, DB error), `2` usage error (Unix convention).
      - **Tested from the image** against a throwaway DB: every exit path above, a `null` old role,
        mixed-case input, an unreachable DB (no hang), and a concurrent row lock (it waited about 6s and
        logged the other session's role as the old one).
      - **Found along the way:** the admin plugin types `defaultRole` as a plain `string`, so
        `defaultRole: 'nope'` compiles and every new sign-up would get an undefined role. Small
        hardening item, not done: `defaultRole: 'pending' satisfies keyof typeof roles`.

      **Brief for the owner.** Use three stages:
      - `build`: all deps with `pnpm install --frozen-lockfile`, then `pnpm build`.
      - `prod-deps`: `--prod` install.
      - `runtime`: a clean base with prod `node_modules`, `dist/`, `drizzle/` (needed at run time by
        `migrate.js`) and `package.json` (for `"type": "module"`).

      Decisions to make, each with a reason:
      - How specific the base image tag is (`24` / `24.21` / `24.21.0`), and slim vs alpine (musl)
        vs distroless (no shell).
      - How pnpm 12.3.4 gets into the image: corepack (does Node 24 still ship it?) or
        `npm i -g pnpm@12.3.4`. It must match the lockfile.
      - Layer order: `COPY` the manifests before the install, so editing `src/` doesn't reinstall
        everything.
      - Non-root `USER node`, `ENV NODE_ENV=production`, `EXPOSE 5000`.
      - Be able to explain why the shell form or `pnpm start` breaks graceful shutdown.

      Original item: pnpm install → `tsc` build → runtime with prod deps only. Use
      `CMD ["node", "--enable-source-maps", "dist/index.js"]` (exec form, node as PID 1), **not**
      `pnpm start`, so SIGTERM reaches the app's shutdown handler. **Migrations (decided
      2026-09-30): drizzle-orm's runtime `migrate()` in `src/migrate.ts` → `dist/migrate.js`, in the
      same image** (one image, several commands; the Rails/Django pattern). Rejected: a separate
      `migrate` build target running `drizzle-kit`, which means two images to keep in step and dev
      tooling in a prod-adjacent image. Run it as a **one-off ECS task** before deploying, not on
      app startup (with 2+ tasks, migrations race, and a failed one turns into a crash loop).
      Trade-offs we accepted:
      - Two runners (`drizzle-kit migrate` locally, `migrate()` in prod) must agree on
        `__drizzle_migrations`. **Verified 2026-10-01** (same code path, see above). Always upgrade
        `drizzle-orm` and `drizzle-kit` together.
      - Migrations need DDL rights and the app user doesn't have them (Phase 6). `run-task` overrides
        can't change `secrets:`, so the migrate task needs its **own task definition**
        (`auth-server-migrate`: same image, owner-level `DATABASE_URL`).
- [~] **staff-app**: Next.js standalone output → `node server.js`. Copy `.next/static` →
      `.next/standalone/.next/static` and `public` → `.next/standalone/public`, and set
      `ENV HOSTNAME=0.0.0.0`. Add a **post-build smoke test** (in CI or a script): run the image,
      then fetch `/api/health` **and** one `/_next/static` file. A missing static copy leaves
      the health check at 200, so only the asset fetch catches it.
      **Groundwork done (2026-10-08), Dockerfile not started.** Findings and decisions:
      - **The lockfile had never been committed** ([PR #31](https://github.com/Luis-Palacios/staff-app/pull/31)).
        A leftover template block in `.gitignore` ignored every lockfile, so `pnpm-lock.yaml` existed
        only on the Mac. A build from a checkout couldn't use `--frozen-lockfile`. Found by the
        build-context check, not by git: always look at what's *missing* from the context too.
      - **pnpm pinned** like auth-server: `devEngines.packageManager` (`onFail: download`) +
        `packageManager`, both `12.3.4`. With `onFail: download`, pnpm writes its own version and
        integrity hashes into the lockfile (`packageManagerDependencies`), so adding the pin changes
        the lockfile. Side effect: `npx` now fails with `EBADDEVENGINES`; use `pnpm exec`/`pnpm dlx`.
        The Dockerfile's `ARG PNPM_VERSION` must match.
      - `.npmrc` (`package-lock=true`, the default) deleted. pnpm 10+ reads only auth/registry
        settings from `.npmrc`; the rest lives in `pnpm-workspace.yaml`.
      - **`.dockerignore`** ([PR #32](https://github.com/Luis-Palacios/staff-app/pull/32)): context
        62,840 files / 2.0 GB → 94 files / 772 KB. Next-specific reasons:
        - `**/.env*` matters more than usual: `next build` loads `.env*` itself and inlines
          `NEXT_PUBLIC_*` values into the client bundle.
        - Host `node_modules` has native binaries for the host OS (`sharp-darwin-x64`,
          `@tailwindcss/oxide-darwin-x64`); `.next`, `next-env.d.ts` and `*.tsbuildinfo` are host
          build output and caches.
        - Next 16's `next build` doesn't run ESLint (Next 15 did), so `eslint.config.mjs` and
          `.prettierrc` are excluded.
        - Kept: `pnpm-workspace.yaml` (its `allowBuilds` lets `sharp`, `oxide` and `unrs-resolver`
          run install scripts, so the image gets Linux binaries), `public/`, the lockfile and the
          configs `next build` reads.

**New concepts:** layers & caching, multi-stage builds, image size, build args vs runtime env.

---

## Phase 3 — Local docker-compose (in this repo)
`[ ]`

- [ ] `compose.yaml` with the three apps plus a `postgres` container for auth-server.
- [ ] membership-applications points at the **Azure SQL dev copy**. Allowlist your home IP in
      its firewall.
- [ ] The `migrate` service runs before auth-server (`depends_on: condition: service_completed_successfully`).
- [ ] Healthchecks plus `depends_on: condition: service_healthy`.
- [ ] `stop_grace_period: 30s` on auth-server. Compose's default is 10s, which is below
      auth-server's `SHUTDOWN_TIMEOUT_MS` (20s).
- [ ] Only staff-app publishes a port to the host, to mirror prod (auth/membership internal-only).
- [ ] **Match prod's `BETTER_AUTH_URL`:** set it to staff-app's origin (`http://localhost:3001`),
      not auth-server's. Email links and cookies then go through the proxy as in prod, and
      auth-server's `TRUSTED_ORIGINS` can be empty, as in prod. The JWT `iss`/`aud` change with it,
      so membership-applications' `JWT_ISSUER`/`JWT_AUDIENCE` move to `:3001` too
      (`AUTH_SERVER_URL` stays internal).
- [ ] `.env.example` per service, with real `.env` files gitignored.
- [ ] membership-applications needs `ENVIRONMENT` set as a real env var in compose (`environment:`
      or `env_file:` in `compose.yaml`; the image never reads a `.env` itself). Use `staging` or
      `production` there to exercise the prod code path (no `/docs`, `DEBUG` refused in production).
- [ ] Test the whole flow: sign-up → email verification → sign-in → list applications (JWT path).

**New concepts:** container networking/DNS by service name, which is the same idea as Service Connect.

---

## Phase 4 — Build & push images manually to ECR
`[ ]`

- [ ] Create 3 ECR repositories (console). Add a lifecycle policy that keeps the last ~10 images.
- [ ] `aws ecr get-login-password | docker login ...`, then `docker buildx build --platform linux/arm64`, tag, push.
- [ ] Tag with the **git SHA**, not `latest`, so a deploy always points at a specific version.

---

## Phase 5 — Networking (VPC)
`[ ]`

- [ ] VPC with 2 public + 2 private subnets across 2 AZs (the ALB needs 2 AZs).
- [ ] fck-nat instance plus an Elastic IP, and private route tables → NAT.
- [ ] Security groups: `alb` (443 from the internet) → `staff-app` → `auth-server` /
      `membership` → `rds` (5432 from auth-server only).
- [ ] Add a server-level firewall rule on the prod **Azure SQL** server for the NAT's Elastic IP
      (Azure portal → SQL server → Networking). Allow that single IP only, not a range.
      Later, manage this rule in Terraform too, with the `azurerm` provider (optional).

**New concepts:** subnets, route tables, IGW vs NAT, security groups as allow-lists referencing each other.

---

## Phase 6 — RDS PostgreSQL
`[ ]`

- [ ] `db.t4g.micro`, single-AZ, 20 GB gp3, private subnets, not publicly accessible.
- [ ] Automated backups (7 days), deletion protection on.
- [ ] Master password managed in Secrets Manager (RDS can do this for you).
- [ ] App user with limited privileges (don't run the app as master).
- [ ] Run migrations (one-off ECS task), then create the admin user.
      **Admin approach (decided 2026-09-30):** a one-off admin process from the same image
      (12-factor XII). The person signs up normally in staff-app (they choose their own password and
      get the `pending` role), then a one-off task runs `node dist/scripts/set-role.js <email> admin`.
      The same command is the break-glass fix if every admin is lost. No password ever goes through
      a CLI argument, an env var, the task definition or the logs. Extra admins and elders come
      through the existing invite flow in staff-app. Not `pnpm dlx auth@latest create-admin` in
      prod: it downloads an unpinned npm package at run time and prompts for input interactively.
      ECS Exec is a debugging tool, not the routine path. **Built** (auth-server `0d4ff3f`, see
      Phase 2). The person must have verified their email first, or the script refuses (exit `1`).
- [ ] **Test a restore** once. A backup you've never restored doesn't count.

---

## Phase 7 — Secrets & config
`[ ]`

- [ ] **SSM Parameter Store `SecureString`** for app secrets (free) instead of Secrets Manager
      ($0.40/secret/mo): `BETTER_AUTH_SECRET`, `DATABASE_URL`, `ASSIMILATION_DATABASE_URL`, `RESEND_API_KEY`.
- [ ] ECS task definitions reference them through `secrets:` (injected as env vars at start).
      The task *execution role* gets read access only to its own parameters.

---

## Phase 8 — ECS, ALB, domain, TLS
`[ ]`

- [ ] ECS cluster with Service Connect namespace.
- [ ] 3 task definitions (start at 0.25 vCPU / 0.5 GB; staff-app may need 1 GB), ARM64,
      logs → CloudWatch (retention 14–30 days, not "never expire").
- [ ] 3 services, desired count 1 each. Deployment circuit breaker with rollback on.
- [ ] membership-applications task definition: **`ENVIRONMENT=production`** (required; the image
      doesn't set it), `DEBUG` unset or `false` (`true` is refused at startup in production).
- [ ] Container `stopTimeout` above auth-server's `SHUTDOWN_TIMEOUT_MS` (30s default vs 20s is
      fine; if you raise one, raise the other).
- [ ] **Verify Service Connect draining.** Does ECS remove auth-server from Service Connect before
      sending SIGTERM, or do requests keep arriving after it? Test it by redeploying while running
      a request loop through staff-app and watching for errors. If errors show up, add a short
      pre-stop delay to auth-server's shutdown (keep serving with `/health` at 503 for a few
      seconds before `server.close()`).
- [ ] **ACM certificate** in `us-east-2` for the staff-app hostname (e.g. `staff.<domain>`).
      Validate by DNS: add the CNAME ACM gives you in **Cloudflare**, as DNS-only.
- [ ] ALB HTTPS listener (ACM cert), HTTP→HTTPS redirect, target group → staff-app `/api/health`.
- [ ] **Cloudflare record**: `staff.<domain>` CNAME → the ALB's DNS name, **DNS-only (grey cloud)**
      for now. The proxy gets turned on in Phase 8.5, once everything works without it.
- [ ] Set staff-app's ALB idle timeout lower than its keep-alive timeout, and do the same between auth-server and staff-app. The auth-server
      ROADMAP already mentions why.
- [ ] Resend: the domain is already verified, so nothing to do in DNS. Just put `RESEND_API_KEY` in
      SSM (Phase 7) and set `RESEND_FROM_EMAIL`. Emails will link to `BETTER_AUTH_URL` (the staff
      public URL), so send a real verification/reset email once prod is up.

---

## Phase 8.5 — Cloudflare proxy (orange cloud)
`[ ]`

**What:** Switch the `staff.<domain>` record from DNS-only to proxied. Browsers then connect to
Cloudflare, and Cloudflare connects to the ALB.

**Why:** staff-app has a public sign-in page. The proxy adds, for free: DDoS absorption, a basic
managed WAF, bot filtering, one free rate-limiting rule (e.g. on `/api/auth/sign-in/*`), and
edge caching of `/_next/static/*`. It also shows you know how to put an edge layer in
front of an origin.

**Why not on day one:** it changes TLS, client IPs and firewalling all at once. If you turn it on
while first deploying, you won't know which layer is breaking. Run DNS-only until sign-in,
email links and JWT calls all work, then flip it.

The proxy only protects you if the ALB can't be reached around it. The ALB's DNS name is public,
so without the security-group step below, attackers can skip Cloudflare entirely.

- [ ] **SSL/TLS mode "Full (strict)"** in Cloudflare. Cloudflare → ALB traffic stays HTTPS and is
      validated against the ACM cert. Never use "Flexible": it sends plain HTTP to the origin,
      and staff-app's auth cookies would travel unencrypted on that hop.
- [ ] **Lock the ALB security group to Cloudflare's IP ranges** (443 only, IPv4 + IPv6). In Terraform,
      read them with the `cloudflare` provider's IP-ranges data source, so the list isn't
      hand-maintained.
- [ ] **Client IP, end to end.** Cloudflare sets `CF-Connecting-IP` (overwriting any value the
      client sent) and appends to `X-Forwarded-For`. The ALB then appends Cloudflare's edge IP.
      - auth-server: with Cloudflare in front, `X-Forwarded-For` always holds 2+ addresses, so add
        Cloudflare's published ranges to `TRUSTED_PROXIES` (Phase 1); better-auth then skips the
        edge address and keys on the real client (checked against better-auth's resolver:
        `client, cf-edge` → `client`; a spoofed leftmost entry is ignored). Alternative once the ALB
        only accepts Cloudflare: point better-auth at `CF-Connecting-IP` with
        `advanced.ipAddress.ipAddressHeaders: ['cf-connecting-ip']`. The Next.js rewrite already
        passes that header through untouched (verified locally).
      - membership-applications: not affected if its rate limiter is keyed by JWT `sub` (Phase 1).
      - ALB access logs and CloudWatch will show Cloudflare IPs, so log `CF-Connecting-IP` in the apps.
- [ ] **Don't cache anything dynamic.** Cloudflare's defaults only cache static file extensions,
      but check that `/api/*` and HTML pages show `cf-cache-status: DYNAMIC`/`BYPASS`, never `HIT`.
- [ ] Rate-limiting rule on sign-in / forgot-password paths. This is an extra layer on top of better-auth's own limits.
- [ ] Retest: sign-in, sign-out, email verification link, password reset, invite link, JWT-backed pages.
- [ ] Rollback plan: flip the record back to grey cloud (takes effect in seconds), and re-open the ALB SG if needed.

**New concepts:** edge proxy vs origin, TLS termination and re-encryption, origin lock-down,
which client-IP headers you can trust.

---

## Phase 9 — Basic observability
`[ ]`

- [ ] CloudWatch alarms: ALB 5xx, unhealthy targets, RDS CPU/storage → SNS email.
- [ ] Structured JSON logs (auth-server ROADMAP Phase 7) make CloudWatch Logs Insights useful.

---

## Phase 10 — GitHub Actions CI/CD
`[ ]`

- [ ] **CI** in each app repo on PRs: lint, type-check, `docker build` (no push).
- [ ] **CD** on push to `main`: build → push to ECR (SHA tag) → render the task definition with
      the new image → `aws ecs deploy`. auth-server runs the migrate task first.
- [ ] **GitHub OIDC → IAM role** (no long-lived AWS keys in GitHub secrets). Scope the role's
      trust to `repo:Luis-Palacios/<repo>:ref:refs/heads/main`.
- [ ] Optional: GitHub `production` environment with required approval.
- [ ] **Migration safety in the pipeline.** migrate.ts's advisory lock only prevents two runs from
      applying the same migration at once. It doesn't decide order, and it doesn't check that two
      PRs' migrations make sense together.
  - [ ] `concurrency:` group on the deploy workflow (queue, don't cancel), so deploys can't finish
        out of order (an older image going live after a newer commit's migration).
  - [ ] Branch protection: **require branches to be up to date before merging** (a merge queue on
        bigger teams). A PR with a migration is then rebased onto the other PR's migration and
        re-tested, and gets its migration regenerated if the `prevIds` snapshot chain forked.
  - [ ] CI applies every migration to a fresh Postgres and runs `drizzle-kit check`. Untested so
        far: how v1 reports two snapshots with the same parent.
  - [ ] Convention: expand/contract (backward-compatible) migrations, so the running old code
        always works with the new schema.
  - [ ] Fail CI if `pnpm why drizzle-kit --prod` returns anything (see the drizzle-kit leak, Phase 2).

---

## Phase 11 — Infrastructure as Code
`[ ]`

**Approach: rebuild, don't import.** Importing console-created resources into IaC is tedious
and error-prone. Once the manual version works, use it as the reference, write the IaC,
and **stand up a fresh copy with it**. Then switch DNS to the new copy and delete the
console-built one. (For RDS, restore from a snapshot into the IaC-managed instance.) Being able to
tear down and rebuild everything is itself the thing worth showing.

**Tool: Terraform (HCL).** Terraform and OpenTofu use the same language, and for this project
the two CLIs are interchangeable. OpenTofu is the open-source fork (MPL license), while Terraform
is under HashiCorp's BSL, which doesn't matter for personal use. **Pick one CLI and stick with
it.** After the two diverge in version, a state file written by one may not be readable by the
other.

**Decision: Terraform CLI.** Reasons:
- It's the name in job postings and interviews, and the tool most tutorials and docs use.
  When you're learning, examples that run without translating them matter.
- OpenTofu's main technical advantage is client-side **state encryption**. Here that matters less:
  the RDS master password is managed by RDS in Secrets Manager (not generated by Terraform),
  app secrets live in SSM, and the state bucket is private and encrypted.
- The license difference (BSL vs MPL) doesn't affect personal use.
- It's reversible. OpenTofu has a documented migration path from Terraform, so you can switch
  later if you ever need to.

Pin the version with `required_version` in `terraform {}` and in CI (`hashicorp/setup-terraform`),
so your laptop and GitHub Actions always run the same version. The HCL skill is the same
either way, so "Terraform/OpenTofu" on a résumé is honest.

Cost: $0. The CLI is free, state lives in an S3 bucket (pennies), and locking uses native S3 lock
files (`use_lockfile = true`), so no DynamoDB table is needed. You don't need HCP Terraform (the paid SaaS).

Providers this project will use:
- `aws`: everything in AWS.
- `cloudflare`: the `staff.<domain>` CNAME and the ACM validation record, so the DNS is in code too.
- `azurerm` (optional): the Azure SQL firewall rule for the NAT EIP.

- [ ] Bootstrap: S3 state bucket (versioning on, public access blocked). Create it once by
      hand, or with a tiny `bootstrap/` config that uses local state.
- [ ] Layout: `terraform/modules/{network,rds,ecs-cluster,ecs-service,alb,github-oidc,s3-uploads}` + `terraform/envs/prod`
- [ ] Commit the `.terraform.lock.hcl`. Never commit `*.tfstate` or `*.tfvars` that contain secrets.
- [ ] CI in this repo: `terraform fmt -check`, `validate`, and `plan` on PRs. Run `apply` manually at first.
- [ ] Switch CD to deploy only the image (app repos), with infra changes applied from this repo

---

## Phase 12 — S3 bucket for profile icons
`[ ]`

Owned by **auth-server**. It already stores the user's `image` field.

- [ ] Private bucket (Block Public Access on), created with Terraform.
- [ ] auth-server route (e.g. `POST /api/custom-auth/avatar-upload-url`, session-gated) returns a
      **presigned POST** for `avatars/<userId>/<uuid>`. The browser uploads directly to S3, so
      no file bytes pass through the app. A presigned *POST* (not PUT) lets the policy
      enforce `content-length-range` and the `Content-Type` (e.g. `image/png|jpeg|webp`, ≤ 1–2 MB).
- [ ] After the upload, a second call updates `user.image` through better-auth's `updateUser`.
- [ ] **Proxy gap:** staff-app only proxies `/api/auth/*` today. Either proxy
      `/api/custom-auth/*` as well, or call it server-side from staff-app.
- [ ] Serve through short-lived presigned GETs, or CloudFront with Origin Access Control if you want
      caching. (Note: a CloudFront cert must be in `us-east-1`, even though everything else is in `us-east-2`.)
- [ ] S3 CORS rule allowing `POST` from the staff-app origin only.
- [ ] auth-server's **task role** (not the execution role) gets `s3:PutObject`/`GetObject` on
      `avatars/*` only. Local dev: point the SDK at LocalStack/MinIO in compose, or at a dev bucket.

---

## Later / stretch

- Staging environment (a second copy from the same IaC with different variables).
- WAF on the ALB, Multi-AZ RDS, autoscaling. Mostly for learning at this user count.
- Fargate Spot for non-prod, VPC endpoints for ECR/S3/SSM (less NAT traffic).
- staff-app UX when auth-server is down: today, pages show the default unstyled `app/error.tsx`
  ("Something went wrong!"), and the proxy returns a bare 500 to the sign-in form. Show a clear
  "temporarily unavailable" message instead, and add `global-error.tsx` (errors in the root
  layout skip `error.tsx`). This is deliberately not handled by the health check, which is
  shallow (see Phase 1).

---

## Cost estimate

Rough monthly, prod only, ARM Fargate, `us-east-2` prices. Check with the
[AWS Pricing Calculator](https://calculator.aws/) before committing.

| Item | ~$/mo |
|---|---|
| Fargate, 3 small tasks (24/7) | 18–25 |
| ALB (hourly + light LCU) | 18–22 |
| Public IPv4 (ALB ×2, NAT ×1) | ~11 |
| RDS `db.t4g.micro` + 20 GB | ~14 |
| fck-nat `t4g.nano` | ~3 |
| CloudWatch, ECR, SSM, S3 (DNS is on Cloudflare, free) | 2–5 |
| **Total** | **~65–80** |

This is above the $30–60 target. Levers, in order: new-account free-tier credits, smaller tasks,
and Compute Savings Plan later. If it has to be well under $50, the ALB and the IPv4 addresses
are the big fixed costs to rethink, not the apps.
