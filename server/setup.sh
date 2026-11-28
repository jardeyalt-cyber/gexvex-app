#!/usr/bin/env bash
# GexVex bot: one-time setup for a fresh Ubuntu 24.04 VPS (any provider). Safe to run again.
#   curl -fsSL https://raw.githubusercontent.com/jardeyalt-cyber/gexvex-app/main/server/setup.sh | bash
# Lives in the public gexvex-app repo because the bot repo is private. It needs no GitHub
# access: the bot repo's "Deploy to server" workflow sends the code and API secrets over SSH.
# It installs a systemd service, a deploy key that can only run deploy.sh, and prints the two
# values to paste into GitHub. deploy.sh and the unit below are copies of the files in
# gexvex-bot/server/ (each deploy refreshes deploy.sh from the repo).
set -euo pipefail

APP=/opt/gexvex
KEY=/root/gexvex-deploy-key

[ "$(id -u)" = 0 ] || { echo "Please run as root (log in as root, or add sudo)."; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing packages (1-2 minutes)"
apt-get update -q >/dev/null
apt-get install -y -q python3-venv python3-pip ufw tzdata ca-certificates >/dev/null

echo "==> Adding 1 GB swap (safety net for a 2 GB server)"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> Creating the gexvex user and folders"
id gexvex >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/gexvex --shell /bin/bash gexvex
usermod -p '*' gexvex           # no password, but key logins allowed
usermod -aG systemd-journal gexvex
mkdir -p "$APP/bin" /var/lib/gexvex
chown -R gexvex:gexvex "$APP" /var/lib/gexvex
chmod 750 "$APP" /var/lib/gexvex
[ -x "$APP/venv/bin/python" ] || sudo -u gexvex python3 -m venv "$APP/venv"
sudo -u gexvex "$APP/venv/bin/pip" install -q --upgrade pip

echo "==> Installing the deploy command and service"
if [ ! -f "$APP/bin/deploy.sh" ]; then
cat > "$APP/bin/deploy.sh" <<'GEXVEX_EOF'
#!/usr/bin/env bash
# Forced command for the GitHub Actions deploy key (installed by setup.sh from the public
# gexvex-app repo; each deploy refreshes it from this file). The key can run only
# this script, as the gexvex user, with one of the actions below.
set -euo pipefail
APP=/opt/gexvex
DB=/var/lib/gexvex/vex_history.db
read -r action arg _ <<<"${SSH_ORIGINAL_COMMAND:-status}" || true
arg=${arg:-}

case "$action" in
  secrets)
    umask 077
    tmp=$(mktemp "$APP/.secrets.XXXXXX")
    head -c 200000 > "$tmp"
    if "$APP/venv/bin/python" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("TRADYTICS_API_KEY") and d.get("GOOGLE_CREDS_JSON") else 1)' "$tmp"; then
      mv "$tmp" "$APP/secrets.json"
      echo "Secrets saved."
    else
      rm -f "$tmp"
      echo "Secrets rejected: TRADYTICS_API_KEY or GOOGLE_CREDS_JSON missing." >&2
      exit 1
    fi
    ;;
  seed-db)
    if [ -s "$DB" ]; then
      cat > /dev/null
      echo "History DB already on the server; kept it."
    else
      head -c 500000000 > "$DB.tmp" && mv "$DB.tmp" "$DB"
      echo "History DB seeded from the Actions cache ($(stat -c %s "$DB") bytes)."
    fi
    ;;
  deploy)
    # The workflow pipes `git archive` of the commit on stdin (the repo is private, so the
    # server never pulls from GitHub itself).
    [[ "$arg" =~ ^[0-9a-f]{7,40}$ ]] || { echo "deploy needs a commit sha" >&2; exit 2; }
    rm -rf "$APP/code.new"
    mkdir -p "$APP/code.new"
    tar -xz -C "$APP/code.new"
    [ -f "$APP/code.new/bot.py" ] || { rm -rf "$APP/code.new"; echo "Archive has no bot.py; kept the old code." >&2; exit 1; }
    echo "$arg" > "$APP/code.new/VERSION"
    new_req=$(sha256sum "$APP/code.new/requirements.txt" | cut -d' ' -f1)
    if [ "$new_req" != "$(cat "$APP/.deps-ok" 2>/dev/null)" ]; then
      [ -x "$APP/venv/bin/pip" ] || python3 -m venv "$APP/venv"
      "$APP/venv/bin/pip" install -q -r "$APP/code.new/requirements.txt"
      echo "$new_req" > "$APP/.deps-ok"
    fi
    rm -rf "$APP/code.old"
    [ -d "$APP/code" ] && mv "$APP/code" "$APP/code.old"
    mv "$APP/code.new" "$APP/code"
    # Keep this forced command current with the repo copy.
    install -m 755 "$APP/code/server/deploy.sh" "$APP/bin/deploy.sh.new" && mv "$APP/bin/deploy.sh.new" "$APP/bin/deploy.sh"
    echo "Code at ${arg:0:7}"
    sudo /usr/bin/systemctl restart gexvex-bot
    sleep 8
    systemctl is-active gexvex-bot || true
    journalctl -u gexvex-bot -n 15 --no-pager -o cat || true
    ;;
  restart)
    sudo /usr/bin/systemctl restart gexvex-bot
    sleep 8
    systemctl is-active gexvex-bot || true
    ;;
  status)
    lines=${arg:-120}
    [[ "$lines" =~ ^[0-9]{1,4}$ ]] || lines=120
    systemctl status gexvex-bot --no-pager -l 2>&1 | head -12 || true
    echo "--- last $lines log lines ---"
    journalctl -u gexvex-bot -n "$lines" --no-pager -o short-iso || true
    echo "--- disk / memory ---"
    df -h / | tail -1
    free -m | head -2
    ;;
  *)
    echo "Unknown action: $action (use secrets, seed-db, deploy, restart, status)" >&2
    exit 2
    ;;
