"""
Painel da Informatica - CRJ Flexal
Roda no PC do estudio: http://127.0.0.1:8080  (so acessivel neste PC)

- Estado das maquinas (atualiza a cada 30 s)
- Acoes: pausar/reativar restricoes, mensagem, hibernar, ligar (Wake-on-LAN), reiniciar, desligar
- Historico de pesquisas e sites (Chrome/Edge) coletado a cada 20 min
- Horario de funcionamento (hiberna no fechamento, acorda sozinho na abertura)
Sem dependencias externas: so Python + PowerShell.
"""
import base64
import csv
import datetime as dt
import hmac
import ipaddress
import os
import secrets
import uuid
import re
import hashlib
import json
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.request
import urllib.error
import ctypes
import ctypes.wintypes
import traceback
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote_plus, urlparse

AQUI = Path(__file__).resolve().parent
BASE = AQUI.parent

# Rodando sem janela (pythonw): grava as mensagens em painel.log
if sys.stdout is None or sys.stderr is None:
    _log = open(AQUI / "painel.log", "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = _log
CSV = BASE / "computadores.csv"
ACOES = AQUI / "painel-acoes.ps1"
CONFIG = AQUI / "config.json"
DB = AQUI / "historico.db"
RAW = AQUI / "hist_raw"
TMP = AQUI / "tmp"
TELAS = AQUI / "telas"
EXT_IMG = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png"}
LOG_ACOES = AQUI / "historico-de-acoes.log"
PORTA = 8080
INTERVALO_STATUS = 30
INTERVALO_HIST = 20 * 60

estado = {"pcs": {}, "atualizado": None, "hist_atualizado": None, "hist_rodando": False}
trava = threading.Lock()
trava_hist = threading.Lock()


# ------------------------------------------------------------------ utilidades
def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def ler_pcs():
    with open(CSV, newline="", encoding="utf-8") as f:
        pcs = [r for r in csv.DictReader(f) if r.get("IP")]

    def ordem(r):
        n = "".join(c for c in r["Nome"] if c.isdigit())
        return int(n) if n else 999
    return sorted(pcs, key=ordem)


def ler_config():
    padrao = {"horario": {"ativo": False, "abre": "14:00", "fecha": "17:30",
                          "dias": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]},
              "aplicado": {}}
    if CONFIG.exists():
        try:
            c = json.loads(CONFIG.read_text(encoding="utf-8-sig"))
            padrao.update(c)
        except Exception:
            pass
    padrao["horario"] = normalizar_horario(padrao["horario"])
    return padrao


DIAS_SEMANA = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def normalizar_horario(h):
    """Formato por dia: {"ativo": bool, "semana": {"Monday": {"ativo", "abre", "fecha"}, ...}}.
    Converte o formato antigo (abre/fecha/dias iguais para todos)."""
    if "semana" not in h:
        h = {"ativo": h.get("ativo", False),
             "semana": {d: {"ativo": d in h.get("dias", []), "abre": h.get("abre", "14:00"), "fecha": h.get("fecha", "17:30")}
                        for d in DIAS_SEMANA}}
    for d in DIAS_SEMANA:
        h["semana"].setdefault(d, {"ativo": False, "abre": "14:00", "fecha": "17:30"})
    return {"ativo": bool(h["ativo"]), "semana": {d: h["semana"][d] for d in DIAS_SEMANA}}


def agenda_ativa(h):
    return [{"dia": d, "abre": v["abre"], "fecha": v["fecha"]} for d, v in h["semana"].items() if v.get("ativo")]


def salvar_config(c):
    CONFIG.write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding="utf-8")


def versao_horario(h):
    return hashlib.md5(json.dumps(h, sort_keys=True).encode()).hexdigest()[:10] if h.get("ativo") else "off"


def porta_aberta(ip, porta=5985, timeout=1.2):
    try:
        with socket.create_connection((ip, porta), timeout=timeout):
            return True
    except OSError:
        return False


CTX = threading.local()          # quem fez a ação (estúdio / rede / automático), por requisição


def quem_agora():
    return getattr(CTX, "quem", None) or "automático"


def registrar_acao(acao, ips, detalhe, quem=None):
    """Historico de tudo que foi feito em massa (quem precisar conferir depois)."""
    nomes = {p["IP"]: p["Nome"] for p in ler_pcs()}
    with open(LOG_ACOES, "a", encoding="utf-8") as f:
        f.write(f"[{dt.datetime.now():%d/%m/%Y %H:%M:%S}] {acao} em {', '.join(nomes.get(i, i) for i in ips)} · por {quem or quem_agora()}\n"
                f"    {json.dumps(detalhe, ensure_ascii=False)}\n")


def rodar_acao(acao, ips, **extra):
    if not ips:
        return []
    cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ACOES),
           "-Acao", acao, "-IPs", ",".join(ips)]
    for k, v in extra.items():
        cmd += [f"-{k}", str(v)]
    # stdin=DEVNULL: sem isso o PowerShell trava quando o painel roda escondido (pythonw)
    p = subprocess.run(cmd, capture_output=True, stdin=subprocess.DEVNULL, timeout=900, creationflags=0x08000000)
    saida = p.stdout.decode("utf-8", errors="replace").strip()
    inicios = [i for i in (saida.find("["), saida.find("{")) if i >= 0]
    inicio = min(inicios) if inicios else -1
    try:
        r = json.loads(saida[inicio:]) if inicio >= 0 else []
        return r if isinstance(r, list) else [r]
    except json.JSONDecodeError:
        log(f"saida inesperada de {acao}: {saida[:300]} {p.stderr[:300]!r}")
        return [{"ip": ip, "ok": False, "erro": "resposta invalida"} for ip in ips]


# ------------------------------------------------------------------ status
def montar_pc(p, d, porta_ok):
    ip = p["IP"]
    anterior = estado["pcs"].get(ip, {})
    ok = bool(porta_ok and d.get("ok"))
    return {
        "nome": p["Nome"], "ip": ip, "mac": p.get("MAC", ""),
        "online": ok,
        "logado": (d.get("logado") or "").split("\\")[-1] if ok else "",
        "estado": d.get("estado", "") if ok else "", "bloqueio": d.get("bloqueio", "") if ok else "",
        "boot": d.get("boot", "") if ok else "", "horario": d.get("horario", False),
        "defeito": bool(d.get("defeito")) if ok else anterior.get("defeito", False),
        "manut": d.get("manut", "") if ok else anterior.get("manut", ""), "semanal": bool(d.get("semanal")) if ok else anterior.get("semanal", False),
        "visto": dt.datetime.now().strftime("%d/%m %H:%M") if ok else anterior.get("visto"),
        "navegador": (d.get("navegador") or "").strip() if ok else anterior.get("navegador", ""),
        "verificar": d.get("verificar") if ok else anterior.get("verificar"),
        "avisos_maquina": d.get("avisos") if ok else anterior.get("avisos_maquina"),
        "telas_n": d.get("telas_n") if ok else anterior.get("telas_n"),
        "telas_cfg": d.get("telas_cfg") if ok else anterior.get("telas_cfg"),
        "pendente": anterior.get("pendente", []),
    }


def atualizar_status():
    """Consulta cada maquina separadamente (em paralelo): uma lenta nao atrasa as outras.
    O resultado de cada uma aparece no painel assim que ela responde."""
    pcs = ler_pcs()
    with trava:   # maquinas novas/removidas do csv
        estado["pcs"] = {p["IP"]: estado["pcs"].get(p["IP"]) or montar_pc(p, {}, False) for p in pcs}

    def um(p):
        porta_ok = porta_aberta(p["IP"])
        d = {}
        if porta_ok:
            r = rodar_acao("Status", [p["IP"]], Limite=60)
            d = r[0] if r else {}
        info = montar_pc(p, d, porta_ok)
        with trava:
            estado["pcs"][p["IP"]] = info
            estado["atualizado"] = dt.datetime.now().strftime("%H:%M:%S")
        try:
            vigiar_pc(info)
        except Exception:
            traceback.print_exc()
        return info

    with ThreadPoolExecutor(16) as ex:
        list(ex.map(um, pcs))
    sincronizar_horario(dict(estado["pcs"]))
    try:
        sincronia_automatica()
    except Exception:
        traceback.print_exc()
    threading.Thread(target=redescobrir_ips, daemon=True).start()
    vigiar_endereco()


def sincronizar_horario(pcs):
    """Aplica o horario nos PCs que ligaram depois da ultima alteracao."""
    c = ler_config()
    h = c["horario"]
    v = versao_horario(h)
    pendentes = [ip for ip, p in pcs.items() if p["online"] and c["aplicado"].get(ip) != v]
    if not pendentes:
        return
    if h.get("ativo"):
        TMP.mkdir(exist_ok=True)
        arq = TMP / f"horario-{time.time_ns()}.json"
        arq.write_text(json.dumps({"agenda": agenda_ativa(h)}), encoding="utf-8")
        try:
            r = rodar_acao("Horario", pendentes, Arquivo=str(arq))
        finally:
            arq.unlink(missing_ok=True)
    else:
        r = rodar_acao("RemoverHorario", pendentes)
    for x in r:
        if x.get("ok"):
            c["aplicado"][x["ip"]] = v
    salvar_config(c)
    log(f"horario sincronizado em: {[x['ip'] for x in r if x.get('ok')]}")


def laco_status():
    while True:
        try:
            atualizar_status()
        except Exception:
            traceback.print_exc()
        try:
            verificar_rotinas()
        except Exception:
            traceback.print_exc()
        time.sleep(INTERVALO_STATUS)


# ------------------------------------------------------------------ historico
def iniciar_db():
    con = sqlite3.connect(DB)
    con.executescript("""
    CREATE TABLE IF NOT EXISTS sites(pc TEXT, conta TEXT, nav TEXT, quando TEXT, url TEXT, titulo TEXT,
        UNIQUE(pc, conta, nav, quando, url));
    CREATE TABLE IF NOT EXISTS pesquisas(pc TEXT, conta TEXT, nav TEXT, quando TEXT, termo TEXT, onde TEXT,
        UNIQUE(pc, conta, nav, quando, termo));
    CREATE INDEX IF NOT EXISTS i_sites ON sites(quando);
    CREATE INDEX IF NOT EXISTS i_pesq ON pesquisas(quando);
    """)
    con.commit()
    con.close()


