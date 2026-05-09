# Orchestration: Coordinator Directive — Slot Assignment Locked

**Date:** 2026-05-09T04:11:47Z  
**Directive:** Round 5 Slot Assignment Capture  
**Context:** Post-coordinator decision refinement

## Directive Resolution

**Coordinator Decision:** Testing approach + production slot assignment  
**Status:** ✅ LOCKED

### Assignment

- **production=repro** (locked)
- **Local client testing:** Phases 1-2 (FastMCP RS server + test client on localhost)
- **CI/CD validation:** Deferred to Phase 3+ (after local validation)

### Rationale

1. RS-mode architecture requires token validation — local repro safer
2. Holden's fix + Naomi's FastMCP RS build both complete and tested
3. Amos provision script ready for both CI/CD + manual flows
4. Coordinator decision prevents premature CI/CD exposure

### Locked Constraints

- No Azure Resource Group provisioning until Phase 3
- Local testing with mock Entra tokens (JWT generation)
- Redirect URI validation against localhost + 127.0.0.1 variants

---

## Documentation

**Captured in:** `.squad/decisions/inbox/coordinator-slot-assignment.md`

---

## Next Steps

1. **Scribe task 4:** Session log entry (this batch)
2. **Scribe task 7:** Git commit (stage scripts + log entries)
3. **Holden / Naomi:** Resume Phase 1 with local repro validation
