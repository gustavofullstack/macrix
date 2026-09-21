# macuse-open

Servidor MCP aberto para automação do macOS — Calendário, Lembretes, Notas,
Shortcuts e um hook do Jev/TypeSafe. Sem limite diário, com quantos agentes
quiser ao mesmo tempo.

Inspirado no [Macuse](https://macuse.app) (que trava em 100 chamadas/dia no
plano grátis), reescrito do zero em Swift, sem dependências externas.

## Por que existe

- **Sem teto**: nenhum contador diário no código. O limite é o seu hardware.
- **Multi-agente**: registro de tools com lock, uma conexão por task — 10
  chamadas concorrentes com 2 chaves diferentes respondem 10/10.
- **Chaves múltiplas**: `MACUSE_OPEN_KEYS` (vírgula) e/ou
  `~/.config/macuse-open/keys` (uma por linha). Qualquer chave válida entra,
  ao mesmo tempo que qualquer outra.

## Build

```sh
swift build -c release   # binário em .build/release/macuse-open
swift test               # 7 testes, zero rede
```

Só macOS 13+. Zero dependências (só Foundation, EventKit, Network e o
`sqlite3` que já vem no sistema).

## Uso

```sh
export MACUSE_OPEN_KEYS="chave-agente-1,chave-agente-2"
macuse-open serve --port 35730
macuse-open keys     # de onde as chaves vêm + quantas
macuse-open version
```

Endpoints: `POST /mcp` (Bearer obrigatório), `GET /health` (aberto).

## Tools (v0.1 — 8)

| Tool | O que faz |
|---|---|
| `health` | vivo + versão + capacidades |
| `calendar_list_calendars` | calendários (EventKit) |
| `calendar_search_events` | eventos por período (`today`, `+7d`, ISO-8601) |
| `reminders_search` | lembretes por título |
| `notes_search_notes` | Notas.app, leitura direta só-leitura do SQLite |
| `shortcuts_list` / `shortcuts_run` | Atalhos do macOS |
| `jev_rerank` | re-ranqueia passagens com o Jev local (só com `MACUSE_OPEN_JEV=1`) |

Calendário/Lembretes pedem autorização na 1ª vez; Notas pede Full Disk Access.
Sem permissão, a tool devolve erro estruturado — nunca quebra a sessão.

## cmux

`cmux/mcp.json` tem o bloco pronto para os agentes que rodam nos painéis do
[cmux](https://cmux.dev). `SKILL.md` documenta o uso agente-a-agente.

## Licença

MIT.
