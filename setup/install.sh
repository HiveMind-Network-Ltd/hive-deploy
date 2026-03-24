#!/bin/bash
# hive-deploy installer
# Run from /home/ubuntu/hive-deploy on the server

set -e

INSTALL_DIR="/home/ubuntu/hive-deploy"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== hive-deploy install ==="

if [ ! -f "$INSTALL_DIR/config.json" ]; then
    echo "Creating config.json from example..."
    cp "$INSTALL_DIR/config.example.json" "$INSTALL_DIR/config.json"
    echo "  Edit $INSTALL_DIR/config.json with your project details and secrets."
fi

echo "Installing systemd units..."
sudo cp "$INSTALL_DIR/setup/hive-deploy.socket" "$SYSTEMD_DIR/"
sudo cp "$INSTALL_DIR/setup/hive-deploy.service" "$SYSTEMD_DIR/"

sudo systemctl daemon-reload
sudo systemctl enable hive-deploy.socket
sudo systemctl start hive-deploy.socket

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Edit $INSTALL_DIR/config.json with your project secrets and paths."
echo "  2. Add the Nginx location block from setup/nginx-location.conf to your site config."
echo "  3. Run: sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo "Test it:"
echo "  curl -X POST http://127.0.0.1:5678/deploy/your-project -H 'X-Hive-Secret: your-secret'"
echo ""
echo "View logs:"
echo "  tail -f $INSTALL_DIR/deploy.log"