esac
GEXVEX_EOF
fi
chown gexvex:gexvex "$APP/bin/deploy.sh"
chmod 755 "$APP/bin/deploy.sh"

cat > /etc/systemd/system/gexvex-bot.service <<'GEXVEX_EOF'
[Unit]
Description=GexVex bot (always on)
After=network-online.target
Wants=network-online.target
# The first deploy from GitHub Actions writes the API secrets; until then the bot stays off.
ConditionPathExists=/opt/gexvex/secrets.json
StartLimitIntervalSec=0

[Service]
Type=simple
User=gexvex
WorkingDirectory=/opt/gexvex/code
Environment=ALWAYS_ON=true
Environment=MAX_RUN_MINUTES=1000
Environment=POLL_INTERVAL_SECONDS=30
Environment=DB_PATH=/var/lib/gexvex/vex_history.db
Environment=GEXVEX_SECRETS=/opt/gexvex/secrets.json
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/gexvex/venv/bin/python /opt/gexvex/code/server/run.py
# The bot exits when the day's window closes (or on a crash); systemd starts it again,
# and the new process sleeps until the next weekday window.
Restart=always
RestartSec=30
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
GEXVEX_EOF
cat > /etc/sudoers.d/gexvex <<'GEXVEX_EOF'
gexvex ALL=(root) NOPASSWD: /usr/bin/systemctl restart gexvex-bot
GEXVEX_EOF
chmod 440 /etc/sudoers.d/gexvex
visudo -cf /etc/sudoers.d/gexvex >/dev/null
systemctl daemon-reload
systemctl enable gexvex-bot >/dev/null 2>&1
if [ -f "$APP/secrets.json" ] && [ -f "$APP/code/bot.py" ]; then systemctl restart gexvex-bot; fi

echo "==> Creating the deploy key"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "github-actions-deploy" -f "$KEY"
install -d -m 700 -o gexvex -g gexvex /home/gexvex/.ssh
echo "command=\"$APP/bin/deploy.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $(cat "$KEY.pub")" \
  > /home/gexvex/.ssh/authorized_keys
chown gexvex:gexvex /home/gexvex/.ssh/authorized_keys
chmod 600 /home/gexvex/.ssh/authorized_keys

echo "==> Firewall: only SSH in"
ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null

# Public IPv4: the default-route source address (works on Vultr, DO, Linode, Hetzner...).
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
[ -n "$IP" ] || IP=$(hostname -I | awk '{print $1}')

cat <<DONE

==================================================================
 Server is ready. Add these two secrets in GitHub
 (gexvex-bot > Settings > Secrets and variables > Actions > New repository secret):

 1) Name:  DEPLOY_HOST
    Value: $IP

 2) Name:  DEPLOY_SSH_KEY
    Value: everything between the two lines of dashes below, including
           the BEGIN and END lines

-------------------------------------------------------------------
$(cat "$KEY")
-------------------------------------------------------------------

 Then open gexvex-bot > Actions > "Deploy to server" > Run workflow.
 Lost this screen? Run:  cat $KEY
==================================================================
DONE
