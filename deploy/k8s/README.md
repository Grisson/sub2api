# Sub2API on Azure Kubernetes Service (AKS)

Production deployment of Sub2API on AKS. Everything needed lives in this directory.

```
                 Internet
                    │ 443 / 80
        ┌───────────▼───────────┐
        │ Azure Load Balancer   │  static public IP
        └───────────┬───────────┘
        ┌───────────▼───────────┐
        │ nginx   (Deployment)  │  HTTPS offload, rate limits, HPA 2-6
        └───────────┬───────────┘
                    │ HTTP 8080 (cluster internal)
        ┌───────────▼───────────┐
        │ sub2api (Deployment)  │  stateless, HPA 2-6
        └─────┬───────────┬─────┘
   ┌──────────▼───┐   ┌───▼──────────┐
   │ postgres     │   │ redis        │   StatefulSets on Azure Managed Disks
   │ (Azure Disk) │   │ (Azure Disk) │   (reclaim policy: Retain)
   └──────┬───────┘   └──────────────┘
          │ daily pg_dump (CronJob)
   ┌──────▼──────────────────┐
   │ Azure Files share       │  Azure Storage account, 14 days of dumps
   └─────────────────────────┘
```

| Service | Kind | Kubernetes Service | Scaling |
|---|---|---|---|
| `nginx` | Deployment | `nginx` (LoadBalancer, public) | HPA 2-6 on CPU |
| `sub2api` | Deployment | `sub2api` (ClusterIP) | HPA 2-6 on CPU |
| `postgres` | StatefulSet | `postgres` (headless) | vertical (resources, disk size) |
| `redis` | StatefulSet | `redis` (headless) | vertical (resources) |
| `postgres-backup` | CronJob | – | – |

## Layout

```
deploy/k8s/
├── config.env.example      settings for the scripts (copy to config.env)
├── azure/create-aks.sh     Azure CLI: resource group, AKS, public IP, (ACR, cert identity)
├── scripts/
│   ├── deploy.sh           asks for credentials, creates Secrets, TLS, applies manifests
│   ├── backup-now.sh       on-demand database backup
│   ├── restore.sh          list backups / restore the database
│   ├── build-image.sh      optional: build this repo's image and push it to ACR
│   └── lib.sh              shared helpers
└── manifests/              kustomize base (one folder per service)
    ├── namespace.yaml  storageclasses.yaml  network-policies.yaml
    ├── nginx/  sub2api/  postgres/  redis/  backup/
```

## Prerequisites

- An Azure subscription where you are **Owner** (or Contributor + User Access Administrator).
- A bash shell: Linux, macOS, WSL, Azure Cloud Shell or **Git Bash on Windows**.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), `kubectl` and `kubelogin`
  (`az aks install-cli` installs both), `openssl`.
- `helm` only for `TLS_MODE=letsencrypt`; Docker only for `build-image.sh`.
- A DNS name you control.

## Deploy

```bash
cd deploy/k8s
cp config.env.example config.env      # edit: region, DOMAIN, TLS_MODE, AKS_API_AUTHORIZED_IPS ...

az login
bash azure/create-aks.sh              # ~10 min, prints the public IP
#   -> create the DNS A record  DOMAIN -> public IP   (see "Domain setup" below)

bash scripts/deploy.sh                # asks for user names / passwords on the first run
```

Open `https://<DOMAIN>` and log in with the admin e-mail and password you entered.

### User names and passwords

`deploy.sh` prompts on the first run and stores the answers **only** as Kubernetes
Secrets in the cluster. Nothing is written to disk or to this repository.

| Prompt | Notes | Secret |
|---|---|---|
| Database user / password | Enter on the password = random 48-character value | `postgres-credentials` |
| Redis password | Enter = random 48-character value | `redis-credentials` |
| Admin e-mail / password | your Sub2API login, password min. 12 characters | `sub2api-secrets` |
| JWT secret, TOTP key | always generated | `sub2api-secrets` |

