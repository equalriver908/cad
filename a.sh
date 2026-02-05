#!/bin/bash
# ===============================================
# Migration Script: WordPress + PHP-FPM + Caddy
# Migrates WordPress from Apache/Nginx to Caddy with Let's Encrypt SSL
# ===============================================

set -e

# -------------------
# USER CONFIGURATION
# -------------------
DOMAIN="sahmcore.com.sa"
ADMIN_EMAIL="a.saeed@$DOMAIN"
WP_PATH="/var/www/html"          # The original WordPress path (no backup needed)
PHP_VERSION="8.3"
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
WP_CONFIG="$WP_PATH/wp-config.php"

# MySQL Credentials
DB_NAME="sahmcore_wp"
DB_USER="sahmcore_user"
DB_PASS="SahmCore@2025"

# -------------------
# SYSTEM UPDATE & DEPENDENCIES
# -------------------
echo "[INFO] Updating system and installing dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget unzip lsb-release software-properties-common net-tools ufw dnsutils git mariadb-client mariadb-server

# -------------------
# PHP-FPM INSTALLATION
# -------------------
echo "[INFO] Checking PHP-FPM..."
if ! command -v php >/dev/null 2>&1; then
    echo "[INFO] Installing PHP-FPM..."
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
    sudo apt install -y php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml php8.3-xmlrpc php8.3-soap php8.3-intl php8.3-zip
fi

echo "[INFO] Using PHP-FPM socket: $PHP_SOCKET"

# -------------------
# CADDY INSTALLATION
# -------------------
echo "[INFO] Installing Caddy..."
if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy
fi

# -------------------
# STOP OTHER WEB SERVERS (Apache / Nginx)
# -------------------
echo "[INFO] Stopping Apache and Nginx to avoid conflicts..."
sudo systemctl stop apache2 nginx 2>/dev/null || true
sudo systemctl disable apache2 nginx 2>/dev/null || true
sudo systemctl mask apache2 nginx  # Ensure Apache and Nginx do not restart

# -------------------
# VERIFY AND RESTORE WORDPRESS FILES
# -------------------
echo "[INFO] Verifying WordPress installation at $WP_PATH..."

# Ensure that the WordPress path exists
if [ ! -d "$WP_PATH" ]; then
    echo "[ERROR] WordPress path $WP_PATH does not exist!"
    exit 1
fi

# Ensure correct permissions for the WordPress files
sudo chown -R www-data:www-data $WP_PATH
sudo find $WP_PATH -type d -exec chmod 755 {} \;
sudo find $WP_PATH -type f -exec chmod 644 {} \;

# -------------------
# RESTORE DATABASE
# -------------------
echo "[INFO] Restoring database..."

# If necessary, create the database (ensure the database exists in MySQL)
sudo mysql -u sahmcore_user -p -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

# Import the existing database dump (if applicable)
# This assumes the original database is running and doesn't require restoring from an external file
# Adjust if you have an actual database dump to restore
sudo mysql -u sahmcore_user -p $DB_NAME < /var/www/html/backup/wordpress_db.sql

# -------------------
# VERIFY wp-config.php
# -------------------
echo "[INFO] Verifying wp-config.php..."
if [ ! -f "$WP_CONFIG" ]; then
    echo "[ERROR] wp-config.php is missing!"
    exit 1
fi

# Ensure wp-config.php points to the correct database
sed -i "s/database_name_here/$DB_NAME/" $WP_CONFIG
sed -i "s/username_here/$DB_USER/" $WP_CONFIG
sed -i "s/password_here/$DB_PASS/" $WP_CONFIG

# Update site URL if necessary
sed -i "s|define('WP_HOME', 'http://localhost');|define('WP_HOME', 'https://$DOMAIN');|" $WP_CONFIG
sed -i "s|define('WP_SITEURL', 'http://localhost');|define('WP_SITEURL', 'https://$DOMAIN');|" $WP_CONFIG

# -------------------
# CREATE CADDYFILE
# -------------------
echo "[INFO] Creating Caddyfile..."
sudo tee /etc/caddy/Caddyfile > /dev/null << EOF
# WordPress site $DOMAIN, www.$DOMAIN
$DOMAIN, www.$DOMAIN {
    root * $WP_PATH
    php_fastcgi unix:$PHP_SOCKET
    file_server
    encode gzip zstd
    log {
        output file /var/log/caddy/wordpress.log
    }
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    # Automatically get SSL certificates from Let's Encrypt
    tls $ADMIN_EMAIL
}

# Other services (ERP, docs, mail, etc.) can be added here as needed
EOF

# -------------------
# FIREWALL SETUP
# -------------------
echo "[INFO] Configuring firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp    # Allow HTTP for debugging
sudo ufw allow 443/tcp   # Allow HTTPS for Let's Encrypt
sudo ufw enable

# -------------------
# START SERVICES
# -------------------
echo "[INFO] Starting PHP-FPM and Caddy..."
sudo systemctl daemon-reload
sudo systemctl enable --now php${PHP_VERSION}-fpm
sudo systemctl enable --now caddy

# -------------------
# DIAGNOSTIC SCRIPT
# -------------------

echo "[INFO] Running diagnostics..."

# Check if PHP-FPM is running
echo "[INFO] Checking PHP-FPM service..."
if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
    echo "[INFO] PHP-FPM is running."
else
    echo "[ERROR] PHP-FPM is NOT running. Starting PHP-FPM..."
    sudo systemctl start php${PHP_VERSION}-fpm
    sudo systemctl enable php${PHP_VERSION}-fpm
fi

# Check if Caddy is running
echo "[INFO] Checking if Caddy is running..."
if systemctl is-active --quiet caddy; then
    echo "[INFO] Caddy is running."
else
    echo "[ERROR] Caddy is NOT running. Starting Caddy..."
    sudo systemctl start caddy
    sudo systemctl enable caddy
fi

# Check if MySQL is accessible
echo "[INFO] Testing MySQL connectivity..."
mysql -u $DB_USER -p$DB_PASS -h localhost -e "SHOW DATABASES;" > /dev/null
if [ $? -eq 0 ]; then
    echo "[INFO] MySQL connection is successful."
else
    echo "[ERROR] Unable to connect to MySQL. Check credentials and permissions."
    exit 1
fi

# Check if PHP-FPM socket exists and is accessible
echo "[INFO] Checking PHP-FPM socket..."
if [ -S "$PHP_SOCKET" ]; then
    echo "[INFO] PHP-FPM socket exists and is accessible."
else
    echo "[ERROR] PHP-FPM socket is missing or inaccessible!"
    exit 1
fi

# Test the PHP-FPM log for errors
echo "[INFO] Checking PHP-FPM logs for errors..."
sudo tail -n 20 /var/log/php8.3-fpm.log

# Test if Caddy is properly serving WordPress
echo "[INFO] Testing WordPress with Curl..."
curl -s --head "https://$DOMAIN" | head -n 20
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN")
if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "[INFO] WordPress is responsive (status code 200)."
else
    echo "[ERROR] WordPress is not responsive (status code: $HTTP_STATUS)."
    exit 1
fi

# -------------------
# COMPLETION
# -------------------
echo "[INFO] Migration complete. The WordPress site should now be available at https://$DOMAIN"

