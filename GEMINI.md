# BigUwidget Project Rules & Guidelines

## 🚨 MANDATORY USER CONSTRAINT

Whenever the user asks to modify, fix, debug, or add features to the usage widgets:
1. **ONLY EDIT BIGUWIDGET**:
   - Every change, UI component, feature, chart, animation, and logic fix MUST be made directly in `/Users/jakubsokolowski/BigUwidget/BigUwidget.swift`.
   - **DO NOT MODIFY** files in:
     - `/Users/jakubsokolowski/agy-usage-widget/`
     - `/Users/jakubsokolowski/grok-usage-widget/`
     - `/Users/jakubsokolowski/grokbot-usage-widget/`
     - `/Users/jakubsokolowski/Library/Application Support/` (do not edit daemon code or config directly)
     - Any other external widget repositories.

2. **BUILD & RUN PROCEDURE**:
   - Compile via `./build.sh` from `/Users/jakubsokolowski/BigUwidget`.
   - Relaunch via `pkill -f "/Applications/BigUwidget.app/Contents/MacOS/BigUwidget" && sleep 0.5 && open /Applications/BigUwidget.app`.
   - Verify active PID via `pgrep -fl BigUwidget`.

3. **SECTION TERMINOLOGY & MAPPING (S1, S2, S3, S4)**:
   - **S1**: **Grok** (Grok 3 Chat, App Builder, Grok Build)
   - **S2**: **Grok Bot** (Grok 3 Bot)
   - **S3**: **AGY** (Gemini Pro/Flash weekly + 5h)
   - **S4**: **Claude & GPT** (Claude 3.7 / 3.5 Sonnet & GPT weekly + 5h)

4. **KEY FEATURES MAINTAINED**:
   - **Blue Quota Progress Bar** (`BlueQuotaProgressBar`): Renders for AGY, Grok Bot, and Grok. Shows `100%` when no intra-week reset occurred, or `100% + X%` if an intra-week reset bonus was gained.
   - **Incoming Vertical Data**: When a new prompt delta drops in, it lights up dynamically in **Green (`#32D74B`) for low usage** or **Orange (`#FF9500`) for high usage** for 1.0s, then smoothly transitions over 0.55s back to the default signature **Cyan (`#24C1E0`)**. 4th item slides off right over 0.68s.
   - **Rolling Wheel Odometer Number Animation** (`RollingWheelNumberView`): Top-left main `% used` numbers smoothly roll up into view from below when increasing, or roll down when resetting.
   - **Interactive Graphs View**: Day (24h), Week (7d), Month (30d) bar charts with 2x larger % digits (14pt Day, 17pt Week, 13pt Month, 26pt HUD Inspector) with hover scrub HUD and session drilldown logs with burst indicators (`⚡`).
