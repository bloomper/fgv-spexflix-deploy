# Spexflix Deploy

Docker Compose setup for running Spexflix (API, worker, web, MySQL and the media server) on a single host, next to
[spexregister-deploy][1] and [fgv-infra-deploy][2], which runs Keycloak, the shared network `fgv-<DEPLOY_ENV>` and the
edge proxy.

Cloudflare is used on staging only. Production uses no Cloudflare Tunnel, DNS or Access: its own reverse proxy serves
`WEB_HOST` and `MEDIA_HOST` (see *Production*).

```
Staging:
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ──▶ spexflix-web:3000            (WEB_HOST)
Browser ──https──▶ edge-caddy (fgv-infra-deploy) ──▶ spexflix-media:80                 (MEDIA_HOST, DNS-only)

spexflix-web ──▶ spexflix-api ──▶ spexflix-mysql
                 spexflix-worker ──▶ spexflix-mysql          (processes uploads with ffmpeg)
                 spexflix-api ──▶ keycloak-server, spexregister-api, spexify-api        (fgv network)
spexify-api ──▶ spexflix-api                                  (chapter links, fgv network)
```

- On staging, the web goes through the Cloudflare Tunnel like Spexregister. Uploads are tus chunks of at most 50 MB
  through the web, below the request limit of Cloudflare's free plan. The API has no public hostname.
- Video goes to viewers straight from the host, on staging because Cloudflare's CDN terms restrict serving video on the
  free plans. `MEDIA_HOST` is a DNS-only record served by `edge-caddy` (`compose.edge.yaml` in `fgv-infra-deploy`), which
  forwards to `spexflix-media`: nginx, serving only files under signed, expiring addresses (`media/default.conf.template`,
  nginx `secure_link`). Originals are never served.

## Files

| File                          | Purpose                                                                    |
|-------------------------------|----------------------------------------------------------------------------|
| `compose.yaml`                | `spexflix-mysql`, `spexflix-api`, `spexflix-worker`, `spexflix-web`, `spexflix-media` |
| `compose.tunnel.yaml`         | `cloudflared` connector for `WEB_HOST`, staging only                       |
| `media/default.conf.template` | The media server's nginx configuration                                     |
| `staging.env.example`, `production.env.example` | Templates for `.env`                                     |
| `bin/init-secrets.sh`         | Generates secrets into `secrets/` and copies the client secrets from `fgv-infra-deploy` |
| `bin/backup-db.sh`            | Dumps the database into `backups/`, pruning dumps older than 14 days       |
| `bin/backup-media.sh`         | Backs up originals, subtitles and uploaded posters with restic             |

| `.env` variable | Image                          | Source repo           |
|-----------------|--------------------------------|-----------------------|
| `API_IMAGE`     | `bloomper/fgv-spexflix-server` | `fgv-spexflix-server` (API and worker) |
| `WEB_IMAGE`     | `bloomper/fgv-spexflix-web`    | `fgv-spexflix-web`    |

## 1. Host

- `fgv-infra-deploy` running with a realm that has the `fgv-spexflix` and `fgv-spexflix-service` clients. Its `.env`
  names this deployment's `WEB_HOST` as `SPEXFLIX_WEB_HOST` and `MEDIA_HOST` as `SPEXFLIX_MEDIA_HOST`, and its edge proxy
  (`compose.edge.yaml`) runs, with only ports 80 and 443 open on the host.
- `spexregister-deploy` running a `spexregister-server` release that knows the `MEDIA` role.
- Optionally `fgv-spexify-deploy`, for links between chapters and tracks.
- Enough disk for the media: a full show of two and a half hours takes about 10 GB of renditions plus its original.
- CPU for transcoding: the worker uses at most `WORKER_CPUS` and runs ffmpeg at low priority.

## 2. Cloudflare (staging only)

Only staging uses Cloudflare. On production, skip this section and point `WEB_HOST` and `MEDIA_HOST` at production's
reverse proxy (see *Production*).

1. Create a tunnel (Networking → Tunnels → *Create a tunnel* → Cloudflared) and copy its token.
2. Add one published application: `WEB_HOST` → `http://spexflix-web:3000`.
3. Add a **DNS-only** (grey cloud) A/AAAA record for `MEDIA_HOST` pointing at the host.
4. Restrict `WEB_HOST` to testers with Cloudflare Access, as `spexregister-deploy`'s README describes. The
   media hostname needs no Access: its addresses are signed and expire.

## 3. Checkout and configuration

```shell
git clone https://github.com/bloomper/fgv-spexflix-deploy.git
cd fgv-spexflix-deploy

cp staging.env.example .env          # set the hostnames
bin/init-secrets.sh                  # copies the client secrets from ../fgv-infra-deploy
nano secrets/cloudflared.env         # staging only: TUNNEL_TOKEN=<token from step 2>
mkdir -p data/api/log_data data/worker/log_data data/media/hls
sudo chown -R 1000:1000 data
docker compose up -d
```

