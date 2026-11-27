"""
Servidor de preparacao - Controle Informatica CRJ Flexal.

Roda no PC do estudio (192.168.10.124), porta 8000.
- GET  /preparar-pc.ps1, /veyon-setup.exe, /crj_public_key.pem  -> entrega os arquivos
- POST /relatorio?pc=NOME                                        -> salva o relatorio em relatorios/

So aceita conexoes da rede 192.168.10.x. Deixe aberto apenas enquanto prepara os PCs.
Parar: Ctrl+C.
"""
import datetime
import ipaddress
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE = Path(__file__).resolve().parent
REDE = ipaddress.ip_network("192.168.10.0/24")
PORTA = 8000
MAX_RELATORIO = 5 * 1024 * 1024

ARQUIVOS = {
    "/preparar-pc.ps1": BASE / "preparar-pc.ps1",
    "/veyon-setup.exe": BASE / "instaladores" / "veyon-setup.exe",
    "/crj_public_key.pem": BASE / "chaves" / "crj_public_key.pem",
    "/restricoes.ps1": BASE / "restricoes.ps1",
    "/aviso.vbs": BASE / "aviso.vbs",
}


def ip_estudio():
    import socket
    try:
        so = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        so.connect(("192.168.10.1", 9))
        ip = so.getsockname()[0]
        so.close()
        return ip
    except Exception:
        return "192.168.10.124"


class Handler(BaseHTTPRequestHandler):
    def _permitido(self):
        try:
            ok = ipaddress.ip_address(self.client_address[0]) in REDE
        except ValueError:
            ok = False
        if not ok:
            self.send_error(403)
        return ok

    def do_GET(self):
        if not self._permitido():
            return
        caminho = ARQUIVOS.get(urlparse(self.path).path)
        if not caminho or not caminho.is_file():
            self.send_error(404)
            return
        dados = caminho.read_bytes()
        if caminho.name == "preparar-pc.ps1":          # o estúdio pode ter mudado de IP: o script usa o endereço atual
            dados = dados.replace(b"192.168.10.124", ip_estudio().encode())
        self.send_response(200)
        # preparar-pc.ps1 vai como texto (irm | iex); o resto vai byte a byte (preserva acentos/BOM)
        tipo = "text/plain; charset=utf-8" if caminho.name == "preparar-pc.ps1" else "application/octet-stream"
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def do_POST(self):
        if not self._permitido():
            return
        url = urlparse(self.path)
        if url.path != "/relatorio":
            self.send_error(404)
            return
        tamanho = int(self.headers.get("Content-Length", 0))
        if tamanho <= 0 or tamanho > MAX_RELATORIO:
            self.send_error(413)
            return
        pc = parse_qs(url.query).get("pc", ["desconhecido"])[0]
        pc = re.sub(r"[^A-Za-z0-9_-]", "_", pc)[:40] or "desconhecido"
        carimbo = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        destino = BASE / "relatorios" / f"{pc}_{carimbo}.txt"
        destino.parent.mkdir(exist_ok=True)
        destino.write_bytes(self.rfile.read(tamanho))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
        print(f"  >> relatorio recebido: {destino.name}")

    def log_message(self, fmt, *args):
        print(f"[{datetime.datetime.now():%H:%M:%S}] {self.client_address[0]} {fmt % args}")


if __name__ == "__main__":
    print(f"Servidor de preparacao CRJ rodando na porta {PORTA} (Ctrl+C para parar)")
    try:
        ThreadingHTTPServer(("0.0.0.0", PORTA), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
