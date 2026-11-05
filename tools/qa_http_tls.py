#!/usr/bin/env python3
"""Servidor HTTPS local para o QA do HTTP dos plugins: certificado próprio, gerado na
hora, para 'localhost'. Responde como o serviço de tradução e anota os cabeçalhos de
cada pedido em <pasta>/requests.txt. Só escuta em 127.0.0.1. Uso: qa_http_tls.py <pasta>
"""
import http.server
import pathlib
import ssl
import subprocess
import sys

folder = pathlib.Path(sys.argv[1])
cert, key = folder / "cert.pem", folder / "key.pem"
subprocess.run(
    ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert),
     "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
    check=True, stderr=subprocess.DEVNULL)
log = folder / "requests.txt"
BODY = b'{"responseData":{"translatedText":"traduzido por HTTPS","match":1},"responseStatus":200}'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with log.open("a") as f:
            f.write(self.requestline + "\n" + str(self.headers) + "\n")
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    # Um cliente que recusa o certificado (de propósito, no teste) derruba a conexão.
    def handle_error(self, request, client_address):
        pass


server = Server(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
(folder / "port").write_text(str(server.server_address[1]))
server.serve_forever()
