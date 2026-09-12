# BigUwidget Project Rules & Guidelines

## 🚨 MANDATORY USER CONSTRAINTS & VERSIONING RULES

1. **VERSIONING ON GIT UPDATES**:
   - **ALWAYS increment / bump the version** whenever pushing an update to git.
   - Update `package.json`, `updater.js`, `renderer.js`, and `latest.json` with the new version and release notes.

2. **PLATFORM SPECIFIC GUIDELINES**:
   - **Mac**: Modifications to Mac widget components, animations, and charts are made directly in `BigUwidget.swift`.
   - **Linux & Electron**: Changes to Linux/cross-platform widget reside in `Linux/` / `electron/` (`src/tracker.js`, `src/main.js`, `src/renderer.js`, `src/styles.css`). Ensure real daily-usage (`daily-usage.json`) and session deltas (`session-deltas.json`) tracking are maintained.

3. **SECTION TERMINOLOGY & MAPPING (S1, S2, S3, S4)**:
   - **S1**: **Grok** (Grok 3 Chat, App Builder, Grok Build)
   - **S2**: **Grok Bot** (Grok 3 Bot)
   - **S3**: **AGY** (Gemini Pro/Flash weekly + 5h)
   - **S4**: **Claude & GPT** (Claude 3.7 / 3.5 Sonnet & GPT weekly + 5h)

4. **KEY FEATURES MAINTAINED**:
   - **Blue Quota Progress Bar** (`BlueQuotaProgressBar`): Renders for AGY, Grok Bot, and Grok. Shows `100%` when no intra-week reset occurred, or `100% + X%` if an intra-week reset bonus was gained.
   - **Incoming Vertical Data**: When a new prompt delta drops in, it displays recent consumption tags with timestamps (`14m +0.70%`, etc.).
   - **Real Calendar Weekly Breakdown**: Monday to Sunday usage with today indicator and reset weekday indicator.
   - **Window Position Persistence**: Automatically saves and restores exact desktop position on launch.
