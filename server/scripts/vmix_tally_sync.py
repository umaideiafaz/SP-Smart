#!/usr/bin/env python3
"""
SP Smart — Script do Controle Mestre (vMix → Tally Sync)
=========================================================
Lê o estado de tally do vMix via sua API TCP e publica
SIMULTANEAMENTE nos dois servidores SP Smart (Principal e Secundário).

REQUISITOS:
    pip install requests

CONFIGURAÇÃO:
    Ajuste as variáveis abaixo conforme o seu ambiente.

USO:
    python3 vmix_tally_sync.py

O script roda em loop contínuo com polling do vMix.
Configure-o como serviço systemd ou Task Scheduler do Windows.
"""

import socket
import time
import threading
import requests
import xml.etree.ElementTree as ET
from datetime import datetime

# ── Configuração ──────────────────────────────────────────────
VMIX_HOST = '127.0.0.1'    # IP do vMix (geralmente localhost)
VMIX_PORT = 8099            # Porta TCP da API do vMix
POLL_INTERVAL_SEC = 0.1     # 100ms → latência de tally ≈ <200ms

# Servidores SP Smart (Principal e Secundário)
# O script envia para AMBOS simultaneamente em threads paralelas.
SERVERS = [
    {'name': 'PRIMARY',  'url': 'http://192.168.1.100:3000'},
    {'name': 'SECONDARY','url': 'http://192.168.1.110:3000'},  # smartphone
]

# Input do vMix a monitorar (ajuste ao seu setup)
# Se MONITORED_INPUT for None, monitora todos os inputs.
MONITORED_INPUT = None  # ex: 1 para monitorar apenas Input 1

# Autenticação HTTP Basic (opcional, se seu servidor exigir)
HTTP_TIMEOUT_SEC = 2

# ── Estado global ─────────────────────────────────────────────
_last_pgm_input: int | None = None
_last_pvw_input: int | None = None
_server_alive   = {s['name']: True for s in SERVERS}

# ─────────────────────────────────────────────────────────────

def vmix_connect() -> socket.socket | None:
    """Cria conexão TCP com a API do vMix."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((VMIX_HOST, VMIX_PORT))
        sock.sendall(b'SUBSCRIBE TALLY\r\n')
        print(f'[vMix] Conectado em {VMIX_HOST}:{VMIX_PORT}')
        return sock
    except Exception as e:
        print(f'[vMix] Falha de conexão: {e}')
        return None


def parse_vmix_xml(xml_data: str) -> tuple[int | None, int | None]:
    """
    Parseia o XML de estado do vMix e retorna (pgm_input, pvw_input).
    Retorna (None, None) em caso de erro.
    """
    try:
        root = ET.fromstring(xml_data)
        pgm = root.find('active')
        pvw = root.find('preview')
        pgm_n = int(pgm.text) if pgm is not None and pgm.text else None
        pvw_n = int(pvw.text) if pvw is not None and pvw.text else None
        return pgm_n, pvw_n
    except Exception:
        return None, None


def send_sync(server: dict, payload: dict) -> bool:
    """
    Envia POST /api/sync para um servidor SP Smart.
    Retorna True se bem-sucedido.
    """
    try:
        resp = requests.post(
            f"{server['url']}/api/sync",
            json=payload,
            timeout=HTTP_TIMEOUT_SEC,
        )
        if resp.status_code == 200:
            if not _server_alive[server['name']]:
                print(f"[{server['name']}] Servidor VOLTOU ao ar ✅")
            _server_alive[server['name']] = True
            return True
        else:
            print(f"[{server['name']}] Resposta inesperada: {resp.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        if _server_alive[server['name']]:
            print(f"[{server['name']}] Servidor INDISPONÍVEL ⚠️  (suprimindo logs subsequentes)")
        _server_alive[server['name']] = False
        return False
    except Exception as e:
        print(f"[{server['name']}] Erro ao enviar sync: {e}")
        return False


def broadcast_tally(pgm_input: int | None, pvw_input: int | None):
    """
    Determina o estado Tally a partir dos inputs do vMix
    e publica SIMULTANEAMENTE em todos os servidores.
    """
    # Determina estado (simplificado: mapa de input → repórter)
    # Em produção, mapeie cada input vMix ao reporterId correspondente.
    now_ms = int(time.time() * 1000)

    payloads: list[dict] = []

    # Input em PGM → estado PGM para todos os repórteres desse input
    if pgm_input is not None:
        payloads.append({
            'reporterId':      'all',   # ajuste para o reporterId específico
            'state':           'PGM',
            'source':          'vmix',
            'originTimestamp': now_ms,
        })

    # Input em PVW → estado PVW (somente se diferente do PGM)
    if pvw_input is not None and pvw_input != pgm_input:
        payloads.append({
            'reporterId':      'all',
            'state':           'PVW',
            'source':          'vmix',
            'originTimestamp': now_ms,
        })

    if not payloads:
        return

    # Dispara para TODOS os servidores em paralelo
    threads = []
    for server in SERVERS:
        for payload in payloads:
            t = threading.Thread(
                target=send_sync,
                args=(server, payload),
                daemon=True,
            )
            threads.append(t)
            t.start()

    for t in threads:
        t.join(timeout=HTTP_TIMEOUT_SEC + 0.5)


def poll_vmix():
    """Loop principal: polling do vMix com reconexão automática."""
    global _last_pgm_input, _last_pvw_input

    while True:
        sock = vmix_connect()
        if sock is None:
            print('[vMix] Reconectando em 5s...')
            time.sleep(5)
            continue

        buffer = ''
        try:
            while True:
                data = sock.recv(4096).decode('utf-8', errors='ignore')
                if not data:
                    break
                buffer += data

                # O vMix envia respostas XML completas seguidas de \r\n
                while '\r\n' in buffer:
                    line, buffer = buffer.split('\r\n', 1)
                    if line.startswith('<?xml') or line.startswith('<vmix>'):
                        pgm, pvw = parse_vmix_xml(line)
                        # Só envia sync se o estado mudou
                        if pgm != _last_pgm_input or pvw != _last_pvw_input:
                            ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
                            print(f'[{ts}] Tally mudou: PGM={pgm} PVW={pvw}')
                            broadcast_tally(pgm, pvw)
                            _last_pgm_input = pgm
                            _last_pvw_input = pvw

                time.sleep(POLL_INTERVAL_SEC)

        except Exception as e:
            print(f'[vMix] Conexão perdida: {e}')
        finally:
            try:
                sock.close()
            except Exception:
                pass
        print('[vMix] Reconectando...')
        time.sleep(2)


if __name__ == '__main__':
    print('=' * 60)
    print('  SP Smart — Controle Mestre (vMix Tally Sync)')
    print(f'  Servidores: {[s["name"] for s in SERVERS]}')
    print('=' * 60)
    poll_vmix()
