# SP Smart Broadcast Ecosystem

## Ecossistema de Transmissão Móvel Proprietário

> **Substituto direto do LiveU e vMix Call**, com SRT + WebRTC + Tally nativo.

---

## Estrutura do Projeto

```
SP Smart/
├── server/          Node.js TypeScript — Signaling Server (WebSocket + REST)
├── mobile/          Flutter — Aplicativo do Repórter (Android + iOS)
└── docker/          (Fase 5) Docker Compose para deploy completo
```

## Roadmap de Fases

| Fase | Objetivo                              | Status   |
|------|---------------------------------------|----------|
| 1    | Setup e Infraestrutura Base           | ✅ Feito |
| 2    | Câmera Nativa + Encoding H.265 (HEVC) | ⏳       |
| 3    | IFB e Video Return (WebRTC)           | ⏳       |
| 4    | Network Bonding / Multipath           | ⏳       |
| 5    | UI/UX Final + Docker Deploy           | ⏳       |

## Início Rápido — Servidor

```bash
cd server
cp .env.example .env
# Edite .env com AUTH_SECRET e configurações do MediaMTX
npm install
npm run dev
```

## Início Rápido — App Mobile

```bash
cd mobile
flutter pub get
flutter run
```

## Endpoints (Fase 1)

| Método | Path                        | Descrição                   |
|--------|-----------------------------|-----------------------------|
| WS     | `ws://host:3000/ws`         | Signaling (Tally + Bitrate) |
| GET    | `/health`                   | Health check                |
| GET    | `/api/reporters`            | Lista repórteres conectados |
| POST   | `/api/tally/:reporterId`    | Seta tally de um repórter   |
| POST   | `/api/tally/broadcast`      | Seta tally para todos       |
| POST   | `/api/bitrate/:reporterId`  | Comando de bitrate          |
| GET    | `/api/bitrate/presets`      | Lista presets disponíveis   |
