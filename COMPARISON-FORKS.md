# Fork comparison — `EdmundFu-233/ReCasaOS` (current) vs `ReCasaOS/*` org

Assessed 2026-10-07, both at `main` HEAD. Code-read, nothing built.

## Verdict

- **Stay on EdmundFu-233** as base/pin of record.
- **Do not switch** to the `ReCasaOS` org fork; harvest selected features from it (list below).
- Re-assess in ~3 months: both forks are 2–3 months old, single-maintainer, could die or converge.

## Identity

| | EdmundFu-233/ReCasaOS ("EF") | ReCasaOS org ("ORG") |
|---|---|---|
| Lineage | IceWhale `main` (Aug 2025) → EF, started 2026-07 | IceWhale → alvins82 fork (2026-08) → inkly → ReCasaOS org (2026-09) |
| Maintainers | 1 (EdmundFu-233 / Zhihao Fu) | 1 (Gary, ixelia.fr) + alvins82 earlier |
| Focus | security hardening, release integrity | "distribution": features, installer, Debian/Ubuntu UX |
| Repos | 6 (root, gateway, user, appmgmt, msgbus, UI) | 10 (+LocalStorage, Common, Install, `_appstore` mirror) |
| Activity since 2025 | root 345, user 11, appmgmt 12, gw 10, msgbus 5, UI 19 | root 162, appmgmt 217, UI 357, LocalStorage 60, others 28–51 |
| Satellite repos | barely touched; still `IceWhaleTech/*` module paths, Go 1.20/1.21 | all renamed `github.com/ReCasaOS/*`, all Go 1.26, deps bumped |
| Pinning | `release/components.lock.json`, GPG-signed checksums, SLSA, SBOMs | installer pins components by tag + SHA-256; no lock-of-record file |
| UI | Vue 2.7 (EOL), no LICENSE | **Vue 3.5**, dark theme, no LICENSE (same caveat, README says so explicitly) |
| Name clash | both call themselves "ReCasaOS" | |

## Security — decisive axis

| Item | EF | ORG |
|---|---|---|
| Password storage | argon2/bcrypt (`pkg/password`) | **unsalted MD5** (`encryption.GetMD5ByStr`), bcrypt only for 2FA recovery codes |
| First admin | local-only bootstrap oneshots, web register → 410 (our module uses this) | upstream web register-by-key (first visitor on LAN claims admin) |
| Loopback auth bypass | root: default-off; **msgbus/appmgmt still trust `c.RealIP()` == 127.0.0.1** | removed everywhere; per-boot `/var/run/casaos/internal.secret` from gateway, all components |
| Bearer vs bare token | inconsistent across components (we carry 3 patches) | consistent (bare token, upstream-compatible) |
| Public files | separate non-root socket-activated portal, `openat2`, workers | — |
| Threat model / CI | THREAT_MODEL.md, CodeQL, govulncheck, trusted-CI runbook | tests + "no IceWhale string" guard; SECURITY.md still upstream's (`wiki@casaos.io`) |
| Phone-home | none found | **PostHog telemetry, opt-out (on by default)**, 3-hourly heartbeat |
| Self-update | stubbed out | live updater → `curl installer \| /bin/bash` as root; **nightly auto-update** (opt-in); apt package updates from dashboard |
| AppMgmt attack surface | upstream-sized | + git-deployed apps: host `git` + builds, **unauthenticated webhook route** (HMAC-signed) |
| LocalStorage | not shipped | shipped; still `source helper.sh; UDEVILUmount <path>` string concat, mergerfs, `/etc/fstab`, devmon |

Net: EF = sound auth core, weak satellites. ORG = sound satellites, weak auth core + more to strip.
Fixing ORG's auth core (MD5 migration, bootstrap) is bigger and riskier than porting ORG's internal-secret scheme to EF's satellites.

## Guardrail cost (T9 strip surface) if switching to ORG

- extra routes to cut: `POST /v1/sys/update` (functional, not stub), `/v1/sys/packages*` (apt), `/v1/sys/telemetry`, `/v1/sys/autoupdate`, `/v1/sys/stop`
- telemetry goroutine + UI consent/preview + installer hook
- `casaos-local-storage` + `-first` units (or keep not shipping → same as today)
- AppMgmt git-app machinery (host git, builds, webhook) — or accept and review
- `casaos-wsdd.service`, `smb-discovery.sh` (replace by Nix-native, see below)
- UI: update, package-update, telemetry, autoupdate affordances

