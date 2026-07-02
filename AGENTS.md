# GrowGuard — iOS Smart Plant Monitor

An iOS app that monitors plants via **Xiaomi FlowerCare BLE sensors**. It reads moisture, light, and soil data, shows charts over time, and fetches readings in the background via Siri Intents / background tasks.

## Tech Stack

- **Swift / SwiftUI** — iOS 17+
- **Xcode project** at `GrowGuard.xcodeproj` (build & run from here)
- **CoreBluetooth** — BLE communication with Xiaomi FlowerCare sensors
- **Core Data** — persistent storage for devices, sensor readings, pot sizes
- **SQLite** (`flower.db`) — bundled plant species lookup database
- **SwiftData** (via `DataService`) — main data context management
- **Combine** — reactive data flow (publishers/subscribers)
- **SwiftGen + Localizable.strings** — type-safe localization via `L10n.*`

## Architecture

### Layered MVVM

```
UI (SwiftUI Views)
  ↓
ViewModels (@Observable classes)
  ↓
Services (singletons: BackgroundBLEWakeService, PlantMonitorService, etc.)
  ↓
Repositories (interface-based, backed by Core Data or SQLite)
  ↓
DTOs (plain structs: FlowerDeviceDTO, SensorDataDTO, OptimalRangeDTO, PotSizeDTO)
  ↓
Hardware (BLE via ConnectionPoolManager + DeviceConnection)
```

- **RepositoryManager** (`Database/RepositoryManager.swift`) is the singleton DI hub — all ViewModels get repos through it.
- **Data flow:** Hardware → BLE → Repositories → DTOs → ViewModels → Views
- Never access Core Data directly from Views or ViewModels — always go through repositories.

### Key Directories

| Folder | Purpose |
|--------|---------|
| `GrowGuard/BLE/` | BLE logic — `ConnectionPoolManager` (multi-device orchestration), `DeviceConnection` (per-device session), `BLETransport`/`CoreBluetoothTransport` (protocol seam), `ReconnectPolicy`/`DisconnectLoopGuard` (reliability), `BLESessionRecorder`/`RecordingBLETransport` (opt-in traffic recording), `SensorDataDecoder` |
| `GrowGuard/Database/` | Core Data models, repository interfaces + implementations, DTOs, SQLite flower search, SwiftData service |
| `GrowGuard/Services/` | Background fetch, weekly updates, history loading, API client |
| `GrowGuard/OverviewList/` | Main device list view + ViewModel |
| `GrowGuard/DeviceDetails/` | Detail view, charts, settings, history, manual watering |
| `GrowGuard/AddDevice/` | BLE scanning / device pairing flow |
| `GrowGuard/AppSettings/` | App-wide settings UI + store |
| `GrowGuard/Strings/` | `Localizable.strings` + SwiftGen-generated `Strings+Generated.swift` — always use `L10n.*` for UI strings |
| `GrowGuard/Utils/` | Shared helpers, logging |
| `GrowGuardWidgets/` | Widget extension + Live Activity |

## Conventions

- **Localization:** Use `L10n.KeyName` everywhere in UI — never hard-code strings. Regenerate with `swiftgen` after editing `Localizable.strings`.
- **DTOs:** Plain structs in `Database/DTOs/`. All DTOs are `Identifiable`, `Hashable`.
- **Repositories:** Define protocol in `Database/Repositories/`, implement as `CoreData*` classes. Inject via `RepositoryManager.shared.*`.
- **Singletons:** Services use `static let shared`. ViewModels are created per-view (not singletons).
- **Combine:** BLE services emit via `PassthroughSubject` → `AnyPublisher`. ViewModels subscribe and store in `cancellables: Set<AnyCancellable>`.
- **Background tasks:** arm-don't-fetch (spec `docs/superpowers/specs/2026-06-12-background-ble-design.md`): triggers (BGAppRefreshTask, silent push, enter-background) only arm pending connects via `ConnectionPoolManager.armBackgroundConnect`; `BackgroundBLEWakeService` does the live read + dry-plant check on the BLE wake. `BackgroundHistorySyncService` runs history sync inside BGProcessingTask windows.

