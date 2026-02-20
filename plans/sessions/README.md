# Claude Code Sessions

Záloha kompletních Claude Code session transcriptů pro projekt somewm.

## Obsah

- `claude-sessions-2026-02-20.zip` — 48 sessions, veškerá práce na somewm

## Klíčové sessions

| Session ID | Popis |
|-----------|-------|
| `2259992d` | Multi-monitor hotplug (6 bugů), keyboard focus desync, upstream issues #216/#237 |
| `c9204253` | XWayland keyboard focus (#137), ICCCM input model, exec UAF |
| `933a13d3` | XKB keyboard layout switching (#233) |
| `2d911d15` | Cold restart, somewm-session, DBus handling |

## Jak použít

### Prohlížení session transcriptu

Session soubory jsou JSONL (jeden JSON objekt na řádek). Každý řádek obsahuje
zprávu (user/assistant/tool_use/tool_result):

```bash
# Rozbalit
unzip claude-sessions-2026-02-20.zip -d /tmp/sessions

# Prohlédnout konkrétní session (human-readable)
cat /tmp/sessions/2259992d-960e-44a9-aa8c-8581f7c76551.jsonl | python3 -m json.tool --no-ensure-ascii | less

# Filtrovat jen user a assistant zprávy
cat /tmp/sessions/SESSION_ID.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    msg = json.loads(line)
    role = msg.get('role', '')
    if role in ('user', 'assistant'):
        content = msg.get('message', {}).get('content', '')
        if isinstance(content, str):
            print(f'=== {role.upper()} ===')
            print(content[:500])
            print()
" | less
```

### Pokračování v session (Claude Code CLI)

Claude Code automaticky ukládá sessions do:
```
~/.claude/projects/-home-box-git-github-somewm/
```

Pro pokračování v existující session:
```bash
# Claude Code si pamatuje poslední session automaticky
# Pro výběr konkrétní session použij:
claude --resume SESSION_ID
```

### Obnovení sessions ze zálohy

```bash
# Rozbalit zpět do Claude Code adresáře
unzip claude-sessions-2026-02-20.zip -d ~/.claude/projects/-home-box-git-github-somewm/
```
