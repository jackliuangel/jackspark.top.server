---
description: How to setup nginx server and deploy a new react app to lightsail
---

# Deploy React App to Lightsail

This workflow details the steps to deploy a new React web app to the Lightsail nginx server based on the README. Throughout these instructions, replace `foobar` with the actual name of your app.

1. **Create DNS Record**
   In Cloudflare, create a new DNS record for your app's subdomain (e.g., `foobar.jackspark.top`) pointing to the Lightsail IP address.

2. **Generate HTTPS Certificate**
   SSH into the nginx server and generate an SSL certificate using Certbot:
   ```bash
   sudo certbot certonly --nginx -d foobar.jackspark.top
   ```
   *(Note: `sudo certbot certificates` lists all certificates managed by Certbot)*

3. **Upload Build Files**
   Build the React app locally (`npm run build`). Then, use SCP to transfer the bundled `dist` directory to the server:
   ```bash
   scp -r dist/* lightsail:/var/www/html/foobar-root/
   ```

4. **Prepare Nginx Configuration**
   Prepare an nginx configuration file named `foobar-subdomain` by referencing an existing one (e.g. `etc/nginx/sites-available/foobar-subdomain`). Place this file in your server repo path:
   `/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain`
   *(You can sync this over to the remote server via Git push/pull, or using SCP.)*

5. **Create Soft Link in `sites-available`**
   On the nginx server, create a symlink in the `/etc/nginx/sites-available` directory pointing to the repository's configuration file:
   ```bash
   sudo ln -sf /home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain /etc/nginx/sites-available/foobar-subdomain
   ```

6. **Create Soft Link in `sites-enabled`**
   On the nginx server, create another symlink in `/etc/nginx/sites-enabled` pointing to `/etc/nginx/sites-available/foobar-subdomain`:
   ```bash
   sudo ln -sf /etc/nginx/sites-available/foobar-subdomain /etc/nginx/sites-enabled/foobar-subdomain
   ```

7. **Restart Nginx**
   Finally, restart nginx so the new site configuration takes effect:
   ```bash
   sudo systemctl restart nginx
   ```
