#!/bin/bash
cd /tmp/dashboard-test
python3 -c "
import http.server
import socketserver

PORT = 9999
Handler = http.server.SimpleHTTPRequestHandler
with socketserver.TCPServer(('0.0.0.0', PORT), Handler) as httpd:
    print(f'Serving on 0.0.0.0:{PORT}')
    httpd.serve_forever()
"
