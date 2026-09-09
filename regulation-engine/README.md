# Compliance Server — D (API) + E (dashboard) + F (reports)

Express + MongoDB server for the offline-first Flutter inspection app.
The app scans and rule-checks fully on-device, then copies each finished
report here (`POST /api/scans`). This server is the shared record:
enforcement dashboard, archival PDFs and the Excel sheet.

Contract (frozen field names / rule codes / CSV order):
`../App/complience_app/docs/backend_api_contract.md`

## Quick start (local)

```bash
cp .env.example .env        # set MONGO_URI + JWT_SECRET
npm install
npm run seed                # LM-R6-* catalog + officer@gov.in / admin@gov.in
npm run dev                 # http://localhost:5000, dashboard at /dashboard
```

Seeded accounts: `officer@gov.in / officer123`, `admin@gov.in / admin123`
(change after first login; passwords via `SEED_*_PASSWORD` in `.env`).

## Run anywhere with Docker (recommended for moving machines)

Prerequisites on the new device: Docker + this folder + your `.env` values
(`MONGO_URI`, `JWT_SECRET`, `BASE_URL` — `.env` never travels with git, so
copy the three lines over). No Node, no MongoDB, no `npm install` needed.

```bash
docker compose up -d --build   # API on :5000, dashboard at /dashboard
docker compose logs -f api     # watch; expect "MongoDB connected successfully"
docker compose exec api npm run seed   # first time on a fresh database only
docker compose down            # stop (data stays in Atlas + ./uploads)
```

Variants: `docker compose --profile local up -d --build` adds a throwaway
local Mongo instead of Atlas (set `MONGO_URI=mongodb://mongo:27017/compliance`
in `.env` first). `docker compose --profile tunnel up -d` serves the API
through your named Cloudflare tunnel from inside Docker (needs
`~/.cloudflared/` from `cloudflared tunnel login`). Rebuild the app APK (or
retype Server URL in-app) only when the public address itself changes.

## Endpoints

| Method | Path | What |
|---|---|---|
| GET | `/` | Homepage for browsers, health JSON for API clients (content negotiation) |
| GET | `/dashboard` | Enforcement web register (static, no build step) |
|---|---|---|
| POST | `/api/auth/login` | `{email,password}` → `{token,user}` (JWT, 12h) |
| POST | `/api/auth/register` | Bootstrap-open when zero users exist, else admin-only |
| POST | `/api/scans` | Multipart `photos[]` (≤8) + `productName, category, reportJson, ocrText, capturedAt, gpsLat/Lng` → `{id,verdict,score,corrected}` |
| GET | `/api/scans?q=&verdict=&category=&page=&limit=` | Shared repository / search |
| GET | `/api/scans/:id` | Full detail (report JSON + image URLs) |
| GET/POST | `/api/regulations` | Rule catalog (`general` + `food`, version `2026.09`) |
| GET | `/api/dashboard/summary` | KPIs, top violations, recent |
| GET | `/api/reports/:id.pdf` | Archival PDF (verdict, violations, evidence, signature) |
| GET | `/api/reports.csv` | Bulk sheet — same column order as the offline app export |
| — | `/dashboard` | Enforcement web register (static, no build step) |
| — | `/uploads/*` | Label photos (local mode) |

Legacy prototype routes (`/api/products`, `/api/validations`) are kept
with their import-case bugs fixed.

## Where to host (recommended)

**API → Render** (free tier, SIH-friendly, no Docker needed):
1. Push this folder as its own repo (or set Render root directory to `regulation-engine/`).
2. Create a Web Service: build `npm install`, start `npm start`.
3. Env vars: `MONGO_URI` (Atlas, below), `JWT_SECRET` (long random),
   `BASE_URL=https://<your-service>.onrender.com`,
   `CLOUDINARY_*` (storage, below).
4. `render.yaml` in this folder is a one-click Blueprint for the above.

**DB → MongoDB Atlas** (free M0):
1. Create a cluster, a database user, and allow Render IPs (`0.0.0.0/0` for the demo).
2. Paste the connection string as `MONGO_URI`.
3. Run `npm run seed` once against it (or `POST /api/auth/register` with no token for the first admin, then seed regulations via `POST /api/regulations`).

**Dashboard → same Render service** (`/dashboard`, zero extra deploy).
It is plain HTML/CSS/JS that calls the API, so it also deploys as-is to
Vercel/Netlify if you prefer a separate URL — just set the Server field to
the API URL.

## Which storage to choose

| Mode | When | Env |
|---|---|---|
| **Local `uploads/`** (default) | Local dev, judging demo on one machine | nothing |
| **Cloudinary (recommended for hosting)** | Any real deploy — Render disks are ephemeral, uploads would vanish on restart | `CLOUDINARY_CLOUD_NAME/ API_KEY/ API_SECRET` |
| S3-compatible | You already have AWS infra | `S3_BUCKET` (+ wire SDK in `src/services/storage.js`) |

The app and dashboard only ever see final URLs (`imageUrls[]`), so
switching modes never changes the mobile code. See `src/services/storage.js`.

## How the app connects (so scans land on the server)

1. **Build the APK pointed at the server:**
   `flutter build apk -- --dart-define=API_BASE_URL=https://<your-service>.onrender.com`
   (or type the URL once in-app under ☁ Server & sync).
2. **Officer signs in once** in-app (☁ icon → email/password). Token is kept
   in secure storage; scanning works fully offline before and after.
3. **Every scan auto-uploads**: after the report card saves locally,
   `SyncService` uploads `photos[] + reportJson + ocrText` in the background
   (online-gated, exponential backoff). Pull-to-refresh / "Sync now" retries.
4. **Verify:** open `https://<host>/dashboard`, sign in — the scan appears in
   Files with verdict, evidence photos and rule findings. Per-scan archival
   PDF comes from the report card's PDF icon or the dashboard drawer;
   the bulk sheet from dashboard "Download sheet" or `GET /api/reports.csv`.

Local dev against this folder: run the app with
`flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000`
(Android emulator) and sign in with the seeded officer account.
