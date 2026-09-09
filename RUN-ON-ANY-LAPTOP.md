# Run everything on any laptop (after `git clone`)

Two halves: **server** (Docker, ~5 min) and **app** (APK install or Flutter, ~10 min).
They connect over plain HTTPS — the laptop and the phones just need internet.

> The ready-to-install APKs in `App/complience_app/build/app/outputs/flutter-apk/`
> are **not** in git (build output is gitignored). Transfer them by Drive/USB cable,
> or rebuild (step B3). Use `app-arm64-v8a-release.apk` for modern phones (78 MB);
> `app-release.apk` (170 MB) works on every CPU.

## A. Server — Docker only, no Node/Mongo needed

1. Install **Docker** (Docker Desktop, or `docker` + `docker compose` plugin) and
   `git`, then:
   ```bash
   git clone <your-repo-url> Compliance-App
   cd Compliance-App/regulation-engine
   ```
2. Recreate `.env` (it never travels with git — copy these 3 lines from your
   old machine or password manager):
   ```bash
   cp .env.example .env
   ```
   then edit `.env`: paste `MONGO_URI=` (Atlas string), keep the same
   `JWT_SECRET=` so existing logins keep working, set `BASE_URL=` to whatever
   public address you will use below (or leave empty for laptop-only testing).
3. Start it:
   ```bash
   docker compose up -d --build
   docker compose logs -f api   # expect "MongoDB connected successfully"
   ```
   First time on a **fresh** database only: `docker compose exec api npm run seed`
   (creates the rule catalog + `officer@gov.in` / `admin@gov.in`).
4. Make it public (pick one):
   - **Stable:** named Cloudflare tunnel — `cloudflared tunnel login`,
     `cloudflared tunnel create compliance-laptop`,
     `cloudflared tunnel route dns compliance-laptop api.yourdomain.com`,
     then `cloudflared tunnel run compliance-laptop`
     (or `docker compose --profile tunnel up -d` once `~/.cloudflared/` exists).
   - **Instant, temporary:** `cloudflared tunnel --url http://localhost:5000`
     or `ssh -R 80:localhost:5000 serveo.net` — use the printed URL, it changes
     on every reconnect.
   - Only one machine can serve a hostname at a time: stop the tunnel on the
     old laptop before starting it on the new one.
5. Verify from the laptop: `http://localhost:5000/` → JSON,
   `http://localhost:5000/dashboard` → register login. Then the same over the
   public URL from your phone (off home Wi-Fi proves it's truly public).
6. If the public URL changed, update `BASE_URL=` in `.env` and restart
   (`docker compose up -d`) so photo links come out right, and retype the URL
   in the app (☁ Server & sync) — no APK rebuild needed for a URL change.

## B. App — install or run

- **Easiest (no setup):** copy the `*-release.apk` onto the phone (USB/Drive/
  `adb install app-arm64-v8a-release.apk`), install, open.
- **From source:** install Flutter 3.44+, then:
  ```bash
  cd App/complience_app
  flutter pub get
  flutter run --dart-define=API_BASE_URL=https://<your-public-url>
  # or bake it into a fresh APK:
  flutter build apk --release --split-per-abi \
    --dart-define=API_BASE_URL=https://<your-public-url>
  ```
- **First launch on the phone:** ☁ Server & sync → check the server URL →
  sign in (`officer@gov.in`) → scan once → it must appear in
  `<public-url>/dashboard`. Offline scanning works before/after sign-in;
  unsynced rows show a cloud-off icon and upload on "Sync now".

## C. Demo-day checklist

- [ ] `docker compose ps` → api healthy; login works on dashboard
- [ ] Public URL loads off-Wi-Fi; `BASE_URL` matches it
- [ ] Phone signed in; one test scan visible in dashboard Files
- [ ] Laptop charged, PC set to never sleep, tunnel terminal kept open
- [ ] Backup: quick-tunnel/serveo command ready in case the main URL dies

## Troubleshooting

| Symptom | Fix |
|---|---|
| `MongoDB connected` never appears | Wrong `MONGO_URI` (password/encoding) or Atlas IP blocklist missing `0.0.0.0/0` |
| Login `Invalid credentials` | Fresh DB → run the `seed` step; old token after `JWT_SECRET` change → sign in again |
| App won't sync | Server URL mistyped in ☁ settings, or tunnel/serveo process died — recheck public URL in a browser first |
| `flutter build apk` fails on AarMetadata/SDK | `android/app/build.gradle.kts` → `compileSdk = 37` (flutter_secure_storage v11 needs it); needs Android SDK platform 37 installed |
| Port 5000 busy | Another server running: `docker compose down` or stop the host `node server.js` |