def chrome_para_local(us):
    try:
        t = dt.datetime(1601, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(microseconds=int(us))
        return t.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def termo_da_url(url):
    try:
        u = urlparse(url)
        q = parse_qs(u.query)
        host = u.netloc.lower()
        if "youtube.com" in host and "search_query" in q:
            return q["search_query"][0], "YouTube"
        if "google." in host and u.path.startswith("/search") and "q" in q:
            return q["q"][0], "Google"
        if "bing.com" in host and u.path.startswith("/search") and "q" in q:
            return q["q"][0], "Bing"
    except Exception:
        pass
    return None, None


def importar_arquivo(con, nome_pc, arquivo):
    conta, nav, _perfil = arquivo.stem.split("__", 2)
    src = sqlite3.connect(f"file:{arquivo}?mode=ro", uri=True)
    try:
        linhas = src.execute("""SELECT v.visit_time, u.url, u.title FROM visits v JOIN urls u ON v.url = u.id
                                WHERE v.visit_time > ?""",
                             (int((time.time() + 11644473600 - 60 * 86400) * 1e6),)).fetchall()
        termos = []
        try:
            termos = src.execute("""SELECT u.last_visit_time, k.term, u.url FROM keyword_search_terms k
                                    JOIN urls u ON k.url_id = u.id""").fetchall()
        except sqlite3.Error:
            pass
    finally:
        src.close()
    n_sites = n_pesq = 0
    for vt, url, titulo in linhas:
        if not url or url.startswith(("chrome://", "edge://", "about:", "chrome-extension://", "file://")):
            continue
        quando = chrome_para_local(vt)
        cur = con.execute("INSERT OR IGNORE INTO sites VALUES(?,?,?,?,?,?)", (nome_pc, conta, nav, quando, url, titulo or ""))
        n_sites += cur.rowcount
        termo, onde = termo_da_url(url)
        if termo:
            cur = con.execute("INSERT OR IGNORE INTO pesquisas VALUES(?,?,?,?,?,?)", (nome_pc, conta, nav, quando, termo.strip(), onde))
            n_pesq += cur.rowcount
    for vt, termo, url in termos:
        _, onde = termo_da_url(url)
        cur = con.execute("INSERT OR IGNORE INTO pesquisas VALUES(?,?,?,?,?,?)",
                          (nome_pc, conta, nav, chrome_para_local(vt), (termo or "").strip(), onde or "Busca"))
        n_pesq += cur.rowcount
    return n_sites, n_pesq


def coletar_historico():
    if not trava_hist.acquire(blocking=False):
        return
    try:
        estado["hist_rodando"] = True
        pcs = [p for p in estado["pcs"].values() if p["online"]]
        if not pcs:
            return
        RAW.mkdir(exist_ok=True)
        rodar_acao("Historico", [p["ip"] for p in pcs], Destino=str(RAW))
        con = sqlite3.connect(DB)
        total = [0, 0]
        for p in pcs:
            pasta = RAW / p["ip"].replace(".", "_")
            for arq in pasta.glob("*.db") if pasta.exists() else []:
                try:
                    s, q = importar_arquivo(con, p["nome"], arq)
                    total[0] += s
                    total[1] += q
                except Exception as e:
                    log(f"erro lendo {arq.name}: {e}")
        con.commit()
        con.close()
        estado["hist_atualizado"] = dt.datetime.now().strftime("%d/%m %H:%M")
        log(f"historico: +{total[0]} sites, +{total[1]} pesquisas")
        try:
            avisar_alertas_novos()
        except Exception:
            traceback.print_exc()
    except Exception:
        traceback.print_exc()
    finally:
        estado["hist_rodando"] = False
        trava_hist.release()


def laco_historico():
    time.sleep(45)
    while True:
        coletar_historico()
        time.sleep(INTERVALO_HIST)


def consultar_historico(q):
    tipo = q.get("tipo", ["pesquisas"])[0]
    pc = q.get("pc", [""])[0]
    dias = int(q.get("dias", ["7"])[0] or 7)
    busca = q.get("busca", [""])[0].strip()
    desde = (dt.datetime.now() - dt.timedelta(days=dias)).strftime("%Y-%m-%d 00:00:00") if dias > 0 \
        else dt.datetime.now().strftime("%Y-%m-%d 00:00:00")
    tabela, campos = ("pesquisas", "pc, conta, nav, quando, termo, onde") if tipo == "pesquisas" \
        else ("sites", "pc, conta, nav, quando, url, titulo")
    sql = f"SELECT {campos} FROM {tabela} WHERE quando >= ?"
    par = [desde]
    if pc:
        sql += " AND pc = ?"
        par.append(pc)
    if busca:
        sql += " AND (" + ("termo LIKE ?" if tipo == "pesquisas" else "url LIKE ? OR titulo LIKE ?") + ")"
        par += [f"%{busca}%"] * (1 if tipo == "pesquisas" else 2)
    so_alertas = q.get("alerta", [""])[0] == "1"
    sql += " ORDER BY quando DESC" + ("" if so_alertas else " LIMIT 1000")
    con = sqlite3.connect(DB)
    linhas = con.execute(sql, par).fetchall()
    con.close()
    rx = regex_alertas()
    saida = []
    for l in linhas:
        achou = palavra_alerta(rx, f"{l[4]} {l[5] or ''}")
        if so_alertas and not achou:
            continue
        saida.append(list(l) + [achou])
        if len(saida) >= 1000:
            break
    return saida


# ------------------------------------------------------------------ palavras de alerta
ALERTAS_PADRAO = [
    "aposta", "apostas", "bet", "bets", "cassino", "tigrinho", "fortune tiger", "blaze", "roleta", "jogo do bicho",
    "porn", "porno", "pornografia", "xvideos", "xxx", "nude", "nudes", "onlyfans", "hentai", "+18", "sexo",
    "suicidio", "se matar", "me matar", "como morrer", "automutilacao", "cortar os pulsos", "quero morrer",
    "maconha", "cocaina", "crack", "drogas", "comprar arma", "arma de fogo", "como fazer bomba", "deep web",
]


def normalizar(t):
    t = unicodedata.normalize("NFKD", str(t or "").lower())
    return "".join(c for c in t if not unicodedata.combining(c))


_cache_rx = {"chave": None, "rx": None}


def regex_alertas():
    palavras = [normalizar(p).strip() for p in ler_config().get("alertas", ALERTAS_PADRAO) if str(p).strip()]
    chave = tuple(palavras)
    if _cache_rx["chave"] != chave:
        # palavra inteira: "bet" pega "bet365" mas nao "alfabeto"; "+18" pega "video+18"
        partes = [(r"(?<![a-z0-9])" if p[0].isalnum() else "") + re.escape(p) for p in sorted(set(palavras), key=len, reverse=True)]
        _cache_rx["rx"] = re.compile("(" + "|".join(partes) + ")", re.I) if partes else None
        _cache_rx["chave"] = chave
    return _cache_rx["rx"]


def palavra_alerta(rx, texto):
    if not rx:
        return ""
    # texto como esta e decodificado (enderecos de sites vem com %20 e +)
    m = rx.search(normalizar(texto)) or rx.search(normalizar(unquote_plus(texto)))
    return m.group(1) if m else ""


def resumo_alertas():
    rx = regex_alertas()
    hoje = dt.datetime.now().strftime("%Y-%m-%d 00:00:00")
    semana = (dt.datetime.now() - dt.timedelta(days=7)).strftime("%Y-%m-%d 00:00:00")
    con = sqlite3.connect(DB)
    linhas = con.execute("SELECT quando, termo, onde FROM pesquisas WHERE quando >= ?", (semana,)).fetchall()
    con.close()
    n_hoje = n_semana = 0
    for quando, termo, onde in linhas:
        if palavra_alerta(rx, f"{termo} {onde or ''}"):
            n_semana += 1
            n_hoje += quando >= hoje
    return {"hoje": n_hoje, "semana": n_semana}


# ------------------------------------------------------------------ Wake-on-LAN
def wake_on_lan(macs):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    enviados = 0
    for mac in macs:
        m = mac.replace(":", "").replace("-", "")
        if len(m) != 12:
            continue
        pacote = b"\xff" * 6 + bytes.fromhex(m) * 16
        for destino in ("192.168.10.255", "255.255.255.255"):
            for porta in (7, 9):
                s.sendto(pacote, (destino, porta))
        enviados += 1
    s.close()
    return enviados


# ------------------------------------------------------------------ execução das ações
ACOES_SIMPLES = ("Pausar", "Aplicar", "Hibernar", "Reiniciar", "Desligar", "Mensagem", "BloquearTela", "Defeito", "DefeitoFim", "NavegadorLivre")
ACOES_JSON = ("Energia", "Otimizar", "Programas", "Desinstalar", "Comando", "Semanal")
ACOES_VALIDAS = set(ACOES_SIMPLES) | set(ACOES_JSON) | {"Ligar", "TelaBloqueio"}


def opcoes_telas(corpo):
    imgs = [TELAS / Path(n).name for n in corpo.get("imagens", [])]
    imgs = [str(i) for i in imgs if i.is_file() and i.suffix.lower() in EXT_IMG]
    opc = {"intervaloSeg": max(0, int(corpo.get("intervaloSeg") or 0)), "bloqueio": bool(corpo.get("bloqueio", True)), "fundo": bool(corpo.get("fundo"))}
    return imgs, opc


def salvar_cfg_telas(corpo):
    imgs, opc = opcoes_telas(corpo)
    c = ler_config()
    c["telas"] = {"aplicadas": [Path(i).name for i in imgs], **opc, "quando": dt.datetime.now().strftime("%d/%m %H:%M")}
    salvar_config(c)


def executar_acao(acao, ips, corpo, registrar=True):
    """Executa uma ação nas máquinas e devolve a lista de resultados (um por IP)."""
    if acao == "Ligar":
        macs = [p["mac"] for p in estado["pcs"].values() if p["ip"] in ips]
        n = wake_on_lan(macs)
        r = [{"ip": ip, "ok": True, "msg": "sinal de ligar enviado"} for ip in ips][:max(n, 0)]
    elif acao in ACOES_SIMPLES:
        extra = {}
        if acao == "Pausar":
            extra["Horas"] = int(corpo.get("horas", 3))
        if acao == "NavegadorLivre":
            extra["Horas"] = max(0, min(12, int(corpo.get("horas", 3) or 0)))
        if acao == "Mensagem":
            extra["Texto"] = str(corpo.get("texto", ""))[:250].replace('"', "'")
        r = rodar_acao(acao, ips, **extra)
    elif acao in ACOES_JSON:
        params = {k: corpo.get(k) for k in ("tela", "semBloqueio", "itens", "nome", "codigo", "dia", "hora", "agora") if k in corpo}
        if registrar:
            registrar_acao(acao, ips, params)
        TMP.mkdir(exist_ok=True)
        arq = TMP / f"acao-{time.time_ns()}-{threading.get_ident()}.json"
        arq.write_text(json.dumps(params, ensure_ascii=False), encoding="utf-8")
        try:
            r = rodar_acao(acao, ips, Arquivo=str(arq))
        finally:
            arq.unlink(missing_ok=True)
    elif acao == "TelaBloqueio":
        imgs, opc = opcoes_telas(corpo)
        if registrar:
            registrar_acao("Imagens do CRJ", ips, {"imagens": [Path(i).name for i in imgs], **opc})
        TMP.mkdir(exist_ok=True)
        arq = TMP / f"telas-{time.time_ns()}-{threading.get_ident()}.json"
        arq.write_text(json.dumps({"arquivos": imgs, **opc}), encoding="utf-8")
        try:
            r = rodar_acao("TelaBloqueio", ips, Arquivo=str(arq))
        finally:
            arq.unlink(missing_ok=True)
        if registrar:
            salvar_cfg_telas(corpo)
    else:
        raise ValueError("acao desconhecida")
    if registrar:
        registrar_acao(acao + " (resultado)", ips, [(x.get("ip"), x.get("ok"), x.get("msg") or (x.get("saida") or "")[:200] or x.get("erro")) for x in r])
        log(f"acao {acao} em {ips}: {[(x.get('ip'), x.get('ok')) for x in r]}")
    return r


# ------------------------------------------------------------------ tarefas (progresso por máquina)
TAREFAS = {}
trava_tarefas = threading.Lock()


def criar_tarefa(acao, ips, corpo):
    tid = uuid.uuid4().hex[:12]
    t = {"id": tid, "acao": acao, "inicio": time.time(), "fim": None, "quem": quem_agora(),
         "online": [ip for ip in ips if (estado["pcs"].get(ip) or {}).get("online")],
         "itens": {ip: {"estado": "aguardando", "msg": "", "dados": None} for ip in ips}}
    if acao in DESLIGAM:
        for ip in ips:
            DESLIGOU[ip] = time.time()
    with trava_tarefas:
        for k in [k for k, v in TAREFAS.items() if v["fim"] and time.time() - v["fim"] > 3600]:
            TAREFAS.pop(k, None)
        TAREFAS[tid] = t
    resumo = {k: corpo.get(k) for k in ("horas", "texto", "tela", "semBloqueio", "itens", "nome", "codigo", "dia", "hora", "agora", "intervaloSeg", "bloqueio", "fundo") if k in corpo}
    if acao == "TelaBloqueio":
        resumo["imagens"] = len(corpo.get("imagens", []))
    registrar_acao(acao, ips, resumo)
    if acao == "Semanal" and not corpo.get("agora") and corpo.get("dia") and corpo.get("hora"):
        c = ler_config()
        c["semanal"] = {"dia": str(corpo["dia"]), "hora": str(corpo["hora"])}
        salvar_config(c)
    threading.Thread(target=_rodar_tarefa, args=(t, corpo), daemon=True).start()
    return tid


def _rodar_tarefa(t, corpo):
    acao = t["acao"]

    def um(ip):
        with trava_tarefas:
            t["itens"][ip]["estado"] = "rodando"
        try:
            r = executar_acao(acao, [ip], corpo, registrar=False)
            x = r[0] if r else {"ok": False, "erro": "sem resposta"}
        except Exception as e:
            x = {"ok": False, "erro": str(e)}
        with trava_tarefas:
            t["itens"][ip].update(estado="ok" if x.get("ok") else "falhou",
                                  msg=x.get("msg") or x.get("erro") or "",
                                  dados={k: v for k, v in x.items() if k not in ("ip",)})
        return ip, x

    with ThreadPoolExecutor(8) as ex:
        resultados = list(ex.map(um, list(t["itens"])))
    with trava_tarefas:
        t["fim"] = time.time()
    if acao == "TelaBloqueio":
        salvar_cfg_telas(corpo)
    registrar_acao(acao + " (resultado)", [ip for ip, _ in resultados],
                   [(ip, x.get("ok"), x.get("msg") or (x.get("saida") or "")[:200] or x.get("erro")) for ip, x in resultados], quem=t.get("quem"))
    log(f"tarefa {acao}: {[(ip, x.get('ok')) for ip, x in resultados]}")
    falhas = [ip for ip, x in resultados if not x.get("ok") and ip in t.get("online", [])]
    if falhas and acao != "Ligar":
        avisar("falha", f"{NOME_ACAO.get(acao, acao)}: falhou em {len(falhas)} máquina(s)",
               ", ".join(nome_pc(ip) for ip in falhas) + f" (de {len(resultados)}). Veja em Atividade, no painel.", 4, "x")
    threading.Thread(target=atualizar_status, daemon=True).start()


def estado_tarefa(tid):
    with trava_tarefas:
        t = TAREFAS.get(tid)
        if not t:
            return None
        nomes = {p["IP"]: p["Nome"] for p in ler_pcs()}
        itens = [{"ip": ip, "nome": nomes.get(ip, ip), **v} for ip, v in t["itens"].items()]
        alvo = t.get("ip")
    feitas = sum(1 for i in itens if i["estado"] in ("ok", "falhou"))
    return {"id": tid, "acao": t["acao"], "alvo": alvo, "itens": itens, "feitas": feitas, "total": len(itens),
            "ok": sum(1 for i in itens if i["estado"] == "ok"), "fim": bool(t["fim"]),
            "segundos": int((t["fim"] or time.time()) - t["inicio"])}


# ------------------------------------------------------------------ adicionar / sincronizar / remover máquinas
trava_csv = threading.Lock()
PREPARO = BASE / "servidor.py"
SEMANAL_PADRAO = {"dia": "Saturday", "hora": "10:00"}
CODIGO_VERIFICAR = r"""
$n = Get-NetAdapter -Physical | Where-Object Status -eq Up | Sort-Object ifIndex | Select-Object -First 1
[pscustomobject]@{
  hostname = $env:COMPUTERNAME
  mac      = ($n.MacAddress -replace '-', ':')
  placa    = $n.InterfaceDescription
  alunos   = @(Get-LocalGroupMember -Group 'Alunos CRJ' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
  crj      = (Test-Path 'C:\ProgramData\CRJ\restricoes.ps1')
  veyon    = (Test-Path 'C:\Program Files\Veyon\veyon-service.exe')
  windows  = (Get-CimInstance Win32_OperatingSystem).Caption
} | ConvertTo-Json -Compress
"""


def preparo_ligado():
    return porta_aberta("127.0.0.1", 8000, 0.5)


def ligar_preparo():
    """Liga o servidor de preparação (porta 8000) escondido, para rodar o preparar-pc.ps1 nas máquinas novas."""
    if not preparo_ligado():
        exe = Path(sys.executable)
        exe = exe.with_name("pythonw.exe") if exe.with_name("pythonw.exe").exists() else exe
        subprocess.Popen([str(exe), str(PREPARO)], cwd=str(BASE), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, creationflags=0x08000000)
        for _ in range(20):
            if preparo_ligado():
                break
            time.sleep(0.25)
    return preparo_ligado()


def nome_limpo(nome):
    nome = re.sub(r"\s+", " ", str(nome or "")).strip()[:40]
    return re.sub(r"^m[aá]quina", "Maquina", nome, flags=re.I)


def sugerir_nome(pcs):
    usados = {int("".join(c for c in p["Nome"] if c.isdigit()) or 0) for p in pcs}
    n = 1
    while n in usados:
        n += 1
    return f"Maquina {n}"


def verificar_maquina(ip):
    try:
        if ipaddress.ip_address(ip) not in REDE_LOCAL or eh_estudio(ip) or ip.endswith(".0") or ip.endswith(".255"):
            return {"erro": "Use um IP da rede da sala (192.168.10.x), que não seja o do estúdio."}
    except ValueError:
        return {"erro": "IP inválido. Exemplo: 192.168.10.160"}
    pcs = ler_pcs()
    ja = next((x for x in pcs if x["IP"] == ip), None)
    if ja:
        return {"erro": f"Este IP já está no painel como {ja['Nome'].replace('Maquina', 'Máquina')}."}
    if not porta_aberta(ip, 5985, 2):
        ping = subprocess.run(["ping", "-n", "1", "-w", "800", ip], capture_output=True, creationflags=0x08000000).returncode == 0
        return {"preparada": False, "responde": ping,
                "erro": ("A máquina responde na rede, mas ainda não foi preparada." if ping else
                         "Nenhum computador respondeu neste IP. Confira se está ligado e no cabo da sala.")}
    try:
        r = executar_acao("Comando", [ip], {"codigo": CODIGO_VERIFICAR}, registrar=False)
        x = r[0] if r else {}
    except Exception as e:
        x = {"ok": False, "erro": str(e)}
    if not x.get("ok"):
        return {"preparada": False, "responde": True,
                "erro": "A máquina tem acesso remoto, mas não aceitou a senha do CRJ-Admin. Rode o preparo nela de novo usando a mesma senha das outras."}
    try:
        info = json.loads((x.get("saida") or "").strip().splitlines()[-1])
    except Exception:
        return {"preparada": False, "erro": "Não consegui ler as informações da máquina: " + (x.get("saida") or "")[:200]}
    alunos = info.get("alunos") or []
    if isinstance(alunos, str):
        alunos = [alunos]
    return {"preparada": bool(info.get("crj")), "hostname": info.get("hostname"), "mac": info.get("mac"), "placa": info.get("placa"),
            "alunos": alunos, "veyon": bool(info.get("veyon")), "windows": info.get("windows"), "sugestao": sugerir_nome(pcs),
            "erro": None if info.get("crj") else "O acesso remoto funciona, mas as restrições do CRJ não foram instaladas. Rode o preparo nela."}


def adicionar_maquina(ip, nome, mac):
    nome = nome_limpo(nome)
    mac = str(mac or "").upper().replace("-", ":")
    if not nome:
        return {"erro": "Dê um nome para a máquina."}
    if not re.fullmatch(r"([0-9A-F]{2}:){5}[0-9A-F]{2}", mac):
        return {"erro": "Endereço da placa (MAC) inválido."}
    with trava_csv:
        pcs = ler_pcs()
        if any(x["IP"] == ip for x in pcs):
            return {"erro": "Este IP já está no painel."}
        if any(x["Nome"].lower() == nome.lower() for x in pcs):
            return {"erro": f"Já existe uma máquina chamada {nome.replace('Maquina', 'Máquina')}."}
        texto = CSV.read_text(encoding="utf-8")
        with open(CSV, "a", encoding="utf-8", newline="") as f:
            if texto and not texto.endswith("\n"):
                f.write("\n")
            csv.writer(f, lineterminator="\n").writerow([nome, ip, mac])
    registrar_acao("Adicionar máquina", [ip], {"nome": nome, "mac": mac})
    log(f"maquina adicionada: {nome} {ip} {mac}")
    threading.Thread(target=atualizar_status, daemon=True).start()
    return {"ok": True, "nome": nome}


def remover_maquina(ip):
    with trava_csv:
        linhas = list(csv.reader(open(CSV, encoding="utf-8", newline="")))
        cab, resto = linhas[0], [l for l in linhas[1:] if l]
        novo = [l for l in resto if len(l) > 1 and l[1] != ip]
        if len(novo) == len(resto):
            return {"erro": "Máquina não encontrada na lista."}
        (BASE / "backup").mkdir(exist_ok=True)
        (BASE / "backup" / f"computadores-{dt.datetime.now():%Y%m%d-%H%M%S}.csv").write_text(CSV.read_text(encoding="utf-8"), encoding="utf-8")
        with open(CSV, "w", encoding="utf-8", newline="") as f:
            csv.writer(f, lineterminator="\n").writerows([cab] + novo)
    with trava:
        estado["pcs"].pop(ip, None)
    c = ler_config()
    c.get("aplicado", {}).pop(ip, None)
    salvar_config(c)
    registrar_acao("Remover máquina da lista", [ip], {})
    log(f"maquina removida da lista: {ip}")
    return {"ok": True}


PASSOS_SINC = ["Bloqueio de instalação", "Horário automático", "Imagens do CRJ", "Manutenção semanal"]


def criar_sincronia(ip, passos=None, auto=False):
    """Deixa uma máquina igual às outras: bloqueio, horário, imagens e manutenção semanal. Uma tarefa com um item por passo."""
    passos = [p for p in PASSOS_SINC if not passos or p in passos]
    tid = uuid.uuid4().hex[:12]
    t = {"id": tid, "acao": "Sincronizar", "ip": ip, "inicio": time.time(), "fim": None, "auto": auto,
         "quem": "automático" if auto else quem_agora(),
         "itens": {k: {"estado": "aguardando", "msg": "", "dados": None} for k in passos}}
    with trava_tarefas:
        TAREFAS[tid] = t
    registrar_acao("Sincronização automática" if auto else "Sincronizar máquina", [ip], {"passos": passos}, quem=t["quem"])
    threading.Thread(target=_rodar_sincronia, args=(t, ip), daemon=True).start()
    return tid


def _rodar_sincronia(t, ip):
    c = ler_config()
    tl = c.get("telas") or {}
    sem = c.get("semanal") or SEMANAL_PADRAO

    def horario():
        c2 = ler_config()
        c2.get("aplicado", {}).pop(ip, None)
        salvar_config(c2)
        sincronizar_horario({ip: {"online": True}})
        ok = ler_config().get("aplicado", {}).get(ip) == versao_horario(ler_config()["horario"])
        return [{"ok": ok, "msg": "horário de cada dia aplicado" if ok else "", "erro": None if ok else "não aplicou"}]

    passos = {
        "Bloqueio de instalação": lambda: executar_acao("Aplicar", [ip], {}, registrar=False),
        "Horário automático": horario,
        "Imagens do CRJ": (lambda: executar_acao("TelaBloqueio", [ip], {"imagens": tl.get("aplicadas", []), "intervaloSeg": tl.get("intervaloSeg", 30),
                                                                          "bloqueio": tl.get("bloqueio", True), "fundo": tl.get("fundo", False)}, registrar=False))
                          if tl.get("aplicadas") else (lambda: [{"ok": True, "msg": "nenhuma imagem aplicada nas outras ainda"}]),
        "Manutenção semanal": lambda: (executar_acao("Semanal", [ip], {"dia": sem["dia"], "hora": sem["hora"], "agora": False}, registrar=False), distribuir_avisos([ip]))[0],
    }
    res = []
    for nome in list(t["itens"]):
        with trava_tarefas:
            t["itens"][nome]["estado"] = "rodando"
        try:
            r = passos[nome]()
            x = r[0] if r else {"ok": False, "erro": "sem resposta"}
        except Exception as e:
            x = {"ok": False, "erro": str(e)}
        res.append((nome, x.get("ok"), x.get("msg") or x.get("erro")))
        with trava_tarefas:
            t["itens"][nome].update(estado="ok" if x.get("ok") else "falhou", msg=x.get("msg") or x.get("erro") or "",
                                    dados={k: v for k, v in x.items() if k != "ip"})
    with trava_tarefas:
        t["fim"] = time.time()
    registrar_acao(("Sincronização automática" if t.get("auto") else "Sincronizar máquina") + " (resultado)", [ip], res, quem=t.get("quem"))
    log(f"sincronia {ip}: {[(n, ok) for n, ok, _ in res]}")
    ruins = [n for n, ok, _ in res if not ok]
    if t.get("auto"):
        if ruins:
            avisar("falha", f"{nome_pc(ip)}: não consegui atualizar sozinho", "Falhou: " + ", ".join(ruins) + ". Tento de novo em 20 min; ou use Sincronizar no painel.", 4, "x")
        else:
            avisar("auto", f"{nome_pc(ip)} atualizada sozinha", "Corrigido: " + ", ".join(n for n, _, _ in res) + ".", 2, "arrows_counterclockwise")
    threading.Thread(target=atualizar_status, daemon=True).start()


# ------------------------------------------------------------------ avisos no celular (ntfy)
AVISOS_PADRAO = {"ativo": False, "servidor": "https://ntfy.sh", "topico": "", "palavra": False,
                 "eventos": {"alerta": True, "sumiu": True, "falha": True, "auto": False, "endereco": True, "manutencao": True}}
NOME_ACAO = {"NavegadorLivre": "Liberar navegador", "Pausar": "Modo manutenção", "Aplicar": "Reativar bloqueio", "Mensagem": "Mensagem", "BloquearTela": "Bloquear tela",
             "Defeito": "Modo defeito", "DefeitoFim": "Liberar máquina", "Hibernar": "Hibernar", "Ligar": "Ligar", "Reiniciar": "Reiniciar",
             "Desligar": "Desligar", "Energia": "Energia e tela", "Otimizar": "Otimização", "Programas": "Lista de programas",
             "Desinstalar": "Desinstalar programa", "Comando": "Comando personalizado", "Semanal": "Manutenção semanal", "TelaBloqueio": "Imagens do CRJ"}
DESLIGAM = {"Hibernar", "Reiniciar", "Desligar", "Defeito", "Semanal"}
DESLIGOU = {}            # ip -> quando o painel mandou desligar/reiniciar (não é "sumiu")
VIGIA = {}               # ip -> {"off_desde", "avisado", "manut"}
trava_vigia = threading.Lock()


def nome_pc(ip):
    p = estado["pcs"].get(ip) or {}
    return (p.get("nome") or ip).replace("Maquina", "Máquina")


def cfg_avisos():
    a = dict(AVISOS_PADRAO)
    a.update(ler_config().get("avisos") or {})
    a["eventos"] = {**AVISOS_PADRAO["eventos"], **(a.get("eventos") or {})}
    return a


def enviar_ntfy(a, titulo, msg, prioridade=3, tags=""):
    corpo = {"topic": a["topico"], "title": titulo, "message": msg, "priority": int(prioridade),
             "tags": [t for t in str(tags).split(",") if t], "click": f"http://{ip_estudio()}:{PORTA}/#atividade"}
    req = urllib.request.Request(a["servidor"].rstrip("/"), data=json.dumps(corpo).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def avisar(evento, titulo, msg, prioridade=3, tags=""):
    a = cfg_avisos()
    if not (a.get("ativo") and a.get("topico") and a["eventos"].get(evento)):
        return

    def manda():
        try:
            enviar_ntfy(a, titulo, msg, prioridade, tags)
            log(f"aviso enviado ({evento}): {titulo}")
        except Exception as e:
            log(f"aviso NAO enviado ({evento}): {e}")
    threading.Thread(target=manda, daemon=True).start()


def em_aula(agora=None):
    agora = agora or dt.datetime.now()
    h = ler_config().get("horario") or {}
    d = (h.get("semana") or {}).get(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][agora.weekday()]) or {}
    if not (h.get("ativo") and d.get("ativo")):
        return False
    m = agora.hour * 60 + agora.minute
    a = [int(x) for x in d.get("abre", "14:00").split(":")]
    f = [int(x) for x in d.get("fecha", "17:30").split(":")]
    return a[0] * 60 + a[1] + 5 <= m <= f[0] * 60 + f[1] - 2


def vigiar_pc(p):
    """Avisa quando uma máquina some da rede no horário de aula e quando a manutenção de sábado dá problema."""
    ip, agora = p["ip"], time.time()
    with trava_vigia:
        v = VIGIA.setdefault(ip, {"off_desde": None, "avisado": False, "manut": p.get("manut") or ""})
        if p["online"]:
            if v["avisado"]:
                avisar("sumiu", f"{nome_pc(ip)} voltou", "A máquina respondeu de novo no painel.", 2, "white_check_mark")
            v["off_desde"], v["avisado"] = None, False
            m = p.get("manut") or ""
            if m and m != v["manut"]:
                v["manut"] = m
                amea = re.search(r"antivirus ok \((\d+) amea", m)
                if amea and int(amea.group(1)) > 0:
                    avisar("falha", f"{nome_pc(ip)}: antivírus encontrou {amea.group(1)} ameaça(s)", m, 5, "rotating_light")
                elif re.search(r"erro", m, re.I):
                    avisar("falha", f"{nome_pc(ip)}: manutenção com problema", m, 4, "warning")
        else:
            if v["off_desde"] is None:
                v["off_desde"] = agora
            intencional = agora - DESLIGOU.get(ip, 0) < 20 * 60
            if (not v["avisado"] and not intencional and not p.get("defeito") and agora - v["off_desde"] >= 90 and em_aula()):
                v["avisado"] = True
                avisar("sumiu", f"{nome_pc(ip)} sumiu da rede", "Parou de responder no horário de aula (desligada, travada ou sem cabo?).", 4, "electric_plug")


def avisar_alertas_novos():
    """Depois de coletar o histórico: avisa as pesquisas novas com palavra de alerta (só máquina e palavra, nunca a pesquisa inteira)."""
    c = ler_config()
    marca_ = (c.get("avisos_estado") or {}).get("alerta_ate")
    agora = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    c.setdefault("avisos_estado", {})["alerta_ate"] = agora
    salvar_config(c)
    if not marca_:
        return                                   # primeira vez: só marca, não avisa o passado
    rx = regex_alertas()
    con = sqlite3.connect(DB)
    linhas = con.execute("SELECT pc, termo, onde FROM pesquisas WHERE quando > ? AND quando <= ?", (marca_, agora)).fetchall()
    con.close()
    por_pc = {}
    for pc, termo, onde in linhas:
        w = palavra_alerta(rx, f"{termo} {onde or ''}")
        if w:
            por_pc.setdefault(pc, []).append(w)
    if not por_pc:
        return
    a = cfg_avisos()
    total = sum(len(v) for v in por_pc.values())
    partes = [f"{pc.replace('Maquina', 'Máquina')}: {len(ws)}" + (f" ({', '.join(sorted(set(ws)))})" if a.get("palavra") else "") for pc, ws in por_pc.items()]
    avisar("alerta", f"{total} pesquisa(s) com palavra de alerta", "; ".join(partes) + ". Abra Pesquisas no painel.", 4, "warning")


# ------------------------------------------------------------------ sincronização automática (máquina desatualizada se corrige sozinha)
AUTO = {}                # ip -> última tentativa automática
trava_auto = threading.Lock()


def pendencias(p, c, todos):
    if not p.get("online") or p.get("defeito") or str(p.get("estado", "")).startswith("PAUSADO"):
        return []
    r = []
    if str(p.get("estado", "")).startswith("ATIVO") and p.get("bloqueio") and p.get("bloqueio") != "Enabled":
        r.append("Bloqueio de instalação")
    tl = c.get("telas") or {}
    if tl.get("aplicadas") and p.get("telas_n") is not None:
        try:
            rc = json.loads(p.get("telas_cfg") or "{}")
        except Exception:
            rc = {}
        igual = (int(rc.get("intervaloSeg", -1)) == int(tl.get("intervaloSeg", 0)) and bool(rc.get("bloqueio")) == bool(tl.get("bloqueio", True))
                 and bool(rc.get("fundo")) == bool(tl.get("fundo", False)))
        if int(p["telas_n"]) != len(tl["aplicadas"]) or not igual:
            r.append("Imagens do CRJ")
    com_semanal = sum(1 for x in todos if x.get("semanal"))
    quer_semanal = c.get("semanal") or com_semanal * 2 >= len(todos)
    sem_aviso = bool(cfg_avisos().get("ativo")) and p.get("avisos_maquina") is False
    if quer_semanal and (not p.get("semanal") or p.get("verificar") is False or sem_aviso):
        r.append("Manutenção semanal")       # falta a manutenção, a verificação das 11:30 ou o tópico dos avisos
    return r


def ocupada(ip):
    with trava_tarefas:
        return any(not t["fim"] and (ip in t["itens"] or t.get("ip") == ip) for t in TAREFAS.values())


def sincronia_automatica():
    c = ler_config()
    with trava:
        todos = list(estado["pcs"].values())
    for p in todos:
        pend = pendencias(p, c, todos)
        with trava:
            if p["ip"] in estado["pcs"]:
                estado["pcs"][p["ip"]]["pendente"] = pend
        if not pend or ocupada(p["ip"]):
            continue
        with trava_auto:
            if time.time() - AUTO.get(p["ip"], 0) < 20 * 60:
                continue
            AUTO[p["ip"]] = time.time()
        log(f"sincronia automatica {p['ip']}: {pend}")
        criar_sincronia(p["ip"], pend, auto=True)


# ------------------------------------------------------------------ IP que muda: acha a máquina pela placa de rede (MAC)
VARREDURA = {"ultima": 0}
trava_varre = threading.Lock()


def tabela_arp():
    saida = subprocess.run(["arp", "-a"], capture_output=True, creationflags=0x08000000).stdout.decode("cp850", "replace")
    mapa = {}
    for ip, mac in re.findall(r"(192\.168\.10\.\d{1,3})\s+([0-9a-f]{2}(?:-[0-9a-f]{2}){5})", saida, re.I):
        mapa[mac.upper().replace("-", ":")] = ip
    return mapa


def redescobrir_ips():
    """Máquinas que não respondem no IP da lista: procura a placa de rede delas na rede e corrige o IP sozinho."""
    with trava:
        fora = [p for p in estado["pcs"].values() if not p["online"] and p.get("mac")]
    if not fora or not trava_varre.acquire(blocking=False):
        return
    try:
        if time.time() - VARREDURA["ultima"] < 5 * 60:
            return
        VARREDURA["ultima"] = time.time()
        with ThreadPoolExecutor(64) as ex:        # acorda a tabela ARP (máquinas hibernadas não respondem; tudo bem)
            list(ex.map(lambda n: subprocess.run(["ping", "-n", "1", "-w", "400", f"192.168.10.{n}"], capture_output=True,
                                                 creationflags=0x08000000), range(2, 255)))
        arp = tabela_arp()
        usados = {p["IP"] for p in ler_pcs()}
        for p in fora:
            novo_ip = arp.get(p["mac"].upper().replace("-", ":"))
            if not novo_ip or novo_ip == p["ip"] or eh_estudio(novo_ip) or novo_ip in usados or not porta_aberta(novo_ip, 5985, 2):
                continue
            with trava_csv:
                linhas = list(csv.reader(open(CSV, encoding="utf-8", newline="")))
                for l in linhas[1:]:
                    if len(l) > 1 and l[1] == p["ip"]:
                        l[1] = novo_ip
                with open(CSV, "w", encoding="utf-8", newline="") as f:
                    csv.writer(f, lineterminator="\n").writerows([l for l in linhas if l])
            with trava:
                estado["pcs"].pop(p["ip"], None)
            c = ler_config()
            if p["ip"] in c.get("aplicado", {}):
                c["aplicado"][novo_ip] = c["aplicado"].pop(p["ip"])
                salvar_config(c)
            usados.add(novo_ip)
            registrar_acao("IP da máquina mudou", [novo_ip], {"de": p["ip"], "para": novo_ip}, quem="automático")
            log(f"{p['nome']} mudou de IP: {p['ip']} -> {novo_ip} (achada pela placa {p['mac']})")
            avisar("auto", f"{nome_pc(novo_ip)} mudou de IP", f"{p['ip']} → {novo_ip}. O painel corrigiu sozinho.", 2, "arrows_counterclockwise")
    finally:
        trava_varre.release()


ENDERECO = {"ip": None}


def vigiar_endereco():
    ip = ip_estudio()
    if ENDERECO["ip"] and ip != ENDERECO["ip"] and ip != "127.0.0.1":
        registrar_acao("Endereço do painel mudou", [], {"de": ENDERECO["ip"], "para": ip}, quem="automático")
        log(f"IP do estudio mudou: {ENDERECO['ip']} -> {ip}")
        avisar("endereco", "Endereço do painel mudou", f"Agora é http://{ip}:{PORTA} (antes {ENDERECO['ip']}).", 4, "link")
    ENDERECO["ip"] = ip


# ------------------------------------------------------------------ rotinas: rede de segurança do fechamento + resumo da manutenção de sábado
DIAS_EN = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
trava_rotinas = threading.Lock()


def _hm(txt):
    h, m = [int(x) for x in str(txt).split(":")[:2]]
    return dt.timedelta(hours=h, minutes=m)


def momentos_do_dia(agora):
    """Quando checar hoje: 30 min depois do fechamento (dia de aula) e 1h30 depois do início da manutenção semanal."""
    c = ler_config()
    h = c.get("horario") or {}
    dia = DIAS_EN[agora.weekday()]
    meia_noite = agora.replace(hour=0, minute=0, second=0, microsecond=0)
    out = []
    d = (h.get("semana") or {}).get(dia) or {}
    if h.get("ativo") and d.get("ativo"):
        out.append(("fechamento", meia_noite + _hm(d.get("fecha", "17:30")) + dt.timedelta(minutes=30)))
    sem = c.get("semanal") or SEMANAL_PADRAO
    if sem.get("dia") == dia:
        out.append(("semanal", meia_noite + _hm(sem.get("hora", "10:00")) + dt.timedelta(minutes=90)))
    return out


def rede_de_seguranca(motivo):
    """Hiberna o que ficou ligado (menos modo manutenção e máquinas no meio de uma ação) e avisa no celular."""
    with trava:
        pcs = list(estado["pcs"].values())
    alvo = [p["ip"] for p in pcs if p["online"] and not str(p.get("estado", "")).startswith("PAUSADO") and not ocupada(p["ip"])]
    pulou = [nome_pc(p["ip"]) for p in pcs if p["online"] and str(p.get("estado", "")).startswith("PAUSADO")]
    if not alvo:
        log(f"rede de seguranca ({motivo}): nada ligado fora do horario" + (f"; em manutencao: {pulou}" if pulou else ""))
        return []
    registrar_acao("Rede de segurança", alvo, {"motivo": motivo, "em_manutencao_mantidas": pulou}, quem="automático")
    criar_tarefa("Hibernar", alvo, {})
    log(f"rede de seguranca ({motivo}): hibernando {alvo}")
    avisar("falha", f"Rede de segurança: {len(alvo)} máquina(s) ainda ligada(s)",
           f"Hibernei: {', '.join(nome_pc(i) for i in alvo)}. Motivo: {motivo}." + (f" Mantidas ligadas (modo manutenção): {', '.join(pulou)}." if pulou else ""), 4, "shield")
    return alvo


def resumo_manutencao(agora, atrasado=False):
    """Uma mensagem com o resultado da manutenção semanal (do dia 'agora') em todas as máquinas."""
    hoje = agora.strftime("%d/%m")
    with trava:
        pcs = list(estado["pcs"].values())
    feitas = [p for p in pcs if str(p.get("manut") or "").startswith(hoje)]
    sem_noticia = [nome_pc(p["ip"]) for p in pcs if p not in feitas]
    ameacas = [(nome_pc(p["ip"]), int(m.group(1))) for p in feitas for m in [re.search(r"antivirus ok \((\d+) amea", p["manut"])] if m and int(m.group(1)) > 0]
    atualizou = [nome_pc(p["ip"]) for p in feitas if re.search(r"\d+ atualiza", p["manut"])]
    erros = [nome_pc(p["ip"]) for p in feitas if re.search(r"erro", p["manut"], re.I)]
    mb = sum(int(m.group(1)) for p in feitas for m in [re.search(r"(\d+) MB limpos", p["manut"])] if m)
    partes = [f"{len(feitas)} de {len(pcs)} fizeram a manutenção ({mb} MB de temporários limpos)"]
    if atualizou:
        partes.append(f"instalaram atualizações: {', '.join(atualizou)}")
    if ameacas:
        partes.append("ANTIVÍRUS ACHOU AMEAÇA: " + ", ".join(f"{n} ({q})" for n, q in ameacas))
    if erros:
        partes.append(f"com erro: {', '.join(erros)}")
    if sem_noticia:
        partes.append(f"sem notícia (desligada/fora da rede?): {', '.join(sem_noticia)}")
    tudo_ok = not (ameacas or erros or sem_noticia)
    registrar_acao("Resumo da manutenção semanal", [], {"feitas": len(feitas), "total": len(pcs), "atualizaram": atualizou, "erros": erros,
                                                        "sem_noticia": sem_noticia, "ameacas": ameacas}, quem="automático")
    log("resumo da manutencao: " + "; ".join(partes))
    avisar("manutencao", ("Manutenção de " + hoje + ": " if atrasado else "Manutenção de sábado: ") + ("tudo certo ✅" if tudo_ok else "ver detalhes"), "; ".join(partes) + ".", 5 if ameacas else 4 if not tudo_ok else 3, "wrench")
    return partes


def distribuir_avisos(ips=None):
    """Grava em cada máquina o tópico do ntfy (arquivo que só SISTEMA/administradores leem): no fim de semana,
    com o estúdio desligado, a própria máquina avisa o celular se algo der errado na manutenção."""
    a = cfg_avisos()
    with trava:
        alvo = [p for p in estado["pcs"].values() if p["online"] and (ips is None or p["ip"] in ips)]
    ok = []
    for p in alvo:
        dados = json.dumps({"ativo": bool(a.get("ativo")), "servidor": a.get("servidor"), "topico": a.get("topico"),
                            "falha": bool(a["eventos"].get("falha")), "nome": nome_pc(p["ip"])}, ensure_ascii=False)
        b64 = base64.b64encode(dados.encode("utf-8")).decode()
        cod = ("$f = 'C:\\ProgramData\\CRJ\\avisos.json'; [IO.File]::WriteAllText($f, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + b64 + "')))\n"
               "icacls $f /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /Q | Out-Null; 'ok'")
        try:
            r = executar_acao("Comando", [p["ip"]], {"codigo": cod}, registrar=False)
            if r and r[0].get("ok"):
                ok.append(p["ip"])
        except Exception as e:
            log(f"distribuir_avisos {p['ip']}: {e}")
    log(f"avisos gravados nas maquinas: {ok}")
    return ok


def ultimo_semanal(agora):
    """Data da última manutenção semanal antes de hoje (para mandar o resumo atrasado quando o estúdio volta a ligar)."""
    sem = ler_config().get("semanal") or SEMANAL_PADRAO
    alvo = DIAS_EN.index(sem.get("dia", "Saturday"))
    for n in range(1, 8):
        d = agora - dt.timedelta(days=n)
        if d.weekday() == alvo:
            return d.replace(hour=0, minute=0, second=0, microsecond=0)


def verificar_rotinas(agora=None):
    agora = agora or dt.datetime.now()
    if not trava_rotinas.acquire(blocking=False):
        return
    try:
        c = ler_config()
        feitas = c.get("rotinas") or {}
        for chave, quando in momentos_do_dia(agora):
            marca_ = f"{chave}:{agora:%Y-%m-%d}"
            if marca_ in feitas.values() or not (quando <= agora < quando + dt.timedelta(hours=3)):
                continue
            feitas[chave] = marca_
            c = ler_config()
            c["rotinas"] = feitas
            salvar_config(c)
            if chave == "semanal":
                resumo_manutencao(agora)
                if not em_aula(agora):
                    rede_de_seguranca("manutenção semanal terminou e a sala está fechada")
            else:
                rede_de_seguranca("30 minutos depois do fechamento da sala")
        # estúdio estava desligado no fim de semana: manda o resumo da última manutenção quando as máquinas aparecerem
        ref = ultimo_semanal(agora)
        marca_ = f"semanal:{ref:%Y-%m-%d}" if ref else None
        if ref and (agora - ref).days <= 4 and marca_ not in feitas.values():
            with trava:
                pcs = list(estado["pcs"].values())
            com_dado = sum(1 for p in pcs if str(p.get("manut") or "").startswith(ref.strftime("%d/%m")))
            if pcs and (com_dado * 2 >= len(pcs) or agora.hour >= 16):
                feitas["semanal"] = marca_
                c = ler_config()
                c["rotinas"] = feitas
                salvar_config(c)
                resumo_manutencao(ref, atrasado=True)
    finally:
        trava_rotinas.release()


# ------------------------------------------------------------------ atividade (histórico de ações, para a aba Atividade)
RX_LINHA = re.compile(r"^\[(\d\d/\d\d/\d{4} \d\d:\d\d:\d\d)\] (.+?) em (.*?)(?: · por (.+))?$")


def ler_atividade(dias=7, limite=600):
    if not LOG_ACOES.exists():
        return []
    desde = dt.datetime.now() - dt.timedelta(days=dias)
    nomes = {p["IP"]: p["Nome"] for p in ler_pcs()}
    linhas = LOG_ACOES.read_text(encoding="utf-8", errors="replace").splitlines()
    itens, abertos = [], {}
    i = 0
    while i < len(linhas):
        m = RX_LINHA.match(linhas[i])
        det = None
        if m and i + 1 < len(linhas) and linhas[i + 1].startswith("    "):
            try:
                det = json.loads(linhas[i + 1].strip())
            except Exception:
                det = linhas[i + 1].strip()
            i += 1
        i += 1
        if not m:
            continue
        quando = dt.datetime.strptime(m.group(1), "%d/%m/%Y %H:%M:%S")
        if quando < desde:
            continue
        acao, alvos, quem = m.group(2), [a for a in m.group(3).split(", ") if a], m.group(4) or ""
        if acao.endswith(" (resultado)"):
            base = acao[:-len(" (resultado)")]
            res = [{"alvo": nomes.get(str(r[0]), str(r[0])), "ok": bool(r[1]), "msg": str(r[2] or "")} for r in (det or []) if isinstance(r, (list, tuple)) and len(r) >= 2]
            j = abertos.pop((base, tuple(sorted(alvos))), None)
            if j is None:
                j = abertos.pop(base, None)
            if j is not None and itens[j]["resultado"] is None:
                itens[j]["resultado"] = res
                itens[j]["fim"] = quando.strftime("%H:%M:%S")
                continue
            itens.append({"quando": quando.strftime("%Y-%m-%d %H:%M:%S"), "acao": base, "alvos": alvos, "quem": quem, "detalhe": None, "resultado": res, "fim": None})
            continue
        itens.append({"quando": quando.strftime("%Y-%m-%d %H:%M:%S"), "acao": acao, "alvos": alvos, "quem": quem, "detalhe": det, "resultado": None, "fim": None})
        abertos[(acao, tuple(sorted(alvos)))] = len(itens) - 1
        abertos[acao] = len(itens) - 1
    itens.reverse()
    return itens[:limite]


# ------------------------------------------------------------------ Assistente (IA pelo Groq)
# Regras: a IA só LÊ por conta própria; ações viram PROPOSTAS que o educador confirma no painel.
# Nunca recebe o texto das pesquisas dos alunos (só contagem de alertas por máquina).
GROQ = "https://api.groq.com/openai/v1"
MODELOS_PREFERIDOS = ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "moonshotai/kimi-k2-instruct", "meta-llama/llama-4-maverick-17b-128e-instruct"]
RESERVA_MODELOS = ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "openai/gpt-oss-20b", "qwen/qwen3.8-27b", "moonshotai/kimi-k2-instruct", "meta-llama/llama-4-scout-17b-16e-instruct", "llama-3.1-8b-instant"]
ACOES_IA = {"Hibernar", "Ligar", "Reiniciar", "Desligar", "Mensagem", "BloquearTela", "Pausar", "Aplicar", "Defeito", "DefeitoFim", "Sincronizar", "NavegadorLivre"}