## Harvest from ORG into the EF-based build

Priority = value for appliance ÷ effort. "Upstream" = propose to EF first, carry as patch meanwhile.

| # | Feature (ORG) | Where | How for us | Prio |
|---|---|---|---|---|
| 1 | internal-secret service auth, loopback ≠ identity | Gateway, Common `external/internal_auth.go`, all services | port to EF msgbus/appmgmt; upstream to EF. Kills RealIP trust (XFF-spoof class, CVE-2023-37265-like) | **high** |
| 2 | systemd power actions (`systemctl poweroff/reboot`, errors propagated) | root `service/system.go` | replaces our open `init 0/6` finding | **high** |
| 3 | Samba: account-restricted shares, `map to guest = never`, testparm + rollback, share-path confinement, dup-name fix | root `service/shares*.go`, `samba_user.go` | fits our generate→validate→reload hot-state pattern; needs `smbpasswd` on unit `path` | high |
| 4 | Time Machine shares (`vfs_fruit`) | root shares | needs `samba` w/ vfs modules in closure (cold) | med |
| 5 | SMB discovery (mDNS + wsdd, no SMB1) | root `smb-discovery.sh`, `casaos-wsdd.service` | **don't port code** — `services.samba-wsdd` + `services.avahi` in Nix (cold layer) | med (cheap) |
| 6 | Gateway HTTPS w/ supplied cert | Gateway | cert path on state partition; or skip, terminate TLS in Caddy/nginx module | med |
| 7 | 2FA (TOTP + bcrypt recovery codes, CAS writes) | UserService + UI | port onto EF user-service (EF has argon2 already) | med |
| 8 | Compose editor w/ validation, per-container stack view, per-service update decisions, scheduled image-update checks, logs/terminal | AppMgmt + UI | large; wait for EF or rebase AppMgmt on ORG (see option B) | med |
| 9 | Push alerts via Shoutrrr (disk, events, deduped) | root `alerts`, UI `AlertsModal` | useful for NAS (disk health); drop the "new release" source | low–med |
| 10 | `_appstore` nightly mirror | ORG `_appstore` | point app-management store URL at a mirror we control (vendor-owned) | med |
| 11 | Vue 3 UI + dark theme | UI | not portable piecemeal; only via option B | low (now) |
| 12 | Go 1.26 + dep bumps, module renames in satellites | all | upstream pressure on EF; until then our build may bump `go` in derivations | low |
| 13 | token-free access log, start.d after sd_notify, signing key survives user-service restart | root, Common | small patches | low |

Not taken: telemetry, auto-update, apt updates, installer, LocalStorage, mergerfs, git-deployed apps (re-evaluate when app story is defined).

## Option B (hybrid) — only if EF satellites stall

- root + user-service: EF (auth core, bootstrap, portal)
- gateway, msgbus, appmgmt, Common: ORG
- UI: ORG (Vue 3) + our patches
- blockers: module path split (`IceWhaleTech/*` vs `ReCasaOS/*` imports of Common/codegen), internal-secret must be added to EF root/user-service, UI ↔ EF-root API drift (2FA, alerts, telemetry routes absent → UI must tolerate 404s), no single lock-of-record → T7 needs new source
- cost: high; benefit: ORG's appmgmt/UI work. Not now.

## Own additions replaceable by ORG upstream (if we switched)

