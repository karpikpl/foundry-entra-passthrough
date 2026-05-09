### 2026-05-09T03:04:39Z: Two App Registrations + App Service Slot Strategy
**By:** Holden (Lead / Auth Architect)
**Status:** APPROVED FOR PROVISIONING

---

## Executive Call

Use **two Entra app registrations for the same FastMCP RS-mode server**:

1. one intentionally misconfigured registration that preserves **H1** (`localhost` only)
2. one correctly configured registration that adds **`127.0.0.1`**

Deploy the **same FastMCP build** to two App Service slots, but challenge the assumption that a slot swap is the main switch mechanism. For this case, the safest design is:

- **staging slot = repro config**
- **production slot = fixed config**
- use the **slot URLs directly** to demonstrate broken vs fixed behavior

Reason: App Service slot swaps do **not** magically move slot-specific auth config unless we intentionally make those settings swappable. For auth, that adds avoidable ambiguity. Slots are useful here as **two live, side-by-side environments**, not primarily as a swap trick.

---

## 1) Exact App Registration Differences

### A. Repro app registration (must reproduce H1)

**Recommended display name:** `cloud-helper-mcp-rs-loopback-repro`

**Purpose:** preserve the historical loopback mismatch so the standalone loopback client can fail the same way the email chain described.

**Sign-in audience**
- `AzureADMyOrg` (single tenant)

**Platform configuration**
- Enable **Mobile and desktop applications / public client**
- Do **not** use Web platform for the loopback repro
- No client secret

**Public client redirect URIs**
- `http://localhost`
- **Do not add** `http://127.0.0.1`

This is the deliberate H1 defect. The Python client binds to `127.0.0.1` and sends `redirect_uri=http://127.0.0.1:<port>/`; Entra treats `localhost` and `127.0.0.1` as distinct loopback identifiers, so redemption fails or never completes.

**Expose an API (RS-mode)**
- Application ID URI: `api://<REPRO_CLIENT_ID>`
- Delegated scope: `mcp.access`
- Requested access token version: `2`

**Why keep the API scope on the repro app too?**
Because the FastMCP RS-mode server validates `aud`, so each slot needs a real resource audience even when we are intentionally keeping the loopback registration broken.

---

### B. Fixed app registration (correct RS-mode target)

**Recommended display name:** `cloud-helper-mcp-rs-loopback-fixed`

**Purpose:** same as repro, except H1 is fixed.

**Sign-in audience**
- `AzureADMyOrg` (single tenant)

**Platform configuration**
- Enable **Mobile and desktop applications / public client**
- No client secret

**Public client redirect URIs**
- `http://localhost`
- `http://127.0.0.1`

This is the exact H1 fix.

**Expose an API (RS-mode)**
- Application ID URI: `api://<FIXED_CLIENT_ID>`
- Delegated scope: `mcp.access`
- Requested access token version: `2`

---

### Important architectural note

For **VS Code** and **AI Foundry**, H1 is not the primary production failure. Those clients are RS-mode clients and do not depend on the server acting as an AS proxy. Therefore:

- the **two-app-reg design reproduces H1 cleanly for the standalone loopback client**
- it also proves the new RS-mode server validates tokens correctly against two different Entra resource apps
- but it does **not** mean slot-switching alone recreates the exact VS Code/Foundry production hang

That distinction matters and should be stated in the demo.

---

## 2) Slot Design and Environment Variables

## Recommended slot mapping

- **Staging slot** → repro app registration
- **Production slot** → fixed app registration

Example URLs:
- production: `https://cloud-helper-mcp.azurewebsites.net`
- staging: `https://cloud-helper-mcp-staging.azurewebsites.net`

## FastMCP env vars to set per slot

From this repo's server config, the runtime contract is:
- `TENANT_ID`
- `CLIENT_ID`
- `AUDIENCE` (optional; if unset, server resolves to `api://<CLIENT_ID>`)
- `RESOURCE_HOST`

### Production slot app settings
- `TENANT_ID=<tenant-guid>`
- `CLIENT_ID=<fixed app registration client id>`
- `AUDIENCE=api://<fixed client id>`
- `RESOURCE_HOST=cloud-helper-mcp.azurewebsites.net`

### Staging slot app settings
- `TENANT_ID=<tenant-guid>`
- `CLIENT_ID=<repro app registration client id>`
- `AUDIENCE=api://<repro client id>`
- `RESOURCE_HOST=cloud-helper-mcp-staging.azurewebsites.net`

## Slot-setting rule

Mark all four values above as **deployment slot settings (sticky)**.

Why:
- `CLIENT_ID` / `AUDIENCE` define which Entra app the slot trusts
- `RESOURCE_HOST` must match the slot hostname that publishes `/.well-known/oauth-protected-resource`
- sticky settings keep each slot stable and predictable

## Optional metadata for operators

