# RFF — Request of Funds

A macOS app that runs the whole money-paperwork loop for a small consultancy:
incoming bills are caught, classified by on-device AI, filed and tracked until paid;
outgoing invoices are generated on schedule; and on the 12th of each month the
accountant report is one click away. Everything is visible at a glance from a dense,
teenage-engineering-inspired menu bar dashboard.

> Vibe-coded with Claude. Absorbed the former
> [invoice-monitor](https://github.com/mandrigin/invoice-monitor) (InvoiceFiler) app —
> one app instead of two, configs inherited automatically.

## What it does

### 📥 Library (inbound bills)
- SwiftData-backed document library with tabs: **Inbox · Confirmed · Paid · Reporting**
  (opens on Confirmed; Inbox shows a `● Inbox N` badge when something is waiting)
- PDF/image import via drag & drop, file picker, or pasted text; OCR via the Vision
  framework with a financial-domain custom vocabulary (EN/DE/SV terms)
- Entity extraction (organization, amount, currency, due date) + optional per-vendor
  extraction schemas with a visual schema editor
- Status flow: pending → under review → approved → completed/paid, with deadline
  notifications (snooze / mark complete from the notification)
- Paid badges are tinted by lateness: green = on time, sliding to orange the later it
  was paid (hover for exact days); overdue warnings disappear once paid

### 👀 Folder monitoring (inherited from InvoiceFiler)
- Watches folders (default `~/Downloads`) via FSEvents with debounce + stability checks
- Extracts text (PDFKit, falling back to Vision OCR for scans), classifies, matches
  against your companies (names/aliases/tax IDs/domains/fuzzy), extracts the invoice date
- Files processed invoices into a **flat archive** (`~/Documents/Invoices/Archive`),
  keeping the original filename plus a nanosecond timestamp
  (`tele2-invoice-20260611-133316.419280000.pdf`) — the app database is the source of
  truth for reporting, so no more per-month folder curation
  (the legacy `invoices-MM-YYYY` mode is still available as a toggle)
- Filed invoices are auto-imported into the Library (deduplicated), so monitoring and
  tracking are one pipeline

### 🤖 AI classification cascade
1. **Apple Intelligence** (macOS 26 FoundationModels, guided generation) decides clear
   cases on-device: invoice confidence + organizations mentioned
2. The uncertain band (25–80 % confidence) gets a second opinion from **local Ollama**
   (auto-picks the largest installed model; override in Settings)
3. Still uncertain → the **Needs Review** queue: QuickLook preview, AI verdicts,
   one-click *Confirm Invoice & File* / *Not an Invoice* (decisions are remembered)
4. No AI available → keyword/structure heuristics as a last resort

Organization names extracted by the AI also feed company matching as a second signal.

### 📤 Outbound invoices
- Reusable templates per client: line items, currency (17 supported), payment terms,
  billing day of month
- Drafts are generated automatically on schedule; due dates avoid weekends and bank
  holidays in *both* countries (Nager.Date API, cached)
- **Bank details** (account holder, bank, IBAN, BIC) are printed on every invoice in a
  PAYMENT DETAILS block; the payment reference defaults to the invoice number
- Draft workflow: pending → approved → sent, with PDF export (US Letter)

### 🧾 Reporting (the every-12th accountant report)
- The **Reporting** tab builds the monthly report from the database:
  - **Outbound**: invoices you sent, selected by *due date* in the month
  - **Inbound**: bills, selected by *paid date* in the month
- Multi-select currency filter chips; per-currency totals per section
- **Export Files** stages everything in a temp folder and opens it in Finder — inbound
  PDFs copied, outbound PDFs re-rendered, all named for accountants:
  `IN 2026-05-07 Tele2 449.00 SEK.pdf`, `OUT 2026-05-25 INV-202605-001 Gateway.fm 23500 CHF.pdf`
- A quiet notification on the 12th at 09:00 carries live counts

### 🎛 Menu bar dashboard (KO-II style)
Always-on badge with live numbers — each segment appears only when it matters:

| Segment | Meaning |
|---|---|
| ● (green/amber/red/gray) | watching / processing / error / stopped |
| `3` (white) | invoices filed today |
| `?2` (amber) | documents in Needs Review |
| `D1` (teal) | outbound drafts awaiting approval |
| `R2` (amber/red) | days until the 12th — shown only within 3 days |

Click it for the dense panel: the badge itself magnified with PCB-trace callouts to
live explanations (Liquid Glass capsules on macOS 26), counter grid
(TODAY / 24H / QUEUE / DRAFTS / PAID·M), report countdown with IN/OUT counts, AI
status LEDs, inline review approvals, pending drafts, and navigation
(LIBRARY · REVIEW · OUTBOUND · REPORT · START/STOP · QUIT).

There's also a **Go** menu: Library ⌘1, Needs Review ⌘2, Outbound Invoices ⌘3,
Reporting ⌘4, Archive folder ⌘5.

### ✨ AI document analysis (in the editor)
Three providers for field extraction, selectable in Settings → AI:
- **Apple Intelligence** — on-device, free, private (macOS 26+)
- **Ollama** — local server, auto-selects the best installed model, no API key
- **Claude** — Anthropic API key, or falls back to the Claude Code CLI when installed

## Data & configuration

| What | Where |
|---|---|
| Document library (SwiftData) + managed files | `~/Library/Application Support/RFF/` |
| Monitoring config | `~/Library/Application Support/RFF/monitoring.json` |
| Review queue + decisions | `~/Library/Application Support/RFF/review-queue.json` |
| Invoice templates / drafts / sequence | `~/Library/Application Support/RFF/Invoices/` |
| Bank holiday cache | `~/Library/Application Support/RFF/Cache/` |
| Move log (JSONL, rotated) | `~/Library/Logs/RFF/moves.jsonl` |
| Filed invoice archive | `~/Documents/Invoices/Archive/` |

On first launch, an existing InvoiceFiler installation
(`~/Library/Application Support/InvoiceFiler/`) is inherited automatically — config,
companies, templates, drafts, holiday cache, and move-log history. Originals are left
untouched. Remember to remove the old app from Login Items.

## Building

Open `RFF/RFF.xcodeproj` in Xcode and build the `RFF` scheme. No external dependencies.

- macOS 14+ to run; macOS 26+ for the Apple Intelligence features
- The app runs **non-sandboxed** (required for FSEvents folder watching)
- Ollama features expect a local server at `127.0.0.1:11434`
- New source files must be added to `project.pbxproj` explicitly (no folder sync)

## tools/

Standalone CLI experiments; build each with `swift build -c release` inside its folder.

- **`ls-isinvoice`** — point it at a folder (`ls-isinvoice ~/Downloads`) and it
  classifies every PDF/image/txt with on-device Apple Intelligence, printing invoice
  confidence and the organizations mentioned.
- **`ls-explain`** — explains every file in a folder using local Ollama
  (`ls-explain [--model qwen3:32b] ~/Downloads`): what the file is (from extracted
  content) and where it came from — read from macOS provenance metadata
  (`kMDItemWhereFroms` download URLs and the quarantine agent), never invented.
  Files without provenance are reported as locally created, by code, not by the model.

## License

Personal project of [@mandrigin](https://github.com/mandrigin).
