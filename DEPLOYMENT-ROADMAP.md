# Deployment Roadmap

Working doc for deploying `staff-app` (Next.js), `auth-server` (better-auth/Hono) and
`membership-applications` (FastAPI) to AWS. The goals are to learn AWS step by step, to run
something real for the church (~20 users), and to end up with something worth showing in
interviews. As in the other roadmaps, each phase is a learning step. Do the manual (console)
version first, then automate it. Pick up at whichever phase is still marked `[ ]`.

Status markers: `[ ]` not started, `[~]` in progress, `[x]` done.

Started: 2026-09-21

---

## Where we left off (2026-09-24)

**Phase 0 is done. Phase 1 is in progress (3 of 9 items done).** Resume at the staff-app items in
[Phase 1](#phase-1--code-changes-needed-before-deployment). Suggested order: first check whether
`rewrites()` bakes the auth-server URL in at build time (run `next build` and read
`.next/routes-manifest.json`; the local probe so far only used `next dev`, which can't tell), because
the answer decides whether the `AUTH_SERVER_URL` rename is a one-line env change or needs the runtime
proxy route handler.

**How we work (learning first):** every code change is shown and explained one at a time. The owner
applies it, or asks Claude to, and it is then reviewed. Prefer industry-standard production patterns
over the minimum for ~20 users, and design for the API and auth-server possibly going public later
(mobile app). The owner is on Windows/PowerShell 7, so give commands as PowerShell or as a script file,
not multi-line bash.

**Local setup still needed after this session's changes:**
- `auth-server/.env`: add a bare `TRUSTED_PROXIES=` line. It is now required to be *present*
  (empty is allowed), and auth-server won't start without it.
- `membership-applications/.env`: needs `JWT_ISSUER` and `JWT_AUDIENCE` (both `http://localhost:5000`
  locally, same as `AUTH_SERVER_URL`). Already done and verified. `RATE_LIMIT_STORAGE_URI` is
  optional (defaults to `memory://`).

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
`[~]`

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
- [ ] **staff-app: `NEXT_PUBLIC_AUTH_SERVER_URL` is now only used server-side.** Rename it to a
      server-only `AUTH_SERVER_URL`.
- [ ] **staff-app: `rewrites()` in `next.config.mjs` is evaluated at build time** (it ends up in
      the routes manifest). **Verify.** If confirmed, the auth-server URL is baked into the image. That's
      acceptable with prod only (pass it as a build arg), but the cleaner fix is a runtime route
      handler `app/api/auth/[...all]/route.ts` that proxies using the env var at request time.
- [ ] **staff-app: add `output: "standalone"`** (small image, no `node_modules` copy) and a
      `/api/health` route for the ALB target group.
- [ ] **auth-server: add `build` + `start` scripts.** The source uses `.js` import specifiers
      for `.ts` files, so it needs `tsc` → `dist/` and then `node dist/index.js`.
- [ ] **auth-server: graceful shutdown** (its own ROADMAP Phase 6). ECS sends SIGTERM on every
      deploy, so finish this before prod.
- [ ] Production CORS: auth-server `CORS_ORIGINS` = staff public URL. membership-applications
      barely needs CORS anymore (the browser never calls it).

---

## Phase 2 — Dockerfiles (one per app repo)
`[ ]`

Besides the `Dockerfile` itself, each repo needs:

- **`.dockerignore`**: `node_modules`, `.next`, `.venv`, `.git`, **`.env*`** (never bake
  secrets into an image), caches.
- **Multi-stage build**: a build stage with dev tooling, and a slim runtime stage.
- **Non-root user** in the runtime stage.
- **Config only through env vars at runtime**, never `.env` files inside the image.
- **Pinned base images** (e.g. `node:24-slim`, `python:3.14-slim`), and later pinned by digest.
- **Target `linux/arm64`** too: Fargate on Graviton is ~20% cheaper.

Per repo:

- [ ] **membership-applications**: the official uv Docker pattern (`uv sync --frozen --no-dev
      --all-packages`) plus **Microsoft's `msodbcsql18`** from their apt repo. Check that it supports
      the Debian version `python:3.14-slim` is based on. Entry point:
      `python -m membership_applications.api.run`, `WORKERS=1` (scale with tasks instead).
      Azure SQL needs `Encrypt=yes` in the connection string.
- [ ] **auth-server**: pnpm install → `tsc` build → runtime with prod deps only. **Migrations**:
      `drizzle-kit` is a dev dependency, so either build a separate `migrate` target in the same
      Dockerfile or use drizzle's runtime `migrate()` function. Run it as a **one-off ECS task**
      before deploying, not on app startup.
- [ ] **staff-app**: Next.js standalone output → `node server.js`.

**New concepts:** layers & caching, multi-stage builds, image size, build args vs runtime env.

---

## Phase 3 — Local docker-compose (in this repo)
`[ ]`

- [ ] `compose.yaml` with the three apps plus a `postgres` container for auth-server.
- [ ] membership-applications points at the **Azure SQL dev copy**. Allowlist your home IP in
      its firewall.
- [ ] The `migrate` service runs before auth-server (`depends_on: condition: service_completed_successfully`).
- [ ] Healthchecks plus `depends_on: condition: service_healthy`.
- [ ] Only staff-app publishes a port to the host, to mirror prod (auth/membership internal-only).
- [ ] `.env.example` per service, with real `.env` files gitignored.
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
