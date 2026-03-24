#!/usr/bin/env python3
"""
hive-deploy: Lightweight webhook server for triggering project deploys.
Supports systemd socket activation — zero idle resources between deploys.

Endpoint: POST /deploy/{project-slug}
          Header: X-Hive-Secret: <project-secret>
"""

import json
import logging
import os
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import BaseServer
from urllib.parse import urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, 'config.json')
LOG_PATH = os.path.join(BASE_DIR, 'deploy.log')

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
)

# systemd passes inherited sockets starting at fd 3
SD_LISTEN_FDS_START = 3


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def run_deploy(project_slug, project):
    repo_path = project.get('repo_path', '')
    commands = project.get('commands', [])
    env = {**os.environ, 'HOME': os.path.expanduser('~')}

    logging.info(f'[{project_slug}] Deploy started')

    for cmd in commands:
        logging.info(f'[{project_slug}] $ {cmd}')
        result = subprocess.run(
            ['bash', '--login', '-c', cmd],
            cwd=repo_path,
            capture_output=True,
            text=True,
            env=env,
        )
        if result.stdout.strip():
            logging.info(f'[{project_slug}] {result.stdout.strip()}')
        if result.stderr.strip():
            logging.warning(f'[{project_slug}] stderr: {result.stderr.strip()}')
        if result.returncode != 0:
            logging.error(
                f'[{project_slug}] Command failed (exit {result.returncode}): {cmd}'
            )
            return

    logging.info(f'[{project_slug}] Deploy complete')


class DeployHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Route all logging through the file logger

    def do_GET(self):
        self._respond(200, 'hive-deploy ok\n')

    def do_POST(self):
        try:
            config = load_config()
            parts = urlparse(self.path).path.strip('/').split('/')

            if len(parts) != 2 or parts[0] != 'deploy':
                self._respond(404, 'Not found\n')
                return

            project_slug = parts[1]
            projects = config.get('projects', {})

            if project_slug not in projects:
                self._respond(404, f'Project "{project_slug}" not found\n')
                return

            project = projects[project_slug]
            provided_secret = self.headers.get('X-Hive-Secret', '')

            if provided_secret != project.get('secret', ''):
                logging.warning(f'[{project_slug}] Rejected: invalid secret')
                self._respond(403, 'Forbidden\n')
                return

            self._respond(202, f'Deploy triggered for {project_slug}\n')
            logging.info(f'[{project_slug}] Webhook accepted — starting deploy thread')

            thread = threading.Thread(
                target=run_deploy,
                args=(project_slug, project),
                daemon=True,
            )
            thread.start()

        except Exception as e:
            logging.error(f'Handler error: {e}')
            self._respond(500, 'Internal server error\n')

    def _respond(self, code, message):
        body = message.encode() if isinstance(message, str) else message
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class InheritedSocketServer(HTTPServer):
    """HTTPServer that adopts an already-bound socket from systemd."""

    def __init__(self, sock, handler_class):
        BaseServer.__init__(self, sock.getsockname(), handler_class)
        self.socket = sock
        self.socket.setblocking(True)
        self.server_activate()  # calls listen() — safe on an already-bound socket


def make_server():
    n_fds = int(os.environ.get('LISTEN_FDS', 0))
    if n_fds >= 1:
        logging.info('Starting via systemd socket activation')
        inherited = socket.fromfd(SD_LISTEN_FDS_START, socket.AF_INET, socket.SOCK_STREAM)
        return InheritedSocketServer(inherited, DeployHandler)
    else:
        logging.info('Starting in standalone mode on 127.0.0.1:5678')
        return HTTPServer(('127.0.0.1', 5678), DeployHandler)


if __name__ == '__main__':
    server = make_server()
    logging.info(f'hive-deploy listening on {server.server_address}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info('hive-deploy stopped')