## BLE Testing & Record/Replay

- **One BLE stack:** `ConnectionPoolManager` + `DeviceConnection` on the `BLETransport` protocol seam. The legacy `FlowerCareManager` was deleted (2026-06); there is no feature flag anymore.
- **Deterministic tests:** `GrowGuardTests/BLE/` has `FakeBLETransport` (TestScheduler with virtual time + scriptable `FakeFlowerCarePeripheral`). No real waits in unit tests.
- **Record/replay:** Beta testers enable "Record BLE Sessions" in the debug menu (`LogExportView`); traffic is captured at the transport seam and exported as `*.ble-session.json` via share sheet. To turn a recording into a regression test: drop the file into `GrowGuardTests/BLE/Recordings/` (bundled automatically — folder reference) and add one entry to `ReplayFixtures.all` in `ReplaySessionTests.swift` with the expected outcome. The generic runner matches the app's outbound traffic against the recording; divergence fails the test.
- **Reliability invariants** (see `BLE-Reliability.md`): reason-aware reconnect backoff (`ReconnectPolicy`), disconnect-loop guard (5 no-progress drops / 120s → abort), per-entry response timeout 2s with ≤2 retries then skip (budget `max(20, total/20)`), history sync resumes at the exact entry index after reconnects.
- **Performance budgets:** `BLEPerformanceTests` asserts traffic counts and virtual-time budgets derived from the protocol constants (0.02s inter-entry delay, 0.05s batch pause per 150 entries). If you change those constants, update the budgets deliberately.

## Goals — Ship to Production

We're preparing GrowGuard for App Store launch. 
Any new feature or refactor should respect the existing architecture (MVVM + Repository pattern) and not break BLE stability.

## Common Commands

- **Build (CI/agent):** `xcodebuild -project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build`
- **Unit tests (CI/agent):** `xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60` — runs the unit suite; hardware-dependent BLE tests are excluded. Keep the timeout flags: some legacy tests can hang indefinitely on publisher waits without them.
- **Hardware BLE tests:** `xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan HardwareTests -destination 'platform=iOS,name=<your iPhone>' TEST_FLOWERCARE_UUID=<peripheral-uuid>` — requires a real FlowerCare sensor in range; tests skip themselves if the env var is missing.
- **Quick build (quiet):** add `-quiet` flag — only errors/warnings shown
- **Clean build:** add `clean` before `build`
- **Regenerate strings:** `swiftgen` (runs `swiftgen.yml` config)
- **Migrate flower DB to Supabase:** `python Scripts/migrate_flower_db_to_supabase.py --sqlite-path GrowGuard/flower.db --recreate`

### Build Notes
- **Shared scheme** at `GrowGuard.xcodeproj/xcshareddata/xcschemes/GrowGuard.xcscheme` references the test plans (`GrowGuard.xctestplan` = unit tests, `HardwareTests.xctestplan` = real-sensor tests). Always use `-scheme GrowGuard`.
- **No iPhone 16 simulator.** Available simulators on this machine (as of 2026-05-15): iPhone 17, iPhone 17 Pro, iPhone 17 Pro Max, iPhone 17e, iPhone Air, iPad Air 11-inch (M4), iPad Air 13-inch (M4), iPad Pro 11-inch (M5), iPad Pro 13-inch (M5), iPad mini (A17 Pro), iPad (A16). Use iPhone 17 as default.
- Run `xcrun simctl list devices available 2>/dev/null` if simulator lineup changes.
- **Known non-blocking warnings:** (1) Widget `CFBundleVersion` mismatch, (2) "Update Build Number" script runs every build. Do not treat these as build failures.
- **Tool:** Use `xcodebuild` directly. No MCP xcode tool is available.

## 🛠 Subagent Usage Patterns

### Parallel Mode — For Independent File Operations
Use `parallel` when tasks read/write **disjoint files** with no dependencies on each other's output. Executes multiple independent tasks concurrently (default: 4 concurrent, respect system limits).