| Our addition | Replaced? | Note |
|---|---|---|
| `recasaos-message-bus/patches/0001-accept-bearer-authorization` | **yes** | ORG consistent token scheme |
| `recasaos-app-management/patches/0001-accept-bearer-authorization` | **yes** | idem |
| `casaos-ui/patches/0003-send-bearer-authorization` | **yes** | idem |
| `recasaos-user-service/patches/0001-drop-local-storage-listener` | **no** | ORG still subscribes to `local-storage`; we don't ship LocalStorage → patch stays |
| finding: `init 0/6` power actions | **yes** | ORG systemd targets |
| finding: msgbus loopback auth relies on gateway XFF overwrite | **yes** | ORG internal secret |
| `recasaos/patches/0003-bash-from-path` | **no — grows** | `/bin/bash` still hardcoded in Common `command.go` + new call sites (`system.go`, `system_package.go`) |
| `recasaos/patches/0001-disable-host-management-routes` | **no — grows** | more routes to cut (above) |
| `recasaos/patches/0002-helper-strip-host-management` | no | helper.sh still present |
| `casaos-ui/patches/0001-disable-self-update` | **no — grows** | + package update, telemetry, autoupdate UI |
| `casaos-ui/patches/0004-storage-panel-finally-typo` | check | UI rewritten for Vue 3 |
| `recasanix-storage` | **no** | ORG LocalStorage: still ext4/mergerfs, shell concat, fstab/devmon, no btrfs. Keep ours; add `PUT /v1/storage/rename` (ORG UI calls it) → 501 or implement via `btrfs filesystem label` |
| local admin bootstrap integration (`recasaos-user-*` oneshots) | **lost** | ORG has no equivalent → regression |
| public-files portal | **lost** | ORG has none |
| T7 pin-drift via `components.lock.json` | **lost** | ORG has no lock-of-record; would need installer manifest parsing |

## Actions (proposed, not done)