Later runs keep existing Secrets untouched. Read a value back with e.g.
`kubectl -n sub2api get secret postgres-credentials -o jsonpath='{.data.password}' | base64 -d`.

The admin e-mail/password are only used to create the first administrator while
the database is empty. Changing the password afterwards is done in the web UI.
The database password is baked into the data directory on first start; changing
it later requires `ALTER USER` in PostgreSQL **and** updating the Secret.

### HTTPS

nginx terminates TLS with the certificate in the Secret `sub2api-tls`; the
application only ever sees plain HTTP from nginx.

| `TLS_MODE` | Use |
|---|---|
| `selfsigned` | Quick test. Clients will show certificate warnings. |
| `byo` | Certificate from your CA (or a Cloudflare origin certificate). Set `TLS_CERT_FILE` (full chain) and `TLS_KEY_FILE`, re-run `deploy.sh` to replace it. |
| `letsencrypt` | Automatic issue and renewal by cert-manager (DNS-01). The domain's zone must be hosted in **Azure DNS**; set `ACME_EMAIL`, `DNS_ZONE_NAME`, `DNS_ZONE_RESOURCE_GROUP` *before* `create-aks.sh`. |

Switching from `selfsigned` to another mode: `kubectl -n sub2api delete secret sub2api-tls`,
change `TLS_MODE`, re-run `deploy.sh` (and `create-aks.sh` first for `letsencrypt`).
nginx picks up a changed certificate within 5 minutes without a restart.

### Domain setup: registrar DNS (GoDaddy) + Azure DNS + Let's Encrypt

`TLS_MODE=letsencrypt` proves domain ownership with a DNS-01 challenge:
cert-manager writes a temporary `_acme-challenge` TXT record, so it needs API
access to the zone, and only Azure DNS is wired up. The domain does not have to
leave its registrar. Delegating just the API subdomain to Azure DNS is enough,
and the website, mail and all other records stay where they are.

The example uses `api.example.com`, registered at GoDaddy, with the zone in a
resource group `dns-rg`.

1. **Create the zone in Azure DNS**, in its own resource group so that deleting
   the cluster's resource group never deletes it:

   ```bash
   az group create --name dns-rg --location <region>
   az network dns zone create --resource-group dns-rg --name api.example.com
   az network dns zone show   --resource-group dns-rg --name api.example.com --query nameServers -o tsv
   ```

   The last command prints four `nsX-YY.azure-dns.*` name servers.

2. **Delegate the subdomain at the registrar.** In GoDaddy (Domain → DNS → Add
   New Record) add four `NS` records with name `api`, one per Azure name
   server. Delete any existing `A` / `CNAME` record named `api`.

   Check it (minutes to an hour): `nslookup -type=NS api.example.com` must list
   the `azure-dns` name servers.

3. **Set `config.env`** *before* running `create-aks.sh`:

   ```bash
   DOMAIN=api.example.com
   TLS_MODE=letsencrypt
   ACME_EMAIL=you@example.com            # Let's Encrypt expiry notices
   DNS_ZONE_NAME=api.example.com         # the zone exactly as created in step 1
   DNS_ZONE_RESOURCE_GROUP=dns-rg
   ```

4. **Install helm** (used only to install cert-manager): `winget install Helm.Helm`
   on Windows, then reopen the terminal.

5. **Run `bash azure/create-aks.sh`.** Besides the cluster it creates a managed
   identity for cert-manager with the role *DNS Zone Contributor* on this one
   zone, and prints the static public IP.

6. **Create the A record in Azure DNS** (not at the registrar). The zone is the
   host name itself, so the record name is `@`:

   ```bash
   az network dns record-set a add-record --resource-group dns-rg --zone-name api.example.com \
     --record-set-name "@" --ipv4-address <PUBLIC_IP>
   ```

7. **Run `bash scripts/deploy.sh`.** It installs cert-manager, creates the
   `letsencrypt-azuredns` ClusterIssuer and requests the certificate into the
   Secret `sub2api-tls`. Renewal is automatic.

   ```bash
   kubectl -n sub2api get certificate          # READY should become True
   nslookup api.example.com                    # should return <PUBLIC_IP>
   ```