Add non-functional tags/settings for clarity:
- `AUTH_PROFILE=repro|fixed`
- `APP_REG_DISPLAY_NAME=<display name>`

---

## 3) Testing Sequence

### Phase 1 — reproduce on staging (broken by design)
1. Deploy the same FastMCP RS-mode build to both slots.
2. Point **staging** at `cloud-helper-mcp-rs-loopback-repro`.
3. Run the standalone loopback client against staging.
4. Request the repro scope: `api://<REPRO_CLIENT_ID>/mcp.access`.
5. Expected result: auth flow breaks at the loopback callback / token redemption boundary because only `http://localhost` is registered while the client uses `http://127.0.0.1:<port>/`.

### Phase 2 — confirm on production (fixed)
1. Point **production** at `cloud-helper-mcp-rs-loopback-fixed`.
2. Run the same loopback client against production.
3. Request the fixed scope: `api://<FIXED_CLIENT_ID>/mcp.access`.
4. Expected result: Entra accepts the `127.0.0.1` loopback redirect and the flow completes.

### Phase 3 — demonstrate RS-mode still works with production clients
1. Validate `/.well-known/oauth-protected-resource` on both slots.
2. Validate Bearer token acceptance on `/mcp`.
3. Use VS Code / Foundry only to verify RS-mode discovery + Bearer validation, not to prove H1.

---

## 4) What about slot swap?

## Preferred answer

**Do not rely on slot swap as the primary broken/fixed switch.**

Use slot URLs directly:
- staging URL = broken demo
- production URL = fixed demo

That is the cleanest and least surprising design.

## If leadership insists on a “flip the public hostname” demo

It can be done, but only with care:

- keep `RESOURCE_HOST` sticky per slot
- allow `CLIENT_ID` and `AUDIENCE` to be swappable **or** manually rewrite them before/after the swap
- use **swap with preview**
- expect the required OAuth scope to change with the active app registration

This is operationally riskier than simply testing both slot URLs directly.

---

## 5) Gotchas

### A. Slot swap and settings behavior
- Slot-specific app settings stay with the slot.
- If `CLIENT_ID` / `AUDIENCE` are sticky, swapping slots will **not** move broken vs fixed auth behavior.
- If they are not sticky, the auth identity moves, but so does operator confusion.

### B. `RESOURCE_HOST` must match the slot hostname
- Each slot publishes protected resource metadata.
- If `RESOURCE_HOST` is wrong, clients discover the wrong resource URL and auth debugging becomes noisy.

### C. Token audience changes by slot
- staging tokens must target `api://<REPRO_CLIENT_ID>`
- production tokens must target `api://<FIXED_CLIENT_ID>`
- do not reuse a cached access token from one slot against the other

### D. Token/session/cache behavior
- MSAL / browser token caches may silently reuse tokens for the wrong audience or old app registration
- for each repro/fix pass, clear cached tokens or run in a fresh browser profile/incognito
- if using a local client cache, keep separate cache files per slot/app registration

### E. App Service restarts
- changing slot app settings restarts that slot
- swap also recycles workers during warmup/finalization
- any in-memory session state is lost; this is acceptable for this demo because FastMCP RS-mode should remain stateless with respect to OAuth sessions

### F. CORS / access restrictions are orthogonal
- CORS, IP restrictions, Easy Auth, and custom domains can still mask the test result
- keep Easy Auth disabled unless explicitly required for a separate experiment
- ensure both slot URLs are directly reachable by the test client

---

## 6) Naming

Replace the loose names with names that encode both **mode** and **purpose**.

### Recommended app registration names
- `cloud-helper-mcp-rs-loopback-repro`
- `cloud-helper-mcp-rs-loopback-fixed`

### Acceptable shorter alternative
- `chmcp-rs-repro`
- `chmcp-rs-fixed`

### Slot naming
- keep Azure defaults: `production` and `staging`
- do not encode repro/fixed in the slot name; encode that in sticky settings and tags

---

## 7) Provisioning Summary for Amos

1. Create two single-tenant Entra app registrations.
2. On **both**, expose API scope `mcp.access` and set token version to v2.
3. On **repro** app, register only `http://localhost` under public client redirects.
4. On **fixed** app, register both `http://localhost` and `http://127.0.0.1`.
5. Deploy one FastMCP RS-mode build to App Service with one staging slot.
6. Set sticky slot settings:
   - staging → repro `CLIENT_ID` / `AUDIENCE` / `RESOURCE_HOST`
   - production → fixed `CLIENT_ID` / `AUDIENCE` / `RESOURCE_HOST`
7. Test by hitting slot URLs directly.
8. Treat slot swap as optional demo choreography, not as the core mechanism.

---

## Final Decision

Proceed with the **two app registrations + two slot URLs** design.

Use slots to host **two live auth profiles in parallel**. That gives us a deterministic broken environment and a deterministic fixed environment, which is exactly what we need for a clean before/after demonstration and avoids overloading App Service slot swap semantics.