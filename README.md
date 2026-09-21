# macrix

Automação do macOS + computer-use + metering de uso — servidor MCP aberto (open-core). **v0.24.0: 100 tools**, console web e medição por chave. Sem o teto de 100 chamadas/dia do Macuse, com quantos agentes quiser ao mesmo tempo.

Inspirado no [Macuse](https://macuse.app), reescrito do zero em Swift, sem dependências externas.

## Por que existe

- **Sem o teto deles**: o free do Macuse trava em 100 chamadas/dia; aqui o tier `free` tem 1000/dia/chave e os pagos são ilimitados na prática. O limite é o seu hardware.
- **Multi-agente provado**: registro de tools com lock, uma conexão por task — 25 chamadas paralelas com a mesma chave respondem 25/25 (medido em 21/09/2026).
- **Chaves múltiplas**: `MACRIX_KEYS` (vírgula) e/ou `~/.config/macrix/keys` (uma por linha). Qualquer chave válida entra, ao mesmo tempo que qualquer outra.

## Build

```sh
swift build -c release   # binário em .build/release/macrix
swift test               # 80 testes, zero rede
```

Só macOS 13+. Só frameworks do sistema (Foundation, EventKit, Network, CryptoKit, CoreImage) + o `sqlite3` que já vem no sistema.

## Uso

```sh
export MACRIX_KEYS="chave-agente-1,chave-agente-2"
macrix serve --port 35730
macrix keys     # de onde as chaves vêm + quantas
macrix version
```

Endpoints: `POST /mcp` (Bearer [REDACTED]ório), `GET /health` (aberto), `GET /` (console, aberto), `GET /catalog` (100 tools em JSON, aberto), `GET /usage` (medição da chave, Bearer).

## Tools (v0.24 — 100)

Contagem medida via `GET /catalog` em 21/09/2026. Fonte da verdade é o endpoint; a tabela agrupa por família:

| Família | Tools |
|---|---|
| Apps Apple (calendário, lembretes, notas, atalhos, mail/messages, contatos, tela) | 14 |
| Sistema e sondas (sys, launchd, host, tailscale, meta, plist, áudio, markdown) | 19 |
| Arquivos e texto (file, zip, text, grep, csv) | 12 |
| Web e rede (chromium, url, net) | 11 |
| Codec e dados (b64, sha, uuid, json, qr, random, imagem, dir) | 11 |
| Computer-use | 9 |
| Jev/TypeSafe (route, rerank, eval, check, skill, models, ping) | 7 |
| Clipboard e UI (clip, open, notify, voz-arquivo, quit) | 6 |
| Catálogo e metering (catalog, usage, providers, health) | 6 |
| Git (status, log, diff) + relógio | 5 |

Calendário/Lembretes pedem autorização na 1ª vez; Notas pede Full Disk Access. Sem permissão, a tool devolve erro estruturado — nunca quebra a sessão. Voz nunca toca no alto-falante (`tts_render` gera arquivo).

## cmux

`cmux/mcp.json` tem o bloco pronto (agora apontando o binário `macrix`) para os agentes que rodam nos painéis do [cmux](https://cmux.dev). `SKILL.md` documenta o uso agente-a-agente.

## Modelo (open-core, igual ao Macuse)

Código MIT e grátis: `free` 1000/dia, `starter` US$20 (10k/dia), `growth` US$50 (50k/dia), `scale` US$100 (200k/dia), `max` US$200 e `lifetime` ilimitados. Quota estourada devolve erro `-32000` nomeando o tier — nunca silencia. Tudo passa pelo `usage_status` e pelo `GET /usage`. Cobrança via processador: checklist em `BILLING.md` (conta e emissão são do dono; o servidor já sabe ler o arquivo de licença e rebaixar sozinho no vencimento).

## Licença

MIT (código). Tiers comerciais via arquivo de licença local.