Moving the whole domain instead: export the zone file at the registrar, create
the zone for `example.com`, `az network dns zone import` it, compare every
record (MX especially), disable DNSSEC at the registrar, then switch the
registrar's name servers to the Azure ones. Use `DNS_ZONE_NAME=example.com` and
`--record-set-name api` in step 6.

On Windows run the scripts from **Git Bash**. In PowerShell, `bash` usually
starts WSL, which cannot see the Windows `az`, `kubectl`, `kubelogin` and `helm`;
use `& "C:\Program Files\Git\bin\bash.exe" scripts/deploy.sh` instead.

## Scaling

Each service is scaled on its own:

```bash
# application / nginx replicas (edit min/max in the HPA to make it permanent)
kubectl -n sub2api patch hpa sub2api --patch '{"spec":{"minReplicas":3,"maxReplicas":10}}'
kubectl -n sub2api patch hpa nginx   --patch '{"spec":{"minReplicas":3}}'
```

- `sub2api`: with more than 6 replicas raise PostgreSQL `max_connections`
  (`manifests/postgres/postgres.yaml`); each replica uses up to
  `DATABASE_MAX_OPEN_CONNS` (50) connections.
- `postgres` / `redis`: change `resources` in their manifest and re-run `deploy.sh`.
  Grow a disk with `kubectl -n sub2api patch pvc data-postgres-0 --patch '{"spec":{"resources":{"requests":{"storage":"128Gi"}}}}'`.
- Nodes: the cluster autoscaler adds nodes between `AKS_NODE_MIN` and `AKS_NODE_MAX`.

Small clusters: `SIZE_PROFILE=small` in `config.env` applies `profiles/small`,
which shrinks every pod so the stack fits 4 vCPUs in total (2 × `Standard_D2s_v5`).
Set it back to `standard` on bigger nodes and re-run `deploy.sh`.

Application settings: edit `manifests/sub2api/app.env` (any variable from
`deploy/.env.example`) and re-run `deploy.sh`; the pods roll automatically.
Upgrade: change `SUB2API_TAG` in `config.env`, take a backup, re-run `deploy.sh`.

## Data persistence and recovery

| Data | Where | Protection |
|---|---|---|
| PostgreSQL | Azure Premium SSD (`data-postgres-0`, 64 GiB) | `Retain` reclaim policy, data checksums |
| Redis (AOF) | Azure Premium SSD (`data-redis-0`, 16 GiB) | `Retain` reclaim policy |
| Database dumps | Azure Files share (`postgres-backups`, 100 GiB) | separate storage account, `Retain`, 14 daily dumps |

**Back up now**

```bash
bash scripts/backup-now.sh
```

**Restore** (API is down while it runs; takes a safety backup of the current state first)

```bash
bash scripts/restore.sh --list
bash scripts/restore.sh latest                          # or a file name from --list
```

**The disk outlives the cluster objects.** Deleting the PVC, the StatefulSet or
the namespace does not delete the Azure disk. To re-attach a retained disk:
`kubectl get pv` → find the `Released` volume → `kubectl patch pv <name> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'`
→ re-run `deploy.sh` after pre-creating a PVC named `data-postgres-0` with `volumeName: <name>`.

**Extra protection worth adding**

- Point-in-time disk snapshot before risky changes:
  `az snapshot create -g <node-rg> -n pg-$(date +%F) --source <disk-id> --incremental true`
  (disk id: `kubectl get pv <name> -o jsonpath='{.spec.csi.volumeHandle}'`).
- Enable *soft delete* on the backup storage account's file shares in the Azure
  portal (the account was created automatically in the node resource group), and
  copy dumps to another region if you need geo-redundancy.
- Test `restore.sh` once before you depend on it.

Backups are daily dumps: in the worst case (disk lost) up to 24 hours of data
are lost. If that is not acceptable, use Azure Database for PostgreSQL Flexible
Server (point-in-time restore) and point `DATABASE_HOST` at it.

## Security measures

