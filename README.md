# macrix

Automação do macOS + computer-use + metering de uso — servidor MCP aberto (open-core) — Calendário, Lembretes, Notas,
Shortcuts e um hook do Jev/TypeSafe. Sem limite diário, com quantos agentes
quiser ao mesmo tempo.

Inspirado no [Macuse](https://macuse.app) (que trava em 100 chamadas/dia no
plano grátis), reescrito do zero em Swift, sem dependências externas.

## Por que existe

- **Sem teto**: nenhum contador diário no código. O limite é o seu hardware.
- **Multi-agente**: registro de tools com lock, uma conexão por task — 10
  chamadas concorrentes com 2 chaves diferentes respondem 10/10.
- **Chaves múltiplas**: `MACRIX_KEYS` (vírgula) e/ou
  `~/.config/macrix/keys` (uma por linha). Qualquer chave válida entra,
  ao mesmo tempo que qualquer outra.

## Build

```sh
swift build -c release   # binário em .build/release/macrix
swift test               # 7 testes, zero rede
```

Só macOS 13+. Zero dependências (só Foundation, EventKit, Network e o
`sqlite3` que já vem no sistema).

## Uso

```sh
export MACRIX_KEYS="chave-agente-1,chave-agente-2"
macrix serve --port 35730
macrix keys     # de onde as chaves vêm + quantas
macrix version
```

Endpoints: `POST /mcp` (Bearer obrigatório), `GET /health` (aberto).

## Tools (v0.3 — 21)

### Rumo a 100 (roadmap)
v0.3 fecha a base: computer-use (8), metering/licenças e 21 tools. Até 100:
Mail compose/send, Messages send, Notas create/update, Calendário/Lembretes
create/delete, Mapas/location, Atalhos com input, AX click-em-elemento,
gravação de tela, timers/alarms, música/podcasts, Finder ops, rede/wifi,
bateria/energia, Docker/local services, clipboard, menubar stats estilo
CodexBar (janelas de uso e créditos por provider lendo logs locais) e
licenças mensais via servidor de contas. Cada família entra com testes e
prova viva antes do push.

| Tool | O que faz |
|---|---|
| `health` | vivo + versão + capacidades |
| `calendar_list_calendars` | calendários (EventKit) |
| `calendar_search_events` | eventos por período (`today`, `+7d`, ISO-8601) |
| `reminders_search` | lembretes por título |
| `notes_search_notes` | Notas.app, leitura direta só-leitura do SQLite |
| `shortcuts_list` / `shortcuts_run` | Atalhos do macOS |
| `jev_rerank` | re-ranqueia passagens com o Jev local (só com `MACRIX_JEV=1`) |
| `mail_search` | assuntos da caixa de entrada do Mail (só leitura) |
| `messages_search` | textos do Messages por substring (só leitura) |
| `contacts_search` | contatos por nome (telefones + e-mails) |
| `screen_capture` | screenshot da tela principal (retorna o caminho do PNG) |

Calendário/Lembretes pedem autorização na 1ª vez; Notas pede Full Disk Access.
Sem permissão, a tool devolve erro estruturado — nunca quebra a sessão.

## cmux

`cmux/mcp.json` tem o bloco pronto (agora apontando o binário `macrix`) para os agentes que rodam nos painéis do
[cmux](https://cmux.dev). `SKILL.md` documenta o uso agente-a-agente.

## Modelo (open-core, igual ao Macuse)

Código MIT e grátis: tier `free` com 1000 chamadas/dia/chave (10x o free
deles). `macrix license-issue --tier pro|lifetime` destrava ilimitado —
mensalidade ou lifetime, emissão no servidor de contas (v0.3 auto-emite
local como placeholder). Sem licença: free. Sem contador escondido: tudo
passa pelo `usage_status`.

## Licença

MIT (código). Tiers comerciais via arquivo de licença local.
