# SP Smart no Termux

O processo Node escuta apenas na porta alta `8080`. O Cloudflare Tunnel termina
o TLS público e encaminha o WebSocket para esse processo:

```yaml
ingress:
  - hostname: spsmart.syncplayer.com.br
    service: http://127.0.0.1:8080
  - service: http_status:404
```

Variáveis mínimas antes de iniciar:

```sh
export HOST='127.0.0.1'
export PORT='8080'
export AUTH_SECRET='<MESMO_SEGREDO_DO_APP>'
export SRT_PUBLIC_HOST='srt-direct.syncplayer.com.br'
export SRT_PORT='8890'
npm run start:termux
```

`SRT_PUBLIC_HOST` deve resolver para uma rota que entregue UDP diretamente ao
Galaxy S10+. Um Cloudflare Tunnel HTTP comum transporta o WSS, não o SRT/UDP.

## Receptor SRT AES-256

O `srt-live-transmit` exige uma entrada e uma saída. Este comando recebe na
porta alta `8890`, exige a mesma passphrase do app com PBKEYLEN 32 e entrega o
fluxo localmente via UDP na porta `10000`:

```sh
export SP_SMART_SRT_PASSPHRASE='<MESMO_AUTH_SECRET_DO_APP>'
srt-live-transmit "srt://:8890?mode=listener&transtype=live&passphrase=${SP_SMART_SRT_PASSPHRASE}&pbkeylen=32&enforcedencryption=true&latency=120" "udp://127.0.0.1:10000" -v
unset SP_SMART_SRT_PASSPHRASE
```

A porta UDP `8890` precisa estar liberada na rota pública escolhida. A porta
`10000` permanece local para MediaMTX, GStreamer ou outro consumidor no Termux.
