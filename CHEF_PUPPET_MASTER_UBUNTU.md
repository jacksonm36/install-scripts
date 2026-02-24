# Chef Infra Server + Puppet Master + Web UI on Ubuntu

This guide installs all of the following on one Ubuntu host:

- Chef Infra Server
- Puppet Server (master)
- PuppetDB
- Puppetboard (web UI)

The included automation script is:

- `chef-puppet-master-ubuntu-install.sh`

## Why the UI is on port 3000

Chef Infra Server uses ports `80/443` by default.  
To avoid conflicts, Puppetboard runs on `3000` by default.

---

## 1) Prerequisites

- Ubuntu with systemd
- Root or sudo access
- FQDN configured for the server (recommended)
- Minimum recommended RAM: 8 GB (Chef + Puppet stack is heavy)

---

## 2) Run the installer

```bash
cd /workspace
chmod +x chef-puppet-master-ubuntu-install.sh
sudo ./chef-puppet-master-ubuntu-install.sh
```

When finished, the script writes a summary file:

- `/root/chef-puppet-install-summary.txt`

---

## 3) Optional environment variable overrides

You can customize defaults before running:

```bash
export CHEF_ADMIN_USER="chefadmin"
export CHEF_ADMIN_FIRST_NAME="Chef"
export CHEF_ADMIN_LAST_NAME="Admin"
export CHEF_ADMIN_EMAIL="chefadmin@example.com"
export CHEF_ADMIN_PASSWORD="StrongPasswordHere"
export CHEF_ORG_SHORT="infra"
export CHEF_ORG_FULL="Infrastructure Organization"

export INSTALL_CHEF_WORKSTATION="true"

export PUPPET_CERTNAME="puppet.example.com"
export PUPPET_DNS_ALT_NAMES="puppet.example.com,puppet"
export PUPPETSERVER_JAVA_ARGS="-Xms1g -Xmx1g"

export PUPPETBOARD_BIND="0.0.0.0"
export PUPPETBOARD_PORT="3000"

export CONFIGURE_UFW="true"
```

Then run:

```bash
sudo ./chef-puppet-master-ubuntu-install.sh
```

---

## 4) Default ports used

- `80/tcp`  - Chef HTTP
- `443/tcp` - Chef HTTPS
- `8140/tcp` - Puppet Server
- `8081/tcp` - PuppetDB (internal API, usually keep restricted)
- `3000/tcp` - Puppetboard UI

---

## 5) Post-install checks

```bash
systemctl status chef-server-runsvdir --no-pager
systemctl status puppetserver --no-pager
systemctl status puppetdb --no-pager
systemctl status puppetboard --no-pager
```

Quick URL checks:

```bash
curl -I https://127.0.0.1
curl -I http://127.0.0.1:3000
```

---

## 6) Access URLs

- Chef Infra Server: `https://<your-hostname>/`
- Puppetboard UI: `http://<your-hostname>:3000/`

---

## 7) Security notes

- Puppetboard is installed without authentication by default.
- For production, restrict source IPs and/or place Puppetboard behind a reverse proxy with authentication.
- Store and protect generated keys/passwords from `/root/chef-puppet-install-summary.txt`.