**Cluster (`create-aks.sh`)**

- Microsoft Entra ID sign-in with Azure RBAC; local `kubeconfig` admin accounts disabled; no SSH keys on nodes.
- `AKS_API_AUTHORIZED_IPS` restricts who can reach the Kubernetes API server – **set it**.
- Azure CNI Overlay + Cilium: enforces the NetworkPolicies below.
- Automatic Kubernetes patch upgrades and weekly node OS image upgrades; unused images are cleaned.
- Workload identity (no stored cloud credentials); cert-manager's identity can only edit the one DNS zone.
- Optional: Microsoft Defender for Containers, Container insights.

**Network**

- Only nginx is exposed (ports 80/443). The app, PostgreSQL and Redis have no public endpoint.
- Default-deny NetworkPolicy; allowed flows are exactly `nginx → sub2api → postgres/redis` and `backup → postgres`.
- The app may reach the public internet only: private ranges and the Azure
  metadata endpoint are blocked (SSRF containment). Upstreams must be `https` and public
  (`SECURITY_URL_ALLOWLIST_*` in `app.env`).

**Edge (nginx)**

- TLS 1.2/1.3 only, modern ciphers, HSTS, HTTP → HTTPS redirect.
- Requests with an unknown `Host` (IP scanners) are dropped without an answer.
- Per-IP limits: 5 req/s on `/api/v1/auth/` (brute force), 30 req/s elsewhere, 40 connections; body/header size limits.
- `X-Forwarded-For` / `X-Real-IP` are overwritten from the real TCP peer and cannot be spoofed.
- Access logs omit query strings (they can carry API keys).

**Workloads**

- Namespace enforces the Kubernetes *restricted* Pod Security Standard.
- All containers: non-root, read-only root filesystem, all capabilities dropped, no privilege escalation, seccomp, no service-account token.
- Secrets are separate per service, random where possible, PostgreSQL uses SCRAM-SHA-256, Redis requires a password.

**Do after the first login**

1. Enable two-factor authentication for the admin account.
2. Decide whether public registration should be open (admin settings).
3. Pin `SUB2API_TAG` to a release version instead of `latest`.

## Operations

```bash
kubectl -n sub2api get pods,hpa,pvc,svc
kubectl -n sub2api logs deploy/sub2api -f
kubectl -n sub2api logs deploy/nginx -f
kubectl -n sub2api rollout restart deploy/sub2api
kubectl -n sub2api exec -it postgres-0 -- psql -U <db-user> sub2api
```

## Limitations to know about

- **PostgreSQL and Redis are single instances.** A node failure means a few
  minutes of downtime while the pod is rescheduled and the disk re-attached
  (zonal `Premium_LRS` disks keep the pod in its zone; switch the storage class
  to `Premium_ZRS` *before the first deploy* if your region supports it). For
  database high availability use the Azure managed services.
- **Rollouts interrupt in-flight streams.** The app shuts down 5 seconds after
  SIGTERM (after a 15 s drain), so long streaming responses on a pod being
  replaced are cut. Deploy during quiet hours.
- **Per-pod local state is not shared.** Admin-uploaded plugins and the in-app
  "online update" are not supported in this multi-replica, read-only setup;
  upgrade by changing the image tag.
- **First start:** two app pods start together and both try to create the admin
  account; one may restart once. This is harmless.
- nginx rate-limit counters are per nginx replica. For volumetric DDoS
  protection or a WAF, put Azure Front Door / Cloudflare in front and then
  restrict the nginx NetworkPolicy and trusted proxy headers to that provider.
- Traffic inside the cluster (nginx → app → database) is plain HTTP/TCP,
  protected by NetworkPolicy, not by encryption.
- These manifests were rendered and syntax-checked offline; run the first
  deployment against a non-production domain and confirm login, a streaming
  request and a backup/restore cycle before going live.

## Tear down

```bash
kubectl delete namespace sub2api                    # disks and backup share are retained
az group delete --name <AZ_RESOURCE_GROUP>          # deletes the cluster AND all retained data
```