**✅ When to use parallel:**
- Reading multiple files for context (no writes needed)
- Writing/readings unrelated files
- Running independent build/test commands with different flags
- Compiling multiple targets that don't depend on each other

**❌ When NOT to use parallel:**
- Tasks where one step's output feeds the next (that requires CHAIN mode)
- Shared state or mutable files being modified simultaneously
- Tasks with file conflicts (use `worktree: true` to isolate)

**Example:**
```json
{
  "mode": "parallel",
  "tasks": [
    {"agent": "scout", "task": "Scan BLE directory for connection-related files", "reads": ["README.md", "KONZEPT_Multi_Sensor.md"]},
    {"agent": "scout", "task": "Scan Database directory for DTO and Repository files", "reads": []},
    {"agent": "scout", "task": "Scan Services directory for background fetch implementation", "reads": []}
  ],
  "concurrency": 4
}
```

### CHAIN Mode — For Sequential Dependencies
Use `chain` when tasks have **sequential dependencies** where later steps need output from earlier steps. Each step receives `{previous}` (prior step's text) and operates in `{chain_dir}`.

**✅ When to use chain:**
- Planning → Execution (plan.md → implement based on plan)
- Context gathering → Analysis → Solution
- Review stages: gather context → identify issues → propose fixes

**❌ When NOT to use chain:**
- Tasks that can run independently (use parallel)
- Simple single-task operations
- Scenarios where intermediate state isn't needed

**Example (connection pool implementation):**
```json
{
  "mode": "chain",
  "steps": [
    {
      "agent": "scout",
      "task": "Map existing connection-related files and BLE architecture"
    },
    {
      "agent": "planner",
      "task": "Create implementation plan for the BLE change based on {previous}. Output to Handoff/connection-pool-plan.md"
    },
    {
      "agent": "worker",
      "task": "Implement migration per plan. Read {chain_dir}/plan.md for specifics, {previous} for high-level guidance"
    },
    {
      "agent": "reviewer",
      "task": "Review implementation against plan and architecture. Provide critique and suggestions"
    }
  ]
}
```

### Agent Configuration Tips
- **Default context:** Set `defaultContext: "fork"` on agents that need isolation (e.g., multiple concurrent scans or test runs). Default is `"fresh"`.
- **Reads:** Always specify relevant files in `reads` to load context before the task runs. Use `grep -rn "pattern"` externally first to avoid reading unnecessary files.
- **Output:** Use `outputMode: "file-only"` when you need consistent artifacts in a directory, and reference those files later.
- **Skill injection:** Use `skill: ["your-skill"]` to inject specialized skills to the agent.
- **For complex operations:** Use `worktree: true` with parallel tasks that may conflict (isolates each task in a git worktree).

### Quick Reference
| Mode | When | How |
|------|------|-----|
| **Single** | One self-contained task, no dependencies | `subagent({ agent: "worker", task: "Fix typo in X.swift" })` |
| **Parallel** | Independent tasks with no output dependency | `subagent({ mode: "parallel", tasks: [{agent:"a",...}, {agent:"b",...}] }, concurrency: 4)` |
| **Chain** | Sequential steps where each depends on the previous output | `subagent({ mode: "chain", steps: [{agent:"a",task:"..."}, {agent:"b",task:"Review {previous}"] })` |

### Verification Strategy
- **Micro tasks:** Compile check only if relevant to build artifacts.
- **Small tasks:** Build + quick test (compile first).
- **Medium/Large tasks:** Happy path + edge cases (disconnected devices, empty inputs).
- **Always verify** before declaring complete.

## ⚡ Speed Principles

*   **Read what you'll change, not the whole codebase.** Use the project `AGENTS.md` directory map to know where to look.
*   **Grepping > Reading.** `grep -rn "pattern" Path/` is faster than opening every file hoping it's relevant.
*   **Edit > Rewrite.** Prefer surgical `edit` calls with small `oldText` matches. Only `write` for brand-new files or complete rewrites.
*   **Parallel > Sequential.** Read unrelated files simultaneously. Edit different files simultaneously.
*   **Trust the plan.** Once the plan is written in `Handoff/`, follow it. Don't drift into "while I'm here..." refactors.
