# CrossPay - Feature Spec Index

**Plan of record**: `MASTER_PROGRESS_REPORT.md` (the 33 items). This index maps
every ID to its spec file and its real state. **"F3.7" was never in the plan -
F3 ends at F3.6.**

| ID | Name | State | Spec |
|----|------|-------|------|
| F1.1 | Scaffold & directory tree | done | - |
| F1.2 | Theme (navy / emerald) | done | - |
| F1.3 | Localization engine (en / sw) | done | - |
| F1.4 | Riverpod state | done | - |
| F1.5 | Network client (Dio, JWT, retry) | done | - |
| F2.1 | Splash & language switcher | done | - |
| F2.2 | Phone entry & carrier suggestion | done | - |
| F2.3 | SMS OTP verification + token storage | done | - |
| F2.4 | Identity & KYC | done | - |
| F3.1 | Home dashboard & converter + 4 tabs | done | - |
| F3.2 | Route selection & rate lock | done | - |
| F3.3 | Recipient details & name check | done | - |
| F3.4 | Payment prompt & manual fallback | done | - |
| F3.5 | Live escrow & queue tracker + support | done | `FEATURE_SPEC/F3/F3.5.md` |
| F3.6 | Digital invoice & share sheet | done | `FEATURE_SPEC/F3/F3.6.md` |
| F4.1 | Searchable ledger, timeline, export, analytics | done (frontend) | `FEATURE_SPEC/F4/F4.1.md` |
| F4.2 | Market depth & queue health | done (frontend) | `FEATURE_SPEC/F4/F4.2.md` |
| F5.1 | Profile & limit bar | done (frontend) | `FEATURE_SPEC/F5/F5.1.md` |
| F5.2 | Saved recipients CRUD | done (frontend) | `FEATURE_SPEC/F5/F5.2.md` |
| F5.3 | PIN lock, language, stay signed in, biometrics | partial (see spec) | `FEATURE_SPEC/F5/F5.3.md` |
| P1 | Preview app (extra, not in the 33) | done | - |
| B1.1 - B2.4 | Backend schema + trade API | not started (no backend in repo) | - |

**State words**
- `done (frontend)` - screen, provider, repository call, contract and tests are
  in place; it renders an honest "not connected" state until the matching
  backend endpoint exists.
- `partial` - part shipped, part blocked (see the spec file for exactly what).

**Blocked, needs a decision or a backend**
| Item | Blocked on |
|------|------------|
| F5.3 biometrics | a `local_auth` dependency decision (none in `pubspec.yaml`) |
| F5.3 stay signed in | `POST /auth/refresh` + a validation call at boot |
| Every "not connected" screen | its backend endpoint (PART 2) |

---

## Report End - No fluff. Just facts.