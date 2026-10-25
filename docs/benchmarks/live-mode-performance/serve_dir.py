"""Serves the traces in a directory to ui.perfetto.dev from 127.0.0.1:9001, then exits after a time limit.
Usage: serve_trace.py TRACE [SECONDS]"""
import http.server, os, sys, threading

root = os.path.abspath(sys.argv[1])
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 900
names = {'/' + n: os.path.join(root, n) for n in os.listdir(root) if n.endswith('.pftrace')}


class Handler(http.server.BaseHTTPRequestHandler):
    def headers_out(self, code, length=0):
        self.send_response(code)
        self.send_header('Access-Control-Allow-Origin', 'https://ui.perfetto.dev')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Content-Length', str(length))
        if code == 200:
            self.send_header('Content-Type', 'application/octet-stream')
        self.end_headers()

    def do_OPTIONS(self):
        self.headers_out(204)

    def do_GET(self):
        path = names.get(self.path.split('?')[0])
        if path is None:
            self.headers_out(404)
            return
        size = os.path.getsize(path)
        self.headers_out(200, size)
        with open(path, 'rb') as f:
            while chunk := f.read(1 << 20):
                self.wfile.write(chunk)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 9001), Handler)
threading.Timer(limit, server.shutdown).start()
print(f'serving {sorted(names)} on http://127.0.0.1:9001 for {limit} s', flush=True)
server.serve_forever()