1. Keep `recasaos` input = EF. No change to AGENTS.md §2 pinning decision.
2. Patch EF msgbus/appmgmt: internal-secret auth (#1) + open issue/PR at EF.
3. Patch root power actions → `systemctl` (#2); close the finding in `nix/lib/exclusions.nix`.
4. SMB discovery via `services.samba-wsdd` + avahi (#5) when SMB scope is decided (task 3.1/3.2 TODO).
5. App-store mirror under our control (#10) → Phase 6.
6. Watch ORG for: MD5 → argon2 migration, local bootstrap. If both land → re-run this comparison.

## PR series to EF (status 2026-10-07)

Branches local in `~/devel/github.com/ppenguin/ReCasaOS-EF/<repo>-EF` (forks `ppenguin/<repo>-EF`), not pushed. Carried here as patches until merged (AGENTS.md §5). Verified: Go unit tests red→green per commit; VM check `service-auth` (T12).

| Order | Repo | Branch | Content | Needs | Harvest # |
|---|---|---|---|---|---|
| 1 | MessageBus | `fix/unix-socket-identity` | unix-socket exemption from the connection (`LocalAddrContextKey`), not `Host: unix`; socket `0600` | — | 1 |
| 2a | ReCasaOS | `feat/message-bus-service-credential` | `gatewayclient` service-credential helpers; msgbus client sends `gateway.token` | — | 1 |
| 2b | UserService | `feat/message-bus-service-credential` | same | — | 1 |
| 2c | AppManagement | `feat/message-bus-service-credential` | same | — | 1 |
| 2d | UI | `feat/message-bus-service-credential` | `register-ui-events.sh` sends the credential (via fd, not argv) | — | 1 |
| 3 | MessageBus | `fix/loopback-needs-service-credential` | loopback skips JWT only with the credential | 1 (stacked), 2a–2d merged | 1 |
| 4 | AppManagement | `fix/loopback-needs-service-credential` | same, v1 + v2 | 2c (stacked) | 1 |
| — | ReCasaOS | `fix/systemd-power-actions` | `systemctl --no-block reboot\|poweroff`, failures → 500 (ported, credited alvins82) | — | 2 |
| — | MessageBus | `fix/subscriptions-before-start` | startup races: subscription made before `Start` wiped (YSK cards stop updating), publish before `Start` → nil-ctx panic; ysk tests poll instead of sleeping (flaked under `nix flake check`) | — (put first: carried as 0002–0003) | — |
| — | UI | `chore/remove-upstream-community-links` | drop IceWhale Discord/GitHub/feedback/share/wiki/awesome links; drop blog news feed (sent `baseinfo.conf` device ids to `blog-casaos.zimaspace.com`) | — | — |
| T-1 | MessageBus | `feat/subscription-tickets` | `POST /v2/message_bus/ticket` → one-use, 30 s, user+UA-bound, HttpOnly, SameSite=Strict, path-scoped cookie redeemed by the WebSocket handshake (EF's SSH-terminal pattern); exemption kept | 3 (stacked) | — |
| T-2 | UI | `feat/bus-subscription-ticket` | socket.io: websocket-only, fetch a ticket before every (re)connect | T-1 deployed | — |
| T-3 | MessageBus | `fix/subscriptions-need-a-ticket` | remove the unauthenticated WebSocket exemption | T-1 (stacked), T-2 merged | — |
| S-A | ReCasaOS | `feat/samba-external-main-config` | `[server] SambaMainConfig = external`: main smb.conf owned by the host (never read/written; NixOS symlink broke every share op), only `smb.casa.conf` managed; reconcile checks the include | — | 3 |
| S-B | ReCasaOS | `feat/samba-share-accounts` | share accounts (`/v1/samba/users`, nologin, GECOS marker, stdin passwords), per-share `valid users` + `force user`, directory handed to the account via pinned-root fchown (ported from ORG 5a7c55c/20df217) | S-A (stacked) | 3 |
| S-C0 | UI | `fix/shares-never-anonymous` | all three share entry points posted `anonymous: true`, which the root service refuses → sharing from the dashboard always failed | — | 3 |
| S-C | UI | `feat/share-accounts-ui` | Share accounts dialog (ported from ORG), "who may open this folder" on Share and a new "Access" item (adapted: no guest/Time Machine) | S-C0 (stacked); S-B deployed | 3 |

- Design: reuses EF's existing per-start `gateway.token` (gateway management API already requires it) instead of ORG's new `internal.secret` → no new file/scheme upstream.
- **#1 is a security fix with a confirmed exploit** on pinned upstream (LAN client + `Host: unix` through the gateway → 200, full bus API). Pre-alpha everywhere → plain public PR (owner decision 2026-10-07).
- Websocket subscriptions: T-1..T-3 (tickets instead of URL tokens, which EF refuses). Not in series: our Bearer-acceptance patches (msgbus, appmgmt, UI) → separate PRs, todo.
- Harvest #3 (Samba account shares): S-A, S-B, S-C0, S-C done, verified by T13 (backend, smbclient) and T14 (browser). Open: EF's *managed* main template still has `map to guest = bad user` (a refused login is denied instead of prompted) → follow-up PR, needs a managed-template migration. EF UI drops the whole app grid (built-in Files included) when the app-grid request fails → follow-up PR.

### Open upstream PRs (2026-10-07)

- MessageBus startup races: https://github.com/EdmundFu-233/ReCasaOS-MessageBus/pull/3
- MessageBus unix-socket identity (Host: unix): https://github.com/EdmundFu-233/ReCasaOS-MessageBus/pull/4
- ReCasaOS service credential: https://github.com/EdmundFu-233/ReCasaOS/pull/151
- UserService service credential: https://github.com/EdmundFu-233/ReCasaOS-UserService/pull/19
- AppManagement service credential: https://github.com/EdmundFu-233/ReCasaOS-AppManagement/pull/5
- UI register-ui-events credential: https://github.com/EdmundFu-233/ReCasaOS-UI/pull/6
- MessageBus loopback needs credential: https://github.com/EdmundFu-233/ReCasaOS-MessageBus/pull/5
- AppManagement loopback needs credential: https://github.com/EdmundFu-233/ReCasaOS-AppManagement/pull/6
- ReCasaOS power actions: https://github.com/EdmundFu-233/ReCasaOS/pull/152
- UI drop IceWhale links / news feed: https://github.com/EdmundFu-233/ReCasaOS-UI/pull/7
- S-A include-only mode: https://github.com/EdmundFu-233/ReCasaOS/pull/153
- S-B share accounts: https://github.com/EdmundFu-233/ReCasaOS/pull/154
- S-C0 shares never anonymous: https://github.com/EdmundFu-233/ReCasaOS-UI/pull/8
- S-C share accounts UI: https://github.com/EdmundFu-233/ReCasaOS-UI/pull/9
- T-1 subscription tickets: https://github.com/EdmundFu-233/ReCasaOS-MessageBus/pull/6
- T-2 UI ticket: https://github.com/EdmundFu-233/ReCasaOS-UI/pull/10
- T-3 subscriptions need a ticket: https://github.com/EdmundFu-233/ReCasaOS-MessageBus/pull/7