class _Blob(ctypes.Structure):
    _fields_ = [("cbData", ctypes.wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _dpapi(dados, cifrar):
    buf = ctypes.create_string_buffer(dados, len(dados))
    ent, sai = _Blob(len(dados), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), _Blob()
    f = ctypes.windll.crypt32.CryptProtectData if cifrar else ctypes.windll.crypt32.CryptUnprotectData
    if not f(ctypes.byref(ent), None, None, None, None, 0, ctypes.byref(sai)):
        raise OSError("DPAPI falhou")
    try:
        return ctypes.string_at(sai.pbData, sai.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(sai.pbData)


def ia_cfg():
    return ler_config().get("ia") or {}


def ia_chave():
    c = ia_cfg().get("chave")
    return _dpapi(base64.b64decode(c), False).decode() if c else ""


def groq(caminho, corpo=None, chave=None, timeout=60):
    req = urllib.request.Request(GROQ + caminho, data=json.dumps(corpo).encode() if corpo is not None else None,
                                 headers={"Authorization": f"Bearer {chave or ia_chave()}", "Content-Type": "application/json",
                                          "User-Agent": "CRJ-Painel/1.0"}, method="POST" if corpo is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        txt = e.read().decode("utf-8", "replace")[:400]
        if e.code == 401:
            raise RuntimeError("Chave do Groq inválida. Confira em Configurar.")
        if e.code == 429:
            raise RuntimeError("O limite gratuito do Groq foi atingido por agora. Tente de novo em alguns minutos.")
        raise RuntimeError(f"Groq respondeu {e.code}: {txt}")


def escolher_modelo(chave, desejado=None):
    ids = [m["id"] for m in groq("/models", chave=chave).get("data", [])]
    if desejado and desejado in ids:
        return desejado, ids
    for m in MODELOS_PREFERIDOS:
        if m in ids:
            return m, ids
    return (ids[0] if ids else ""), ids


CODIGO_DIAG = r"""
$os = Get-CimInstance Win32_OperatingSystem; $d = Get-PSDrive C
$n = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1; $s = if ($n) { Get-NetAdapterStatistics -Name $n.Name }
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
[pscustomobject]@{
  ligada_desde = $os.LastBootUpTime.ToString('dd/MM HH:mm'); horas_ligada = [int]((Get-Date) - $os.LastBootUpTime).TotalHours
  disco_livre_gb = [math]::Round($d.Free / 1GB, 1); disco_total_gb = [math]::Round(($d.Used + $d.Free) / 1GB, 1)
  memoria_livre_mb = [int]($os.FreePhysicalMemory / 1KB); memoria_total_mb = [int]($os.TotalVisibleMemorySize / 1KB)
  cpu_uso_pct = [int](Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
  rede = if ($n) { "$($n.LinkSpeed); erros recebidos $($s.ReceivedPacketErrors) de $($s.ReceivedUnicastPackets) pacotes" } else { 'sem placa ativa' }
  programas_mais_memoria = (Get-Process | Sort-Object WS -Descending | Select-Object -First 6 | ForEach-Object { "$($_.ProcessName) $([int]($_.WS / 1MB)) MB" }) -join ', '
  ultima_manutencao = [string](Get-Content C:\ProgramData\CRJ\manutencao-ultima.txt -ErrorAction SilentlyContinue)
  windows = "$($os.Caption) build $($os.BuildNumber)"
  reinicio_pendente = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
  antivirus = if ($mp) { "tempo real=$($mp.RealTimeProtectionEnabled), assinaturas de $($mp.AntivirusSignatureLastUpdated.ToString('dd/MM'))" } else { '?' }
  ameacas_7_dias = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-7) }).Count
  erros_do_windows_24h = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 100 -ErrorAction SilentlyContinue).Count
} | ConvertTo-Json -Compress
"""

FERRAMENTAS = [
    {"type": "function", "function": {"name": "machine_status", "description": "Situação atual de todas as máquinas da sala: ligada, bloqueio, manutenção, defeito, usuário logado, desde quando está ligada, último sinal, manutenção semanal, pendências.", "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "diagnose_machine", "description": "Diagnóstico detalhado de UMA máquina ligada: disco, memória, processador, rede (erros), programas pesados, antivírus, atualizações, erros do Windows. Demora uns 10-20 segundos.", "parameters": {"type": "object", "properties": {"maquina": {"type": "string", "description": "Nome (ex.: 'Máquina 3') ou IP"}}, "required": ["maquina"]}}},
    {"type": "function", "function": {"name": "recent_activity", "description": "O que o painel fez recentemente (ações, quem fez, resultados, falhas, correções automáticas).", "parameters": {"type": "object", "properties": {"dias": {"type": "integer", "description": "1 a 30"}, "so_falhas": {"type": "boolean"}}}}},
    {"type": "function", "function": {"name": "search_alerts", "description": "Quantas pesquisas com palavra de alerta houve por máquina (hoje e 7 dias). NUNCA traz o texto das pesquisas.", "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "room_schedule", "description": "Horário de funcionamento por dia (abre/fecha) e dia/hora da manutenção semanal.", "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "propose_action", "description": "PROPÕE uma ação nas máquinas. NÃO executa: o educador confirma no painel. Ações: Hibernar, Ligar, Reiniciar, Desligar, Mensagem (precisa 'texto'), BloquearTela, NavegadorLivre (libera SÓ o navegador: aba anônima/InPrivate, convidado, extensões, busca segura; o bloqueio de programas continua; 'horas' 1-12 ou 0 = até reativar), Pausar (modo manutenção: libera TUDO, inclusive instalar programas; 'horas' 1-4), Aplicar (reativar todas as restrições, inclusive do navegador), Defeito, DefeitoFim (liberar máquina com defeito), Sincronizar.", "parameters": {"type": "object", "properties": {"acao": {"type": "string", "enum": sorted(ACOES_IA)}, "maquinas": {"type": "array", "items": {"type": "string"}, "description": "Nomes ou IPs; use ['todas'] para todas as ligadas"}, "texto": {"type": "string"}, "horas": {"type": "integer"}, "motivo": {"type": "string", "description": "Por que você sugere isso, em uma frase"}}, "required": ["acao", "maquinas", "motivo"]}}},
]

PROMPT_IA = """Você é o Assistente do Painel da Informática do CRJ Flexal (sala de informática para jovens). Fala com o educador Gillead, em português do Brasil, de forma curta e prática.
Você ajuda a consultar, diagnosticar e cuidar das máquinas da sala usando as ferramentas. Regras:
- Use as ferramentas para buscar dados reais; nunca invente números, nomes ou estados. Se não souber, diga.
- Você NÃO executa ações. Para agir (hibernar, ligar, reiniciar, mensagem, bloquear tela, liberar navegador, manutenção, defeito, sincronizar), chame propose_action; o educador confirma no painel.
- Pedidos para liberar aba anônima, InPrivate, extensões ou restrições do navegador = NavegadorLivre (não use Pausar, que libera também a instalação de programas). Para voltar ao normal = Aplicar.
- Use SOMENTE estas ferramentas, com estes nomes exatos: machine_status, diagnose_machine, recent_activity, search_alerts, room_schedule, propose_action. Diga que a proposta está aguardando confirmação.
- Você não tem acesso ao texto das pesquisas dos alunos, só à quantidade de alertas. Se pedirem o conteúdo, explique que fica só no painel (aba Pesquisas).
- Explique diagnósticos em linguagem simples: o que está errado, a causa provável e o que fazer. Destaque o que for grave.
- Máquinas se chamam "Máquina N". Responda em poucas linhas; use listas curtas quando ajudar."""


def _achar_ips(nomes):
    pcs = ler_pcs()
    if any(str(n).strip().lower() in ("todas", "todas as máquinas", "todas as maquinas", "all") for n in nomes):
        return [p["ip"] for p in estado["pcs"].values() if p["online"]] or [p["IP"] for p in pcs]
    ips = []
    for n in nomes:
        n = str(n).strip()
        dig = "".join(c for c in n if c.isdigit())
        for p in pcs:
            num = "".join(c for c in p["Nome"] if c.isdigit())
            if n == p["IP"] or n.lower() == p["Nome"].lower() or (dig and not n.count(".") and dig == num):
                ips.append(p["IP"])
    return list(dict.fromkeys(ips))


APELIDOS_FERR = {"machine_status": "estado_maquinas", "diagnose_machine": "diagnosticar", "recent_activity": "atividade", "search_alerts": "alertas",
                 "room_schedule": "horario_da_sala", "propose_action": "propor_acao", "activity": "atividade", "diagnose": "diagnosticar",
                 "alerts": "alertas", "schedule": "horario_da_sala", "status": "estado_maquinas"}


def _ferramenta(nome, args, propostas):
    nome = APELIDOS_FERR.get(nome, nome)
    if nome == "estado_maquinas":
        with trava:
            pcs = list(estado["pcs"].values())
        return [{"maquina": nome_pc(p["ip"]), "ip": p["ip"], "ligada": p["online"], "situacao": ("defeito" if p.get("defeito") else "manutencao" if str(p.get("estado", "")).startswith("PAUSADO") else "bloqueada" if p.get("bloqueio") == "Enabled" else "desligada" if not p["online"] else "bloqueio desligado!"),
                 "usuario": p.get("logado") or None, "navegador_liberado": p.get("navegador") or None, "ligada_desde": p.get("boot") or None, "ultimo_sinal": p.get("visto"), "manutencao_semanal": p.get("semanal"),
                 "ultima_manutencao": p.get("manut") or None, "pendencias": p.get("pendente") or []} for p in pcs]
    if nome == "diagnosticar":
        ips = _achar_ips([args.get("maquina", "")])
        if not ips:
            return {"erro": "Máquina não encontrada. Use o nome (Máquina 3) ou o IP."}
        ip = ips[0]
        if not (estado["pcs"].get(ip) or {}).get("online"):
            return {"erro": f"{nome_pc(ip)} está desligada ou sem resposta agora; não dá para diagnosticar."}
        r = executar_acao("Comando", [ip], {"codigo": CODIGO_DIAG}, registrar=False)
        x = r[0] if r else {}
        registrar_acao("Diagnóstico pelo Assistente", [ip], {}, quem=quem_agora())
        try:
            return {"maquina": nome_pc(ip), **json.loads((x.get("saida") or "").strip().splitlines()[-1])}
        except Exception:
            return {"erro": "Não consegui ler o diagnóstico: " + str(x.get("erro") or x.get("saida") or "")[:200]}
    if nome == "atividade":
        dias = max(1, min(30, int(args.get("dias") or 1)))
        itens = ler_atividade(dias, 40)
        if args.get("so_falhas"):
            itens = [e for e in itens if any(not r["ok"] for r in (e.get("resultado") or []))]
        return [{"quando": e["quando"][5:16], "acao": NOME_ACAO.get(e["acao"], e["acao"]), "maquinas": [a.replace("Maquina", "Máquina") for a in e["alvos"]][:12], "por": e["quem"],
                 "resultado": (f"{sum(1 for r in e['resultado'] if r['ok'])}/{len(e['resultado'])} ok" + "".join(f"; FALHOU {r['alvo']}: {r['msg'][:60]}" for r in e["resultado"] if not r["ok"])[:200] if e.get("resultado") else None)} for e in itens[:25]]
    if nome == "alertas":
        rx = regex_alertas()
        hoje = dt.datetime.now().strftime("%Y-%m-%d 00:00:00")
        semana = (dt.datetime.now() - dt.timedelta(days=7)).strftime("%Y-%m-%d 00:00:00")
        con = sqlite3.connect(DB)
        linhas = con.execute("SELECT pc, quando, termo, onde FROM pesquisas WHERE quando >= ?", (semana,)).fetchall()
        con.close()
        cont = {}
        for pc, quando, termo, onde in linhas:
            if palavra_alerta(rx, f"{termo} {onde or ''}"):
                c = cont.setdefault(pc.replace("Maquina", "Máquina"), {"hoje": 0, "7_dias": 0})
                c["7_dias"] += 1
                c["hoje"] += quando >= hoje
        return {"por_maquina": cont, "observacao": "Só contagens. O texto das pesquisas fica no painel, aba Pesquisas."}
    if nome == "horario_da_sala":
        c = ler_config()
        h = c.get("horario") or {}
        return {"controle_ativo": h.get("ativo"), "semana": h.get("semana"), "manutencao_semanal": c.get("semanal") or SEMANAL_PADRAO}
    if nome == "propor_acao":
        acao = args.get("acao")
        if acao not in ACOES_IA:
            return {"erro": "Ação não permitida."}
        ips = _achar_ips(args.get("maquinas") or [])
        if not ips:
            return {"erro": "Nenhuma máquina reconhecida. Use nomes como 'Máquina 3' ou 'todas'."}
        if acao == "Mensagem" and not str(args.get("texto") or "").strip():
            return {"erro": "Mensagem precisa do campo texto."}
        p = {"acao": acao, "ips": ips, "maquinas": [nome_pc(i) for i in ips], "motivo": str(args.get("motivo") or "")[:200]}
        if acao == "Mensagem":
            p["texto"] = str(args["texto"])[:250]
        if acao == "Pausar":
            p["horas"] = max(1, min(4, int(args.get("horas") or 3)))
        if acao == "NavegadorLivre":
            p["horas"] = max(0, min(12, int(args.get("horas") if args.get("horas") is not None else 3)))
        propostas.append(p)
        return {"ok": True, "status": "proposta criada; aguardando o educador confirmar no painel", "maquinas": p["maquinas"]}
    return {"erro": "ferramenta desconhecida"}


def ia_conversar(mensagens):
    cfg = ia_cfg()
    if not cfg.get("chave"):
        return {"erro": "O Assistente ainda não foi configurado. Clique em Configurar e cole a chave do Groq."}
    hist = [{"role": m["role"], "content": str(m.get("content") or "")[:4000]} for m in mensagens[-16:] if m.get("role") in ("user", "assistant")]
    agora = dt.datetime.now()
    dia = ["segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado", "domingo"][agora.weekday()]
    msgs = [{"role": "system", "content": PROMPT_IA + f"\nAgora: {dia}, {agora:%d/%m/%Y %H:%M}."}] + hist
    propostas, usadas = [], []
    for _ in range(6):
        r = None
        disponiveis = cfg.get("modelos") or []
        modelos = [cfg.get("modelo") or MODELOS_PREFERIDOS[0]] + [m for m in RESERVA_MODELOS if m in disponiveis and m != cfg.get("modelo")]
        mi, tentativa = 0, 0
        while True:
            modelo = modelos[mi]
            corpo = {"model": modelo, "messages": msgs, "tools": FERRAMENTAS, "tool_choice": "auto",
                     "temperature": 0.2 if tentativa == 0 else 0.5, "max_tokens": 2000}
            if "gpt-oss" in modelo:
                corpo["reasoning_effort"] = "low"
            try:
                r = groq("/chat/completions", corpo)
            except RuntimeError as e:
                if "limite gratuito" in str(e) and mi + 1 < len(modelos):
                    log(f"assistente: limite do {modelo}; usando {modelos[mi + 1]}")
                    mi += 1
                    continue
                if "tool_use_failed" in str(e) and tentativa < 2:
                    tentativa += 1
                    log(f"assistente: ferramenta invalida, tentando de novo ({e})"[:300])
                    continue
                if "tool_use_failed" in str(e):
                    return {"erro": "O assistente se confundiu ao consultar os dados. Tente perguntar de novo, com outras palavras."}
                raise
            m0 = r["choices"][0]["message"]
            if not m0.get("tool_calls") and not (m0.get("content") or "").strip() and tentativa < 2:
                tentativa += 1
                log("assistente: resposta vazia, tentando de novo")
                continue
            break
        m = r["choices"][0]["message"]
        chamadas = m.get("tool_calls") or []
        if not chamadas:
            return {"resposta": (m.get("content") or "").strip() or "(sem resposta)", "propostas": propostas, "ferramentas": usadas}
        msgs.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": chamadas})
        for c in chamadas:
            nome = c["function"]["name"]
            try:
                args = json.loads(c["function"].get("arguments") or "{}")
            except Exception:
                args = {}
            usadas.append({"nome": nome, "args": args})
            try:
                res = _ferramenta(nome, args, propostas)
            except Exception as e:
                res = {"erro": str(e)}
            msgs.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(res, ensure_ascii=False, default=str)[:6000]})
    return {"resposta": "Precisei de passos demais para responder. Tente perguntar de forma mais direta.", "propostas": propostas, "ferramentas": usadas}


# ------------------------------------------------------------------ acesso pela rede (senha)
REDE_LOCAL = ipaddress.ip_network("192.168.10.0/24")
IPS_LOCAIS = {"127.0.0.1", "::1"}       # o próprio PC do estúdio entra direto (o IP de rede dele é descoberto em ip_estudio)


def ip_estudio():
    """IP atual deste PC na rede da sala (o roteador pode trocar; nada fica preso ao 192.168.10.124)."""
    try:
        so = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        so.connect(("192.168.10.1", 9))
        ip = so.getsockname()[0]
        so.close()
        return ip
    except Exception:
        return "127.0.0.1"


def eh_estudio(ip):
    return ip in IPS_LOCAIS or ip == ip_estudio()
SESSOES = {}
FALHAS_LOGIN = {}
DURACAO_SESSAO = 12 * 3600


def gerar_hash(senha):
    sal = os.urandom(16)
    return {"sal": sal.hex(), "hash": hashlib.pbkdf2_hmac("sha256", senha.encode(), sal, 200_000).hex(), "iter": 200_000}


def conferir_senha(senha, dados):
    if not dados:
        return False
    h = hashlib.pbkdf2_hmac("sha256", senha.encode(), bytes.fromhex(dados["sal"]), int(dados.get("iter", 200_000)))
    return hmac.compare_digest(h.hex(), dados["hash"])


# ------------------------------------------------------------------ HTTP
class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, codigo=200):
        dados = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(dados)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(dados)

    # ---------- porteiro: só a rede da sala; fora do estúdio precisa de senha
    def _cookie(self, nome):
        for parte in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = parte.strip().partition("=")
            if k == nome:
                return v
        return ""

    def _local(self):
        return eh_estudio(self.client_address[0])

    def _autenticado(self):
        if self._local():
            return True
        tok = self._cookie("crj_sessao")
        exp = SESSOES.get(tok)
        if exp and exp > time.time():
            return True
        SESSOES.pop(tok, None)
        return False

    def _arquivo(self, caminho, tipo, cache="no-store"):
        dados = caminho.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", tipo)
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def _porteiro(self, api):
        ip = self.client_address[0]
        try:
            na_rede = self._local() or ipaddress.ip_address(ip) in REDE_LOCAL
        except ValueError:
            na_rede = False
        if not na_rede:
            log(f"acesso recusado de {ip} (fora da rede da sala)")
            corpo = ("<!DOCTYPE html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
                     "<body style='margin:0;min-height:100vh;display:grid;place-items:center;background:#08090a;color:#eeeff1;font:15px system-ui;text-align:center;padding:24px'>"
                     f"<div><div style='font-size:40px'>&#128274;</div><h2>Fora da rede da sala</h2><p style='color:#8a8f98'>Este aparelho ({ip}) não está na rede 192.168.10.x do CRJ.<br>Conecte no Wi-Fi da sala e tente de novo.</p></div>").encode()
            self.send_response(403); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(corpo))); self.end_headers(); self.wfile.write(corpo)
            return False
        if self._autenticado() or urlparse(self.path).path == "/api/login":
            return True
        if api:
            self._json({"erro": "login necessário", "login": True}, 401)
        else:
            self._arquivo(AQUI / "login.html", "text/html; charset=utf-8")
        return False

    def _login(self, corpo):
        ip = self.client_address[0]
        agora = time.time()
        falhas = [t for t in FALHAS_LOGIN.get(ip, []) if agora - t < 300]
        if len(falhas) >= 5:
            return self._json({"erro": "Muitas tentativas. Espere 5 minutos e tente de novo."}, 429)
        dados = ler_config().get("acesso")
        if not dados:
            return self._json({"erro": "A senha de acesso ainda não foi criada. Crie no PC do estúdio, no menu “Acesso pela rede”."}, 400)
        if not conferir_senha(str(corpo.get("senha", "")), dados):
            FALHAS_LOGIN[ip] = falhas + [agora]
            time.sleep(1)
            return self._json({"erro": "Senha incorreta."}, 401)
        FALHAS_LOGIN.pop(ip, None)
        tok = secrets.token_urlsafe(32)
        SESSOES[tok] = agora + DURACAO_SESSAO
        registrar_acao("Login pela rede", [], {"de": ip})
        corpo_r = b'{"ok": true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", f"crj_sessao={tok}; Path=/; Max-Age={DURACAO_SESSAO}; HttpOnly; SameSite=Strict")
        self.send_header("Content-Length", str(len(corpo_r)))
        self.end_headers()
        self.wfile.write(corpo_r)

    def do_GET(self):
        u = urlparse(self.path)
        CTX.quem = "estúdio" if self._local() else f"rede ({self.client_address[0]})"
        if not self._porteiro(api=u.path.startswith("/api/")):
            return
        if u.path in ("/", "/index.html"):
            self._arquivo(AQUI / "index.html", "text/html; charset=utf-8")   # sempre a versao mais nova do painel
        elif u.path == "/apresentacao":
            self._arquivo(AQUI / "apresentacao.html", "text/html; charset=utf-8")
        elif u.path.startswith("/apresentacao/"):
            arq = (AQUI / "apresentacao" / Path(unquote_plus(u.path[len("/apresentacao/"):])).name).resolve()
            if arq.parent != (AQUI / "apresentacao").resolve() or not arq.is_file() or arq.suffix.lower() not in EXT_IMG:
                return self.send_error(404)
            self._arquivo(arq, EXT_IMG[arq.suffix.lower()], "max-age=600")
        elif u.path.startswith("/api/tarefa/"):
            t = estado_tarefa(u.path.rsplit("/", 1)[-1])
            return self._json(t) if t else self._json({"erro": "tarefa não encontrada"}, 404)
        elif u.path == "/api/atividade":
            q = parse_qs(u.query)
            return self._json({"itens": ler_atividade(int((q.get("dias") or ["7"])[0] or 7))})
        elif u.path == "/api/ia":
            c = ia_cfg()
            return self._json({"configurada": bool(c.get("chave")), "modelo": c.get("modelo", ""), "modelos": c.get("modelos", []), "local": self._local()})
        elif u.path == "/api/avisos":
            a = cfg_avisos()
            return self._json({**a, "local": self._local()})
        elif u.path == "/api/maquinas/preparo":
            return self._json({"ligado": preparo_ligado(), "comando": f"irm http://{ip_estudio()}:8000/preparar-pc.ps1 | iex"})
        elif u.path == "/api/acesso":
            self._json({"definida": bool(ler_config().get("acesso")), "local": self._local(),
                        "endereco": f"http://{ip_estudio()}:{PORTA}", "sessoes": sum(1 for v in SESSOES.values() if v > time.time())})
        elif u.path == "/api/estado":
            with trava:
                pcs = list(estado["pcs"].values())
            c = ler_config()
            v = versao_horario(c["horario"])
            for p in pcs:
                p["horario_sync"] = c["aplicado"].get(p["ip"]) == v
            self._json({"pcs": pcs, "atualizado": estado["atualizado"], "horario": c["horario"],
                        "hist_atualizado": estado["hist_atualizado"], "hist_rodando": estado["hist_rodando"]})
        elif u.path == "/api/telas":
            TELAS.mkdir(exist_ok=True)
            c = ler_config().get("telas", {})
            lista = [{"nome": f.name, "kb": f.stat().st_size // 1024,
                      "data": dt.datetime.fromtimestamp(f.stat().st_mtime).strftime("%d/%m %H:%M")}
                     for f in sorted(TELAS.iterdir()) if f.suffix.lower() in EXT_IMG]
            seg = c.get("intervaloSeg", int(c.get("intervalo", 0) or 0) * 60)   # formato antigo era em minutos
            self._json({"imagens": lista, "aplicadas": c.get("aplicadas", []), "intervaloSeg": seg,
                        "bloqueio": c.get("bloqueio", True), "fundo": c.get("fundo", False), "quando": c.get("quando")})
        elif u.path.startswith("/telas/"):
            nome = unquote_plus(u.path[len("/telas/"):])
            arq = (TELAS / nome).resolve()
            if arq.parent != TELAS.resolve() or not arq.is_file() or arq.suffix.lower() not in EXT_IMG:
                return self.send_error(404)
            dados = arq.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", EXT_IMG[arq.suffix.lower()])
            self.send_header("Content-Length", str(len(dados)))
            self.send_header("Cache-Control", "max-age=3600")
            self.end_headers()
            self.wfile.write(dados)
        elif u.path == "/api/alertas":
            self._json({"palavras": ler_config().get("alertas", ALERTAS_PADRAO), **resumo_alertas()})
        elif u.path == "/api/historico":
            self._json({"linhas": consultar_historico(parse_qs(u.query))})
        else:
            self.send_error(404)

    def do_POST(self):
        CTX.quem = "estúdio" if self._local() else f"rede ({self.client_address[0]})"
        if not self._porteiro(api=True):
            return
        if self.headers.get("X-CRJ") != "1":          # protege contra outros sites
            self.send_error(403)
            return
        n = int(self.headers.get("Content-Length", 0) or 0)
        corpo = json.loads(self.rfile.read(n) or b"{}")
        u = urlparse(self.path)
        try:
            if u.path == "/api/login":
                return self._login(corpo)
            if u.path == "/api/sair":
                SESSOES.pop(self._cookie("crj_sessao"), None)
                self.send_response(200)
                self.send_header("Set-Cookie", "crj_sessao=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")
                return
            if u.path == "/api/ia/config":
                if not self._local():
                    return self._json({"erro": "A chave só pode ser configurada no PC do estúdio."}, 403)
                chave = str(corpo.get("chave") or "").strip() or ia_chave()
                if not chave:
                    return self._json({"erro": "Cole a chave do Groq (começa com gsk_)."}, 400)
                try:
                    modelo, ids = escolher_modelo(chave, str(corpo.get("modelo") or "").strip() or ia_cfg().get("modelo"))
                except Exception as e:
                    return self._json({"erro": f"Não consegui falar com o Groq: {e}"}, 400)
                if not modelo:
                    return self._json({"erro": "O Groq não retornou nenhum modelo para esta chave."}, 400)
                c = ler_config()
                c["ia"] = {"chave": base64.b64encode(_dpapi(chave.encode(), True)).decode(), "modelo": modelo,
                           "modelos": [i for i in ids if not re.search(r"whisper|tts|guard|playai|orpheus|distil", i)]}
                salvar_config(c)
                registrar_acao("Assistente configurado", [], {"modelo": modelo})
                return self._json({"ok": True, "modelo": modelo})
            if u.path == "/api/ia/chat":
                try:
                    return self._json(ia_conversar(corpo.get("mensagens") or []))
                except Exception as e:
                    return self._json({"erro": str(e)})
            if u.path in ("/api/avisos", "/api/avisos/teste"):
                a = cfg_avisos()
                for k in ("ativo", "palavra"):
                    if k in corpo:
                        a[k] = bool(corpo[k])
                for k in ("servidor", "topico"):
                    if k in corpo:
                        a[k] = str(corpo[k]).strip()
                if isinstance(corpo.get("eventos"), dict):
                    a["eventos"] = {k: bool(corpo["eventos"].get(k, v)) for k, v in a["eventos"].items()}
                if a["topico"] and not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", a["topico"]):
                    return self._json({"erro": "O tópico só pode ter letras, números, - e _ (sem espaços nem acentos)."}, 400)
                if not re.match(r"^https?://", a["servidor"]):
                    return self._json({"erro": "Servidor inválido. Ex.: https://ntfy.sh"}, 400)
                if u.path.endswith("/teste"):
                    if not a["topico"]:
                        return self._json({"erro": "Escreva o tópico primeiro."}, 400)
                    try:
                        enviar_ntfy(a, "Painel da Informática · CRJ", "Teste de aviso: está funcionando! ✅", 3, "tada")
                    except Exception as e:
                        return self._json({"erro": f"Não consegui enviar: {e}"}, 502)
                    return self._json({"ok": True})
                c = ler_config()
                c["avisos"] = a
                salvar_config(c)
                threading.Thread(target=distribuir_avisos, daemon=True).start()
                registrar_acao("Avisos no celular", [], {"ativo": a["ativo"], "eventos": a["eventos"]})
                return self._json({"ok": True})
            if u.path == "/api/maquinas/preparo":
                return self._json({"ligado": ligar_preparo(), "comando": f"irm http://{ip_estudio()}:8000/preparar-pc.ps1 | iex"})
            if u.path == "/api/maquinas/verificar":
                return self._json(verificar_maquina(str(corpo.get("ip", "")).strip()))
            if u.path == "/api/maquinas/adicionar":
                return self._json(adicionar_maquina(str(corpo.get("ip", "")).strip(), corpo.get("nome"), corpo.get("mac")))
            if u.path == "/api/maquinas/remover":
                return self._json(remover_maquina(str(corpo.get("ip", "")).strip()))
            if u.path == "/api/maquinas/sincronizar":
                ip = str(corpo.get("ip", "")).strip()
                if not any(x["IP"] == ip for x in ler_pcs()):
                    return self._json({"erro": "Máquina não está na lista."}, 400)
                return self._json({"id": criar_sincronia(ip), "passos": PASSOS_SINC})
            if u.path == "/api/maquinas/veyon":            # atualiza a lista do Veyon do estúdio (pede "Sim" do Windows aqui)
                if not self._local():
                    return self._json({"erro": "Só pelo PC do estúdio (o Windows pede permissão na tela dele)."}, 403)
                script = BASE / "configurar-veyon-estudio.ps1"
                subprocess.Popen(["powershell.exe", "-NoProfile", "-Command",
                                  f"Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"{script}\"'"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=0x08000000)
                registrar_acao("Atualizar lista do Veyon", [], {})
                return self._json({"ok": True})
            if u.path == "/api/sessoes/encerrar":       # desconecta todos os notebooks/PCs que entraram com senha
                if not self._local():
                    return self._json({"erro": "Só pode ser feito no PC do estúdio."}, 403)
                n = sum(1 for v in SESSOES.values() if v > time.time())
                SESSOES.clear()
                registrar_acao("Encerrar sessões da rede", [], {"sessoes": n})
                return self._json({"ok": True, "encerradas": n})
            if u.path == "/api/acesso":                 # definir/trocar a senha de acesso pela rede
                if not self._local():
                    return self._json({"erro": "A senha só pode ser trocada no PC do estúdio."}, 403)
                senha = str(corpo.get("senha", ""))
                if len(senha) < 6:
                    return self._json({"erro": "A senha precisa ter pelo menos 6 caracteres."}, 400)
                c = ler_config()
                c["acesso"] = gerar_hash(senha)
                salvar_config(c)
                SESSOES.clear()
                registrar_acao("Senha de acesso pela rede alterada", [], {"por": self.client_address[0]})
                return self._json({"ok": True})
            if u.path == "/api/tarefa":
                acao = corpo.get("acao", "")
                ips = [ip for ip in corpo.get("ips", []) if isinstance(ip, str)]
                if acao not in ACOES_VALIDAS or not ips:
                    return self._json({"erro": "Ação desconhecida ou nenhuma máquina escolhida."}, 400)
                if acao == "TelaBloqueio" and not corpo.get("imagens"):
                    return self._json({"erro": "Escolha pelo menos uma imagem."}, 400)
                return self._json({"id": criar_tarefa(acao, ips, corpo)})
            if u.path == "/api/acao":
                acao = corpo["acao"]
                ips = corpo.get("ips", [])
                if acao not in ACOES_VALIDAS:
                    return self._json({"erro": "acao desconhecida"}, 400)
                r = executar_acao(acao, ips, corpo)
                threading.Thread(target=atualizar_status, daemon=True).start()
                return self._json({"resultados": r})
            if u.path == "/api/horario":
                c = ler_config()
                semana = {}
                for d in DIAS_SEMANA:
                    v = (corpo.get("semana") or {}).get(d) or {}
                    abre, fecha = v.get("abre", "14:00"), v.get("fecha", "17:30")
                    if dt.datetime.strptime(abre, "%H:%M") >= dt.datetime.strptime(fecha, "%H:%M"):
                        return self._json({"erro": f"No dia {d}, o horário de abrir precisa ser antes do de fechar."}, 400)
                    semana[d] = {"ativo": bool(v.get("ativo")), "abre": abre, "fecha": fecha}
                c["horario"] = {"ativo": bool(corpo.get("ativo")), "semana": semana}
                registrar_acao("Horario alterado", [], c["horario"])
                salvar_config(c)
                threading.Thread(target=sincronizar_horario, args=(dict(estado["pcs"]),), daemon=True).start()
                return self._json({"ok": True})
            if u.path == "/api/telas":            # enviar imagem (base64)
                nome = re.sub(r"[^\w.\- ]", "_", Path(str(corpo.get("nome", ""))).name).strip() or "imagem.jpg"
                ext = Path(nome).suffix.lower()
                if ext not in EXT_IMG:
                    return self._json({"erro": "Use imagens JPG ou PNG."}, 400)
                dados = base64.b64decode(corpo.get("dados", ""))
                if not dados or len(dados) > 60 * 1024 * 1024:
                    return self._json({"erro": "Imagem vazia ou maior que 60 MB."}, 400)
                TELAS.mkdir(exist_ok=True)
                destino = TELAS / nome
                n = 2
                while destino.exists():
                    destino = TELAS / f"{Path(nome).stem} ({n}){ext}"
                    n += 1
                destino.write_bytes(dados)
                return self._json({"ok": True, "nome": destino.name})
            if u.path == "/api/telas/apagar":           # uma ("nome") ou varias ("nomes")
                nomes = list(corpo.get("nomes") or []) + ([corpo["nome"]] if corpo.get("nome") else [])
                apagadas = 0
                for n in nomes:
                    arq = (TELAS / Path(str(n)).name).resolve()
                    if arq.parent == TELAS.resolve() and arq.is_file() and arq.suffix.lower() in EXT_IMG:
                        arq.unlink()
                        apagadas += 1
                if apagadas > 1:
                    registrar_acao("Galeria: fotos apagadas", [], {"total": apagadas})
                return self._json({"ok": True, "apagadas": apagadas})
            if u.path == "/api/telas/aplicar":
                ips = corpo.get("ips", [])
                if not corpo.get("imagens") or not ips:
                    return self._json({"erro": "Escolha pelo menos uma imagem e uma máquina."}, 400)
                return self._json({"resultados": executar_acao("TelaBloqueio", ips, corpo)})
            if u.path == "/api/alertas":
                palavras = [str(p).strip()[:60] for p in corpo.get("palavras", []) if str(p).strip()][:300]
                c = ler_config()
                c["alertas"] = palavras
                salvar_config(c)
                registrar_acao("Palavras de alerta alteradas", [], {"total": len(palavras)})
                return self._json({"ok": True, "total": len(palavras)})
            if u.path == "/api/historico/atualizar":
                threading.Thread(target=coletar_historico, daemon=True).start()
                return self._json({"ok": True})
        except Exception as e:
            traceback.print_exc()
            return self._json({"erro": str(e)}, 500)
        self.send_error(404)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    # so uma copia do painel por vez
    if porta_aberta("127.0.0.1", PORTA, timeout=0.5):
        log("painel ja esta rodando; saindo")
        sys.exit(0)
    # registro nao cresce para sempre
    try:
        if (AQUI / "painel.log").exists() and (AQUI / "painel.log").stat().st_size > 2_000_000:
            (AQUI / "painel.log").write_text("", encoding="utf-8")
    except OSError:
        pass
    iniciar_db()
    threading.Thread(target=laco_status, daemon=True).start()
    threading.Thread(target=laco_historico, daemon=True).start()
    log(f"Painel da Informatica em http://127.0.0.1:{PORTA} (rede: http://{ip_estudio()}:{PORTA}, com senha)")
    ThreadingHTTPServer(("0.0.0.0", PORTA), Handler).serve_forever()