| Variable                          | Purpose                                                                      |
|-----------------------------------|------------------------------------------------------------------------------|
| `WEB_HOST`                        | Spexflix's address                                                           |
| `MEDIA_HOST`                      | The DNS-only media hostname                                                  |
| `KEYCLOAK_HOST`, `KEYCLOAK_REALM` | Keycloak's public address and realm                                          |
| `WORKER_CPUS`                     | CPUs the worker may use                                                      |
| `MAX_UPLOAD_SIZE`                 | The largest upload the deployment accepts; admins can lower it in the web    |
| `SPEXREGISTER_GRAPHQL_URL`        | Spexregister's GraphQL endpoint on the shared network                        |
| `SPEXIFY_GRAPHQL_URL`, `SPEXIFY_WEB_URL` | Spexify, for links between chapters and tracks; empty without Spexify |
| `SPEXREGISTER_WEB_URL`            | Spexregister's web, for links to a spex                                      |
| `API_IMPORT_SAMPLE_DATA`          | `true` on staging only: replaces all data at every start                     |
| `API_SAMPLE_DATA_SIZE`, `API_SAMPLE_DATA_PREPROCESSED` | `small` or `large`; `true` to process every sample video at start |
| `SUPPORT_EMAIL`, `FEEDBACK_EMAIL` | Shown on the Support and About pages                                         |
| `UMAMI_WEBSITE_ID`                | Umami website for `WEB_HOST`; without it the web sends no statistics         |

For visitor statistics, run `bin/configure-umami.sh` in `fgv-infra-deploy` (see *Umami* in its README). It adds a
website `SPEXFLIX_NAME` for `SPEXFLIX_WEB_HOST` and prints its ID; put that ID in `UMAMI_WEBSITE_ID`. The web
serves Umami's tracker as `/stats/script.js` and forwards events through `/stats/api/send`, so browsers only talk to
`WEB_HOST`. Leave the ID empty to send nothing.

`API_MEDIA_SIGNING_KEY` is shared by the API, which signs playback addresses, and `spexflix-media`, which checks them.
Changing it invalidates every address handed out, which only makes open players ask for new ones.

## Media

Everything lies under `data/media/`, mounted into the API and the worker; `spexflix-media` mounts only `data/media/hls`
read-only:

| Folder       | Content                                                         | Back up |
|--------------|-----------------------------------------------------------------|---------|
| `originals/` | The uploaded files, the archive copies                          | Yes     |
| `hls/`       | Renditions, thumbnails, posters and subtitles                   | Subtitles and uploaded posters; renditions can be remade |
| `uploads/`   | Unfinished uploads, deleted after 24 hours                      | No      |

## First start

The API creates its tables, and on staging (`API_IMPORT_SAMPLE_DATA=true`) replaces all data with sample data built on
Spexregister's sample spex, which the worker then processes; see *Sample data* in `fgv-spexflix-server`'s README for
the users. Spexregister deletes all Keycloak users on every start of its sample import, so restart Spexflix after it:
`docker compose restart spexflix-api`.

## Production

- `.env` from `production.env.example`: `DEPLOY_ENV=production` (the API then refuses sample data),
  `API_IMPORT_SAMPLE_DATA=false`, and images pinned to release versions.
- No Cloudflare: `COMPOSE_FILE` leaves out `compose.tunnel.yaml` and needs no `secrets/cloudflared.env`. Production's
  own reverse proxy terminates TLS and forwards `WEB_HOST` to `spexflix-web:3000` (tus chunks of up to 50 MB) and
  `MEDIA_HOST` to `spexflix-media:80` (GET and HEAD only), as `fgv-infra-deploy`'s *Edge proxy* describes.
- `bin/backup-db.sh` and `bin/backup-media.sh` in cron, with `backups/` copied off the host.
- The old Spexflix's videos are moved in once with `fgv-spexflix-migration`, when they are found.

## Troubleshooting

| Symptom                                           | Cause                                                                       |
|---------------------------------------------------|-----------------------------------------------------------------------------|
| Videos don't play; the browser shows 403 from `MEDIA_HOST` | `API_MEDIA_SIGNING_KEY` differs between the API and `spexflix-media`, or the clocks differ |
| Videos don't play; the console names a Content Security Policy | `MEDIA_HOST` changed without restarting `spexflix-web`             |
| Videos stay "processing"                          | `spexflix-worker` is down; see *Bearbetning* under *Redigera*               |
| Login fails with "Invalid parameter: redirect_uri" | `SPEXFLIX_WEB_HOST` in `fgv-infra-deploy` doesn't match `WEB_HOST`         |

[1]: https://github.com/bloomper/spexregister-deploy
[2]: https://github.com/bloomper/fgv-infra-deploy
