# Decision: derive tenantId from subscription() in AZD Bicep entrypoint

**Date:** 2026-05-09T04:51:40Z  
**By:** Amos (Infrastructure / DevOps)  
**Requested by:** Piotr  
**Status:** IMPLEMENTED

---

## Problem

`azd provision` was prompting for `tenantId`. The root cause was `infra/main.bicep` declaring `tenantId` as a required parameter with no default. Although `infra/main.parameters.json` mapped it from `${AZURE_TENANT_ID}`, AZD still prompted whenever that environment variable was absent.

## Decision

Resolve the tenant inside Bicep instead of treating it as an operator-supplied input:

- Remove `param tenantId string` from `infra/main.bicep`
- Add `var tenantId = subscription().tenantId` near the top of the file
- Keep passing `tenantId` into `infra/modules/appService.bicep` unchanged
- Remove the `tenantId` parameter block from `infra/main.parameters.json`

## Rationale

- `subscription().tenantId` is available at deployment time and matches the active Azure context used by AZD/Bicep.
- This eliminates unnecessary operator input and prevents AZD from prompting for a value it can already derive.
- The module contract for `infra/modules/appService.bicep` remains intact, so the change stays localized to the entrypoint template.

## Verification

Executed from repo root:

```bash
bicep build infra/main.bicep
```

Result: exit code 0, no errors.
